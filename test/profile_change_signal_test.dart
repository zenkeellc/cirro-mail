import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/change_signal.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('实例增删改 + token 写入都打枪；同步时间戳不打', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 钥匙串走内存实现：单测里没有插件，真去问平台通道会抛 MissingPluginException。
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final signal = SettingsChangeSignal();
    final prefs = PrefsStore(
      await SharedPreferences.getInstance(),
      signal: signal,
    );
    final tokens = TokenStore(signal: signal);
    final repo = ProfileRepository(db: db, tokens: tokens, prefs: prefs);

    var count = 0;
    final sub = prefs.changes.listen((_) => count++);
    final profile = await repo.create(baseUrl: 'mail.example.com', email: 'a@b.com');
    await pumpEventQueue();
    expect(count, 1, reason: '新建实例要触发同步');

    await tokens.write(profile.id, 'tok-1');
    await pumpEventQueue();
    expect(count, 2, reason: '写 token 也是配置变更');

    await repo.rename(profile.id, '工作');
    await pumpEventQueue();
    expect(count, 3);

    await repo.touch(profile.id);
    await repo.setLastSyncAt(profile.id, DateTime.utc(2026, 11, 11));
    await pumpEventQueue();
    expect(count, 3, reason: '同步轮次的时间戳不算配置变更');

    await repo.delete(profile.id); // 行没了 + token 删了，各打一枪
    await pumpEventQueue();
    expect(count, 5);

    await sub.cancel();
  });
}
