import 'dart:convert';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/roam_rig.dart';

List<Map<String, Object?>> snapshot(List<RoamConfigItem> items) =>
    <Map<String, Object?>>[for (final item in items) item.toJson()];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('写回 app 级条目；未知 key / 敏感项忽略；写两遍结果一致', () async {
    final r = await roamRig();
    await r.host.applyItems(const <RoamConfigItem>[
      RoamConfigItem(
        key: 'app.appearance',
        group: 'appearance',
        secret: false,
        data: <String, Object?>{'themeMode': 'dark', 'themePackId': null, 'locale': 'en'},
      ),
      RoamConfigItem(
        key: 'app.compose',
        group: 'compose',
        secret: false,
        data: <String, Object?>{'sendDelaySeconds': 5},
      ),
      RoamConfigItem(
        key: 'sig:a@b.com',
        group: 'compose',
        secret: false,
        data: <String, Object?>{'text': '— A'},
      ),
      RoamConfigItem(
        key: 'phrases:a@b.com',
        group: 'compose',
        secret: false,
        data: <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'id': 'p1', 'name': '问候', 'text': '你好'},
          ],
        },
      ),
      RoamConfigItem(
        key: 'app.reading',
        group: 'reading',
        secret: false,
        data: <String, Object?>{
          'pollSeconds': 120,
          'prefetchFull': false,
          'notifyEnabled': false,
          'notifyBanner': false,
          'quietTrackingPixels': false,
          'externalAllowedHosts': <Object?>['*.example.com'],
        },
      ),
      RoamConfigItem(
        key: 'app.ai',
        group: 'ai',
        secret: false,
        data: <String, Object?>{
          'settings': <String, Object?>{'apiFormat': 'openai', 'model': 'm-1'},
          'source': 'byok',
        },
      ),
      // 核心不认识的：扩展自己的条目 + 未来版本的条目 + 混进来的敏感项
      RoamConfigItem(
        key: 'app.dnd',
        group: 'pro',
        secret: false,
        data: <String, Object?>{'rules': <Object?>[]},
      ),
      RoamConfigItem(
        key: 'app.schema',
        group: 'meta',
        secret: false,
        data: <String, Object?>{'v': 1},
      ),
      RoamConfigItem(
        key: 'secret.instance:https://mail.example.com|a@b.com',
        group: 'secrets',
        secret: true,
        data: <String, Object?>{'value': 'must-not-be-written'},
      ),
    ]);
    expect(r.prefs.themeMode, 'dark');
    expect(r.prefs.localeCode, 'en');
    expect(r.prefs.sendDelay, const Duration(seconds: 5));
    expect(r.prefs.signatureFor('a@b.com'), '— A');
    expect(r.prefs.phrasesFor('a@b.com').single.text, '你好');
    expect(r.prefs.pollInterval, const Duration(seconds: 120));
    expect(r.prefs.prefetchFull, isFalse);
    expect(r.prefs.quietTrackingPixels, isFalse);
    expect(r.prefs.externalAllowedHosts, <String>['*.example.com']);
    expect((jsonDecode(r.prefs.aiSettingsJson!) as Map)['model'], 'm-1');
    expect(r.prefs.aiSourceCode, 'byok');
    // 回声：把导出的原样写回去，快照不变（消费方抑制回传，核心本身也必须幂等）。
    final once = snapshot(await r.host.exportItems());
    await r.host.applyItems(await r.host.exportItems());
    expect(snapshot(await r.host.exportItems()), once);
  });
}
