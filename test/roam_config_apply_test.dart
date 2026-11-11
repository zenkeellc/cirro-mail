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
    expect(r.prefs.notifyEnabled, isFalse);
    expect(r.prefs.notifyBanner, isFalse);
    expect(r.prefs.quietTrackingPixels, isFalse);
    expect(r.prefs.externalAllowedHosts, <String>['*.example.com']);
    expect((jsonDecode(r.prefs.aiSettingsJson!) as Map)['model'], 'm-1');
    expect(r.prefs.aiSourceCode, 'byok');
    // 回声：把导出的原样写回去，快照不变（消费方抑制回传，核心本身也必须幂等）。
    final once = snapshot(await r.host.exportItems());
    await r.host.applyItems(await r.host.exportItems());
    expect(snapshot(await r.host.exportItems()), once);
  });

  test('实例按 instanceKey 去重：新建 → 再写只改展示字段、不碰登录态', () async {
    final r = await roamRig();
    const apiBase = 'https://mail.example.com/api';
    const key = 'instance:https://mail.example.com|a@b.com';
    await r.host.applyItems(const <RoamConfigItem>[
      RoamConfigItem(
        key: key,
        group: 'instances',
        secret: false,
        data: <String, Object?>{
          'baseUrl': apiBase,
          'name': '工作',
          'email': 'a@b.com',
          'colorIndex': 2,
          'sort': 0,
        },
      ),
    ]);
    var profiles = await r.db.profileDao.allProfiles();
    expect(profiles.length, 1);
    expect(profiles.single.needsLogin, isTrue, reason: '没有 token 的实例恢复后要先登录');
    expect(profiles.single.colorIndex, 2);
    final id = profiles.single.id;
    await r.db.profileDao.updateProfileFields(
      id,
      userId: 7,
      userName: 'Alice',
      needsLogin: false,
    );
    await r.host.applyItems(const <RoamConfigItem>[
      RoamConfigItem(
        key: key,
        group: 'instances',
        secret: false,
        data: <String, Object?>{
          // 带尾部斜杠的写法：归一化之后与 key 自洽，但**不能**把这个原始串
          // 写进本机 —— `baseUrl` 是登录与探测的产物，existing 分支不碰它。
          'baseUrl': 'https://mail.example.com/api/',
          'name': '新备注',
          'email': 'a@b.com',
          'colorIndex': 5,
          'sort': 0,
        },
      ),
    ]);
    profiles = await r.db.profileDao.allProfiles();
    expect(profiles.length, 1, reason: '同一个 instanceKey 不许建出第二台');
    expect(profiles.single.id, id, reason: '本机 id 不动（token 的 key 是它）');
    expect(profiles.single.name, '新备注');
    expect(profiles.single.colorIndex, 5);
    expect(profiles.single.baseUrl, apiBase,
        reason: 'existing 分支不改 baseUrl（登录/探测的产物，不是展示字段）');
    expect(profiles.single.userId, 7);
    expect(profiles.single.userName, 'Alice');
    expect(profiles.single.needsLogin, isFalse);
  });

  test('常用语整组都解不出来时保留本地那组（不静默清空）', () async {
    final r = await roamRig(seed: <String, Object>{
      'cm_phrases': jsonEncode(<String, dynamic>{
        'a@b.com': <Map<String, String>>[
          <String, String>{'id': 'p1', 'name': '问候', 'text': '你好'},
        ],
      }),
    });
    await r.host.applyItems(const <RoamConfigItem>[
      RoamConfigItem(
        key: 'phrases:a@b.com',
        group: 'compose',
        secret: false,
        data: <String, Object?>{
          // 全是解不出来的条目（不是 Map / 缺字段）：对方版本换了格式或数据坏掉。
          'items': <Object?>[
            'junk',
            <String, Object?>{'id': 'x'},
          ],
        },
      ),
    ]);
    expect(
      r.prefs.phrasesFor('a@b.com').single.text,
      '你好',
      reason: '一条都解不出来 ≠ 用户删光了：本地那组必须原样留着',
    );
  });

  test('常用语空列表照样清空本机那一组（对方删光了要跟）', () async {
    final r = await roamRig(seed: <String, Object>{
      'cm_phrases': jsonEncode(<String, dynamic>{
        'a@b.com': <Map<String, String>>[
          <String, String>{'id': 'p1', 'name': '问候', 'text': '你好'},
        ],
      }),
    });
    expect(r.prefs.phrasesFor('a@b.com'), hasLength(1));

    await r.host.applyItems(const <RoamConfigItem>[
      RoamConfigItem(
        key: 'phrases:a@b.com',
        group: 'compose',
        secret: false,
        data: <String, Object?>{'items': <Object?>[]},
      ),
    ]);

    // 「空列表」是对方那台**删光了**，与「一条都解不出来」（上一条用例）是
    // 两件事：前者要跟着删，后者要保住本地。把这两条混成一条（比如「空就
    // 一律 return」）会让跨设备删除永远不生效 —— 用户删了常用语，另一台
    // 永远还在。
    expect(r.prefs.phrasesFor('a@b.com'), isEmpty,
        reason: '空列表 = 删除传播，必须清掉本机这一组');
  });

  test('常用语坏条目跳过、好的那条照写（不因第一条坏就整组放弃）', () async {
    final r = await roamRig();

    await r.host.applyItems(const <RoamConfigItem>[
      RoamConfigItem(
        key: 'phrases:a@b.com',
        group: 'compose',
        secret: false,
        data: <String, Object?>{
          'items': <Object?>[
            // 第一条就解不出来（不是 Map）：只该跳过它，不该连累后面那条。
            'junk',
            <String, Object?>{'id': 'p2', 'name': '约时间', 'text': '周四下午？'},
          ],
        },
      ),
    ]);

    final saved = r.prefs.phrasesFor('a@b.com');
    expect(saved, hasLength(1), reason: '坏条目跳过，好的那条必须留下');
    expect(saved.single.id, 'p2');
    expect(saved.single.text, '周四下午？');
  });

  test('key 与 data 对不上的实例条目不写（脏数据不制造假实例）', () async {
    final r = await roamRig();
    await r.host.applyItems(const <RoamConfigItem>[
      RoamConfigItem(
        key: 'instance:https://a.example.com|x@y.com',
        group: 'instances',
        secret: false,
        data: <String, Object?>{
          'baseUrl': 'https://b.example.com/api',
          'email': 'x@y.com',
        },
      ),
    ]);
    expect(await r.db.profileDao.allProfiles(), isEmpty);
  });
}
