import 'user_info.dart';
import 'user_role.dart';

/// 服务端的发信配额，**从 `loginUserInfo` 推出来**，不需要新端点。
///
/// 判定逻辑逐条对齐 `mail-worker/src/service/email-service.js::send`
/// 与 Web 端 `mail-vue/src/layout/header/index.vue` 的配额文案：
///
/// | 条件 | 结论 |
/// |---|---|
/// | `setting.send === 1` | 整个站点关掉了发信（由 `InstanceCapabilities` 判，不在这里） |
/// | `role.sendType === 'ban'` | 角色被禁发 |
/// | `role.sendType === 'internal'` | 只能发站内邮箱 |
/// | `!role.sendCount` | 不限量 |
/// | `sendType === 'day'` | 每日 `role.sendCount` 封 |
/// | 其余（`'count'`） | 累计 `role.sendCount` 封 |
///
/// 服务端还额外比了一次 `userRow.sendCount + receiveEmail.length > roleRow.sendCount`
/// （一次性群发会整体超限）—— 本条在客户端**不预判**：收件人数是用户边写边变的，
/// 提示一个会随时翻脸的「还差几封」比不提示更烦人，真正的拒绝交给服务端。
///
/// 「已发数」`user.sendCount` 是服务端 `email` 表的计数，App 无法自己维护
/// （其他设备/Web 端发的信也算在内），所以这个数字只有每次重开写邮件页时是新的。
class SendQuota {
  const SendQuota({
    this.allowed = true,
    this.internalOnly = false,
    this.used = 0,
    this.limit = 0,
    this.isDay = false,
    this.known = false,
  });

  /// 角色是否允许发信（`sendType !== 'ban'`）。
  final bool allowed;

  /// 是否只能给站内邮箱发信（`sendType === 'internal'`）。
  final bool internalOnly;

  /// 已发件数。
  final int used;

  /// 上限；`0` 表示不限量（服务端 `if (roleRow.sendCount)` 的短路）。
  final int limit;

  /// `true` = 每日配额，`false` = 累计配额。
  final bool isDay;

  /// 是否真的拿到了 `loginUserInfo`。为 false 时 UI 不该显示任何配额文案 ——
  /// 显示一个猜测出来的「不限量」比什么都不显示更糟。
  final bool known;

  /// 还没探测到（离线、或请求失败）。
  static const SendQuota unknown = SendQuota();

  bool get unlimited => limit <= 0;

  /// 还能发几封；不限量时返回 -1。
  int get remaining => unlimited ? -1 : (limit - used).clamp(0, limit);

  /// 配额已经用完。服务端会因为 `userRow.sendCount >= roleRow.sendCount` 而 403。
  bool get exhausted => !unlimited && used >= limit;

  /// 从 `loginUserInfo` 推导。
  static SendQuota fromUserInfo(UserInfo? user) {
    if (user == null || user.userId <= 0) return unknown;
    // `role` 是 role 表整行；超管走 `constant.ADMIN_ROLE`（只有四个字段），
    // `UserRole.fromJson` 对缺失字段都有默认值，所以 null 也能解。
    final UserRole role = UserRole.fromJson(user.role);
    return SendQuota(
      allowed: role.sendType != 'ban',
      internalOnly: role.sendType == 'internal',
      used: user.sendCount,
      limit: role.sendCount,
      isDay: role.isDayQuota,
      known: true,
    );
  }

  @override
  String toString() => 'SendQuota(allowed=$allowed, internal=$internalOnly, '
      '$used/$limit, day=$isDay, known=$known)';
}
