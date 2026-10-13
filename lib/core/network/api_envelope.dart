/// cloud-mail 的响应信封。**HTTP 状态码恒为 200**，真正的状态在 `code` 里
/// （Hono 的 onError 直接用 c.json 返回，不设置 HTTP status）。
///
/// 线上实测：不带 token 请求 /api/my/loginUserInfo →
///   HTTP/1.1 200 OK
///   {"code":401,"message":"登录已过期","data":null}
class ApiEnvelope {
  const ApiEnvelope({required this.code, required this.message, this.data});

  final int code;
  final String message;
  final Object? data;

  static const int codeOk = 200;

  /// 登录失效 / token 不在 KV 的 tokens 列表里。
  static const int codeUnauthorized = 401;

  /// 无权限（缺 perm、发信配额、域名限制等），message 可直接展示。
  static const int codeForbidden = 403;

  /// BizError 的默认码，绝大多数业务错误都是它（i18n 后的中/英文案）。
  static const int codeBizError = 501;

  /// 基础设施未配置（KV/D1 未绑定、数据库未升级），message 可能含 `<br/>`。
  static const int codeInfra = 502;

  /// 只有真的「长得像信封」才认：必须同时有数字 `code`，且带 `message` 或 `data`。
  ///
  /// 不能只看 `code` —— 邮件行里有个同名 `code` 字段（Workers AI 抽出来的验证码，
  /// 是字符串），单独一个 `code` 不足以判定这是信封。
  static ApiEnvelope? tryParse(Object? body) {
    if (body is Map) {
      if (!body.containsKey('message') && !body.containsKey('data')) return null;
      final rawCode = body['code'];
      final code = rawCode is int ? rawCode : int.tryParse('$rawCode');
      if (code == null) return null;
      return ApiEnvelope(
        code: code,
        message: body['message']?.toString() ?? '',
        data: body['data'],
      );
    }
    return null;
  }

  bool get isOk => code == codeOk;

  @override
  String toString() => 'ApiEnvelope($code, $message)';
}
