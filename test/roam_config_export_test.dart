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
import 'package:mail_app/data/models/profile.dart';
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
    // **精确键集**（不是 containsAll）：多导出一条不该漫游的 key 就是越界。
    // 典型是扩展自己的 `app.dnd` / `app.proxy` —— 核心不解释它们，也就不该
    // 替它们保管，更不该在别的设备上把它们当成核心设置写回去。
    expect(byKey.keys.toSet(), <String>{
      'app.schema',
      'app.appearance',
      'app.compose',
      'sig:a@b.com',
      'phrases:a@b.com',
      'app.reading',
      'app.ai',
    });
    expect(
      <String, String>{for (final item in items) item.key: item.group},
      <String, String>{
        'app.schema': 'meta',
        'app.appearance': 'appearance',
        'app.compose': 'compose',
        'sig:a@b.com': 'compose',
        'phrases:a@b.com': 'compose',
        'app.reading': 'reading',
        'app.ai': 'ai',
      },
      reason: 'group 是消费方分组的唯一依据，每条都要落在约定的组里',
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

  test('实例按 instanceKey 出条目；敏感项只在 includeSecrets 时出现', () async {
    final r = await rig();
    await r.db.profileDao.upsertProfile(const Profile(
      id: 'p-1',
      baseUrl: 'https://mail.example.com/api',
      name: '工作',
      email: 'A@B.com',
      colorIndex: 2,
      sort: 4,
      needsLogin: true,
    ));
    await r.tokens.write('p-1', 'tok-1');
    await r.host.writeSecret('secret.ai_key', 'sk-1');
    final plain = await r.host.exportItems();
    final instance = plain.firstWhere(
      (item) => item.key == 'instance:https://mail.example.com|a@b.com',
    );
    expect(instance.group, 'instances');
    expect(instance.data, <String, Object?>{
      'baseUrl': 'https://mail.example.com/api',
      'name': '工作',
      'email': 'A@B.com',
      'colorIndex': 2,
      'sort': 4,
    });
    expect(plain.any((item) => item.secret), isFalse);
    final withSecrets = await r.host.exportItems(includeSecrets: true);
    final tokenItem = withSecrets.firstWhere(
      (item) =>
          item.key == 'secret.instance:https://mail.example.com|a@b.com',
    );
    expect(tokenItem.secret, isTrue);
    expect(tokenItem.group, 'secrets');
    expect(tokenItem.data['value'], 'tok-1');
    expect(
      withSecrets.firstWhere((item) => item.key == 'secret.ai_key').data['value'],
      'sk-1',
    );
    await r.db.profileDao.upsertProfile(const Profile(
      id: 'p-2',
      baseUrl: 'https://other.example.com/api',
    ));
    expect(
      (await r.host.exportItems())
          .any((item) => item.key.startsWith('instance:https://other')),
      isFalse,
      reason: '没有登录邮箱的实例不漫游',
    );
  });

  test('坏 JSON 的 AI 设置降级成空对象；没配来源时 source 为 null', () async {
    final r = await rig(seed: <String, Object>{'cm_ai_settings': '{"apiFormat":'});
    final byKey = <String, RoamConfigItem>{
      for (final item in await r.host.exportItems()) item.key: item,
    };
    expect(
      byKey['app.ai']!.data['settings'],
      <String, Object?>{},
      reason: '坏 JSON 当没配过（与 AiSettingsCodec.decode 同口径），不是半截字符串',
    );
    expect(byKey['app.ai']!.data['source'], isNull);
  });

  test('includeSecrets 只带出真有 token 的实例', () async {
    final r = await rig();
    await r.db.profileDao.upsertProfile(const Profile(
      id: 'p-1',
      baseUrl: 'https://mail.example.com/api',
      email: 'a@b.com',
      sort: 0,
    ));
    await r.db.profileDao.upsertProfile(const Profile(
      id: 'p-2',
      baseUrl: 'https://other.example.com/api',
      email: 'b@c.com',
      sort: 1,
    ));
    await r.tokens.write('p-1', 'tok-1');
    final withSecrets = await r.host.exportItems(includeSecrets: true);
    expect(
      <String>[
        for (final item in withSecrets)
          if (item.group == 'secrets') item.key,
      ],
      <String>['secret.instance:https://mail.example.com|a@b.com'],
      reason: '没有 token 的实例不出 secret 条目 —— 空值写回去会把对方的登录态删掉',
    );
    expect(
      <String>[
        for (final item in withSecrets)
          if (item.group == 'instances') item.key,
      ],
      <String>[
        'instance:https://mail.example.com|a@b.com',
        'instance:https://other.example.com|b@c.com',
      ],
      reason: '没有 token 的实例照样导出（别的设备靠它建实例），只是不带登录态',
    );
    expect(
      withSecrets.where((item) => item.group == 'secrets').every(
            (item) => item.secret,
          ),
      isTrue,
    );
  });

  test('同 instanceKey 的多条本机 profile 只导出一条实例（先到先得）', () async {
    final r = await rig();
    // 同 host 同邮箱、挂载 path 不同 → instanceKey 相同。
    await r.db.profileDao.upsertProfile(const Profile(
      id: 'p-1',
      baseUrl: 'https://mail.example.com/api',
      name: '工作',
      email: 'a@b.com',
      colorIndex: 2,
      sort: 0,
    ));
    await r.db.profileDao.upsertProfile(const Profile(
      id: 'p-2',
      baseUrl: 'https://mail.example.com/mail/api',
      name: '工作（重复登记）',
      email: 'a@b.com',
      colorIndex: 5,
      sort: 1,
    ));
    await r.tokens.write('p-1', 'tok-1');
    await r.tokens.write('p-2', 'tok-2');
    final withSecrets = await r.host.exportItems(includeSecrets: true);
    const key = 'instance:https://mail.example.com|a@b.com';
    final instances =
        withSecrets.where((item) => item.group == 'instances').toList();
    expect(instances.length, 1, reason: '按 key 建 map 的消费方会静默丢掉一条');
    expect(instances.single.key, key);
    expect(instances.single.data['name'], '工作', reason: '先到先得（按 sort 的顺序）');
    expect(instances.single.data['colorIndex'], 2);
    final tokens = withSecrets
        .where((item) => item.group == 'secrets')
        .toList(growable: false);
    expect(tokens.length, 1, reason: '一台实例至多一份登录态');
    expect(tokens.single.key, 'secret.instance:https://mail.example.com|a@b.com');
    expect(tokens.single.data['value'], 'tok-1');
  });

  test('先去的那条没有 token 时，token 仍从同 key 的另一条带上', () async {
    final r = await rig();
    await r.db.profileDao.upsertProfile(const Profile(
      id: 'p-1',
      baseUrl: 'https://mail.example.com/api',
      email: 'a@b.com',
      needsLogin: true,
      sort: 0,
    ));
    await r.db.profileDao.upsertProfile(const Profile(
      id: 'p-2',
      baseUrl: 'https://mail.example.com/mail/api',
      email: 'a@b.com',
      sort: 1,
    ));
    await r.tokens.write('p-2', 'tok-2');
    final tokens = (await r.host.exportItems(includeSecrets: true))
        .where((item) => item.group == 'secrets')
        .toList(growable: false);
    expect(tokens.length, 1);
    expect(
      tokens.single.data['value'],
      'tok-2',
      reason: '同实例还有一条留着 token，别的设备就不该被要求重登',
    );
  });
}
