// 本地邮件的**变更发布点**。
//
// 扩展（全文索引）靠这套事件做增量：写入的几行、删掉的几行、整个实例被清空。
// 它不接 drift 的 `tableUpdates`（只说「某张表变了」，不说是哪几行；raw SQL
// 的 `kind` 是 null；跨 isolate 还看不见）—— 理由见 `mail_store_events.dart`。
//
// 显式发布的代价就是「新增一条写 `mails` 的路径时得记得回来发一条」。所以这里
// **逐条跑真 DAO** 钉住现存的那几条：写入两条、删除三条。少一条的症状是
// 「搜索里还搜得到已经删掉的邮件」，而它不会报错。
//
// `mails` 的删除有**三条**路，不是两条 —— 第三条（`ProfileDao._clearDataOf`，
// 由删实例与退出登录调用）最容易被漏掉。
import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/db/mail_store_events.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late List<MailStoreEvent> events;
  late StreamSubscription<MailStoreEvent> sub;

  const profileId = 'p1';

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    events = <MailStoreEvent>[];
    // 广播流：**订阅要在动作之前**（冷订阅收不到历史，这正是扩展那边
    // 「先冷扫、再订阅」那条规矩的同一件事）。
    sub = mailStoreChanges().listen(events.add);
  });

  tearDown(() async {
    await sub.cancel();
    await db.close();
  });

  /// 事件是异步派发的，动作返回时可能还在队列里。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  MailRow row(int id, {int accountId = 1, String subject = '标题'}) => MailRow(
        emailId: id,
        profileId: profileId,
        accountId: accountId,
        mailboxEmail: 'box@example.com',
        subject: subject,
        type: MailType.receive,
        unread: UnreadState.unread,
      );

  Future<void> seedProfile() => db.profileDao.upsertProfile(
        const Profile(
          id: profileId,
          baseUrl: 'https://mail.example.com',
          name: '测试实例',
        ),
      );

  /// 落一行 + 把事件清空（播种不该混进断言里）。
  Future<void> seedMail(int id, {int accountId = 1}) async {
    await db.mailDao.upsertPage(<MailRow>[row(id, accountId: accountId)]);
    await settle();
    events.clear();
  }

  group('写入', () {
    test('upsertPage 发一批 upserted，带的是这一批的 id', () async {
      await db.mailDao.upsertPage(<MailRow>[row(11), row(12)]);
      await settle();

      expect(events, hasLength(1));
      final event = events.single as MailUpserted;
      expect(event.profileId, profileId);
      expect(event.emailIds, <int>[11, 12]);
    });

    /// `upsertFull` 是**补正文**那条路 —— 它不发事件的话，「拉回来的正文
    /// 搜不到」会看起来像索引坏了。
    test('upsertFull 发一封 upserted', () async {
      await seedMail(11);
      await db.mailDao.upsertFull(
        row(11).copyWith(content: '<p>全文</p>', text: '全文'),
      );
      await settle();

      final event = events.single as MailUpserted;
      expect(event.emailIds, <int>[11]);
    });

    /// 空批不发事件：一页空响应、或者一次「没有新邮件」的轮询，不该在
    /// 订阅那边产生任何动静。
    test('空的一批什么都不发', () async {
      await db.mailDao.upsertPage(const <MailRow>[]);
      await settle();
      expect(events, isEmpty);
    });
  });

  group('删除', () {
    test('deleteRefs 按 profileId 分组发 deleted', () async {
      await seedMail(11);
      await seedMail(12);
      await db.mailDao.deleteRefs(<MailRef>[
        MailRef(profileId: profileId, emailId: 11),
        MailRef(profileId: profileId, emailId: 12),
      ]);
      await settle();

      final event = events.single as MailDeleted;
      expect(event.profileId, profileId);
      expect(event.emailIds, <int>[11, 12]);
    });

    test('deleteRefs 跨实例时按实例分成两条', () async {
      await seedMail(11);
      await db.mailDao.upsertPage(<MailRow>[
        MailRow(
          emailId: 21,
          profileId: 'p2',
          subject: '另一个实例',
        ),
      ]);
      await settle();
      events.clear();

      await db.mailDao.deleteRefs(<MailRef>[
        MailRef(profileId: profileId, emailId: 11),
        const MailRef(profileId: 'p2', emailId: 21),
      ]);
      await settle();

      expect(events, hasLength(2));
      final byProfile = <String, List<int>>{
        for (final e in events.cast<MailDeleted>()) e.profileId: e.emailIds,
      };
      expect(byProfile, <String, List<int>>{profileId: <int>[11], 'p2': <int>[21]});
    });

    test('空的 refs 什么都不发（也不开事务）', () async {
      await db.mailDao.deleteRefs(const <MailRef>[]);
      await settle();
      expect(events, isEmpty);
    });

    /// 删邮箱是**物理删除**，那批邮件的索引行也得跟着走。
    test('purgeMailbox 发的正是它返回的那批 id', () async {
      await db.profileDao.upsertMailboxes(profileId, <MailboxAccount>[
        const MailboxAccount(accountId: 8, email: 'box@example.com'),
      ]);
      await seedMail(11, accountId: 8);
      await seedMail(12, accountId: 8);
      await seedMail(13, accountId: 99); // 别动它

      final purged = await db.mailDao.purgeMailbox(profileId, 8);
      await settle();

      final event = events.single as MailDeleted;
      expect(event.profileId, profileId);
      expect(event.emailIds, unorderedEquals(<int>[11, 12]));
      expect(purged, unorderedEquals(<int>[11, 12]));
      expect(purged, isNot(contains(13)), reason: '别的邮箱的信不能跟着死');
    });

    test('purgeMailbox 对着真数据发 deleted', () async {
      await db.profileDao.upsertMailboxes(profileId, <MailboxAccount>[
        const MailboxAccount(accountId: 8, email: 'box@example.com'),
      ]);
      await seedMail(11, accountId: 8);
      await seedMail(12, accountId: 8);

      final purged = await db.mailDao.purgeMailbox(profileId, 8);
      await settle();

      final event = events.single as MailDeleted;
      expect(event.profileId, profileId);
      expect(event.emailIds, unorderedEquals(purged));
    });
  });

  group('整个实例被清空', () {
    /// 第三条删除路径：`DELETE FROM mails WHERE profile_id = ?`。
    ///
    /// 核心在删之前并不知道有哪些 id（也没必要知道），所以事件是 `reset`
    /// 而不是一长串 `deleted`。扩展那边要做的也正是「把这个实例的一切抹掉」。
    test('删实例发 reset（deleteProfileCascade）', () async {
      await seedProfile();
      await seedMail(11);

      await db.profileDao.deleteProfileCascade(profileId);
      await settle();

      final event = events.single as MailStoreReset;
      expect(event.profileId, profileId);
    });

    /// 退出登录但保留服务器那条路。
    ///
    /// 漏掉它的症状最容易骗过人：**删掉实例之后搜索仍然能搜到**，点进去却是
    /// 一封空信（本地那行已经没了）。
    test('退出登录保留服务器也发 reset（clearProfileData）', () async {
      await seedProfile();
      await seedMail(11);

      await db.profileDao.clearProfileData(profileId);
      await settle();

      final event = events.single as MailStoreReset;
      expect(event.profileId, profileId);
    });
  });

  group('订阅语义', () {
    /// 广播流：**订阅之前发生的事一律收不到**。
    ///
    /// 这不是缺陷，而是扩展那边「先冷扫、再订阅」那条顺序的根据 —— 反过来的
    /// 话，冷扫期间发生的变更就永远丢了（而且看起来一切正常）。
    test('晚订阅收不到历史事件', () async {
      await db.mailDao.upsertPage(<MailRow>[row(11)]);
      await settle();

      final late2 = <MailStoreEvent>[];
      final s = mailStoreChanges().listen(late2.add);
      addTearDown(s.cancel);
      await settle();
      expect(late2, isEmpty, reason: '冷订阅不该补发历史');
    });

    test('两个订阅者都收得到（broadcast 语义）', () async {
      final a = <MailStoreEvent>[];
      final b = <MailStoreEvent>[];
      final sa = mailStoreChanges().listen(a.add);
      final sb = mailStoreChanges().listen(b.add);
      addTearDown(sa.cancel);
      addTearDown(sb.cancel);

      await db.mailDao.upsertPage(<MailRow>[row(11)]);
      await settle();

      expect(a, hasLength(1));
      expect(b, hasLength(1));
    });

    /// 事件里的 id 列表必须是**新的、不可被外部改动的**列表 ——
    /// 发送方之后复用同一个 list 会让订阅方看到已经被改过的内容。
    test('事件里带的是独立的一份 id 列表', () async {
      final ids = <int>[11];
      publishMailsUpserted(profileId, ids);
      ids.add(12);
      await settle();

      final event = events.single as MailUpserted;
      expect(event.emailIds, <int>[11]);
    });
  });
}
