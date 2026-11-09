import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_provider.dart';

/// 假传输：按预设的 chunk 序列喂回来。
class FakeTransport implements AiTransport {
  FakeTransport(this.chunks, {this.error});

  final List<String> chunks;
  final Object? error;
  bool cancelled = false;
  Map<String, String>? lastHeaders;
  Map<String, dynamic>? lastBody;
  String? lastUrl;

  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async {
    lastUrl = url;
    lastHeaders = headers;
    lastBody = body;
    for (final c in chunks) {
      if (cancelToken.isCancelled) {
        cancelled = true;
        throw const AiCancelledException();
      }
      onChunk(c);
      await Future<void>.delayed(Duration.zero);
    }
    if (error != null) throw error!;
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

/// 记录每一次非流式请求，按预设返回一段响应体（或抛预设的错）。
class RecordingTransport implements AiTransport {
  RecordingTransport(this.response, {this.error});

  final String response;
  final Object? error;
  String? lastMethod;
  String? lastUrl;
  Map<String, String>? lastHeaders;
  Map<String, dynamic>? lastBody;

  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async =>
      // 只服务非流式通道。像旁边几个假传输一样**大声失败**，而不是静默完成 ——
      // 万一有人误把 stream() 接到这里，应该立刻炸，而不是拿到一个空结果。
      throw UnimplementedError('这个假传输只用来测非流式通道');

  @override
  Future<String> request({
    required String method,
    required String url,
    required Map<String, String> headers,
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  }) async {
    lastMethod = method;
    lastUrl = url;
    lastHeaders = headers;
    lastBody = body;
    if (error != null) throw error!;
    return response;
  }
}

const openai = AiProvider(
  format: AiApiFormat.openai,
  model: 'm',
  baseUrl: 'https://api.openai.com/v1',
);
const req = AiRequest(system: 'S', prompt: 'P');

String openaiChunk(String text) =>
    'data: {"choices":[{"delta":{"content":"$text"}}]}\n\n';

/// 会一直挂着直到被取消的假传输 —— 用来测取消，不用 `Future.delayed` 抢时序。
class BlockingTransport implements AiTransport {
  BlockingTransport(this.initial);

  final List<String> initial;
  bool cancelled = false;

  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async {
    for (final text in initial) {
      onChunk(openaiChunk(text));
    }
    while (!cancelToken.isCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    cancelled = true;
    throw const AiCancelledException();
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

void main() {
  test('一次生成：增量与完整结果都对', () async {
    final t = FakeTransport([openaiChunk('你'), openaiChunk('好'), 'data: [DONE]\n\n']);
    final client = AiClient(transport: t);
    final stream = client.stream(provider: openai, request: req, apiKey: 'k');
    final parts = await stream.text.toList();
    expect(parts, ['你', '好']);
    expect(await stream.done, '你好');
    expect(t.lastUrl, 'https://api.openai.com/v1/chat/completions');
    expect(t.lastHeaders!['authorization'], 'Bearer k');
    expect(t.lastBody!['stream'], isTrue);
  });

  test('done 不会抢在最后一段增量前面完成', () async {
    // 这是个真实的竞态：controller.close() 只是把 done 事件同步排进队列，
    // 投递是异步的 —— 不等它的话 `await done` 会先返回完整结果，界面拿它
    // 覆盖浮层，随后迟到的最后几段增量又被追加一遍，用户看到末尾重复。
    final t = FakeTransport([openaiChunk('甲'), openaiChunk('乙')]);
    final client = AiClient(transport: t);
    final stream = client.stream(provider: openai, request: req, apiKey: 'k');
    final order = <String>[];
    stream.text.listen((part) {
      order.add('text:$part');
      if (part == '乙') order.add('last-chunk');
    });
    expect(await stream.done, '甲乙');
    order.add('done');
    expect(order.last, 'done');
    expect(order[order.length - 2], 'last-chunk');
  });

  test('没人监听 text 时 done 照样完成（不能挂死）', () async {
    // 无人监听的单订阅 StreamController，`close()` 的 future 要等 done 事件
    // 真的投递出去才完成 —— 没人听就永远不完成。所以「有人听才 await」。
    final t = FakeTransport([openaiChunk('甲')]);
    final client = AiClient(transport: t);
    final stream = client.stream(provider: openai, request: req, apiKey: 'k');
    expect(await stream.done.timeout(const Duration(seconds: 5)), '甲');
  });

  test('SSE 事件被切在字节边界上也不丢字', () async {
    final whole = openaiChunk('abc') + openaiChunk('def');
    final t = FakeTransport([
      whole.substring(0, 20),
      whole.substring(20, 40),
      whole.substring(40),
    ]);
    final client = AiClient(transport: t);
    final stream = client.stream(provider: openai, request: req, apiKey: 'k');
    expect(await stream.done, 'abcdef');
  });

  test('最后一个事件没收尾空行 → finish 时补出来', () async {
    final t = FakeTransport(['data: {"choices":[{"delta":{"content":"尾"}}]}\n']);
    final client = AiClient(transport: t);
    final stream = client.stream(provider: openai, request: req, apiKey: 'k');
    expect(await stream.done, '尾');
  });

  test('Anthropic 的帧也能解', () async {
    final t = FakeTransport([
      'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"甲"}}\n\n',
      'data: {"type":"content_block_stop"}\n\n',
    ]);
    final client = AiClient(transport: t);
    final stream = client.stream(
        provider: const AiProvider(
          format: AiApiFormat.anthropic,
          model: 'm',
          baseUrl: AiProvider.anthropicDefaultBase,
        ),
        request: req,
        apiKey: 'k');
    expect(await stream.done, '甲');
  });

  test('心跳与未知帧被忽略，不影响结果', () async {
    final t = FakeTransport([
      ': ping\n\n',
      'data: {"type":"ping"}\n\n',
      openaiChunk('ok'),
      'data: [DONE]\n\n',
    ]);
    final client = AiClient(transport: t);
    final stream = client.stream(provider: openai, request: req, apiKey: 'k');
    expect(await stream.done, 'ok');
  });

  test('传输层错误：done 抛错，text 流上也带 error（不是静默结束）', () async {
    final t = FakeTransport([
      'data: {"choices":[{"delta":{"content":"半"}}]}\n\n',
    ], error: AiTransportException('{"error":{"message":"invalid key"}}', statusCode: 401));
    final client = AiClient(transport: t);
    final stream = client.stream(provider: openai, request: req, apiKey: 'bad');
    final parts = <String>[];
    Object? streamError;
    final closed = Completer<void>();
    stream.text.listen(
      parts.add,
      onError: (Object e) => streamError = e,
      onDone: closed.complete,
    );
    final doneError = await stream.done.then<Object?>(
      (String _) => null,
      onError: (Object e) => e,
    );
    await closed.future;
    expect(parts, ['半'], reason: '已经流出来的半截不该被丢掉');
    expect(streamError, isA<AiTransportException>());
    expect((streamError! as AiTransportException).message, 'invalid key');
    expect(doneError, isA<AiTransportException>());
  });

  group('撞上长度上限（truncated / AiTruncatedException）', () {
    test('一个字都没吐 + finish_reason: length → done 抛 AiTruncatedException', () async {
      final t = FakeTransport([
        'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n',
        'data: [DONE]\n\n',
      ]);
      final client = AiClient(transport: t);
      final stream = client.stream(provider: openai, request: req, apiKey: 'k');
      // text 上也带着同一个错 —— 界面据此立刻报「截断」而不是等 done。
      Object? streamError;
      stream.text.listen((_) {}, onError: (Object e) => streamError = e);
      final doneError = await stream.done.then<Object?>(
        (String _) => null,
        onError: (Object e) => e,
      );
      expect(doneError, isA<AiTruncatedException>());
      expect(streamError, isA<AiTruncatedException>());
      expect(await stream.truncated, isTrue);
    });

    test('吐了半截再截断 → 不算错误，半截照旧，truncated 为 true', () async {
      final t = FakeTransport([
        'data: {"choices":[{"delta":{"content":"半截"}}]}\n\n',
        'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n',
        'data: [DONE]\n\n',
      ]);
      final client = AiClient(transport: t);
      final stream = client.stream(provider: openai, request: req, apiKey: 'k');
      Object? streamError;
      stream.text.listen((_) {}, onError: (Object e) => streamError = e);
      // 有内容可看，不该当失败 —— 提示由调用方按 truncated 自己加（AiRun）。
      expect(await stream.done, '半截');
      expect(streamError, isNull);
      expect(await stream.truncated, isTrue);
    });

    test('正常写完 → truncated 为 false，done 不抛', () async {
      final t = FakeTransport([openaiChunk('你好'), 'data: [DONE]\n\n']);
      final client = AiClient(transport: t);
      final stream = client.stream(provider: openai, request: req, apiKey: 'k');
      expect(await stream.done, '你好');
      expect(await stream.truncated, isFalse);
    });

    test('没有这个结论时（假传输不发 finish_reason）也不误报', () async {
      final t = FakeTransport(['data: [DONE]\n\n']);
      final client = AiClient(transport: t);
      final stream = client.stream(provider: openai, request: req, apiKey: 'k');
      // 「空 + 没截断」仍然是那句笼统的「没有返回内容」——由 AiRun 兜。
      expect(await stream.done, '');
      expect(await stream.truncated, isFalse);
    });

    test('厂商错误优先于截断结论（真错误要原样冒出来）', () async {
      final t = FakeTransport([
        'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n',
      ], error: const AiTransportException('boom', statusCode: 500));
      final client = AiClient(transport: t);
      final stream = client.stream(provider: openai, request: req, apiKey: 'k');
      final doneError = await stream.done.then<Object?>(
        (String _) => null,
        onError: (Object e) => e,
      );
      expect(doneError, isA<AiTransportException>());
    });
  });

  test('取消：安静停下，不算错误', () async {
    final t = BlockingTransport(['一']);
    final client = AiClient(transport: t);
    final stream = client.stream(provider: openai, request: req, apiKey: 'k');
    final parts = <String>[];
    Object? caught;
    final closed = Completer<void>();
    stream.text.listen(
      parts.add,
      onError: (Object e) => caught = e,
      onDone: closed.complete,
    );
    // 等第一段增量真的出来了再取消，否则测的是「取消一个还没开始的流」。
    while (parts.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    stream.cancel();
    await closed.future.timeout(const Duration(seconds: 5));
    // 先等 done：它要等传输层真的观察到取消才算完，此时 t.cancelled 才可靠。
    expect(await stream.done, '一', reason: '取消后 done 仍给出已生成的部分');
    expect(caught, isNull, reason: '取消不是错误');
    expect(t.cancelled, isTrue);
    expect(parts, ['一']);
  });

  test('重复 cancel 是幂等的（用户可能连点两下停止）', () async {
    final t = BlockingTransport(['一']);
    final client = AiClient(transport: t);
    final stream = client.stream(provider: openai, request: req, apiKey: 'k');
    final closed = Completer<void>();
    stream.text.listen((_) {}, onDone: closed.complete);
    await Future<void>.delayed(Duration.zero);
    stream.cancel();
    stream.cancel();
    await closed.future.timeout(const Duration(seconds: 5));
    expect(await stream.done, '一');
  });

  test('Key 不出现在 provider 的 body 里（只在 header）', () async {
    final t = FakeTransport(['data: [DONE]\n\n']);
    final client = AiClient(transport: t);
    await client
        .stream(provider: openai, request: req, apiKey: 'sk-secret')
        .done;
    expect(t.lastBody.toString().contains('sk-secret'), isFalse);
    expect(t.lastHeaders!['authorization'], 'Bearer sk-secret');
  });

  test('C-1 端到端：401 回显的 Key 不进最终异常的 message 与 toString', () async {
    // 假 transport 抛出的原始异常里带着 key（模拟厂商把 key 回显进错误体）。
    const key = 'sk-live-end2end';
    final t = FakeTransport(
      const [],
      error: AiTransportException(
        '{"error":{"message":"Incorrect API key provided: sk-live-end2end"}}',
        statusCode: 401,
      ),
    );
    final client = AiClient(transport: t);
    final stream = client.stream(provider: openai, request: req, apiKey: key);
    final error = await stream.done.then<Object?>(
      (String _) => null,
      onError: (Object e) => e,
    );
    expect(error, isA<AiTransportException>());
    final ex = error! as AiTransportException;
    expect(ex.message.contains(key), isFalse, reason: 'message 里不能有 key');
    expect(ex.toString().contains(key), isFalse, reason: 'toString 里不能有 key');
  });

  test('C-1：AiTransportException.toString 只给类型与状态码', () {
    final ex = AiTransportException('some message', statusCode: 401);
    expect(ex.toString(), 'AiTransportException(401)');
    expect(ex.toString().contains('some message'), isFalse);
  });

  group('非流式通道（列模型 / 连接测试用）', () {
    test('方法、地址、头、体原样传给传输层，响应体原样回来', () async {
      final t = RecordingTransport('{"data":[{"id":"m1"}]}');
      final client = AiClient(transport: t);
      final body = await client.request(
        method: 'GET',
        url: 'https://api.openai.com/v1/models',
        headers: const {'authorization': 'Bearer k'},
      );
      expect(body, '{"data":[{"id":"m1"}]}');
      expect(t.lastMethod, 'GET');
      expect(t.lastUrl, 'https://api.openai.com/v1/models');
      expect(t.lastHeaders!['authorization'], 'Bearer k');
      expect(t.lastBody, isNull);
    });

    test('带 body 的 POST 也走得通（连接测试）', () async {
      final t = RecordingTransport('{"choices":[{"message":{"content":"hi"}}]}');
      final client = AiClient(transport: t);
      await client.request(
        method: 'POST',
        url: 'https://x/v1/chat/completions',
        headers: const {'authorization': 'Bearer k'},
        body: const {'model': 'm', 'messages': <dynamic>[]},
      );
      expect(t.lastMethod, 'POST');
      expect(t.lastBody!['model'], 'm');
    });

    test('传输层抛的错连状态码与 message 一起原样冒出去（脱敏在 AiService 那层做）', () async {
      final t = RecordingTransport('',
          error: const AiTransportException('boom', statusCode: 404));
      final client = AiClient(transport: t);
      final caught = await client
          .request(
            method: 'GET',
            url: 'https://x/models',
            headers: const {},
          )
          .then<Object?>((String _) => null, onError: (Object e) => e);
      expect(caught, isA<AiTransportException>());
      // 只断言类型太松：任何 AiTransportException 都能过。这里钉死「原样」——
      // 状态码与 message 都得是假传输抛出来的那两个，AiClient 不许动它们
      // （脱敏是 AiService 的活）。
      final ex = caught! as AiTransportException;
      expect(ex.statusCode, 404);
      expect(ex.message, 'boom');
    });
  });

  group('DioAiTransport 的非流式通道（真 dio + 假适配器）', () {
    test('200 时响应体整段字符串原样回来（顺带证明 ResponseType.plain）', () async {
      // 用的是**真** DioAiTransport（不是假传输），只把传输底座换成假
      // HttpClientAdapter：于是 method/validateStatus/ResponseType.plain 以及
      // 4xx 的手工映射这几段真代码才第一次被执行到。返回的是 `Response<String>`
      // 的整段字符串 —— 若 ResponseType 退化成默认的 json，这里会拿到 decode 后
      // 的 Map，类型都不对。第 4 条要求由本用例覆盖，不再叠加重复用例。
      final f = _dioWith('{"data":[{"id":"m1"}]}', status: 200);
      final t = DioAiTransport(dio: f.dio);
      final body = await t.request(
        method: 'GET',
        url: 'https://api.openai.com/v1/models',
        headers: const {'authorization': 'Bearer k'},
      );
      expect(body, '{"data":[{"id":"m1"}]}');
    });

    test('404：带 JSON body → AiTransportException 带状态码与原始 body', () async {
      // 4xx 在 dio 层是「成功」（validateStatus: status < 500），抛异常是
      // transport 自己的活。body 必须原样带上 —— AiService 靠它按值脱敏。
      const raw = '{"error":{"message":"invalid key"}}';
      final f = _dioWith(raw, status: 404);
      final t = DioAiTransport(dio: f.dio);
      final caught = await t
          .request(
            method: 'GET',
            url: 'https://x/v1/models',
            headers: const {},
          )
          .then<Object?>((Object? _) => null, onError: (Object e) => e);
      expect(caught, isA<AiTransportException>());
      final ex = caught! as AiTransportException;
      expect(ex.statusCode, 404);
      expect(ex.message, raw);
    });

    test('HTTP 方法真的落到线上（GET，以及带 body 的 POST）', () async {
      final get = _dioWith('{}', status: 200);
      await DioAiTransport(dio: get.dio).request(
          method: 'GET', url: 'https://x/v1/models', headers: const {});
      expect(get.adapter.lastOptions!.method, 'GET');

      final post = _dioWith('{}', status: 200);
      await DioAiTransport(dio: post.dio).request(
        method: 'POST',
        url: 'https://x/v1/chat/completions',
        headers: const {'content-type': 'application/json'},
        body: const {'model': 'm'},
      );
      expect(post.adapter.lastOptions!.method, 'POST');
      // 方法之外，body 也真的编码进了请求流。
      expect(post.adapter.lastBody, contains('"model":"m"'));
    });
  });
}

// ------------------------------------------------------------------ 测试替身

/// 一个真 `Dio`（只换掉传输底座）+ 记录请求的假适配器。
_DioFixture _dioWith(String text, {required int status}) {
  final adapter = _RecordingAdapter(_body(text, status: status));
  final dio = Dio(BaseOptions(validateStatus: (_) => true))
    ..httpClientAdapter = adapter;
  return _DioFixture(dio, adapter);
}

/// 固定的 JSON 响应体（非流式通道一律走 ResponseType.plain，所以头只需像真的）。
ResponseBody _body(String text, {required int status}) {
  final bytes = utf8.encode(text);
  return ResponseBody(
    Stream<Uint8List>.fromIterable(<Uint8List>[Uint8List.fromList(bytes)]),
    status,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json;charset=utf-8'],
      Headers.contentLengthHeader: <String>['${bytes.length}'],
    },
  );
}

class _DioFixture {
  _DioFixture(this.dio, this.adapter);

  final Dio dio;
  final _RecordingAdapter adapter;
}

/// 记录被交到线上的 `RequestOptions` 与请求体，回一个固定响应。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this._response);

  final ResponseBody _response;
  RequestOptions? lastOptions;
  String? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    // 请求体分块送进来，收拢后按 UTF-8 读回 —— 这样能证明 body 真的上了线。
    if (requestStream != null) {
      final chunks = <int>[];
      await for (final bytes in requestStream) {
        chunks.addAll(bytes);
      }
      lastBody = utf8.decode(chunks, allowMalformed: true);
    }
    return _response;
  }

  @override
  void close({bool force = false}) {}
}
