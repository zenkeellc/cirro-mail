// 剪贴板那一组 API 在 flutter_quill 11.6 上标了 `@experimental`，但**没有
// 别的路子**能配到这几个口子（`QuillEditorConfig` 上根本没有它们）。用它，
// 并且把「为什么用它」写在这里 —— 将来升级时这几个名字是最先要复查的。
// ignore_for_file: experimental_member_use

import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart'
    show PointerDownEvent, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

import '../table/table_block.dart';
import 'drop_target.dart';
import 'editor_context_menu.dart';
import 'editor_toolbar.dart';
import 'image_actions.dart' show EmbedTapCallback;
import 'mail_embed_builders.dart';

/// 建一个**配好粘贴通路**的 `QuillController`。
///
/// 为什么要有这个工厂：剪贴板的行为在 `QuillControllerConfig` 上，不在
/// `QuillEditorConfig` 上（`quill_controller.dart:29`，`config:` 参数）。
/// 界面拿到的是 controller，所以「粘贴怎么处理」这件事必须在**建 controller
/// 的时候**就定下来。把它收成一个工厂，就不会出现「编辑器配好了但粘贴没接上」。
///
/// 三条粘贴通路的**顺序**由 flutter_quill 定死（`quill_controller.dart:573`）：
/// 自定义 `onClipboardPaste` → 内嵌图 → HTML → Markdown → 位图 →
/// 纯文本 → `onUnprocessedPaste`。
q.QuillController mailQuillController({
  required q.Document document,
  TextSelection? selection,
  bool readOnly = false,
  Future<String?> Function(Uint8List imageBytes)? onImagePaste,
  Future<String?> Function(String plainText)? onPlainTextPaste,
  /// 自定义剪贴板处理。**返回 true 表示「我处理完了，别走默认通路」**。
  /// 富文本粘贴（HTML 风味）就走这里，因为上游 `pasteHTML` 用的是
  /// `DeltaX.fromHtml`，而那是**被弃用的、表格会转换两次的**实现
  /// （spec §0.2 第 2 条）。我们用自写的 `MailHtmlToDelta`。
  Future<bool> Function()? onClipboardPaste,
}) {
  return q.QuillController(
    document: document,
    readOnly: readOnly,
    // 光标默认落在**末尾那个 `\n` 之前** —— 也就是「接着往下写」的位置。
    // 注意用的是 `Document.length`（含末尾换行）而不是 `delta.length`：
    // 后者是 **op 的个数**（`Delta.length => operations.length`），
    // 与字符数毫无关系，拿它当偏移会让光标停在完全不对的地方
    // （§0.2 第 6c 条）。
    selection: selection ?? TextSelection.collapsed(offset: document.length - 1),
    config: q.QuillControllerConfig(
      clipboardConfig: q.QuillClipboardConfig(
        onClipboardPaste: onClipboardPaste,
        onImagePaste: onImagePaste,
        onPlainTextPaste: onPlainTextPaste,
        // **关掉**上游的外部富文本粘贴：它走 `DeltaX.fromHtml`，而那个实现对
        // 表格会转换两次（`html_to_delta.dart:132` 的 `continue` 跳的是内层
        // for）。关掉之后 HTML 粘贴由 `onClipboardPaste` 接管。
        // 纯文本通路不受影响（它在 `enableExternalRichPaste` 的判断之外）。
        enableExternalRichPaste: false,
      ),
    ),
  );
}

/// 正文编辑器：`QuillEditor` 的**挂载与配置**，外加选区浮动工具栏。
///
/// **编辑器与工具栏一起挂**，不是分成两个 widget 让页面自己拼 `Stack`：
/// 工具栏的位置是相对**编辑器视口**算的，两者共用同一个盒子；分开摆的话页面
/// 得自己造一个 `GlobalKey` 的 `Stack` 并把 `editorKey` 传进去 —— 三个必须对上
/// 的 key 散在调用方手里，错一个的表现是「工具栏跑到屏幕外」，很难查。
///
/// 挂载点还要一次性把「嵌入注册表 + 未知嵌入兜底」配齐
/// （§0.2 第 6 条：漏一个嵌入 builder 就白屏）。
///
/// 注意 `readOnly` **不在这里** —— 它在 controller 上（见 [mailQuillController]）。
class MailQuillEditor extends StatefulWidget {
  const MailQuillEditor({
    super.key,
    required this.controller,
    required this.focusNode,
    this.placeholder,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.tableCallbacks,
    this.onAiRewrite,
    this.onDropFiles,
    this.dropEnabled,
    this.overlayBuilder,
    this.onImageTap,
    this.onKeyPressed,
  });

  final q.QuillController controller;
  final FocusNode focusNode;

  /// 空文档时显示的提示语。**要认真写** —— spec §3.1 说静默画布的空状态
  /// 更容易显得空，这句提示就是补偿。
  final String? placeholder;

  /// 正文区的内边距。默认左右 16：读起来像纸，不像表单。
  final EdgeInsets padding;

  /// 表格块的行列操作回调（表格将来想插图时会问它）。
  final TableBlockCallbacks? tableCallbacks;

  /// 点浮动工具栏上「AI 改写」时回调。**为 null 就不显示那个按钮** ——
  /// 没配 AI 的用户不该看到一个点了没反应的图标。
  final VoidCallback? onAiRewrite;

  /// 有文件被拖进正文区。为 null 就不装拖放（移动端拖不了，装了也没用）。
  ///
  /// 第二个参数是**松手位置对应的文档偏移**，拿不到几何信息时是 null
  /// （调用方退回光标处）。落点由这里算而不是交给页面：只有这里同时握着
  /// `editorKey` 和 `ScrollController`，页面两个都没有。
  final void Function(DropDoneDetails details, int? dropOffset)? onDropFiles;

  /// 拖动悬停时的那层遮罩要不要收事件。**页面被别的路由盖住时必须传 false**
  /// （`DropTarget.enable` 的语义），否则在设置页拖文件会落到这里。
  final bool? dropEnabled;

  /// 造一个浮层，塞进编辑器视口里（行内续写的幽灵文本用）。
  ///
  /// **为什么是 builder 而不是直接收一个 `Widget`**：`_editorKey` /
  /// `_viewportKey` / `_scroll` **三个都是私有的**，而 `AiGhostText` 恰恰
  /// 需要前两个（它要把光标位置换算成屏幕坐标，用的是与浮动工具栏同一套
  /// 算法）。收 `Widget` 的话，调用方得自己弄到那两个 key —— 唯一的办法是
  /// 把它们公开出去，那就等于把这个 widget 存在的理由（「三个必须对上的
  /// key 只在一个文件里」）废掉了。给一个 builder，这件事仍然只在这里发生。
  ///
  /// 它会和 `EditorToolbar` 一样是那个 `Stack` 的直接子节点，
  /// 于是里面写的 `Positioned` 才合法（§0.2 第 11 条）。
  final Widget Function(
    GlobalKey<q.EditorState> editorKey,
    GlobalKey viewportKey,
  )? overlayBuilder;

  /// 点正文里的一张图时回调，参数是那张图在**当前文档**里的偏移。
  ///
  /// **为空就不可点**：只读视图（收信侧）不传它。这一路必须**直达**
  /// `mailEmbedBuilders` —— 中间任何一层吞掉它，表现都是「点了没反应」，
  /// 而本机跑不了真机 UI，断链只能靠读代码看出来。
  final EmbedTapCallback? onImageTap;

  /// 正文里的按键**先手**。返回非 null 就直接当结果
  /// （quill 的 `_onKeyEvent` 在
  /// `raw_editor/keyboard_shortcuts/editor_keyboard_shortcuts.dart:82`
  /// 就是这么用的：`if (result != null) return result;`）。
  ///
  /// 为什么必须从这里过：quill 自己那层 `Shortcuts` 无条件绑了
  /// `escape → HideSelectionToolbarIntent`，而它在**焦点树**上比页面那层
  /// `Shortcuts` 近，页面根本收不到 —— 这是唯一一个「比 quill 自己的表更早」
  /// 的口子。
  ///
  /// **不按键的键必须返回 null，不能返回 `KeyEventResult.ignored`**：quill 判的
  /// 是 `!= null`（同一行），`ignored` 也是非 null，等于把 quill 自己那些按键
  /// 全吞掉（正文直接打不了字）。
  final KeyEventResult? Function(KeyEvent event)? onKeyPressed;

  @override
  State<MailQuillEditor> createState() => _MailQuillEditorState();
}

class _MailQuillEditorState extends State<MailQuillEditor> {
  late final ScrollController _scroll = ScrollController();

  /// 编辑器内部状态。`EditorToolbar` 靠它把选区换算成屏幕坐标。
  final GlobalKey<q.EditorState> _editorKey = GlobalKey<q.EditorState>();

  /// 浮动工具栏的定位参照系 —— 就是下面这个 `Stack`。
  final GlobalKey _viewportKey = GlobalKey();

  /// 表格单元格那些输入框的**焦点归属**（焦点树上的宿主节点）。
  ///
  /// 为什么需要它：`FocusNode.hasFocus` 的定义带了「祖先」这一条
  /// （`focus_manager.dart:774`：`hasPrimaryFocus || primaryFocus.ancestors
  /// .contains(this)`）。单元格输入框在**控件树**上是正文编辑器的后代，
  /// 于是「用户点进单元格」之后，正文那个 `FocusNode.hasFocus` **仍然是
  /// true**，`RenderEditableTextLine.hasFocus` 也就仍然是 true
  /// （`raw_editor_state.dart:74` → `_buildChildren` 一路传下去）—— 光标守卫
  /// `hasFocus && cursorCont.show.value && containsCursor()`
  /// （`text_line.dart:1470`）三个条件全成立，正文光标照样画。
  ///
  /// 于是屏幕上同时出现两根光标：单元格里的，和正文里那根（光标落在表格那一行
  /// 时，它的高度是 `RenderEmbedProxy.getFullHeightForCaret => size.height`，
  /// 也就是**跟表格一样高**）。
  ///
  /// 把它们在**焦点树上**拆开就没有这件事了：单元格的输入框 `Focus
  /// (parentNode: 这个节点)`，成为正文编辑器的**兄弟**而不是后代，正文的
  /// `hasFocus` 就会在单元格拿到主焦点时变回 false（探针实测），光标随之
  /// 不再画 —— 这正是「两根光标互斥」。
  ///
  /// `canRequestFocus: false` + `skipTraversal: true`：它只是焦点树上的一个
  /// 挂点，自己不参与聚焦与 Tab 遍历。
  final FocusNode _embedFocusHost = FocusNode(
    debugLabel: 'quill-embed-host',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// 编辑菜单（右击/长按弹出的剪切复制粘贴）现在开着吗。
  ///
  /// 开着的时候浮动工具栏让位（见 [EditorToolbar.suppressed]）。两个气泡都锚
  /// 在同一个选区上、又都画在同一个 `Stack` 里，不让位就会叠着出现。
  bool _contextMenuOpen = false;

  /// 菜单出现/消失。**从帧后回调进来**（见 `MailQuillContextMenu._notify`），
  /// 那时可能已经卸载，所以先看 `mounted`。
  void _setContextMenuOpen(bool open) {
    // 菜单收起来时把右击坐标一起清掉 —— 不清的话，下一次长按（触屏那条路，
    // 根本没有右击坐标）会复用到上一次右击的坐标，菜单飞到屏幕上一个莫名其
    // 妙的地方。
    if (!open) _secondaryTapDown = null;
    if (!mounted || _contextMenuOpen == open) return;
    setState(() => _contextMenuOpen = open);
  }

  /// 最近一次**右击**落在哪（屏幕全局坐标），菜单关掉就清。
  ///
  /// 为什么要在外面自己记：quill 的 `QuillRawEditorState.contextMenuAnchors`
  /// 只按选区端点算锚点，没把右击坐标留出来（`RenderEditor` 上没有这个字段，
  /// `lastSecondaryTapDownPosition` 是 Flutter 自己 `RenderEditable` 才有的）。
  /// 详见 `editor_context_menu.dart` 顶上的说明。
  Offset? _secondaryTapDown;

  /// 右键按下：记坐标，并按 Flutter 自己的惯例调整光标/选区。
  ///
  /// 语义抄的是 `SelectableRegion._handleRightClickDown`
  /// （`selectable_region.dart:1046`）在 android/windows/linux 那几支：
  /// 右击点**落在当前非折叠选区内**就原样保住（否则「复制/剪切」没有对象），
  /// 落在**外面**就把光标落到右击处、选区收起（否则点「粘贴」会粘到旧光标
  /// 位置上）。macOS/iOS 那边 Flutter 更进一步做了「选中鼠标下的词」，这里
  /// 不做 —— 那与「回复时右击一下打算粘贴」的意图正好相反。
  ///
  /// 放在 `onPointerDown` 而不是菜单 builder 里：builder 会被反复调用，不是
  /// 做副作用的地方；而且选区必须在菜单算锚点**之前**落定。
  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons != kSecondaryMouseButton) {
      // 任何**主键**按下都清掉旧坐标：否则「先右击、再左键点到别处」之后
      // 若从键盘/长按唤出菜单，会锚在上一次右击的位置。
      _secondaryTapDown = null;
      return;
    }
    _secondaryTapDown = event.position;
    _adjustSelectionForSecondaryTap(event.position);
  }

  void _adjustSelectionForSecondaryTap(Offset globalPosition) {
    final state = _editorKey.currentState;
    if (state == null || !state.mounted) return;
    final render = state.renderEditor;
    if (!render.attached || !render.hasSize) return;
    final selection = widget.controller.selection;
    if (selection.isValid && !selection.isCollapsed) {
      // 角色偏移落在 `[start, end)` 就算「点在选区里」。
      final at = render.getPositionForOffset(globalPosition).offset;
      if (selection.start <= at && at < selection.end) return;
    }
    render.selectPositionAt(
      from: globalPosition,
      cause: SelectionChangedCause.longPress,
    );
  }

  @override
  void dispose() {
    _embedFocusHost.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final callbacks =
        widget.tableCallbacks ?? TableBlockCallbacks(onChanged: (_) {});
    final canvas = Stack(
      key: _viewportKey,
      children: [
        // 外层 `Listener` **只看右击**（见 [_onPointerDown]）：quill 不把右击
        // 坐标留出来，而菜单要锚在那儿。`Listener` 不参与手势竞技场（不是
        // `GestureDetector`），所以底下的选区/点击/拖拽手势一个都不受影响 ——
        // 这也是没有改用 `RawGestureDetector` 抢 kSecondaryButton 的原因。
        //
        // 包在**编辑器**外面、不是整个 `Stack` 外面：工具栏上的右击不该被当成
        // 「正文里右键」。
        Listener(
          onPointerDown: _onPointerDown,
          child: q.QuillEditor(
            controller: widget.controller,
            focusNode: widget.focusNode,
            scrollController: _scroll,
            config: q.QuillEditorConfig(
              editorKey: _editorKey,
              placeholder: widget.placeholder,
              padding: widget.padding,
              autoFocus: false,
              // **撑满分到的空间**（F-4）。不设它的时候，`Stack` 里这个非定位
              // 子节点拿到的是**松**约束（`RenderStack._computeSize` +
              // `StackFit.loose`），编辑器于是缩到「内容高度」—— 一行的空正文
              // 只有 18px 高（实测），剩下的一大片空白既不是它的、也点不到，
              // 表现就是「看着没占满、非得点到光标附近才聚焦」。设了之后
              // `raw_editor_state.dart:536` 给出 `BoxConstraints.expand()`，
              // 盒子撑满，点正文区任何位置都落进编辑器（实测 18px → 600px）。
              //
              // `minHeight` / `maxHeight` 必须留空：`expands` 为 true 时它们
              // 被忽略（quill 文档明说两者只能取其一）。
              expands: true,
              // **打开** flutter_quill 自带的 cut/copy/paste 菜单（F-3）。
              //
              // 早先这里是 false，理由是「它跟我们自己的浮动工具栏会叠着出现」。
              // 那个理由本身没错，但代价被严重低估：`enableSelectionToolbar:
              // false` → `editor.dart:291` 把 `contextMenuBuilder` 传成 null →
              // `copyEnabled`/`cutEnabled`/`pasteEnabled`/`selectAllEnabled`
              // **一起变成 false**（`..._selection_delegate_mixin.dart:124-135`），
              // 于是那三个回调全是空壳 —— 用户右击弹出的是一个点了没反应的菜单。
              // 正确做法是开着它、给一个自己的 builder，再把「叠着出现」交给
              // 浮动工具栏让位（[EditorToolbar.suppressed]）。
              enableSelectionToolbar: true,
              contextMenuBuilder: mailContextMenuBuilder(
                onPresenceChanged: _setContextMenuOpen,
                // 「菜单跟着鼠标」的那份坐标（见 [_onPointerDown]）。
                rightClickAnchor: () => _secondaryTapDown,
              ),
              // **一次给全**（§0.2 第 6 条）。`mailEmbedBuilders` 里带一份兜底，
              // 于是「加了新嵌入类型忘了注册」的表现是「显示成一行提示」而不是白屏。
              embedBuilders: mailEmbedBuilders(
                controller: widget.controller,
                tableCallbacks: callbacks,
                // 单元格输入框挂到正文编辑器**之外**（见 [_embedFocusHost]）。
                embedFocusParent: _embedFocusHost,
                // 点图改对齐/换图。**这里是唯一的去处**，页面拿不到
                // `embedContext`，只能从这里透下去。
                onImageTap: widget.onImageTap,
              ),
              // 未知嵌入走的是**独立字段**，不在 embedBuilders 里，两处都要给。
              unknownEmbedBuilder: const UnknownEmbedBuilder(),
              // 按键先手（正文里的 Esc，见 [onKeyPressed]）。quill 那个回调收
              // 两个参数，页面只关心 `event`，在这里把 `node` 吃下去 ——
              // 别让这个本页用不上的参数漏进页面的回调签名里。
              onKeyPressed: widget.onKeyPressed == null
                  ? null
                  : (event, _) => widget.onKeyPressed!(event),
            ),
          ),
        ),
        // **顺序有讲究**：工具栏画在浮层**上面** —— 幽灵文本是长在光标下沿的
        // 一行灰字，而工具栏是选中时才出现的一张不透明卡片。反过来盖的话，
        // 用户选中一段打算改写时，甲板会被幽灵文本压住几个像素。
        if (widget.overlayBuilder != null)
          widget.overlayBuilder!(_editorKey, _viewportKey),
        EditorToolbar(
          controller: widget.controller,
          editorKey: _editorKey,
          viewportKey: _viewportKey,
          onAiRewrite: widget.onAiRewrite,
          // 编辑菜单开着时让位（见 [EditorToolbar.suppressed]）。
          suppressed: _contextMenuOpen,
        ),
      ],
    );

    // 焦点树上的挂点：正文编辑器挂**在这个节点下面**，单元格输入框挂成它的
    // **平级**（见 [_embedFocusHost] 的说明）。`canRequestFocus: false` 让它
    // 自己不被聚焦。
    final focusHosted = Focus(
      focusNode: _embedFocusHost,
      canRequestFocus: false,
      skipTraversal: true,
      child: canvas,
    );

    final onDrop = widget.onDropFiles;
    if (onDrop == null) return focusHosted;
    // 拖放**罩在整个画布外面**：落点相对的是这一层的盒子，而 `_editorKey` 与
    // `_scroll` 都在手边，于是「松手位置 → 文档偏移」可以当场算出来，
    // 页面不用去猜（它既拿不到 editorKey，也拿不到这个滚动控制器）。
    return MailDropTarget(
      enabled: widget.dropEnabled ?? true,
      onDrop: (details) => onDrop(
        details,
        dropOffsetInDocument(
          localPosition: details.localPosition,
          editorState: _editorKey,
          scrollOffset: _scroll.hasClients ? _scroll.offset : 0,
        ),
      ),
      child: focusHosted,
    );
  }
}
