import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/inline_continuation.dart';
import 'package:mail_app/features/compose/ai/ai_ghost_text.dart';

class ManualTransport implements AiTransport {
  ManualTransport(this.reply);

  final String reply;
  final List<Completer<void>> _gates = <Completer<void>>[];
  bool cancelled = false;
  var calls = 0;

  void finish() {
    if (_gates.isNotEmpty && !_gates.last.isCompleted) _gates.last.complete();
  }

  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async {
    calls++;
    final gate = Completer<void>();
    _gates.add(gate);
    onChunk('data: {"choices":[{"delta":{"content":"$reply"}}]}\n\n');
    await Future.any(<Future<void>>[
      gate.future,
      cancelToken.whenCancel.then((_) {}),
    ]);
    if (cancelToken.isCancelled) {
      cancelled = true;
      throw const AiCancelledException();
    }
  }

  @override
  Future<String> request({
    required String method,
    required String url,
    required Map<String, String> headers,
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  }) async =>
      throw UnimplementedError('这个假传输只用来测流式');
}

AiRun startWith(AiTransport t) => AiRun(AiStarted(
      AiClient(transport: t).stream(
        provider: const AiProvider(
          format: AiApiFormat.openai,
          model: 'm',
          baseUrl: 'https://api.openai.com/v1',
        ),
        request: const AiRequest(system: 's', prompt: 'p'),
        apiKey: 'k',
      ),
    ));

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 测试宿主：QuillEditor 与幽灵文本是同一个 Stack 里的兄弟节点（生产里也是），
/// 而且 Stack **必须**撑满 —— 否则浮层落在框外，`tester.tap` 点不动。
class Host extends StatefulWidget {
  const Host({
    super.key,
    required this.controller,
    required this.editorKey,
    required this.viewportKey,
    required this.enabled,
    required this.start,
    this.idleDelay = const Duration(milliseconds: 20),
    this.other,
  });

  final q.QuillController controller;
  final GlobalKey<q.EditorState> editorKey;
  final GlobalKey viewportKey;
  final bool enabled;
  final AiRun? Function() start;
  final Duration idleDelay;

  /// 「别的输入框」（收件人 / 主题之类）。焦点挪到这里之后，幽灵文本不该再
  /// 吃 Tab —— 见下面那条反例。
  final FocusNode? other;

  @override
  State<Host> createState() => _HostState();
}

class _HostState extends State<Host> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: Stack(
              key: widget.viewportKey,
              children: <Widget>[
                q.QuillEditor(
                  controller: widget.controller,
                  focusNode: _focus,
                  scrollController: ScrollController(),
                  // 焦点必须**真的在正文里**：Tab 只在「人在写正文」时才算接受
                  // 建议（否则就是上面那条反例要修的行为）。这里用 autoFocus
                  // 起手把焦点放到编辑器上，省得每条用例都手动 requestFocus。
                  config: q.QuillEditorConfig(
                    editorKey: widget.editorKey,
                    autoFocus: true,
                  ),
                ),
                if (widget.other != null)
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Focus(
                      focusNode: widget.other,
                      child: const SizedBox(
                        key: ValueKey('other-field'),
                        width: 40,
                        height: 20,
                      ),
                    ),
                  ),
                AiGhostText(
                  controller: widget.controller,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  start: widget.start,
                  editorKey: widget.editorKey,
                  viewportKey: widget.viewportKey,
                  idleDelay: widget.idleDelay,
                ),
              ],
            ),
          ),
        ),
      );
}

/// 建一个文档，光标停在 [cursor]（默认末尾，即 `\n` 之前）。
q.QuillController doc(String plain, {int? cursor}) => q.QuillController(
      document: q.Document.fromJson([
        {'insert': plain},
      ]),
      selection: TextSelection.collapsed(
        offset: cursor ?? (plain.length - 1),
      ),
    );

void main() {
  testWidgets('总开关关着 → 停笔多久都不请求（默认就是关的）', (tester) async {
    final t = ManualTransport('建议');
    final controller = doc('这是一句已经写好的话\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: false,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(t.calls, 0);
    controller.dispose();
  });

  testWidgets('停笔一会儿 → 请求一次，幽灵文本出现', (tester) async {
    final t = ManualTransport('接下来该说时间了');
    final controller = doc('这是一句已经写好的话\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    expect(t.calls, 1);
    t.finish();
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-ghost')), findsOneWidget);
    expect(find.text('接下来该说时间了'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('Tab 接受 → 建议真的写进文档，浮层消失', (tester) async {
    final t = ManualTransport('接下来该说时间了');
    final controller = doc('这是一句已经写好的话\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    t.finish();
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-ghost')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(tester);
    expect(controller.document.toPlainText(), contains('接下来该说时间了'));
    expect(find.byKey(const ValueKey('ai-ghost')), findsNothing);
    controller.dispose();
  });

  testWidgets('焦点在别的输入框时 Tab 不该接受建议（不碰文档、也不吃 Tab）',
      (tester) async {
    final t = ManualTransport('接下来该说时间了');
    final controller = doc('这是一句已经写好的话\n');
    final other = FocusNode(debugLabel: 'other-field');
    addTearDown(other.dispose);
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
      other: other,
    ));
    await tester.pump(const Duration(milliseconds: 60));
    t.finish();
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-ghost')), findsOneWidget);

    // 人把焦点挪到「主题 / 收件人」那种框里了。建议还挂着，但此刻按 Tab
    // 语义是**切换焦点**，不是「接受续写」。
    other.requestFocus();
    await tester.pump();
    final p0 = FocusManager.instance.primaryFocus;
    expect(p0, other);
    final before = controller.document.toDelta().toJson();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(tester);
    // 文档一个字都没变。
    expect(controller.document.toDelta().toJson(), before);
    // Tab 没有被幽灵文本吃掉：它照样干了自己该干的事（焦点切走了）。
    // 修之前这里会是「建议被写进正文 + 焦点还停在 other」。
    expect(FocusManager.instance.primaryFocus, isNot(other));
    expect(other.hasFocus, isFalse);
    controller.dispose();
  });

  testWidgets('Tab 把建议插在**光标之后**，而不是别的地方', (tester) async {
    final t = ManualTransport('尾巴');
    // 光标在**第一行的行尾**（第 8 个字符之后、「这一行」的 \n 之前）。
    // 注意不能放在行中间 —— 那属于「光标后面还有字」，按规则根本不该请求
    // （见 `InlineContinuation.shouldRequest` 规则 3），测的就不是插入位置了。
    final controller = doc('这一行已经写好了\n第二行\n', cursor: 8);
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    t.finish();
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(tester);
    expect(controller.document.toPlainText(), startsWith('这一行已经写好了尾巴'));
    // 光标落在插入的文本之后。
    expect(controller.selection.extentOffset, 10);
    controller.dispose();
  });

  testWidgets('Tab 被吃掉，不会往正文里插一个制表符', (tester) async {
    final t = ManualTransport('建议');
    final controller = doc('这是一句已经写好的话\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    t.finish();
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(tester);
    expect(controller.document.toPlainText(), isNot(contains('\t')));
    controller.dispose();
  });

  testWidgets('Esc 丢弃 → 文档一个字都不变', (tester) async {
    final t = ManualTransport('不要这句');
    final controller = doc('这是一句已经写好的话\n');
    final before = controller.document.toPlainText();
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    t.finish();
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-ghost')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-ghost')), findsNothing);
    expect(controller.document.toPlainText(), before);
    controller.dispose();
  });

  testWidgets('光标一移动 → 建议立刻作废（不能让过期的建议还能被 Tab 接受）',
      (tester) async {
    final t = ManualTransport('过期的建议');
    final controller = doc('这是一句已经写好的话\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    t.finish();
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-ghost')), findsOneWidget);

    controller.updateSelection(
      const TextSelection.collapsed(offset: 1),
      q.ChangeSource.local,
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-ghost')), findsNothing);
    controller.dispose();
  });

  testWidgets('打字取消在飞的请求，停顿后按新上下文重新发一次', (tester) async {
    // 这一条钉的是本轮的要害：延续写现在每次都要把整封邮件发出去，用户在请求
    // 飞着的时候继续打字，旧答案一定过期。**只丢弃、不取消**的话钱白花、且新
    // 建议还得排在旧请求后面。修之前的行为是「生成中直接早退」—— 用户接着
    // 打字反而永远不会再发请求（`calls` 停在 1）。
    final t = ManualTransport('建议');
    final controller = doc('这是一句已经写好的话\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    expect(t.calls, 1);
    expect(t.cancelled, isFalse);

    // 请求还在飞的时候用户又敲了一下（controller 通知一次即可）。
    controller.updateSelection(controller.selection, q.ChangeSource.local);
    await tester.pump();
    expect(t.cancelled, isTrue, reason: '在飞的请求要被取消，不然钱白花');

    // 停了足够久 → 按新上下文重发一次。
    await tester.pump(const Duration(milliseconds: 60));
    expect(t.calls, 2);
    t.finish();
    await settle(tester);
    controller.dispose();
  });

  testWidgets('停顿够 idleDelay 才请求（打字过程中的停顿不发）', (tester) async {
    // 用一个明显大于默认值的 idleDelay：只推进一半不该发，推过才发。
    final t = ManualTransport('建议');
    final controller = doc('这是一句已经写好的话\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
      idleDelay: const Duration(milliseconds: 800),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(t.calls, 0, reason: '还没停够');
    await tester.pump(const Duration(milliseconds: 500));
    expect(t.calls, 1, reason: '停够了就该发');
    t.finish();
    await settle(tester);
    controller.dispose();
  });

  testWidgets('续写上下文用整封邮件 + 光标标记（不再只是光标前一段）', (tester) async {
    // 上下文怎么组装由 `ai_continuation_test.dart` 的 `build` 那一组纯逻辑
    // 用例钉住；这里只钉「页面接的是 `build(...).marked` 而不是别的」——
    // 用一个把 build 结果记下来的 start 回调，间接验证接线。
    final t = ManualTransport('建议');
    final controller = doc('这是一句已经写好的话\n另一段更靠后的内容\n');
    String? seen;
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () {
        seen = InlineContinuation.build(controller).marked;
        return startWith(t);
      },
    ));
    // 光标停在第一行行尾（第 10 个字符之后）。
    controller.updateSelection(
      const TextSelection.collapsed(offset: 10),
      q.ChangeSource.local,
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(seen, isNotNull);
    expect(seen, contains(InlineContinuation.marker));
    // 光标**后面**那一段同样在上下文里（旧的 context 只取光标前，这段会丢）。
    expect(seen, contains('另一段更靠后的内容'));
    t.finish();
    await settle(tester);
    controller.dispose();
  });

  testWidgets('出错 → 浮层安静地消失，不留一句红字打扰正在写字的人',
      (tester) async {
    final controller = doc('这是一句已经写好的话\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(_FailingTransport()),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-ghost')), findsNothing);
    expect(find.textContaining('401'), findsNothing);
    controller.dispose();
  });

  testWidgets('没配 Key（start 回 null）→ 什么都不发生，也不报错', (tester) async {
    final controller = doc('这是一句已经写好的话\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => null,
    ));
    await tester.pump(const Duration(milliseconds: 60));
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-ghost')), findsNothing);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('行太短就不请求（刚敲两三个字就弹建议是骚扰）', (tester) async {
    final t = ManualTransport('建议');
    // 当前行只有 3 个字（阈值是 8）。
    final controller = doc('短行\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(t.calls, 0);
    controller.dispose();
  });

  testWidgets('拆掉 widget 时把生成停掉（不能留着后台跑、白花钱）', (tester) async {
    final t = ManualTransport('建议');
    final controller = doc('这是一句已经写好的话\n');
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      enabled: true,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    expect(t.calls, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await settle(tester);
    expect(t.cancelled, isTrue);
    controller.dispose();
  });

  testWidgets('光标贴着视口底边时，灰字翻到光标**上方**且整条留在视口内', (tester) async {
    // 这是本轮的回归点。修之前的表现是「调用次数涨了，正文里什么都看不到」：
    // 编辑器总把光标滚进可见区，于是写到屏幕最后一行时光标下沿正好压在视口
    // 底边上，灰字从「光标下方」起画 —— 整条落在裁剪区外，被 `Stack` 剪掉。
    // 这里用一个高过视口的文档把光标顶到底边，再断言灰字的矩形**整个**在
    // 视口里（`Rect.contains` 对边界是闭的，所以贴边也算通过）。
    final t = ManualTransport('接下来该说时间了');
    final lines = List<String>.generate(40, (i) => '这是第 $i 行，写得挺长的了\n');
    final controller = doc(lines.join());
    final viewport = GlobalKey();
    await tester.pumpWidget(Host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: viewport,
      enabled: true,
      start: () => startWith(t),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    t.finish();
    await settle(tester);

    final ghost = find.byKey(const ValueKey('ai-ghost'));
    expect(ghost, findsOneWidget, reason: '灰字得真的画出来');
    final viewportRect = tester.getRect(find.byKey(viewport));
    final ghostRect = tester.getRect(ghost);
    expect(
      viewportRect.contains(ghostRect.topLeft) &&
          viewportRect.contains(ghostRect.bottomRight),
      isTrue,
      reason: '灰字整条要在视口里：viewport=$viewportRect ghost=$ghostRect',
    );
    controller.dispose();
  });
}

class _FailingTransport implements AiTransport {
  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async {
    throw AiTransportException('invalid api key', statusCode: 401);
  }

  @override
  Future<String> request({
    required String method,
    required String url,
    required Map<String, String> headers,
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  }) async =>
      throw UnimplementedError('这个假传输只用来测流式');
}
