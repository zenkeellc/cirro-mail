import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/network/interceptors/auth_interceptor.dart';
import 'package:mail_app/core/network/interceptors/envelope_interceptor.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 会话生命周期：**401 → 落库 → 重启后仍跳回登录页**，以及
/// **401 之后的那次复验**（虚惊一场要能翻案，真失效才删 token）。
///
/// 这一条链上有几个容易断的地方，它们都不会在编译期报错：
/// 1. `RuntimeRegistry` 只在内存里记 `_needsLoginMessages`，**没写进库** ——
///    于是杀掉重启后 `Profile.isLoggedIn` 又是 true，用户被困在一个每次
///    请求都 401 的收件箱里；
/// 2. `redirect` 的例外分支写错，掉线的实例登不回去（或被立刻弹走）；
/// 3. 401 处理如果**先删钥匙串 token 再想复验**，那条翻案路径永远走不通
///    （`probeSession` 一见 `hasToken == false` 就判定过期）。
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
      // 事件经 broadcast Stream 投递，是异步的 —— 等复验也走完再断言。
      await pumpEventQueue();

      expect(harness.registry.needsLoginMessage(profile.id), '登录已过期');
      expect(
        harness.tokens.readCached(profile.id),
        isNull,
        reason: '废 token 必须从缓存里清掉，否则下一轮又带着它吃一次 401',
      );
      expect(
        await harness.tokens.readFresh(profile.id),
        isNull,
        reason: '复验也回了 401 —— 这一次是真的废了，钥匙串那份要删掉',
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

  group('401 之后的复验', () {
    test('复验通过：登录态原地恢复，needs_login 被撤掉', () async {
      // 探针打的服务端「认这个 token」—— 模拟一次虚惊（KV 跨 colo 抖动、
      // 或服务端刚换 jwt_secret 之后的半秒）。
      final harness = await _Harness.create(
        reply: (options) => const <String, Object?>{
          'code': 200,
          'data': <String, Object?>{'userId': 42, 'email': 'c@example.net'},
        },
      );
      final profile = await harness.seedLoggedIn(email: 'c@example.net');
      await harness.registry.ensure(profile).warmUp();

      harness.authEvents.emitAuthExpired(
        profileId: profile.id,
        message: '登录已过期',
      );
      await pumpEventQueue();

      // 探针请求带上的必须是**钥匙串里那一份** —— 复验的全部意义就在这里。
      expect(harness.adapter.authHeaders, <String?>['fake-jwt-token']);

      expect(harness.registry.needsLoginMessage(profile.id), isNull);
      expect(
        harness.tokens.readCached(profile.id),
        'fake-jwt-token',
        reason: '复验成功后 token 要回到缓存，后续请求才能重新带上它',
      );
      expect(
        (await harness.profiles.find(profile.id))!.needsLogin,
        isFalse,
        reason: '标记是落库的，光撤内存不够（否则重启又进登录页）',
      );
      expect((await harness.profiles.find(profile.id))!.isLoggedIn, isTrue);
    });

    test('复验问不出结论：钥匙串里的 token 保留，等下一次再翻案', () async {
      // 断网 / 服务端 5xx —— 既不能判死，也不能翻案。
      final harness = await _Harness.create(
        reply: (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: '网络不可用',
        ),
      );
      final profile = await harness.seedLoggedIn(email: 'd@example.net');
      await harness.registry.ensure(profile).warmUp();

      harness.authEvents.emitAuthExpired(
        profileId: profile.id,
        message: '登录已过期',
      );
      await pumpEventQueue();

      expect(harness.registry.needsLoginMessage(profile.id), '登录已过期');
      expect(
        harness.tokens.readCached(profile.id),
        'fake-jwt-token',
        reason: '复验刚用它打过请求，所以它回到了缓存 —— 这是下一次再验的凭据；'
            '真失效的话上一轮就已经判 expired 并删掉了',
      );
      expect(
        await harness.tokens.readFresh(profile.id),
        'fake-jwt-token',
        reason: '钥匙串那份必须留着：冷启动时 warmUp 把它读回来，调度器那条'
            '「验活」路径才有东西可验',
      );
      expect((await harness.profiles.find(profile.id))!.needsLogin, isTrue);
    });

    test('复验不会自己打转：401 只补一次探针请求', () async {
      final harness = await _Harness.create();
      final profile = await harness.seedLoggedIn(email: 'e@example.net');
      await harness.registry.ensure(profile).warmUp();
      harness.adapter.authHeaders.clear();

      harness.authEvents.emitAuthExpired(
        profileId: profile.id,
        message: '登录已过期',
      );
      await pumpEventQueue();

      // 一次探针就够：探针自己回 401 会重新触发 `_onAuthExpired`，那里必须
      // 被防重入闸挡住，否则每台掉线实例都会按「事件次数」放大请求。
      expect(harness.adapter.authHeaders, hasLength(1));
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
      bool compact = true,
      AsyncValue<List<Profile>>? async,
    }) =>
        resolveRedirect(
          healthy: healthy,
          async: async ?? AsyncData<List<Profile>>(profiles),
          location: location,
          profileIdParam: param,
          compact: compact,
        );

    test('一个实例都没有 → 窄屏去主页面（欢迎页），宽屏去设置页', () {
      // 窄屏：主页面就是「邮件」那一格，零实例时它是欢迎 / 引导页
      // （`WelcomeView`）—— 用户既能去设置加实例，也随时能回主页面。
      expect(
        at(location: '/mail/all', profiles: const <Profile>[]),
        '/home',
      );
      expect(at(location: '/settings', profiles: const <Profile>[]), isNull);
      expect(at(location: '/home', profiles: const <Profile>[]), isNull);
      // `/setup` 是旧地址（现在只是到主页面的重定向）。
      expect(at(location: '/setup', profiles: const <Profile>[]), '/home');

      // 宽屏：主页面是左侧栏（零实例时收起），没有「一页」可落 ——
      // 落点仍是设置页，添加实例就在那一栏里。
      expect(
        at(
          location: '/mail/all',
          profiles: const <Profile>[],
          compact: false,
        ),
        '/settings',
      );
      expect(
        at(location: '/home', profiles: const <Profile>[], compact: false),
        '/settings',
        reason: '宽屏没有主页面可看，/home 与其它壳内页一样折回设置页',
      );
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
      // `/setup` 现在是旧地址：有实例时也落到设置页（添加实例在那页里）。
      expect(at(location: '/setup', profiles: <Profile>[a, b]), '/settings');
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

/// 一套内存版的依赖：内存 SQLite + 假密钥库 + 假 prefs + 假 HTTP 适配器。
///
/// 假适配器是给**复验**用的：401 之后 `RuntimeRegistry` 会拿钥匙串里那份
/// token 再打一次 `/my/loginUserInfo`，不接管这条连接的话，测试会真的往
/// `mail.example.net` 发请求（慢、且结果不确定）。
class _Harness {
  _Harness._({
    required this.db,
    required this.profiles,
    required this.tokens,
    required this.prefs,
    required this.authEvents,
    required this.adapter,
    required this.registry,
  });

  static Future<_Harness> create({
    bool onAuthExpiredThrows = false,
    Object? Function(RequestOptions options)? reply,
  }) async {
    // 平台通道在测试里没有实现，两个包都提供了官方的内存替身。
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final tokens = TokenStore();
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final authEvents = AuthEvents();
    final profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);
    // 默认回 401：复验的结论是「确实废了」，与改 401 处理之前的行为一致。
    // 想验「虚惊一场」的用例自己传一个 200 的 reply。
    final adapter = _FakeAdapter(
      reply ??
          (_) => const <String, Object?>{'code': 401, 'message': '登录已过期'},
    );

    final harness = _Harness._(
      db: db,
      profiles: profiles,
      tokens: tokens,
      prefs: prefs,
      authEvents: authEvents,
      adapter: adapter,
      registry: RuntimeRegistry(
        authEvents: authEvents,
        tokens: tokens,
        prefs: prefs,
        onAuthExpired: (String profileId) {
          if (onAuthExpiredThrows) throw StateError('磁盘炸了');
          // 与 core_providers 里的接法一致（那边是 fire-and-forget）。
          profiles.markNeedsLogin(profileId);
        },
        onSessionRecovered: (String profileId) =>
            profiles.markNeedsLogin(profileId, needsLogin: false),
        buildApiDio: (Profile profile) => _buildApiDio(
          profile: profile,
          authEvents: authEvents,
          tokens: tokens,
          adapter: adapter,
        ),
      ),
    );
    addTearDown(harness.dispose);
    return harness;
  }

  /// 与 `DioFactory.build` 同一条拦截器链（只是换了适配器）：复验请求
  /// 必须真的带上 `Authorization`，否则「用的哪一份 token」就验不了。
  static Dio _buildApiDio({
    required Profile profile,
    required AuthEvents authEvents,
    required TokenStore tokens,
    required _FakeAdapter adapter,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: profile.baseUrl,
        contentType: Headers.jsonContentType,
        responseType: ResponseType.json,
        // 服务端 HTTP 状态恒 200，真实状态在信封里 —— 与线上一致。
        validateStatus: (_) => true,
      ),
    );
    dio.httpClientAdapter = adapter;
    dio.interceptors.add(
      AuthInterceptor(readToken: () => tokens.readCached(profile.id)),
    );
    dio.interceptors.add(
      EnvelopeInterceptor(
        onUnauthorized: (message) => authEvents.emitAuthExpired(
          profileId: profile.id,
          message: message,
        ),
      ),
    );
    return dio;
  }

  final AppDatabase db;
  final ProfileRepository profiles;
  final TokenStore tokens;
  final PrefsStore prefs;
  final AuthEvents authEvents;
  final _FakeAdapter adapter;
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

/// 记录每次请求带上的 `Authorization`，然后按 [reply] 回包。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.reply);

  final Object? Function(RequestOptions options) reply;

  /// 每个请求实际带出去的 `Authorization`（null = 没带）。
  final List<String?> authHeaders = <String?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authHeaders.add(options.headers['Authorization']?.toString());
    return ResponseBody.fromString(
      jsonEncode(reply(options)),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
