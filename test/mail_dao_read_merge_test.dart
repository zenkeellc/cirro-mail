import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/daos/mail_dao.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';

/// 本地 `unread` 是**单调**的：服务端行只能把它抬成已读，不能打回未读。
///
/// 这一条是「点开邮件立刻变已读」的前置条件 —— 没有它，一个「取页早于
/// `PUT /email/read` 返回」的陈旧页（`backfillBodies` 每轮轮询都跑）会把刚
/// 标上的已读盖回去，用户看到的就是「读着读着自己又变成未读了」。
/// Web 端为同一个坑专门写了 `keepRead`（`mail-vue/src/store/email.js`）。
///
/// 两个出口都要钉住：`_merge` 有摘要分支与完整分支两条 `copyWith`，只补一条
/// 的话另一条上回弹照旧，而且只有走到那条路的场景才看得出来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profileId = 'p1';
  const emailId = 12;

  late AppDatabase db;
  late MailDao dao;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = db.mailDao;
  });

  tearDown(() => db.close());

  /// 一页**收信方向**的行（未读计数只算这个方向）。
  Map<String, Object?> pageRow({
    int id = emailId,
    int unread = UnreadState.unread,
    bool withBody = false,
  }) =>
      <String, Object?>{
        'emailId': id,
        'toEmail': 'me@example.net',
        'sendEmail': '',
        'subject': '标题',
        'type': MailType.receive,
        'status': 0,
        'unread': unread,
        'isDel': 0,
        'createTime': '2026-10-09 10:00:00',
        if (withBody) 'content': '<p>正文</p>',
        if (withBody) 'text': '正文',
      };

  /// 走真实入口落一页：`MailRow.fromJson` 那一层不能绕开，否则测的是我
  /// 手搓的对象而不是服务端载荷的解析结果。
  ///
  /// `MailRow.fromJson` 的 `profileId` 是**具名必填**、`mailboxEmail` 也得自己
  /// 传（服务端载荷里没有这两样）。
  List<MailRow> parse(List<Map<String, Object?>> rows) => rows
      .map((json) => MailRow.fromJson(
            json.cast<String, dynamic>(),
            profileId: profileId,
            mailboxEmail: 'me@example.net',
          ))
      .toList(growable: false);

  Future<void> upsertPage(List<Map<String, Object?>> rows) =>
      dao.upsertPage(parse(rows));

  Future<void> upsertFull(Map<String, Object?> row) =>
      dao.upsertFull(parse(<Map<String, Object?>>[row]).single);

  test('服务端 unread=1 能把本地抬成已读（正常回执走得通）', () async {
    await upsertPage(<Map<String, Object?>>[pageRow()]);
    expect((await dao.find(profileId, emailId))!.isUnread, isTrue);

    await upsertPage(
      <Map<String, Object?>>[pageRow(unread: UnreadState.read)],
    );

    expect((await dao.find(profileId, emailId))!.isUnread, isFalse);
  });

  test('本地已读后，unread=0 的摘要页灌进来不回弹（upsertPage）', () async {
    await upsertPage(<Map<String, Object?>>[pageRow()]);
    await dao.markRead(
      <MailRef>[MailRef(profileId: profileId, emailId: emailId)],
      read: true,
    );

    // 一个在 PUT 之前取到的页 —— 服务端那行还是 0。
    await upsertPage(<Map<String, Object?>>[pageRow()]);

    expect(
      (await dao.find(profileId, emailId))!.isUnread,
      isFalse,
      reason: '陈旧摘要页不能把已读打回未读',
    );
  });

  test('本地已读后，unread=0 的 full=1 行也不回弹（upsertFull）', () async {
    await upsertPage(<Map<String, Object?>>[pageRow()]);
    await dao.markRead(
      <MailRef>[MailRef(profileId: profileId, emailId: emailId)],
      read: true,
    );

    // 这条走 `_merge` 的**第二个**出口：正文齐了的行也要能覆盖 content。
    await upsertFull(pageRow(withBody: true));

    final row = await dao.find(profileId, emailId);
    expect(row!.isUnread, isFalse, reason: 'backfillBodies 那条路同样不能回弹');
    expect(row.hasFullBody, isTrue, reason: '正文该覆盖还是要覆盖');
    expect(row.content, '<p>正文</p>');
  });

  test('本地标未读后，服务端已读页把它拉回已读（文档化的取舍）', () async {
    await upsertPage(
      <Map<String, Object?>>[pageRow(unread: UnreadState.read)],
    );
    await dao.markRead(
      <MailRef>[MailRef(profileId: profileId, emailId: emailId)],
      read: false,
    );
    expect((await dao.find(profileId, emailId))!.isUnread, isTrue);

    // 服务端的 `unread` 只会被置 1，所以下一次同步必然把它盖回已读 ——
    // 单调合并的代价，不是 bug。
    await upsertPage(
      <Map<String, Object?>>[pageRow(unread: UnreadState.read)],
    );

    expect((await dao.find(profileId, emailId))!.isUnread, isFalse);
  });

  test('未读数跟着落库变：读掉一封后按邮箱分组的计数归零', () async {
    await upsertPage(<Map<String, Object?>>[pageRow()]);
    // `account_id` 由调用方补（列表接口不返回它），这里手动归位一次。
    await dao.reassignAccountIds(profileId, <String, int>{'me@example.net': 3});

    expect(await dao.unreadCountOfMailbox(profileId, 3), 1);

    await dao.markRead(
      <MailRef>[MailRef(profileId: profileId, emailId: emailId)],
      read: true,
    );

    expect(await dao.unreadCountOfMailbox(profileId, 3), 0);
    // 一条流覆盖全部邮箱：没有未读的邮箱**不在 Map 里**，取值方按 0 处理。
    final byMailbox = await dao.watchUnreadByMailbox().first;
    expect(byMailbox[profileId]?[3] ?? 0, 0);
  });

  test('watchUnreadByMailbox 按 (实例, 邮箱) 分组，别的实例同号不串', () async {
    await upsertPage(<Map<String, Object?>>[pageRow()]);
    await dao.reassignAccountIds(profileId, <String, int>{'me@example.net': 3});

    // 另一台实例的同号邮件，落在另一个邮箱上。
    await dao.upsertPage(<MailRow>[
      MailRow(
        emailId: emailId,
        profileId: 'p2',
        toEmail: 'other@example.net',
        subject: '别的实例的同号信',
        type: MailType.receive,
      ),
    ]);
    await dao.reassignAccountIds('p2', <String, int>{'other@example.net': 5});

    final byMailbox = await dao.watchUnreadByMailbox().first;
    expect(byMailbox[profileId]![3], 1);
    expect(byMailbox['p2']![5], 1);
    expect(byMailbox[profileId]!.containsKey(5), isFalse);
  });
}
