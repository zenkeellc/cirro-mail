import 'app_defaults.dart';

/// 一次「服务端会话还能撑多久」的估算。
///
/// 为什么只能估算：服务端签的 JWT **没有 `exp`**，有效性全靠 KV 里那份
/// token 列表，而那份记录的 TTL 是**滑动**的 30 天 —— 每来一次通过鉴权的
/// 请求就续一次。客户端拿不到到期时刻，只能拿「本地记得的最后一次成功
/// 触达服务端」往后推。所以 [expiresAt] 是**下限**：真实到期只会更晚。
/// 宁可提醒早一点，不要用户被突然踢回登录页。
class SessionExpiry {
  const SessionExpiry({required this.expiresAt, required this.shouldWarn});

  /// 估算的到期时刻（UTC）；拿不到时间戳时为 null（不知道，别吓人）。
  final DateTime? expiresAt;

  /// 是否到了该提示「再不来就要重登了」的程度。
  final bool shouldWarn;

  /// 按最近一次触达服务端的时刻估算。
  ///
  /// [lastSyncAt] 每轮成功同步都会写、[lastActiveAt] 在登录 / 切换实例时写，
  /// 两者取**较晚**的那个：任意一次鉴权请求都会续期，同步成功本身就是一次。
  /// 手动传 [now] 是为了让测试不受墙上时钟影响。
  factory SessionExpiry.estimate({
    required bool isLoggedIn,
    DateTime? lastActiveAt,
    DateTime? lastSyncAt,
    DateTime? now,
  }) {
    // 已经掉了（等待重登）的实例没有「到期」可言。
    if (!isLoggedIn) {
      return const SessionExpiry(expiresAt: null, shouldWarn: false);
    }
    final lastTouch = _later(lastActiveAt, lastSyncAt);
    if (lastTouch == null) {
      return const SessionExpiry(expiresAt: null, shouldWarn: false);
    }

    final expiresAt = lastTouch.toUtc().add(AppDefaults.sessionTtl);
    final clock = (now ?? DateTime.now()).toUtc();
    return SessionExpiry(
      expiresAt: expiresAt,
      shouldWarn:
          clock.isAfter(expiresAt.subtract(AppDefaults.sessionWarnBefore)),
    );
  }

  /// 两个时间戳里较晚的那个；都为 null 时返回 null。
  static DateTime? _later(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }
}
