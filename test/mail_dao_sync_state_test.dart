import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';

/// `SyncStates` 里那两列总数相关的写读。
///
/// 它们是侧栏「未读 / 总数」那格的全部数据来源，而错法全是**安静**的：
/// - 用 `saveSyncState`（读旧行 → 整行 replace）去写总数，会与同步引擎的
///   `advanceCursor` 互相丢字段 —— 表现得像「总数偶尔闪回未知」；
/// - 把服务端真的回了 `0` 当成「还不知道」丢掉，空邮箱会永远显示占位符。
///
/// 所以这里钉的是**列级粒度**：一次 `recordMailboxTotal` 之后，除了
/// `remote_total` 与 `remote_total_at`，那一行其余字段一个都不许动。
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  const profile = 'p1';
  const scope = 'mailbox:1:type:0';

  /// drift 默认把 `DateTime` 存成 unix 秒，读回来是**本地时区**的实例 ——
  /// 与写进去那个 `DateTime.utc(...)` 直接 `==` 会不等（两者其实是同一时刻）。
  /// 所以时间一律按「同一时刻」比。
  Matcher sameMoment(DateTime expected) =>
      predicate<DateTime>((actual) => actual.isAtSameMomentAs(expected),
          '某一刻的 $expected');

  test('还没有这一行时插一行（其余列走默认值）', () async {
    final at = DateTime.utc(2026, 10, 12, 8, 30);
    await db.mailDao.recordMailboxTotal(
      profileId: profile,
      scope: scope,
      total: 12,
      at: at,
    );

    final row = await db.mailDao.syncState(profile, scope);
    expect(row, isNotNull);
    expect(row!.remoteTotal, 12);
    expect(row.remoteTotalAt, sameMoment(at));
    // 其余列与「根本没有这一行」等价（见 `recordMailboxTotal` 的注释）。
    expect(row.cursorEmailId, 0);
    expect(row.oldestEmailId, 0);
    expect(row.backfillDone, isFalse);
    expect(row.failCount, 0);
    expect(row.lastSyncAt, isNull);
    expect(row.lastError, isNull);
  });

  /// 这一条是整个改动里最要紧的一条：**只动两列**。
  ///
  /// 先写一条带游标 / 退避计数的行，再记总数，然后逐列断言它们还在 ——
  /// 换成 `saveSyncState(remoteTotal: …)` 的实现时这里会红。
  test('已经有一行时只改那两列，游标与退避计数一字不动', () async {
    final syncAt = DateTime.utc(2026, 10, 11, 7, 0);
    await db.mailDao.saveSyncState(
      profileId: profile,
      scope: scope,
      cursorEmailId: 900,
      oldestEmailId: 120,
      backfillDone: true,
      lastSyncAt: syncAt,
      failCount: 3,
      lastError: 'boom',
    );

    final at = DateTime.utc(2026, 10, 12, 8, 30);
    await db.mailDao.recordMailboxTotal(
      profileId: profile,
      scope: scope,
      total: 42,
      at: at,
    );

    final row = (await db.mailDao.syncState(profile, scope))!;
    expect(row.remoteTotal, 42);
    expect(row.remoteTotalAt, sameMoment(at));
    expect(row.cursorEmailId, 900);
    expect(row.oldestEmailId, 120);
    expect(row.backfillDone, isTrue);
    expect(row.lastSyncAt, sameMoment(syncAt));
    expect(row.failCount, 3);
    expect(row.lastError, 'boom');
  });

  /// 服务端**真的回了 0**（空邮箱）也是一条结论：那一列照样写 0，
  /// 而「已知」与否由 `remoteTotalAt` 非 null 表达。
  test('total = 0 也落库，并且与「从来没探过」分得开', () async {
    final at = DateTime.utc(2026, 10, 12, 8, 30);
    await db.mailDao.recordMailboxTotal(
      profileId: profile,
      scope: scope,
      total: 0,
      at: at,
    );

    final known = (await db.mailDao.syncState(profile, scope))!;
    expect(known.remoteTotal, 0);
    expect(known.remoteTotalAt, sameMoment(at));

    // 没探过的那一个 scope：连行都没有，`remoteTotal` 的默认 0 与上面那个
    // 0 值**长得一样** —— 全靠 `remoteTotalAt` 分开。
    final unknown = await db.mailDao.syncState(profile, 'mailbox:2:type:0');
    expect(unknown, isNull);
  });

  /// 同步顺手拿到的 `total`（`_saveRemoteTotal` → `saveRemoteTotal`）也要
  /// 盖时间戳：不然一次正常同步之后侧栏仍然显示占位符，然后还要白探一次。
  test('saveRemoteTotal 顺手盖时间戳', () async {
    final at = DateTime.utc(2026, 10, 12, 9);
    await db.mailDao.saveRemoteTotal(
      profileId: profile,
      scope: scope,
      total: 7,
      at: at,
    );

    final row = (await db.mailDao.syncState(profile, scope))!;
    expect(row.remoteTotal, 7);
    expect(row.remoteTotalAt, sameMoment(at));
  });

  /// `total <= 0` 仍然早退（那是「还不知道」而不是「空的」）—— 这一条是
  /// `SyncStates.remoteTotal` 那句注解的直接体现，别顺手改掉。
  test('saveRemoteTotal 拿到 0 时什么都不写', () async {
    await db.mailDao.saveRemoteTotal(
      profileId: profile,
      scope: scope,
      total: 0,
      at: DateTime.utc(2026, 10, 12, 9),
    );
    expect(await db.mailDao.syncState(profile, scope), isNull);
  });

  group('watchSyncStatesOfProfile', () {
    test('一条流覆盖该实例的**全部** scope，别的实例不混进来', () async {
      await db.mailDao.recordMailboxTotal(
        profileId: profile,
        scope: 'mailbox:1:type:0',
        total: 10,
        at: DateTime.utc(2026, 10, 12),
      );
      await db.mailDao.recordMailboxTotal(
        profileId: profile,
        scope: 'all:type:0',
        total: 99,
        at: DateTime.utc(2026, 10, 12),
      );
      await db.mailDao.recordMailboxTotal(
        profileId: 'p2',
        scope: 'mailbox:1:type:0',
        total: 5,
        at: DateTime.utc(2026, 10, 12),
      );

      final map = await db.mailDao.watchSyncStatesOfProfile(profile).first;
      expect(map.keys.toSet(), <String>{'mailbox:1:type:0', 'all:type:0'});
      expect(map['mailbox:1:type:0']!.remoteTotal, 10);
      expect(map['all:type:0']!.remoteTotal, 99);
    });

    test('写一次库之后流会重发（不是一次性的 Future）', () async {
      final stream = db.mailDao.watchSyncStatesOfProfile(profile);
      expect((await stream.first).keys, isEmpty);

      await db.mailDao.recordMailboxTotal(
        profileId: profile,
        scope: 'mailbox:1:type:0',
        total: 3,
        at: DateTime.utc(2026, 10, 12),
      );

      final after = await stream.first;
      expect(after['mailbox:1:type:0']!.remoteTotal, 3);
    });
  });
}
