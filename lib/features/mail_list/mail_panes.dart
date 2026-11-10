import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/breakpoints.dart';
import '../../data/models/mail_ref.dart';
import '../../providers/settings_providers.dart';
import '../mail_detail/mail_detail_screen.dart';
import 'no_selection_pane.dart';

/// 分栏形态下每栏顶部条的高度。
///
/// 两栏的头必须**一样高**，否则中间那条分隔条会对不上，一眼就看出是两块
/// 拼起来的。左右两侧都不再各自撑一个 `AppBar`，就是为了一起用这个数。
///
/// 60（原来是 52）：收件箱那一栏的头多了一颗「已选 x 个邮箱」按钮，整块
/// 从一行变两行（`MailListScreen._ListHeader`：标题 + 按钮），52 装不下 ——
/// 实测会 `RenderFlex overflowed by 8.0 pixels`（`titleMedium` 行高 24 +
/// 按钮 36 = 60）。
///
/// 窄屏 `AppBar` 那一边的 `toolbarHeight` 是 72 而不是这个数：那里上下各要
/// 留 6 的余量（`AppBar` 自己不带纵向内边距），而这里靠的是一分不差地填满。
/// 两个数不同是**有意的**，不是忘了同步。
const double kPaneHeaderHeight = 60;

/// 「栏顶」这一块底：高 [kPaneHeaderHeight] + 底边一条 1px 的 [BorderSide]。
///
/// [PaneHeader]（列表栏 / 阅读区各自的头）就是「这块底 + 一行内容」。
///
/// 另外**两处只借它的底边那条线**：侧栏顶格（那条横线要从窗口左缘一直连到
/// 右缘，侧栏那一段不能例外）与两栏之间的拖动条（它占的 6px 不属于任何一栏，
/// 两栏的头都只画到栏边为止 —— 这就是用户看到的那个「豁口」）。
///
/// 三处共用同一个部件，而不是各自写一遍 `height: 60` + `outlineVariant.alpha
/// 0.5`：那条线现在要跨四个部件才连成一条，高度差 1px 或色差一档，它在拼接处
/// 就又「断」了一次。
class PaneHeaderBand extends StatelessWidget {
  const PaneHeaderBand({super.key, this.child});

  /// 头里的内容；拖动条那条只画线，传 null。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: kPaneHeaderHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: child,
      ),
    );
  }
}

/// 宽屏分栏形态的内容区：左栏列表（可拖动调宽）+ 右栏阅读区。
///
/// 由三个列表页共用，各自把「自己的列表栏」作为 [list] 传进来（列表栏里
/// 含它自己的头与 `MailListView`）—— 三个页面的左栏内容差别很大（聚合有
/// 实例筛选条，星标有实例 Tab，收件箱有邮箱切换器），与其在这里开一堆
/// 开关，不如让调用方自己拼。
///
/// **为什么不是 `StatefulShellRoute.navigatorContainerBuilder`**：
/// `app_shell.dart` 的注释里给的是那条路（把分支 Navigator 摆成 `Row`），
/// 但它要求**四个分支全部**参与排版，等于重写 `indexedStack` 的保活语义
/// （切分支时另外三枝得 offstage 而不是进 `Row`）。这条路只需要改三个列表页，
/// 风险和改动面都小一个数量级。详见 `Routes.mailOf` 里对选中态为什么是
/// 查询参数的说明。
class MailPanes extends ConsumerStatefulWidget {
  const MailPanes({
    super.key,
    required this.list,
    required this.selected,
    required this.onClosed,
    this.pane,
  });

  /// 左栏：列表页自己拼好的那一整块（头 + 列表）。
  final Widget list;

  /// 右栏要显示的邮件；null 显示空态。
  final MailRef? selected;

  /// 关掉右栏（回到空态）。
  final VoidCallback onClosed;

  /// 右栏改渲染它（多选面板），而不是那一封的正文。
  ///
  /// 由列表页在「本屏正在多选」时才传（它自己算 scope，见
  /// `selectionScopeForQuery`）—— 这里**不自己读多选状态**：右栏要显示什么
  /// 是这一屏的判断，而不是分栏容器的。null（默认）= 今天的行为，逐字不变。
  final Widget? pane;

  @override
  ConsumerState<MailPanes> createState() => _MailPanesState();
}

class _MailPanesState extends ConsumerState<MailPanes> {
  /// 用户想要的宽度（未夹取）。用 State 而不是直接读 provider：
  /// 拖动过程中每帧都要改它，而落盘只在松手时发生一次。
  late double _wanted = ref.read(paneListWidthProvider);

  /// 最近一次布局拿到的内容区宽度。拖动回调里拿不到 constraints，
  /// 只能在这儿存一份 —— 夹取必须用内容区宽度，不是窗口宽度。
  double _available = 0;

  @override
  Widget build(BuildContext context) {
    // 窄屏时 `Scaffold` 靠 AppBar 替 body 去掉顶部内边距；这里没有 AppBar，
    // 得自己兜住（macOS 标题栏 / iPad 状态栏 / 安卓平板挖孔）。
    return SafeArea(
      top: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _available = constraints.maxWidth;
          final listWidth = Breakpoints.clampListWidth(_wanted, _available);
          final selected = widget.selected;
          final pane = widget.pane;

          return Row(
            children: <Widget>[
              SizedBox(width: listWidth, child: widget.list),
              _PaneResizeHandle(
                onDrag: _onDrag,
                onDragEnd: _onDragEnd,
                // 右栏顶上有没有那条头：阅读区（`MailDetailScreen` 内嵌形态）
                // 有，多选面板与空态都没有。没有头的那一侧不画这 6px ——
                // 画了就是一小段**悬在空栏里**的线，比缺口更像 bug。
                showHeaderBorder: pane == null && selected != null,
              ),
              Expanded(
                // 多选优先：正在选一批信时，右栏说的是那一批（用户需求 1），
                // 哪怕之前开着一封的正文。
                child: pane ??
                    (selected == null
                        ? const NoSelectionPane()
                        : MailDetailScreen(
                            // 换一封邮件就重挂：既让 `_openOnce` 重新跑
                            // （否则第二封信永远不会被标已读、也不会补拉
                            // 正文），也把正文滚动位置归零 —— 这正是用户
                            // 换一封信时预期的。
                            key: ValueKey<String>(
                              '${selected.profileId}#${selected.emailId}',
                            ),
                            profileId: selected.profileId,
                            emailId: selected.emailId,
                            embedded: true,
                            onClose: widget.onClosed,
                          )),
              ),
            ],
          );
        },
      ),
    );
  }

  void _onDrag(double dx) {
    if (_available <= 0) return;
    final next = Breakpoints.clampListWidth(_wanted + dx, _available);
    if (next == _wanted) return;
    setState(() => _wanted = next);
  }

  void _onDragEnd() {
    // 只在松手时落盘。每帧写一次 SharedPreferences 没有意义。
    ref.read(paneListWidthProvider.notifier).set(_wanted);
  }
}

/// 中缝那条竖线的宽度。
const double kPaneDividerWidth = 1;

/// 两栏之间那条可拖动的分隔条。
///
/// 视觉上是一条 [kPaneDividerWidth] 的竖线（与外壳 `app_shell.dart` 里那条
/// 同款），但命中区有 [Breakpoints.paneHandleWidth] 那么宽 —— 1px 几乎点不中。
///
/// **竖线画在拖动条的左缘，不是正中。** 它同时是**列表栏的右边界**：行的
/// 选中 / 未读底色必须一直铺到它上面。画在正中时，行的底色到竖线之间空出
/// 半个拖动条（3px）的一道光 —— 一列里凡是带底色的行（选中的那封、未读的
/// 那几封）右边都缺一角，用户报的「列表要填充满这条缝」就是它。挪到左缘
/// 之后，那 3px 落在阅读区一侧，而阅读区那一侧通体是 `surface`，看不出来。
///
/// 代价是拖动的手感往右偏了 3px（命中区还是这 6px），可以忽略：光标进到
/// 这 6px 里就是 `resizeColumn`，用户不会去数线在哪一像素上。
///
/// 它顺带是那条**横线**的最后一截：两栏的头各自只画到自己栏边为止，中间这
/// [Breakpoints.paneHandleWidth] 谁也不画 —— 于是那条横线在两栏之间空出一截
/// （用户报的「线断开」就是这个，截图里红框框着的就是那个豁口）。所以这里
/// 在头的高度上补一段同色同高的线。
///
/// 补多长取决于右栏顶上有没有头：
/// - **有**（阅读区）：补满整个宽度，横线于是从侧栏一路连到窗口右缘；
/// - **没有**（空态 / 多选面板）：只补到左缘那条竖线上为止（就是它自己那
///   1px）。补满会让线伸进空栏里变成一小段悬空的线；不补又会在角上缺一格。
class _PaneResizeHandle extends StatefulWidget {
  const _PaneResizeHandle({
    required this.onDrag,
    required this.onDragEnd,
    required this.showHeaderBorder,
  });

  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  /// 右栏顶上有没有那条头（阅读区有；空态与多选面板没有）。
  final bool showHeaderBorder;

  @override
  State<_PaneResizeHandle> createState() => _PaneResizeHandleState();
}

class _PaneResizeHandleState extends State<_PaneResizeHandle> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        onHorizontalDragEnd: (_) => widget.onDragEnd(),
        child: SizedBox(
          width: Breakpoints.paneHandleWidth,
          child: Stack(
            // 竖线要**贯穿整个高度**（含头部这一段），所以靠在 `Align` 里
            // 铺满；头部那截横线是叠在上面的 `Positioned`。
            fit: StackFit.expand,
            children: <Widget>[
              Positioned(
                top: 0,
                left: 0,
                // 竖线在左缘（见类注释），所以「到竖线上」= 它自己那 1px。
                width: widget.showHeaderBorder
                    ? Breakpoints.paneHandleWidth
                    : kPaneDividerWidth,
                child: const PaneHeaderBand(
                  key: ValueKey<String>('paneHandleHeaderBand'),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: AnimatedContainer(
                  // 贴左缘：列表栏的行底色与它之间不再留那道白缝。
                  key: const ValueKey<String>('paneHandleDivider'),
                  duration: const Duration(milliseconds: 120),
                  width: _hovering ? 3 : kPaneDividerWidth,
                  color: _hovering ? scheme.primary : scheme.outlineVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分栏形态下每栏顶部的条：左端是标题一类的控件，右端是动作按钮。
///
/// 高度与底边那条线都来自 [PaneHeaderBand] —— 侧栏顶格与两栏之间的拖动条也要
/// 跟它对上（见那边的注释）。
class PaneHeader extends StatelessWidget {
  const PaneHeader({super.key, required this.child, this.actions = const <Widget>[]});

  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return PaneHeaderBand(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: <Widget>[
            Expanded(child: child),
            ...actions,
          ],
        ),
      ),
    );
  }
}
