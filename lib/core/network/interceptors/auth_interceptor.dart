import 'package:dio/dio.dart';

/// `Authorization: <原始 JWT>` —— **不带 `Bearer ` 前缀**。
///
/// worker 的 `security/security.js` 直接把整个 header 丢给
/// `jwtUtils.verifyToken` 做 HMAC 校验，多一个前缀签名就过不了。
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required this.readToken});

  /// 返回 null / 空串时不加 header（未登录、或免鉴权端点）。
  final String? Function() readToken;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.extra[skipAuthKey] != true) {
      final token = readToken();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = token;
      }
    }
    handler.next(options);
  }

  static const String skipAuthKey = 'skipAuth';
}
