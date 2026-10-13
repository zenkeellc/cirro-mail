import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/instance/sync_scheduler.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「关掉窗口之后还在菜单栏里收信」这条行为的 Dart 侧那一半。
///
/// macOS 上 `applicationShouldTerminateAfterLastWindowClosed` 已经返回 false
/// 了（见 `macos/Runner/AppDelegate.swift`），也就是说关窗之后进程还活着、
/// 菜单栏图标还挂着。但那只是**壳**还活着 —— 如果 Dart 这一侧把关窗当成
/// 「进后台」而把调度器停掉，用户看到的就是「图标还在，信却不来了」，
/// 而且是静默的：没有任何界面会告诉他这件事。
///
/// 所以这里钉的是 `SyncController` 的那个分叉：
/// - **桌面端**的 `hidden`/`paused` 只意味着「窗口看不见了」（关窗、最小化、
///   Cmd+H），收信必须继续；
/// - **移动端**照旧要停 —— 那是真的进了后台，系统随时会掐掉进程，跑也白跑。
///
/// 两者共用同一个 `AppLifecycleState` 回调，差别只有 `_isDesktop` 一次判断。
/// 「顺手把桌面也算进去」这种改动**不会报错、也不会被别的用例发现**，只会
/// 让关窗之后再也不收信 —— 这条用例就是为它准备的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 走真实的 `resumed → inactive → hidden` 序列。
  ///
  /// 不能直接跳 `hidden`：`AppLifecycleListener` 对非法跳转有 assert，而且
  /// 真机上确实是逐档变过去的。macOS 上关窗停在 `hidden`（没有 `paused`），
  /// 所以这一步才是最关键的。
  void hideWindow() {
    final binding = WidgetsBinding.instance;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }

  void showWindow() {
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  group('窗口看不见了要不要继续收信', () {
    test('macOS：关窗 / 最小化之后调度器照跑', () async {
      final harness = await _Harness.create(platform: TargetPlatform.macOS);
      harness.scheduler.start(const <Profile>[]);
      expect(harness.scheduler.isRunning, isTrue, reason: '前提：先让它跑起来');

      hideWindow();
      await pumpEventQueue();

      expect(
        harness.scheduler.isRunning,
        isTrue,
        reason: '关窗之后进程还在菜单栏里活着，收信不该停',
      );

      showWindow();
      harness.resetPlatform();
    });

    test('Android：进后台把调度器停掉（上面那条不许把它顺手改坏）', () async {
      final harness = await _Harness.create(platform: TargetPlatform.android);
      harness.scheduler.start(const <Profile>[]);
      expect(harness.scheduler.isRunning, isTrue);

      hideWindow();
      await pumpEventQueue();

      expect(
        harness.scheduler.isRunning,
        isFalse,
        reason: 'Android 进后台就该停 —— 系统随时会掐掉这个进程，跑了也是白跑',
      );

      showWindow();
      harness.resetPlatform();
    });

    test('macOS：设置页那个总开关仍然停得掉（「不适用」不等于「管不了」）',
        () async {
      final harness = await _Harness.create(platform: TargetPlatform.macOS);
      harness.scheduler.start(const <Profile>[]);

      harness.controller.pause();
      expect(
        harness.scheduler.isRunning,
        isFalse,
        reason: '用户自己关掉收信时必须真的停 —— 桌面端豁免的只有「窗口没了」这件事',
      );

      harness.resetPlatform();
    });
  });
}

class _Harness {
  _Harness._(this.scheduler, this.controller);

  static Future<_Harness> create({required TargetPlatform platform}) async {
    debugDefaultTargetPlatformOverride = platform;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        // `SyncController.build` 会 `ref.listen(onlineProvider)`，而真身第一
        // 件事就是去问 `connectivity_plus` 的平台通道 —— 测试里没有那个通道，
        // 于是这条异步调用会**在用例结束之后**才失败，报出一句很容易看错方向
        // 的「This test failed after it had already completed」。
        // 这里换成一个固定的「在线」，反正在场用例验的是生命周期，不是联网。
        onlineProvider.overrideWith((ref) => Stream<bool>.value(true)),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    // 读一次控制器，把它的 `AppLifecycleListener` 挂上 —— 它就是被测对象。
    container.read(syncControllerProvider);
    final harness = _Harness._(
      container.read(syncSchedulerProvider),
      container.read(syncControllerProvider.notifier),
    );
    // 调度器的时钟要收干净，否则那条 `Timer.periodic` 会跨到下一个用例里。
    addTearDown(harness.scheduler.stop);
    return harness;
  }

  final SyncScheduler scheduler;
  final SyncController controller;

  /// 把平台与生命周期都还原，免得串到下一个用例。
  void resetPlatform() {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      WidgetsBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
    debugDefaultTargetPlatformOverride = null;
  }
}
