import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/profile.dart';

import 'support/roam_rig.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('实例 token 与 AI Key 走钥匙串；空串 = 删；没授权实例不写', () async {
    final r = await roamRig();
    await r.db.profileDao.upsertProfile(const Profile(
      id: 'p-1',
      baseUrl: 'https://mail.example.com/api',
      email: 'a@b.com',
    ));
    const instanceSecret = 'secret.instance:https://mail.example.com|a@b.com';
    await r.host.writeSecret(instanceSecret, 'tok-9');
    expect(await r.host.readSecret(instanceSecret), 'tok-9');
    expect(await r.tokens.read('p-1'), 'tok-9',
        reason: '写的是本机 profileId 的 token');
    expect(await r.host.readSecret('secret.ai_key'), isNull);
    await r.host.writeSecret('secret.ai_key', 'sk-9');
    expect(await r.host.readSecret('secret.ai_key'), 'sk-9');
    await r.host.writeSecret('secret.ai_key', '');
    expect(await r.host.readSecret('secret.ai_key'), isNull, reason: '空串 = 删');
    // 本机没有这台实例：安静 no-op，不替用户造实例。
    await r.host
        .writeSecret('secret.instance:https://nope.example.com|z@z.com', 'x');
    expect((await r.db.profileDao.allProfiles()).length, 1);
    // 认不出的 key：读写都安静返回。
    await r.host.writeSecret('secret.unknown', 'x');
    expect(await r.host.readSecret('secret.unknown'), isNull);
    expect(await r.host.readSecret('secret.instance:'), isNull);
  });
}
