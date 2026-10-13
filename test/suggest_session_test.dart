import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/suggest/mail_action.dart';
import 'package:mail_app/features/suggest/suggest_session.dart';
import 'package:mail_app/features/suggest/suggestion.dart';

/// 一个受控的流：`emit` 推增量、`close` 正常结束、`fail` 抛错。
///
/// **不用 `ManualTransport` + `AiClient`**（那是 `ai_polish_sheet_test.dart`
/// 的做法）：这一份测的是状态机，不是 HTTP 形状 —— 直接造一个 `AiStream`
/// 就能把「流怎么结束」这件事精确控制住，少一层解析。
class FakeStream {
  final StreamController<String> _controller = StreamController<String>();
  final Completer<String> _done = Completer<String>();
  final StringBuffer _text = StringBuffer();

  var cancelled = false;

  AiStream get stream => AiStream(
        text: _controller.stream,
        done: _done.future,
        cancel: () {
          cancelled = true;
          if (!_controller.isClosed) unawaited(_controller.close());
        },
      );

  void emit(String part) {
    _text.write(part);
    if (!_controller.isClosed) _controller.add(part);
  }

  void fail(Object error) {
    if (!_controller.isClosed) _controller.addError(error);
  }

  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
    if (!_done.isCompleted) _done.complete(_text.toString());
  }
}

MailRow row({bool hasFullBody = true}) => MailRow(
      emailId: 7,
      profileId: 'p1',
      name: '张三',
      sendEmail: 'alice@example.com',
      subject: '上线时间',
      mailboxEmail: 'me@example.com',
      content: '<p>会议时间定了吗？</p>',
      unread: UnreadState.unread,
      hasFullBody: hasFullBody,
    );

const String _goodJson = '{"summary":"对方在等确认","actions":['
    '{"action":"reply","reason":"在等你回"},'
    '{"action":"remind","reason":"不急"}]}';

/// 建一个会话，并把两趟回调的调用情况记下来。
///
/// [refreshed] 是补正文那趟的返回值：null 表示补失败（实例不支持 full / 网络
/// 挂了）。
({SuggestSession session, List<int> refreshes, List<List<String>> pools}) build({
  bool hasFullBody = true,
  MailRow? refreshed,
  AiStart Function(FakeStream stream)? start,
}) {
  final refreshes = <int>[];
  final pools = <List<String>>[];
  final session = SuggestSession(
    row: row(hasFullBody: hasFullBody),
    starEnabled: true,
    refresh: () async {
      refreshes.add(1);
      return refreshed;
    },
    launch: (input, actionIds) async {
      pools.add(actionIds);
      // **每一趟都新建一个**（`start` 回调因此自己保留它那一个实例）：
      // `AiStream.text` 是**单订阅**流，同一个实例在重新分析时再听一次会抛
      // `Bad state: Stream has already been listened to` ——
      // 那测的是 `dart:async` 的规矩，不是本状态机的行为。
      final stream = FakeStream();
      return start == null ? AiStarted(stream.stream) : start(stream);
    },
  );
  return (session: session, refreshes: refreshes, pools: pools);
}

/// 走完一次会话：`start()` + 把微任务队列冲干净。
///
/// **不 `pumpAndSettle`**：这里没有 widget，冲队列用的是
/// `pumpEventQueue()`（`flutter_test` 里那个）。
Future<void> run(SuggestSession session) async {
  await session.start();
  await pumpEventQueue();
}

void main() {
  test('正文已经齐了：不跑补正文那一趟，直接进分析', () async {
    final h = build();
    await run(h.session);
    expect(h.refreshes, isEmpty, reason: 'hasFullBody 为真时不该白跑一趟网络');
    expect(h.session.input.hasBody, isTrue);
    h.session.dispose();
  });

  test('正文是摘要：先补一次，并**换成补完之后重新读过的那一行**', () async {
    final full = MailRow(
      emailId: 7,
      profileId: 'p1',
      sendEmail: 'alice@example.com',
      subject: '上线时间',
      content: '<p>补全之后的完整正文</p>',
      hasFullBody: true,
    );
    final h = build(hasFullBody: false, refreshed: full);
    expect(h.session.stage.value, SuggestStage.fetching, reason: '初始态就是它');
    await run(h.session);
    expect(h.refreshes, hasLength(1));
    expect(h.session.row.hasFullBody, isTrue, reason: '执行器要用的是这一份');
    expect(h.session.input.text, contains('补全之后的完整正文'));
    h.session.dispose();
  });

  test('补正文失败**不阻断**：拿摘要继续（spec §8.4 第 3 段）', () async {
    final h = build(hasFullBody: false, refreshed: null);
    await run(h.session);
    expect(h.refreshes, hasLength(1));
    expect(h.session.row.hasFullBody, isFalse);
    expect(h.session.input.text, contains('会议时间定了吗？'), reason: '用摘要那一段');
    expect(h.session.stage.value, isNot(SuggestStage.fetching),
        reason: '不能卡在补正文那一态');
    h.session.dispose();
  });

  test('发出去的是**过滤后的池子**（与解析器当白名单的是同一个）', () async {
    final h = build();
    await run(h.session);
    final ids = h.pools.single;
    expect(ids, contains('reply'));
    expect(ids, contains('none'));
    // 这封信是**未读**的，所以池子里是 `markRead` 而不是 `markUnread` ——
    // 「已经读过」那件事由状态说了，模型不该再被提示去读一遍。
    // （别把这条写成「因为没有星标能力」：harness 里 `starEnabled` 是
    // **true**，`star` / `unstar` 都在池子里。）
    expect(ids, contains('markRead'));
    expect(ids, isNot(contains('markUnread')));
    expect(h.session.pool.map((a) => a.id).toList(), ids);
    h.session.dispose();
  });

  test('模型吐了合法 JSON：done，parsed 是 SuggestionParsed', () async {
    late FakeStream stream;
    final h = build(start: (s) {
      stream = s;
      return AiStarted(s.stream);
    });
    await h.session.start();
    await pumpEventQueue();
    expect(h.session.stage.value, SuggestStage.analyzing);
    stream.emit(_goodJson);
    await stream.close();
    await pumpEventQueue();
    expect(h.session.stage.value, SuggestStage.done);
    final parsed = h.session.parsed;
    expect(parsed, isA<SuggestionParsed>());
    expect(
      (parsed! as SuggestionParsed).suggestion.choices.map((c) => c.action),
      <MailAction>[MailAction.reply, MailAction.remind],
    );
    h.session.dispose();
  });

  test('模型吐了一句自然语言：failed（不是「无需处理」）', () async {
    late FakeStream stream;
    final h = build(start: (s) {
      stream = s;
      return AiStarted(s.stream);
    });
    await h.session.start();
    await pumpEventQueue();
    stream.emit('我觉得这封信不用处理，你可以不管它。');
    await stream.close();
    await pumpEventQueue();
    expect(h.session.stage.value, SuggestStage.failed);
    expect(h.session.parsed, isA<SuggestionUnreadable>());
    h.session.dispose();
  });

  test('请求失败：failed，且那一句话留在 run.message 里（面板要画它）', () async {
    final h = build(start: (_) => const AiNotStarted('还没有配置 AI'));
    await run(h.session);
    expect(h.session.stage.value, SuggestStage.failed);
    expect(h.session.run.message.value, isNotEmpty);
    h.session.dispose();
  });

  test('流里报错：failed', () async {
    late FakeStream stream;
    final h = build(start: (s) {
      stream = s;
      return AiStarted(s.stream);
    });
    await h.session.start();
    await pumpEventQueue();
    stream.fail(StateError('boom'));
    await stream.close();
    await pumpEventQueue();
    expect(h.session.stage.value, SuggestStage.failed);
    h.session.dispose();
  });

  test('用户停止：failed，半截内容还留着（spec §4.3 末段）', () async {
    late FakeStream stream;
    final h = build(start: (s) {
      stream = s;
      return AiStarted(s.stream);
    });
    await h.session.start();
    await pumpEventQueue();
    stream.emit('{"summary":"对方在等');
    await pumpEventQueue();
    h.session.run.stop();
    await pumpEventQueue();
    expect(h.session.stage.value, SuggestStage.failed);
    expect(h.session.run.text.value, '{"summary":"对方在等', reason: '半截留着');
    h.session.dispose();
  });

  test('重新分析：**整个换掉 AiRun 实例**，并且再补一次正文（spec §4.5）', () async {
    late FakeStream first;
    var calls = 0;
    final h = build(
      start: (s) {
        calls++;
        if (calls == 1) first = s;
        return AiStarted(s.stream);
      },
    );
    await h.session.start();
    await pumpEventQueue();
    final before = h.session.run;
    first.emit('不是 JSON 的一句话');
    await first.close();
    await pumpEventQueue();
    expect(h.session.stage.value, SuggestStage.failed);
    expect(identical(h.session.run, before), isTrue, reason: '前提：还没换');

    await h.session.restart();
    await pumpEventQueue();
    expect(identical(h.session.run, before), isFalse,
        reason: '换实例 —— 上一次的增量与错误必须一起丢掉');
    expect(calls, 2);
    expect(h.session.parsed, isNull, reason: '换完之后还没解析过');
    h.session.dispose();
  });

  test('dispose 之后再来的回调不写任何 notifier', () async {
    late FakeStream stream;
    final h = build(start: (s) {
      stream = s;
      return AiStarted(s.stream);
    });
    await h.session.start();
    await pumpEventQueue();
    h.session.dispose();
    // 流在 dispose 之后才关：`AiRun.dispose` 会把监听者摘掉，
    // 这里只是确保不抛（「ValueNotifier used after being disposed」那种）。
    stream.emit('迟到的增量');
    await stream.close();
    await pumpEventQueue();
  });
}
