// 这份测试是计划 D12 逐字给的：两个 import（`ai_prompts` / `ai_service`）与
// 三处 `(_, __)` 的多下划线写法都在原文里。为了「逐字照抄」而不改语义，这里
// 文件级关掉这两条 lint（它们只是风格提示，去掉反而偏离计划原文）。
// ignore_for_file: unused_import
// ignore_for_file: unnecessary_underscores

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/compose/ai/ai_rewrite_sheet.dart';

/// 一个受控的假生成：测试决定什么时候放行。
///
/// **不用「1 毫秒轮询等标志位」**：那会让 `pumpAndSettle` 永远等不到静止
/// （每帧都有新的定时器排上），测试表现是 `pumpAndSettle timed out`。
/// 用一个 Completer 让测试显式放行，挂起的 Future 不带定时器，pumpAndSettle
/// 就能正常收敛。
class ManualTransport implements AiTransport {
  final List<String> chunks = <String>[];
  final Completer<void> _gate = Completer<void>();
  bool cancelled = false;

  /// 发过几次请求。用来钉「打开面板不发请求」这条本轮的要害。
  var calls = 0;

  /// 放行：simulate 服务端把这次响应写完。
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
    calls++;
    for (final c in chunks) {
      if (cancelToken.isCancelled) {
        cancelled = true;
        throw const AiCancelledException();
      }
      onChunk(c);
    }
    // 卡在这儿直到「放行」或「取消」。
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

String chunk(String text) =>
    'data: {"choices":[{"delta":{"content":"$text"}}]}\n\n';

/// 推进若干帧。**不能用 `pumpAndSettle`**：面板里跑着转圈
/// （`CircularProgressIndicator` 是永不结束的动画），`pumpAndSettle` 会一直
/// 等它静止 —— 表现是 `pumpAndSettle timed out`，而不是某个断言失败。
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
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

/// 把面板挂到一个按钮上，点开，返回一个**读结果**的函数。
///
/// 为什么不直接返回 `RewriteOutcome?`：面板关掉（`pop`）之后 `await
/// showModalBottomSheet` 才带着结果回来，而 `openSheet` 在点开之后就要把控制权
/// 交回测试 —— 那时结果还是 null。返回一个读函数，测试在点完按钮再读。
Future<RewriteOutcome? Function()> openSheet(
  WidgetTester tester, {
  required AiTransport transport,
  String original = '我们明天开会',
  List<String>? tones,
}) async {
  RewriteOutcome? outcome;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            outcome = await showModalBottomSheet<RewriteOutcome>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AiRewriteSheet(
                original: original,
                start: (tone, extra) {
                  tones?.add(tone.name);
                  return startWith(transport);
                },
              ),
            );
          },
          child: const Text('改写'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('改写'));
  await settle(tester);
  return () => outcome;
}

/// 点面板里的「生成」。**打开面板本身不再发请求**（本轮改的正是这个），
/// 于是每条「期待有请求」的用例都要先过这一下。
Future<void> generate(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('rewrite-generate')));
  await settle(tester);
}

void main() {
  testWidgets('打开面板不发请求（用户要先选语气、点生成才花钱）', (tester) async {
    final t = ManualTransport()..chunks.add(chunk('改写中'));
    await openSheet(tester, transport: t);
    // 面板刚打开：一个字都还没生成过，只给「生成」。
    expect(t.calls, 0, reason: '打开面板是免费的，点生成才发请求');
    expect(find.byKey(const ValueKey('rewrite-generate')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-retry')), findsNothing);
    await generate(tester);
    expect(t.calls, 1);
    t.finish();
    await settle(tester);
  });

  testWidgets('面板里看得到原文（用户要能对照）', (tester) async {
    final t = ManualTransport();
    await openSheet(tester, transport: t, original: '这段话要改');
    expect(find.byKey(const ValueKey('ai-original')), findsOneWidget);
    expect(find.text('这段话要改'), findsOneWidget);
    t.finish();
    await settle(tester);
  });

  testWidgets('还没出字 → 三个动作按钮都不给点（半截结果换成残句更糟）',
      (tester) async {
    final t = ManualTransport();
    await openSheet(tester, transport: t);
    await generate(tester);
    expect(find.byKey(const ValueKey('ai-replace')), findsNothing);
    expect(find.byKey(const ValueKey('ai-insert-below')), findsNothing);
    // 生成中给的是「重新生成」（此时不可点）。
    expect(find.byKey(const ValueKey('ai-retry')), findsOneWidget);
    t.finish();
    await settle(tester);
  });

  testWidgets('生成中 → 有停止按钮；停完按「拿到多少算多少」把半截留下',
      (tester) async {
    final t = ManualTransport()..chunks.add(chunk('改写中'));
    await openSheet(tester, transport: t);
    await generate(tester);
    await tester.pump();
    expect(find.byKey(const ValueKey('ai-stop')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-stop')));
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-stop')), findsNothing);
    // 半截文本留在面板里（`AiRun.stop` 的承诺），于是三个动作照给 ——
    // 用户看得见它停在哪里，自己决定要不要用。**出错**才是真的不给（下一条）。
    expect(find.textContaining('改写中'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-replace')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-retry')), findsOneWidget);
  });

  testWidgets('生成完 → 三个按钮出现；点「替换」返回替换意图与文本',
      (tester) async {
    final t = ManualTransport()..chunks.add(chunk('明天的会'));
    final read = await openSheet(tester, transport: t);
    await generate(tester);
    t.finish();
    await settle(tester);

    expect(find.text('明天的会'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-insert-below')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-discard')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-replace')));
    await settle(tester);
    expect(read()!.action, RewriteAction.replace);
    expect(read()!.text, '明天的会');
  });

  testWidgets('「替换」带回的文本就是用户看到的那份', (tester) async {
    final t = ManualTransport()..chunks.add(chunk('明天的会'));
    RewriteOutcome? outcome;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              outcome = await showModalBottomSheet<RewriteOutcome>(
                context: context,
                isScrollControlled: true,
                builder: (_) => AiRewriteSheet(
                  original: '我们明天开会',
                  start: (_, __) => startWith(t),
                ),
              );
            },
            child: const Text('改写'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('改写'));
    await settle(tester);
    await generate(tester);
    t.finish();
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('ai-replace')));
    await settle(tester);
    expect(outcome!.action, RewriteAction.replace);
    expect(outcome!.text, '明天的会');
  });

  testWidgets('出错 → 显示原因，且**不给**替换（只给重新生成）', (tester) async {
    await openSheet(tester, transport: _FailingTransport());
    await generate(tester);
    await settle(tester);
    expect(find.textContaining('401'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-replace')), findsNothing);
    expect(find.byKey(const ValueKey('ai-stop')), findsNothing);
  });

  testWidgets('换语气：换 chip 不发请求，点生成才用新语气发一次', (tester) async {
    final t = ManualTransport()..chunks.add(chunk('x'));
    final tones = <String>[];
    await openSheet(tester, transport: t, tones: tones);
    expect(tones, isEmpty, reason: '面板打开只是摆好了 chip，还没发');

    await tester.tap(find.byKey(const ValueKey('tone-formal')));
    await settle(tester);
    expect(tones, isEmpty, reason: '换 chip 只是改选中态，不该发请求');

    await generate(tester);
    expect(tones, ['formal'], reason: '点生成才发，且用的是新选中的语气');
    t.finish();
    await settle(tester);
  });

  testWidgets('重新生成会清掉上一次的错误（否则用户一按还是看到旧的红字）',
      (tester) async {
    var failing = true;
    final good = ManualTransport()..chunks.add(chunk('好的结果'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showModalBottomSheet<RewriteOutcome>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AiRewriteSheet(
                original: '原文',
                start: (_, __) =>
                    startWith(failing ? _FailingTransport() : good),
              ),
            ),
            child: const Text('改写'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('改写'));
    await settle(tester);
    await generate(tester);
    await settle(tester);
    expect(find.textContaining('401'), findsOneWidget);

    failing = false;
    await tester.tap(find.byKey(const ValueKey('ai-retry')));
    await settle(tester);
    good.finish();
    await settle(tester);
    expect(find.textContaining('401'), findsNothing);
    expect(find.text('好的结果'), findsOneWidget);
  });

  testWidgets('「额外要求」默认收起，展开后能填，并且下一次生成带上它',
      (tester) async {
    final t = ManualTransport()..chunks.add(chunk('x'));
    final extras = <String?>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showModalBottomSheet<RewriteOutcome>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AiRewriteSheet(
                original: '原文',
                start: (_, extra) {
                  extras.add(extra);
                  return startWith(t);
                },
              ),
            ),
            child: const Text('改写'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('改写'));
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-extra')), findsNothing,
        reason: '默认收起');

    await tester.tap(find.byKey(const ValueKey('ai-extra-toggle')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('ai-extra')), '保留术语');
    await generate(tester);
    expect(extras, ['保留术语'], reason: '首次生成就该带上填好的额外要求');
    t.finish();
    await settle(tester);
  });

  testWidgets('丢弃 → 返回丢弃意图，文本照带（调用方可以选择忽略）',
      (tester) async {
    final t = ManualTransport()..chunks.add(chunk('建议'));
    final read = await openSheet(tester, transport: t);
    await generate(tester);
    t.finish();
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-discard')));
    await settle(tester);
    expect(read()!.action, RewriteAction.discard);
  });

  testWidgets('面板关掉时把生成停掉（不能留着后台跑、白花钱）', (tester) async {
    final t = ManualTransport()..chunks.add(chunk('半'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showModalBottomSheet<RewriteOutcome>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AiRewriteSheet(
                original: '原文',
                start: (_, __) => startWith(t),
              ),
            ),
            child: const Text('改写'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('改写'));
    await settle(tester);
    await generate(tester);

    // 用户按系统返回 / 点外面关掉面板。
    Navigator.of(tester.element(find.byType(AiRewriteSheet))).pop();
    await settle(tester);
    expect(t.cancelled, isTrue, reason: '关掉面板必须取消生成');
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
