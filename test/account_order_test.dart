// 这一条修的是**今天就存在的顺序不一致**（规格 §7.2）：
//
//   服务端 `accountService.list` 排 `desc(sort), asc(accountId)`；
//   本地 `profile_dao.dart` 却排 `sort ASC, accountId ASC` —— 正好相反。
//
// 症状是可复现的：用户点一次「置顶」，
//   网页端那个邮箱跳到最前，
//   App 里它**跳到最末**。
// 本机 App 库 `mailboxes` 表里就是这样：`admin@example.com`（sort=3）排在
// `kedong@example.com`（sort=0）后面，而网页端它排第一位。
//
// 为什么改方向是安全的：`sort` 列**只有置顶语义**，唯一的写者是
// `upsertMailboxes`（服务端行整行覆盖），而服务端从不写 0 以外的值 ——
// 加邮箱时走列默认值 0，只有 `setAsTop` 会写非 0。所以 sort 相同的那一堆
// 仍然按 accountId 升序（那正是服务端对同 sort 的第二关键字）。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/data/models/mailbox_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  const profileId = 'p1';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 线上 user 7 的真实形状：主邮箱被 setAsTop 抬过两次（sort = 3），
    // 其余都是 0。
    await db.profileDao.upsertMailboxes(profileId, <MailboxAccount>[
      const MailboxAccount(accountId: 3, email: 'admin@example.com', sort: 3),
      const MailboxAccount(accountId: 8, email: 'kedong@example.com'),
      const MailboxAccount(accountId: 12, email: 'hello@example.com'),
      const MailboxAccount(accountId: 26, email: 'archive@example.com'),
    ]);
  });

  tearDown(() async => db.close());

  test('mailboxesOf：sort 大的在前，同 sort 按 accountId 升序', () async {
    final rows = await db.profileDao.mailboxesOf(profileId);
    expect(
      rows.map((m) => m.accountId).toList(),
      <int>[3, 8, 12, 26],
      reason: 'admin（sort=3）必须排第一（网页端就是这个顺序），'
          '其余 sort=0 的按 accountId 升序',
    );
  });

  test('watchMailboxes：与 mailboxesOf 同一个顺序', () async {
    // 两条查询的 orderBy 是**各写一份**的，改了一处忘了另一处是本仓库
    // 发生过的事（`_mailboxPredicate` 那条注释就是在讲同类问题）。
    final rows = await db.profileDao.watchMailboxes(profileId).first;
    expect(rows.map((m) => m.accountId).toList(), <int>[3, 8, 12, 26]);
  });

  test('置顶一个 sort 为 0 的邮箱：它紧跟主邮箱，其余顺序不动', () async {
    // 服务端 `setAsTop` 的算术：主邮箱原本 sort=3 → 抬到 4；目标 → 4 - 1 = 3。
    // 于是目标与主邮箱同为 sort=3 时靠 accountId 决出先后 —— 8 在 3 后面，
    // 这正是服务端 `asc(accountId)` 那个第二关键字存在的理由。
    await db.profileDao.upsertMailboxes(profileId, <MailboxAccount>[
      const MailboxAccount(accountId: 3, email: 'admin@example.com', sort: 4),
      const MailboxAccount(accountId: 8, email: 'kedong@example.com', sort: 3),
    ]);
    final rows = await db.profileDao.mailboxesOf(profileId);
    expect(rows.map((m) => m.accountId).toList(), <int>[3, 8, 12, 26]);
  });

  test('primaryOrNull 仍然优先 allReceive，否则第一行', () async {
    final rows = await db.profileDao.mailboxesOf(profileId);
    // 没有 allReceive 时取第一行 —— 它现在真的是服务端排名第一的那个。
    expect(rows.primaryOrNull!.accountId, 3);

    await db.profileDao.upsertMailboxes(profileId, <MailboxAccount>[
      const MailboxAccount(
        accountId: 26,
        email: 'archive@example.com',
        allReceive: 1,
      ),
    ]);
    final after = await db.profileDao.mailboxesOf(profileId);
    expect(after.primaryOrNull!.accountId, 26);
  });
}
