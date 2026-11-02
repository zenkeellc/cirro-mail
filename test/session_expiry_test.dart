import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/config/app_defaults.dart';
import 'package:mail_app/core/config/session_expiry.dart';

/// # 会话到期的估算
///
/// 服务端那份 token 记录是**滑动**的 30 天：只要有一次通过鉴权的请求就续满，
/// 所以「到期」不是日历上某个固定日期。客户端没有 `exp` 可读，只能拿本地
/// 最后一次成功请求往后推 —— 这一组把那个推算（尤其是「取较晚者」和
/// 提前多少天开始提示）钉住，免得哪天改成「取 lastActiveAt 就完事」，
/// 结果一个天天同步的实例被提示「再不动就要重登了」。
void main() {
  final now = DateTime.utc(2026, 11, 2, 10);
  final ttl = AppDefaults.sessionTtl;
  final warnBefore = AppDefaults.sessionWarnBefore;

  DateTime ago(Duration d) => now.subtract(d);

  test('还没登录的实例不参与估算 —— 没有「到期」可言', () {
    final expiry = SessionExpiry.estimate(
      isLoggedIn: false,
      lastActiveAt: ago(const Duration(days: 1)),
      lastSyncAt: ago(const Duration(days: 1)),
      now: now,
    );
    expect(expiry.expiresAt, isNull);
    expect(expiry.shouldWarn, isFalse);
  });

  test('连时间戳都没有时也不猜 —— 显示为空，不报假警报', () {
    final expiry = SessionExpiry.estimate(isLoggedIn: true, now: now);
    expect(expiry.expiresAt, isNull);
    expect(expiry.shouldWarn, isFalse);
  });

  test('到期 = 最近一次触达 + 30 天', () {
    final lastTouch = ago(const Duration(hours: 3));
    final expiry = SessionExpiry.estimate(
      isLoggedIn: true,
      lastSyncAt: lastTouch,
      now: now,
    );
    expect(expiry.expiresAt, lastTouch.add(ttl));
    expect(expiry.shouldWarn, isFalse);
  });

  test('刚同步过的实例不该被提示', () {
    final expiry = SessionExpiry.estimate(
      isLoggedIn: true,
      lastSyncAt: ago(const Duration(days: 1)),
      now: now,
    );
    expect(expiry.shouldWarn, isFalse);
  });

  test('剩不到一周时开始提示（30 天 - 7 天 = 23 天没动）', () {
    final warn = SessionExpiry.estimate(
      isLoggedIn: true,
      lastSyncAt: ago(ttl - warnBefore + const Duration(hours: 1)),
      now: now,
    );
    expect(
      warn.shouldWarn,
      isTrue,
      reason: '还剩不到 ${warnBefore.inDays} 天就该说了 —— 打开收一次信就续上',
    );

    final quiet = SessionExpiry.estimate(
      isLoggedIn: true,
      lastSyncAt: ago(ttl - warnBefore - const Duration(hours: 1)),
      now: now,
    );
    expect(quiet.shouldWarn, isFalse);
  });

  test('取两个时间戳里较晚的那个：同步记录很旧但实例刚活跃过，不算过期', () {
    final expiry = SessionExpiry.estimate(
      isLoggedIn: true,
      // 40 天没同步（例如实例被停用了很久）……
      lastSyncAt: ago(const Duration(days: 40)),
      // ……但昨天切到过这个实例 / 刚重登过，那也会续期。
      lastActiveAt: ago(const Duration(days: 1)),
      now: now,
    );
    expect(expiry.shouldWarn, isFalse);
    expect(expiry.expiresAt, ago(const Duration(days: 1)).add(ttl));
  });

  test('反过来也一样：很久没活跃但刚刚同步成功过', () {
    final expiry = SessionExpiry.estimate(
      isLoggedIn: true,
      lastActiveAt: ago(const Duration(days: 60)),
      lastSyncAt: ago(const Duration(minutes: 10)),
      now: now,
    );
    expect(expiry.shouldWarn, isFalse);
    expect(expiry.expiresAt!.isAfter(now), isTrue);
  });

  test('真的放满 30 天没动：估算到期已过，提示照旧给（用户还能重登）', () {
    final expiry = SessionExpiry.estimate(
      isLoggedIn: true,
      lastSyncAt: ago(const Duration(days: 31)),
      now: now,
    );
    expect(expiry.shouldWarn, isTrue);
    expect(expiry.expiresAt!.isBefore(now), isTrue);
  });
}
