import '../../core/network/api_client.dart';
import '../../core/network/endpoints.dart';
import '../models/mailbox_account.dart';

/// 邮箱（服务端的 `account` 表，UI 上叫「邮箱」）。
///
/// 两个退化点：
/// - 需要 `account:query` 权限（`requirePerms` 里有 `/account/list`），
///   多数自建实例的普通用户没有 → 403，客户端要退到 `loginUserInfo.account`；
/// - 分页游标是 `(sort, accountId)` 的**组合**（服务端
///   `or(lt(sort,lastSort), and(eq(sort,lastSort), gt(accountId,accountId)))`），
///   不是下标，所以必须取上一页末行的两个值一起传。
class AccountApi {
  const AccountApi(this._client);

  final ApiClient _client;

  /// [lastSort] / [lastAccountId] 传上一页末行的值；首屏不传。
  Future<List<MailboxAccount>> list({
    int size = 30,
    int? lastSort,
    int? lastAccountId,
  }) async {
    final data = await _client.request<Object?>(
      Endpoints.accountList,
      query: <String, dynamic>{
        'size': size,
        // 游标是 (sort, accountId) 组合，两个要么都传要么都不传。
        'lastSort': ?lastSort,
        'accountId': ?lastAccountId,
      },
    );
    return MailboxAccount.listFromJson(data);
  }

  /// 加邮箱。`token` 是 Turnstile token（站点开了 `addEmailVerify` 才需要）。
  Future<MailboxAccount?> add(String email, {String? turnstileToken}) async {
    final data = await _client.request<Object?>(
      Endpoints.accountAdd,
      method: 'POST',
      data: <String, dynamic>{
        'email': email,
        'token': ?turnstileToken,
      },
    );
    if (data is Map) {
      return MailboxAccount.fromJson(data.cast<String, dynamic>());
    }
    return null;
  }

  Future<void> delete(int accountId) => _client.request<Object?>(
        Endpoints.accountDelete,
        method: 'DELETE',
        query: <String, dynamic>{'accountId': accountId},
      );

  Future<void> setName(int accountId, String name) => _client.request<Object?>(
        Endpoints.accountSetName,
        method: 'PUT',
        data: <String, dynamic>{'accountId': accountId, 'name': name},
      );

  /// **切换语义**：开启某个邮箱会把这个用户其他所有邮箱的该标记清 0。
  ///
  /// 想「收所有邮箱的信」不要靠它 —— 用 `/email/list?allReceive=1` 的
  /// 合并查询（`EmailApi.list` 的 `allReceive` 参数），那才是无副作用的。
  Future<void> setAllReceive(int accountId, bool on) => _client.request<Object?>(
        Endpoints.accountSetAllReceive,
        method: 'PUT',
        data: <String, dynamic>{'accountId': accountId, 'allReceive': on ? 1 : 0},
      );

  Future<void> setAsTop(int accountId) => _client.request<Object?>(
        Endpoints.accountSetAsTop,
        method: 'PUT',
        data: <String, dynamic>{'accountId': accountId},
      );
}
