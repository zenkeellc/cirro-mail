import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/providers/profile_providers.dart' show kAllMailboxes;

/// 「按 (实例, 邮箱) 集合过滤」的 SQL 结果。
///
/// 这是本次改动里唯一一处新的查询路径，钉住它的三条口径：
/// - 空集合 = 全部（聚合语义，不是「什么都不选」）；
/// - 选了具体邮箱时，`account_id = 0` 的**归属未知**老行**不**出现
///   （它可能属于别的邮箱，混进来就是脏数据）；
/// - 选的是合并项（`accountId = kAllMailboxes`）时，那个实例的全部行
///   都要出现，**含** `account_id = 0` 的老行。
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  MailRow row(
    int id, {
    String profile = 'A',
    int account = 1,
    int type = 0,
    int isDel = 0,
  }) =>
      MailRow(
        emailId: id,
        profileId: profile,
        accountId: account,
        type: type,
        isDel: isDel,
        subject: 's$id',
        createTime: DateTime.utc(2026, 10, 9, 0, 0, id),
      );

  Future<List<int>> ids(List<MailboxFilter> boxes, {int? type}) async {
    final rows = await db.mailDao
        .watchMailboxSet(mailboxes: boxes, type: type)
        .first;
    return rows.map((r) => r.emailId).toList();
  }

  test('空集合 = 全部实例的全部邮箱', () async {
    await db.mailDao.upsertPage(<MailRow>[
      row(1),
      row(2, profile: 'B', account: 3),
      row(3, profile: 'A', account: 0),
    ]);
    expect((await ids(const <MailboxFilter>[])).toSet(), <int>{1, 2, 3});
  });

  test('跨实例的多个具体邮箱', () async {
    await db.mailDao.upsertPage(<MailRow>[
      row(1, account: 1),
      row(2, account: 2),
      row(3, profile: 'B', account: 3),
      row(4, profile: 'B', account: 4),
    ]);
    expect(
      (await ids(const <MailboxFilter>[
        MailboxFilter(profileId: 'A', accountId: 1),
        MailboxFilter(profileId: 'B', accountId: 3),
      ])).toSet(),
      <int>{1, 3},
    );
  });

  test('具体邮箱不会把 account_id = 0 的老行带出来', () async {
    await db.mailDao.upsertPage(<MailRow>[
      row(1, account: 1),
      row(2, account: 0),
    ]);
    expect(
      await ids(const <MailboxFilter>[
        MailboxFilter(profileId: 'A', accountId: 1),
      ]),
      <int>[1],
    );
  });

  test('合并项（accountId = 0）把该实例全部行都带出来，含老行', () async {
    await db.mailDao.upsertPage(<MailRow>[
      row(1, account: 1),
      row(2, account: 0),
      row(3, profile: 'B', account: 3),
    ]);
    expect(
      (await ids(const <MailboxFilter>[
        MailboxFilter(profileId: 'A', accountId: kAllMailboxes),
      ])).toSet(),
      <int>{1, 2},
    );
  });

  test('同一个实例的两个邮箱是「或」不是「与」', () async {
    await db.mailDao.upsertPage(<MailRow>[
      row(1, account: 1),
      row(2, account: 2),
      row(3, account: 5),
    ]);
    expect(
      (await ids(const <MailboxFilter>[
        MailboxFilter(profileId: 'A', accountId: 1),
        MailboxFilter(profileId: 'A', accountId: 2),
      ])).toSet(),
      <int>{1, 2},
    );
  });

  test('type 过滤仍然生效', () async {
    await db.mailDao.upsertPage(<MailRow>[
      row(1, type: MailType.receive),
      row(2, type: MailType.send),
    ]);
    expect(
      await ids(
        const <MailboxFilter>[MailboxFilter(profileId: 'A', accountId: 1)],
        type: MailType.send,
      ),
      <int>[2],
    );
  });

  test('已删除的行不出现', () async {
    await db.mailDao.upsertPage(<MailRow>[row(1), row(2)]);
    // `isDel` 不在 `MailRow.copyWith` 的参数里（它是服务端字段，本地不改），
    // 所以直接构造一行 isDel=1 的同 emailId 行覆盖。
    await db.mailDao.upsertPage(<MailRow>[row(2, isDel: 1)]);
    expect((await ids(const <MailboxFilter>[])).toSet(), <int>{1});
  });

  test('unreadOnly 只看收件方向的未读', () async {
    await db.mailDao.upsertPage(<MailRow>[
      row(1).copyWith(unread: UnreadState.unread),
      row(2).copyWith(unread: UnreadState.read),
      row(3, type: MailType.send).copyWith(unread: UnreadState.unread),
    ]);
    final rows = await db.mailDao.watchMailboxSet(unreadOnly: true).first;
    expect(rows.map((r) => r.emailId).toSet(), <int>{1});
  });

  test('按时间倒序，同秒按 emailId 倒序', () async {
    await db.mailDao.upsertPage(<MailRow>[row(1), row(2), row(3)]);
    expect(await ids(const <MailboxFilter>[]), <int>[3, 2, 1]);
  });

  test('limit 生效', () async {
    await db.mailDao.upsertPage(<MailRow>[row(1), row(2), row(3)]);
    final rows = await db.mailDao.watchMailboxSet(limit: 2).first;
    expect(rows.length, 2);
  });
}
