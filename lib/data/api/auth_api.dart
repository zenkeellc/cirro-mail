import '../../core/network/api_client.dart';
import '../../core/network/endpoints.dart';

/// 登录 / 退出。
///
/// 服务端行为（`service/login-service.js`）：
/// - `POST /login {email, password}` → `{token}`
/// - 密码校验用 `salt` + hash，失败返回 `501`（i18n 文案）
/// - 登录成功会往 KV `auth-uid:<uid>.tokens` 追加 token，**最多 11 个**
///   （服务端是 `if (tokens.length > 10) shift()` 再 push：第 12 次登录才把
///   最老的挤掉。注释与 UI 文案里说的「10 个 / 第 11 次」一直差一）——
///   同一账号在多设备登录会互相顶下来，401 的提示里要提到这一点，
///   而不是静默重登（重登会继续挤）。
/// - `DELETE /logout` 只移除**当前**这一个 token。
///
/// token 里**没有 `exp`**，有效性全靠 KV 那个列表，所以客户端无法预先判断
/// 过期，只能在下次请求拿到 401 时知道。401 本身也**未必**是真的过期（服务端
/// 换 `jwt_secret`、KV 抖动、被别的设备挤掉），所以 `RuntimeRegistry` 会拿
/// 钥匙串里那份 token 再问一次服务端，确认失效才删。
class AuthApi {
  const AuthApi(this._client);

  final ApiClient _client;

  Future<String> login({
    required String email,
    required String password,
    bool skipAuth = true,
  }) async {
    final data = await _client.request<Object?>(
      Endpoints.login,
      method: 'POST',
      data: <String, dynamic>{'email': email, 'password': password},
      skipAuth: skipAuth,
    );
    if (data is Map && data['token'] is String) {
      return data['token'] as String;
    }
    // 服务端契约变了（或反代吞了 body）—— 明确报错，别返回空 token。
    throw StateError('登录没有成功，请重试');
  }

  /// 退出登录。
  ///
  /// 拿到 401 时**也当作成功** —— token 已经无效了，本地清掉即可，
  /// 不该因为这个把用户卡在「退出失败」的循环里。
  Future<void> logout() async {
    await _client.request<Object?>(Endpoints.logout, method: 'DELETE');
  }
}
