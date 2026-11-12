import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/network/interceptors/auth_interceptor.dart';
import 'package:mail_app/core/network/interceptors/envelope_interceptor.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/account_repository.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:mail_app/instance/sync_scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 换机 / 配置漫游恢复出来的实例：**先核对 token 属于谁，再决定要不要用它收信**。
///
/// 真实故障（2026-11-12）：云端多出一条 `mail.gui-ke.com | admin@en.ke` 的
/// 实例条目（同一台实例上换过账号、宿主又同时承载两个域名，登录不报错）。
/// 恢复出来的实例名字叫「GUIKE」，邮箱却全是 `@en.ke` —— 用户读到的是
/// 「gui-ke 的邮箱全丢了」。这里钉住两道闸：
/// 1. 反馈的账号邮箱与实例记录的登录邮箱**一致**才采用（并回填身份）；
/// 2. 不一致时**不采用、也不改名**（改名会让漫游 key 跟着变）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const instanceKeyMail = 'kedong@gui-ke.com';

  Future<_Harness> createHarness({
    Object? Function(RequestOptions options)? loginUser,
  }) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final tokens = TokenStore();
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final authEvents = AuthEvents();
    final profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);
    final adapter = _FakeAdapter(
      loginUser ??
          (_) => <String, Object?>{
            'code': 200,
            'message': 'success',
            'data': <String, Object?>{
              'userId': 7,
              'email': instanceKeyMail,
              'name': 'kedong',
              'account': <String, Object?>{
                'accountId': 10,
                'email': instanceKeyMail,
              },
            },
          },
    );
    final registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      buildApiDio: (Profile profile) => _buildApiDio(
        profile: profile,
        authEvents: authEvents,
        tokens: tokens,
        adapter: adapter,
      ),
    );
    addTearDown(() async {
      await registry.dispose();
      await authEvents.dispose();
      await db.close();
    });
    return _Harness(
      db: db,
      tokens: tokens,
      profiles: profiles,
      registry: registry,
      adapter: adapter,
      prefs: prefs,
    );
  }

  test('token 属于这个登录邮箱：采用并回填身份，内存里的「需重登」撤掉', () async {
    final h = await createHarness();
    final profile = await h.seedRestored(email: instanceKeyMail);
    h.registry.ensure(profile);

    final adoption = await h.registry.adoptRestoredSession(profile);

    expect(adoption.result, RestoredSession.adopted);
    expect(adoption.user?.userId, 7);
    expect(adoption.user?.email, instanceKeyMail);
    expect(adoption.actualEmail, isNull);
    expect(h.adapter.authHeaders, everyElement('fake-jwt-token'));
  });

  test('token 属于另一个账号：不采用、不改名，冷却期内不再重复问', () async {
    final h = await createHarness(
      loginUser: (_) => <String, Object?>{
        'code': 200,
        'message': 'success',
        'data': <String, Object?>{
          'userId': 11,
          'email': 'admin@en.ke',
          'name': 'admin',
        },
      },
    );
    final profile = await h.seedRestored(email: instanceKeyMail);
    h.registry.ensure(profile);

    final first = await h.registry.adoptRestoredSession(profile);
    expect(first.result, RestoredSession.mismatch);
    expect(first.actualEmail, 'admin@en.ke');
    expect(first.user, isNull);
    expect(h.registry.identityMismatchEmail(profile.id), 'admin@en.ke');

    final requests = h.adapter.requestCount;
    final second = await h.registry.adoptRestoredSession(profile);
    expect(second.result, RestoredSession.mismatch);
    expect(
      h.adapter.requestCount,
      requests,
      reason: '结论已经记住了，冷却期内不该再拿同一个 token 去打服务端',
    );

    // **关键**：实例记录的邮箱不能被 token 的账号覆盖 ——
    // 它是漫游 key（`instance:<host>|<email>`）的一部分。
    final after = (await h.profiles.find(profile.id))!;
    expect(after.email, instanceKeyMail);
    expect(after.needsLogin, isTrue);
    expect(after.isLoggedIn, isFalse);
  });

  test('token 已失效（401）：按 expired 返回，留给用户重登', () async {
    final h = await createHarness(
      loginUser: (_) => <String, Object?>{'code': 401, 'message': '登录已过期'},
    );
    final profile = await h.seedRestored(email: instanceKeyMail);
    h.registry.ensure(profile);

    final adoption = await h.registry.adoptRestoredSession(profile);
    expect(adoption.result, RestoredSession.expired);
    expect(h.registry.identityMismatchEmail(profile.id), isNull);
  });

  test('钥匙串里没有 token：none（恢复没写回时不假装已登录）', () async {
    final h = await createHarness();
    final profile = await h.seedRestored(email: instanceKeyMail, token: false);

    final adoption = await h.registry.adoptRestoredSession(profile);
    expect(adoption.result, RestoredSession.none);
  });

  test('调度器：恢复的 token 属于别的账号时不建 engine、也不回填身份', () async {
    final h = await createHarness(
      loginUser: (_) => <String, Object?>{
        'code': 200,
        'message': 'success',
        'data': <String, Object?>{'userId': 11, 'email': 'admin@en.ke'},
      },
    );
    final profile = await h.seedRestored(email: instanceKeyMail);
    final capabilities = CapabilityRepository(h.db);
    var adopted = 0;
    final scheduler = SyncScheduler(
      db: h.db,
      registry: h.registry,
      capabilities: capabilities,
      prefs: h.prefs,
      emails: EmailRepository(
        db: h.db,
        registry: h.registry,
        capabilities: capabilities,
        profiles: h.profiles,
        prefs: h.prefs,
      ),
      accounts: AccountRepository(
        db: h.db,
        registry: h.registry,
        capabilities: capabilities,
      ),
      onSessionRecovered: (_) async {},
      onRestoredSessionAdopted: (_, _) async => adopted++,
    );
    addTearDown(scheduler.dispose);

    await scheduler.start(<Profile>[profile]);
    scheduler.stop();

    expect(adopted, 0, reason: '对不上就不该把身份回填成 server 上那个账号');
    expect(h.registry.identityMismatchEmail(profile.id), 'admin@en.ke');
    final after = (await h.profiles.find(profile.id))!;
    expect(after.needsLogin, isTrue);
    expect(after.email, instanceKeyMail);
  });

  test('用户重新登录（clearNeedsLogin）会清掉「不是这个账号」的结论', () async {
    final h = await createHarness(
      loginUser: (_) => <String, Object?>{
        'code': 200,
        'message': 'success',
        'data': <String, Object?>{'userId': 11, 'email': 'admin@en.ke'},
      },
    );
    final profile = await h.seedRestored(email: instanceKeyMail);
    h.registry.ensure(profile);

    await h.registry.adoptRestoredSession(profile);
    expect(h.registry.identityMismatchEmail(profile.id), isNotNull);

    h.registry.clearNeedsLogin(profile.id);
    expect(h.registry.identityMismatchEmail(profile.id), isNull);
  });
}

class _Harness {
  _Harness({
    required this.db,
    required this.tokens,
    required this.profiles,
    required this.registry,
    required this.adapter,
    required this.prefs,
  });

  final AppDatabase db;
  final TokenStore tokens;
  final ProfileRepository profiles;
  final RuntimeRegistry registry;
  final _FakeAdapter adapter;
  final PrefsStore prefs;

  /// 建一个「从漫游恢复出来」的实例：有登录邮箱、`needs_login = 1`，
  /// 钥匙串里（可选）已经有 token —— 正是恢复写回之后的形状。
  Future<Profile> seedRestored({
    required String email,
    bool token = true,
  }) async {
    final created = await profiles.create(
      baseUrl: 'https://mail.gui-ke.com',
      email: email,
    );
    await profiles.markNeedsLogin(created.id);
    if (token) await tokens.write(created.id, 'fake-jwt-token');
    return (await profiles.find(created.id))!;
  }
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.reply);

  final Object? Function(RequestOptions options) reply;
  final List<String?> authHeaders = <String?>[];
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
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

Dio _buildApiDio({
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
      validateStatus: (_) => true,
    ),
  );
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(
    AuthInterceptor(readToken: () => tokens.readCached(profile.id)),
  );
  dio.interceptors.add(
    EnvelopeInterceptor(
      onUnauthorized: (message) =>
          authEvents.emitAuthExpired(profileId: profile.id, message: message),
    ),
  );
  return dio;
}
