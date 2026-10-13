// 整篇润色面板（`AiPolishSheet`）的接线用例。
//
// 与本轮改动直接相关的两条要害：
// 1. **打开面板不发请求** —— 以前点一下 AppBar 那颗图标就直接调模型，用户连语气
//    都没看就把钱花了。现在是「开面板 → 选语气/写要求 → 点生成」。
// 2. **指令框与邮件正文是两份独立入参** —— 指令框里的字一路作为 `extra` 传给
//    `AiPrompts.rewrite`，绝不与正文拼成同一个参数（那样等于把模型的指令写进了
//    邮件里）。
//
// 组装/剪裁那一层的纯逻辑在 `ai_continuation_test.dart` / `ai_service_test.dart`
// 里钉着；这一份只管面板自己的行为。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/compose/ai/ai_polish_sheet.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 受控的假生成：`finish()` 放行。**不能用带定时器的轮询** —— 面板里跑着
/// `CircularProgressIndicator`（永不结束的动画），`pumpAndSettle` 会一直等到
/// `timed out`，而不是让某条断言失败。
class ManualTransport implements AiTransport {
  ManualTransport(this.reply);

  final String reply;
  final Completer<void> _gate = Completer<void>();
  bool cancelled = false;

  /// 发过几次请求。用来钉「打开面板不发请求」。
  var calls = 0;

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

/// 推进若干帧（不 `pumpAndSettle`，理由见 [ManualTransport] 的注释）。
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

/// 一次生成被调用时记下的入参。断言「语气与指令是两份独立入参」全靠它。
class Call {
  Call(this.tone, this.extra);

  final RewriteTone tone;
  final String? extra;
}

/// 把面板挂到一个按钮上，点开。返回**读结果**的函数（结果要等 pop 之后才有）。
Future<String? Function()> openSheet(
  WidgetTester tester, {
  required AiTransport transport,
  List<Call>? calls,
}) async {
  String? returned;
  await tester.pumpWidget(MaterialApp(
    // 面板用 `AppLocalizations`（标题/提示/按钮文案都走 l10n），测试宿主也得
    // 挂上同一套 delegate，否则 `AppLocalizations.of` 是 null。
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            returned = await showModalBottomSheet<String>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AiPolishSheet(
                start: (tone, extra) {
                  calls?.add(Call(tone, extra));
                  return startWith(transport);
                },
              ),
            );
          },
          child: const Text('润色'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('润色'));
  await settle(tester);
  return () => returned;
}

Future<void> generate(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('polish-generate')));
  await settle(tester);
}

void main() {
  testWidgets('打开面板不发请求，只摆好参数（用户没点生成就不花钱）', (tester) async {
    final t = ManualTransport('润色后的正文');
    final calls = <Call>[];
    await openSheet(tester, transport: t, calls: calls);

    expect(t.calls, 0, reason: '打开面板是免费的，点生成才发请求');
    expect(calls, isEmpty);
    // 参数控件都在：语气 chips + 独立指令框 + 生成按钮。
    expect(find.byKey(const ValueKey('polish-tone-polish')), findsOneWidget);
    expect(find.byKey(const ValueKey('polish-extra')), findsOneWidget);
    expect(find.byKey(const ValueKey('polish-generate')), findsOneWidget);
    // 还没生成 → 没有「替换全文」，也没有转圈。
    expect(find.byKey(const ValueKey('polish-replace')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('点生成才发请求，且带上所选语气与指令框里的字（两份独立入参）',
      (tester) async {
    final t = ManualTransport('润色后的正文');
    final calls = <Call>[];
    await openSheet(tester, transport: t, calls: calls);

    await tester.tap(find.byKey(const ValueKey('polish-tone-concise')));
    await settle(tester);
    await tester.enterText(
        find.byKey(const ValueKey('polish-extra')), '保留专业术语');
    await settle(tester);
    expect(calls, isEmpty, reason: '改参数不该发请求');

    await generate(tester);
    expect(t.calls, 1);
    expect(calls.single.tone, RewriteTone.concise);
    expect(calls.single.extra, '保留专业术语');
    t.finish();
    await settle(tester);
  });

  testWidgets('指令框留空 → extra 传 null（不是空串，别让 prompt 多一节空白的「额外要求」）',
      (tester) async {
    final t = ManualTransport('x');
    final calls = <Call>[];
    await openSheet(tester, transport: t, calls: calls);

    await generate(tester);
    expect(calls.single.tone, RewriteTone.polish, reason: '默认是润色');
    expect(calls.single.extra, isNull);
    t.finish();
    await settle(tester);
  });

  testWidgets('指令框在**面板里**、是独立于邮件正文的一个输入框', (tester) async {
    final t = ManualTransport('x');
    await openSheet(tester, transport: t);
    // 面板自己有一个可编辑的框（用户提示词），它不认识邮件正文 —— 正文由
    // 调用方在 `start` 里现取，两者从来不拼进同一个参数。
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('polish-extra')));
    expect(field.controller, isNotNull);
    expect(field.maxLines, greaterThan(1));
    t.finish();
    await settle(tester);
  });

  testWidgets('运行中：生成按钮禁用，「替换全文」等结果出来才可点', (tester) async {
    final t = ManualTransport('润色后的正文');
    await openSheet(tester, transport: t);
    await generate(tester);

    // 生成中：生成按钮禁用（同一件事不留两颗按钮），替换全文还不给点。
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('polish-generate')))
          .onPressed,
      isNull,
      reason: '生成中不该能再点一次 —— 会叠加请求',
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('polish-replace')))
          .onPressed,
      isNull,
    );
    // 半截结果已经在面板里了（`AiStreamView` 边收边显示），但「替换全文」
    // 仍然不给点 —— 写一个半截句子进正文比不写糟。
    expect(find.text('润色后的正文'), findsOneWidget);

    t.finish();
    await settle(tester);
    // 出来了 → 替换全文可点。
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('polish-replace')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('「替换全文」把生成的文本交回给调用方', (tester) async {
    final t = ManualTransport('润色后的正文');
    final read = await openSheet(tester, transport: t);
    await generate(tester);
    t.finish();
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('polish-replace')));
    await settle(tester);
    expect(read(), '润色后的正文');
  });

  testWidgets('划走面板 → 回 null（用户没点替换，正文一个字不动）', (tester) async {
    final t = ManualTransport('润色后的正文');
    final read = await openSheet(tester, transport: t);
    await generate(tester);
    t.finish();
    await settle(tester);

    Navigator.of(tester.element(find.byType(AiPolishSheet))).pop();
    await settle(tester);
    expect(read(), isNull);
  });

  testWidgets('出错 → 不给「替换全文」（没内容可写，给了等于不改）', (tester) async {
    await openSheet(tester, transport: _FailingTransport());
    await generate(tester);
    await settle(tester);
    expect(find.textContaining('401'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('polish-replace')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('关面板时把生成停掉（不能留着后台跑、白花钱）', (tester) async {
    final t = ManualTransport('润色后的正文');
    await openSheet(tester, transport: t);
    await generate(tester);

    Navigator.of(tester.element(find.byType(AiPolishSheet))).pop();
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
