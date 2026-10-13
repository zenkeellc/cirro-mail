import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../../l10n/app_localizations.dart';
import 'compose_sender.dart';

/// 发件人那一行。
///
/// 形状：左边一个 label（与收件人 / 主题两行同构），右边是「姓名 <邮箱>」
/// 加一行小字的实例名。**选不出人**时是一句红字（说清原因），不可点。
///
/// **恰好一个候选时形状不变**，只是不画下拉箭头、点它不展开。两个实例各有
/// 一个邮箱时，这一行不该长得跟只有一个实例时不一样；顺带把「这封信从哪台
/// 实例发」这个此前完全看不见的信息摆出来（改造前它是一个纯文本行）。
///
/// ## 面板为什么是 `OverlayPortal` 而不是 `MenuAnchor`
///
/// 手法照抄 `mailbox_filter_button.dart`（那里有一份更详细的理由）：`MenuAnchor`
/// 会把面板包进 `IntrinsicWidth` + 自己的滚动容器，和面板里那个可滚的邮箱清单
/// 抢 `PrimaryScrollController`，`flutter test` 里会抛
/// `The PrimaryScrollController is attached to more than one ScrollPosition`。
class SenderField extends StatefulWidget {
  const SenderField({
    super.key,
    required this.sender,
    required this.groups,
    required this.onChanged,
  });

  /// 当前发件人；null = 选不出人 —— 一台可用邮箱都没有，或者入口实例这台没有。
  final SenderOption? sender;

  /// 可选发件人（跨实例）。为空且 [sender] 为 null 时说明「一台都没有」。
  final List<SenderGroup> groups;

  final ValueChanged<SenderOption> onChanged;

  @override
  State<SenderField> createState() => _SenderFieldState();
}

class _SenderFieldState extends State<SenderField> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _controller = OverlayPortalController();

  /// 触发行与面板必须同组，否则点面板本身会被当成「点外部」把面板关掉。
  static final Object _groupId = Object();

  /// 面板里能选的邮箱**总数**（跨所有实例、扁平之后）。
  int get _candidateCount =>
      widget.groups.fold<int>(0, (sum, g) => sum + g.mailboxes.length);

  /// 帧后关闭。
  ///
  /// **不能当帧直接 `hide()`**：`_OverlayPortalState.hide` 有一条
  /// `SchedulerBinding.instance.schedulerPhase != SchedulerPhase
  /// .persistentCallbacks` 的断言，而路由变化引起的重建正好发生在构建期间
  /// （实测会抛出来）。放到帧后就没有这个问题。
  ///
  /// `isShowing` 那道判断不是多余的：widget 已经被摘下来时 controller 是
  /// detached 的，那时 `hide()` 会撞上 `controller._attachTarget` 那条断言。
  void _close() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.isShowing) _controller.hide();
    });
  }

  void _pick(SenderOption option) {
    widget.onChanged(option);
    _controller.hide();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final current = widget.sender;

    // 上面压了新的一页（窄屏点开一封副本 / 弹出别的页）时把面板收掉。
    //
    // **不收会「复活」**：面板挂在 Navigator 那层 `Overlay` 上，push 之后它
    // 只是被那个不透明的路由**盖住**（offstage），并没有被拆掉；退回来时
    // 它又整整齐齐地出现在屏幕上，看起来像一张忘了关的浮层。实测：
    // `push 之后 PANEL=0`、`pop 回来之后 PANEL=1`。
    //
    // 这一行同时也是那句依赖的**唯一**来路（没有它就收不到信号），所以不能
    // 因为「读了不用」删掉它 —— 副作用才是它的用处。
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) _close();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            // 与 `RecipientField` 的 label 同一处对齐（输入框里的字比 label
            // 低 10px）。
            padding: const EdgeInsets.only(top: 10),
            child: Text(l10n.composeFrom),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: current == null
                // 没有可用邮箱 = 所有实例都没拿到邮箱列表、账号被禁、或站点
                // 关了发信。发送按钮同时也会是灰的（`sendDisabledReason`），
                // 这里说清原因。
                //
                // 红字文案仍按「候选空不空」分两种：候选整个空 = 真的一台都
                // 没有发信能力；候选非空却选不出人 = 这个实例的发件地址拿不到
                // （`composeSenderUnavailable`）。
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      widget.groups.isEmpty
                          ? l10n.composeNoMailbox
                          : l10n.composeSenderUnavailable,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  )
                : CompositedTransformTarget(
                    link: _link,
                    child: OverlayPortal(
                      controller: _controller,
                      overlayChildBuilder: (context) =>
                          CompositedTransformFollower(
                        link: _link,
                        // 触发行还没画过时不画面板（默认会把它摆在原点）。
                        showWhenUnlinked: false,
                        targetAnchor: Alignment.bottomLeft,
                        followerAnchor: Alignment.topLeft,
                        offset: const Offset(0, 4),
                        child: Align(
                          alignment: Alignment.topLeft,
                          // 面板**自己**带着尺寸上限（`SenderSheet` 里的那句
                          // `ConstrainedBox`）：follower 的 child 是按 overlay
                          // 那层的约束布局的，宽高夹在这里等于夹在「谁来量」
                          // 之前，`Material` 的圆角与阴影仍会照最小尺寸收缩，
                          // 但不该在两层各写一遍同一个数 —— 尺寸是面板自己的
                          // 事，锚点这一侧只管「贴在哪」。
                          child: TextFieldTapRegion(
                            child: TapRegion(
                              groupId: _groupId,
                              onTapOutside: (_) => _controller.hide(),
                              child: CallbackShortcuts(
                                bindings: <ShortcutActivator, VoidCallback>{
                                  const SingleActivator(
                                    LogicalKeyboardKey.escape,
                                  ): _controller.hide,
                                },
                                child: SenderSheet(
                                  groups: widget.groups,
                                  selected: current,
                                  onPick: _pick,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // **不套 `Focus(autofocus: true)`**（`mailbox_filter_button
                      // .dart` 有那层）：这里的焦点必须落进面板里的搜索框，而它
                      // 自己就是 `autofocus: true`。外面再来一层抢首帧焦点，
                      // 键盘就落不到输入框上，Esc / ↑↓ 全部失灵。
                      child: TapRegion(
                        groupId: _groupId,
                        child: _Trigger(
                          option: current,
                          // 只有一个**候选邮箱**时不给「展开」这条能力（见类注释）。
                          //
                          // 数的是**扁平后的邮箱总数**，不是组数：一台实例挂两个
                          // 邮箱（`me@a.example` / `fin@a.example`）时组数是 1，
                          // 可面板里明明有两行要选。按组数判会让这台实例的第二个
                          // 邮箱永远选不到 —— 而改造前的 `DropdownButton` 数的
                          // 是扁平后的候选，是能选的。
                          onTap: _candidateCount <= 1
                              ? null
                              : () => _controller.toggle(),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 触发行本体：主行 + 实例名小字 +（可选）下拉箭头。
class _Trigger extends StatelessWidget {
  const _Trigger({required this.option, this.onTap});

  final SenderOption option;

  /// null = 不展开（只有一个候选）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  option.profileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
          if (onTap != null)
            Icon(
              Icons.arrow_drop_down,
              key: const ValueKey('sender-chevron'),
              color: theme.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );

    if (onTap == null) return row;
    return InkWell(
      key: const ValueKey('sender-trigger'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: row,
    );
  }
}

/// 发件人面板：顶部搜索框 + 按实例分组的邮箱列表。
///
/// 过滤是**纯本地、即时**的：对邮箱地址、显示名、实例名做忽略大小写的子串
/// 匹配。某个组一个都没命中就整组隐藏（组头不单独留着）——
/// 一行孤零零的组头对用户没有任何用。
class SenderSheet extends StatefulWidget {
  const SenderSheet({
    super.key,
    required this.groups,
    required this.selected,
    required this.onPick,
  });

  final List<SenderGroup> groups;
  final SenderOption? selected;
  final ValueChanged<SenderOption> onPick;

  @override
  State<SenderSheet> createState() => _SenderSheetState();
}

class _SenderSheetState extends State<SenderSheet> {
  final TextEditingController _search = TextEditingController();

  /// 列表的滚动控制器。**建在这里、在 `dispose` 里释放** ——
  /// 放在 `build()` 里 `final scroller = ScrollController()` 会让每一帧都
  /// 新建一个（内存泄漏 + 滚动位置每帧丢掉），键盘走位的 `animateTo` 也就
  /// 永远作用在一个刚出生的 controller 上。
  final ScrollController _scroller = ScrollController();

  /// 过滤之后的高亮行下标（键盘 ↑/↓ 用）。
  ///
  /// **一开始就是 0（第一项）**：面板刚打开、还没按过方向键时视觉上第一行就是
  /// 亮的（用户知道回车会选谁），回车 / ↓ 也都在它上面。这同时是设计 §4.2 的
  /// 要求 —— 「过滤词一变高亮回到第一项」。
  ///
  /// **只在「搜索词变化」这一路下才是有效下标**：`_search.addListener` 会把它
  /// 复位成 0。可 `groups` 是**外面**传进来的（`state.senderGroups` ← 同步），
  /// 面板开着的时候它变小，那条监听器并不会跑 —— 下标就落在越界的位置上了。
  /// 所以 `_submit` 取项时仍要夹一道，那不是死代码。
  ///
  /// 曾经这里是 `-1`（「没有高亮」）。那个哨兵值有个测不到的坑：从 `-1` 按 ↑
  /// 会走 `_move` 的「前一项」分支、**绕到最后一项**，而 `0` 只会夹在第一项。
  int _highlight = 0;

  /// 高亮那一行的 key —— `_move` 靠它把**那一行本身**滚进视野（见 `_reveal`）。
  ///
  /// 一个 key 反复挪到当前高亮行上，而不是「每行一个 key」的表：高亮只有一行，
  /// 挪过去比维护一张要跟着过滤结果变的表省事。
  final GlobalKey _highlightKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() => _highlight = 0));
  }

  @override
  void dispose() {
    _search.dispose();
    _scroller.dispose();
    super.dispose();
  }

  /// 过滤后的分组。判据一句话：地址 / 显示名 / 实例名里有这个子串。
  List<SenderGroup> get _filtered {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.groups;
    final result = <SenderGroup>[];
    for (final group in widget.groups) {
      final profileHit =
          group.profile.displayName.toLowerCase().contains(query);
      final boxes = group.mailboxes
          .where(
            (m) =>
                profileHit ||
                m.email.toLowerCase().contains(query) ||
                m.name.toLowerCase().contains(query),
          )
          .toList(growable: false);
      if (boxes.isEmpty) continue;
      result.add(SenderGroup(profile: group.profile, mailboxes: boxes));
    }
    return result;
  }

  /// 过滤后的扁平列表（键盘走位用）—— 与面板里从上到下的视觉顺序一致。
  List<SenderOption> get _flat => <SenderOption>[
        for (final group in _filtered) ...group.options,
      ];

  void _move(int delta) {
    final flat = _flat;
    if (flat.isEmpty) return;
    setState(() {
      // 高亮下标在「搜索词变化」这一路下恒为有效值（监听器复位），所以「走到
      // 头」只要往两端夹；外部改小 `groups` 越界那种情况由这里一并夹回来。
      _highlight = (_highlight + delta).clamp(0, flat.length - 1);
    });
    // 走位之后把高亮行滚进视野 —— 键盘操作时用户看不见它在哪就没意义了。
    //
    // 不能按「下标 × 行高」估位置：列表里还夹着组头和顶部 4px 内边距，组数一多
    // 那个估算会越偏越多。列表现在是一口气建完的（见 `build` 里那段注释），
    // 高亮行恒在树里，直接 `ensureVisible` 把那一行本身滚进来即可。
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  /// 把高亮行滚进视野。
  ///
  /// 列表是**一口气建完**的（`SingleChildScrollView` + `Column`），高亮行恒在
  /// 树里，`ensureVisible` 总能拿到它的 context —— 从前那条「行还没 build，
  /// 退回按布局估偏移」的兜底分支已随之删除。用得了 `ensureVisible` 也因为
  /// 它**只在方向键之后跑**：那时布局早就有了；面板刚打开那一刻确实拿不到布局，
  /// 但那条路径根本不走这里。
  void _reveal() {
    if (!mounted || !_scroller.hasClients) return;
    final ctx = _highlightKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  /// 回车：选中高亮那一项。
  ///
  /// `_highlight` 是**搜索驱动**下才有效的下标（见字段注释）—— 外部改小
  /// `groups` 会把它留在越界的位置上，所以这里要夹一道，不能直接拿去索引。
  void _submit() {
    final flat = _flat;
    if (flat.isEmpty) return;
    widget.onPick(flat[_highlight.clamp(0, flat.length - 1)]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final filtered = _filtered;
    final flat = _flat;
    // 每一行在**过滤后的扁平表**里的下标。高亮靠它判：`flat` 与面板里从上到
    // 下的顺序一致，行自己不知道序号，所以先把「option → 下标」摊平。
    final indexOf = <SenderOption, int>{
      for (var i = 0; i < flat.length; i++) flat[i]: i,
    };

    return Material(
      key: const ValueKey('sender-sheet'),
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerHigh,
      // 尺寸上限放在**面板这一侧**：follower 的 child 是按 overlay 那层的约束
      // 布局的，宽高若只夹在锚点那边，量出来的仍是面板自己想要的尺寸 ——
      // 夹在这里才是真正生效的那一处（锚点侧因此不再重复写一遍）。
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.sizeOf(context).width - 32).clamp(200.0, 360.0),
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        // ↑/↓ 走位就挂在这一层（设计 §4.2 的既定机制）。它是本设计里唯一一处
        // 「机制对不对得实测」的地方：焦点在搜索框里，`EditableText` 自己也把
        // ↑/↓ 映成「上下挪光标」的 intent，两边都想要这两枚键。实测
        // （`test/compose_sender_picker_test.dart` 里那条 ↓ 用例）——
        // `CallbackShortcuts` 的 `Focus` 比 `EditableText` 内层那个更靠外，
        // 冒泡先经过它，**它在前面就把事件吃掉了**，方向键 intent 拿不到；
        // 把这条用例单独拿出来跑就是为它守夜。
        //
        // 回车**不走这里**（见 TextField.onSubmitted 那段注释）：真实桌面按一份
        // Enter 会同时来按键和 done 两条，键盘一并接就会提交两次。所以这一层
        // 只认方向键。
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: TextField(
                  key: const ValueKey('sender-search'),
                  controller: _search,
                  autofocus: true,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: l10n.composeSenderSearch,
                    border: const OutlineInputBorder(),
                  ),
                  // 回车**只走这一条路**（IME 的 done → onSubmitted）。
                  //
                  // 不要在输入框外面再套一层 `Focus(onKeyEvent:)` 去认
                  // `LogicalKeyboardKey.enter`：桌面上一次真实的 Enter 会同时
                  // 送来按键事件**和** IME 的 done action（flutter/flutter
                  // #119268，重复于 #109628），两条路都接就会 `_submit()`
                  // 两次 → `onPick` 两次 → `widget.onChanged` 两次，切换实例
                  // 时白刷两遍 `refreshQuota` / `_refreshSuggestions`。
                  //
                  // 键盘用例里 `sendKeyEvent(enter)` **测不到**这条路径：它只把
                  // 按键交给框架、不产生 done action（`EditableText.onSubmitted`
                  // 的文档原文如此）。所以用例用 `receiveAction(done)` 驱动。
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: filtered.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          l10n.composeSenderNoMatch,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                      )
                    // 列表**一口气建完**（`SingleChildScrollView` +
                    // `Column`，与 `suggest_panel.dart` 同一套手法），不用惰性
                    // 的 `ListView`。差别在这一处很要紧：惰性列表会把屏外的行
                    // dispose 掉，那条高亮行滑出视口后**根本不在树里**，
                    // `_reveal` 拿不到它的 context，只好退回按「组头高 + 行高」
                    // 估一个滚动偏移 —— 正因为要估得准，组头与行才被迫钉成定高
                    // （组头 36px 定高就是这么来的），而文本缩放到 1.75 就被裁。
                    // 改成一口气建完之后每行恒在树里，`ensureVisible` 一条路就
                    // 够，估算和定高一起失去存在理由。
                    : SingleChildScrollView(
                        controller: _scroller,
                        padding: const EdgeInsets.symmetric(
                          vertical: kSenderListPadding,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            for (final group in filtered) ...<Widget>[
                              _GroupHeader(name: group.profile.displayName),
                              for (final option in group.options)
                                _OptionRow(
                                  // key 挂在**高亮那一行**上，`_move` 靠它定位。
                                  // 判据用 indexOf（不是直接索引 `flat`）—— 外部
                                  // 改小 groups 时 _highlight 可能越界，直接索引
                                  // 会抛 RangeError。
                                  key: indexOf[option] == _highlight
                                      ? _highlightKey
                                      : null,
                                  option: option,
                                  selected: option == widget.selected,
                                  highlighted: indexOf[option] == _highlight,
                                  onTap: () => widget.onPick(option),
                                ),
                            ],
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 组头：实例显示名。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 高度**由内容自然决定**，不钉死。列表一口气建完之后没有任何东西会去量
    // 组头的盒高（那套按组头行高估滚动偏移的旧机制已经删掉），套定高只会让
    // 组头跟不上主题字号 / 文本缩放 —— 文本缩放到 1.75 时一行 `labelSmall`
    // 要 28px，定高 36px 的内容盒只剩 24px，字就被裁掉。自然高度永远装得下。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 一行邮箱。高亮（键盘走位）与选中（打勾）是**两件事** ——
/// 高亮是「回车会选它」，选中是「现在是它」。
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.option,
    required this.selected,
    required this.highlighted,
    required this.onTap,
  });

  final SenderOption option;
  final bool selected;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      // 高度是**最小高度**不是定高：默认缩放下盒高就是 [kSenderRowHeight]（高亮
      // 色带与勾号与从前一模一样），但文本放大到装不下那一行时让盒子长高 ——
      // 定高会在大字号下把字裁掉。
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kSenderRowHeight),
        child: Container(
          color: highlighted
              ? theme.colorScheme.surfaceContainerHighest
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (selected)
                Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一行的高度：默认文本缩放下固定 40px（见 `_OptionRow`，那里用的是最小高度，
/// 字号大到 40px 装不下时会自然长高）。
const double kSenderRowHeight = 40;

/// 列表顶部内边距（滚动视图 `padding` 的 `vertical`）。
const double kSenderListPadding = 4;
