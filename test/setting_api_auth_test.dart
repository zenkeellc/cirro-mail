// 这一条修的是一个**今天就已经坏掉**的功能（规格 §1.3）：
//
//   服务端 `setting-service.js:209`：
//     domainList: settingRow.loginDomain === 1 && !token ? [] : settingRow.domainList
//
// 线上实例 `login_domain = 1`，而 `SettingApi.websiteConfig()` 写死了
// `skipAuth: true` —— **从来不带 token**。于是无论登录与否 `domainList` 恒为空，
// 「域名后缀下拉」这个控件在 App 里永远没有选项。
//
// `auth_repository.dart` 那句「带 token 再拉一次（domainList 这时才可信）」
// 的**意图是对的**，只是被 `skipAuth` 架空了。
//
// 所以这里钉的不是「配置能拿到」（那早就通了），而是**请求上有没有
// Authorization 头** —— 一个只在网络层可见、在返回值上完全看不出来的差别。
// `_FakeAdapter` 因此必须记 header（`config_repository_test.dart` 里那个
// 只记 URI，不够用）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/network/dio_factory.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/api/setting_api.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/config_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() async => h = await _Harness.create());
  tearDown(() async => h.dispose());

  test('authenticated: false（默认）→ 请求上没有 Authorization 头', () async {
    await h.api.websiteConfig();
    // 注：原稿是 `<String?>[isNull]` —— 但 `isNull` 是 `Matcher`，
    // 不是 `String?`，那个列表字面量直接是类型错误。放宽成 `<Object?>`，
    // 深比较时元素级 matcher 照样生效。
    expect(h.adapter.authHeaders, <Object?>[isNull],
        reason: '免鉴权那一次（登录页「测试连接」）不该带 token');
  });

  test('authenticated: true → 请求带上 token', () async {
    await h.tokens.write(h.profileId, 'tok-123');
    await h.api.websiteConfig(authenticated: true);
    expect(h.adapter.authHeaders.last, 'tok-123',
        reason: '`Authorization: <jwt>`，**不带** `Bearer ` 前缀');
  });

  test('authenticated: true 但运行时有 token → ConfigRepository 会自动带', () async {
    await h.tokens.write(h.profileId, 'tok-456');
    // 关键：`ConfigRepository` 自己看 `runtime.hasToken` 决定，
    // 调用方（登录页、诊断页、首页）不需要知道这件事。
    await h.repo.fetch(h.profile, force: true, allowStaleOnError: false);
    expect(h.adapter.authHeaders.last, 'tok-456');
  });

  test('authenticated: true 但运行时没 token → 不带（不打无意义的 401）', () async {
    await h.repo.fetch(h.profile, force: true, allowStaleOnError: false);
    expect(h.adapter.authHeaders.last, isNull,
        reason: '没 token 却带上一个空 Authorization，会被服务端当假 token 拒');
  });

  test('带 token 时拿到的 domainList 会落进能力表', () async {
    await h.tokens.write(h.profileId, 'tok-789');
    h.adapter.respondJson(<String, Object?>{
      'code': 200,
      'data': <String, Object?>{
        'title': 'UMail',
        'domainList': <String>['@example.com', '@example.net'],
      },
    });
    await h.repo.fetch(h.profile, force: true, allowStaleOnError: false);
    for (var i = 0; i < 40; i++) {
      final caps = await h.db.profileDao.loadCapabilities(h.profileId);
      if (caps != null && caps.domainList.isNotEmpty) {
        expect(caps.domainList, <String>['@example.com', '@example.net']);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('域名单一直没有落进能力表');
  });
}

class _Harness {
  _Harness._({
    required this.db,
    required this.profileId,
    required this.profile,
    required this.repo,
    required this.api,
    required this.tokens,
    required this.adapter,
    required this._registry,
    required this._authEvents,
  });

  static Future<_Harness> create() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final tokens = TokenStore();
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);
    final authEvents = AuthEvents();
    final adapter = _HeaderRecordingAdapter();

    final registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      buildApiDio: (profile) => DioFactory.build(
        userApi: profile.baseUrl,
        profileId: profile.id,
        authEvents: authEvents,
        // **真读 token**：这一组测的就是「有没有带上它」。
        readToken: () => tokens.readCached(profile.id),
        readLanguage: () => 'zh',
      )..httpClientAdapter = adapter,
    );

    final profile = await profiles.create(baseUrl: 'https://mail.example.net');
    final runtime = registry.ensure(profile);
    return _Harness._(
      db: db,
      profileId: profile.id,
      profile: profile,
      repo: ConfigRepository(
        registry: registry,
        capabilities: CapabilityRepository(db),
      ),
      api: runtime.settingApi,
      tokens: tokens,
      adapter: adapter,
      // 私有字段形参在**调用点**要用公开名（与 `config_repository_test.dart`
      // 同一个模式）。
      registry: registry,
      authEvents: authEvents,
    );
  }

  final AppDatabase db;
  final String profileId;
  final Profile profile;
  final ConfigRepository repo;
  final SettingApi api;
  final TokenStore tokens;
  final _HeaderRecordingAdapter adapter;
  final RuntimeRegistry _registry;
  final AuthEvents _authEvents;

  Future<void> dispose() async {
    await _registry.dispose();
    await _authEvents.dispose();
    await db.close();
  }
}

/// 与 `config_repository_test.dart` 里那个的区别只有一个：**记 header**。
class _HeaderRecordingAdapter implements HttpClientAdapter {
  final List<String?> authHeaders = <String?>[];
  Object _body = const <String, Object?>{
    'code': 200,
    'data': <String, Object?>{'title': 'T'},
  };

  void respondJson(Object body) => _body = body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authHeaders.add(options.headers['Authorization']?.toString());
    return ResponseBody.fromString(
      jsonEncode(_body),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
