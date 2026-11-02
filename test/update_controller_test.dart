// 检查更新状态机（`UpdateController`）的护栏。
//
// 四种终态各钉一条：已是最新 / 有更新 / 失败 / 关闭（清单未配置或用户关掉
// 自动检查）。另外钉住三条容易写错的规则：
//
// 1. 「每天最多一次」只在**成功**后写时间戳 —— 失败写进去等于当天不再重试；
// 2. 「同一个版本只提示一次」靠 prefs 里的版本串，不是 bool；
// 3. 手动「检查」不受自动检查开关影响（开关只管启动那一次）。
//
// 全程不碰网络：`UpdateService` 用 mocktail 换成假的，prefs 是 mock 的
// `SharedPreferences`，版本用 `appVersionProvider` 的 override 注入。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/update/update_controller.dart';
import 'package:mail_app/core/update/update_manifest.dart';
import 'package:mail_app/core/update/update_service.dart';
import 'package:mail_app/core/version/app_version.dart';
import 'package:mail_app/core/version/version_info.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockUpdateService extends Mock implements UpdateService {}

const AppVersion _current = AppVersion(name: '0.1.0', buildNumber: 131);

UpdateRelease _release({
  String version = '0.2.0',
  int buildNumber = 132,
}) =>
    UpdateRelease(
      version: version,
      buildNumber: buildNumber,
      notes: '修了几个问题',
      releaseUrl: 'https://cirro.zenkee.com/download',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockUpdateService service;

  setUp(() {
    service = _MockUpdateService();
    when(() => service.isConfigured).thenReturn(true);
  });

  Future<PrefsStore> prefsWith([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    return PrefsStore(await SharedPreferences.getInstance());
  }

  ProviderContainer boot(PrefsStore prefs) {
    final container = ProviderContainer(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        updateServiceProvider.overrideWithValue(service),
        appVersionProvider.overrideWith((ref) async => _current),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('已是最新：清单版本不比当前新 → upToDate，并记下检查时间', () async {
    final prefs = await prefsWith();
    when(() => service.fetchLatest())
        .thenAnswer((_) async => _release(version: '0.1.0', buildNumber: 131));
    final container = boot(prefs);
    final now = DateTime(2026, 11, 2, 10, 30);

    final state =
        await container.read(updateCheckProvider.notifier).check(now: now);

    expect(state.status, UpdateCheckStatus.upToDate);
    expect(state.release?.display, '0.1.0+131');
    expect(prefs.updateLastCheckMs, now.millisecondsSinceEpoch);
    expect(container.read(updateCheckProvider).status, UpdateCheckStatus.upToDate);
  });

  test('有更新：available + 版本；提示过一次之后不再重复提示', () async {
    final prefs = await prefsWith();
    when(() => service.fetchLatest()).thenAnswer((_) async => _release());
    final container = boot(prefs);
    final controller = container.read(updateCheckProvider.notifier);

    final state = await controller.check();

    expect(state.status, UpdateCheckStatus.available);
    expect(state.release?.display, '0.2.0+132');
    expect(controller.shouldNotify, isTrue);

    await controller.markNotified();
    expect(prefs.updateLastNotified, '0.2.0+132');
    expect(controller.shouldNotify, isFalse);

    // 再检查一次：结果还是 available（版本确实更新），但不会再提示。
    await controller.check();
    expect(container.read(updateCheckProvider).status, UpdateCheckStatus.available);
    expect(controller.shouldNotify, isFalse);
  });

  test('已提示过的版本在 prefs 里对得上 → 启动不再提示', () async {
    final prefs = await prefsWith(<String, Object>{
      'cm_update_last_notified': '0.2.0+132',
    });
    when(() => service.fetchLatest()).thenAnswer((_) async => _release());
    final container = boot(prefs);
    final controller = container.read(updateCheckProvider.notifier);

    await controller.autoCheckIfDue();

    expect(controller.shouldNotify, isFalse);
  });

  test('失败：failed + 原因，且**不**写检查时间戳（下次启动还会重试）', () async {
    final prefs = await prefsWith();
    when(() => service.fetchLatest()).thenThrow(
      const UpdateException(UpdateFailureKind.network, '没网'),
    );
    final container = boot(prefs);

    final state = await container.read(updateCheckProvider.notifier).check();

    expect(state.status, UpdateCheckStatus.failed);
    expect(state.failure?.kind, UpdateFailureKind.network);
    expect(prefs.updateLastCheckMs, 0);
  });

  test('关闭：用户关掉自动检查 → disabled，自动检查不打网络但手动仍可用', () async {
    final prefs = await prefsWith(<String, Object>{
      'cm_update_check_enabled': false,
    });
    when(() => service.fetchLatest()).thenAnswer((_) async => _release());
    final container = boot(prefs);

    expect(
      container.read(updateCheckProvider).status,
      UpdateCheckStatus.disabled,
    );

    final autoState =
        await container.read(updateCheckProvider.notifier).autoCheckIfDue();
    expect(autoState.status, UpdateCheckStatus.disabled);
    verifyNever(() => service.fetchLatest());

    // 手动检查不受开关影响：用户明确点了按钮就要有结果。
    final manual =
        await container.read(updateCheckProvider.notifier).check();
    expect(manual.status, UpdateCheckStatus.available);
    verify(() => service.fetchLatest()).called(1);
  });

  test('关闭：清单地址为空（构建期关掉）→ disabled', () async {
    when(() => service.isConfigured).thenReturn(false);
    final prefs = await prefsWith();
    final container = boot(prefs);

    expect(
      container.read(updateCheckProvider).status,
      UpdateCheckStatus.disabled,
    );
    await container.read(updateCheckProvider.notifier).autoCheckIfDue();
    verifyNever(() => service.fetchLatest());
  });

  test('每天最多一次：24 小时内不再检查，超过才检查', () async {
    final now = DateTime(2026, 11, 2, 12);
    final prefs = await prefsWith(<String, Object>{
      'cm_update_last_check_ms':
          now.subtract(const Duration(hours: 23)).millisecondsSinceEpoch,
    });
    when(() => service.fetchLatest())
        .thenAnswer((_) async => _release(version: '0.1.0', buildNumber: 131));
    final container = boot(prefs);

    // 23 小时前刚检查过 → 不打网络、状态保持 idle。
    final skipped = await container
        .read(updateCheckProvider.notifier)
        .autoCheckIfDue(now: now);
    expect(skipped.status, UpdateCheckStatus.idle);
    verifyNever(() => service.fetchLatest());

    // 25 小时前检查过 → 该检查了，成功后时间戳推进到 now。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cm_update_last_check_ms':
          now.subtract(const Duration(hours: 25)).millisecondsSinceEpoch,
    });
    final freshPrefs = PrefsStore(await SharedPreferences.getInstance());
    final fresh = boot(freshPrefs);
    final checked =
        await fresh.read(updateCheckProvider.notifier).autoCheckIfDue(now: now);
    expect(checked.status, UpdateCheckStatus.upToDate);
    verify(() => service.fetchLatest()).called(1);
    expect(freshPrefs.updateLastCheckMs, now.millisecondsSinceEpoch);
  });

  test('检查中重复点击不并发打两个请求', () async {
    final prefs = await prefsWith();
    when(() => service.fetchLatest()).thenAnswer((_) async {
      // 让第一次检查挂在网络那一刻，再发起第二次。
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return _release();
    });
    final container = boot(prefs);
    final controller = container.read(updateCheckProvider.notifier);

    final first = controller.check();
    final second = controller.check();
    await Future.wait(<Future<UpdateCheckState>>[first, second]);

    verify(() => service.fetchLatest()).called(1);
  });

  test('「稍后」：收起 available 并记为已提示，不重复打扰', () async {
    final prefs = await prefsWith();
    when(() => service.fetchLatest()).thenAnswer((_) async => _release());
    final container = boot(prefs);
    final controller = container.read(updateCheckProvider.notifier);

    await controller.check();
    expect(controller.shouldNotify, isTrue);

    await controller.dismiss();
    expect(container.read(updateCheckProvider).status, UpdateCheckStatus.idle);
    expect(prefs.updateLastNotified, '0.2.0+132');
    expect(controller.shouldNotify, isFalse);
  });
}
