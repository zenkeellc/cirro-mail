import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_row.dart';
// `AiStream` 在 `ai_client.dart`；`AiStart` / `AiStarted` / `AiNotStarted`
// （视图 `launch` 形参的返回类型）在 `ai_service.dart` —— 少任何一个都编不过。
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/suggest/mail_action.dart';
import 'package:mail_app/features/suggest/suggest_panel.dart';
import 'package:mail_app/features/suggest/suggestion.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 一个受控的假生成。与 `ai_polish_sheet_test.dart` 的 `ManualTransport`
/// 同一套：**绝不 `pumpAndSettle`** —— 面板里跑着
/// `CircularProgressIndicator`（永不结束的动画），`pumpAndSettle` 会一直等到
/// `timed out`，而不是让某条断言失败。
class FakeStream {
  final StreamController<String> _controller = StreamController<String>();
  final Completer<String> _done = Completer<String>();
  final StringBuffer _text = StringBuffer();

  AiStream get stream => AiStream(
        text: _controller.stream,
        done: _done.future,
        cancel: () {
          if (!_controller.isClosed) unawaited(_controller.close());
        },
      );

  void emit(String part) {
    _text.write(part);
    _controller.add(part);
  }

  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
    if (!_done.isCompleted) _done.complete(_text.toString());
  }
}

/// 一次假的生成：[reply] 是这次要吐的整段回话；[gate] 给了就等它 ——
/// 用来停在「分析中」那一态做断言（**调用方必须自己 complete 掉**，
/// 否则这一次请求永远不结束）。
class FakeReply {
  FakeReply({required this.reply, this.emit = true, this.gate});

  final String reply;
  final bool emit;
  final Completer<void>? gate;

  final FakeStream _fake = FakeStream();

  AiStream get stream {
    scheduleMicrotask(() async {
      if (gate != null) await gate!.future;
      if (emit) _fake.emit(reply);
      await _fake.close();
    });
    return _fake.stream;
  }
}

/// 几次 pump，把微任务里跑完的状态切换落到画面上（**不用 `pumpAndSettle`**）。
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

MailRow sampleRow({
  bool hasFullBody = true,
  String content = '<p>会议时间定了吗？</p>',
}) =>
    MailRow(
      emailId: 7,
      profileId: 'p1',
      name: '张三',
      sendEmail: 'alice@example.com',
      subject: '上线时间',
      mailboxEmail: 'me@example.com',
      content: content,
      hasFullBody: hasFullBody,
    );

const String _goodJson = '{"summary":"对方在等确认","actions":['
    '{"action":"reply","reason":"在等你回"},'
    '{"action":"remind","reason":"周五之前回就行"}]}';

const String _pointsJson = '{"summary":"对方在等确认",'
    '"points":["周五前确认上线时间","附件是季度报告，需要审阅"],'
    '"actions":['
    '{"action":"reply","reason":"在等你回"},'
    '{"action":"remind","reason":"周五之前回就行"}]}';

/// 只有动作、没有概述与要点：摘要区整块不画（旧模型/旧网关的回话形状）。
const String _actionsOnlyJson = '{"actions":'
    '[{"action":"reply","reason":"在等你回"}]}';

const String _noneOnlyJson = '{"summary":"纯通知","actions":'
    '[{"action":"none","reason":"不用管"}]}';

/// 七项全给：`sampleRow` 造的那一行（未读、没星、有正文）的池子正好七项。
/// 用来把内容撑到装不下，钉「整块可滚、不溢出」。
const String _manyJson = '{"summary":"七件事","actions":['
    '{"action":"reply","reason":"在等你回"},'
    '{"action":"forward","reason":"转给同事"},'
    '{"action":"remind","reason":"明天再说"},'
    '{"action":"delete","reason":"是广告"},'
    '{"action":"markRead","reason":"扫一眼就行"},'
    '{"action":"star","reason":"回头处理"},'
    '{"action":"none","reason":"不用管"}]}';

/// 假视图的读数口：点了哪一项、发了几次请求、`onClose` 触发几次。
class Harness {
  SuggestionChoice? picked;
  int launches = 0;
  int closes = 0;
}

/// 把 [SuggestView]（停靠面板形态）挂在一块有界区域里。
///
/// 尺寸用 `tester.view.physicalSize` 设（dpr=1）—— 面板的「两列 / 单列」
/// 判据读的是**面板自身宽度**，由 [LayoutBuilder] 从这块区域拿，
/// 所以必须让它在想要的宽度上布局。
Future<Harness> pumpDock(
  WidgetTester tester, {
  required String reply,
  Size size = const Size(900, 700),
  MailRow? row,
  bool hasFullBody = true,
  bool emitReply = true,
  Completer<void>? gate,
  Future<MailRow?> Function()? refresh,
  bool showTitle = true,
  bool withClose = false,
  Future<AiStart> Function(String input, List<String> actionIds)? launch,
}) async {
  // 必须在 `pumpWidget` **之前**设尺寸。
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final harness = Harness();
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Scaffold(
      body: SuggestView(
        row: row ?? sampleRow(hasFullBody: hasFullBody),
        starEnabled: true,
        refresh: refresh ?? () async => null,
        launch: launch ??
            (input, actionIds) async {
              harness.launches++;
              return AiStarted(
                FakeReply(reply: reply, emit: emitReply, gate: gate).stream,
              );
            },
        onPick: (choice) => harness.picked = choice,
        onClose: withClose ? () => harness.closes++ : null,
        showTitle: showTitle,
      ),
    ),
  ));
  return harness;
}

/// 从列表上的一个按钮点开 [showSuggestPage]（整页形态），返回读数口。
Future<Harness> pumpPage(
  WidgetTester tester, {
  required String reply,
  Size size = const Size(600, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final harness = Harness();
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          key: const ValueKey('open'),
          onPressed: () async {
            harness.picked = await showSuggestPage(
              context,
              row: sampleRow(),
              starEnabled: true,
              refresh: () async => null,
              launch: (input, actionIds) async {
                harness.launches++;
                return AiStarted(FakeReply(reply: reply).stream);
              },
            );
          },
          child: const Text('开'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const ValueKey('open')));
  await settle(tester);
  return harness;
}

void main() {
  // ------------------------------------------------------------ 两列 / 单列

  group('布局（停靠面板按自身宽度分两列/单列）', () {
    testWidgets('宽度 900：两列 —— 摘要在左、建议操作在右，两列各自可滚',
        (tester) async {
      await pumpDock(tester, reply: _pointsJson);
      await settle(tester);

      // 面板标题只画一次（停靠面板自己有标题；整页形态才交给 AppBar）。
      expect(find.text('AI 建议'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-summary')), findsOneWidget);
      expect(find.text('对方在等确认'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-choice-reply')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-choice-remind')),
          findsOneWidget);

      // 两列：有分隔线，且摘要在左、动作在右。
      expect(find.byType(VerticalDivider), findsOneWidget);
      final summaryX = tester
          .getTopLeft(find.byKey(const ValueKey('ai-suggest-summary')))
          .dx;
      final choiceX = tester
          .getTopLeft(find.byKey(const ValueKey('ai-suggest-choice-reply')))
          .dx;
      expect(summaryX, lessThan(choiceX));

      // 两个区块标题都画（spec §1.2：两列时显示）。
      expect(find.byKey(const ValueKey('ai-suggest-summary-title')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-actions-title')),
          findsOneWidget);

      // 两列各自可滚：左右各一个滚动区。
      expect(find.byType(SingleChildScrollView), findsNWidgets(2));
    });

    testWidgets('宽度 600：单列 —— 无区块标题，摘要在上、动作卡片在下',
        (tester) async {
      await pumpDock(tester, reply: _pointsJson, size: const Size(600, 700));
      await settle(tester);

      expect(find.byType(VerticalDivider), findsNothing);
      // 停靠面板的单列保持旧观感：不硬加区块标题（spec §1.2）。
      expect(find.byKey(const ValueKey('ai-suggest-summary-title')),
          findsNothing);
      expect(find.byKey(const ValueKey('ai-suggest-actions-title')),
          findsNothing);

      final summaryY = tester
          .getTopLeft(find.byKey(const ValueKey('ai-suggest-summary')))
          .dy;
      final choiceY = tester
          .getTopLeft(find.byKey(const ValueKey('ai-suggest-choice-reply')))
          .dy;
      expect(summaryY, lessThan(choiceY));

      // 单列只有一整块滚动区。
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('要点按「圆点 + 一句」逐条渲染', (tester) async {
      await pumpDock(tester, reply: _pointsJson);
      await settle(tester);
      expect(find.text('周五前确认上线时间'), findsOneWidget);
      expect(find.text('附件是季度报告，需要审阅'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-point-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-point-1')), findsOneWidget);
    });

    testWidgets('摘要与要点都为空时只画动作卡片', (tester) async {
      await pumpDock(tester, reply: _actionsOnlyJson);
      await settle(tester);
      expect(find.byKey(const ValueKey('ai-suggest-summary')), findsNothing);
      expect(find.byKey(const ValueKey('ai-suggest-summary-title')),
          findsNothing);
      expect(find.byKey(const ValueKey('ai-suggest-choice-reply')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-actions-title')),
          findsOneWidget);
    });

    testWidgets('窄高停靠面板：七张卡不溢出（内容区自己滚）', (tester) async {
      await pumpDock(tester, reply: _manyJson, size: const Size(600, 400));
      await settle(tester);
      expect(tester.takeException(), isNull,
          reason: '没有滚动区时这里是 RenderFlex overflowed');
      expect(find.byKey(const ValueKey('ai-suggest-choice-reply')),
          findsOneWidget);
    });
  });

  // ---------------------------------------------------------------- 四个态

  group('四个状态', () {
    testWidgets('fetching：一句静态的「正在补全正文…」，没有停止按钮',
        (tester) async {
      final gate = Completer<void>();
      await pumpDock(
        tester,
        reply: '不该走到这里',
        hasFullBody: false,
        refresh: () => gate.future.then((_) => null),
        launch: (input, ids) async => const AiNotStarted('不该走到这里'),
      );
      await tester.pump();
      expect(find.text('正在补全正文…'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-stop')), findsNothing,
          reason: '还没发起请求，没有东西可停');
      gate.complete();
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('analyzing：画流式视图与停止按钮，抬头已经在', (tester) async {
      // **必须给一个 gate 把流按住**，否则整条流程会在 settle 里跑完，
      // 断言见到的已经是结果态。
      final gate = Completer<void>();
      await pumpDock(tester, reply: '正在想…', gate: gate);
      await settle(tester);
      expect(find.byKey(const ValueKey('ai-suggest-header')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-stop')), findsOneWidget);
      expect(find.textContaining('正文'), findsWidgets);
      expect(find.byKey(const ValueKey('ai-suggest-choice-reply')),
          findsNothing);
      gate.complete();
      await settle(tester);
    });

    testWidgets('done：摘要 + 动作卡片 + 「最推荐」徽标挂在第一项上',
        (tester) async {
      await pumpDock(tester, reply: _goodJson);
      await settle(tester);
      expect(find.text('对方在等确认'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-choice-reply')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-choice-remind')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-top')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ai-suggest-choice-reply')),
          matching: find.byKey(const ValueKey('ai-suggest-top')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('failed（解析失败）：模型原文 + 重试，**没有任何可点动作**',
        (tester) async {
      await pumpDock(tester, reply: '我觉得这封信不用处理，你可以不管它。');
      await settle(tester);
      expect(find.byKey(const ValueKey('ai-suggest-raw')), findsOneWidget);
      expect(find.textContaining('我觉得这封信不用处理'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-retry')), findsOneWidget);
      for (final action in MailAction.values) {
        expect(
          find.byKey(ValueKey<String>('ai-suggest-choice-${action.id}')),
          findsNothing,
          reason: '${action.id} 不该出现',
        );
      }
    });

    testWidgets('failed（请求失败）：画 AiStreamView 那句话 + 重试',
        (tester) async {
      await pumpDock(
        tester,
        reply: '',
        launch: (input, ids) async =>
            const AiNotStarted('还没有配置 AI —— 去「设置 → AI」里填上'),
      );
      await settle(tester);
      expect(find.textContaining('还没有配置 AI'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-retry')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-choice-none')),
          findsNothing);
    });
  });

  // ------------------------------------------------------------ 交互与状态

  testWidgets('重新分析：真的再发一次请求，并换掉整个会话', (tester) async {
    final harness = await pumpDock(tester, reply: _goodJson);
    await settle(tester);
    expect(harness.launches, 1);
    await tester.tap(find.byKey(const ValueKey('ai-suggest-again')));
    await settle(tester);
    expect(harness.launches, 2, reason: '重新分析会真的再发一次请求');
    expect(find.byKey(const ValueKey('ai-suggest-choice-reply')),
        findsOneWidget);
  });

  testWidgets('停靠面板的 × 只收起自己：交给 onClose，不挑任何一项',
      (tester) async {
    final harness = await pumpDock(tester, reply: _goodJson, withClose: true);
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-suggest-close')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-suggest-close')));
    expect(harness.closes, 1);
    expect(harness.picked, isNull);
  });

  testWidgets('点一项：把 SuggestionChoice 交给 onPick（视图只选不做）',
      (tester) async {
    final harness = await pumpDock(tester, reply: _goodJson);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-suggest-choice-reply')));
    await settle(tester);
    expect(harness.picked, isNotNull);
    expect(harness.picked!.action, MailAction.reply);
    expect(harness.picked!.reason, '在等你回');
    expect(harness.picked!.replyDraft, isNull,
        reason: '模型没给 draft，不凭空造一份');
  });

  testWidgets('`none` 单列时不打「最推荐」徽标', (tester) async {
    await pumpDock(tester, reply: _noneOnlyJson);
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-suggest-choice-none')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('ai-suggest-top')), findsNothing,
        reason: '「无需处理」标成最推荐是荒谬的');
  });

  testWidgets('长正文：抬头用**原文长度**说「取开头和结尾」', (tester) async {
    await pumpDock(
      tester,
      reply: _goodJson,
      row: sampleRow(content: '<p>${'x' * 9000}</p>'),
    );
    await settle(tester);
    expect(find.textContaining('已取开头和结尾'), findsOneWidget);
    expect(find.textContaining('9000'), findsOneWidget,
        reason: '{chars} 是原文长度，不是喂进去的长度');
    expect(find.textContaining('只取前'), findsNothing);
  });

  // -------------------------------------------------------------- 回车（已删）

  testWidgets('桌面端按回车什么都不发生，也不再画回车提示', (tester) async {
    final harness = await pumpDock(tester, reply: _goodJson);
    await settle(tester);
    // 停靠面板在阅读场景里**不抢焦点、不接管回车**（spec §2.1 末条）。
    expect(find.byKey(const ValueKey('ai-suggest-enter-hint')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(harness.picked, isNull, reason: '回车不再执行第一项');
    expect(find.byKey(const ValueKey('ai-suggest-choice-reply')),
        findsOneWidget, reason: '面板不许被这一下回车白关掉');
  }, variant: TargetPlatformVariant.desktop());

  // ---------------------------------------------------------------- 整页路由

  group('整页路由 showSuggestPage', () {
    testWidgets('AppBar 标题 + 单列 + 两个区块标题（宽度 900 也单列）',
        (tester) async {
      await pumpPage(tester, reply: _pointsJson, size: const Size(900, 700));
      await settle(tester);

      expect(find.byType(SuggestView), findsOneWidget);
      // 标题由 AppBar 写；`showTitle: false` 保证正文里不再重复。
      expect(find.text('AI 建议'), findsOneWidget);
      // `isPage` 恒为单列，哪怕宽度超过两列门槛。
      expect(find.byType(VerticalDivider), findsNothing);
      // 整页形态显示两个区块标题（spec §2.2）。
      expect(find.byKey(const ValueKey('ai-suggest-summary-title')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-actions-title')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('ai-suggest-choice-reply')),
          findsOneWidget);
    });

    testWidgets('点一项：先把整页 pop 掉，再把 SuggestionChoice 交回调用方',
        (tester) async {
      final harness =
          await pumpPage(tester, reply: _goodJson, size: const Size(600, 700));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('ai-suggest-choice-reply')));
      await settle(tester);

      expect(find.byType(SuggestView), findsNothing, reason: '整页要 pop 掉');
      expect(harness.picked, isNotNull);
      expect(harness.picked!.action, MailAction.reply);
      expect(harness.picked!.reason, '在等你回');
      expect(harness.picked!.replyDraft, isNull);
    });
  });
}
