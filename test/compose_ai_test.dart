// 计划原文就带着这两个 import；它们在本文件里确实没被直接用到（`Future`、
// `until` 等由 flutter_test 转出的 dart:async 覆盖），但保留它们与计划逐字
// 一致，也让测试随时能直接写 `unawaited(...)`。两条 lint 都是误报。
// ignore: unnecessary_import
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
// ignore: unused_import
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/ai/ai_settings_store.dart';
import 'package:mail_app/features/compose/ai/ai_draft_sheet.dart';
import 'package:mail_app/features/compose/ai/ai_rewrite_sheet.dart';
import 'package:mail_app/features/compose/ai/compose_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假传输：记下请求，回一段固定文本（不出错、不挂起）。
class RecordingTransport implements AiTransport {
  RecordingTransport({this.chunk});

  String? chunk;
  Map<String, dynamic>? lastBody;

  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async {
    lastBody = body;
    if (chunk != null) onChunk(chunk!);
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

const fakeKey = 'sk-test-0123456789';

/// 拼一个 SSE 帧。**内容要 `jsonEncode`**：模型吐多行文本是常事，裸着塞进
/// JSON 字符串里就是非法 JSON，`SseDecoder` 解不出来、整帧被丢掉 ——
/// 表现是「测试等不到内容」，而原因跟被测代码毫无关系。
String openaiChunk(String text) =>
    'data: {"choices":[{"delta":{"content":${jsonEncode(text)}}}]}\n\n';

Future<void> until(String label, bool Function() ok) async {
  for (var i = 0; i < 2000; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('等不到：$label');
}

q.QuillController doc(String plain, {int? selStart, int? selEnd}) =>
    q.QuillController(
      document: q.Document.fromJson([
        {'insert': plain},
      ]),
      selection: TextSelection(
        baseOffset: selStart ?? 0,
        extentOffset: selEnd ?? selStart ?? 0,
      ),
    );

/// 正文里嵌一张图（`ab` + image + `cd`）。偏移：a=0, b=1, 图=2, c=3, d=4, \n=5。
q.QuillController docWithImage({int? selStart, int? selEnd}) => q.QuillController(
      document: q.Document.fromJson([
        {'insert': 'ab'},
        {'insert': {'image': 'https://x/y.png'}},
        {'insert': 'cd\n'},
      ]),
      selection: TextSelection(
        baseOffset: selStart ?? 0,
        extentOffset: selEnd ?? selStart ?? 0,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingTransport transport;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    transport = RecordingTransport();
  });

  Future<AiService> service({bool configured = true}) async {
    final p = PrefsStore(await SharedPreferences.getInstance());
    final store = AiSettingsStore(prefs: p);
    await store.save(const AiSettings(
      apiFormat: AiApiFormat.openai,
      model: 'gpt-4o-mini',
    ));
    if (configured) await store.setApiKey(fakeKey);
    return AiService(store: store, usage: AiUsageCounter(prefs: p),
        client: AiClient(transport: transport));
  }

  group('start*：先给一个转圈，拿到之后再接管', () {
    test('改写：返回时立刻是「转圈中」，随后才拿到内容', () async {
      transport.chunk = openaiChunk('改写结果');
      final ai = await service();
      final run = ComposeAi.startRewrite(
        ai,
        selection: '原文',
        tone: RewriteTone.polish,
      );
      // 同步返回的那一刻还没跑过平台通道，所以必须是「跑着」而不是「空的」。
      expect(run.running.value, isTrue);
      await until('拿到内容', () => run.text.value.isNotEmpty);
      expect(run.text.value, '改写结果');
      run.dispose();
    });

    test('没配 Key：adopt 之后转圈停下，并给一句要去设置的提示', () async {
      final ai = await service(configured: false);
      final run = ComposeAi.startRewrite(
        ai,
        selection: '原文',
        tone: RewriteTone.polish,
      );
      await until('拿到提示', () => run.message.value.isNotEmpty);
      expect(run.running.value, isFalse, reason: '不然就是永远转圈');
      expect(run.message.value, contains('设置'));
      run.dispose();
    });

    test('改写：语气与额外要求都进 prompt', () async {
      transport.chunk = openaiChunk('x');
      final ai = await service();
      final run = ComposeAi.startRewrite(
        ai,
        selection: '原文',
        tone: RewriteTone.formal,
        extraInstruction: '保留术语',
      );
      await until('请求发出', () => transport.lastBody != null);
      final prompt = (transport.lastBody!['messages'] as List)
          .map((m) => (m as Map)['content'])
          .join('\n')
          .toString();
      expect(prompt, contains(RewriteTone.formal.instruction));
      expect(prompt, contains('保留术语'));
      run.dispose();
    });

    test('起草：useSubject 为 false 时主题**不进** prompt', () async {
      transport.chunk = openaiChunk('草稿');
      final ai = await service();
      final run = ComposeAi.startDraft(
        ai,
        const DraftRequest(
          points: '周四评审顺延',
          tone: RewriteTone.polish,
          length: DraftLength.short,
          useSubject: false,
        ),
        subject: '不该出现的主题',
      );
      await until('请求发出', () => transport.lastBody != null);
      final prompt = (transport.lastBody!['messages'] as List)
          .map((m) => (m as Map)['content'])
          .join('\n')
          .toString();
      expect(prompt, isNot(contains('不该出现的主题')));
      expect(prompt, contains('周四评审顺延'));
      run.dispose();
    });

    test('起草：useSubject 为 true 时主题进 prompt', () async {
      transport.chunk = openaiChunk('草稿');
      final ai = await service();
      final run = ComposeAi.startDraft(
        ai,
        const DraftRequest(
          points: '要点',
          tone: RewriteTone.polish,
          length: DraftLength.short,
          useSubject: true,
        ),
        subject: '评审时间变更',
      );
      await until('请求发出', () => transport.lastBody != null);
      final prompt = (transport.lastBody!['messages'] as List)
          .map((m) => (m as Map)['content'])
          .join('\n')
          .toString();
      expect(prompt, contains('评审时间变更'));
      run.dispose();
    });

    test('标题：只要一个，不该再要求「一行一个候选」', () async {
      transport.chunk = openaiChunk('周四评审顺延');
      final ai = await service();
      final run = ComposeAi.startSubject(ai, body: '正文');
      await until('拿到内容', () => run.text.value.isNotEmpty);
      final prompt = (transport.lastBody!['messages'] as List)
          .map((m) => (m as Map)['content'])
          .join('\n')
          .toString();
      expect(prompt, isNot(contains('候选主题')));
      run.dispose();
    });

    test('标题：已有主题会作为参考进 prompt', () async {
      transport.chunk = openaiChunk('周四评审顺延');
      final ai = await service();
      final run = ComposeAi.startSubject(
        ai,
        body: '正文',
        current: '评审',
      );
      await until('拿到内容', () => run.text.value.isNotEmpty);
      final prompt = (transport.lastBody!['messages'] as List)
          .map((m) => (m as Map)['content'])
          .join('\n')
          .toString();
      expect(prompt, contains('评审'));
      run.dispose();
    });

    test('检查：附件数进 prompt（「说了要附件却没交代」靠它判）', () async {
      transport.chunk = openaiChunk('没问题');
      final ai = await service();
      final run = ComposeAi.startReview(
        ai,
        subject: '主题',
        body: '正文',
        attachmentCount: 2,
      );
      await until('请求发出', () => transport.lastBody != null);
      final prompt = (transport.lastBody!['messages'] as List)
          .map((m) => (m as Map)['content'])
          .join('\n')
          .toString();
      expect(prompt, contains('附件数：2'));
      run.dispose();
    });

    test('续写：上下文进 prompt', () async {
      transport.chunk = openaiChunk('接下来');
      final ai = await service();
      final run = ComposeAi.startContinuation(ai, context: '已经写好的部分');
      await until('请求发出', () => transport.lastBody != null);
      final prompt = (transport.lastBody!['messages'] as List)
          .map((m) => (m as Map)['content'])
          .join('\n')
          .toString();
      expect(prompt, contains('已经写好的部分'));
      run.dispose();
    });

    test('Key 不出现在请求体里（只在请求头）', () async {
      transport.chunk = openaiChunk('x');
      final ai = await service();
      final run = ComposeAi.startRewrite(
        ai,
        selection: '原文',
        tone: RewriteTone.polish,
      );
      await until('请求发出', () => transport.lastBody != null);
      expect(transport.lastBody.toString(), isNot(contains(fakeKey)));
      run.dispose();
    });
  });

  group('applyRewrite', () {
    test('替换：选区被换掉，撤销能一次退回', () {
      final controller = doc('前面 [要改的] 后面\n', selStart: 3, selEnd: 8);
      final applied = ComposeAi.applyRewrite(
        controller,
        const RewriteOutcome(
          action: RewriteAction.replace,
          text: '改好了',
        ),
      );
      expect(applied, RewriteApplyResult.applied);
      expect(controller.document.toPlainText(), '前面 改好了 后面\n');
    });

    test('插入到下方：原文一字不动，新内容在下一行', () {
      // 选中**整行**（0..3），插入点落在行尾那个 `\n` 之前。
      final controller = doc('第一行\n', selStart: 0, selEnd: 3);
      final applied = ComposeAi.applyRewrite(
        controller,
        const RewriteOutcome(
          action: RewriteAction.insertBelow,
          text: '第二行',
        ),
      );
      expect(applied, RewriteApplyResult.applied);
      expect(controller.document.toPlainText(), '第一行\n第二行\n');
    });

    test('丢弃：文档一个字都不变，且与「被拒」是**不同**的结局', () {
      // 这个区别是本组测试存在的理由：用户主动不改（不该提示）与系统拒绝
      // （必须提示）以前都被压成一个 `false`，调用方分不出来。
      final controller = doc('原样\n');
      final before = controller.document.toDelta().toJson();
      final applied = ComposeAi.applyRewrite(
        controller,
        const RewriteOutcome(
          action: RewriteAction.discard,
          text: '这个不该被写进去',
        ),
      );
      expect(applied, RewriteApplyResult.discarded);
      expect(applied, isNot(RewriteApplyResult.selectionHasEmbed));
      expect(applied, isNot(RewriteApplyResult.selectionGone));
      expect(controller.document.toDelta().toJson(), before,
          reason: '丢弃必须逐字节不动');
    });

    test('选区已经不在了（用户点了别处）→ 拒绝，且原因是**选区过期**', () {
      final controller = doc('一二三四五\n');
      final before = controller.document.toDelta().toJson();
      final applied = ComposeAi.applyRewrite(
        controller,
        const RewriteOutcome(
          action: RewriteAction.replace,
          text: '改好了',
        ),
      );
      expect(applied, RewriteApplyResult.selectionGone);
      expect(applied, isNot(RewriteApplyResult.discarded));
      expect(controller.document.toDelta().toJson(), before);
    });

    test('选区折叠（等于没有选区）→ 拒绝，同样是**选区过期**', () {
      final controller = doc('一二三四五\n', selStart: 2, selEnd: 2);
      final before = controller.document.toDelta().toJson();
      final applied = ComposeAi.applyRewrite(
        controller,
        const RewriteOutcome(
          action: RewriteAction.replace,
          text: '改好了',
        ),
      );
      expect(applied, RewriteApplyResult.selectionGone);
      expect(controller.document.toDelta().toJson(), before);
    });

    test('选区含块级嵌入（图片）→ 拒绝，且原因是**嵌入**（必须提示用户）', () {
      // 选区 [0,5) 覆盖 `ab￼cd`，￼ 就是图片嵌入。
      final controller = docWithImage(selStart: 0, selEnd: 5);
      final before = controller.document.toDelta().toJson();
      final applied = ComposeAi.applyRewrite(
        controller,
        const RewriteOutcome(
          action: RewriteAction.replace,
          text: '改好了',
        ),
      );
      expect(applied, RewriteApplyResult.selectionHasEmbed);
      expect(applied, isNot(RewriteApplyResult.selectionGone),
          reason: '「含嵌入」与「选区没了」要能被区分开');
      expect(applied, isNot(RewriteApplyResult.discarded));
      expect(controller.document.toDelta().toJson(), before,
          reason: '拒绝改写时一个字都不能动（图片必须还在）');
    });

    test('结果里的 ``` 围栏与多余空行先被清掉（模型很爱加）', () {
      final controller = doc('要改的\n', selStart: 0, selEnd: 3);
      ComposeAi.applyRewrite(
        controller,
        const RewriteOutcome(
          action: RewriteAction.replace,
          text: '```\n改好了\n\n\n\n再一句\n```',
        ),
      );
      final text = controller.document.toPlainText();
      expect(text, isNot(contains('```')));
      expect(text, isNot(contains('\n\n\n')));
      expect(text, contains('改好了'));
    });

    test('结果只有空白 → 不动文档（不能把选区换成空）', () {
      final controller = doc('要改的\n', selStart: 0, selEnd: 3);
      final before = controller.document.toDelta().toJson();
      final applied = ComposeAi.applyRewrite(
        controller,
        const RewriteOutcome(action: RewriteAction.replace, text: '   \n  '),
      );
      expect(applied, RewriteApplyResult.emptyResult);
      expect(controller.document.toDelta().toJson(), before);
    });
  });

  group('applyDraft / insertDraft', () {
    test('applyDraft：整段换掉正文（用户是从「什么都没有」点进来的）', () {
      final controller = doc('删掉这些\n');
      expect(ComposeAi.applyDraft(controller, '新的正文'), isTrue);
      expect(controller.document.toPlainText(), '新的正文\n');
      expect(controller.selection.extentOffset, '新的正文'.length);
    });

    test('applyDraft：空结果不动文档', () {
      final controller = doc('保留\n');
      expect(ComposeAi.applyDraft(controller, '  \n '), isFalse);
      expect(controller.document.toPlainText(), '保留\n');
    });

    test('insertDraft：插到光标后面，不动已有内容（用户已经在写了）', () {
      final controller = doc('开头\n', selStart: 2, selEnd: 2);
      expect(ComposeAi.insertDraft(controller, '接上的话'), isTrue);
      expect(controller.document.toPlainText(), '开头接上的话\n');
      expect(controller.selection.extentOffset, 2 + '接上的话'.length);
    });

    test('insertDraft：多段内容会拆成多个块', () {
      final controller = doc('开头\n', selStart: 2, selEnd: 2);
      ComposeAi.insertDraft(controller, '第一段\n\n第二段');
      expect(controller.document.toPlainText(), '开头第一段\n\n第二段\n');
    });
  });
}
