import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/features/notifications/reminder_ticker.dart';

/// 降级路的**纯逻辑**：挑哪些行、弹的顺序、弹完置什么。
///
/// **测不了什么，先说清楚**：Linux 那个插件类的单测跑不了 ——
/// `flutter_local_notifications_linux` 会去 `dlopen('libc.so.6')`，
/// 在 macOS 的测试进程里直接失败。所以 `show` 在这里是个记录器，
/// 「真的弹出来长什么样」只能人在 Linux 上点一次（见收尾清单）。
void main() {
  late AppDatabase db;
  late List<int> shown;
  late ReminderTicker ticker;

  final now = DateTime.utc(2026, 10, 11, 10, 0);

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    shown = <int>[];
    ticker = ReminderTicker(
      dao: db.reminderDao,
      show: (r) async => shown.add(r.emailId),
    );
  });

  tearDown(() => db.close());

  Future<int> add(int emailId, DateTime remindAt) => db.reminderDao.insert(
        profileId: 'p1',
        emailId: emailId,
        subject: '主题 $emailId',
        sender: 'alice@example.com',
        remindAt: remindAt,
        createdAt: now,
      );

  test('到点的弹出来、弹完置 firedAt；再跑一次不再弹', () async {
    await add(7, now.subtract(const Duration(minutes: 1)));

    expect(await ticker.run(now: now), 1);
    expect(shown, <int>[7]);

    expect(await ticker.run(now: now), 0, reason: '弹过的不能再弹一次');
    expect(shown, <int>[7]);
    expect((await db.reminderDao.all()).single.firedAt, isNotNull);
  });

  test('没到点的一条都不弹', () async {
    await add(7, now.add(const Duration(minutes: 1)));
    expect(await ticker.run(now: now), 0);
    expect(shown, isEmpty);
    expect((await db.reminderDao.all()).single.firedAt, isNull);
  });

  test('多条一起到点：按时间升序弹，一次全弹出来', () async {
    await add(7, now.subtract(const Duration(minutes: 5)));
    await add(8, now.subtract(const Duration(minutes: 30)));
    await add(9, now.subtract(const Duration(hours: 1)));

    expect(await ticker.run(now: now), 3);
    expect(shown, <int>[9, 8, 7], reason: '早排的先弹');
  });

  test('某一条弹失败不置 firedAt（下一拍会重试），也不挡住后面的', () async {
    final failing = ReminderTicker(
      dao: db.reminderDao,
      show: (r) async {
        if (r.emailId == 7) throw StateError('弹不出来');
        shown.add(r.emailId);
      },
    );
    await add(7, now.subtract(const Duration(minutes: 5)));
    await add(8, now.subtract(const Duration(minutes: 10)));

    expect(await failing.run(now: now), 1, reason: '只成功了一条');

    final rows = await db.reminderDao.all();
    final seven = rows.firstWhere((r) => r.emailId == 7);
    final eight = rows.firstWhere((r) => r.emailId == 8);
    expect(seven.firedAt, isNull, reason: '没弹出来就不能算弹过');
    expect(eight.firedAt, isNotNull);
    // 下一拍会把 7 再捞一次（它冒出来了）
    expect(shown, <int>[8]);
    expect(await failing.run(now: now), 0, reason: '7 还是弹不出来');
  });

  test('心跳每一拍都真的去查一次库（节流只在调度器那一处）', () async {
    // 这条用例是「两道闸门相乘」那个 bug 的守卫。`onHeartbeat` 原来自己也在
    // 数 20 拍，而它挂的 `SyncScheduler.onSlowTick` **本来就已经是每 20 拍
    // 一次**了 —— 两下一乘 ≈400 秒，Linux 上（那条降级路是唯一一条）用户设
    // 的「今天 18:00」当天不会响。
    //
    // 断言用「一拍下来 `shown` 就该变」而不是只断返回值：只断返回值的话，
    // 把节流从 20 改成 1 也能全绿，而真正的契约是**回调被调 = 查一次库**。
    //
    // 两条都排在一个**远在过去**的时刻：`onHeartbeat` 不带 `now`，`run()`
    // 拿的是真实墙钟，写死 2026-10-11 那种「刚刚过去一点」的常量会在时钟
    // 稍早的机器上变成「还没到点」。
    await add(7, DateTime.utc(2000, 1, 2));
    await add(8, DateTime.utc(2000, 1, 1));

    expect(ticker.onHeartbeat(), isTrue, reason: '第一拍就该查');
    await pumpEventQueue();
    expect(shown, <int>[8, 7], reason: '这一拍真的查了库、真的弹了，早排的先弹');

    // 第二拍：还是查（不是「数满 20 拍才查」）。新加一条，看它这一拍就出来。
    await add(9, DateTime.utc(2000, 1, 3));
    expect(ticker.onHeartbeat(), isTrue);
    await pumpEventQueue();
    expect(shown, <int>[8, 7, 9], reason: '每一拍都查，不是攒 20 拍');
  });

  test('重入闸门：上一轮没跑完时再调直接返回 0', () async {
    await add(7, now.subtract(const Duration(minutes: 1)));
    // 不 await 第一次，紧接着第二次 —— 第二次该被 `_running` 挡掉。
    final first = ticker.run(now: now);
    final second = await ticker.run(now: now);
    expect(second, 0);
    expect(await first, 1);
    expect(shown, <int>[7], reason: '只弹一次');
  });

  test('库已经关了也不抛（心跳回调里抛异常没人接）', () async {
    // **另开一个库并在本用例里关掉它**，不关外层那个 —— 外层还有
    // `tearDown(() => db.close())`，两边都关同一个连接会关第二次
    // （drift 上抛 `StateError: Can't re-open a database after closing it`，
    // 而且报在 tearDown 里，看着与本条用例无关）。
    final dead = AppDatabase.forTesting(NativeDatabase.memory());
    final ticker = ReminderTicker(
      dao: dead.reminderDao,
      show: (r) async => shown.add(r.emailId),
    );
    await dead.close();
    expect(await ticker.run(now: now), 0);
  });
}
