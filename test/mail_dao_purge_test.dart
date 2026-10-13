// 「删邮箱」是**服务端物理删除**（`physicsDelete` → 删附件记录 +
// `DELETE FROM email WHERE account_id = ?`），所以本地那批邮件也一样不存在了。
//
// 这个方法最容易错的地方是**它删了不该删的**：
//   - 按 `isDel` 过滤 → 软删的行留下来，永远查不出来（`_mailboxPredicate`
//     带 `isDel = 0`，谁也看不见它们）；
//   - 顺手清了 `all:type:*` 的聚合游标 → 下次同步从 0 开始，把整台实例
//     重拉一遍（用户以为卡住了）；
//   - 顺手清了草稿 → 用户自己写的东西没了。
// 三条都在下面各有一条用例钉着。
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_attachment.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/repositories/email_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  const profileId = 'p1';
  const target = 8; // 要删掉的邮箱
  const other = 12; // 别动它

  Future<void> seed() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.profileDao.upsertMailboxes(profileId, <MailboxAccount>[
      const MailboxAccount(accountId: target, email: 'kedong@example.com'),
      const MailboxAccount(accountId: other, email: 'hello@example.com'),
    ]);
    await db.mailDao.upsertPage(<MailRow>[
      MailRow(
        emailId: 101,
        profileId: profileId,
        accountId: target,
        mailboxEmail: 'kedong@example.com',
        subject: '目标邮箱的收件',
      ),
      MailRow(
        emailId: 102,
        profileId: profileId,
        accountId: target,
        mailboxEmail: 'kedong@example.com',
        subject: '目标邮箱的软删行',
        isDel: 1,
      ),
      MailRow(
        emailId: 103,
        profileId: profileId,
        accountId: target,
        mailboxEmail: 'kedong@example.com',
        subject: '目标邮箱的已发送',
        type: MailType.send,
      ),
      MailRow(
        emailId: 201,
        profileId: profileId,
        accountId: other,
        mailboxEmail: 'hello@example.com',
        subject: '别的邮箱',
      ),
    ]);
    await db.mailDao.upsertAttachments(profileId, 101, <MailAttachment>[
      const MailAttachment(
        attId: 9001,
        key: 'k1',
        filename: 'a.pdf',
      ),
    ]);
    await db.mailDao.upsertAttachments(profileId, 201, <MailAttachment>[
      const MailAttachment(
        attId: 9002,
        key: 'k2',
        filename: 'b.pdf',
      ),
    ]);
    await db.into(db.reminders).insert(RemindersCompanion.insert(
          profileId: profileId,
          emailId: 101,
          remindAt: DateTime.utc(2026, 10, 20),
          createdAt: DateTime.utc(2026, 10, 13),
        ));
    await db.into(db.reminders).insert(RemindersCompanion.insert(
          profileId: profileId,
          emailId: 201,
          remindAt: DateTime.utc(2026, 10, 20),
          createdAt: DateTime.utc(2026, 10, 13),
        ));
    await db.into(db.drafts).insert(DraftsCompanion.insert(
          profileId: profileId,
          accountEmail: const Value('kedong@example.com'),
          recipientsJson: const Value('[]'),
          content: const Value('用户自己写了一半的信'),
          updatedAt: DateTime.utc(2026, 10, 13),
        ));

    // 同步游标：目标邮箱的两种 type、别的邮箱、以及**实例级聚合**。
    for (final scope in <String>[
      EmailRepository.mailboxScope(target, MailType.receive),
      EmailRepository.mailboxScope(target, MailType.send),
      EmailRepository.mailboxScope(other, MailType.receive),
      EmailRepository.aggregateScope(MailType.receive),
    ]) {
      await db.mailDao.saveSyncState(
        profileId: profileId,
        scope: scope,
        cursorEmailId: 777,
      );
    }
  }

  // 归属 0 的「老信」：`allReceive` 同步 + 摘要列不带 `accountId`，写库时
  // 反查不到地址就落成 0，而 `_merge` 只在入参非 0 时才覆盖（0 是粘的）。
  // 它们只能靠地址与邮箱对上 —— 下面三条用例钉的就是这条地址兜底。
  Future<void> seedOrphan({
    required int emailId,
    required String toEmail,
    int isDel = 0,
    int type = MailType.receive,
    int? attachId,
  }) async {
    await db.mailDao.upsertPage(<MailRow>[
      MailRow(
        emailId: emailId,
        profileId: profileId,
        accountId: 0,
        toEmail: toEmail,
        type: type,
        isDel: isDel,
        subject: '归属未知的老信 $emailId',
      ),
    ]);
    if (attachId != null) {
      await db.mailDao.upsertAttachments(profileId, emailId, <MailAttachment>[
        MailAttachment(attId: attachId, key: 'k$attachId', filename: 'o.pdf'),
      ]);
    }
  }

  setUp(seed);
  tearDown(() async => db.close());

  test('删掉目标邮箱的 mails / attachments / reminders（软删行也不放过）',
      () async {
    final purged = await db.mailDao.purgeMailbox(profileId, target);

    expect(purged.toSet(), <int>{101, 102, 103},
        reason: '返回值是**被删掉的 emailId 列表**，调用方要用它清磁盘');

    for (final id in <int>[101, 102, 103]) {
      expect(await db.mailDao.find(profileId, id), isNull, reason: 'mail $id');
    }
    expect(await db.mailDao.attachmentsOf(profileId, 101), isEmpty);
    final reminders = await db
        .customSelect('SELECT email_id FROM reminders WHERE profile_id = ?',
            variables: <Variable<String>>[Variable<String>(profileId)])
        .get();
    expect(reminders.map((r) => r.read<int>('email_id')), <int>[201]);
  });

  test('别的邮箱一行不动', () async {
    await db.mailDao.purgeMailbox(profileId, target);
    expect((await db.mailDao.find(profileId, 201))!.subject, '别的邮箱');
    expect(await db.mailDao.attachmentsOf(profileId, 201), hasLength(1));
    expect((await db.profileDao.mailboxesOf(profileId))
        .map((m) => m.accountId), contains(other));
  });

  test('删掉 mailbox:<id>:type:* 的同步游标，但**不碰** all:type:*', () async {
    await db.mailDao.purgeMailbox(profileId, target);

    expect(
      await db.mailDao.syncState(
          profileId, EmailRepository.mailboxScope(target, MailType.receive)),
      isNull,
    );
    expect(
      await db.mailDao.syncState(
          profileId, EmailRepository.mailboxScope(target, MailType.send)),
      isNull,
    );
    // 这两条是重点：误删任何一个都会让用户吃一次全量重拉。
    expect(
      await db.mailDao.syncState(profileId,
          EmailRepository.mailboxScope(other, MailType.receive)),
      isNotNull,
      reason: '别的邮箱的游标不该动',
    );
    expect(
      await db.mailDao
          .syncState(profileId, EmailRepository.aggregateScope(MailType.receive)),
      isNotNull,
      reason: '实例级聚合游标（all:type:*）是 SyncEngine 每轮都在维护的，'
          '删了会让整台实例从头全量拉一遍',
    );
  });

  test('草稿保留（那是用户自己写的东西，与邮箱还在不在无关）', () async {
    await db.mailDao.purgeMailbox(profileId, target);
    final drafts = await db.select(db.drafts).get();
    expect(drafts, hasLength(1));
    expect(drafts.single.accountEmail, 'kedong@example.com');
  });

  test('删掉 mailboxes 那一行', () async {
    await db.mailDao.purgeMailbox(profileId, target);
    expect(
      (await db.profileDao.mailboxesOf(profileId)).map((m) => m.accountId),
      <int>[other],
    );
  });

  test('目标邮箱没有邮件时返回空表，不抛', () async {
    final purged = await db.mailDao.purgeMailbox(profileId, 999);
    expect(purged, isEmpty);
  });

  group('归属 0 的老信按地址兜底', () {
    test('投递到目标邮箱的老信（account_id = 0）一并清掉，emailId 也在返回值里',
        () async {
      await seedOrphan(
        emailId: 301,
        toEmail: 'kedong@example.com',
        attachId: 9301,
      );
      await db.into(db.reminders).insert(RemindersCompanion.insert(
            profileId: profileId,
            emailId: 301,
            remindAt: DateTime.utc(2026, 10, 20),
            createdAt: DateTime.utc(2026, 10, 13),
          ));

      final purged = await db.mailDao.purgeMailbox(profileId, target);

      expect(purged.toSet(), <int>{101, 102, 103, 301},
          reason: '301 的 emailId 必须在返回值里 —— 调用方拿它清磁盘附件目录，'
              '漏掉就留下孤儿文件');
      expect(await db.mailDao.find(profileId, 301), isNull,
          reason: '老信自己也要没了');
      expect(await db.mailDao.attachmentsOf(profileId, 301), isEmpty);
      final reminders = await db
          .customSelect('SELECT email_id FROM reminders WHERE profile_id = ?',
              variables: <Variable<String>>[Variable<String>(profileId)])
          .get();
      expect(reminders.map((r) => r.read<int>('email_id')), <int>[201],
          reason: '301 的提醒要跟着走');
    });

    test('投递到**别的、还在的**邮箱的老信一行不动（不会误删）', () async {
      await seedOrphan(
        emailId: 302,
        toEmail: 'hello@example.com',
        attachId: 9302,
      );

      await db.mailDao.purgeMailbox(profileId, target);

      expect(await db.mailDao.find(profileId, 302), isNotNull,
          reason: '它属于 other(12)，那个邮箱还在 —— 地址反查应落到 12 而不是哨兵');
      expect(await db.mailDao.attachmentsOf(profileId, 302), hasLength(1));
    });

    test('软删的归属 0 老信也一并清掉（物理删除面前软删行同样不存在）',
        () async {
      await seedOrphan(
        emailId: 303,
        toEmail: 'kedong@example.com',
        isDel: 1,
      );

      final purged = await db.mailDao.purgeMailbox(profileId, target);

      expect(purged.toSet(), contains(303));
      expect(await db.mailDao.find(profileId, 303), isNull,
          reason: '这里**不按 isDel 过滤** —— 服务端是物理删除，软删行一样没了');
    });
  });

  test('scope 前缀与 EmailRepository.mailboxScope 是同一条口径', () async {
    // DAO 里是**手写**这个前缀的（它不能 import `data/repositories/*`：
    // `core/db` → `data/repositories` 会成环，`mail_dao.dart` 顶上那段
    // 关于 `features/mail_list` 的注释讲的就是这条线的分寸）。
    // 手写就有走散的风险，所以这里把两个字符串**钉在一起**。
    expect(EmailRepository.mailboxScope(8, MailType.receive),
        'mailbox:8:type:0');
    expect(EmailRepository.aggregateScope(MailType.receive), 'all:type:0');
  });

  group('removeMailboxesNotIn 只收拾 mailboxes 那一张表', () {
    // 这个方法**以前是「大删」**：删掉目标邮箱的 `mailboxes` 行之外，还要
    // 连带删它的 mails / attachments / syncStates。问题出在调用方 ——
    // 那个行为有一条**够得着**的坏路径：`AccountRepository.refresh` 在
    // 服务端**成功但返回空列表**时（老版本、或 `data: null`）会把结果换成
    // `_fallbackOnly` —— **只有主邮箱那一个** —— 而 `cameFromServer` 已经是
    // true，于是 `removeMailboxesNotIn(<主邮箱>)` 把其他所有邮箱判成
    // 「服务端没有」，连它们的邮件一起清掉。而且那条路绕过
    // `EmailRepository.delete` 的取消 / 重试，也不清磁盘（留下孤儿文件）。
    //
    // 现在它只删 `mailboxes`：真正要清空本地痕迹的动作只剩一个入口
    // —— `purgeMailbox`（Task 7），而它只在 `AccountRepository.remove`
    // 里被调（服务端已确认删成功）。
    late AppDatabase db;
    const profileId = 'p75';
    const doomed = 9; // 这次服务端没返回它
    const kept = 3;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.profileDao.upsertMailboxes(profileId, <MailboxAccount>[
        const MailboxAccount(accountId: kept, email: 'admin@example.com'),
        const MailboxAccount(accountId: doomed, email: 'gone@example.com'),
      ]);
      await db.mailDao.upsertPage(<MailRow>[
        MailRow(
          emailId: 901,
          profileId: profileId,
          accountId: doomed,
          mailboxEmail: 'gone@example.com',
          subject: '它还有信在本地',
        ),
      ]);
      await db.mailDao.upsertAttachments(profileId, 901, <MailAttachment>[
        const MailAttachment(
          attId: 9101,
          key: 'k901',
          filename: 'a.pdf',
        ),
      ]);
      await db.mailDao.saveSyncState(
        profileId: profileId,
        scope: EmailRepository.mailboxScope(doomed, MailType.receive),
        cursorEmailId: 5,
      );
    });

    tearDown(() async => db.close());

    test('删掉的是 mailboxes 行，邮件 / 附件 / 游标一个都不动', () async {
      await db.profileDao.removeMailboxesNotIn(profileId, <int>{kept});

      expect(
        (await db.profileDao.mailboxesOf(profileId)).map((m) => m.accountId),
        <int>[kept],
        reason: 'mailboxes 行要删 —— 「这个邮箱不在服务端列表里了」正是它要表达的',
      );
      expect(await db.mailDao.find(profileId, 901), isNotNull,
          reason: '**只**删 mailboxes：邮件不该跟着掉');
      expect(await db.mailDao.attachmentsOf(profileId, 901), isNotEmpty);
      expect(
        await db.mailDao.syncState(
          profileId,
          EmailRepository.mailboxScope(doomed, MailType.receive),
        ),
        isNotNull,
        reason: '游标也不动 —— 那个邮箱只是「这次没在列表里」，不是被删了',
      );
    });

    test('没有邮件的邮箱照样删得掉（唯一调用方的真实形态）', () async {
      // setUp 给 doomed(9) 播了一封邮件 —— 那验的是「有邮件时也只删
      // mailboxes 行」。这一条要验的是另一个形态：本地只有 mailboxes 行、
      // 一封邮件都没有的那个邮箱，删起来不该出岔子（`refresh` 的日常）。
      await db.profileDao.upsertMailboxes(profileId, <MailboxAccount>[
        const MailboxAccount(accountId: 55, email: 'empty@example.com'),
      ]);

      await db.profileDao.removeMailboxesNotIn(profileId, <int>{kept});

      expect(
        (await db.profileDao.mailboxesOf(profileId)).map((m) => m.accountId),
        <int>[kept],
        reason: 'accountId 55 与 9 都不在 keep 里，两个都该删掉；不抛即通过',
      );
    });
  });
}
