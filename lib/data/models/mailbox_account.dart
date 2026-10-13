import '../../core/util/json_utils.dart';
import 'recipient.dart';

/// 邮箱的最小公共形状。
///
/// 两个来源：`GET /account/list` 的行，和 `loginUserInfo.account`（一个裸 Map）。
/// 缺 `account:query` 权限的账号只能拿到后者，所以两者都要能落进本地库。
abstract interface class MailboxAccountLike {
  int get accountId;
  String get email;
  String get name;
  int get status;
  int get allReceive;
  int get sort;
  String? get latestEmailTime;
}

/// 邮箱（worker 里的 `account` 表，UI 上叫「邮箱」/「账号」）。
class MailboxAccount implements MailboxAccountLike {
  const MailboxAccount({
    this.accountId = 0,
    this.email = '',
    this.name = '',
    this.status = 0,
    this.userId = 0,
    this.allReceive = 0,
    this.sort = 0,
    this.latestEmailTime,
    this.createTime,
  });

  @override
  final int accountId;
  @override
  final String email;

  @override
  final String name;

  @override
  final int status;

  final int userId;

  /// 1 = 接收该用户所有邮箱的邮件。
  /// 注意服务端 `PUT /account/setAllReceive` 是**切换语义**：
  /// 开启某个邮箱会把这个用户其他邮箱的该标记清 0。
  @override
  final int allReceive;

  @override
  final int sort;

  @override
  final String? latestEmailTime;

  final String? createTime;

  bool get isAllReceive => allReceive == 1;

  String get displayName => name.isNotEmpty ? name : email;

  factory MailboxAccount.fromJson(Map<String, dynamic> json) {
    return MailboxAccount(
      accountId: JsonUtils.intValue(json, 'accountId'),
      email: JsonUtils.string(json, 'email'),
      name: JsonUtils.string(json, 'name'),
      status: JsonUtils.intValue(json, 'status'),
      userId: JsonUtils.intValue(json, 'userId'),
      allReceive: JsonUtils.intValue(json, 'allReceive'),
      sort: JsonUtils.intValue(json, 'sort'),
      latestEmailTime: JsonUtils.stringOrNull(json, 'latestEmailTime'),
      createTime: JsonUtils.stringOrNull(json, 'createTime'),
    );
  }

  /// `/account/list` 的裸数组 → 列表。
  static List<MailboxAccount> listFromJson(Object? json) {
    if (json is! List) return const <MailboxAccount>[];
    return json
        .whereType<Map>()
        .map((e) => MailboxAccount.fromJson(e.cast<String, dynamic>()))
        .where((a) => a.accountId > 0)
        .toList(growable: false);
  }

  /// `loginUserInfo.account`（裸 Map，可能为 null 或已删行）。
  static MailboxAccount? fromLoginUserInfo(Object? account) {
    if (account is! Map) return null;
    final parsed = MailboxAccount.fromJson(account.cast<String, dynamic>());
    return parsed.accountId > 0 ? parsed : null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'accountId': accountId,
        'email': email,
        'name': name,
        'status': status,
        'userId': userId,
        'allReceive': allReceive,
        'sort': sort,
        'latestEmailTime': latestEmailTime,
        'createTime': createTime,
      };

  @override
  String toString() => 'MailboxAccount($accountId, $email)';
}

/// 邮箱列表上的常用派生值。
///
/// 放在**模型文件**里而不是 dao 里：写邮件页、侧栏、设置页都要用它，
/// 而它们不该 import 任何一个 dao。
extension MailboxListX on List<MailboxAccount> {
  /// 「合并视图」用的收件邮箱：开了 allReceive 的那个就代表全部，
  /// 否则第一个（服务端按 `sort` 排过序）。
  MailboxAccount? get primaryOrNull {
    if (isEmpty) return null;
    for (final a in this) {
      if (a.isAllReceive) return a;
    }
    return first;
  }

  /// 收件人自动补全的候选（「发给自己的另一个邮箱」是常见操作）。
  List<Recipient> toRecipients() =>
      map((a) => Recipient(address: a.email, name: a.name))
          .where((r) => r.address.isNotEmpty)
          .toList(growable: false);

  /// 按 `accountId` 找；找不到返回 null（调用方再退到 [primaryOrNull]）。
  MailboxAccount? byId(int? accountId) {
    if (accountId == null || accountId <= 0) return null;
    for (final a in this) {
      if (a.accountId == accountId) return a;
    }
    return null;
  }
}
