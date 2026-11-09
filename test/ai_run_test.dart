import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';

/// 假传输：按脚本喂增量、按需抛错、能被取消。
class ScriptedTransport implements AiTransport {
  ScriptedTransport(this.chunks, {this.error, this.hang = false});

  final List<String> chunks;
  final Object? error;

  /// true = 喂完就不返回，直到被取消（模拟一次很长的生成）。
  final bool hang;
  bool cancelled = false;

  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async {
    await Future<void>.delayed(Duration.zero);
    for (final c in chunks) {
      if (cancelToken.isCancelled) {
        cancelled = true;
        throw const AiCancelledException();
      }
      onChunk(c);
      await Future<void>.delayed(Duration.zero);
    }
    if (error != null) throw error!;
    while (hang && !cancelToken.isCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (hang) {
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

const openai = AiProvider(
  format: AiApiFormat.openai,
  model: 'm',
  baseUrl: 'https://api.openai.com/v1',
);

String chunk(String text) =>
    'data: {"choices":[{"delta":{"content":"$text"}}]}\n\n';

AiStream start(AiTransport t) => AiClient(transport: t).stream(
      provider: openai,
      request: const AiRequest(system: 's', prompt: 'p'),
      apiKey: 'k',
    );

/// 生成是异步推进的，等一个条件成立。`label` 只用于等不到时报得清楚。
///
/// **每次让出一毫秒真实时间**（不是 `Duration.zero`）：假传输里有一个
/// 「等到被取消为止」的 1ms 轮询，只让出微任务的话它永远走不到 ——
/// 「取消真的传到了传输层」这句话就断言不了。
Future<void> until(String label, bool Function() ok) async {
  for (var i = 0; i < 2000; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('等不到：$label');
}

void main() {
  test('增量一段段追加，跑完之后 running 变 false', () async {
    final run = AiRun(AiStarted(start(ScriptedTransport(
      [chunk('你'), chunk('好'), 'data: [DONE]\n\n'],
    ))));
    await until('生成结束', () => !run.running.value);
    expect(run.text.value, '你好');
    expect(run.message.value, isEmpty);
    expect(run.started, isTrue);
    run.dispose();
  });

  test('没配 Key：不跑、给一句提示、不转圈', () {
    final run = AiRun(
      const AiNotStarted(AiService.notConfiguredMessage),
    );
    expect(run.started, isFalse);
    expect(run.running.value, isFalse, reason: '没开始就不该转圈');
    expect(run.message.value, contains('设置'));
    expect(run.text.value, isEmpty);
    run.dispose();
  });

  test('出错：message 拿到一句人话，running 必须关掉（否则永远转圈）', () async {
    final run = AiRun(AiStarted(start(ScriptedTransport(
      [chunk('半')],
      // 真实情形：传输层把厂商写的响应体原样带上来，`AiClient` 再把它压成
      // 一句人话（`AiProvider.errorMessage`）。
      error: AiTransportException(
        '{"error":{"message":"invalid api key"}}',
        statusCode: 401,
      ),
    ))));
    await until('拿到错误文案', () => run.message.value.isNotEmpty);
    expect(run.message.value, contains('401'));
    expect(run.message.value, contains('invalid api key'));
    expect(run.text.value, '半', reason: '已经流出来的半截不该被丢掉');
    await until('错误之后停转', () => !run.running.value);
    run.dispose();
  });

  test('停止：不算错误，半截留着，running 关掉', () async {
    final t = ScriptedTransport([chunk('一'), chunk('二')], hang: true);
    final run = AiRun(AiStarted(start(t)));
    await until('两段都到了', () => run.text.value.contains('二'));

    run.stop();
    // `running` 是**同步**被关掉的（用户按下按钮就该立刻看到转圈停），
    // 所以先断言它，再等传输层真的观察到取消。
    expect(run.running.value, isFalse);
    await until('传输层收到取消', () => t.cancelled);
    expect(run.message.value, isEmpty, reason: '停止不是错误');
    expect(run.text.value, contains('二'), reason: '已经拿到的留着');
    run.dispose();
  });

  test('一直在转的生成：停止按钮点得动（running 是可见的）', () async {
    final t = ScriptedTransport([chunk('一')], hang: true);
    final run = AiRun(AiStarted(start(t)));
    await until('开始出字', () => run.text.value.isNotEmpty);
    expect(run.running.value, isTrue, reason: '还没结束，转圈与停止按钮都该在');
    run.stop();
    run.dispose();
  });

  test('超时给一句能看懂的话（不是 DioException 的 toString）', () {
    expect(AiRun.describeError(TimeoutException('x')), contains('超时'));
  });

  test('不认识的异常也给人话，不倒原始对象', () {
    final described = AiRun.describeError(StateError('内部细节'));
    expect(described, contains('失败'));
    expect(described, isNot(contains('内部细节')));
  });

  test('厂商的 4xx 文案带状态码一起给（用户要知道是 Key 不对还是超限）', () {
    expect(
      AiRun.describeError(AiTransportException('invalid api key', statusCode: 401)),
      'AI 返回 401：invalid api key',
    );
    expect(
      AiRun.describeError(AiTransportException('network error')),
      'network error',
    );
  });

  test('截断有一句专门的话（点得出原因，也说得出怎么办）', () {
    final described = AiRun.describeError(const AiTruncatedException());
    expect(described, contains('截断'));
    // 与「没返回内容」那一种分开：后者只会让人一直重试。
    expect(described, isNot(contains('没有返回内容')));
  });

  test('pending：先用它开面板，adopt 之后才真的有内容', () async {
    // 读设置与读 Key 要走钥匙串（异步），用户点下去要有几十毫秒没反应。
    // 先给一个 pending 的 run，面板从那一刻起就开始转圈。
    final run = AiRun.pending();
    expect(run.started, isFalse);
    expect(run.running.value, isTrue, reason: 'pending 要转圈');
    expect(run.text.value, isEmpty);

    run.adopt(AiStarted(start(ScriptedTransport([chunk('接'), 'data: [DONE]\n\n']))));
    await until('拿到内容', () => run.text.value == '接');
    expect(run.started, isTrue);
    run.dispose();
  });

  test('adopt 只生效一次（同一次生成被接两遍会丢增量）', () async {
    final run = AiRun.pending();
    run.adopt(AiStarted(start(ScriptedTransport([chunk('甲'), 'data: [DONE]\n\n']))));
    await until('甲到了', () => run.text.value == '甲');
    // 第二遍本该被忽略：否则第二次的 controller 会顶掉第一次的监听。
    run.adopt(AiStarted(start(ScriptedTransport([chunk('乙'), 'data: [DONE]\n\n']))));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(run.text.value, '甲');
    run.dispose();
  });

  test('pending 之后 adopt 一条「没配 Key」：转圈要停下', () async {
    final run = AiRun.pending();
    expect(run.running.value, isTrue);
    run.adopt(const AiNotStarted('还没有配置 AI'));
    expect(run.running.value, isFalse, reason: '不然就是永远转圈');
    expect(run.message.value, contains('配置'));
    run.dispose();
  });

  test('厂商一个字都没返回 → 给一句话，不留一个转不完的圈', () async {
    // 内容被过滤、或者 max_tokens 太小，都会正常结束但没有内容。
    final run = AiRun(AiStarted(start(ScriptedTransport(['data: [DONE]\n\n']))));
    await until('生成结束', () => !run.running.value);
    expect(run.running.value, isFalse);
    expect(run.message.value, contains('没有返回内容'));
    run.dispose();
  });

  test('撞上长度上限、一个字都没吐 → 说「截断」，不是笼统的「没有返回内容」', () async {
    // 这是用户实际遇到的那一种：网关上的推理模型思考与正文共用 max_tokens，
    // 预算被思考吃光 → content 空 + finish_reason: length。旧实现只报一句
    // 「AI 没有返回内容，请重试」，用户无从下手（换个说法也一样会撞）。
    final run = AiRun(AiStarted(start(ScriptedTransport([
      'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n',
      'data: [DONE]\n\n',
    ]))));
    await until('报出结果', () => run.message.value.isNotEmpty);
    expect(run.text.value, isEmpty);
    expect(run.message.value, contains('截断'));
    expect(run.message.value, isNot(contains('没有返回内容')));
    await until('停转', () => !run.running.value);
    run.dispose();
  });

  test('吐了半截、又被截断 → 半截留着，另加一句提示', () async {
    // 界面上有一句没写完的话却什么都不说，是最容易让人以为「就这样了」的形态。
    final run = AiRun(AiStarted(start(ScriptedTransport([
      'data: {"choices":[{"delta":{"content":"这件事我想说的是"},"finish_reason":"length"}]}\n\n',
      'data: [DONE]\n\n',
    ]))));
    await until('提示出现', () => run.message.value.isNotEmpty);
    expect(run.text.value, '这件事我想说的是', reason: '半截结果要留着，用户想用还能用');
    expect(run.message.value, contains('截断'));
    expect(run.running.value, isFalse);
    run.dispose();
  });

  test('正常写完（finish_reason: stop）不留任何提示', () async {
    final run = AiRun(AiStarted(start(ScriptedTransport([
      'data: {"choices":[{"delta":{"content":"你好"},"finish_reason":"stop"}]}\n\n',
      'data: [DONE]\n\n',
    ]))));
    await until('生成结束', () => !run.running.value);
    expect(run.text.value, '你好');
    expect(run.message.value, isEmpty, reason: '没被截断就别多话');
    run.dispose();
  });

  test('用户自己停的，不算「没有返回内容」（半截留下就好）', () async {
    final run = AiRun(AiStarted(start(ScriptedTransport([chunk('半')], hang: true))));
    await until('拿到半截', () => run.text.value == '半');
    run.stop();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(run.message.value, isEmpty, reason: '停是用户的意思，不该报错');
    expect(run.text.value, '半');
    run.dispose();
  });

  test('pending 阶段就点了停止 → 迟到的 adopt 不能把它又跑起来', () async {
    // 真实路径：点「改写」先开 pending（读设置/读 Key 是异步的），用户在
    // 这几十毫秒里点了停止。此时 `_stream` 还是 null，`stop()` 只能立一个
    // 旗子；随后 `AiStarted` 才姗姗来迟 —— 如果 `_adopt` 不看旗子，它会给
    // 一条已经被放弃的流挂上监听，用户看到「已经停了的生成又自己转了起来」。
    final t = ScriptedTransport([chunk('一'), chunk('二'), 'data: [DONE]\n\n']);
    final run = AiRun.pending();
    expect(run.running.value, isTrue, reason: 'pending 先转圈');

    run.stop();
    expect(run.running.value, isFalse, reason: '按下停止就得立刻停');

    run.adopt(AiStarted(start(t)));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(run.text.value, isEmpty, reason: '已经停了，增量不能再写进来');
    expect(run.running.value, isFalse, reason: '已经停了，不该再转圈');
    expect(t.cancelled, isTrue, reason: '迟到的那次生成要当场取消，别白花钱');
    run.dispose();
  });

  test('pending 停掉、又 adopt 了一条长生成：dispose 时迟到的回调也不炸',
      () async {
    final t = ScriptedTransport([chunk('一')], hang: true);
    final run = AiRun.pending();
    run.stop();
    run.adopt(AiStarted(start(t)));
    run.dispose();
    // 让被取消的流把 onDone / onError 回调投递过来。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(run.text.value, isEmpty);
  });

  test('dispose 之后流才回调 → 不炸（重新生成/关面板每次都会走到这条）',
      () async {
    final run = AiRun(AiStarted(start(ScriptedTransport(
      [chunk('a'), 'data: [DONE]\n\n'],
    ))));
    run.dispose();
    // 让被取消的流把 onDone / onError 回调投递过来。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // 断言的是「没有异常冒出来」——`_set` 在 dispose 之后直接 return。
    expect(run.text.value, isNot('炸了'));
  });
}
