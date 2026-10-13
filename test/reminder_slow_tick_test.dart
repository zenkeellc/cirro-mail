import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「稍后提醒」在 Linux 上的实际节奏 = **两道东西相乘**：
///
/// 1. `SyncScheduler` 的 1 秒心跳 → 慢活闸门（`slowEveryTicks = 20`）；
/// 2. `ReminderTicker.onHeartbeat`（`SyncScheduler.onSlowTick` 的回调）→ `run()`。
///
/// 第 1 道在这里钉住，第 2 道在 `reminder_ticker_test.dart` 里钉住
/// （「每一拍都真的去查库」）。**两条缺一不可** —— 这个功能真正出过的 bug
/// 正是「两道闸门都在数 20，乘起来 ≈400 秒」，而当时两边各自的用例都是绿的：
/// ticker 那条只验「自己数 20 拍」，看不到外面还有一道。
///
/// 这一条测的是**契约**（20 拍 ≈ 20 秒），不是实现细节：把 `slowEveryTicks`
/// 改成别的值而不同步改注释，就会在这里红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('调度器的慢活：1 秒心跳走满 20 拍才调一次 onSlowTick（≈20 秒）',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final scheduler = container.read(syncSchedulerProvider);
    // 时钟要收干净，否则那条 `Timer.periodic` 会活到用例之外
    // （`testWidgets` 会当场报「A Timer is still pending」）。
    addTearDown(scheduler.stop);

    var slowTicks = 0;
    scheduler.onSlowTick = () => slowTicks++;

    // 空实例表就够：慢活那一行在 `_runOne` 之前，而 `_runOne` 在
    // `_engines` 为空时立刻返回 —— 这条用例不需要任何网络/仓储。
    await scheduler.start(const <Profile>[]);

    // `start()` 自己先走了一拍（慢活计数从 1 开始）。
    expect(slowTicks, 0, reason: '第 1 拍还没满 20');

    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(slowTicks, 0, reason: '第 19 拍仍然不动');

    await tester.pump(const Duration(seconds: 1));
    expect(slowTicks, 1, reason: '第 20 拍 —— 换算成墙钟就是 ≈20 秒');

    // 计数归零，下一轮同样要再等 20 拍。
    for (var i = 0; i < 19; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(slowTicks, 1, reason: '第二十拍还没到，不该连发');
    await tester.pump(const Duration(seconds: 1));
    expect(slowTicks, 2, reason: '第二轮的第 20 拍');

    // **必须在用例体里停掉**，不能只靠 `addTearDown`：`testWidgets` 在跑
    // teardown 之前就先查一遍「还有没有活着的定时器」，那时这条 1 秒心跳
    // 还在，报的是一句与本题无关的「A Timer is still pending」。
    // （`desktop_sync_keepalive_test.dart` 用 `test(...)` 就没有这一道查，
    // 可以只靠 `addTearDown`。）
    scheduler.stop();
  });
}
