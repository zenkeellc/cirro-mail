// 下面三个假密钥库替换的是 `FlutterSecureStoragePlatform.instance`
// （`flutter_secure_storage` 的**传递**依赖：它自己的库只 re-export 了枚举、
// 没导出这个基类），用来造出「钥匙串坏了」「首读一直不返回」这些真会发生的
// 降级/加载窗口场景。与 `test/ai_settings_store_test.dart` 是同一套用法。
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/ai/ai_settings_store.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const fakeKey = 'sk-test-0123456789';

/// 读、写、删**全部抛异常**的密钥库 —— 对应 Linux 没装 libsecret / 钥匙串被锁 /
/// 插件没注册。用来复现「写失败却报 `hasApiKey=true`」的缺陷 ②。
class _BrokenKeychain extends FlutterSecureStoragePlatform {
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async =>
      throw PlatformException(code: '-34018', message: 'libsecret not available');

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async =>
      throw PlatformException(code: '-34018', message: 'libsecret not available');

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      false;

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async =>
      throw PlatformException(code: '-34018', message: 'libsecret not available');

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      const <String, String>{};

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {}
}

/// **读永远不返回**、写却正常的密钥库 —— 模拟冷启动时首读还在走平台通道的
/// 那个 `AsyncLoading` 窗口。用来复现缺陷 ①（`save` 在窗口里把 `hasApiKey`
/// 抹成 false）。
class _HangingReadKeychain extends FlutterSecureStoragePlatform {
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) =>
      // 永不完成：`load()` 会一直挂在钥匙串这一半上，「首读未落地」就是这样。
      Completer<String?>().future;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    data[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    data.remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      data.containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      Map<String, String>.of(data);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    data.clear();
  }
}

/// `load()` 可控失败的 store —— 复现缺陷 ③（读失败后 `save` 把 `AsyncError`
/// 复活成 `AsyncData`）。用 `StateError`（属于 `Error`）而不是普通异常：
/// Riverpod 的默认重试只针对非 `Error`，用 `StateError` 才能保证「读失败」
/// 是一次性的、不会挂上重试定时器。
class _FlakyLoadStore extends AiSettingsStore {
  _FlakyLoadStore({required super.prefs});

  bool failLoad = false;

  @override
  Future<AiSettings> load() => failLoad
      ? Future<AiSettings>.error(StateError('钥匙串读炸了（测试构造）'))
      : super.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> chain;

  setUp(() {
    chain = Map<String, String>.of(const <String, String>{});
    FlutterSecureStorage.setMockInitialValues(chain);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 建一个把 `prefsStoreProvider` 换成假 prefs 的容器。
  Future<ProviderContainer> container() async {
    final c = ProviderContainer.test(
      overrides: [
        prefsStoreProvider.overrideWithValue(
          PrefsStore(await SharedPreferences.getInstance()),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('读第一遍', () {
    test('没配过 → 默认设置、没有 Key、不可用', () async {
      final c = await container();
      final settings = await c.read(aiSettingsProvider.future);
      expect(settings, const AiSettings());
      expect(settings.hasApiKey, isFalse);
      expect(settings.isUsable, isFalse);
    });

    test('配过 → 两半合起来（这一读会去问钥匙串）', () async {
      final c = await container();
      // 假装用户之前填过。
      await c.read(aiSettingsStoreProvider).save(const AiSettings(
        apiFormat: AiApiFormat.anthropic,
        model: 'claude-x',
      ));
      await c.read(aiSettingsStoreProvider).setApiKey(fakeKey);

      // 重读（模拟重启）。
      c.invalidate(aiSettingsProvider);
      final settings = await c.read(aiSettingsProvider.future);
      expect(settings.apiFormat, AiApiFormat.anthropic);
      expect(settings.hasApiKey, isTrue);
      expect(settings.isUsable, isTrue);
    });
  });

  group('改设置', () {
    test('save 之后 state 立刻变，且不用重读', () async {
      final c = await container();
      await c.read(aiSettingsProvider.future);
      await c.read(aiSettingsProvider.notifier).save(const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: 'gpt-4o',
        preflightEnabled: false,
      ));
      final now = c.read(aiSettingsProvider).value!;
      expect(now.apiFormat, AiApiFormat.openai);
      expect(now.preflightEnabled, isFalse);
    });

    test('save 不会把「已经有 Key」这一点抹掉', () async {
      final c = await container();
      await c.read(aiSettingsStoreProvider).setApiKey(fakeKey);
      c.invalidate(aiSettingsProvider);
      await c.read(aiSettingsProvider.future);

      // 用户在设置页改了一下厂商 —— 界面上传进来的对象是不知道 Key 的。
      await c.read(aiSettingsProvider.notifier).save(const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: 'gpt-4o',
      ));
      expect(c.read(aiSettingsProvider).value!.hasApiKey, isTrue,
          reason: 'Key 不在这个对象里，save 不该把它当成「清掉了」');
    });

    test('setApiKey 之后 hasApiKey 立刻为 true，Key 真的进了钥匙串', () async {
      final c = await container();
      await c.read(aiSettingsProvider.future);
      await c.read(aiSettingsProvider.notifier).setApiKey(fakeKey);
      expect(c.read(aiSettingsProvider).value!.hasApiKey, isTrue);
      expect(chain.values.single, fakeKey);
    });

    test('setApiKey 空串 → hasApiKey 立刻为 false，钥匙串也清了', () async {
      final c = await container();
      await c.read(aiSettingsProvider.notifier).setApiKey(fakeKey);
      expect(c.read(aiSettingsProvider).value!.hasApiKey, isTrue);

      await c.read(aiSettingsProvider.notifier).setApiKey('  ');
      expect(c.read(aiSettingsProvider).value!.hasApiKey, isFalse);
      expect(chain, isEmpty);
    });

    test('改 Key 不会把设置一起清掉，反之亦然', () async {
      final c = await container();
      await c.read(aiSettingsProvider.notifier).save(const AiSettings(
        apiFormat: AiApiFormat.anthropic,
        model: 'claude-x',
      ));
      await c.read(aiSettingsProvider.notifier).setApiKey(fakeKey);

      c.invalidate(aiSettingsProvider);
      final rebooted = await c.read(aiSettingsProvider.future);
      expect(rebooted.apiFormat, AiApiFormat.anthropic);
      expect(rebooted.model, 'claude-x');
      expect(rebooted.hasApiKey, isTrue);
    });
  });

  group('状态缺陷（复核者实测复现的三条）', () {
    // 缺陷①：`save()` 在 AsyncLoading 窗口里把 `hasApiKey` 抹成 false（复核者
    // 实测）：
    // loading state = AsyncLoading<AiSettings>()
    // after save（load 还没回来）= AiSettings(openai, …, hasKey=false)
    // 根因是 `state.value ?? const AiSettings()` 的 false 兜底 —— 而在窗口里
    // 「有没有 Key」根本还是未知，不该被断言成 false。
    test('① 首读未落地时 save 不会把「有 Key」抹成「没 Key」', () async {
      // 读永远不返回的密钥库：造出冷启动首读未落地的窗口。
      // （setUp 里每次会重装默认 mock，所以这里不用手动还原。）
      FlutterSecureStoragePlatform.instance = _HangingReadKeychain();

      final c = await container();
      // 挂上监听让 provider 开始 build（首读卡住），但不 await。
      c.listen(aiSettingsProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      expect(c.read(aiSettingsProvider), isA<AsyncLoading<AiSettings>>());

      // 窗口里 save：修前 state 会变成 AsyncData(hasApiKey=false)。
      await c.read(aiSettingsProvider.notifier).save(const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: 'gpt-4o',
      ));

      final now = c.read(aiSettingsProvider);
      expect(now.value?.hasApiKey, isNot(false),
          reason: '首读没落地时「有没有 Key」还是未知，不能断言成 false');
      expect(now, isA<AsyncLoading<AiSettings>>(),
          reason: '首读还在飞，save 不该把它变成一份「已加载」的假结论');
      // 非敏感那半**必须照常落盘** —— 修法不能把 save 变成不干活。
      final persisted =
          AiSettingsCodec.decode(c.read(prefsStoreProvider).aiSettingsJson);
      expect(persisted.apiFormat, AiApiFormat.openai,
          reason: 'save 落盘这一半不受影响');
    });

    // 缺陷②：钥匙串写失败时 `setApiKey` 仍报 `hasApiKey=true`（复核者实测）：
    // setApiKey 之后 state.hasApiKey = true （但钥匙串里没有）
    // store.isKeychainDegraded = true ；store.readApiKey() = null
    // 重启后 hasApiKey = false（掉回 false）。
    test('② 钥匙串写不进去时，setApiKey 不会谎报 hasApiKey', () async {
      // 换成「读写都抛」的密钥库 —— 对应 Linux 没装 libsecret。
      // （setUp 里每次会重装默认 mock，所以这里不用手动还原。）
      FlutterSecureStoragePlatform.instance = _BrokenKeychain();

      final c = await container();
      await c.read(aiSettingsProvider.future); // 这一读同样失败 → 降级
      await c.read(aiSettingsProvider.notifier).setApiKey(fakeKey);

      final store = c.read(aiSettingsStoreProvider);
      expect(store.isKeychainDegraded, isTrue,
          reason: '写失败要让降级标志带出去（设置页 aiKeyDegraded 据此提示）');
      // 值确实没进去 → 不能报「有 Key」：报 true 会让设置页显示「已保存 Key
      // / 清除」按钮，用户重开后却掉回「还没填过 Key」。
      expect(c.read(aiSettingsProvider).value!.hasApiKey, isFalse,
          reason: '回读不到就是没存进去，不能拿入参冒充结果');
    });

    // 缺陷③：`save` 会把 `AsyncError` 复活成 `AsyncData`（复核者实测）：
    // B) after blowup: hasError=true value=AiSettings(…, hasKey=true)
    // C) after save:  AsyncData(AiSettings(…, hasKey=true))   ← 错误被吞成成功。
    test('③ 首读失败后 save 不会把 AsyncError 复活成成功态', () async {
      final c = ProviderContainer.test(
        overrides: [
          prefsStoreProvider.overrideWithValue(
            PrefsStore(await SharedPreferences.getInstance()),
          ),
          aiSettingsStoreProvider.overrideWith(
            (ref) => _FlakyLoadStore(prefs: ref.watch(prefsStoreProvider)),
          ),
        ],
      );
      addTearDown(c.dispose);

      final store = c.read(aiSettingsStoreProvider) as _FlakyLoadStore;
      store.failLoad = true;

      // 首读炸掉：state 进 AsyncError，`.value` 是 null。
      await expectLater(
        c.read(aiSettingsProvider.future),
        throwsA(isA<StateError>()),
      );
      expect(c.read(aiSettingsProvider).hasError, isTrue);

      // 错误状态下 save —— 修前这里会变成 AsyncData（错误被静默吞掉）。
      await c.read(aiSettingsProvider.notifier).save(const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: 'gpt-4o',
      ));
      expect(c.read(aiSettingsProvider).hasError, isTrue,
          reason: '非敏感那半确实落盘了，但「可信的设置」这一读仍失败着，'
              '不能拿旧值冒充一次成功的加载');
    });
  });

  group('aiServiceProvider 接的是同一套东西', () {
    test('设置页存下的 Key，服务层立刻能用（不用重启）', () async {
      final c = await container();
      await c.read(aiSettingsProvider.notifier).save(const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: 'gpt-4o-mini',
      ));
      await c.read(aiSettingsProvider.notifier).setApiKey(fakeKey);

      // 服务层自己读一次 —— 它读的就是同一份落盘。
      final settings = await c.read(aiSettingsStoreProvider).load();
      expect(settings.isUsable, isTrue);
    });

    test('引用同一个 usage 计数器（额度是全局的，不是每个界面一份）', () async {
      final c = await container();
      final a = c.read(aiUsageProvider);
      final b = c.read(aiUsageProvider);
      expect(identical(a, b), isTrue);
      await a.record();
      expect(c.read(aiServiceProvider).usedToday, 1);
    });
  });
}
