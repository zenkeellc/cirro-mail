import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'reminder_dao.g.dart';

/// 「稍后提醒」那张表的读写（spec §7.1）。
///
/// 四个方法就是这一版需要的全部：落一条、挑到点的、标记弹过、按邮件删。
/// **刻意没有 `update`** —— 改时间这一版不支持（用户要改就删了重排），
/// 而一个 `update` 方法会立刻引诱出「那要不要给它一个界面」这个问题。
@DriftAccessor(tables: [Reminders])
class ReminderDao extends DatabaseAccessor<AppDatabase> with _$ReminderDaoMixin {
  ReminderDao(super.db);

  Future<int> insert({
    required String profileId,
    required int emailId,
    required String subject,
    required String sender,
    required DateTime remindAt,
    required DateTime createdAt,
  }) =>
      into(reminders).insert(RemindersCompanion.insert(
        profileId: profileId,
        emailId: emailId,
        subject: Value(subject),
        sender: Value(sender),
        remindAt: remindAt,
        createdAt: createdAt,
      ));

  /// 到点的（`remindAt <= now` 且还没弹过），早的排前面。
  ///
  /// 比较用 `isSmallerOrEqualValue` 而不是手写 SQL：drift 会按列的时间存储
  /// 格式（本仓库是 Unix 秒）拼出正确的比较。
  Future<List<DbReminder>> due(DateTime now) => (select(reminders)
        ..where((t) => t.remindAt.isSmallerOrEqualValue(now) & t.firedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.remindAt)]))
      .get();

  /// 标记「弹过了」。**幂等**：只在 `firedAt` 还是 null 时写，
  /// 这样两路（系统排期 + ticker）同时到点时不会互相覆盖时间戳。
  Future<void> markFired(int id, DateTime at) => (update(reminders)
        ..where((t) => t.id.equals(id) & t.firedAt.isNull()))
      .write(RemindersCompanion(firedAt: Value(at)));

  /// 某封信的所有提醒。执行 `delete` 之前要拿它去撤销系统排期（§6.3）。
  Future<List<DbReminder>> forMail(String profileId, int emailId) =>
      (select(reminders)
            ..where((t) => t.profileId.equals(profileId) & t.emailId.equals(emailId)))
          .get();

  /// 按邮件删。由 `MailDao.deleteRefs` 的事务调用（cascade 的一半）。
  Future<void> deleteByMail(String profileId, int emailId) => (delete(reminders)
        ..where((t) => t.profileId.equals(profileId) & t.emailId.equals(emailId)))
      .go();

  /// 全部（测试与将来的提醒列表页用）。
  Future<List<DbReminder>> all() => select(reminders).get();
}
