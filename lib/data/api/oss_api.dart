import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/error/app_exception.dart';
import '../../core/network/api_envelope.dart';

/// 附件下载。
///
/// 三点与普通 API 不同，所以单独一个文件：
/// 1. **免鉴权** —— `/api/oss/<key>` 与历史数据里的完整 CDN URL 都不要 token，
///    用 [ApiClient] 那条带 Authorization 的 Dio 会把 token 泄漏给第三方 CDN。
///    这里收一条裸 Dio（`DioFactory.buildDownloadDio`）。
/// 2. **失败也是 HTTP 200** —— 对象不存在时返回
///    `{"code":500,"message":"Cannot read properties of null (reading 'body')"}`。
///    必须嗅探响应，否则会把 72 字节的 JSON 当附件写盘。
/// 3. **流式落盘** —— 用 [downloadTo] 把响应流直接接到文件，不经过内存，
///    大附件才不会把 App 打爆。
class OssApi {
  OssApi(this._dio);

  final Dio _dio;

  /// 把 [url] 下载到 [savePath]。
  ///
  /// 返回实际写入的字节数。抛 [AttachmentNotAvailableException] 表示
  /// 服务端说「这个 key 没有对象」，[NetworkException] 表示真的没连上。
  Future<int> downloadTo({
    required String url,
    required String savePath,
    required Future<void> Function(Stream<List<int>> stream, int expectedBytes)
        writeTo,
    CancelToken? cancelToken,
    ProgressCallback? onProgress,
  }) async {
    if (url.isEmpty) {
      throw const AttachmentNotAvailableException(detail: 'key 为空');
    }

    Response<ResponseBody> response;
    try {
      response = await _dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw _mapDownloadError(e);
    }

    final body = response.data;
    if (body == null) {
      throw const AttachmentNotAvailableException(detail: '响应体为空');
    }

    // `application/json` 是「没找到对象」的信号；正常附件不会是这个类型。
    if (_looksLikeJson(response.headers)) {
      throw AttachmentNotAvailableException(
        detail: '服务端返回 JSON 而非文件（content-type: '
            '${response.headers.value('content-type')}）',
      );
    }

    // Content-Length 可能被压缩/分块，拿不到就按 0（调用方只用于显示）。
    final contentLength = body.contentLength;

    await writeTo(body.stream, contentLength);
    return contentLength;
  }

  /// 建 [CancelToken] 的便捷方法，让 UI 层不用直接依赖 dio。
  CancelToken cancelToken() => CancelToken();

  static bool _looksLikeJson(Headers headers) {
    final contentType = headers.value('content-type')?.toLowerCase() ?? '';
    return contentType.contains('application/json') ||
        contentType.contains('text/html') ||
        contentType.contains('application/xml');
  }

  static AppException _mapDownloadError(DioException e) {
    switch (e.type) {
      case DioExceptionType.cancel:
        return const RequestCancelledException();
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return TimeoutException(detail: e.message);
      default:
        // 4xx/5xx 也可能带信封（老实例把 /api/oss 也包了一层）。
        final envelope = ApiEnvelope.tryParse(e.response?.data);
        if (envelope != null && !envelope.isOk) {
          return AttachmentNotAvailableException(detail: envelope.message);
        }
        return NetworkException(detail: e.message);
    }
  }
}
