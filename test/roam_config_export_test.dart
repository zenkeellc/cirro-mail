import 'dart:convert';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
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

/// 后面几个任务（导出 / 写回 / 敏感项 / 删除）共用的测试夹具：一份内存库、
/// 一份注入同一 signal 的 prefs / token、一个 host。
typedef Rig = ({
  AppDatabase db,
  PrefsStore prefs,
  TokenStore tokens,
  RoamConfigHostImpl host,
});

Future<Rig> rig({Map<String, Object> seed = const <String, Object>{}}) async {
  SharedPreferences.setMockInitialValues(seed);
  FlutterSecureStorage.setMockInitialValues(<String, String>{});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final signal = SettingsChangeSignal();
  final prefs = PrefsStore(await SharedPreferences.getInstance(), signal: signal);
  final tokens = TokenStore(signal: signal);
  return (
    db: db,
    prefs: prefs,
    tokens: tokens,
    host: RoamConfigHostImpl(
      prefs: prefs,
      tokens: tokens,
      db: db,
      aiKeys: AiApiKeyStore(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('导出 app 级条目', () async {
    final r = await rig(seed: <String, Object>{
      'cm_theme_mode': 'dark',
      'cm_locale': 'en',
      'cm_send_delay_seconds': 3,
      'cm_signatures': jsonEncode(<String, String>{'a@b.com': '— A'}),
      'cm_phrases': jsonEncode(<String, dynamic>{
        'a@b.com': <Map<String, String>>[
          <String, String>{'id': 'p1', 'name': '问候', 'text': '你好'},
        ],
      }),
      'cm_poll_seconds': 120,
      'cm_prefetch_full': false,
      'cm_quiet_tracking_pixels': false,
      'cm_external_allowed_hosts': <String>['*.example.com'],
      'cm_ai_settings': jsonEncode(<String, String>{
        'apiFormat': 'openai',
        'model': 'm-1',
      }),
      'cm_ai_source': 'byok',
    });
    final items = await r.host.exportItems();
    final byKey = <String, RoamConfigItem>{for (final item in items) item.key: item};
    expect(
      byKey.keys,
      containsAll(<String>[
        'app.schema',
        'app.appearance',
        'app.compose',
        'sig:a@b.com',
        'phrases:a@b.com',
        'app.reading',
        'app.ai',
      ]),
    );
    expect(byKey['app.schema']!.data, <String, Object?>{'v': 1});
    expect(byKey['app.appearance']!.data, <String, Object?>{
      'themeMode': 'dark',
      'themePackId': null,
      'locale': 'en',
    });
    expect(byKey['app.compose']!.data['sendDelaySeconds'], 3);
    expect(byKey['sig:a@b.com']!.data['text'], '— A');
    expect((byKey['phrases:a@b.com']!.data['items']! as List).length, 1);
    final reading = byKey['app.reading']!.data;
    expect(reading['pollSeconds'], 120);
    expect(reading['prefetchFull'], isFalse);
    expect(reading['quietTrackingPixels'], isFalse);
    expect(reading['externalAllowedHosts'], <String>['*.example.com']);
    expect(
      (byKey['app.ai']!.data['settings']! as Map)['model'],
      'm-1',
      reason: '原样 JSON，不重新编码字段',
    );
    expect(byKey['app.ai']!.data['source'], 'byok');
    expect(items.any((item) => item.secret), isFalse, reason: '默认不导敏感项');
  });
}
