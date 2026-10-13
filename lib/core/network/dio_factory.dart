import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../config/app_defaults.dart';
import '../error/app_exception.dart';
import '../network/auth_events.dart';
import '../network/interceptors/auth_interceptor.dart';
import '../network/interceptors/envelope_interceptor.dart';
import '../util/diag_log.dart';

/// 拦截器之间用来传递「这是第几个请求」的 key。
const String _reqSeqKey = 'diagReqSeq';

/// 为一个实例构造 Dio。
///
/// 两个关键点：
/// 1. `validateStatus` 必须放行一切 —— 服务端 HTTP 状态恒 200，
///    401/403/501/502 全在 body 的 `code` 里，dio 默认会把它们当成功，
///    真正的判定在 [EnvelopeInterceptor]。
/// 2. 附件下载用另一条**无鉴权**的裸 Dio（[buildDownloadDio]），
///    `/api/oss/*` 不需要 token，而且超时要长得多。
class DioFactory {
  const DioFactory._();

  static Dio build({
    required String userApi,
    required String profileId,
    required AuthEvents authEvents,
    required String? Function() readToken,
    required String Function() readLanguage,
    bool enableLog = false,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: userApi,
        connectTimeout: AppDefaults.connectTimeout,
        receiveTimeout: AppDefaults.receiveTimeout,
        sendTimeout: AppDefaults.sendTimeout,
        contentType: Headers.jsonContentType,
        responseType: ResponseType.json,
        // 关键：HTTP 状态恒 200，真实状态在 envelope.code 里。
        validateStatus: (_) => true,
        headers: <String, dynamic>{
          'Accept': Headers.jsonContentType,
          'User-Agent': AppDefaults.userAgent,
        },
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['accept-language'] = readLanguage();
          handler.next(options);
        },
      ),
    );

    dio.interceptors.add(AuthInterceptor(readToken: readToken));

    dio.interceptors.add(
      EnvelopeInterceptor(
        onUnauthorized: (message) {
          authEvents.emitAuthExpired(profileId: profileId, message: message);
        },
      ),
    );

    // 诊断日志**只在 `ProfileRuntime` 里挂一次**（两种建法都会经过那里），
    // 不在这里挂 —— 挂两处同一请求会打两遍。

    return dio;
  }

  /// 附件下载用的裸 Dio：无鉴权、长超时、bytes 响应。
  static Dio buildDownloadDio({bool enableLog = false}) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: AppDefaults.connectTimeout,
        receiveTimeout: AppDefaults.downloadTimeout,
        responseType: ResponseType.stream,
        followRedirects: true,
        validateStatus: (_) => true,
        headers: <String, dynamic>{
          'User-Agent': AppDefaults.userAgent,
        },
      ),
    );

    // 有些自建实例会拒掉自签证书/自定义域，给出明确一点的错误。
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.userAgent = AppDefaults.userAgent;
        return client;
      },
    );

    return dio;
  }

  /// 给一条 Dio 挂上诊断用的请求日志。
  ///
  /// 三个事件都打，**尤其是 `onRequest`** —— 排查「一直转圈」这类问题时，
  /// 唯一有决定性的证据是「请求发出去了、但没有下文」。只在 `onResponse` /
  /// `onError` 里打是不够的：那两种情况都意味着请求已经结束，而卡住的请求
  /// 恰恰**永远不会结束**。
  ///
  /// 超时值一起打出来，是为了能把「卡了 35 秒」和「receiveTimeout 就是 35 秒」
  /// 对起来 —— 否则会误以为是网络慢，其实是配置。
  ///
  /// 由 `ProfileRuntime` 调用（两条 Dio 各一次）。**不要放到 `DioFactory.build`
  /// 里**：注入 Dio 的路径不经过 `build`，而两条路径都会经过 `ProfileRuntime`。
  static void attachDiagLogger(Dio dio, {String scope = 'http'}) {
    if (!DiagLog.enabled) return;
    var seq = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final id = ++seq;
          options.extra[_reqSeqKey] = id;
          DiagLog.log(
            scope,
            '#$id → ${options.method} ${options.uri} '
            '(connect=${options.connectTimeout?.inSeconds}s '
            'recv=${options.receiveTimeout?.inSeconds}s)',
          );
          handler.next(options);
        },
        onResponse: (response, handler) {
          DiagLog.log(
            scope,
            '#${response.requestOptions.extra[_reqSeqKey]} ← '
            'HTTP ${response.statusCode} '
            '${response.requestOptions.method} ${response.requestOptions.uri}',
          );
          handler.next(response);
        },
        onError: (error, handler) {
          DiagLog.log(
            scope,
            '#${error.requestOptions.extra[_reqSeqKey]} ✗ '
            '${error.requestOptions.uri} type=${error.type.name} '
            'status=${error.response?.statusCode} msg=${error.message}',
          );
          handler.next(error);
        },
      ),
    );
  }

  /// 测试/后台隔离用：允许 callers 直接拿到映射好的异常。
  static AppException toAppException(Object error) {
    if (error is AppException) return error;
    if (error is DioException) return mapDioException(error);
    return ServerException(message: error.toString());
  }

  static bool get isReleaseMode => bool.fromEnvironment('dart.vm.product');
}
