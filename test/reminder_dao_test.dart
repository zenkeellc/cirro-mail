import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/profile.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final now = DateTime.utc(2026, 10, 11, 10, 0);

  test('insert 之后 due 能挑出来（按时间升序）', () async {
    await db.reminderDao.insert(
      profileId: 'p1',
      emailId: 7,
      subject: '主题 A',
      sender: 'alice@example.com',
      remindAt: now.subtract(const Duration(minutes: 5)),
      createdAt: now,
    );
    await db.reminderDao.insert(
      profileId: 'p1',
      emailId: 8,
      subject: '主题 B',
      sender: 'bob@example.com',
      remindAt: now.subtract(const Duration(minutes: 30)),
      createdAt: now,
    );

    final due = await db.reminderDao.due(now);
    expect(due.map((r) => r.emailId), <int>[8, 7], reason: '早的先弹');
  });

  test('还没到点的挑不出来；正好等于 now 的算到点', () async {
    await db.reminderDao.insert(
      profileId: 'p1', emailId: 1, subject: 's', sender: 'a@b.c',
      remindAt: now.add(const Duration(minutes: 1)), createdAt: now,
    );
    await db.reminderDao.insert(
      profileId: 'p1', emailId: 2, subject: 's', sender: 'a@b.c',
      remindAt: now, createdAt: now,
    );

    final due = await db.reminderDao.due(now);
    expect(due.map((r) => r.emailId), <int>[2]);
  });

  test('markFired 之后不再出现在 due 里（不重复弹）', () async {
    final id = await db.reminderDao.insert(
      profileId: 'p1', emailId: 1, subject: 's', sender: 'a@b.c',
      remindAt: now.subtract(const Duration(minutes: 1)), createdAt: now,
    );
    await db.reminderDao.markFired(id, now);

    expect(await db.reminderDao.due(now), isEmpty);
    // 行**还在**（不删）—— 「这封信我提醒过一次」这个事实留着
    final all = await db.reminderDao.all();
    expect(all.single.firedAt, isNotNull);
  });

  test('markFired 是幂等的（第二次调用不覆盖第一次的时间）', () async {
    final id = await db.reminderDao.insert(
      profileId: 'p1', emailId: 1, subject: 's', sender: 'a@b.c',
      remindAt: now.subtract(const Duration(minutes: 1)), createdAt: now,
    );
    final first = now.subtract(const Duration(seconds: 1));
    await db.reminderDao.markFired(id, first);
    await db.reminderDao.markFired(id, now);
    // drift 按 Unix 秒落库、读回来是**本机墙上时间**（`isUtc == false`），
    // 而 `DateTime` 的 `==` 同时要求「同一瞬间」与「isUtc 相同」——
    // 直接比 `first` 会假红。比同一瞬间的本地时间。
    expect((await db.reminderDao.all()).single.firedAt, first.toLocal());
  });

  test('deleteByMail 按 (profileId, emailId) 删，别的行不动', () async {
    await db.reminderDao.insert(
      profileId: 'p1', emailId: 7, subject: 's', sender: 'a@b.c',
      remindAt: now, createdAt: now,
    );
    await db.reminderDao.insert(
      profileId: 'p1', emailId: 8, subject: 's', sender: 'a@b.c',
      remindAt: now, createdAt: now,
    );
    await db.reminderDao.insert(
      profileId: 'p2', emailId: 7, subject: 's', sender: 'a@b.c',
      remindAt: now, createdAt: now,
    );

    await db.reminderDao.deleteByMail('p1', 7);
    final left = await db.reminderDao.all();
    expect(left.map((r) => '${r.profileId}#${r.emailId}').toSet(),
        <String>{'p1#8', 'p2#7'});
  });

  test('同一封邮件重复排期：第二次是插一行新的（这一版不做「覆盖」）', () async {
    await db.reminderDao.insert(
      profileId: 'p1', emailId: 7, subject: 's', sender: 'a@b.c',
      remindAt: now.add(const Duration(hours: 1)), createdAt: now,
    );
    await db.reminderDao.insert(
      profileId: 'p1', emailId: 7, subject: 's', sender: 'a@b.c',
      remindAt: now.add(const Duration(hours: 2)), createdAt: now,
    );
    expect(await db.reminderDao.all(), hasLength(2));
  });

  test('forMail 能查到某封信的提醒（执行 delete 前要拿它去撤销排期）', () async {
    await db.reminderDao.insert(
      profileId: 'p1', emailId: 7, subject: 's', sender: 'a@b.c',
      remindAt: now, createdAt: now, );
    final found = await db.reminderDao.forMail('p1', 7);
    expect(found, hasLength(1));
    expect(found.single.subject, 's');
    expect(await db.reminderDao.forMail('p1', 99), isEmpty);
  });

  test('新库（createAll）里 reminders 表就绪、可写可读', () async {
    final fresh = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);
    await fresh.reminderDao.insert(
      profileId: 'p1', emailId: 1, subject: 's', sender: 'a@b.c',
      remindAt: now, createdAt: now,
    );
    expect(await fresh.reminderDao.all(), hasLength(1));
  });

  test('schemaVersion 是 4（remote_total_at 是第 4 版加的）', () {
    // **这条只钉住版本号本身**，不证明 `onUpgrade` 的各条分支能跑通 ——
    // 见下面那段说明：本仓库没有 schema dump 基建，2 → 3 与 3 → 4 这两条
    // 迁移路径目前**没有自动化覆盖**。别把这条读成「迁移测过了」。
    final fresh = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);
    expect(fresh.schemaVersion, 4);
  });

  group('级联清理（spec §7.1：不声明外键，改走既有的删除漏斗）', () {
    test('deleteRefs 删邮件时把它的提醒一起删掉', () async {
      await db.mailDao.upsertPage(<MailRow>[
        MailRow(emailId: 7, profileId: 'p1', subject: '主题'),
      ]);
      await db.reminderDao.insert(
        profileId: 'p1', emailId: 7, subject: '主题', sender: 'a@b.c',
        remindAt: now, createdAt: now,
      );

      await db.mailDao.deleteRefs(<MailRef>[
        const MailRef(profileId: 'p1', emailId: 7),
      ]);

      expect(await db.reminderDao.all(), isEmpty);
    });

    test('清空实例数据时提醒也清掉', () async {
      await db.profileDao.upsertProfile(const Profile(
        id: 'p1', baseUrl: 'https://x/api', email: 'a@x.com', userId: 7,
      ));
      await db.reminderDao.insert(
        profileId: 'p1', emailId: 7, subject: '主题', sender: 'a@b.c',
        remindAt: now, createdAt: now,
      );

      await db.profileDao.clearProfileData('p1');

      expect(await db.reminderDao.all(), isEmpty);
    });
  });
}
