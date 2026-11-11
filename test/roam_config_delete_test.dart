import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/profile.dart';

import 'support/roam_rig.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('deleteItems：sig / phrases 删除生效；其它 key 一律忽略且不抛', () async {
    final r = await roamRig(seed: <String, Object>{
      'cm_signatures': jsonEncode(<String, String>{
        'a@b.com': '— A',
        'b@b.com': '— B',
      }),
      'cm_phrases': jsonEncode(<String, dynamic>{
        'a@b.com': <Map<String, String>>[
          <String, String>{'id': 'p1', 'name': '问候', 'text': '你好'},
        ],
      }),
    });
    await r.db.profileDao.upsertProfile(const Profile(
      id: 'p-1',
      baseUrl: 'https://mail.example.com/api',
      email: 'a@b.com',
    ));
    var changes = 0;
    final sub = r.prefs.changes.listen((_) => changes++);

    await r.host.deleteItems(<String>[
      'sig:a@b.com',
      'phrases:a@b.com',
      // 下面这些必须被忽略：实例、登录态、app.*、未知 key
      'instance:https://mail.example.com|a@b.com',
      'secret.instance:https://mail.example.com|a@b.com',
      'secret.ai_key',
      'app.reading',
      'app.future',
    ]);
    await pumpEventQueue();

    expect(r.prefs.signatureFor('a@b.com'), isEmpty, reason: 'sig 删除生效');
    expect(r.prefs.signatureFor('b@b.com'), '— B', reason: '别的邮箱签名不动');
    expect(r.prefs.phrasesFor('a@b.com'), isEmpty, reason: 'phrases 清空生效');
    expect((await r.db.profileDao.allProfiles()).length, 1,
        reason: '删条目不删实例');
    expect(await r.tokens.read('p-1'), isNull, reason: '删条目不删登录态');
    expect(r.prefs.notifyEnabled, isTrue, reason: 'app.* 条目一律忽略');
    expect(changes, greaterThanOrEqualTo(2),
        reason: '走既有 setter，变更信号照常打');

    // 空邮箱 / 空串都不抛。
    await r.host.deleteItems(<String>['sig:', 'phrases:', '']);
    await pumpEventQueue();
    await sub.cancel();
  });
}
