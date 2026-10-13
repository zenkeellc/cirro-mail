import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/preflight.dart';
import 'package:mail_app/features/compose/ai/ai_preflight_sheet.dart';

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
    onChunk(
      'data: {"choices":[{"delta":{"content":"${reply.replaceAll('\n', r'\n')}"}}]}\n\n',
    );
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

Future<PreflightDecision? Function()> openPreflight(
  WidgetTester tester, {
  required List<PreflightFinding> local,
  AiTransport? transport,
  Future<void> Function()? afterOpen,
}) async {
  PreflightDecision? decision;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            decision = await showModalBottomSheet<PreflightDecision>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AiPreflightSheet(
                local: local,
                startReview: transport == null
                    ? null
                    : () => startWith(transport),
              ),
            );
          },
          child: const Text('发送'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('发送'));
  await settle(tester);
  if (afterOpen != null) await afterOpen();
  return () => decision;
}

const noAttachment = PreflightFinding(
  severity: PreflightSeverity.warning,
  message: '正文里提到了附件，但这一封没有附件',
);
const emptySubject = PreflightFinding(
  severity: PreflightSeverity.warning,
  message: '主题是空的',
);

void main() {
  testWidgets('本地那几条直接显示出来（没配 Key 的用户也能看到）', (tester) async {
    await openPreflight(tester, local: const [noAttachment, emptySubject]);
    expect(find.text('正文里提到了附件，但这一封没有附件'), findsOneWidget);
    expect(find.text('主题是空的'), findsOneWidget);
  });

  testWidgets('本地没发现问题 → 明说「没有发现问题」，不留空白', (tester) async {
    await openPreflight(tester, local: const []);
    expect(find.byKey(const ValueKey('preflight-local-clean')), findsOneWidget);
  });

  testWidgets('没配 Key（startReview 是 null）→ AI 那一段整个不显示', (tester) async {
    await openPreflight(tester, local: const []);
    expect(find.text('AI 建议'), findsNothing);
    expect(find.byKey(const ValueKey('preflight-ask-ai')), findsNothing);
  });

  testWidgets('**不自动**跑模型检查（每次点发送都自动花钱是不可接受的）',
      (tester) async {
    final t = ManualTransport('第一条建议');
    await openPreflight(tester, local: const [], transport: t);
    expect(t.calls, 0, reason: '打开面板本身不该发请求');
    expect(find.byKey(const ValueKey('preflight-ask-ai')), findsOneWidget);
  });

  testWidgets('点「让 AI 再看看」→ 发一次请求，结果一行一条列出来', (tester) async {
    final t = ManualTransport('「截止日期」写成了「截至日期」\n结尾的语气偏随意');
    await openPreflight(tester, local: const [], transport: t);
    await tester.tap(find.byKey(const ValueKey('preflight-ask-ai')));
    await settle(tester);
    expect(t.calls, 1);
    t.finish();
    await settle(tester);

    expect(find.text('「截止日期」写成了「截至日期」'), findsOneWidget);
    expect(find.text('结尾的语气偏随意'), findsOneWidget);
  });

  testWidgets('模型没问题（回「没有问题」）→ 明说「AI 也没看出问题」', (tester) async {
    final t = ManualTransport('没有问题');
    await openPreflight(tester, local: const [], transport: t);
    await tester.tap(find.byKey(const ValueKey('preflight-ask-ai')));
    await settle(tester);
    t.finish();
    await settle(tester);
    expect(find.byKey(const ValueKey('preflight-ai-clean')), findsOneWidget);
  });

  testWidgets('模型检查出错 → 显示原因，且不让「AI 也没看出问题」跟着冒出来',
      (tester) async {
    await openPreflight(
      tester,
      local: const [],
      transport: _FailingTransport(),
      afterOpen: () async {
        await tester.tap(find.byKey(const ValueKey('preflight-ask-ai')));
        await settle(tester);
      },
    );
    expect(find.textContaining('401'), findsOneWidget);
    expect(find.byKey(const ValueKey('preflight-ai-clean')), findsNothing);
  });

  testWidgets('本地有发现时，「仍然发送」照样可点（检查不拦人）', (tester) async {
    final read = await openPreflight(
      tester,
      local: const [noAttachment, emptySubject],
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('preflight-send')),
    );
    expect(button.onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('preflight-send')));
    await settle(tester);
    expect(read(), PreflightDecision.sendAnyway);
  });

  testWidgets('「返回修改」带回 backToEdit', (tester) async {
    final read = await openPreflight(tester, local: const [noAttachment]);
    await tester.tap(find.byKey(const ValueKey('preflight-back')));
    await settle(tester);
    expect(read(), PreflightDecision.backToEdit);
  });

  testWidgets('两条文案相同的本地发现都要显示（不能被 key 撞掉一条）',
      (tester) async {
    const dup = PreflightSeverity.warning;
    await openPreflight(tester, local: const [
      PreflightFinding(severity: dup, message: '同一条'),
      PreflightFinding(severity: dup, message: '同一条'),
    ]);
    expect(find.text('同一条'), findsNWidgets(2));
  });

  testWidgets('关掉面板 → 模型检查被取消（不能留着后台跑、白花钱）', (tester) async {
    final t = ManualTransport('建议');
    await openPreflight(
      tester,
      local: const [],
      transport: t,
      afterOpen: () async {
        await tester.tap(find.byKey(const ValueKey('preflight-ask-ai')));
        await settle(tester);
      },
    );
    Navigator.of(tester.element(find.byType(AiPreflightSheet))).pop();
    await settle(tester);
    expect(t.cancelled, isTrue);
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
