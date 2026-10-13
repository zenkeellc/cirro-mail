// 这一层存在的理由与仓库里其它 repository 一样：**UI 不直接碰 `accountApi`**。
// 它要负责的是「服务端成功之后，本地跟着做什么」：
//
//   add     → 返回的新行 upsert 进库（列表当场多一行，不必等下一次刷新）
//   remove  → 先删服务端，**成功之后**才动本地（`purgeMailbox` + 逐封清磁盘）
//   setName → 只写服务端（本地靠下一轮 refresh，避免两处真相打架）
//   setAsTop→ 只写服务端 + 重拉一次列表（顺序要跟服务端走）
//
// 「服务端失败时本地一行都不该动」是本组最重要的一条：删错了邮箱
// 是不可恢复的（服务端物理删除）。
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
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/account_repository.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;
  setUp(() async => h = await _Harness.create());
  tearDown(() async => h.dispose());

  test('add：打到 POST /account/add，返回的新行立刻进本地库', () async {
    h.adapter.reply(<String, Object?>{
      'code': 200,
      'data': <String, Object?>{
        'accountId': 77,
        'email': 'new@example.com',
        'name': '',
        'userId': 42,
        'sort': 0,
      },
    });

    final added = await h.accounts.add(h.profile, 'new@example.com');

    expect(added!.accountId, 77);
    final sent = h.adapter.sent.single;
    expect(sent.path, '/account/add');
    expect(sent.method, 'POST');
    expect(sent.body['email'], 'new@example.com');
    // 没开 Turnstile 时**不要**带一个空的 token 字段（服务端会当缺 token 拒）。
    expect(sent.body.containsKey('token'), isFalse);

    expect(
      (await h.accounts.of(h.profile.id)).map((m) => m.accountId),
      contains(77),
      reason: '返回行要落库 —— 用户点完「添加」当场就该在列表里看到它',
    );
  });

  test('add：没拿到行（服务端回了空 data）时不抛，也不写库', () async {
    h.adapter.reply(<String, Object?>{'code': 200, 'data': null});
    expect(await h.accounts.add(h.profile, 'x@example.com'), isNull);
    expect(
      (await h.accounts.of(h.profile.id)).map((m) => m.accountId),
      isNot(contains(0)),
    );
  });

  test('remove：先删服务端，成功后才清本地（邮件 + 附件记录 + 邮箱行）', () async {
    await h.seedMail(emailId: 601, accountId: h.targetId);
    h.adapter.reply(<String, Object?>{'code': 200, 'data': null});

    await h.accounts.remove(h.profile, h.targetId);

    final sent = h.adapter.sent.single;
    expect(sent.path, '/account/delete');
    expect(sent.method, 'DELETE');
    expect(sent.query['accountId'], h.targetId);
    expect(await h.db.mailDao.find(h.profile.id, 601), isNull);
    expect(
      (await h.accounts.of(h.profile.id)).map((m) => m.accountId),
      isNot(contains(h.targetId)),
    );
    expect(h.purgedDisk, <int>[601],
        reason: 'purgeMailbox 返回的 emailId 要逐封传给 onDiskPurge');
  });

  test('remove：归属 0 的老信按地址兜底，磁盘附件目录也要清（onDiskPurge 带上它）',
      () async {
    // 这封信 `account_id = 0`（同步时反查不到投递邮箱），但 `toEmail` 指向
    // 目标邮箱 —— 端到端验「删邮箱 → purgeMailbox 认出它 → onDiskPurge 收得到」。
    await h.db.mailDao.upsertPage(<MailRow>[
      MailRow(
        emailId: 603,
        profileId: h.profile.id,
        accountId: 0,
        toEmail: 'kedong@example.net',
        type: MailType.receive,
        subject: '归属未知的老信',
      ),
    ]);
    h.adapter.reply(<String, Object?>{'code': 200, 'data': null});

    await h.accounts.remove(h.profile, h.targetId);

    expect(await h.db.mailDao.find(h.profile.id, 603), isNull);
    expect(h.purgedDisk, contains(603),
        reason: '返回的 emailId 要含这封老信 —— 否则它的磁盘附件目录永远没人清');
  });

  test('remove：服务端失败时本地一行都不动', () async {
    await h.seedMail(emailId: 602, accountId: h.targetId);
    h.adapter.reply(<String, Object?>{'code': 501, 'message': '该邮箱不存在'});

    await expectLater(
      h.accounts.remove(h.profile, h.targetId),
      throwsA(isA<Exception>()),
    );

    expect(await h.db.mailDao.find(h.profile.id, 602), isNotNull,
        reason: '服务端没删成，本地就一行都不该动 —— 重建比误删便宜得多');
    expect(
      (await h.accounts.of(h.profile.id)).map((m) => m.accountId),
      contains(h.targetId),
    );
    expect(h.purgedDisk, isEmpty);
  });

  test('setName：PUT /account/setName，body 带 accountId 与 name', () async {
    h.adapter.reply(<String, Object?>{'code': 200, 'data': null});
    await h.accounts.setName(h.profile, h.targetId, '小号');
    final sent = h.adapter.sent.single;
    expect(sent.path, '/account/setName');
    expect(sent.method, 'PUT');
    expect(sent.body, <String, Object?>{
      'accountId': h.targetId,
      'name': '小号',
    });
  });

  test('setAsTop：PUT /account/setAsTop，然后重拉一次列表', () async {
    h.adapter
      ..reply(<String, Object?>{'code': 200, 'data': null})
      ..thenList(<Map<String, Object?>>[
        <String, Object?>{
          'accountId': h.targetId,
          'email': 'kedong@example.net',
          'sort': 3,
        },
        <String, Object?>{
          'accountId': h.primaryId,
          'email': 'admin@example.net',
          'sort': 4,
        },
      ]);

    await h.accounts.setAsTop(h.profile, h.targetId);

    expect(h.adapter.sent.first.path, '/account/setAsTop');
    expect(h.adapter.sent.first.method, 'PUT');
    expect(
      h.adapter.sent.map((r) => r.path),
      contains('/account/list'),
      reason: '置顶之后顺序要跟服务端走，本地不自己算',
    );
    // 重拉之后的本地顺序 = 服务端给的顺序（本地只管排序方向）。
    expect(
      (await h.accounts.of(h.profile.id)).map((m) => m.accountId),
      <int>[h.primaryId, h.targetId],
    );
  });

  // 下面两条钉的是 `_readyRuntime` 的两条**防御分支**（`account_repository.dart`
  // 216-220 行）。删掉 `|| runtime.isDisposed`、或整条早退判断，此前这六条
  // 用例都不会响 —— 于是「拿不到可用 runtime 时静默不做」这条约定其实没人守。

  test('四个管理动作：runtime 缺失（peek 为 null）时静默早退，一个请求都不发', () async {
    // 造「runtime 缺失」：把已经建好的这条丢弃（与登出 / 删实例同一条路径），
    // 之后 `registry.peek(id)` 回到 null —— 与「从未 ensure 过」等价。
    h.registry.discard(h.profile.id);
    expect(h.registry.peek(h.profile.id), isNull);

    // add 应当静默返回 null（拿不到 runtime 就造不出行）。
    expect(await h.accounts.add(h.profile, 'x@example.com'), isNull);
    // 其余三个应当正常完成、不抛。
    await h.accounts.remove(h.profile, h.targetId);
    await h.accounts.setName(h.profile, h.targetId, '小号');
    await h.accounts.setAsTop(h.profile, h.targetId);

    expect(
      h.adapter.sent,
      isEmpty,
      reason: '没有 runtime 时四个动作都该静默早退 —— 不能凭空发请求（连 setAsTop '
          '里那次 refresh 的重拉也不该发生）',
    );
  });

  test('四个管理动作：runtime 已 dispose 时同样静默早退，一个请求都不发', () async {
    final runtime = h.registry.peek(h.profile.id)!;
    runtime.dispose();
    expect(runtime.isDisposed, isTrue);
    // 关键：`dispose()` **不会**把它移出 `_runtimes`，所以 `peek` 仍返回这条
    // —— 此刻唯一能拦下四个动作的就是 `runtime.isDisposed` 那一半判断。
    expect(h.registry.peek(h.profile.id), same(runtime));

    expect(await h.accounts.add(h.profile, 'y@example.com'), isNull);
    await h.accounts.remove(h.profile, h.targetId);
    await h.accounts.setName(h.profile, h.targetId, '小号');
    await h.accounts.setAsTop(h.profile, h.targetId);

    expect(
      h.adapter.sent,
      isEmpty,
      reason: 'runtime 已经 dispose（Dio 被关、在途请求被取消），动作必须早退，'
          '不能拿一条关掉的 Dio 去打请求',
    );
  });
}

class _Sent {
  _Sent({
    required this.path,
    required this.method,
    required this.query,
    required this.body,
  });

  final String path;
  final String method;
  final Map<String, dynamic> query;
  final Map<String, dynamic> body;
}

class _Harness {
  _Harness._({
    required this.db,
    required this.accounts,
    required this.profile,
    required this.adapter,
    required this.purgedDisk,
    required this.registry,
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
    final adapter = _RoutingAdapter();

    final registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      buildApiDio: (profile) => DioFactory.build(
        userApi: profile.baseUrl,
        profileId: profile.id,
        authEvents: authEvents,
        readToken: () => 'fake-jwt',
        readLanguage: () => 'zh',
      )..httpClientAdapter = adapter,
    );

    final created = await profiles.create(baseUrl: 'https://mail.example.net');
    await profiles.markLoggedIn(
      created.id,
      userId: 42,
      email: 'admin@example.net',
      userName: 'admin',
    );
    await db.profileDao.upsertMailboxes(created.id, <MailboxAccount>[
      const MailboxAccount(
        accountId: 3,
        email: 'admin@example.net',
        name: 'admin',
        sort: 4,
      ),
      const MailboxAccount(
        accountId: 8,
        email: 'kedong@example.net',
        sort: 3,
      ),
    ]);

    final purgedDisk = <int>[];
    final h = _Harness._(
      db: db,
      accounts: AccountRepository(
        db: db,
        registry: registry,
        capabilities: CapabilityRepository(db),
        onDiskPurge: (_, emailId) async => purgedDisk.add(emailId),
      ),
      profile: (await profiles.find(created.id))!,
      adapter: adapter,
      purgedDisk: purgedDisk,
      registry: registry,
      authEvents: authEvents,
    );
    // 首次请求前必须 await 一次 warmUp，否则首个请求会不带 token。
    await registry.ensure(h.profile).warmUp();
    return h;
  }

  final AppDatabase db;
  final AccountRepository accounts;
  final Profile profile;
  final _RoutingAdapter adapter;
  final List<int> purgedDisk;
  final RuntimeRegistry registry;
  final AuthEvents authEvents;

  int get targetId => 8;
  int get primaryId => 3;

  Future<void> seedMail({required int emailId, required int accountId}) =>
      db.mailDao.upsertPage(<MailRow>[
        MailRow(
          emailId: emailId,
          profileId: profile.id,
          accountId: accountId,
          type: MailType.receive,
          subject: '会被删掉的信',
        ),
      ]);

  Future<void> dispose() async {
    await registry.dispose();
    await authEvents.dispose();
    await db.close();
  }
}

/// 按路径分发的假适配器：`/account/list` 回 `thenList` 那批，其余回 `reply`。
class _RoutingAdapter implements HttpClientAdapter {
  final List<_Sent> sent = <_Sent>[];
  Object _body = const <String, Object?>{'code': 200, 'data': null};
  Object _listBody = const <String, Object?>{'code': 200, 'data': <Object?>[]};

  void reply(Object body) => _body = body;
  void thenList(Object rows) => _listBody = <String, Object?>{'code': 200, 'data': rows};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path.replaceFirst('/api', '');
    sent.add(_Sent(
      path: path,
      method: options.method,
      query: options.queryParameters,
      // `DELETE` 的入参走 query、其余走 body（见 `account_api.dart`）。
      body: options.data is Map
          ? (options.data as Map).cast<String, dynamic>()
          : const <String, dynamic>{},
    ));
    final body = path == '/account/list' ? _listBody : _body;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
