import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/config/app_defaults.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/settings/roam_config_host.dart';
import 'package:mail_app/core/storage/change_signal.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/features/ai/ai_settings_store.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('applyItems 写回 prefs 之后，读 prefs 的同步 provider 自己刷新', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final signal = SettingsChangeSignal();
    final prefs =
        PrefsStore(await SharedPreferences.getInstance(), signal: signal);
    final tokens = TokenStore(signal: signal);
    final container = ProviderContainer.test(overrides: [
      bootstrapProvider.overrideWithValue(
        BootstrapData(db: db, tokens: tokens, prefs: prefs),
      ),
    ]);
    // 先读一次，让「版本号 → 这几个 provider」的依赖边真的建起来。
    expect(container.read(themeModeProvider), ThemeMode.system);
    expect(container.read(localeProvider), isNull);
    expect(container.read(pollIntervalProvider), AppDefaults.pollDefault);
    expect(container.read(prefetchFullProvider), isTrue);
    final host = RoamConfigHostImpl(
      prefs: prefs,
      tokens: tokens,
      db: db,
      aiKeys: AiApiKeyStore(),
    );
    await host.applyItems(const <RoamConfigItem>[
      RoamConfigItem(
        key: 'app.appearance',
        group: 'appearance',
        secret: false,
        data: <String, Object?>{'themeMode': 'dark', 'locale': 'en'},
      ),
      RoamConfigItem(
        key: 'app.reading',
        group: 'reading',
        secret: false,
        data: <String, Object?>{'pollSeconds': 120, 'prefetchFull': false},
      ),
    ]);
    await pumpEventQueue();
    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(container.read(localeProvider), const Locale('en'));
    expect(container.read(pollIntervalProvider), const Duration(seconds: 120));
    expect(container.read(prefetchFullProvider), isFalse);
  });

  test('writeSecret 写回 AI Key 之后，aiSettingsProvider 也自己刷新', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final signal = SettingsChangeSignal();
    final prefs =
        PrefsStore(await SharedPreferences.getInstance(), signal: signal);
    final tokens = TokenStore(signal: signal);
    final container = ProviderContainer.test(overrides: [
      bootstrapProvider.overrideWithValue(
        BootstrapData(db: db, tokens: tokens, prefs: prefs),
      ),
    ]);
    // 首读：钥匙串里没有 Key。
    expect((await container.read(aiSettingsProvider.future)).hasApiKey, isFalse);
    // 漫游恢复 Key：host 用的是**另一个** `AiApiKeyStore` 实例，provider 层
    // 只能靠重读钥匙串看见它 —— 这正是「不做缓存」的理由（缓存会一直说没有）。
    final host = RoamConfigHostImpl(prefs: prefs, tokens: tokens, db: db);
    await host.writeSecret('secret.ai_key', 'sk-roamed');
    await pumpEventQueue();
    expect(
      (await container.read(aiSettingsProvider.future)).hasApiKey,
      isTrue,
      reason: '统一的变更流响过之后，读钥匙串的那半也会重读',
    );
  });
}
