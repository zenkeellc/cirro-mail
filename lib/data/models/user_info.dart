import '../../core/util/json_utils.dart';

/// `GET /my/loginUserInfo` 的响应。
///
/// 形状（worker `service/user-service.js::loginUserInfo`）：
/// ```
/// { userId, sendCount, email, account, name, permKeys, role, type }
/// ```
/// - `name` 直接取自 `account.name`（默认邮箱的显示名），不是用户表的字段；
/// - `account` 是该用户**主邮箱**的 account 行（`selectByEmailIncludeDel`），
///   `my:delete` 之类的路径下可能是已删行；
/// - `role` 是 role 表整行（`permKeys` 与它并存 —— `permKeys` 是实际判定依据）；
/// - `c.env.admin` 命中时 `permKeys = ['*']` 且 `role` 被替换成
///   `constant.ADMIN_ROLE`（只有四个字段的裸对象），所以 `role.roleId` 可能是 null。
class UserInfo {
  const UserInfo({
    this.userId = 0,
    this.email = '',
    this.name = '',
    this.sendCount = 0,
    this.type = 1,
    this.permKeys = const <String>[],
    this.account,
    this.role,
    this.raw = const <String, dynamic>{},
  });

  final int userId;
  final String email;

  /// 主邮箱的显示名。
  final String name;

  /// 已发件数（配额用），服务端是 TEXT 列。
  final int sendCount;

  /// 用户类型 = roleId（`role.roleId`）。
  final int type;

  /// `'*'` 表示超管。
  final List<String> permKeys;

  /// 主邮箱行（原样保留，登录后不再请求 `/account/list` 也能拿到它）。
  final Map<String, dynamic>? account;

  /// role 表整行；超管走 `constant.ADMIN_ROLE`，只有四个字段。
  final Map<String, dynamic>? role;

  final Map<String, dynamic> raw;

  bool get isSuperAdmin => permKeys.contains('*');

  bool hasPerm(String key) => isSuperAdmin || permKeys.contains(key);

  /// 主邮箱地址（登录用户的收件地址）。
  String get primaryEmail =>
      (account?['email']?.toString().isNotEmpty ?? false)
          ? account!['email'].toString()
          : email;

  int get primaryAccountId =>
      account == null ? 0 : JsonUtils.intValue(account!, 'accountId');

  String get primaryAccountName =>
      account == null ? name : JsonUtils.string(account!, 'name', name);

  factory UserInfo.fromJson(Object? json) {
    if (json is! Map) return const UserInfo();
    final map = json.cast<String, dynamic>();
    return UserInfo(
      userId: JsonUtils.intValue(map, 'userId'),
      email: JsonUtils.string(map, 'email'),
      name: JsonUtils.string(map, 'name'),
      sendCount: JsonUtils.intValue(map, 'sendCount'),
      type: JsonUtils.intValue(map, 'type', 1),
      permKeys: JsonUtils.stringList(map, 'permKeys'),
      account: map['account'] is Map
          ? (map['account'] as Map).cast<String, dynamic>()
          : null,
      role: map['role'] is Map
          ? (map['role'] as Map).cast<String, dynamic>()
          : null,
      raw: map,
    );
  }

  @override
  String toString() => 'UserInfo($userId, $email, perms=${permKeys.length})';
}
