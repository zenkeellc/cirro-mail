import '../../core/network/api_client.dart';
import '../../core/network/endpoints.dart';
import '../models/user_info.dart';
import '../models/user_role.dart';

/// 当前用户相关。
///
/// `loginUserInfo` 是登录后**第一个**该调的接口：它同时给出主邮箱
/// （`account`）、权限（`permKeys`）与角色配额（`role`）。
/// 普通用户没有 `account:query` 权限，拿不到 `/account/list`，
/// 此时 `account` 就是唯一的邮箱来源。
class MyApi {
  const MyApi(this._client);

  final ApiClient _client;

  Future<UserInfo> loginUserInfo() async {
    final data = await _client.request<Object?>(Endpoints.loginUserInfo);
    return UserInfo.fromJson(data);
  }

  /// 改密码。服务端会**清掉该用户的全部 token**（`security` 的 KV 记录），
  /// 即所有设备一起下线 —— 调用方要预期紧接着的 401。
  Future<void> resetPassword(String password) => _client.request<Object?>(
        Endpoints.resetPassword,
        method: 'PUT',
        data: <String, dynamic>{'password': password},
      );

  /// 注销账号（不可逆；服务端逻辑删除用户并清 token）。
  Future<void> deleteAccount() =>
      _client.request<Object?>(Endpoints.deleteMyAccount, method: 'DELETE');
}

extension UserInfoRoleX on UserInfo {
  UserRole get parsedRole => UserRole.fromJson(role);
}
