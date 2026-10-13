import '../network/api_envelope.dart';

/// 应用层异常。`userMessage` 是给用户看的（已去掉 HTML 标签、已按 accept-language 本地化）。
sealed class AppException implements Exception {
  const AppException(this.userMessage, {this.code, this.rawMessage});

  final String userMessage;
  final int? code;
  final String? rawMessage;

  @override
  String toString() => '$runtimeType(code: $code, message: $userMessage)';
}

/// 服务端返回了一个非 200 的 `code`（401/403/501/502 等）。
final class ApiException extends AppException {
  const ApiException({
    required int code,
    required String message,
    this.data,
  }) : super(message, code: code, rawMessage: message);

  /// 信封里的 data，出错时通常为 null，但保留以便诊断页展示原始内容。
  final Object? data;
}

/// 401：会话失效。拦截器负责清 token 并广播，UI 负责跳登录。
///
/// 不再单独存 `rawMessage` —— 服务端给的文案本身就是要展示的那句。
final class AuthExpiredException extends AppException {
  const AuthExpiredException(super.message)
      : super(code: ApiEnvelope.codeUnauthorized);
}

/// 网络层失败：DNS、TLS、不可达。
final class NetworkException extends AppException {
  const NetworkException({String? detail})
      : super('网络不可用', rawMessage: detail);
}

final class TimeoutException extends AppException {
  const TimeoutException({String? detail})
      : super('请求超时', rawMessage: detail);
}

/// 返回的不是 JSON 信封（被代理改写了，或根本不是 cloud-mail 实例）。
final class ServerException extends AppException {
  const ServerException({required String message, this.statusCode, String? body})
      : super(message, rawMessage: body);

  final int? statusCode;
}

/// 附件下载时服务端返回了 JSON 而不是字节流。
///
/// `/api/oss/*` 找不到对象时是 **HTTP 200 + `{"code":500,...}`**，
/// 必须识别出来，否则会把几十字节的 JSON 当文件写盘。
final class AttachmentNotAvailableException extends AppException {
  const AttachmentNotAvailableException({String? detail})
      : super('附件不可用', rawMessage: detail);
}

/// 请求被 CancelToken 主动取消（切换邮箱/实例时）。UI 不应弹错。
final class RequestCancelledException extends AppException {
  const RequestCancelledException() : super('已取消');
}

/// 发信前的本地校验没过。
///
/// **必须在本地拦**：服务端的「≤10 附件 / ≤10 内嵌图 / 收件人非空」检查
/// 发生在**插库之后**（见计划约束 13），不先拦就会在那个用户的发件箱里
/// 留下一条永远发不出去的 `SAVING` 脏行 —— 用户看得见、删得掉、
/// 但每次都以为是 App 出了错。
final class SendValidationException extends AppException {
  /// [reasons] 是一次性给全的所有问题，UI 一次列完，
  /// 而不是让用户改一条试一次。
  const SendValidationException(this.reasons)
      : super('邮件还没准备好发送');

  final List<String> reasons;

  /// 拼成一句话，给 SnackBar / outbox 的 `lastError` 用。
  String get describe => reasons.join('；');
}
