// 这份测试是计划 D13 逐字给的：`ai_service` 这个 import 在原文里（用到
// `AiStarted`）。文件级关掉「未使用 import」这条风格 lint，只为逐字保留原文。
// ignore_for_file: unused_import

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/compose/ai/ai_draft_sheet.dart';

/// 受控的假生成：`finish()` 放行（理由见 D12 的验收要点 —— 不能用带定时器的
/// 轮询，否则 `pumpAndSettle` 永远等不到静止）。
class ManualTransport implements AiTransport {
  ManualTransport([this.reply = '草稿正文']);

  final String reply;
  final Completer<void> _gate = Completer<void>();
  bool cancelled = false;

  void finish() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async {
    onChunk('data: {"choices":[{"delta":{"content":"$reply"}}]}\n\n');
    await Future.any(<Future<void>>[
      _gate.future,
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

/// 点开起草面板。返回**读结果**的函数（结果要等面板 pop 之后才拿得到）。
Future<String? Function()> openDraft(
  WidgetTester tester, {
  required AiTransport transport,
  String? subject,
  void Function(DraftRequest request)? onStart,
}) async {
  String? inserted;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            inserted = await showModalBottomSheet<String>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AiDraftSheet(
                subject: subject,
                start: (request) {
                  onStart?.call(request);
                  return startWith(transport);
                },
              ),
            );
          },
          child: const Text('起草'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('起草'));
  await settle(tester);
  return () => inserted;
}

void main() {
  testWidgets('刚打开：不转圈、不给插入（用户连要点都还没填）', (tester) async {
    await openDraft(tester, transport: ManualTransport());
    expect(find.byKey(const ValueKey('draft-points')), findsOneWidget);
    expect(find.byKey(const ValueKey('draft-insert')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 要点为空 → 生成按钮不可点。
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('draft-generate')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('填了要点 → 生成按钮变成可点', (tester) async {
    await openDraft(tester, transport: ManualTransport());
    await tester.enterText(find.byKey(const ValueKey('draft-points')), '周四评审顺延');
    await settle(tester);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('draft-generate')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('空白要点（只有空格）不算填了', (tester) async {
    await openDraft(tester, transport: ManualTransport());
    await tester.enterText(find.byKey(const ValueKey('draft-points')), '   ');
    await settle(tester);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('draft-generate')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('点生成 → 出结果 → 插入正文，把文本带回去', (tester) async {
    final t = ManualTransport('周四的评审顺延到下周');
    final read = await openDraft(tester, transport: t);
    await tester.enterText(find.byKey(const ValueKey('draft-points')), '周四评审顺延');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('draft-generate')));
    await settle(tester);
    t.finish();
    await settle(tester);

    expect(find.text('周四的评审顺延到下周'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('draft-insert')));
    await settle(tester);
    expect(read(), '周四的评审顺延到下周');
  });

  testWidgets('生成中 → 不给插入（半截正文插进去比不插糟）', (tester) async {
    await openDraft(tester, transport: ManualTransport());
    await tester.enterText(find.byKey(const ValueKey('draft-points')), '要点');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('draft-generate')));
    await settle(tester);
    // 已经出字了，但还没跑完。
    final insert = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('draft-insert')),
    );
    expect(insert.onPressed, isNull);
    // 生成中「生成」也不该再点一下（那会同时跑两次）。
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('draft-generate')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('语气与篇幅都进请求；没主题时 useSubject 是 false', (tester) async {
    final requests = <DraftRequest>[];
    final t = ManualTransport();
    await openDraft(tester, transport: t, onStart: requests.add);
    await tester.enterText(find.byKey(const ValueKey('draft-points')), '要点');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('tone-formal')));
    await tester.tap(find.byKey(const ValueKey('length-short')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('draft-generate')));
    await settle(tester);

    expect(requests.single.tone, RewriteTone.formal);
    expect(requests.single.length, DraftLength.short);
    expect(requests.single.points, '要点');
    expect(requests.single.useSubject, isFalse, reason: '没有主题可给');
    t.finish();
    await settle(tester);
  });

  testWidgets('有主题且勾着 → useSubject 是 true；取消勾选 → false',
      (tester) async {
    final requests = <DraftRequest>[];
    final t = ManualTransport();
    await openDraft(tester, transport: t, subject: '评审时间变更',
        onStart: requests.add);
    await tester.enterText(find.byKey(const ValueKey('draft-points')), '要点');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('draft-generate')));
    await settle(tester);
    expect(requests.last.useSubject, isTrue);

    // 先让这一轮跑完 —— 生成中「重新生成」是不可点的（那条规矩在下面单测里）。
    t.finish();
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('draft-use-subject')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-retry')));
    await settle(tester);
    expect(requests.last.useSubject, isFalse);
    t.finish();
    await settle(tester);
  });

  testWidgets('生成中「重新生成」不可点（否则会同时跑两次、白花钱）',
      (tester) async {
    final t = ManualTransport();
    await openDraft(tester, transport: t);
    await tester.enterText(find.byKey(const ValueKey('draft-points')), '要点');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('draft-generate')));
    await settle(tester);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('ai-retry')))
          .onPressed,
      isNull,
    );
    t.finish();
    await settle(tester);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('ai-retry')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('没有主题时，那个勾选框根本不显示（不给一句空话）', (tester) async {
    await openDraft(tester, transport: ManualTransport());
    expect(find.byKey(const ValueKey('draft-use-subject')), findsNothing);
  });

  testWidgets('重新生成会清掉上一次的错误', (tester) async {
    var failing = true;
    final requests = <DraftRequest>[];
    final good = ManualTransport('成功的草稿');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showModalBottomSheet<String>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AiDraftSheet(
                start: (request) {
                  requests.add(request);
                  return startWith(failing ? _FailingTransport() : good);
                },
              ),
            ),
            child: const Text('起草'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('起草'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('draft-points')), '要点');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('draft-generate')));
    await settle(tester);
    expect(find.textContaining('401'), findsOneWidget);

    failing = false;
    await tester.tap(find.byKey(const ValueKey('ai-retry')));
    await settle(tester);
    good.finish();
    await settle(tester);
    expect(find.textContaining('401'), findsNothing);
    expect(find.text('成功的草稿'), findsOneWidget);
  });

  testWidgets('关掉面板 → 生成被取消（不能留着后台跑、白花钱）', (tester) async {
    final t = ManualTransport();
    await openDraft(tester, transport: t);
    await tester.enterText(find.byKey(const ValueKey('draft-points')), '要点');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('draft-generate')));
    await settle(tester);

    Navigator.of(tester.element(find.byType(AiDraftSheet))).pop();
    await settle(tester);
    expect(t.cancelled, isTrue);
  });

  testWidgets('生成结果很长时不把面板顶爆（有高度上限、可滚）', (tester) async {
    final long = '这是一段很长的草稿正文。' * 80;
    final t = ManualTransport(long);
    await openDraft(tester, transport: t);
    await tester.enterText(find.byKey(const ValueKey('draft-points')), '要点');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('draft-generate')));
    await settle(tester);
    t.finish();
    await settle(tester);
    // 「插入正文」必须还在屏幕里 —— 用户看到了满意的结果却按不到按钮，
    // 是这一条最容易出的问题。
    final box = tester.getRect(find.byKey(const ValueKey('draft-insert')));
    final screen = tester.getRect(find.byType(MaterialApp));
    expect(box.bottom, lessThanOrEqualTo(screen.bottom));
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
