import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/config/app_defaults.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/network/dio_factory.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/account_repository.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:mail_app/instance/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `/account/list` 的客户端 TTL（`SyncEngine._mailboxes`）。
///
/// 这条 TTL 是**成本**上的决定，但它是会坏在「新装的实例拿不到主邮箱」
/// 这种功能问题上的，所以两个方向都要钉住：
/// - 列表已经在本地、且没过 TTL → 不再打请求（否则默认 5 分钟轮询下，
///   一天 288 次 `/account/list`，每次都带 1 次 KV 读 + 一次四表权限 JOIN）；
/// - 本地为空 → TTL 必须让路（否则新实例永远同步不出东西）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('列表在本地且没过 TTL：连续两轮同步只问一次 /account/list', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);

    await harness.engine.syncOnce();
    expect(harness.adapter.countOf('/account/list'), 1);

    await harness.engine.syncOnce();
    expect(
      harness.adapter.countOf('/account/list'),
      1,
      reason: 'TTL（${AppDefaults.mailboxRefreshTtl.inMinutes} 分钟）内不该再问',
    );
    // 收信本身照旧：省掉的只是邮箱列表那一次。
    expect(harness.adapter.countOf('/email/list'), 2);
  });

  test('用户手动「立即同步」绕过 TTL，立刻重新问一次邮箱列表', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);

    await harness.engine.syncOnce();
    expect(harness.adapter.countOf('/account/list'), 1);

    harness.engine.requestNow();
    await harness.engine.syncOnce();
    expect(
      harness.adapter.countOf('/account/list'),
      2,
      reason: '手动刷新的语义是「按服务器上的真实状态来」，不该吃缓存',
    );
  });

  test('本地没有邮箱时 TTL 让路：新实例第一轮就能拿到列表', () async {
    final harness = await _Harness.create(seedMailboxes: false);
    addTearDown(harness.dispose);
    expect(await harness.accounts.of(harness.profile.id), isEmpty);

    await harness.engine.syncOnce();

    expect(harness.adapter.countOf('/account/list'), 1);
    expect(
      await harness.accounts.of(harness.profile.id),
      isNotEmpty,
      reason: 'TTL 是「有本地列表才缓存」的优化，不能反过来把空列表钉死',
    );
  });
}

/// 一套真仓储（内存 SQLite）+ 假 HTTP（不碰网络）的同步环境。
class _Harness {
  _Harness._({
    required this.db,
    required this.tokens,
    required this.profile,
    required this.registry,
    required this.adapter,
    required this.authEvents,
    required this.accounts,
    required this.engine,
  });

  static Future<_Harness> create({bool seedMailboxes = true}) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final tokens = TokenStore();
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);
    final authEvents = AuthEvents();
    final adapter = _FakeAdapter();

    final registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      buildApiDio: (Profile profile) {
        final dio = DioFactory.build(
          userApi: profile.baseUrl,
          profileId: profile.id,
          authEvents: authEvents,
          readToken: () => tokens.readCached(profile.id),
          readLanguage: () => 'zh',
        );
        dio.httpClientAdapter = adapter;
        return dio;
      },
    );

    final created = await profiles.create(baseUrl: 'https://mail.example.net');
    await profiles.markLoggedIn(
      created.id,
      userId: 42,
      email: 'me@example.net',
      userName: 'me',
    );
    await tokens.write(created.id, 'fake-jwt');
    if (seedMailboxes) {
      await db.profileDao.upsertMailboxes(created.id, <MailboxAccount>[
        const MailboxAccount(
          accountId: 3,
          email: 'me@example.net',
          name: 'me',
          allReceive: 1,
        ),
      ]);
    }
    final profile = (await profiles.find(created.id))!;
    // `SyncEngine.syncOnce` 开头就靠 `hasToken` 判「能不能收信」。
    await registry.ensure(profile).warmUp();

    final capabilities = CapabilityRepository(db);
    final emails = EmailRepository(
      db: db,
      registry: registry,
      capabilities: capabilities,
      profiles: profiles,
      prefs: prefs,
    );
    final accounts = AccountRepository(
      db: db,
      registry: registry,
      capabilities: capabilities,
    );

    return _Harness._(
      db: db,
      tokens: tokens,
      profile: profile,
      registry: registry,
      adapter: adapter,
      authEvents: authEvents,
      accounts: accounts,
      engine: SyncEngine(
        profile: profile,
        registry: registry,
        emails: emails,
        accounts: accounts,
        capabilities: capabilities,
        prefs: prefs,
        onNewMail: (_, _) {},
      ),
    );
  }

  final AppDatabase db;
  final TokenStore tokens;
  final Profile profile;
  final RuntimeRegistry registry;
  final _FakeAdapter adapter;
  final AuthEvents authEvents;
  final AccountRepository accounts;
  final SyncEngine engine;

  Future<void> dispose() async {
    engine.stop();
    await registry.dispose();
    await authEvents.dispose();
    await db.close();
  }
}

/// 按路径回合法信封的假适配器（`/account/list` 的形状要能过
/// `MailboxAccount.listFromJson`，否则会退到「仅主邮箱」那条降级路径）。
class _FakeAdapter implements HttpClientAdapter {
  final Map<String, int> hits = <String, int>{};

  int countOf(String path) => hits[path] ?? 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.path;
    hits[path] = (hits[path] ?? 0) + 1;

    final Object? data;
    if (path == '/account/list') {
      data = <Object?>[
        <String, Object?>{
          'accountId': 3,
          'email': 'me@example.net',
          'name': 'me',
          'sort': 0,
          'allReceive': 1,
        },
      ];
    } else if (path == '/email/list') {
      data = <String, Object?>{'list': <Object?>[], 'total': 0};
    } else if (path == '/email/latest') {
      data = <Object?>[];
    } else {
      data = null;
    }

    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{'code': 200, 'data': data}),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
