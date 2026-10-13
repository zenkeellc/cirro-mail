import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

import 'toolbar_button.dart';

/// 选区浮动工具栏：**选中文字时冒出来**的那一条。
///
/// 为什么自己摆位置而不用 flutter_quill 的 `contextMenuBuilder`：
/// 那条路走的是 `EditorTextSelectionOverlay`，只在**手势触发的**选区上出菜单
/// （`delegate.dart:184/209/277/302/356` 各处 `editor!.showToolbar()`），
/// 而我们要的「选中即出现」还包括键盘选、程序选中、以及**没有手势**的那些
/// 路径。自己算位置覆盖得全，而且位置算法是纯函数，能单测。
///
/// 摆位置的算法在 [toolbarAnchor] 里，**与 widget 分开** —— 那是整个工具栏
/// 唯一会算错的地方（工具栏跑到屏幕外、或者盖住选区）。
///
/// ## 与常驻那条的分工（`ComposeToolbar`）
///
/// 正文上方那条**一直在**，管「随时可点」（尤其是空行上「想加粗还没打的字」）；
/// 这一条只在**选中文字**时浮出，管「选中之后就近操作」—— 手已经停在选区上，
/// 不必把目光挪回页面顶部的工具栏。两条并存、按钮尺寸共用
/// （`toolbar_button.dart`），key 前缀分开（这里 `tb-`、那条 `ct-`）。
///
/// 因此**这一条身上的按钮不必与常驻那条一一对齐**：它的存在价值是「近」，
/// 不是「全」。像撤销/重做、链接这类「偶尔用一次、位置固定在顶上也无所谓」的
/// 条目只放常驻那条，免得浮出的小气泡被撑成一条长带、反而盖住正文。
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.controller,
    required this.editorKey,
    required this.viewportKey,
    this.onAiRewrite,
    this.suppressed = false,
  });

  final q.QuillController controller;

  /// 编辑器内部状态的 key（`config.editorKey`）—— 用来从选区算出屏幕坐标。
  final GlobalKey<q.EditorState> editorKey;

  /// 工具栏要定位在**哪个盒子**里。通常是正文区外层的 `Stack`。
  final GlobalKey viewportKey;

  /// 点「AI 改写」时回调（由页面打开改写面板）。
  final VoidCallback? onAiRewrite;

  /// 让位：为 true 时一条都不画。
  ///
  /// 用于**编辑菜单（右击/长按弹出的剪切复制粘贴）开着的时候** —— 那条菜单
  /// 锚在选区上，与本工具栏锚在同一个小方块里，两个气泡会叠着出现。菜单是
  /// 用户刚刚主动点出来的，优先级更高，所以由工具栏让位（见
  /// `editor_context_menu.dart` 与 `MailQuillEditor` 的 `_contextMenuOpen`）。
  ///
  /// 为什么不是「菜单出现时把选区清掉」：清掉选区就没得复制了 —— 那条菜单
  /// 的每一项都作用在这个选区上。
  final bool suppressed;

  /// 选区一变就得重算位置。
  ///
  /// **必须订阅 controller**：`build` 里读的是 `controller.selection`，而选区的
  /// 变化（键盘选、程序选中、点一下放开）**不一定**会让上层页面重建。不订阅的话
  /// 工具栏要么不出现，要么停在上一处选区的旧位置上。`_Bar` 里的按钮高亮同理。
  @override
  Widget build(BuildContext context) {
    // 让位（见 [suppressed]）：编辑菜单开着时一条都不画。
    if (suppressed) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final selection = controller.selection;
        if (!selection.isValid || selection.isCollapsed) {
          return const SizedBox.shrink();
        }
        // **宽度要按视口夹**（F-7）：早先只把名义的 420 传给位置算法，
        // 而没有任何地方限制工具栏自身的宽度，于是它按内容撑到 ~636px ——
        // 任何 ≤636px 的视口上，右边的按钮渲染在屏幕外，`tester.tap` /
        // 真手指都打不中（RenderStack.hitTest 拒框外的点）。
        final viewportBox = viewportKey.currentContext?.findRenderObject();
        final viewportWidth = viewportBox is RenderBox && viewportBox.hasSize
            ? viewportBox.size.width
            : null;
        final width = viewportWidth == null
            ? _maxToolbarWidth
            : viewportWidth < _maxToolbarWidth
                ? viewportWidth
                : _maxToolbarWidth;
        final rect = toolbarAnchor(
          editorState: editorKey.currentState,
          viewportKey: viewportKey,
          selection: selection,
          toolbarWidth: width,
          toolbarHeight: _toolbarHeight,
        );
        if (rect == null) return const SizedBox.shrink();

        return Positioned(
          left: rect.left,
          top: rect.top,
          child: SizedBox(
            width: width,
            // 窄到放不下时横向滚动：按钮**一个都不丢**（滚一下就能点），
            // 代价是极窄的视口上要划一下才够得着最右边的「AI」。
            // 相对地「收缩」方案（减图标/密度）会把可点区域压到触控下限以下，
            // 对手机不友好，所以选滚动。
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _Bar(
                controller: controller,
                onAiRewrite: onAiRewrite,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 工具栏高度：一行图标 + 内边距。写死是为了**先**算出位置再渲染 ——
  /// 用实测高度的话第一帧会闪一下（先画在错位置，量完再挪）。
  ///
  /// **与按钮尺寸耦合**，而那两个常量现在住在 [toolbar_button.dart] 里，
  /// 因为它同时被常驻的那条工具栏（`ComposeToolbar`）用着。改了按钮高度必须
  /// 同步改那里（有测试钉住实渲染高度 == 这个常量）。
  static const double _toolbarHeight = kMailToolbarHeight;
}

/// 工具栏自身宽度的上限。它既是布局宽度、又是传给 [toolbarAnchor] 用来算
/// 左坐标的宽度 —— `build` 里会先按视口宽度夹小，真正参与布局的是夹过之后的
/// 宽度。单行全部按钮实测约 516px（20px 按钮 + 分隔线），640 留足余量。
const double _maxToolbarWidth = 640;

/// 工具栏摆哪儿。**返回 null 表示不摆**（拿不到几何信息、或选区在视野外）。
///
/// 规则：
/// - 摆在选区**上方**，中间留 [_gap] 的空隙；
/// - 上方放不下（离顶太近）就翻到选区**下方** —— 邮件第一行就选中的情况很常见；
/// - 左右夹在视口内（选区靠右时工具栏不能溢出，否则右边几个按钮点不到）。
///
/// 坐标系是**相对 viewportKey 那个盒子**的，所以两边都要 `localToGlobal` 再相减，
/// 只用编辑器自身的坐标会在页面有滚动偏移时错位。
@visibleForTesting
Rect? toolbarAnchor({
  required q.EditorState? editorState,
  required GlobalKey viewportKey,
  required TextSelection selection,
  required double toolbarWidth,
  required double toolbarHeight,
}) {
  final render = editorState?.renderEditor;
  final viewportBox = viewportKey.currentContext?.findRenderObject();
  if (render == null || viewportBox is! RenderBox) return null;
  if (!render.hasSize || !viewportBox.hasSize) return null;

  // `getEndpointsForSelection` 在**选区两端落不到已渲染的行**时会抛
  // （`editor.dart:884` 的 `baseChild != null` 断言）。这不是理论情况：
  // 对当前行套上块属性（引用/对齐）之后，行结构重建、选区的端点可能暂时
  // 匹配不到子节点，而工具栏正好是在这次重建里被重画的（F-7 用例实测）。
  // 这里是**渲染路径**，抛一次就是红屏 —— 拿不到几何就当「不摆工具栏」，
  // 等下一帧选区稳定了自然会再出现。
  final List<TextSelectionPoint> endpoints;
  try {
    endpoints = render.getEndpointsForSelection(selection);
  } on Object {
    return null;
  }
  if (endpoints.isEmpty) return null;

  // 选区的水平中点与顶边（编辑器局部坐标 → 全局 → viewport 局部）。
  const anchorOffset = Offset.zero;
  final editorOrigin = render.localToGlobal(anchorOffset);
  final viewportOrigin = viewportBox.localToGlobal(anchorOffset);

  var left = endpoints.first.point.dx;
  var right = endpoints.last.point.dx;
  if (right < left) {
    final swap = left;
    left = right;
    right = swap;
  }
  final centreX = (left + right) / 2 + editorOrigin.dx - viewportOrigin.dx;
  final selectionTop =
      endpoints.first.point.dy + editorOrigin.dy - viewportOrigin.dy;

  final viewportWidth = viewportBox.size.width;
  final half = toolbarWidth / 2;
  final clampedCentre =
      centreX.clamp(half, (viewportWidth - half).clamp(half, double.infinity));
  final x = clampedCentre - half;

  final above = selectionTop - toolbarHeight - _gap;
  final y = above >= 0 ? above : selectionTop + _lineHeight + _gap;
  return Rect.fromLTWH(x, y, toolbarWidth, toolbarHeight);
}

/// 工具栏与选区之间留的空隙。
const double _gap = 8;

/// 翻到下方时，要让开一行的高度（选区底边）。
const double _lineHeight = 20;

class _Bar extends StatelessWidget {
  const _Bar({required this.controller, this.onAiRewrite});

  final q.QuillController controller;
  final VoidCallback? onAiRewrite;

  /// 当前选区在这些格式上的状态（决定按钮是否高亮）。
  ///
  /// 只看**选区起点**的样式就够：多段选中时各段样式可能不同，全选高亮反而
  /// 误导。这是编辑器里的通行做法。
  q.Style get _style {
    final selection = controller.selection;
    final index = selection.start.clamp(0, controller.document.length - 1);
    return controller.document.collectStyle(index, 0);
  }

  bool _has(q.Attribute<Object?> attr) => _style.attributes.containsKey(attr.key);

  void _toggle(q.Attribute<Object?> attr) {
    controller.formatSelection(
      _has(attr) ? q.Attribute.clone(attr, null) : attr,
    );
  }

  /// 一个按钮。尺寸与内边距都在 [ToolbarButton] 里（与常驻工具栏共用）。
  ///
  /// 原来这里有一个私有的 `_button` 包装 `SizedBox` + `IconButton`，已经提到
  /// [toolbar_button.dart] —— 常驻那条要长得一模一样，各自存一份的话迟早
  /// 会出现「浮动那条 19px、常驻那条 24px」这种只有肉眼能发现的不一致。
  Widget _button({
    required String key,
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
    String? tooltip,
  }) =>
      ToolbarButton(
        key: ValueKey(key),
        icon: icon,
        active: active,
        onTap: onTap,
        tooltip: tooltip,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: kMailToolbarPadding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _button(key: 'tb-bold', icon: Icons.format_bold, active: _has(q.Attribute.bold), onTap: () => _toggle(q.Attribute.bold)),
            _button(key: 'tb-italic', icon: Icons.format_italic, active: _has(q.Attribute.italic), onTap: () => _toggle(q.Attribute.italic)),
            _button(key: 'tb-underline', icon: Icons.format_underline, active: _has(q.Attribute.underline), onTap: () => _toggle(q.Attribute.underline)),
            _button(key: 'tb-strike', icon: Icons.format_strikethrough, active: _has(q.Attribute.strikeThrough), onTap: () => _toggle(q.Attribute.strikeThrough)),
            _button(key: 'tb-code', icon: Icons.code, active: _has(q.Attribute.inlineCode), onTap: () => _toggle(q.Attribute.inlineCode)),
            const ToolbarSeparator(),
            _button(key: 'tb-h1', icon: Icons.looks_one, active: _has(q.Attribute.h1), onTap: () => _toggleHeader(1)),
            _button(key: 'tb-h2', icon: Icons.looks_two, active: _has(q.Attribute.h2), onTap: () => _toggleHeader(2)),
            _button(key: 'tb-h3', icon: Icons.looks_3, active: _has(q.Attribute.h3), onTap: () => _toggleHeader(3)),
            const ToolbarSeparator(),
            _button(key: 'tb-ul', icon: Icons.format_list_bulleted, active: _has(q.Attribute.ul), onTap: () => _toggle(q.Attribute.ul)),
            _button(key: 'tb-ol', icon: Icons.format_list_numbered, active: _has(q.Attribute.ol), onTap: () => _toggle(q.Attribute.ol)),
            _button(key: 'tb-quote', icon: Icons.format_quote, active: _has(q.Attribute.blockQuote), onTap: () => _toggle(q.Attribute.blockQuote)),
            const ToolbarSeparator(),
            _button(key: 'tb-align-left', icon: Icons.format_align_left, active: _has(q.Attribute.leftAlignment), onTap: () => _toggle(q.Attribute.leftAlignment)),
            _button(key: 'tb-align-center', icon: Icons.format_align_center, active: _has(q.Attribute.centerAlignment), onTap: () => _toggle(q.Attribute.centerAlignment)),
            _button(key: 'tb-align-right', icon: Icons.format_align_right, active: _has(q.Attribute.rightAlignment), onTap: () => _toggle(q.Attribute.rightAlignment)),
            if (onAiRewrite != null) ...[
              const ToolbarSeparator(),
              _button(
                key: 'tb-ai',
                icon: Icons.auto_awesome,
                active: false,
                onTap: onAiRewrite!,
                tooltip: 'AI 改写',
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 标题是**互斥**的：点了 H1 再点 H2 要换掉，不是两个都开。
  /// 列表同理 —— `Attribute.clone` 清掉再设，这在 Quill 里是标准做法。
  void _toggleHeader(int level) {
    final target = switch (level) {
      1 => q.Attribute.h1,
      2 => q.Attribute.h2,
      _ => q.Attribute.h3,
    };
    if (_has(target)) {
      controller.formatSelection(q.Attribute.clone(target, null));
      return;
    }
    controller.formatSelection(q.Attribute.clone(q.Attribute.h1, null));
    controller.formatSelection(q.Attribute.clone(q.Attribute.h2, null));
    controller.formatSelection(q.Attribute.clone(q.Attribute.h3, null));
    controller.formatSelection(target);
  }
}
