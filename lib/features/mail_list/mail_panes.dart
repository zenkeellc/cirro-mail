import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/breakpoints.dart';
import '../../data/models/mail_ref.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/settings_providers.dart';
import '../mail_detail/mail_detail_screen.dart';

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
              ),
              Expanded(
                // 多选优先：正在选一批信时，右栏说的是那一批（用户需求 1），
                // 哪怕之前开着一封的正文。
                child: pane ??
                    (selected == null
                        ? const _NoSelectionPane()
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

/// 两栏之间那条可拖动的分隔条。
///
/// 视觉上是一条 1px 的竖线（与外壳 `app_shell.dart` 里那条同款），
/// 但命中区有 [Breakpoints.paneHandleWidth] 那么宽 —— 1px 几乎点不中。
class _PaneResizeHandle extends StatefulWidget {
  const _PaneResizeHandle({required this.onDrag, required this.onDragEnd});

  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

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
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: _hovering ? 3 : 1,
              color: _hovering ? scheme.primary : scheme.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 右栏还没有选中任何邮件时的样子。
///
/// **不默认选中第一封**：那样冷启动一进页面就等于替用户把最上面那封信
/// 标成了已读。宁可留一块空的。
class _NoSelectionPane extends StatelessWidget {
  const _NoSelectionPane();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.drafts_outlined,
            size: 40,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            AppLocalizations.of(context).pickMail,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 分栏形态下每栏顶部的条：左端是标题一类的控件，右端是动作按钮。
class PaneHeader extends StatelessWidget {
  const PaneHeader({super.key, required this.child, this.actions = const <Widget>[]});

  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: kPaneHeaderHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: <Widget>[
              Expanded(child: child),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}
