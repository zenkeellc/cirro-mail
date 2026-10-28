import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/daos/mail_dao.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/network/dio_factory.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 探测一个邮箱的服务端总数时，**发出去的那个请求**长什么样。
///
/// 这一条是这次改动里唯一真的会往外打请求的地方，而它的错法全是安静的：
/// 少了 `size=1` 就是白传一页 50 封的正文（几十 KB × 几十个邮箱），
/// 少了 `full=0` 更贵；而**写完顺手碰了游标**的话，用户下一次同步会从
/// 一个错的位置开始 —— 那是要等到发现「有邮件漏了」才知道的错。
///
/// 夹的是一个可控响应的假适配器（照 `open_mail_read_test.dart` 的样板），
/// 于是「请求参数对不对」和「库里只动了哪两列」都能直接断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() async => h = await _Harness.create());
  tearDown(() async => h.dispose());

  test('发出的是 GET /email/list，size=1、full=0、accountId 正确', () async {
    h.adapter.respond((options, body) => h.ok(data: <String, Object?>{
          'list': <Object?>[],
          'total': 12,
          'latestEmail': null,
        }));

    final total = await h.repo.probeMailboxTotal(
      profile: h.profile,
      accountId: 3,
    );

    expect(total, 12);
    expect(h.adapter.listRequests, hasLength(1));
    final q = h.adapter.listRequests.single.query;
    expect(h.adapter.listRequests.single.method, 'GET');
    expect(q['accountId'], 3);
    expect(q['type'], MailType.receive);
    // `size: 1` 就够 —— 服务端的 `total` 与游标、与每页几条都无关。
    expect(q['size'], 1);
    expect(q['full'], 0);
    // 不该出现的东西：探测不是翻页，也不是「收全部邮箱」。
    expect(q.containsKey('emailId'), isFalse);
    // **必须显式带 0**：不带参数时服务端会回落到该账户自己的「合并接收」
    // 开关，探单邮箱就会拿回整账户的 total（见 `EmailApi.list` 的注释）。
    expect(q['allReceive'], 0);
  });

  test('只写 remote_total / remote_total_at，游标与退避计数一字不动', () async {
    // 先造一条「正在增量同步」的行：游标非 0、有退避历史。
    const scope = 'mailbox:3:type:0';
    await h.mailDao.saveSyncState(
      profileId: h.profile.id,
      scope: scope,
      cursorEmailId: 900,
      oldestEmailId: 120,
      backfillDone: true,
      lastSyncAt: DateTime.utc(2026, 10, 11, 7),
      failCount: 3,
      lastError: 'boom',
    );
    h.adapter.respond((options, body) => h.ok(data: <String, Object?>{
          'list': <Object?>[],
          'total': 42,
        }));

    await h.repo.probeMailboxTotal(profile: h.profile, accountId: 3);

    final row = (await h.mailDao.syncState(h.profile.id, scope))!;
    expect(row.remoteTotal, 42);
    expect(row.remoteTotalAt, isNotNull);
    expect(row.cursorEmailId, 900, reason: '探测不是同步，游标不许动');
    expect(row.oldestEmailId, 120);
    expect(row.backfillDone, isTrue);
    expect(row.failCount, 3, reason: '探测失败/成功都不进退避计数');
    expect(row.lastError, 'boom');
    expect(row.lastSyncAt, isNotNull);
  });

  test('服务端回 total = 0 也落库，并且与「从来没探过」分得开', () async {
    h.adapter.respond((options, body) => h.ok(data: <String, Object?>{
          'list': <Object?>[],
          'total': 0,
        }));

    expect(await h.repo.probeMailboxTotal(profile: h.profile, accountId: 3), 0);

    final known = (await h.mailDao.syncState(h.profile.id, 'mailbox:3:type:0'))!;
    expect(known.remoteTotal, 0);
    // 这一列非 null 才是「空邮箱」这条结论的落点（`remote_total` 的 0
    // 本身表示「还不知道」）。
    expect(known.remoteTotalAt, isNotNull);
    expect(await h.mailDao.syncState(h.profile.id, 'mailbox:4:type:0'), isNull);
  });

  test('请求失败时什么都不写（下次展开会重试）', () async {
    h.adapter.failNext();

    expect(await h.repo.probeMailboxTotal(profile: h.profile, accountId: 3),
        isNull);
    // 连行都不该有 —— 写了行（哪怕是「未知」那一种）就等于给这一格
    // 盖了「探过」的印，而它其实没探到。
    expect(await h.mailDao.syncState(h.profile.id, 'mailbox:3:type:0'), isNull);
  });

  test('拿不到 total 时也不写（响应里没有这个字段）', () async {
    h.adapter.respond((options, body) => h.ok(data: <String, Object?>{
          'list': <Object?>[],
        }));

    expect(await h.repo.probeMailboxTotal(profile: h.profile, accountId: 3),
        isNull);
    expect(await h.mailDao.syncState(h.profile.id, 'mailbox:3:type:0'), isNull);
  });

  test('探到的总数进 `mailboxScope`，不是 `all:type:0`', () async {
    h.adapter.respond((options, body) => h.ok(data: <String, Object?>{
          'list': <Object?>[],
          'total': 7,
        }));

    await h.repo.probeMailboxTotal(profile: h.profile, accountId: 3);

    final byScope = await h.mailDao
        .watchSyncStatesOfProfile(h.profile.id)
        .first;
    expect(byScope.keys, <String>[
      EmailRepository.mailboxScope(3, MailType.receive),
    ]);
  });
}

/// 一个能发真请求、但不碰网络的假适配器。
class _Harness {
  _Harness._({
    required this.db,
    required this.mailDao,
    required this.repo,
    required this.profile,
    required this.registry,
    required this.adapter,
    required this.authEvents,
  });

  static Future<_Harness> create() async {
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
      buildApiDio: (profile) {
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
    await db.profileDao.upsertMailboxes(created.id, <MailboxAccount>[
      const MailboxAccount(accountId: 3, email: 'me@example.net', name: '我'),
    ]);

    final h = _Harness._(
      db: db,
      mailDao: db.mailDao,
      repo: EmailRepository(
        db: db,
        registry: registry,
        capabilities: CapabilityRepository(db),
        profiles: profiles,
        prefs: prefs,
      ),
      profile: (await profiles.find(created.id))!,
      registry: registry,
      adapter: adapter,
      authEvents: authEvents,
    );
    // 响应里那个 email 是 `Profile.email`，`probeMailboxTotal` 只用到 id，
    // 但让它与库里的实例行一致，读日志时不会看岔。
    final runtime = registry.ensure(h.profile);
    await runtime.warmUp();
    return h;
  }

  final AppDatabase db;
  final MailDao mailDao;
  final EmailRepository repo;
  final Profile profile;
  final RuntimeRegistry registry;
  final _FakeAdapter adapter;
  final AuthEvents authEvents;

  Map<String, Object?> ok({Object? data}) =>
      <String, Object?>{'code': 200, 'message': 'success', 'data': data};

  /// `MailboxFilter` 那几行（探测的入参形态）。
  List<MailboxFilter> boxes(List<int> accountIds) => <MailboxFilter>[
        for (final id in accountIds)
          MailboxFilter(profileId: profile.id, accountId: id),
      ];

  Future<void> dispose() async {
    await registry.dispose();
    await authEvents.dispose();
    await db.close();
  }
}

class _SentRequest {
  _SentRequest({required this.path, required this.method, required this.query});

  final String path;
  final String method;
  final Map<String, dynamic> query;
}

class _FakeAdapter implements HttpClientAdapter {
  FutureOr<Object?> Function(RequestOptions, List<int>)? _handler;
  Object? _failure;
  int _inFlight = 0;
  int _maxInFlight = 0;

  final List<_SentRequest> listRequests = <_SentRequest>[];

  /// 同时最多有几个请求在飞（并发的用例要看它）。
  int get maxInFlight => _maxInFlight;

  void respond(FutureOr<Object?> Function(RequestOptions, List<int>) handler) {
    _handler = handler;
    _failure = null;
  }

  void failNext() {
    _failure = DioException.connectionError(
      requestOptions: RequestOptions(path: '/email/list'),
      reason: '测试注入的断网',
    );
    _handler = null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _inFlight++;
    if (_inFlight > _maxInFlight) _maxInFlight = _inFlight;
    try {
      final bytes = <int>[];
      if (requestStream != null) {
        await for (final chunk in requestStream) {
          bytes.addAll(chunk);
        }
      }
      if (options.path.contains('/email/list')) {
        listRequests.add(_SentRequest(
          path: options.path,
          method: options.method,
          query: options.queryParameters,
        ));
      }

      // 让出一拍再答：没有这一段的话「并发」永远测不出来 —— 每个请求都会
      // 在自己的第一帧里答完，`_maxInFlight` 恒为 1。
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final failure = _failure;
      if (failure != null) {
        _failure = null;
        throw failure;
      }

      final handler = _handler;
      final payload = handler == null
          ? <String, Object?>{'code': 200, 'message': 'success', 'data': null}
          : await handler(options, bytes);
      final encoded = utf8.encode(jsonEncode(payload));
      return ResponseBody(
        Stream<Uint8List>.fromIterable(<Uint8List>[Uint8List.fromList(encoded)]),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json;charset=utf-8'],
        },
      );
    } finally {
      _inFlight--;
    }
  }

  @override
  void close({bool force = false}) {}
}
