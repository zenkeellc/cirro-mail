import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 会话生命周期：**401 → 落库 → 重启后仍跳回登录页**。
///
/// 这一条链上有两个容易断的地方，它们都不会在编译期报错：
/// 1. `RuntimeRegistry` 只在内存里记 `_needsLoginMessages`，**没写进库** ——
///    于是杀掉重启后 `Profile.isLoggedIn` 又是 true，用户被困在一个每次
///    请求都 401 的收件箱里；
/// 2. `redirect` 的例外分支写错，掉线的实例登不回去（或被立刻弹走）。
///
/// 所以这里既验状态（`Profile.needsLogin` 真的落到了库里），
/// 也把 `resolveRedirect` 的判断矩阵钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('401 的落库', () {
    test('token 被判 401 后，needsLogin 会写进 profiles 表', () async {
      final harness = await _Harness.create();
      final profile = await harness.seedLoggedIn(email: 'a@example.net');

      final runtime = harness.registry.ensure(profile);
      await runtime.warmUp();
      expect(runtime.hasToken, isTrue, reason: '前提：这个实例本来是有 token 的');

      harness.authEvents.emitAuthExpired(
        profileId: profile.id,
        message: '登录已过期',
      );
      // 事件经 broadcast Stream 投递，是异步的 —— 等一拍再断言。
      await pumpEventQueue();

      expect(harness.registry.needsLoginMessage(profile.id), '登录已过期');
      expect(
        harness.tokens.readCached(profile.id),
        isNull,
        reason: '废 token 必须从缓存里清掉，否则下一轮又带着它吃一次 401',
      );

      final after = (await harness.profiles.find(profile.id))!;
      expect(after.needsLogin, isTrue);
      expect(after.isLoggedIn, isFalse, reason: 'redirect 只认 isLoggedIn');

      // 「杀掉重启」：换一棵全新的 registry，内存里的标记与 token 缓存
      // 全都没了 —— 能救场的只有库里的那一位。
      final restarted = harness.restart();
      expect(restarted.needsLoginMessage(profile.id), isNull);
      expect((await harness.profiles.find(profile.id))!.isLoggedIn, isFalse);
    });

    test('落库回调抛异常也不会把 401 的处理路径打断', () async {
      final harness = await _Harness.create(onAuthExpiredThrows: true);
      final profile = await harness.seedLoggedIn(email: 'b@example.net');
      await harness.registry.ensure(profile).warmUp();

      harness.authEvents.emitAuthExpired(
        profileId: profile.id,
        message: '登录已过期',
      );
      await pumpEventQueue();

      // 内存标记与 token 清理照常完成 —— 磁盘的毛病不该带走整条链路。
      expect(harness.registry.needsLoginMessage(profile.id), '登录已过期');
      expect(harness.tokens.readCached(profile.id), isNull);
    });
  });

  group('resolveRedirect', () {
    final a = _profile(id: 'A', userId: 7, email: 'a@example.net');
    final aDead = a.copyWith(needsLogin: true);
    final b = _profile(
      id: 'B',
      userId: 9,
      email: 'b@example.net',
      baseUrl: 'https://mail.example.com/api',
    );

    String? at({
      required String location,
      required List<Profile> profiles,
      String? param,
      bool healthy = true,
      AsyncValue<List<Profile>>? async,
    }) =>
        resolveRedirect(
          healthy: healthy,
          async: async ?? AsyncData<List<Profile>>(profiles),
          location: location,
          profileIdParam: param,
        );

    test('一个实例都没有 → 去服务器设置页', () {
      expect(at(location: '/mail/all', profiles: const <Profile>[]), '/setup');
      expect(at(location: '/setup', profiles: const <Profile>[]), isNull);
    });

    test('有实例但都没登录 → 去第一个的登录页', () {
      final dead = _profile(id: 'A', email: 'a@example.net'); // userId 0
      expect(
        at(location: '/mail/all', profiles: <Profile>[dead]),
        '/login/A',
      );
    });

    test('token 判 401 的实例，即使别的实例还活着也要让位给登录页', () {
      // 关键：B 是登录着的，所以 `anyLoggedIn` 为真 —— 早先的写法会在
      // 这里直接返回 null，把用户留在一个只会 401 的 `/mail/A` 上。
      expect(
        at(location: '/mail/A', profiles: <Profile>[aDead, b], param: 'A'),
        '/login/A',
      );
    });

    test('别的实例掉线，不该把正在读信的用户拽走', () {
      // 路由指向 B（活着），A 掉线与之无关。
      expect(
        at(location: '/mail/B', profiles: <Profile>[aDead, b], param: 'B'),
        isNull,
      );
    });

    test('掉线实例的登录页是可停留的（能被弹回主屏）', () {
      expect(
        at(location: '/login/A', profiles: <Profile>[aDead, b], param: 'A'),
        isNull,
      );
    });

    test('实例已被删除 → 回全部实例合并的列表', () {
      expect(
        at(location: '/mail/Z', profiles: <Profile>[a, b], param: 'Z'),
        '/mail/all',
      );
    });

    test('登好之后不再停在登录页 / 服务器设置页', () {
      expect(
        at(location: '/login/B', profiles: <Profile>[a, b], param: 'B'),
        '/mail/all',
      );
      expect(at(location: '/setup', profiles: <Profile>[a, b]), '/mail/all');
    });

    test('实例列表还没读出来时停在原地（避免冷启动闪一下设置页）', () {
      expect(
        at(
          location: '/mail/all',
          profiles: const <Profile>[],
          async: const AsyncLoading<List<Profile>>(),
        ),
        isNull,
      );
    });

    test('启动失败页优先于一切', () {
      expect(
        at(location: '/mail/all', profiles: const <Profile>[], healthy: false),
        '/startup-failure',
      );
      expect(
        at(location: '/startup-failure', profiles: const <Profile>[], healthy: false),
        isNull,
      );
    });
  });
}

Profile _profile({
  required String id,
  int userId = 0,
  String email = '',
  String baseUrl = 'https://mail.example.net/api',
  bool needsLogin = false,
}) =>
    Profile(
      id: id,
      baseUrl: baseUrl,
      email: email,
      userId: userId,
      needsLogin: needsLogin,
    );

/// 一套内存版的依赖：内存 SQLite + 假密钥库 + 假 prefs。
class _Harness {
  _Harness._({
    required this.db,
    required this.profiles,
    required this.tokens,
    required this.prefs,
    required this.authEvents,
    required this.registry,
  });

  static Future<_Harness> create({bool onAuthExpiredThrows = false}) async {
    // 平台通道在测试里没有实现，两个包都提供了官方的内存替身。
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final tokens = TokenStore();
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final authEvents = AuthEvents();
    final profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);

    final harness = _Harness._(
      db: db,
      profiles: profiles,
      tokens: tokens,
      prefs: prefs,
      authEvents: authEvents,
      registry: RuntimeRegistry(
        authEvents: authEvents,
        tokens: tokens,
        prefs: prefs,
        onAuthExpired: (String profileId) {
          if (onAuthExpiredThrows) throw StateError('磁盘炸了');
          // 与 core_providers 里的接法一致（那边是 fire-and-forget）。
          profiles.markNeedsLogin(profileId);
        },
      ),
    );
    addTearDown(harness.dispose);
    return harness;
  }

  final AppDatabase db;
  final ProfileRepository profiles;
  final TokenStore tokens;
  final PrefsStore prefs;
  final AuthEvents authEvents;
  final RuntimeRegistry registry;

  /// 建一个「已登录」的实例：库里有 userId/email，密钥库里有 token。
  Future<Profile> seedLoggedIn({required String email}) async {
    final profile = await profiles.create(baseUrl: 'https://mail.example.net');
    await profiles.markLoggedIn(
      profile.id,
      userId: 42,
      email: email,
      userName: email.split('@').first,
    );
    await tokens.write(profile.id, 'fake-jwt-token');
    return (await profiles.find(profile.id))!;
  }

  /// 模拟「杀掉重启」：新的 registry、新的 AuthEvents，**共用同一个库**。
  RuntimeRegistry restart() => RuntimeRegistry(
        authEvents: authEvents,
        tokens: tokens,
        prefs: prefs,
        onAuthExpired: (_) {},
      );

  Future<void> dispose() async {
    await registry.dispose();
    await authEvents.dispose();
    await db.close();
  }
}
