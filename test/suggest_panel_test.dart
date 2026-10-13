import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_row.dart';
// `AiStream`（`FakeStream.stream` 的返回类型）在 `ai_client.dart`；
// `AiStart` / `AiStarted` / `AiNotStarted`（面板 `launch` 形参的返回类型）
// 在 `ai_service.dart` —— 少任何一个都编不过。
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

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

const String _goodJson = '{"summary":"对方在等确认","actions":['
    '{"action":"reply","reason":"在等你回"},'
    '{"action":"remind","reason":"周五之前回就行"}]}';

const String _noneOnlyJson = '{"summary":"纯通知","actions":'
    '[{"action":"none","reason":"不用管"}]}';

/// 只建议「加星」：用来钉「图标按信件状态画」（`openPanel` 造的那一行默认
/// 未加星，所以池子里是 `star`、画的该是空心星）。
const String _starJson = '{"summary":"先存着","actions":'
    '[{"action":"star","reason":"回头再看"}]}';

/// 七项全给：`openPanel` 造的那一行（未读、没星、有正文）的池子正好七项。
/// 用来把面板撑到屏幕装不下，钉限高滚动。
const String _manyJson = '{"summary":"七件事","actions":['
    '{"action":"reply","reason":"在等你回"},'
    '{"action":"forward","reason":"转给同事"},'
    '{"action":"remind","reason":"明天再说"},'
    '{"action":"delete","reason":"是广告"},'
    '{"action":"markRead","reason":"扫一眼就行"},'
    '{"action":"star","reason":"回头处理"},'
    '{"action":"none","reason":"不用管"}]}';

/// 把面板挂到一个按钮上、点开，返回 pop 回来的那个东西的读取口。
///
/// [reply] 是这次假流要吐的整段回话；[emitReply] 为 false 时一个字都不吐
/// （直接结束）；[gate] 给了就等它 —— 于是能在「分析中」那一态停下来做断言。
///
/// **调用方必须自己把 [gate] complete 掉**，否则这一次请求永远不结束。
Future<SuggestionChoice? Function()> openPanel(
  WidgetTester tester, {
  required String reply,
  bool hasFullBody = true,
  bool emitReply = true,
  Completer<void>? gate,
}) async {
  SuggestionChoice? returned;
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          key: const ValueKey('open'),
          onPressed: () async {
            returned = await showSuggestPanel(
              context,
              row: MailRow(
                emailId: 7,
                profileId: 'p1',
                name: '张三',
                sendEmail: 'alice@example.com',
                subject: '上线时间',
                mailboxEmail: 'me@example.com',
                content: '<p>会议时间定了吗？</p>',
                hasFullBody: hasFullBody,
              ),
              starEnabled: true,
              refresh: () async => null,
              launch: (input, actionIds) async => AiStarted(
                FakeStreamSession(tester, reply, emitReply, gate).stream,
              ),
            );
          },
          child: const Text('开'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const ValueKey('open')));
  await settle(tester);
  return () => returned;
}

/// 一次假的流：构造时就推完 [reply]，然后 `close()`。
///
/// [gate] 给了就等它 —— 用来停在「分析中」那一态做断言。
class FakeStreamSession {
  FakeStreamSession(this.tester, this.reply, this.emitReply, this.gate);

  final WidgetTester tester;
  final String reply;
  final bool emitReply;
  final Completer<void>? gate;

  final FakeStream _fake = FakeStream();

  AiStream get stream {
    scheduleMicrotask(() async {
      if (gate != null) await gate!.future;
      if (emitReply) _fake.emit(reply);
      await _fake.close();
    });
    return _fake.stream;
  }
}

void main() {
  testWidgets('分析中：画流式内容与停止按钮，抬头已经在', (tester) async {
    // **必须给一个 gate 把流按住。** 没有它的话这一整个流程是
    // 「`start()` → 假流 microtask 里推完 + close → `running` 翻 false →
    // `_onRunningChanged` 切到结果态」，全在 `openPanel` 里那两下 `pump`
    // 之间跑完 —— 断言见到的已经是结果态，`ai-stop` 永远 `findsNothing`，
    // 而这条用例声称要测的「分析中」一帧都到不了。
    final gate = Completer<void>();
    await openPanel(tester, reply: '正在想…', gate: gate);
    expect(find.byKey(const ValueKey('ai-suggest-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-stop')), findsOneWidget);
    // 抬头如实写了看到了什么
    expect(find.textContaining('正文'), findsWidgets);
    // 这一态**没有**可点的动作项
    expect(find.byKey(const ValueKey('ai-suggest-choice-reply')), findsNothing);
    // 放行，收尾（不然这一次请求一直挂着）。
    gate.complete();
    await settle(tester);
  });

  testWidgets('结果态：summary + 两项，第一项带「最推荐」徽标', (tester) async {
    await openPanel(tester, reply: _goodJson);
    await settle(tester);
    expect(find.text('对方在等确认'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-suggest-choice-reply')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-suggest-choice-remind')), findsOneWidget);
    // 徽标只有一个，挂在第一项上
    expect(find.byKey(const ValueKey('ai-suggest-top')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-suggest-choice-reply')),
        matching: find.byKey(const ValueKey('ai-suggest-top')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('`none` 单列时不打「最推荐」徽标', (tester) async {
    await openPanel(tester, reply: _noneOnlyJson);
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-suggest-choice-none')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-suggest-top')), findsNothing,
        reason: '「无需处理」标成最推荐是荒谬的');
  });

  testWidgets('点一项：pop 回一个 SuggestionChoice（面板只选不做）', (tester) async {
    final result = await openPanel(tester, reply: _goodJson);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-suggest-choice-reply')));
    await settle(tester);
    final choice = result();
    expect(choice, isNotNull);
    expect(choice!.action, MailAction.reply);
    expect(choice.reason, '在等你回');
    expect(choice.replyDraft, isNull, reason: '模型没给 draft，不凭空造一份');
  });

  testWidgets('解析失败：显示模型原文，**没有任何可点动作**', (tester) async {
    await openPanel(tester, reply: '我觉得这封信不用处理，你可以不管它。');
    await settle(tester);
    expect(find.textContaining('我觉得这封信不用处理'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-suggest-retry')), findsOneWidget);
    // 一个动作项都没有
    for (final action in MailAction.values) {
      expect(
        find.byKey(ValueKey<String>('ai-suggest-choice-${action.id}')),
        findsNothing,
        reason: '${action.id} 不该出现',
      );
    }
  });

  testWidgets('请求失败：画的是 AiStreamView 那句话，也没有可点动作', (tester) async {
    // launch 直接给 AiNotStarted —— 走的是 `run.message` 那一条。
    SuggestionChoice? returned;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () async {
              returned = await showSuggestPanel(
                context,
                row: MailRow(
                  emailId: 7,
                  profileId: 'p1',
                  subject: '上线时间',
                  content: '<p>x</p>',
                ),
                starEnabled: true,
                refresh: () async => null,
                launch: (input, ids) async =>
                    const AiNotStarted('还没有配置 AI —— 去「设置 → AI」里填上'),
              );
            },
            child: const Text('开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await settle(tester);
    expect(find.textContaining('还没有配置 AI'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-suggest-choice-none')), findsNothing);
    expect(returned, isNull);
  });

  testWidgets('补正文那一态：一句静态的「正在补全正文…」', (tester) async {
    final gate = Completer<void>();
    SuggestionChoice? returned;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () async {
              returned = await showSuggestPanel(
                context,
                row: MailRow(
                  emailId: 7,
                  profileId: 'p1',
                  subject: '上线时间',
                  content: '<p>x</p>',
                  // 摘要行 —— 于是会话会先走补正文那一态
                  hasFullBody: false,
                ),
                starEnabled: true,
                refresh: () => gate.future.then((_) => null),
                launch: (input, ids) async =>
                    const AiNotStarted('不该走到这里'),
              );
            },
            child: const Text('开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await settle(tester);
    expect(find.text('正在补全正文…'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-stop')), findsNothing,
        reason: '还没发起请求，没有东西可停');
    gate.complete();
    await settle(tester);
    expect(returned, isNull);
  });

  testWidgets('重新分析：调第二次，并且换掉整个 session', (tester) async {
    var launches = 0;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () => showSuggestPanel(
              context,
              row: MailRow(
                emailId: 7,
                profileId: 'p1',
                subject: '上线时间',
                content: '<p>x</p>',
                hasFullBody: true,
              ),
              starEnabled: true,
              refresh: () async => null,
              launch: (input, ids) async {
                launches++;
                // **必须吐一份能解析的回话**（计划里原来的写法是
                // `AiStarted(FakeStream().stream)` —— 那条流一个字都不吐、
                // 也不 close，面板永远停在 `analyzing`）。而 `ai-suggest-again`
                // 只在 `done` 那一态画（spec §4.5）：`analyzing` 里给的是
                // `AiStreamView` 的停止按钮。用一条不结束的流的话，这条用例
                // 连按钮都找不到（`Found 0 widgets with key ai-suggest-again`），
                // 而它声称要测的是「重新分析真的再发一次请求」。
                return AiStarted(
                    FakeStreamSession(tester, _goodJson, true, null).stream);
              },
            ),
            child: const Text('开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await settle(tester);
    expect(launches, 1);
    await tester.tap(find.byKey(const ValueKey('ai-suggest-again')));
    await settle(tester);
    expect(launches, 2, reason: '重新分析会真的再发一次请求');
  });

  // ---------------------------------------------------------- 卡片行与图标

  testWidgets('每条候选都画了图标', (tester) async {
    await openPanel(tester, reply: _goodJson);
    await settle(tester);
    expect(find.byIcon(Icons.reply), findsOneWidget);
    expect(find.byIcon(Icons.alarm), findsOneWidget);
  });

  testWidgets('图标按信件状态画：未加星的信上「加星标」是空心星', (tester) async {
    await openPanel(tester, reply: _starJson);
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-suggest-choice-star')), findsOneWidget);
    expect(find.byIcon(Icons.star_border), findsOneWidget);
    expect(find.byIcon(Icons.star), findsNothing,
        reason: '这封信还没加星，画实心星就和旁边的文字对不上了');
  });

  // ---------------------------------------------------------- 回车

  testWidgets('回车执行第一项，与点它逐字相同', (tester) async {
    final result = await openPanel(tester, reply: _goodJson);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    final choice = result();
    expect(choice, isNotNull, reason: '回车要把面板 pop 掉');
    expect(choice!.action, MailAction.reply);
    expect(choice.reason, '在等你回', reason: '与鼠标点第一张卡拿到的是同一份');
  });

  testWidgets('分析中按回车：什么都不做，面板不许被白关掉', (tester) async {
    // 与「分析中」那条同一个 gate 手法：把流按住，面板停在 `analyzing`。
    final gate = Completer<void>();
    final result = await openPanel(tester, reply: '正在想…', gate: gate);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-stop')), findsOneWidget,
        reason: '还没有可执行的动作，回车不该把面板关掉');
    expect(result(), isNull);
    gate.complete();
    await settle(tester);
  });

  testWidgets('Tab 到「重新分析」后按回车：重新分析，不执行第一项', (tester) async {
    // 这条钉的是「面板根的回车处理**不许抢自己按钮的键**」。原来的
    // `CallbackShortcuts` 对匹配的键一律返回 handled，事件在浮到
    // `WidgetsApp` 默认快捷键之前就被吃掉了 —— 焦点在「重新分析」上按回车
    // 会去执行第一项，那颗按钮永远按不动。
    var launches = 0;
    SuggestionChoice? returned;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () async {
              returned = await showSuggestPanel(
                context,
                row: MailRow(
                  emailId: 7,
                  profileId: 'p1',
                  subject: '上线时间',
                  content: '<p>x</p>',
                  hasFullBody: true,
                ),
                starEnabled: true,
                refresh: () async => null,
                launch: (input, ids) async {
                  launches++;
                  return AiStarted(
                      FakeStreamSession(tester, _goodJson, true, null).stream);
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
    expect(launches, 1);
    // 面板根 `autofocus`，Tab 一次正好落到抬头那一行里唯一的按钮
    // （「重新分析」是 `Column` 第一个子 `Row` 里唯一可聚焦的东西）。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(launches, 2, reason: '回车要按下「重新分析」，而不是被面板根抢去执行第一项');
    expect(returned, isNull, reason: '面板不能因为这一下回车被关掉');
    expect(find.byKey(const ValueKey('ai-suggest-choice-reply')), findsOneWidget);
  });

  // ---------------------------------------------------------- 回车提示

  testWidgets('桌面平台：最推荐那一项带回车提示', (tester) async {
    await openPanel(tester, reply: _goodJson);
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-suggest-enter-hint')), findsOneWidget);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('移动端：不画回车提示', (tester) async {
    await openPanel(tester, reply: _goodJson);
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-suggest-enter-hint')), findsNothing);
  }, variant: TargetPlatformVariant.mobile());

  testWidgets('`none` 单列时不画回车提示（提示挂在徽标里，而徽标不画）',
      (tester) async {
    // 这条**必须**跑在桌面上才有效：默认平台（android）下提示本来就不画，
    // 拿它当护栏等于什么都没钉。
    await openPanel(tester, reply: _noneOnlyJson);
    await settle(tester);
    expect(find.byKey(const ValueKey('ai-suggest-enter-hint')), findsNothing);
  }, variant: TargetPlatformVariant.desktop());

  // ---------------------------------------------------------- 尺寸

  testWidgets('窄高屏幕：七张卡不溢出（限高滚动真的接上了）', (tester) async {
    // 必须在 `openPanel`（它会 `pumpWidget`）**之前**设尺寸。
    tester.view.physicalSize = const Size(420, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await openPanel(tester, reply: _manyJson);
    await settle(tester);
    expect(tester.takeException(), isNull,
        reason: '没有限高滚动时这里是 RenderFlex overflowed；溢出让这一帧'
            '带上一枚异常，`takeException()` 就是在为它显式收账');
  });
}
