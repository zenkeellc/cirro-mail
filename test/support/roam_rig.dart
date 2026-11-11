import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/settings/roam_config_host.dart';
import 'package:mail_app/core/storage/change_signal.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/features/ai/ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 配置漫游几个测试（导出 / 写回 / 敏感项 / 删除）共用的夹具：一份内存 drift
/// 库、一份注入同一 signal 的 prefs / token、一个 host。
///
/// prefs 与 token 共用同一个 [SettingsChangeSignal]，是因为生产里
/// `bootstrap()` 就是这么接的：`changes` 只有一条流，导出与写回才看得到
/// 「token 变了」这件事。
typedef RoamRig = ({
  AppDatabase db,
  PrefsStore prefs,
  TokenStore tokens,
  RoamConfigHostImpl host,
});

/// [seed] 直接灌进 SharedPreferences（键名用 `cm_` 那套）。
Future<RoamRig> roamRig({
  Map<String, Object> seed = const <String, Object>{},
}) async {
  SharedPreferences.setMockInitialValues(seed);
  FlutterSecureStorage.setMockInitialValues(<String, String>{});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  // 每个用例自己一份内存库（drift 的 `NativeDatabase.memory()` 不共享），
  // 用完就关，免得测试进程里攒一堆打开着的库。
  addTearDown(db.close);
  final signal = SettingsChangeSignal();
  final prefs =
      PrefsStore(await SharedPreferences.getInstance(), signal: signal);
  // **显式注入假存储**，不走 `resolveSecureStorage()`：那条路会去探平台通道
  // （macOS 上真写一次 data protection 钥匙串），测试里既没必要也依赖环境。
  // `setMockInitialValues` 已经把平台实现换成内存版，这里注入的实例照样落在
  // 内存里，而且 prefs / token / AI Key 共用同一份。
  const fakeSecureStorage = FlutterSecureStorage();
  final tokens = TokenStore(storage: fakeSecureStorage, signal: signal);
  return (
    db: db,
    prefs: prefs,
    tokens: tokens,
    host: RoamConfigHostImpl(
      prefs: prefs,
      tokens: tokens,
      db: db,
      aiKeys: AiApiKeyStore(storage: fakeSecureStorage),
    ),
  );
}
