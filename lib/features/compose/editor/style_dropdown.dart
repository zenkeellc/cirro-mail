import 'package:flutter/material.dart';

import 'toolbar_button.dart';

/// 工具栏里一个**下拉**的按钮（外观与 [ToolbarButton] 同尺寸）。
///
/// `label` 非空时按钮上显示文字（段落样式那个显示当前是「正文」还是「H1」），
/// 为空时只画图标。两种都占 [kMailToolbarMenuWidth] × `kMailToolbarHeight - 4`，
/// 所以下拉与平铺按钮排在一行里不会高低不齐。
class ToolbarMenuButton extends StatelessWidget {
  const ToolbarMenuButton({
    super.key,
    this.icon,
    this.label,
    required this.tooltip,
    this.active = false,
  }) : assert(icon != null || label != null, '图标与文字至少给一个');

  final IconData? icon;
  final String? label;
  final String tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: kMailToolbarMenuWidth,
        height: kMailToolbarHeight - 2 * 2,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (icon != null) Icon(icon, size: 15, color: colour),
            if (icon != null && label != null) const SizedBox(width: 2),
            if (label != null)
              Flexible(
                child: Text(
                  label!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: colour),
                ),
              ),
            Icon(Icons.arrow_drop_down, size: 12, color: colour),
          ],
        ),
      ),
    );
  }
}

/// 一个**保住编辑器焦点的下拉**。条目由调用方给 `menuChildren`。
///
/// ## 为什么触发按钮要包 [TextFieldTapRegion]
///
/// flutter_quill 在编辑器外层包了一圈 `TextFieldTapRegion`
/// （`raw_editor_state.dart`），默认 `onTapOutsideEnabled` 为真 ——
/// **点到编辑器外面就会 `unfocus()`**，选区随之塌掉，接着那一下
/// `formatSelection` 作用在一个已经不成立的选区上（用户看到的是「点了没反应」）。
///
/// 弹出项挂在**应用级 Overlay** 上，落在那个 region 之外，所以
/// [MenuAnchor] 的**触发按钮**必须自己包一层，让「点它」算作 region 内部的点击。
/// （弹出项本身不用包 —— 点条目那一下的焦点归 [MenuItemButton] 管，但**它只顾得上
/// 把菜单关干净、把 `onPressed` 排到焦点还原之后**，编辑器拿不拿得回焦点仍是
/// 调用方的事，见 [ToolbarMenuItem]。）
class ToolbarMenu extends StatelessWidget {
  const ToolbarMenu({
    super.key,
    required this.button,
    required this.menuChildren,
    this.onOpen,
    this.onClose,
  });

  /// 关上时显示的那个按钮（用 [ToolbarMenuButton]）。
  final Widget button;
  final List<Widget> menuChildren;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
        child: MenuAnchor(
          menuChildren: menuChildren,
          onOpen: onOpen,
          onClose: onClose,
          builder: (context, controller, child) => InkWell(
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: button,
          ),
        ),
      );
}

/// 下拉里的一个色块。包 [TextFieldTapRegion] 是为了 **桌面 / 移动端浏览器**
/// 那条 pointer-down 路径不把它当「点到编辑器外面」而闪一下 `unfocus`
/// （quill 只对鼠标这么做，见 [ToolbarMenu] 的注释）。**没有用例钉住这一层** ——
/// 测试默认 `android`，触摸那一支本来就不 `unfocus`，拿它当回归护栏是空的
/// （`ToolbarMenuItem` 那层也是同一个处境，见 `compose_toolbar_menus_test.dart`）。
class ToolbarSwatch extends StatelessWidget {
  const ToolbarSwatch({super.key, required this.color, required this.onTap});

  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color,
              border:
                  Border.all(color: Theme.of(context).dividerColor, width: 0.5),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      );
}

/// 菜单里一个条目。**点完菜单自己会关**。
///
/// [MenuItemButton] 自己会把 `onPressed` 推到下一帧、在焦点还原之后才调
/// （`menu_anchor.dart:1308`），所以「格式作用在正确的选区上」这一半它包了。
/// **把焦点主动要回编辑器**是**调用方**的事 —— 菜单关掉之后焦点往往落在触发它
/// 的那个按钮上，用户接着敲字会发现打不进去；每一条的 `onPressed` 结尾都要调一次
/// 去要回焦点的那个回调（`ComposeToolbar._back`）。
class ToolbarMenuItem extends StatelessWidget {
  const ToolbarMenuItem({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.active = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
        child: MenuItemButton(
          leadingIcon: icon == null
              ? null
              : Icon(icon, size: 16, color: active ? Theme.of(context).colorScheme.primary : null),
          onPressed: onPressed,
          child: Text(label),
        ),
      );
}
