// AI 输出处的**来源署名**（设计稿 §5.3 / §7.5 / 接缝 S5）。
//
// 这份用例钉三件事：
// 1. `sourceLabel == null`（公开版 / BYOK）时，五个撰写面板与建议面板的抬头
//    **一个像素都不变** —— 不出现 chip、标题还是从前那颗 `Text`；
// 2. `sourceLabel != null`（托管）时，抬头右侧出现那颗 `[hub] …` chip；
// 3. 建议面板的 chip **done 态也保留**：结果态渲染的是两列内容、不经过
//    `AiStreamView`，抬头是唯一跨阶段都在的位置（设计稿 §5.3 第 1 条）。
//
// 面板只认 `AiRun`、不认 `AiService`，所以这里全部直接构造面板、传一个
// 不会真的被调用的 `start`（chip 画不画与有没有生成无关）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_stream_view.dart';
import 'package:mail_app/features/ai/preflight.dart';
import 'package:mail_app/features/compose/ai/ai_draft_sheet.dart';
import 'package:mail_app/features/compose/ai/ai_polish_sheet.dart';
import 'package:mail_app/features/compose/ai/ai_preflight_sheet.dart';
import 'package:mail_app/features/compose/ai/ai_reply_sheet.dart';
import 'package:mail_app/features/compose/ai/ai_rewrite_sheet.dart';
import 'package:mail_app/features/suggest/suggest_panel.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 面板的 `start` 至少要交出同一个类型的东西；这里永远返回「没开始」的 run
/// —— 用例只关心抬头，不点生成。
AiRun idleRun() => AiRun(const AiNotStarted(''));

/// 把面板挂到一个按钮上，点开（与实际使用一致的 bottom sheet 形态；直接塞进
/// `Scaffold.body` 会让 `mainAxisSize.min` 的 Column 在桌面高度里溢出）。
Future<void> openSheet(WidgetTester tester, Widget Function() builder) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => builder(),
          ),
          child: const Text('开'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('开'));
  // **不用 `pumpAndSettle`**：回复建议面板里有一颗获得焦点的输入框，光标闪烁是
  // 永不结束的动画，settle 会一直等到超时。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

MailRow sampleRow() => const MailRow(
      emailId: 7,
      profileId: 'p1',
      name: '张三',
      sendEmail: 'alice@example.com',
      subject: '上线时间',
      mailboxEmail: 'me@example.com',
      content: '<p>会议时间定了吗？</p>',
      hasFullBody: true,
    );

/// 只动作、没有概述与要点：建议面板直接进 done 态并铺出动作。
const String _actionsOnlyJson = '{"actions":'
    '[{"action":"reply","reason":"在等你回"}]}';

/// 一次性假生成：吐出 [reply] 后正常关闭（会话据此进 done 态）。
class _OneShotStream {
  final StreamController<String> _controller = StreamController<String>();
  final Completer<String> _done = Completer<String>();

  AiStream get stream => AiStream(
        text: _controller.stream,
        done: _done.future,
        cancel: () {
          if (!_controller.isClosed) unawaited(_controller.close());
        },
      );

  Future<void> emitAll(String reply) async {
    _controller.add(reply);
    await _controller.close();
    if (!_done.isCompleted) _done.complete(reply);
  }
}

/// 推进若干帧（**不 `pumpAndSettle`**：面板里有永不结束的
/// `CircularProgressIndicator`，settle 会一直等到超时）。
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> pumpDock(
  WidgetTester tester, {
  required String? sourceLabel,
  bool succeed = false,
}) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Scaffold(
      body: SuggestView(
        row: sampleRow(),
        starEnabled: true,
        refresh: () async => null,
        launch: (input, actionIds) async {
          final fake = _OneShotStream();
          if (succeed) {
            scheduleMicrotask(() => fake.emitAll(_actionsOnlyJson));
          }
          return AiStarted(fake.stream);
        },
        onPick: (_) {},
        sourceLabel: sourceLabel,
      ),
    ),
  ));
  await settle(tester);
}

void main() {
  // 五个撰写面板：标题文案 + 各自的构造参数。`start` 都不会被调用。
  final panels = <String, Widget Function(String?)>{
    '润色': (label) => AiPolishSheet(
          start: (_, _) => idleRun(),
          sourceLabel: label,
        ),
    '改写': (label) => AiRewriteSheet(
          original: '原文',
          start: (_, _) => idleRun(),
          sourceLabel: label,
        ),
    '起草': (label) => AiDraftSheet(
          start: (_) => idleRun(),
          sourceLabel: label,
        ),
    '回复建议': (label) => AiReplySheet(
          incoming: '来信正文',
          start: idleRun,
          sourceLabel: label,
        ),
    '发送前检查': (label) => AiPreflightSheet(
          local: const <PreflightFinding>[],
          sourceLabel: label,
        ),
  };

  group('空注册表 / BYOK：抬头不署名（逐像素不变的护栏）', () {
    for (final entry in panels.entries) {
      testWidgets('${entry.key}：sourceLabel 为 null → 没有来源 chip',
          (tester) async {
        await openSheet(tester, () => entry.value(null));
        expect(find.byType(AiSourceChip), findsNothing);
        // 抬头还是那个「标题 + chip」组件本身，但里面只有标题 —— 不是套了一层
        // 会改变布局的 Row。
        expect(find.byType(AiPanelHeader), findsOneWidget);
        expect(tester.widget<AiPanelHeader>(find.byType(AiPanelHeader))
            .sourceLabel, isNull);
      });
    }
  });

  group('托管：抬头右侧画来源 chip', () {
    for (final entry in panels.entries) {
      testWidgets('${entry.key}：sourceLabel 非 null → 出现「订阅通道」chip',
          (tester) async {
        await openSheet(tester, () => entry.value('订阅通道'));
        expect(find.byType(AiSourceChip), findsOneWidget);
        expect(find.text('订阅通道'), findsOneWidget);
        expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
      });
    }
  });

  group('建议面板（整页形态）', () {
    testWidgets('署名画在 AppBar 标题行右侧', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showSuggestPage(
                context,
                row: sampleRow(),
                starEnabled: true,
                refresh: () async => null,
                launch: (input, actionIds) async =>
                    AiStarted(_OneShotStream().stream),
                sourceLabel: '订阅通道',
              ),
              child: const Text('开'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('开'));
      await settle(tester);
      // 整页形态的标题在 `AppBar` 上，chip 必须跟着它，而不是掉进正文。
      final chip = find.descendant(
        of: find.byType(AppBar),
        matching: find.text('订阅通道'),
      );
      expect(chip, findsOneWidget);
      expect(find.byType(AiSourceChip), findsOneWidget,
          reason: '同一颗 chip 不该在正文里再画一遍');
    });
  });

  group('建议面板（停靠形态）', () {
    testWidgets('空注册表：抬头不署名', (tester) async {
      await pumpDock(tester, sourceLabel: null);
      expect(find.byType(AiSourceChip), findsNothing);
    });

    testWidgets('托管：抬头右侧署名，且 **done 态也保留**', (tester) async {
      await pumpDock(tester, sourceLabel: '订阅通道', succeed: true);
      expect(find.text('订阅通道'), findsOneWidget);
      // `ai-suggest-again` 只在 done 态画 —— 用它确认面板真的进了结果态。
      expect(find.byKey(const ValueKey('ai-suggest-again')), findsOneWidget);
      expect(find.byType(AiSourceChip), findsOneWidget);
    });
  });
}
