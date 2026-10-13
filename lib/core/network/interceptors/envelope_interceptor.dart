import 'dart:convert';

import 'package:dio/dio.dart';

import '../../error/app_exception.dart';
import '../api_envelope.dart';

/// 把 `{code,message,data}` 信封拆开：
/// - `code == 200` → 直接把 `data` 交给调用方（`Map` / `List` / `null`）
/// - `401` → 清 token + 广播 AuthEvents，抛 [AuthExpiredException]
/// - 其余非 200 → 抛 [ApiException]
class EnvelopeInterceptor extends Interceptor {
  EnvelopeInterceptor({
    required this.onUnauthorized,
    this.silentExtra = const <String>{},
  });

  /// 401 时的回调（清 token、广播事件）。由 ApiClient 注入。
  final void Function(String message) onUnauthorized;

  /// 额外需要「静默失败」的路径（例如 /email/latest 的轮询）。
  final Set<String> silentExtra;

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final envelope = ApiEnvelope.tryParse(response.data);

    if (envelope == null) {
      // email/send 这类接口成功后返回的是数组，不会是信封 —— 只有当我们真的拿到
      // 一个「看起来像信封但不是」的东西时才报错。
      handler.next(response);
      return;
    }

    if (envelope.isOk) {
      // 用 data 覆盖 body，调用方拿到的是拆开后的 payload。
      handler.next(
        response..data = envelope.data,
      );
      return;
    }

    if (envelope.code == ApiEnvelope.codeUnauthorized) {
      onUnauthorized(envelope.message);
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
          error: AuthExpiredException(envelope.message),
          message: envelope.message,
        ),
      );
      return;
    }

    handler.reject(
      DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: ApiException(
          code: envelope.code,
          message: stripHtml(envelope.message),
          data: envelope.data,
        ),
        message: envelope.message,
      ),
    );
  }

  /// 502 的文案里带 `<br/>`（例如「KV数据库未绑定<br/>KV database not bound」），
  /// SnackBar 里要剥掉标签；诊断页保留原始 message。
  static String stripHtml(String input) =>
      input.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .trim();
}

/// 把 dio 的原始异常翻译成应用层异常。
AppException mapDioException(DioException e, {String? fallbackMessage}) {
  final inner = e.error;
  if (inner is AppException) return inner;

  switch (e.type) {
    case DioExceptionType.cancel:
      return const RequestCancelledException();
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return TimeoutException(detail: e.message);
    case DioExceptionType.connectionError:
      return NetworkException(detail: e.message);
    case DioExceptionType.badCertificate:
      return ServerException(
        message: '证书校验失败',
        statusCode: e.response?.statusCode,
      );
    case DioExceptionType.badResponse:
      final envelope = ApiEnvelope.tryParse(e.response?.data);
      if (envelope != null) {
        return ApiException(
          code: envelope.code,
          message: EnvelopeInterceptor.stripHtml(envelope.message),
          data: envelope.data,
        );
      }
      return ServerException(
        message: fallbackMessage ?? '服务端返回异常（${e.response?.statusCode}）',
        statusCode: e.response?.statusCode,
        body: _bodyPreview(e.response?.data),
      );
    // unknown 以及 dio 后续新增的类型（如 transformTimeout）。
    default:
      // 响应体不是 JSON —— 常见于地址填错、被反代接管。
      final body = _bodyPreview(e.response?.data);
      if (body != null) {
        return ServerException(
          message: fallbackMessage ?? '返回内容不是 cloud-mail 接口（检查服务器地址）',
          statusCode: e.response?.statusCode,
          body: body,
        );
      }
      return NetworkException(detail: e.message);
  }
}

String? _bodyPreview(Object? data) {
  if (data == null) return null;
  if (data is String) {
    return data.length > 500 ? '${data.substring(0, 500)}…' : data;
  }
  try {
    final encoded = jsonEncode(data);
    return encoded.length > 500 ? '${encoded.substring(0, 500)}…' : encoded;
  } catch (_) {
    return data.toString();
  }
}
