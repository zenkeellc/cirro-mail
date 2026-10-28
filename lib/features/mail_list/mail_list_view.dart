import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/breakpoints.dart';
import '../../data/models/enums.dart';
import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../data/models/mailbox_account.dart';
import '../../data/models/user_info.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/mail_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/sync_providers.dart';
import '../../router.dart';
import '../outbox/send_queue_bar.dart';
import '../suggest/mail_row_menu.dart';
import 'mail_row_tile.dart';
import 'mail_selection.dart';
import 'mail_selection_pane.dart';

/// 邮件列表的通用主体：聚合 / 收件箱 / 已发送 / 星标四个页面共用。
///
/// 三条与后端契约直接相关的设计：
/// 1. **列表数据只来自本地库**（`mailListProvider` watch drift）。网络只在
///    `MailListController` 里跑，写库之后列表自动刷新 —— UI 不需要维护
///    「请求回来了但界面没动」这类状态。
/// 2. **下拉刷新 = 让所有实例同步一轮**，而不是重拉本页。服务端没有
///    「按时间戳取增量」的口径，只能靠同步引擎维护游标。
/// 3. **滚到底在聚合视图里不做翻页**：各实例的 `emailId` 是独立序列，
///    跨实例没有统一游标；聚合视图的「更多」语义是「再同步一轮」。
class MailListView extends ConsumerStatefulWidget {
  const MailListView({
    super.key,
    required this.query,
    this.listNode,
    this.showInstanceBand = false,
    this.emptyHint,
    this.onOpen,
    this.multiSelect = false,
    this.headerSlivers = const <Widget>[],
    this.selected,
  });

  final MailListQuery query;

  /// 这一页是哪张列表：实例 id 或 `all`（聚合）。**没传就是聚合**。
  ///
  /// 只影响 [MailListView._open] 那条兜底路径（页面的地址里写哪个节点）；
  /// 调用方已经用 `onOpen` 接管时它用不上。
  final String? listNode;

  /// 聚合视图为 true（每行加实例色带与标签）。
  final bool showInstanceBand;

  /// 空列表时的提示语（不同文件夹用不同文案）。
  final String? emptyHint;

  /// 覆盖默认的「打开」行为。默认是跳到详情路由。
  final void Function(MailRow row)? onOpen;

  /// 这一块列表接不接多选（复选框、长按拖动、Shift/Ctrl、右键批量）。
  ///
  /// **默认 false**：发件箱 / 草稿箱那两处不该沾上多选 —— 那两屏没有「一批
  /// 一起处理」的语义（服务端连「移到文件夹」都没有）。默认值让现有的
  /// `MailListView(query: …)` 行为逐字不变。
  ///
  /// 收件箱 / 星标两屏传 true。窄屏也开：那里多选由长按进入，常用动作走底部
  /// 操作栏（见 `MailSelectionBar`）。
  final bool multiSelect;

  /// 追加在列表之前的 sliver（筛选栏等）。
  final List<Widget> headerSlivers;

  /// 分栏形态下当前在右侧打开的那封。窄屏恒为 null。
  final MailRef? selected;

  @override
  ConsumerState<MailListView> createState() => _MailListViewState();
}

class _MailListViewState extends ConsumerState<MailListView> {
  final ScrollController _controller = ScrollController();

  /// 长按拖动时，那一段「带子」是从哪一行按下去的。
  ///
  /// 往回拖时起点要跟着往上走（`from = min(按下行, 当前行)`），所以按下那一行
  /// 必须留一份 —— 指针事件给的只是「相对按下点走了多远」。
  int? _dragFrom;

  /// 指针按下时的全局位置（长按拖动换算的参照点）。
  ///
  /// 由 [Listener] 记；长按判定本身是 `InkWell` 的
  /// `LongPressGestureRecognizer` 的事（它还要负责水波反馈），这里只是**旁听**
  /// 指针：等它认了长按（`onLongPress` 回调 → [_onLongPress]），再从这里记下的
  /// 位置开始算指针走了多远。
  Offset? _pointerDownAt;

  /// 第一行的内容高度，由 `_measureFirstRow` 量出来。0 = 还没量到。
  double _measuredRowHeight = 0;

  /// 「继续加载」这一刻是否真的在跑（占位行/页脚的转圈与防重复点）。
  ///
  /// 不能用 `controller.isLoadingMore` 代替：那是普通字段，`loadMore` 里改它
  /// 不会让这一屏重建 —— 用户点了之后既看不到转圈、也能连点好多下。
  bool _advancing = false;

  /// 上一次由滚动触发的加载时间（节流用）。
  DateTime _lastScrollLoad = DateTime.fromMillisecondsSinceEpoch(0);

  /// 只有一个邮箱时才允许翻页（多邮箱没有统一游标）。
  bool get _canLoadMore => widget.query.singleMailbox;

  /// 这一块列表的 scope 串（多选不跨列表串味的判据）。
  String get _scope =>
      selectionScopeForQuery(widget.query, listNode: widget.listNode);

  /// 这块列表接不接多选。
  bool get _selectable => widget.multiSelect;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_maybeLoadMore);
    // 首帧之后补一次「更旧的一页」——冷启动本地只有游标附近的数据，
    // 不补的话用户一进来滚两下就见底了。
    WidgetsBinding.instance.addPostFrameCallback((_) => _primeFirstPage());
    // 让多选状态认下「这一块列表」：换了列表（切文件夹/实例/Tab）时
    // `enter` 会把旧选择清掉，见 [MailSelectionController.enter]。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncScope());
  }

  @override
  void didUpdateWidget(MailListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listNode != widget.listNode || oldWidget.query != widget.query) {
      // 帧后做：build 期间改 provider 会触发 riverpod 的断言。
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncScope());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_maybeLoadMore);
    _controller.dispose();
    super.dispose();
  }

  void _syncScope() {
    if (!mounted || !_selectable) return;
    ref.read(mailSelectionProvider.notifier).enter(_scope);
  }

  Future<void> _primeFirstPage() async {
    final controller = ref.read(mailListControllerProvider(widget.query));
    // `_canLoadMore`（单邮箱）才预热：多邮箱那一支的 `loadMore()` 是
    // 「再同步一轮」，进页面就白推一次是浪费。但**滚到底那一下要接上**
    // —— 聚合视图底部的说明写的就是「滚到底会自动同步」，见
    // `_maybeLoadMore`。
    if (!_canLoadMore) return;
    // 预热也要走「可能先放本地窗口」那条路：本地已经缓存了多过一屏的邮件时，
    // 进页面就该多露出一页，而不是无条件再发一个「更旧」的请求。
    if (controller.hasMore || await controller.cachedBeyondWindow()) {
      await _advance();
    }
  }

  void _maybeLoadMore() {
    if (!_controller.hasClients) return;
    if (_advancing) return;
    final position = _controller.position;
    if (position.pixels < position.maxScrollExtent - 400) return;
    // 滚到底会连着收到一串事件（尤其 iOS 的回弹）：节流，别一秒发十几个
    // count 查询。真正的重复请求还有 `_advancing` 挡着。
    final now = DateTime.now();
    if (now.difference(_lastScrollLoad) < const Duration(milliseconds: 300)) {
      return;
    }
    _lastScrollLoad = now;
    unawaited(_advance());
  }

  /// 推进列表（「加载更多」的唯一入口：滚动、预热、点占位行都走这里）。
  ///
  /// [retryExhausted] 只在用户**主动点了**底部占位行时为 true —— 那个数字可能
  /// 是旧快照算出来的，到底之后也值得再问服务端一次（见
  /// `MailListController.loadMore`）。
  Future<void> _advance({bool retryExhausted = false}) async {
    if (_advancing) return;
    if (!mounted) return;
    setState(() => _advancing = true);
    try {
      await ref
          .read(mailListControllerProvider(widget.query))
          .loadMore(retryExhausted: retryExhausted);
    } finally {
      if (mounted) setState(() => _advancing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(mailListProvider(widget.query));
    final controller = ref.watch(mailListControllerProvider(widget.query));
    final rows = async.value ?? const <MailRow>[];
    // 「还有 N 封没同步」：0 / null 都表示「别说」。在同一处算一次，
    // 占位行与页脚用同一个数 —— 否则会出现「还有 10 封未同步 · 点击继续加载」
    // 与「没有更多了」同时挂在一屏上的自相矛盾。
    final unsynced =
        ref.watch(unsyncedPlaceholderProvider(widget.query)).value ?? 0;
    final refs = <MailRef>[
      for (final row in rows)
        MailRef(profileId: row.profileId, emailId: row.emailId),
    ];

    final selection =
        _selectable ? ref.watch(mailSelectionProvider) : MailSelection.empty;
    // scope 对不上就不接管：多选记着的是**做选择时的那一块列表**，切了文件夹
    // 之后旧选择还在状态里，但它不该点亮这一屏的任何一行。判据与列表页那边
    // 决定右栏显示什么时用的是**同一个函数**（`selectionAppliesTo`）。
    final selecting = _selectable && selectionAppliesTo(selection, _scope);
    // 折一次就够了：高亮、统计、缩略表全都看这一份下标（`selectedRowsProvider`
    // 内部折的是同一条规则）。
    final picked = selecting ? selection.positions(rows.length) : const <int>[];
    final stats = selecting
        ? ref.watch(selectedRowsProvider(widget.query))
        : const SelectedMails();

    // 「选中的行一封都不在了」（被删/被过滤掉）→ 退出多选。
    //
    // **只在视图层做**：写回 `mailSelectionProvider` 是状态变更，放在派生
    // provider 里会在 build 期间触发 riverpod 的断言。判据要 `prev != null`
    // ——列表加载中（`value == null`）时统计也会是空的，那不该等于「用户
    // 选的东西没了」。
    ref.listen(selectedRowsProvider(widget.query), (prev, next) {
      if (!selecting) return;
      if (prev == null || prev.count == 0 || next.count != 0) return;
      ref.read(mailSelectionProvider.notifier).clear();
    });

    return Stack(
      children: <Widget>[
        RefreshIndicator(
          onRefresh: () => controller.refresh(),
          child: CustomScrollView(
            controller: _controller,
            // 空列表时也要能下拉 —— RefreshIndicator 需要一个可滚动的子节点。
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              ...widget.headerSlivers,
              if (async.hasError && !async.hasValue)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _ListStatus(
                    icon: Icons.cloud_off,
                    title: AppLocalizations.of(context).loadFailed,
                    detail: '${async.error}',
                    onRetry: () => controller.refresh(),
                  ),
                )
              else if (rows.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _ListStatus(
                    icon: Icons.mark_email_read_outlined,
                    title:
                        widget.emptyHint ?? AppLocalizations.of(context).emptyList,
                  ),
                )
              else
                SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        // 次键手势要包在**外面**：`InkWell` 不认次键点击，
                        // 而 `onSecondaryTapUp`（不是 `onSecondaryTap`）
                        // 的 `TapUpDetails` 带 `globalPosition`，
                        // `showMenu` 要它来定位。
                        //
                        // 次键与 `InkWell` 的主键/长按在 gesture arena 里
                        // 用的是不同的 recognizer，**不冲突** ——
                        // 这里不需要 `behavior` 之类的花招。
                        GestureDetector(
                          onSecondaryTapUp: (details) => _onSecondaryTapUp(
                            details.globalPosition,
                            index,
                            row,
                            refs,
                          ),
                          // 长按与「长按后拖动扫选」都挂在这一层。
                          //
                          // 用 `Listener`（指针原始事件）而不是再叠一个
                          // `GestureDetector`：`InkWell` 内部**已经**有一个
                          // `LongPressGestureRecognizer` 了，同一个
                          // `PointerDownEvent` 上再挂一个，两者会同时在竞技场
                          // 里、同时到期、同时 `accept` —— 谁赢不确定。而
                          // `Listener` 不进竞技场，只是旁听指针：谁最终赢、
                          // 是谁负责「打开/弹菜单」，这里一概不管。
                          //
                          // 于是分工是：**「按住多久算长按」交给 `InkWell`**
                          // （它还要负责水波反馈），长按一旦认下（`onLongPress`
                          // → [_onLongPress]）就起一条拖动带；`Listener` 只记
                          // 「按下的位置」，供 [_onPointerMove] 换算指针走了
                          // 多远。
                          child: Listener(
                            onPointerDown: _onPointerDown,
                            onPointerMove: (event) =>
                                _onPointerMove(event.position, rows),
                            onPointerUp: (_) => _onPointerEnd(),
                            onPointerCancel: (_) => _onPointerEnd(),
                            child: Builder(
                              builder: (rowContext) {
                                if (index == 0) _measureFirstRow(rowContext);
                                return MailRowTile(
                                  // 聚合视图里 emailId 会重号，key 必须带实例。
                                  key: ValueKey<String>(
                                      '${row.profileId}#${row.emailId}'),
                                  row: row,
                                  showInstanceBand: widget.showInstanceBand,
                                  // 用 MailRef 比而不是比 emailId：聚合视图里两个
                                  // 实例的 emailId 会撞号，直接比会点亮两行。
                                  selected: widget.selected != null &&
                                          widget.selected!.profileId ==
                                              row.profileId &&
                                          widget.selected!.emailId == row.emailId ||
                                      (selecting && picked.contains(index)),
                                  // 多选时这一格换成复选框（替掉头像，宽度不变）。
                                  selectionMode: selecting,
                                  onCheckboxToggle:
                                      selecting ? () => _toggleAt(index) : null,
                                  onTap: () => _onTap(index, row, refs),
                                  // 长按**两副面孔**：不可多选的列表弹行菜单
                                  // （没有坐标 → 底部弹窗），可多选的列表进入
                                  // 多选并起一条拖动带。判据在 `_onLongPress`。
                                  onLongPress: () => _onLongPress(index, row, refs),
                                );
                              },
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                      ],
                    );
                  },
                ),
              if (rows.isNotEmpty) ...<Widget>[
                // 「还有 N 封没同步」的占位行。放在真正的邮件行之后、
                // 状态页脚之前 —— 它属于列表内容的一部分（点一下继续加载），
                // 而不是一句说明文字。
                _UnsyncedPlaceholder(
                  remaining: unsynced,
                  canAdvance: _canLoadMore,
                  busy: _advancing,
                  // 用户主动点的这一下传 `retryExhausted`：数字可能是旧快照
                  // 算出来的，`hasMore == false` 也值得再问服务端一次。
                  onTap: () => unawaited(_advance(retryExhausted: true)),
                ),
                SliverToBoxAdapter(
                  child: _ListFooter(
                    loading: _advancing || controller.isLoadingMore,
                    // 占位行还在说「还有 N 封」的时候，页脚不能说「没有更多了」。
                    exhausted: !controller.hasMore && unsynced <= 0,
                    aggregate: !_canLoadMore,
                  ),
                ),
              ],
            ],
          ),
        ),
        // 发送队列微标签（需求六）常驻在列表底部。挂在 `Stack` 上而不是
        // 塞进 slivers：它不该跟着列表滚走 —— 信到点自己发出去这件事
        // 与用户当前滚到哪一页无关。
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SendQueueBar(),
        ),
        // 窄屏多选的操作栏（宽屏有右栏，不需要它）。压在发送队列那条之上
        // —— 两条同时出现时，多选是用户此刻正在做的事，该看得见的是它。
        if (selecting && !Breakpoints.panesOf(context))
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: MailSelectionBar(stats: stats),
          ),
      ],
    );
  }

  // ------------------------------------------------------------ 手势

  /// 点一行。
  ///
  /// 三层：没进多选就是「打开」（今天的行为，一行不改）；已进多选、按了修饰键
  /// 就按 Shift（连续）/ Ctrl·Cmd（切换）扩展；否则把选择换成这一行。
  void _onTap(int index, MailRow row, List<MailRef> refs) {
    if (!_selectable) {
      _open(row);
      return;
    }
    final selection = ref.read(mailSelectionProvider);
    final notifier = ref.read(mailSelectionProvider.notifier);
    final mods = _modifiers();

    if (mods.shift) {
      if (selection.isActive) {
        notifier.extendTo(index, refs);
      } else {
        notifier.selectOnly(index, anchor: refs[index]);
      }
      return;
    }
    if (mods.toggle) {
      notifier.toggle(index);
      return;
    }
    if (selection.isActive) {
      notifier.selectOnly(index, anchor: refs[index], clearAnchor: true);
      return;
    }
    _open(row);
  }

  void _toggleAt(int index) =>
      ref.read(mailSelectionProvider.notifier).toggle(index);

  void _onLongPress(int index, MailRow row, List<MailRef> refs) {
    if (!_selectable) {
      // 不可多选的列表（已发送…）保持原样：长按弹行菜单。
      unawaited(MailRowMenu.show(context, ref, row));
      return;
    }
    _dragFrom = index;
    ref.read(mailSelectionProvider.notifier).beginBand(index, anchor: refs[index]);
  }

  /// 长按后拖动：带子按**行**扩展。
  ///
  /// 换算用「指针相对按下点走了多远 ÷ 行高」，起止行是
  /// `(按下行, 按下行 + 跨过的行数)` 那段连续区间 —— 往回拖时起点跟着往上走，
  /// 所以长度是 `|Δ行| + 1`。
  ///
  /// **拖到边缘不自动滚动**（有意留白）：那要求把「列表自己滚了多少」也加进
  /// 位移里（`PointerMoveEvent.position` 只反映指针，不含滚动），而自动滚动
  /// 本身又会反过来改变行高换算 —— 是一整块单独的活，做一个半对的版本不如
  /// 先不做。
  void _onPointerMove(Offset position, List<MailRow> rows) {
    final from = _dragFrom;
    if (from == null || rows.isEmpty) return;
    final down = _pointerDownAt;
    if (down == null) return;
    final rowHeight = _rowHeight;
    if (rowHeight <= 0) return;
    final delta = ((position.dy - down.dy) / rowHeight).round();
    final current = (from + delta).clamp(0, rows.length - 1);
    final start = current < from ? current : from;
    final length = (current - from).abs() + 1;
    ref.read(mailSelectionProvider.notifier).updateBand(start, length);
  }

  void _onPointerEnd() {
    final from = _dragFrom;
    _pointerDownAt = null;
    if (from == null) return;
    _dragFrom = null;
    ref
        .read(mailSelectionProvider.notifier)
        .endBand(ref.read(mailListProvider(widget.query)).value?.length ?? 0);
  }

  /// 指针按下：记位置（拖动换算的参照点）。
  ///
  /// 长按判定不在这里 —— 那是 `InkWell` 的 `LongPressGestureRecognizer` 的
  /// 事（它还要负责水波反馈），这里只是**旁听**：等它认了长按（[onLongPress]
  /// 回调），从这里记下的位置开始算指针走了多远。
  void _onPointerDown(PointerDownEvent event) {
    _pointerDownAt = event.position;
  }

  /// 右键：**先选中这一封**，再在指针处弹出菜单。
  ///
  /// 两条都是用户报的那个 bug（需求 2）。批量语义见 `MailRowMenu.show` 的
  /// [batch]：落在已选中的一行上就保持整批，否则把选择换成这一行。
  void _onSecondaryTapUp(
    Offset at,
    int index,
    MailRow row,
    List<MailRef> refs,
  ) {
    var batch = const <MailRow>[];
    if (_selectable) {
      ref.read(mailSelectionProvider.notifier).rightClick(index, refs);
      batch = ref.read(selectedRowsProvider(widget.query)).rows;
    }
    unawaited(MailRowMenu.show(
      context,
      ref,
      row,
      at: at,
      batch: batch,
    ));
  }

  /// 当前按着哪些修饰键。
  ///
  /// 当场读 `HardwareKeyboard.instance` 而不是把键盘事件传下来：`onTap` 是
  /// 同步回调，读到的一定是**当次事件那一刻**的状态；而沿着树转发键事件既
  /// 要维护一份自己的键盘状态，又会和 `InkWell` 的水波反馈抢事件。
  ///
  /// Flutter 没有跨平台的 Meta/Control 单例，只能看按下集合里有没有这三个键
  /// 中的任何一个。
  ({bool shift, bool toggle}) _modifiers() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final shift = keys.contains(LogicalKeyboardKey.shift) ||
        keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
    final toggle = keys.contains(LogicalKeyboardKey.control) ||
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.meta) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
    return (shift: shift, toggle: toggle);
  }

  /// 一行占多高 = 量到的行高 + 1（那一行下面 `Divider(height: 1)` 的厚度）。
  ///
  /// `_measureFirstRow` 拿到的 `rowContext` 是 `Builder` 的 —— 它底下第一个
  /// render object 就是这一行本身（`GestureDetector`/`Listener` 那一层），
  /// **不含**分隔线。少了这 1px，拖过 50 行就差出大半行。
  ///
  /// 拖动的**第一帧**还没有测量值（`_measureFirstRow` 是帧后回调），退回到
  /// 一个粗略常数即可 —— 那时带子刚起、长度就是 1，误差没有任何影响。
  double get _rowHeight => _measuredRowHeight > 0 ? _measuredRowHeight + 1 : 72;

  /// 量第一行的**内容**高度（不含它下面那条 1px 分隔线 —— 见 [_rowHeight]）。
  ///
  /// 由 itemBuilder 里 `Builder` 的 `context` 调：`findRenderObject` 会往下
  /// 找到这一行自己的那个 `RenderBox`（`InkWell` 那一层），分隔线是它在
  /// `Column` 里的**兄弟**，所以不在这个高度里。只在 index == 0 时调，一帧
  /// 最多排一次回调。
  void _measureFirstRow(BuildContext rowContext) {
    if (_measuring) return;
    _measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measuring = false;
      if (!mounted) return;
      final box = rowContext.findRenderObject();
      if (box is RenderBox && box.attached && box.size.height > 0) {
        _measuredRowHeight = box.size.height;
      }
    });
  }

  /// 防重入：同一帧里 `Builder` 可能被调多次。
  bool _measuring = false;


  void _open(MailRow row) {
    final handler = widget.onOpen;
    if (handler != null) {
      handler(row);
      return;
    }
    // 详情路由要带着**这一页的列表节点**与**这封邮件真正所属的实例**，两者
    // 是两件事：聚合列表里每一行来自不同实例，写进路径段的只能是列表自己的
    // 节点（`?profile=` 才是实例）。见 `detailRouteOf` 的注释。
    context.go(
      detailRouteOf(
        node: Routes.aliasOf(widget.listNode),
        profileId: row.profileId,
        emailId: row.emailId,
        folder: widget.query.folder,
        unreadOnly: widget.query.unreadOnly,
      ),
    );
  }
}

/// 列表底部那条「还有 N 封未同步 · 点击继续加载」（需求三）。
///
/// 刻意**长得不像一封邮件**：没有发件人、没有时间、居中的 `labelSmall` 文字，
/// 底色是 `surfaceContainerHighest`。它的用途是回答「下面还有东西吗」，
/// 而那正是无限滚动最容易让人怀疑的地方 —— 用户划到底看到一行空隙，
/// 分不清是「没有了」还是「还在下载」。
///
/// 数字未知（还没完整拉过一次列表）时不显示：宁可什么都不说，也不要给一个
/// 猜出来的数字 —— 那个数字会被用户拿去和邮箱网页版对账。
class _UnsyncedPlaceholder extends StatelessWidget {
  const _UnsyncedPlaceholder({
    required this.remaining,
    required this.onTap,
    required this.canAdvance,
    this.busy = false,
  });

  /// 还有几封没同步（0 / null 已经在调用方折成 0）。
  final int remaining;

  final VoidCallback onTap;

  /// 这一行点下去**真的能推进**吗（= 单邮箱，`loadMore` 走的是翻页）。
  ///
  /// 不满足时把它从可点降级成一句说明文字，而不是继续挂一个 `onTap`：
  /// 多邮箱 / 聚合视图里那一支是「再同步一轮」，它既不一定会让这个数变小
  /// （信可能本来就在服务端、只是本地还没拉），用户点完看到数字不动，
  /// 只会得出「按钮坏了」。点不动但说清楚，比点得动却毫无反应好。
  final bool canAdvance;

  /// 正在加载（转圈 + 不接第二次点击）。
  ///
  /// 没有它的话，用户点下去到列表变化的这几百毫秒里**什么反馈都没有** ——
  /// 这正是「点了没反应」的一半来源：请求其实发出去了，但界面既不转圈也
  /// 不禁止连点。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (remaining <= 0) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final label = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (busy)
          const SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(
            Icons.cloud_download_outlined,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        const SizedBox(width: 8),
        Text(
          canAdvance
              ? l10n.pendingMore(remaining)
              : l10n.pendingMorePassive(remaining),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return SliverToBoxAdapter(
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        child: canAdvance
            ? InkWell(
                // 加载中不接第二次点击：这次点击已经没有意义，接了只会
                // 让用户以为「点一下才动一下」。
                onTap: busy ? null : onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: label,
                ),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: label,
              ),
      ),
    );
  }
}

/// 列表底部的「加载更多 / 到底了」提示。
class _ListFooter extends StatelessWidget {
  const _ListFooter({
    required this.loading,
    required this.exhausted,
    required this.aggregate,
  });

  final bool loading;
  final bool exhausted;
  final bool aggregate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final String text;
    if (aggregate) {
      text = l10n.listAggregateFooter;
    } else if (loading) {
      text = l10n.listLoadingMore;
    } else if (exhausted) {
      text = l10n.listNoMore;
    } else {
      text = '';
    }
    if (text.isEmpty) {
      return const SizedBox(height: 24);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (loading) ...<Widget>[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            text,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 空态 / 错误态。
class _ListStatus extends StatelessWidget {
  const _ListStatus({
    required this.icon,
    required this.title,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleSmall),
            if (detail != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(AppLocalizations.of(context).retry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 折叠当前视图的实例过滤条件。
///
/// 单独抽出来是因为聚合时间线、星标页都要用，而它们对「过滤」的表达不同
/// （前者允许多选，后者只显示不选）。
extension MailListQueryX on MailListQuery {
  bool covers(String profileId) =>
      mailboxes.isEmpty || profileIds.contains(profileId);

  MailRef refOf(MailRow row) =>
      MailRef(profileId: row.profileId, emailId: row.emailId);
}

/// 供筛选栏复用：把 `MailFolder` 翻成界面文案。
String folderLabel(MailFolder folder, AppLocalizations l10n) => switch (folder) {
  MailFolder.receive => l10n.inbox,
  MailFolder.send => l10n.sent,
  MailFolder.starred => l10n.starred,
};

/// 让设置页/侧栏能拿到「这个实例的主邮箱」，避免各自复算。
MailboxAccount? primaryMailboxOf(List<MailboxAccount> list) =>
    list.primaryOrNull;

/// 从 `UserInfo` 造一个临时邮箱（登录刚完成、`/account/list` 还没回来时用）。
MailboxAccount? mailboxFromUserInfo(UserInfo user) =>
    MailboxAccount.fromLoginUserInfo(user.account);

