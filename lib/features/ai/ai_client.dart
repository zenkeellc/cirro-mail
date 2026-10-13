import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'ai_provider.dart';
import 'sse.dart';

/// 一次流式生成的句柄。
class AiStream {
  AiStream({
    required this.text,
    required this.done,
    required this.cancel,
    this.truncated,
  });

  /// 增量文本。每次生成**恰好**吐一遍，且只在这里吐（不重复）。
  final Stream<String> text;

  /// 增量吐完之后完成，携带完整结果。
  final Future<String> done;

  /// 取消。取消是正常操作（用户点了停止），不算错误。
  final void Function() cancel;

  /// 「这次是**撞上长度上限**才结束的」。
  ///
  /// 为什么值得从流里单独带出来：它有两种表现，而主播那条「增量文本」的路
  /// **两种都盖不住** ——
  ///
  /// - 一个字都没吐（预算被思考吃光）：`done` 回空串，`AiRun` 只能报一句
  ///   「没有返回内容，请重试」，用户不知道是模型没答、还是话太长；
  /// - 吐了半截：界面上是一句没写完的话，却**没有任何提示**。
  ///
  /// 两处用到它：
  /// 1. [AiClient] 在**一个字都没收到**时抛出 [AiTruncatedException] —— 于是
  ///    界面拿到的是「被截断了」而不是「没返回内容」（见 `AiRun.describeError`）；
  /// 2. 半截内容的提示由调用方按这个 future 自己决定要不要提（`AiRun` 在
  ///    `done` 之后读它，给消息加一句「可能被截断」）。
  ///
  /// 在流的**每一个**事件里判定（不只看最后一个）：有些兼容端点的收尾事件是
  /// `choices: []` 的空壳，`finish_reason` 只在前面某一帧出现过 —— 只看最后
  /// 一帧就会漏掉。认「出现过」而不是「最后一帧写着」。
  final Future<bool>? truncated;
}

/// 传输层抽象。真实现走 `dio`；测试注入假实现，于是「分帧 + 错误映射 + 取消」
/// 全都能离线测 —— 这些正是最容易出错、又最难在 UI 上看出来的部分。
abstract class AiTransport {
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  });

  /// 非流式请求：拿一小段 JSON 回来（列模型、连接测试走这条）。
  ///
  /// 失败抛 [AiTransportException]（4xx/5xx 带原始 body 与状态码，网络错误带
  /// message）—— 与 [send] **同一套错误约定**，于是上层（`AiService`）能用同一条
  /// `AiProvider.redactSecrets` 链按值脱敏。注意这条通道本身**不做脱敏**：
  /// `AiClient._normalize` 只在 `stream()` 的 catch 里跑，`request` 的调用方
  /// 必须自己过脱敏。**[method] 是 HTTP 方法**（`send` 恒为 POST，所以它没有
  /// 这个参数）。
  Future<String> request({
    required String method,
    required String url,
    required Map<String, String> headers,
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  });
}

class AiTransportException implements Exception {
  const AiTransportException(this.message, {this.statusCode});

  /// 给人看的一句话。**可能仍含有厂商写的原文**，所以它只该被界面/提示层直接
  /// 使用；任何字符串化（toString、日志、crash reporter）都不该带上它 ——
  /// 见 [toString]。密钥的脱敏在构造前由 `_normalize` 完成。
  final String message;
  final int? statusCode;

  /// **刻意不带 [message]**。
  ///
  /// 厂商的 401 响应体常把用户提交的 key 原样回显，脱敏是「尽力而为」而不是
  /// 证明：任何 crash reporter、`debugPrint('$e')`、日志序列化都会走 toString。
  /// 与其赌脱敏不漏，不如让 toString 根本不输出 message —— 状态码足够定位
  /// 「是认证失败还是限流」，而真正的文案由界面从 [message] 显式取用。
  @override
  String toString() => 'AiTransportException($statusCode)';
}

/// 生成期间被取消。与「出错」分开 —— 它的表现是安静地停下，不该弹错误提示。
class AiCancelledException implements Exception {
  const AiCancelledException();
}

/// 生成**撞上了长度上限、而且一个字都没吐出来**。
///
/// 只有「空 + 截断」才抛它：吐了半截的情况下界面上有内容可看，不必当错误
/// （那种情况由 [AiStream.truncated] 带出「可能被截断」的提示）。
///
/// 与厂商错误分开的意义：这不是「端点配错了」，是「这次预算不够」—— 界面
/// 该说的那句话完全不同（见 `AiRun.describeError`）。
class AiTruncatedException implements Exception {
  const AiTruncatedException();
}

/// 流式底座：发请求 → 解 SSE → 吐文本。厂商差异全在 [AiProvider] 里。
class AiClient {
  AiClient({AiTransport? transport})
      : _transport = transport ?? DioAiTransport();

  final AiTransport _transport;

  /// 开始一次生成。
  ///
  /// [apiKey] 只在这条调用链里活着：不进字段、不进日志、不进异常消息。
  AiStream stream({
    required AiProvider provider,
    required AiRequest request,
    required String apiKey,
  }) {
    final controller = StreamController<String>();
    final cancelToken = CancelToken();
    final buffer = StringBuffer();
    // 解码器必须**每次生成一个**，而且要活在闭包里（不能用 Expando 之类
    // 跟着 controller 走 —— 那会把「这次生成」和「这个 controller」绑死，
    // 且拿不到确定性的生命周期）。
    final decoder = SseDecoder();
    var finished = false;
    var finishedClosing = false;
    Object? failure;
    // 流里**出现过**「撞上长度上限」的帧。每个事件都判一次（不只看最后一个）：
    // 有些端点的收尾帧是 `choices: []` 的空壳，`finish_reason` 只在前面某一帧
    // 出现过，只看最后一帧会漏。
    var truncated = false;

    Future<void> run() async {
      try {
        await _transport.send(
          url: provider.endpoint,
          headers: provider.headers(apiKey),
          body: provider.body(request),
          onChunk: (chunk) {
            if (finished) return;
            for (final event in decoder.add(chunk)) {
              if (event.isDone) continue;
              if (provider.isTruncated(event.data)) truncated = true;
              final text = provider.textDelta(event.data);
              if (text == null || text.isEmpty) continue;
              buffer.write(text);
              if (!controller.isClosed) controller.add(text);
            }
          },
          cancelToken: cancelToken,
        );
        // 有些兼容端点最后一个事件后面没有空行，收尾时要补出来。
        final last = decoder.finish();
        if (last != null && !last.isDone) {
          if (provider.isTruncated(last.data)) truncated = true;
          final text = provider.textDelta(last.data);
          if (text != null && text.isNotEmpty) {
            buffer.write(text);
            if (!controller.isClosed) controller.add(text);
          }
        }
      } on AiCancelledException {
        // 取消不算错。
      } catch (error) {
        failure = _normalize(error, provider, apiKey);
        if (!controller.isClosed) controller.addError(failure!);
      } finally {
        finished = true;
        // **撞上上限而且一个字都没吐**：这是一条可解释的失败，不该落到「没有
        // 返回内容，请重试」那种无从下手的话上（见 [AiTruncatedException]）。
        // 与上面那支厂商错误**走同一条路**：先 `addError` 给增量流（界面据此
        // 立刻报出「截断」），再在下面对 `done` 抛出 —— 少任一处置，调用方
        // 就会先收到一次「没有返回内容」，语义反了。
        if (failure == null && truncated && buffer.isEmpty) {
          failure = const AiTruncatedException();
          if (!controller.isClosed) controller.addError(failure!);
        }
        // 关闭是同步排队的，所以「不 await」不会丢事件；但**投递**是异步的：
        // `add()` 把事件排进微任务队列，而 run() 一返回 `done` 就完成了 ——
        // 于是 `await done` 会**先于**最后几段增量拿到结果。调用方在 done 里
        // 用完整结果覆盖浮层、随后迟到的增量又被追加一遍，用户看到最后几个字
        // 重复。所以在**有人监听**时等 close 完成，把顺序钉死。
        //
        // 而**无人监听**时绝不能等：单订阅 StreamController 的 `close()` future
        // 要等 done 事件真的投递出去才完成，没人听就永远不完成 —— `done` 于是
        // 挂死（表现是「生成永远不结束」）。这正是 Task D3 那条注释说的坑，
        // 只是它的解法不是「一律不等」，而是「看有没有人在听」。
        if (!finishedClosing) {
          finishedClosing = true;
          // 有人听才等：没人听就 unawaited（见下）。
          final listened = controller.hasListener;
          final closing =
              controller.isClosed ? controller.done : controller.close();
          if (listened) {
            try {
              await closing;
            } catch (_) {
              // 监听者的 onError 抛错不该改变 `done` 的结论。
            }
          } else {
            unawaited(closing.catchError((Object _) {}));
          }
        }
      }
      // **失败要一路传到 [AiStream.done]**。只 addError 到 text 流上是不够的：
      // 「把增量写进浮层」的调用方通常只 await done，若 done 静默返回半截
      // 文本，界面会把一次失败的生成当成成功。
      if (failure != null) throw failure!;
    }

    // **只调一次**（`run()` 是真正发请求的那一段）—— 两条结论共用同一个 future。
    final runFuture = run();
    // 截断结论**永不抛错**（哪怕 run 失败了）：它是「这次有没有撞上限」这个
    // 事实的答案，本身不是「这次生成了什么」的成败。而且调用方挂的是
    // `truncated.then(_applyTruncated)` 这种**不带 onError** 的写法 —— 让它跟着
    // run 一起抛，就是一个没人接的异步异常（会被 Flutter 当崩溃上报）。
    final truncatedResult = runFuture.then<bool>(
      (_) => truncated,
      onError: (Object _) => truncated,
    );
    final done = runFuture.then((_) => buffer.toString());
    // **给 done 挂一个吞掉的处理器**：只监听 [AiStream.text] 的调用方（比如
    // 把增量直接写进浮层、根本不 await 完整结果的界面）不会给 done 挂 onError，
    // 那时一个失败会在 zone 里冒成「未处理异常」，被 Flutter 当成崩溃上报。
    // 这个 catchError 只是把 done「标成已监听」，不改变它的可见行为。
    unawaited(done.catchError((Object _) => ''));
    // 截断那条结论**也要挂一个吞掉的处理器**：调用方可能只看 `text`（不看它）。
    // 少了这一句，生成失败时它会在 zone 里冒成「未处理异常」。
    unawaited(truncatedResult.catchError((Object _) => false));

    return AiStream(
      // 单订阅流：一次生成只该有一个消费者。
      text: controller.stream,
      done: done,
      truncated: truncatedResult,
      cancel: () {
        if (finished) return;
        if (!cancelToken.isCancelled) cancelToken.cancel('user');
        if (!controller.isClosed) controller.close();
      },
    );
  }

  /// 一次非流式请求。**不做脱敏、不解析** —— 那一层在 `AiService`（它手上有
  /// Key，才能按值精确替换）。
  Future<String> request({
    required String method,
    required String url,
    required Map<String, String> headers,
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  }) =>
      _transport.request(
        method: method,
        url: url,
        headers: headers,
        body: body,
        cancelToken: cancelToken,
      );

  /// 把厂商的错误外壳压成一条给人看的话。不认识的形状退到「HTTP xxx」——
  /// 宁可粗糙，也不要把整段 JSON 倒在界面上。
  ///
  /// [apiKey] 一路从 `stream()` 带下来：脱敏靠「按值精确替换已知 key」这一层
  /// 兜底，光靠形状猜不出所有厂商的 key 形态（见 `AiProvider.redactSecrets`）。
  static Object _normalize(Object error, AiProvider provider, String apiKey) {
    if (error is AiTransportException) {
      return AiTransportException(
        provider.errorMessage(error.statusCode ?? 0, error.message, apiKey: apiKey),
        statusCode: error.statusCode,
      );
    }
    return error;
  }
}

/// 真实现。
class DioAiTransport implements AiTransport {
  DioAiTransport({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              // 流式响应可能很长，所以不设总超时，只留「连上」与「块间」两道。
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 120),
              responseType: ResponseType.stream,
            ));

  final Dio _dio;

  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async {
    try {
      final response = await _dio.post<ResponseBody>(
        url,
        data: body,
        options: Options(
          headers: headers,
          // 4xx 也要读 body：厂商把「Key 不对」的原因写在里面。
          validateStatus: (status) => status != null && status < 500,
        ),
        cancelToken: cancelToken,
      );

      final status = response.statusCode ?? 0;
      if (status >= 400) {
        final raw = await _readAll(response.data);
        throw AiTransportException(raw.isEmpty ? 'HTTP $status' : raw,
            statusCode: status);
      }

      final stream = response.data?.stream;
      if (stream == null) {
        throw AiTransportException('empty body', statusCode: status);
      }

      // **增量**解码。绝不能对每个字节块单独 `utf8.decode` —— 一个中文字
      // 占三字节，被网络切在中间时会被解成 U+FFFD（用户看到「你好」变「��」）。
      final sink = _ChunkSink(onChunk);
      final converter =
          const Utf8Decoder(allowMalformed: true).startChunkedConversion(sink);
      await for (final bytes in stream) {
        converter.add(bytes);
      }
      converter.close();
    } on DioException catch (error) {
      _throwDio(error);
    }
  }

  @override
  Future<String> request({
    required String method,
    required String url,
    required Map<String, String> headers,
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.request<String>(
        url,
        data: body,
        options: Options(
          method: method,
          headers: headers,
          // 与 `send` 同一条约定：4xx 也要读 body，厂商把原因写在里面。
          validateStatus: (status) => status != null && status < 500,
          // 与 `send` 的 ResponseType.stream 不同：这一条要整段文本。
          responseType: ResponseType.plain,
        ),
        cancelToken: cancelToken,
      );

      final status = response.statusCode ?? 0;
      final raw = response.data ?? '';
      if (status >= 400) {
        throw AiTransportException(
            raw.isEmpty ? 'HTTP $status' : raw, statusCode: status);
      }
      return raw;
    } on DioException catch (error) {
      _throwDio(error);
    }
  }

  /// 把 `DioException` 映射成传输层的错误约定。`send` 与 `request` **必须**共用
  /// 这一段：少了「取消 → [AiCancelledException]、优先用非空 body 顶掉
  /// `error.message`」这两条里的任何一条，「同一套错误约定」就不成立。两条通道的
  /// **成功**路径不同（流 vs 整段文本），所以只共享这一段。
  static Never _throwDio(DioException error) {
    if (error.type == DioExceptionType.cancel) {
      throw const AiCancelledException();
    }
    final status = error.response?.statusCode;
    final raw = error.response?.data;
    throw AiTransportException(
      raw is String && raw.isNotEmpty ? raw : (error.message ?? 'network error'),
      statusCode: status,
    );
  }

  static Future<String> _readAll(ResponseBody? body) async {
    if (body == null) return '';
    final chunks = <int>[];
    await for (final bytes in body.stream) {
      chunks.addAll(bytes);
    }
    return utf8.decode(chunks, allowMalformed: true);
  }
}

/// `Utf8Decoder` 的增量接口要一个 `Sink<String>`。
class _ChunkSink implements Sink<String> {
  _ChunkSink(this._onText);

  final void Function(String) _onText;

  @override
  void add(String data) => _onText(data);

  @override
  void close() {}
}
