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
import 'package:mail_app/core/util/email_address.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「切换邮箱后收件箱一片空白」的回归测试。
///
/// 症状：默认的「这个实例的所有邮箱」视图正常，但侧栏切到任意一个具体邮箱
/// 就是空的。
///
/// 链路是：收件方向的同步永远走 `allReceive: true`（一个请求覆盖所有邮箱），
/// 而服务端的 `/email/latest` 用的是 `emailBriefColumns` —— 那一组列里
/// **没有 `accountId`**。于是每一封收信落库时 `account_id` 都是 0；本地列表
/// 按邮箱过滤（`mails.account_id = <选中的 id>`）时一封都选不出来。
///
/// 而 `_merge` 的「`fresh.accountId == 0` 就保留本地值」把 0 锁死了 ——
/// 摘要行永远给不出非 0 的 `accountId`，0 与 0 合并还是 0。所以这里要钉住
/// 两件事：**新同步进来的行归属要正确**，以及**已经存在的那批 0 要被回填**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() async {
    h = await _Harness.create();
  });

  tearDown(() async => h.dispose());

  test('收信按投递地址归属：切换邮箱后列表不再是空的', () async {
    h.respondLatest(<Map<String, Object?>>[
      // 真实载荷形态：`emailBriefColumns` 里没有 accountId。
      row(emailId: 101, toEmail: 'api-trial-archive@example.net', subject: '归档'),
      row(emailId: 102, toEmail: 'kedong@example.net', subject: '给我的'),
    ]);

    await h.sync();

    final byArchive = await h.mailDao
        .watchMailbox(h.profileId, h.archiveAccountId, type: MailType.receive)
        .first;
    final byKedong = await h.mailDao
        .watchMailbox(h.profileId, h.kedongAccountId, type: MailType.receive)
        .first;

    expect(byArchive.map((m) => m.subject), <String>['归档']);
    expect(byKedong.map((m) => m.subject), <String>['给我的']);
  });

  test('带 +tag 的投递地址退到基址仍能归位', () async {
    h.respondLatest(<Map<String, Object?>>[
      row(emailId: 103, toEmail: 'kedong+news@example.net', subject: '订阅'),
    ]);

    await h.sync();

    final rows = await h.mailDao
        .watchMailbox(h.profileId, h.kedongAccountId, type: MailType.receive)
        .first;
    expect(rows.map((m) => m.emailId), <int>[103]);
  });

  test('发信按发件地址归属（本地 payload 就没带 accountId）', () async {
    h.respondLatest(<Map<String, Object?>>[
      row(
        emailId: 104,
        toEmail: 'someone@example.com',
        sendEmail: 'hello@example.net',
        type: MailType.send,
        subject: '我发的',
      ),
    ]);

    await h.sync();

    final rows = await h.mailDao
        .watchMailbox(h.profileId, h.helloAccountId, type: MailType.send)
        .first;
    expect(rows.map((m) => m.subject), <String>['我发的']);
  });

  test('修复前就已落库的 account_id=0 会被回填（不能只修新数据）', () async {
    // 先造一批「老数据」：直接写库，accountId 留 0 —— 这正是线上已有的形态。
    await h.mailDao.upsertPage(<MailRow>[
      MailRow(
        emailId: 201,
        profileId: h.profileId,
        toEmail: 'api-trial-archive@example.net',
        subject: '修复前收到的',
        type: MailType.receive,
      ),
    ]);
    final before = await h.mailDao.find(h.profileId, 201);
    expect(before!.accountId, 0, reason: '夹具前提：这行确实是「无归属」的');

    h.respondLatest(<Map<String, Object?>>[
      row(emailId: 202, toEmail: 'kedong@example.net', subject: '新来的'),
    ]);
    await h.sync();

    final repaired = await h.mailDao.find(h.profileId, 201);
    expect(repaired!.accountId, h.archiveAccountId,
        reason: '回填只靠它自己的地址，不依赖它是否出现在本次同步的页里');
    expect(repaired.mailboxEmail, 'api-trial-archive@example.net');
  });

  test('回填不越界：地址不属于本实例任何邮箱的行保持 0（别硬塞给某个邮箱）',
      () async {
    await h.mailDao.upsertPage(<MailRow>[
      MailRow(
        emailId: 301,
        profileId: h.profileId,
        toEmail: 'nobody@elsewhere.com',
        subject: '来路不明',
        type: MailType.receive,
      ),
    ]);

    h.respondLatest(<Map<String, Object?>>[
      row(emailId: 302, toEmail: 'kedong@example.net', subject: '新来的'),
    ]);
    await h.sync();

    final untouched = await h.mailDao.find(h.profileId, 301);
    expect(untouched!.accountId, 0);
  });

  test('地址匹配规则本身：精确优先于去 tag，跨域不误配', () {
    final byEmail = <String, int>{
      normalizeEmail('a@example.net'): 1,
      normalizeEmail('a+b@example.net'): 2,
      normalizeEmail('c@other.com'): 3,
    };

    // `a+b@` 是自己一个邮箱时，不能被 `a@` 抢走。
    expect(accountIdForEmail(byEmail, 'A+B@example.net'), 2);
    expect(accountIdForEmail(byEmail, 'a@example.net'), 1);
    // 没有独立条目才退到基址。
    expect(accountIdForEmail(byEmail, 'a+xyz@example.net'), 1);
    expect(accountIdForEmail(byEmail, 'c@other.com'), 3);
    expect(accountIdForEmail(byEmail, 'c@other.net'), isNull);
    expect(accountIdForEmail(byEmail, 'not-an-address'), isNull);
  });
}

// ------------------------------------------------------------------ 夹具

Map<String, Object?> row({
  required int emailId,
  required String toEmail,
  required String subject,
  String sendEmail = '',
  int type = MailType.receive,
}) =>
    <String, Object?>{
      'emailId': emailId,
      'sendEmail': sendEmail,
      'toEmail': toEmail,
      'subject': subject,
      'type': type,
      'status': 0,
      'unread': 0,
      'isDel': 0,
      'createTime': '2026-10-09 10:00:00',
    };

class _Harness {
  _Harness._({
    required this.db,
    required this.mailDao,
    required this.repo,
    required this.profileId,
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

    final profile = await profiles.create(baseUrl: 'https://mail.example.net');
    await profiles.markLoggedIn(
      profile.id,
      userId: 42,
      email: 'kedong@example.net',
      userName: 'kedong',
    );
    await tokens.write(profile.id, 'fake-jwt');
    await db.profileDao.upsertMailboxes(profile.id, <MailboxAccount>[
      const MailboxAccount(
        accountId: 10,
        email: 'kedong@example.net',
        name: 'kedong',
      ),
      const MailboxAccount(
        accountId: 26,
        email: 'api-trial-archive@example.net',
        name: '归档',
        allReceive: 1,
      ),
      const MailboxAccount(
        accountId: 30,
        email: 'hello@example.net',
        name: 'hello',
      ),
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
      profileId: profile.id,
      registry: registry,
      adapter: adapter,
      authEvents: authEvents,
    );

    final runtime = registry.ensure((await profiles.find(profile.id))!);
    await runtime.warmUp();
    return h;
  }

  final AppDatabase db;
  final MailDao mailDao;
  final EmailRepository repo;
  final String profileId;
  final RuntimeRegistry registry;
  final _FakeAdapter adapter;
  final AuthEvents authEvents;

  final int archiveAccountId = 26;
  final int kedongAccountId = 10;
  final int helloAccountId = 30;

  void respondLatest(List<Map<String, Object?>> rows) =>
      adapter.respondJson(<String, Object?>{'code': 200, 'data': rows});

  /// 走真实的收件同步口径：`allReceive: true`（合并视图），游标从 0 起。
  Future<int> sync() async {
    final profile = await ProfileRepository(
      db: db,
      tokens: TokenStore(),
      prefs: PrefsStore(await SharedPreferences.getInstance()),
    ).find(profileId);
    return repo.syncMailbox(
      profile: profile!,
      accountId: kedongAccountId,
      type: MailType.receive,
      allReceive: true,
    );
  }

  Future<void> dispose() async {
    await registry.dispose();
    await authEvents.dispose();
    await db.close();
  }
}

class _FakeAdapter implements HttpClientAdapter {
  Object _body = const <String, Object?>{'code': 200, 'data': <Object?>[]};

  void respondJson(Object body) => _body = body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      await for (final _ in requestStream) {}
    }
    final encoded = utf8.encode(jsonEncode(_body));
    return ResponseBody(
      Stream<Uint8List>.fromIterable(<Uint8List>[Uint8List.fromList(encoded)]),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json;charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
