// `secure_storage.dart` 的用例。
//
// 测试进程本身**没有** App 的 entitlement，真去写 data protection 钥匙串一定抛
// `-34018`，所以这里全部注入假 probe（只测选哪一套），另外用插件自带的
// `setMockInitialValues` 覆盖「解析出来的实例真的能用」。
//
// 下面这个 import 是为了替换 `FlutterSecureStoragePlatform.instance`（造
// 「钥匙串彻底坏了」的场景）：平台接口是 `flutter_secure_storage` 的**传递**
// 依赖，它的库只 re-export 了枚举、没导出这个基类，所以只能直接 import。
// 与 `test/ai_settings_store_test.dart` 是同一套用法。
// ignore_for_file: depend_on_referenced_packages
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/secure_storage.dart';
import 'package:mail_app/core/storage/token_store.dart';

/// 读写删**全部抛 `-34018`** 的密钥库 —— 对应「这条构建没有
/// `com.apple.application-identifier`」的真实情形。
class _ThrowingKeychain extends FlutterSecureStoragePlatform {
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async =>
      throw PlatformException(code: '-34018', message: 'errSecMissingEntitlement');

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async =>
      throw PlatformException(code: '-34018', message: 'errSecMissingEntitlement');

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async =>
      throw PlatformException(code: '-34018', message: 'errSecMissingEntitlement');

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      false;

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      const <String, String>{};

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSecureStorageCache();
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  group('pickMacSecureStorage', () {
    test('探测成功 → 用 data protection 钥匙串', () async {
      var probed = 0;
      final picked = await pickMacSecureStorage(
        dataProtection: macDataProtectionStorage,
        legacy: macLegacyStorage,
        probe: (storage) async {
          probed++;
          expect(identical(storage, macDataProtectionStorage), isTrue,
              reason: '探测的必须是 data protection 实例');
        },
      );
      expect(probed, 1);
      expect(identical(picked, macDataProtectionStorage), isTrue);
    });

    test('探测抛 -34018（没有 application-identifier 的构建）→ 退回老钥匙串',
        () async {
      final picked = await pickMacSecureStorage(
        dataProtection: macDataProtectionStorage,
        legacy: macLegacyStorage,
        probe: (_) async => throw PlatformException(
          code: '-34018',
          message: 'errSecMissingEntitlement',
        ),
      );
      expect(identical(picked, macLegacyStorage), isTrue);
    });

    test('探测抛别的错（钥匙串临时被锁）→ 也退回老钥匙串，不抛给调用方', () async {
      final picked = await pickMacSecureStorage(
        dataProtection: macDataProtectionStorage,
        legacy: macLegacyStorage,
        probe: (_) async => throw PlatformException(
          code: '-25308',
          message: 'errSecInteractionNotAllowed',
        ),
      );
      expect(identical(picked, macLegacyStorage), isTrue,
          reason: '选钥匙串失败不该拦启动，退回能从前的行为');
    });

    test('插件没注册（MissingPluginException）→ 同样退回，不让启动炸掉', () async {
      final picked = await pickMacSecureStorage(
        dataProtection: macDataProtectionStorage,
        legacy: macLegacyStorage,
        probe: (_) async => throw MissingPluginException(),
      );
      expect(identical(picked, macLegacyStorage), isTrue,
          reason: 'MissingPluginException 不是 PlatformException，也要接住');
    });
  });

  group('两个 macOS 实例的配置', () {
    test('data protection 实例开着 usesDataProtectionKeychain', () {
      expect(
        (macDataProtectionStorage.mOptions as MacOsOptions)
            .usesDataProtectionKeychain,
        isTrue,
      );
    });

    test('老钥匙串实例显式关掉它（没有 entitlement 的构建只能走这条）', () {
      expect(
        (macLegacyStorage.mOptions as MacOsOptions).usesDataProtectionKeychain,
        isFalse,
      );
    });
  });

  group('resolveSecureStorage', () {
    test('同一个进程只解析一次（缓存的是实例，不是 Future）', () async {
      final first = await resolveSecureStorage();
      final second = await resolveSecureStorage();
      expect(identical(first, second), isTrue);
    });

    test('macOS 上探测成功 → 选中 data protection 实例；其它平台用插件默认值',
        () async {
      final storage = await resolveSecureStorage();
      if (Platform.isMacOS) {
        expect(identical(storage, macDataProtectionStorage), isTrue);
      } else {
        expect(identical(storage, macDataProtectionStorage), isFalse,
            reason: '非 macOS 平台不存在这套区分，应是插件默认实例');
        expect(
          (storage.mOptions as MacOsOptions).usesDataProtectionKeychain,
          isTrue,
          reason: '其它平台不该改动 macOS 选项（macOS 上仍走插件默认）',
        );
      }
    });

    test('探测项写完就删，不会在钥匙串里留下垃圾', () async {
      final data = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(data);
      await resolveSecureStorage();
      expect(data.containsKey(probeKey), isFalse);
    });
  });

  group('接入 TokenStore', () {
    test('构造不碰平台通道；真去读才解析（探测失败也不抛，只降级）', () async {
      FlutterSecureStoragePlatform.instance = _ThrowingKeychain();
      final store = TokenStore();
      expect(store.isDegraded, isFalse, reason: '构造时不该有任何平台调用');
      expect(store.readCached('p1'), isNull);
      expect(await store.read('p1'), isNull);
      expect(store.isDegraded, isTrue, reason: '钥匙串真的坏了，要能告诉 UI');
    });

    test('解析出来的存储真能写读（mock 钥匙串里能查到那条 token）', () async {
      final data = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(data);
      final store = TokenStore();
      await store.write('p1', 'tok-1');
      expect(store.isDegraded, isFalse);
      expect(data[TokenStore.keyFor('p1')], 'tok-1');
      expect(await store.readFresh('p1'), 'tok-1');
    });
  });
}
