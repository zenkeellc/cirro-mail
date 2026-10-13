import '../../core/util/json_utils.dart';

/// `role` 表的一行（`loginUserInfo.role`）。
///
/// 两个形态：
/// - 正常：role 表整行，`roleId` / `key` / `isDefault` 都在；
/// - 超管：`constant.ADMIN_ROLE`，只有 `{name:'admin', sendCount:0, sendType:'count', accountCount:0}`，
///   **没有 `roleId`、没有 `key`** —— 所以全部字段都要有默认值。
///
/// `sendType` 决定发信配额口径（见 `const/entity-const.js` 的 `roleConst.sendType`），
/// 但注意它**不包含**「禁止发信」这一态：那由 `sendCount` 与用户已发数比较得出，
/// 且 `websiteConfig.send === 1` 会直接关掉整个发信入口。
class UserRole {
  const UserRole({
    this.roleId,
    this.name = '',
    this.key = '',
    this.description,
    this.banEmail = const <String>[],
    this.banEmailType = 0,
    this.availDomain = const <String>[],
    this.isDefault = 0,
    this.sendCount = 0,
    this.sendType = 'count',
    this.accountCount = 0,
  });

  final int? roleId;
  final String name;
  final String key;
  final String? description;

  /// 封禁的邮箱/域名（服务端存的是逗号拼接的字符串，这里已拆开）。
  final List<String> banEmail;

  /// 0 = 全部拦截，1 = 只按内容拦截。
  final int banEmailType;

  /// 允许使用的域名（同样已从逗号拼接串拆开）。
  final List<String> availDomain;

  final int isDefault;

  /// 发信配额上限。
  final int sendCount;

  /// `count`（累计） / `day`（每日）。
  final String sendType;

  /// 可用邮箱数上限。
  final int accountCount;

  bool get isDayQuota => sendType == 'day';

  factory UserRole.fromJson(Object? json) {
    if (json is! Map) return const UserRole();
    final map = json.cast<String, dynamic>();
    return UserRole(
      roleId: JsonUtils.intOrNull(map, 'roleId'),
      name: JsonUtils.string(map, 'name'),
      key: JsonUtils.string(map, 'key'),
      description: JsonUtils.stringOrNull(map, 'description'),
      banEmail: _splitCsv(map['banEmail']),
      banEmailType: JsonUtils.intValue(map, 'banEmailType'),
      availDomain: _splitCsv(map['availDomain']),
      isDefault: JsonUtils.intValue(map, 'isDefault'),
      sendCount: JsonUtils.intValue(map, 'sendCount'),
      sendType: JsonUtils.string(map, 'sendType', 'count'),
      accountCount: JsonUtils.intValue(map, 'accountCount'),
    );
  }

  /// 服务端存的是 `a@b.com,c@d.com`，空串拆出来必须是空列表（不是 `['']`）。
  static List<String> _splitCsv(Object? raw) {
    if (raw == null) return const <String>[];
    if (raw is List) return raw.map((e) => e.toString()).toList(growable: false);
    return raw
        .toString()
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  @override
  String toString() => 'UserRole($roleId, $name, $sendType/$sendCount)';
}
