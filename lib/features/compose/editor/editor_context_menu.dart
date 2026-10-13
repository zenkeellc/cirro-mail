import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

/// 右击 / 长按弹出来的**编辑菜单**：剪切 / 复制 / 粘贴 / 全选。
///
/// ## 为什么必须自己给一个 builder
///
/// `QuillEditorConfig.enableSelectionToolbar` 为 `false` 时，`editor.dart:291`
/// 会把 `contextMenuBuilder` 传成 `null`。而那个 null 不只是「不弹菜单」——
/// `contextMenuBuilder == null` 会让 `copyEnabled` / `cutEnabled` /
/// `pasteEnabled` / `selectAllEnabled` **一起变成 false**
/// （`raw_editor_state_selection_delegate_mixin.dart:124-135`），于是
/// `contextMenuButtonItems` 里每一项的回调都是 null、菜单成了空壳。所以这一项
/// 必须开着，并且给一个真的 builder。
///
/// ## 为什么不用 `QuillRawEditorConfig.defaultContextMenuBuilder`
///
/// 默认那份在 macOS 桌面上会走 `DesktopTextSelectionToolbar`，锚在选区上 ——
/// 位置几乎一定和我们自己的浮动格式工具栏（`EditorToolbar`）重叠。这里按钮
/// **条目**仍然取 `state.contextMenuButtonItems`（那一份是 flutter_quill 按
/// 只读、剪贴板状态算出来的，自己拼会漏判），但把「菜单出现 / 消失」这件事
/// 通知出去，让浮动工具栏在菜单开着时让位（见 [MailQuillContextMenu] 与
/// `MailQuillEditor` 的 `_contextMenuOpen`）。
///
/// ## macOS 上那个原生 Edit 菜单是**没有救**的
///
/// `macos/Runner/Base.lproj/MainMenu.xib` 里的 Cut/Copy/Paste/Select All 走的是
/// `target="-1"`（第一响应者）+ `copy:`/`paste:` 这些 selector。引擎把它转成
/// `TextInputClient.performSelectors`（`services/text_input.dart:2282`），
/// 再交给 `QuillRawEditorState.performSelector`；而
/// `intentForMacOSSelector`（`default_text_editing_shortcuts.dart:1031`）的 41 条
/// 映射里**没有** `copy:`/`paste:`/`cut:`/`selectAll:` —— `performSelector` 拿到
/// null 就直接 return。所以那几个菜单项点了不会有任何反应，这不是我们的错，
/// Flutter 自己的 `EditableText.performSelector` 一样是空的。
/// 用户在应用内可达的剪贴板入口就两个：**Cmd+C/V/X**（走 Flutter 的
/// `_clipboardShortcuts` → quill 的 Actions，一直是好的）与**本菜单**。
///
/// ## 菜单要落在**鼠标**上，不是落在选区上（用户报的那条）
///
/// Flutter 自己的 `EditableTextState.contextMenuAnchors`
/// （`editable_text.dart:3210`）第一句就是
/// `if (renderEditable.lastSecondaryTapDownPosition != null)` —— 有右击点就用
/// 右击点当锚。flutter_quill 的 `QuillRawEditorState.contextMenuAnchors`
/// （`raw_editor_state.dart:262`）**没有这一支**：它一律按**选区端点**算
/// （`getEndpointsForSelection`）。折叠选区时右击会先把光标挪过去，锚点于是
/// 「看起来」跟着走；**一旦有非折叠选区**，右击既不动选区也不动锚点 ——
/// 菜单停在旧选区上，离鼠标可能隔着好几行。这就是用户看到的现象。
///
/// 修法与 Flutter 一样：拿「那一次右击的坐标」，有它就直接当
/// `primaryAnchor`。坐标由 `MailQuillEditor` 那层 `Listener` 记下来（quill
/// 没有把它暴露出来，`RenderEditor` 上也拿不到），从 [rightClickAnchor] 传进来。
///
/// 只给 `primaryAnchor`、不给 `secondaryAnchor` —— 与 `EditableTextState`
/// 那一支逐字一致（工具条在屏幕下沿时靠它翻到锚点上方）。
///
/// 返回的是一个工厂：调用方每次 `build` 造一个新的 builder，闭包捕获到的
/// `onPresenceChanged` 用来把「菜单开着」这件事通知回编辑器，
/// [rightClickAnchor] 用来取「这一次右击落在哪」。
q.QuillEditorContextMenuBuilder mailContextMenuBuilder({
  ValueChanged<bool>? onPresenceChanged,
  Offset? Function()? rightClickAnchor,
}) {
  return (context, state) => MailQuillContextMenu(
        onPresenceChanged: onPresenceChanged,
        child: TextFieldTapRegion(
          // `TextFieldTapRegion` 不是装饰：它让菜单里的点击算作**输入框内部**
          // 的点击，于是 `onTapOutside` 不会因为「点菜单」而把编辑器失焦
          // （失焦之后 Paste 那一项按下去就没有落点了）。默认实现也是这么包的。
          child: AdaptiveTextSelectionToolbar.buttonItems(
            buttonItems: state.contextMenuButtonItems,
            anchors: _anchorsFor(state, rightClickAnchor),
          ),
        ),
      );
}

/// 有记录的右击点就锚在那儿；没有（长按 / 键盘那条路）退回 quill 按选区
/// 算出的锚点。
///
/// `rightClickAnchor()` 有可能抛（编辑器还没挂上 / 已经拆了，`renderEditor`
/// 会在 `_editorKey.currentContext!` 上炸）—— 那一支退回选区锚点，菜单
/// 照常出现，只是位置退化成老行为。
TextSelectionToolbarAnchors _anchorsFor(
  q.QuillRawEditorState state,
  Offset? Function()? rightClickAnchor,
) {
  if (rightClickAnchor != null) {
    Offset? anchor;
    try {
      anchor = rightClickAnchor();
    } catch (_) {
      anchor = null;
    }
    if (anchor != null) {
      return TextSelectionToolbarAnchors(primaryAnchor: anchor);
    }
  }
  return state.contextMenuAnchors;
}

/// 把「这个菜单在不在图上」这件事报出去的一层壳。
///
/// 用 widget 的生命周期而不是在 builder 里直接调用回调：builder 每次重建都会
/// 被调用，而 [initState] / [dispose] 才是「插入 overlay」与「从 overlay 摘掉」
/// 的一次性事件。
///
/// 通知**放到帧后**：这两个生命周期回调都可能发生在别的 widget 正在 build 的
/// 过程中，直接 `setState` 会撞「setState() called during build」。
@visibleForTesting
class MailQuillContextMenu extends StatefulWidget {
  const MailQuillContextMenu({
    super.key,
    required this.child,
    this.onPresenceChanged,
  });

  final Widget child;

  /// true = 菜单出现了，false = 菜单没了。可能为 null（不需要知道）。
  final ValueChanged<bool>? onPresenceChanged;

  @override
  State<MailQuillContextMenu> createState() => _MailQuillContextMenuState();
}

class _MailQuillContextMenuState extends State<MailQuillContextMenu> {
  @override
  void initState() {
    super.initState();
    _notify(true);
  }

  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    _notify(false);
    super.dispose();
  }

  void _notify(bool open) {
    final callback = widget.onPresenceChanged;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => callback(open));
  }
}
