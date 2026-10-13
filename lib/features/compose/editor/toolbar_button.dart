import 'package:flutter/material.dart';

/// 工具栏按钮与条带的**几何常量**，两条工具栏共用。
///
/// 为什么要独立成一个文件：写信页现在有**两条**格式工具栏 —— 正文上方常驻的
/// 那条（`ComposeToolbar`）与选中文字时浮出的那条（`EditorToolbar`）。它们的
/// 按钮必须长得一模一样，否则同一屏上会出现两种按钮尺寸。把尺寸收在这里，
/// 「两条一样」才有唯一出处；各自存一份的话，改了其中一边就会出现「浮动那条
/// 32px、常驻那条 40px」这种只有肉眼能发现的不一致。
///
/// 这几个数字都是**被坑出来的**，不是随手取的：
///
/// - [_buttonSize] 19×28：默认的 40px `IconButton` 会把选中态工具栏撑到
///   ~636px，任何 ≤636px 的视口上右边几个按钮渲染在屏幕外、
///   `RenderStack.hitTest` 拒收框外的点 —— 表现是「按钮找得到、点不动」
///   （F-7）。19 宽是「15 个按钮 + 4 条分隔线在 320px 里刚好排得下」。
/// - [kMailToolbarHeight] 32 = `2 * 上下内边距(2) + 按钮高(28)`。
///   **写死**是为了「先算出位置再渲染」：用实测高度的话第一帧会画在错位置、
///   量完再挪一下（闪一下）。`test/editor_toolbar_test.dart` 里有一条断言把
///   「实渲染高度」钉在这个常量上 —— 改了按钮高度或内边距必须同步改这里，
///   否则那条测试会红，这正是它存在的意义。
const Size _buttonSize = Size(19, 28);

/// 条带内边距（左右 4、上下 2）。
const EdgeInsets kMailToolbarPadding = EdgeInsets.symmetric(horizontal: 4, vertical: 2);

/// 一条工具栏的高度。见文件头 [kMailToolbarHeight] 的说明。
const double kMailToolbarHeight = 2 * 2 + 28;

/// 工具栏里一个按钮。
///
/// 尺寸**钉死**成 [_buttonSize]（见文件头的 F-7 说明）：`constraints:
/// BoxConstraints()` 清掉 `IconButton` 默认的 48 最小尺寸，再靠外层 `SizedBox`
/// 定死宽高。
class ToolbarButton extends StatelessWidget {
  const ToolbarButton({
    super.key,
    required this.icon,
    required this.active,
    required this.onTap,
    this.enabled = true,
    this.tooltip,
  });

  final IconData icon;

  /// 当前选区/光标处这个格式开着没有（决定按钮是否高亮）。
  final bool active;

  final VoidCallback onTap;

  /// 灰掉（点了不响应）。撤销/重做要看 `controller.hasUndo` / `hasRedo`。
  final bool enabled;

  final String? tooltip;

  /// 供测试点它用（`tester.tap(find.byKey(ValueKey('ct-bold')))`）。
  ///
  /// **由调用方挂在这个 widget 自己身上**（`ToolbarButton(key: …)`），不要往
  /// 里面的 `IconButton` 再传一次 `key` —— 同一个 `ValueKey` 出现在同一棵子树
  /// 的两个 widget 上，`find.byKey` 会一次命中两个，`findsOneWidget` 当场就红。
  @override
  Widget build(BuildContext context) {
    // 按钮**自己**声明成输入框的点击区域（`TextFieldTapRegion` 默认就在
    // `EditableText` 那个 group 里，与编辑器那层同组）。少了这一层，点按钮会
    // 先让编辑器失焦：选区高亮消失、浮出那条工具栏消失，接着这一下
    // `formatSelection` 作用在一个已经不成立的选区上 —— 用户看到的是
    // 「点了没反应」。`editor_context_menu.dart` 里那个自建编辑菜单踩过同一个
    // 坑，解法就是这个 `TextFieldTapRegion`。放在**按钮自己身上**而不是某条
    // 工具栏上，是为了两条工具栏都自动具备这个性质、且都只盖住按钮本身
    // （常驻那条整条横贯屏幕，整条算「输入框内部」的话，点它右边的空白区
    // 也会被当成长按拖选）。
    final button = TextFieldTapRegion(
      child: SizedBox(
        width: _buttonSize.width,
        height: _buttonSize.height,
        child: IconButton(
          icon: Icon(icon, size: 15),
          onPressed: enabled ? onTap : null,
          isSelected: active,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// 两条按钮之间的竖线。
class ToolbarSeparator extends StatelessWidget {
  const ToolbarSeparator({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: SizedBox(
          height: 16,
          child: VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
        ),
      );
}

/// 工具栏里下拉按钮的宽度。段落样式那个要放得下「H1」，字号那个要放得下
/// 「特大」；图标按钮仍是 19 宽。菜单按钮的 widget 在 `style_dropdown.dart`。
const double kMailToolbarMenuWidth = 40;
