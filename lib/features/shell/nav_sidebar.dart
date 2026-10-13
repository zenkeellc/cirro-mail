import 'package:flutter/material.dart';

import '../../core/theme/breakpoints.dart';
import 'sidebar_counts.dart';

/// 宽屏左侧的一级导航栏。
///
/// 取代了原来的 `NavigationRail`。换掉的理由不是「不好看」，是三件事凑在一起
/// 让它既不省地方也不好看：
/// - `NavigationRail` 的 hover 高亮是**图标大小**的一块，四周还留着大段空白 ——
///   鼠标扫过时高亮的边界和菜单项的边界对不上，看着像没对齐；
/// - 它不提供「图标 + 角标 + 选中态」的自定义位（本仓库要的是发件箱那个
///   「0 也显示」的角标），选中态的配色由 rail 自己决定，改不动；
/// - 分组小标题需要 `labelType` 与组之间的留白，rail 的接口表达不了。
///
/// 现在每一项是整宽可点的一块（左右各留 8 边距、圆角 10），hover / 选中都是
/// 这**同一块**的底色变化，标签是**常驻文字**。
///
/// ## 为什么从 72px 加宽成 232
///
/// 这个宽度下侧栏是**唯一**的一级导航 —— 主屏那张 icon 网格只在窄屏出现
/// （见 `HomeMenuScreen` 的类注释）。原来 72px 里 7 个入口挤成一列图标，
/// 认字只能靠 hover 300ms 的 Tooltip，桌面上等于没有标签（spec §2.2）。
/// 宽度来源见 [Breakpoints.railWidth]。
class NavSidebar extends StatelessWidget {
  const NavSidebar({
    super.key,
    required this.leading,
    required this.items,
    this.footer,
  });

  /// 顶部常驻的那一格（实例名 + 同步状态按钮）。
  ///
  /// 单独一个参数而不是混进 [items]：它是**状态**不是导航目的地，
  /// 点了弹面板而不是切分支，混进列表会让「选中态」这个概念失去意义。
  final Widget leading;

  /// 分组后的导航项。`label` 为 null 的组不加小标题。
  final List<NavSidebarGroup> items;

  /// 常驻在**底部**的一格（设置）。
  ///
  /// 又一个单独的参数，理由与 [leading] 不同但是同一类：它必须脱离那个
  /// `Expanded(ListView)` —— 列表滚起来时它不能跟着滚走。塞进 [items] 就会
  /// 跟着滚，而「设置在哪儿」这件事本来就不该随着滚动变。
  ///
  /// 里面仍然放一个 [NavSidebarItem] 而不是一颗光秃秃的 `IconButton`：
  /// 这个侧栏当初从 72px 加宽到 232 的全部理由就是「桌面上没有常驻标签」，
  /// 在最下面那颗按钮上把标签去掉，等于把那条理由原地否掉。
  final Widget? footer;

  static const double width = Breakpoints.railWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      // 右缘那条 1px 分隔线收在侧栏自己这里画：外壳那层就不必再关心
      // 「侧栏和内容之间要有条线」，窄屏不走侧栏时也不会留下一条孤零零的
      // Divider。
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Material(
        color: scheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: leading,
            ),
            // 可滚动：窗口压低到刚好分栏时，7 个入口 + 3 个小组标题会超出
            // 高度。原来 7 个图标挤在 72px 里没有这个问题，加宽之后有了。
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 12),
                children: <Widget>[
                  for (final group in items) ...<Widget>[
                    if (group.label != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                        child: Text(
                          group.label!,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    for (final item in group.items) item,
                  ],
                ],
              ),
            ),
            // 上下各留一点：上面那道 6px 是它与最后一行导航项之间的呼吸，
            // 下面 10px 与顶部那一格的 10 对称。
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: footer!,
              ),
          ],
        ),
      ),
    );
  }
}

/// 侧栏里的一组。`label` 为 null 表示这组不加小标题（设置那一组用）。
///
/// [items] 是 `List<Widget>` 而不是 `List<NavSidebarItem>`：收件箱那一项下面
/// 会挂**缩进的邮箱下级菜单**（另一种控件，见 `sidebar_mailboxes.dart`），
/// 它得和一级项住在同一个组里，否则「收件箱 + 它的邮箱」会被组间留白劈开。
/// 现有的调用点写的都是 `NavSidebarItem`，放宽之后一个字都不用改。
class NavSidebarGroup {
  const NavSidebarGroup({required this.items, this.label});

  final String? label;
  final List<Widget> items;
}

/// 侧栏里的一项。整块可点、整块高亮，标签是**常驻文字**。
class NavSidebarItem extends StatefulWidget {
  const NavSidebarItem({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count = 0,
    this.alwaysShowCount = false,
    this.trailing,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 0 表示不显示角标 —— **除了发件箱**。那里 0 也要显示（一个灰色的 `0`），
  /// 因为它的用途是「让你知道还有这么个地方」（spec §2.4）。
  /// 这个区别由调用方用 [alwaysShowCount] 表达。
  final int count;

  /// 角标为 0 时也画出来。
  final bool alwaysShowCount;

  /// 数字右边再多一样东西。收件箱那一项用它放展开箭头（▼/▲）—— 那一项
  /// 本身就是邮箱下级菜单的组头，箭头是「这里还能展开」的唯一提示。
  ///
  /// 与 [count] 分开传而不是塞进角标那个位置：两项都有（收件箱既有未读数
  /// 又可展开），挤在一个槽里就得让调用方自己拼一行 `Row`。
  final Widget? trailing;

  @override
  State<NavSidebarItem> createState() => _NavSidebarItemState();
}

class _NavSidebarItemState extends State<NavSidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selected;
    // 选中态优先：一个已经选中的项在鼠标扫过时不该变成另一种「更像选中」的样子。
    final background = selected
        ? scheme.secondaryContainer
        : (_hovered
            ? scheme.onSurfaceVariant.withValues(alpha: 0.08)
            : Colors.transparent);
    final foreground =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    final showCount = widget.count > 0 || widget.alwaysShowCount;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                Icon(selected ? widget.selectedIcon : widget.icon,
                    size: 20, color: foreground),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: foreground,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                  ),
                ),
                if (showCount)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: SidebarCountPill(
                      text: formatSidebarCount(widget.count),
                      color: foreground,
                    ),
                  ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 侧栏右侧那个小数字。
///
/// 收**已经排版好的文案**而不是 `int`：侧栏这几格现在装的不都是「一个数」
/// —— 邮箱行与实例行装的是「未读 / 总数」整段（`3/12`）。收 `int` 的话
/// 那几格得自己 `Text`，而它们必须与一级项那颗数字**长得一模一样**（同一套
/// `labelSmall` + `w600` + 颜色），两份实现立刻会走散。
/// 单纯一个数的调用方用 [formatSidebarCount] 打折（`99+` 那套也共用它）。
///
/// 0 也画（见 [NavSidebarItem.alwaysShowCount]）—— 抑制由调用方决定。
///
/// 公开（原来叫 `_CountPill`）是因为**邮箱下级菜单也要它**。
class SidebarCountPill extends StatelessWidget {
  const SidebarCountPill({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
    );
  }
}

/// 带数量角标的图标。
///
/// 收 `IconData` 而不是 `Widget`：`Badge` 的 `child` 需要一层 `Icon`，
/// 让调用方每次都写 `Icon(...)` 只是噪声。
///
/// 底部导航（`app_shell.dart` 的窄屏分支）仍在用 —— 侧栏这一改不走它了。
class BadgedIcon extends StatelessWidget {
  const BadgedIcon({super.key, required this.icon, required this.count, this.color});

  final IconData icon;
  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final child = Icon(icon, color: color);
    if (count <= 0) return child;
    return Badge(
      label: Text(formatSidebarCount(count)),
      child: child,
    );
  }
}
