import 'package:dio/dio.dart';

import '../network/interceptors/envelope_interceptor.dart';

/// 包在 Dio 外面的一层薄封装：统一异常类型、统一「静默」语义。
///
/// 每个实例一个 ApiClient（见 `instance/profile_runtime.dart`）。
class ApiClient {
  ApiClient(this.dio);

  final Dio dio;

  /// 发起请求并返回拆包后的 `data`。
  ///
  /// [silent] 为 true 时，调用方自己处理错误展示（轮询、后台预取用）。
  Future<T> request<T>(
    String path, {
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? query,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    bool skipAuth = false,
  }) async {
    try {
      final response = await dio.request<dynamic>(
        path,
        data: data,
        queryParameters: _cleanQuery(query),
        cancelToken: cancelToken,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        options: (options ?? Options()).copyWith(
          method: method,
          extra: <String, dynamic>{
            if (skipAuth) 'skipAuth': true,
          },
        ),
      );
      return response.data as T;
    } on DioException catch (e) {
      throw mapDioException(e);
    }
  }

  /// 服务端把空值当缺省，显式传 null 会被序列化成 `key=`（多数接口无害，
  /// 但 `/email/list` 的 `allReceive=` 空串会变成 NaN 走到账户查询分支）。
  Map<String, dynamic>? _cleanQuery(Map<String, dynamic>? query) {
    if (query == null || query.isEmpty) return null;
    final cleaned = <String, dynamic>{};
    for (final entry in query.entries) {
      final value = entry.value;
      if (value == null) continue;
      if (value is String && value.isEmpty) continue;
      cleaned[entry.key] = value;
    }
    return cleaned;
  }
}
