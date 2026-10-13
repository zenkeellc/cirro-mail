import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

import '../../ai/ai_run.dart';
import '../../ai/inline_continuation.dart';

/// ③ 行内续写：用户停笔一会儿，在光标后面浮一句灰色的建议。
///
/// **Tab 接受 / Esc 丢弃 / 继续打字自动丢**（spec §4.3③）。做成浮层而不是直接
/// 写进文档，是因为「续写」这件事本身是**猜测**：写进去而用户没注意，就成了一
/// 封带着别人口吻的邮件。浮层是一份提案，不是一次修改。
///
/// 它**只读编辑器**，不改任何东西 —— 接受时才调用
/// `InlineContinuation.accept`。于是「什么时候请求、什么时候丢」这些规则全在
/// 纯函数里（Task D5），这个 widget 只管三件事：计时、按键、摆位置。
class AiGhostText extends StatefulWidget {
  const AiGhostText({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.start,
    required this.editorKey,
    required this.viewportKey,
    this.idleDelay = InlineContinuation.idleDelay,
  });

  final q.QuillController controller;

  /// 编辑器的焦点节点 —— 只用来判断「现在是不是真的在写正文」。
  final FocusNode focusNode;

  /// 总开关（设置里那个默认关着的 `inlineContinuationEnabled`）。
  final bool enabled;

  /// 起一次生成。返回 null 表示这一次不发（比如已经配不上条件了）。
  final AiRun? Function() start;

  /// 用来把光标位置换成屏幕坐标（与浮动工具栏同一套）。
  final GlobalKey<q.EditorState> editorKey;

  /// 浮层要定位在哪个盒子里。
  final GlobalKey viewportKey;

  final Duration idleDelay;

  @override
  State<AiGhostText> createState() => _AiGhostTextState();
}

class _AiGhostTextState extends State<AiGhostText> {
  Timer? _idle;
  AiRun? _run;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onEdited);
    // **抢在编辑器之前**拿到 Tab / Esc。
    //
    // 为什么不用 `Focus.onKeyEvent`：这个浮层与编辑器是 Stack 里的**兄弟**，
    // 不是它的祖先 —— 焦点在编辑器上，兄弟节点的 `Focus` 永远收不到按键。
    //
    // 为什么用 `FocusManager.addEarlyKeyEventHandler` 而不是
    // `HardwareKeyboard.addHandler`：后者是**全局**的，但 `HardwareKeyboard`
    // 和焦点树是**两条不同的分发路径**（`KeyEventManager.handleRawKeyMessage`
    // 先发 HardwareKeyboard 的处理链、再走 `keyMessageHandler` 进焦点树），
    // 它的「handled」结果**不会**阻止焦点树继续处理 —— 实测里 quill 照样能收到
    // 那个 Tab 并往正文插一个制表符。`addEarlyKeyEventHandler` 则是在焦点树
    // 分发的**最前面**：返回 `handled` 就直接吃掉，quill 再也看不见这个键。
    //
    // 代价是「所有按键都会先经过这里」—— 所以 [_onKey] 只在**确实有建议挂着**
    // **且焦点真的在正文里**（见下）且按键是 Tab / Esc 时才返回 handled。
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
    // **挂载时也算一次「停笔了」**：打开一封草稿把光标停在末尾、什么都没敲，
    // 用户其实已经停下来了。只在 controller 通知时才计时的话，得先敲一个字
    // 才会开始等 —— 手感上就是「续写功能时灵时不灵」。
    _onEdited();
  }

  @override
  void didUpdateWidget(AiGhostText old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onEdited);
      widget.controller.addListener(_onEdited);
    }
    if (!widget.enabled) _clear();
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    widget.controller.removeListener(_onEdited);
    _idle?.cancel();
    _run?.dispose();
    super.dispose();
  }

  /// 编辑器一有动静：先掐掉待发的请求，再收掉在飞的旧请求，最后重新计时。
  ///
  /// **「取消在飞的请求」是这一轮的要害**：续写现在每次都要把整封邮件（含引用）
  /// 发出去，用户继续打字时旧请求的答案一定是过期的（基于上一个光标位置）。
  /// 只丢弃显示、不取消请求的话，钱白花、且下一份建议还得排在它后面。
  /// [_clear] 里的 `run.dispose()` 会把底层 HTTP 一起 cancel 掉
  /// （`AiRun.dispose → AiStream.cancel → Dio CancelToken`）。
  void _onEdited() {
    _idle?.cancel();
    // 用户一有动静（打字 / 移光标）→ 已有的建议与在飞的请求一起作废。
    if (_run != null) _clear();

    if (!widget.enabled) return;
    if (!InlineContinuation.shouldRequest(
      controller: widget.controller,
      enabled: widget.enabled,
      // 上面刚清空，所以这里恒为 false —— 留着这个参数是因为 [shouldRequest]
      // 仍是纯函数、仍有单测钉着「生成中不请求」这条规则。
      isGenerating: _run != null,
    )) {
      return;
    }
    _idle = Timer(widget.idleDelay, _request);
  }

  void _request() {
    if (!mounted || !widget.enabled) return;
    if (!InlineContinuation.shouldRequest(
      controller: widget.controller,
      enabled: widget.enabled,
      isGenerating: _run != null,
    )) {
      return;
    }
    final run = widget.start();
    if (run == null) return;
    setState(() {
      _run?.dispose();
      _run = run;
    });
  }

  void _clear() {
    _idle?.cancel();
    final run = _run;
    if (run == null) return;
    // 换掉整个 run：`cancel()` 之后流还会回调一次（见 `AiRun.dispose`）。
    setState(() => _run = null);
    run.dispose();
  }

  /// Tab / Esc。**返回 handled 表示这次按键被吃掉了**（不让焦点树里的编辑器
  /// 再处理一遍，否则 Tab 会往正文里插一个制表符、Esc 会去干别的）。
  ///
  /// 焦点门禁：这个处理器是**全应用**的（`FocusManager` 里全局注册），于是
  /// 光标在收件人/主题这些别的输入框里时它照样会被叫到。这里必须确认焦点
  /// **真的在正文里**（[FocusNode.hasFocus] 含后代节点，因为焦点可能落在编辑器
  /// 内部的子节点上），否则就会出现「在主题栏按 Tab，建议被静悄悄地写进了正文，
  /// 而 Tab 本该是切换焦点」——本轮要修的正是这个。
  KeyEventResult _onKey(KeyEvent event) {
    final run = _run;
    if (run == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!widget.focusNode.hasFocus) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final suggestion = run.text.value;
      if (suggestion.trim().isEmpty) return KeyEventResult.handled;
      InlineContinuation.accept(widget.controller, suggestion);
      _clear();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _clear();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // 订阅 controller：光标一移动浮层就得跟着挪（或者干脆消失），而那时候
    // 上层页面不一定重建。
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final run = _run;
        if (run == null) return const SizedBox.shrink();
        return ValueListenableBuilder<String>(
          valueListenable: run.message,
          builder: (context, message, _) {
            // 出错/没配 Key → 幽灵文本**安静地消失**。它是个锦上添花的
            // 东西，为它弹一句报错会打扰正在写字的人（与停止按钮同一个道理）。
            if (message.isNotEmpty) return const SizedBox.shrink();
            return ValueListenableBuilder<String>(
              valueListenable: run.text,
              builder: (context, text, _) {
                if (text.trim().isEmpty) return const SizedBox.shrink();
                final placement = _placement();
                if (placement == null) return const SizedBox.shrink();
                return Positioned(
                  left: placement.left,
                  top: placement.top,
                  child: _GhostBubble(
                    text: text,
                    maxWidth: placement.maxWidth,
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// 建议摆哪儿。**这是这个 widget 唯一算错就会「什么都没看见」的地方。**
  ///
  /// 默认摆在光标**下方** —— 续写是对「接下来会写什么」的提案，放在下方正好
  /// 是它将要出现的位置。但「下方」经常是**可见区的底边外面**：编辑器会一直
  /// 把光标滚到看得见的地方，于是用户写到屏幕底部那一行时，光标的下沿正好
  /// 贴着视口底边（探针实测：光标底部 492.0 == 编辑器底边 492.0），灰色的
  /// 建议整条落在裁剪区外 —— 表现就是**「调用次数涨了，正文里什么都看不到」**。
  /// 所以下方放不下就翻到光标上方；再放不下（视口比一行还矮）就夹回可见区，
  /// 宁可压住一行字，也比整条建议被裁掉强。
  ///
  /// 坐标系是**相对 viewportKey 那个盒子**的：`localToGlobal` 已经把滚动偏移
  /// 算进去了（光标所在的渲染盒在滚动视图内部，向上平移了 scroll offset），
  /// 两边相减即得。
  ({double left, double top, double maxWidth})? _placement() {
    final caret = _caretRect();
    if (caret == null) return null;
    final viewportBox = widget.viewportKey.currentContext?.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;
    final height = viewportBox.size.height;
    final width = viewportBox.size.width;

    var top = caret.bottom;
    if (top + _ghostHeight > height) top = caret.top - _ghostHeight;
    top = top.clamp(0.0, (height - _ghostHeight).clamp(0.0, double.infinity));

    final left =
        caret.left.clamp(0.0, (width - _maxGhostWidth).clamp(0.0, double.infinity));
    // 剩下的宽度：窄视口上不能让它溢出右边（`Stack` 默认 `Clip.hardEdge`，
    // 溢出的部分是被**裁掉**的，不是挤出去）。
    return (left: left, top: top, maxWidth: (width - left).clamp(0.0, _maxGhostWidth));
  }

  /// 光标在 viewport 局部坐标里的那个小矩形（宽 0，高一行）。
  ///
  /// 用 `getEndpointsForSelection`：它对折叠选区给的是**光标下沿**那一点
  /// （`editor.dart:854` 那一支：`Offset(0, preferredLineHeight) + localOffset`），
  /// 于是 `top` 就是这一行的顶边、`bottom` 就是底边。与浮动工具栏同一套取法。
  Rect? _caretRect() {
    final selection = widget.controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final render = widget.editorKey.currentState?.renderEditor;
    final viewportBox = widget.viewportKey.currentContext?.findRenderObject();
    if (render == null || viewportBox is! RenderBox) return null;
    if (!render.hasSize || !viewportBox.hasSize) return null;

    // 行结构重建期间端点可能匹配不到子节点，会抛（`editor.dart:884` 的
    // 断言）—— 与 `toolbarAnchor` 同一个坑。这里是渲染路径，抛一次就是红屏，
    // 拿不到几何就当「不摆」，下一帧自然会再试。
    final List<TextSelectionPoint> endpoints;
    try {
      endpoints = render.getEndpointsForSelection(selection);
    } on Object {
      return null;
    }
    if (endpoints.isEmpty) return null;

    const origin = Offset.zero;
    final editorOrigin = render.localToGlobal(origin);
    final viewportOrigin = viewportBox.localToGlobal(origin);
    final point = endpoints.first.point;
    final left = point.dx + editorOrigin.dx - viewportOrigin.dx;
    final bottom = point.dy + editorOrigin.dy - viewportOrigin.dy;
    return Rect.fromLTWH(left, bottom - _lineHeight, 0, _lineHeight);
  }
}

/// 一行的高度（光标顶边到「光标下沿」的距离）。写死是为了**先**算出位置再
/// 渲染 —— 用实测高度的话第一帧会闪一下。
const double _lineHeight = 22;

/// 估算的浮层高度。**只用来判「下方放不放得下」** —— 差几个像素的后果是它
/// 稍微压住上一行，而不是被裁掉（那是修之前的行为）。
const double _ghostHeight = 22;

/// 浮层最大宽度。与下面的 `ConstrainedBox` 同一个数，两边必须一致：
/// 定位时用它算「左边最多能到哪」，渲染时用它限制自身宽度。
const double _maxGhostWidth = 420;

/// 幽灵文本本身：灰、斜、不可点（它不是按钮，是提案）。
class _GhostBubble extends StatelessWidget {
  const _GhostBubble({required this.text, this.maxWidth = _maxGhostWidth});

  final String text;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 太长的建议不铺满整屏；它本来就只该是一两句。**行数也封住**：续写那边
    // 的输出预算从 256 抬到了 10000（那是为了正文那条路不被截断），模型偶尔
    // 会拿「一两句」的指令当耳旁风、续出一整段 —— 不封的话浮层会吃掉整个编辑
    // 区。封住之后溢出的部分被裁，至少不会把正文盖没。
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: IgnorePointer(
        child: Text(
          text,
          key: const ValueKey('ai-ghost'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}
