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
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「点开邮件要等很久才变已读」的回归测试。
///
/// 病根是把本地落盘串在了两个网络往返**之后**（`PUT /email/read` 与
/// `GET /email/list?full=1`）。UI 全部 watch 本地 drift 流，所以在那之前列表
/// 加粗、未读角标、详情顶栏一个都不动 —— 用户感知就是「点了没反应」。
///
/// 三件事要钉住：
/// 1. **PUT 还没返回时，本地已经是已读了**（主诉求）；
/// 2. **失败会回滚**，而且回滚不会把更新的那次操作抹掉；
/// 3. 服务端那一趟确实发出去了，body 是对的（`{emailIds:[id]}`）。
///
/// 夹的是一个**可控响应**的假适配器：请求停在半空中，断言此时本地库的状态 ——
/// 这是唯一能看到「服务端还没答」这个瞬间的办法。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const emailId = 701;

  late _Harness h;

  setUp(() async {
    h = await _Harness.create();
  });

  tearDown(() async => h.dispose());

  /// 一页收信方向的行（未读）。`emailId` 之外的内容无所谓，只为让本地有行。
  Future<void> seedUnread() => h.mailDao.upsertPage(<MailRow>[
        MailRow(
          emailId: emailId,
          profileId: h.profileId,
          toEmail: 'me@example.net',
          subject: '没读过的信',
          type: MailType.receive,
          accountId: 3,
          mailboxEmail: 'me@example.net',
          hasFullBody: true,
          content: '<p>正文</p>',
          text: '正文',
        ),
      ]);

  MailRef mailRef() => MailRef(profileId: h.profileId, emailId: emailId);

  Future<bool> isUnread() async =>
      (await h.mailDao.find(h.profileId, emailId))!.isUnread;

  test('PUT 还没返回时本地已经是已读（不再等网络）', () async {
    await seedUnread();
    h.adapter.holdNext(); // 让 /email/read 停在半空。

    // 故意不 await：模拟「用户刚点开」的那一瞬间。
    final opening = h.repo.openMail(mailRef());

    // 给本地那一趟写库一点时间（它是纯 SQLite，不涉及网络）。
    await h.settleLocal();

    expect(
      await isUnread(),
      isFalse,
      reason: '本地落盘必须发生在 PUT 返回之前 —— 这就是那半秒延迟的来源',
    );

    h.adapter.release();
    await opening;
  });

  test('网络失败：本地先读后回滚，最终仍是未读，且 openMail 不抛', () async {
    await seedUnread();
    h.adapter.failNext();

    // 打开一封信不该因为标已读失败而失败（详情页照常渲染）。
    await h.repo.openMail(mailRef());

    expect(await isUnread(), isTrue, reason: '服务端没收到，本地不该留在已读');
  });

  test('超时回滚后，下一轮同步带回 unread=1 就自愈（PUT 是幂等的）', () async {
    await seedUnread();
    h.adapter.failNext();

    await h.repo.openMail(mailRef());
    expect(await isUnread(), isTrue, reason: '夹具前提：这次确实回滚了');

    // 服务端其实收到了（超时只是回执没回来），下一轮同步把它带回来。
    h.adapter.respond((options, body) async {
      if (options.path.contains('/email/read')) return h.ok();
      return h.ok(data: <Object?>[
        <String, Object?>{
          'emailId': emailId,
          'toEmail': 'me@example.net',
          'subject': '没读过的信',
          'type': MailType.receive,
          'status': 0,
          'unread': UnreadState.read,
          'isDel': 0,
          'createTime': '2026-10-09 10:00:00',
        },
      ]);
    });
    await h.sync();

    expect(await isUnread(), isFalse, reason: '服务端的 1 能把本地抬回已读');
  });

  test('打开后灌入陈旧未读页，本地不回弹', () async {
    await seedUnread();
    h.adapter.respond((options, body) async => h.ok());

    await h.repo.openMail(mailRef());
    expect(await isUnread(), isFalse);

    // 一个「取页早于 PUT 返回」的页：服务端那行还是 0。
    await h.mailDao.upsertPage(<MailRow>[
      MailRow(
        emailId: emailId,
        profileId: h.profileId,
        toEmail: 'me@example.net',
        subject: '没读过的信',
        type: MailType.receive,
        accountId: 3,
        mailboxEmail: 'me@example.net',
      ),
    ]);

    expect(await isUnread(), isFalse, reason: '陈旧页不能把已读打回未读');
  });

  test('请求确实发出去了，body 是 {emailIds:[id]}', () async {
    await seedUnread();
    h.adapter.respond((options, body) async => h.ok());

    await h.repo.openMail(mailRef());

    final sent = h.adapter.sentReadRequests;
    expect(sent, hasLength(1), reason: '标已读必须真的发给服务端');
    expect(sent.single.path, contains('/email/read'));
    expect(sent.single.method, 'PUT');
    final decoded = jsonDecode(utf8.decode(sent.single.bodyBytes));
    expect(decoded, <String, Object?>{
      'emailIds': <int>[emailId],
    });
  });

  test('详情菜单「标记已读」：未读点的这一下真的写成已读', () async {
    // 这一条覆盖的是菜单里那个 `read: row.isUnread` 的取值 —— 它原来写的是
    // `!row.isUnread`，于是「未读那封点标记已读」什么都没发生。
    await seedUnread();
    h.adapter.respond((options, body) async => h.ok());

    await h.repo.markRead(<MailRef>[mailRef()], read: await isUnread());

    expect(await isUnread(), isFalse);
    expect(h.adapter.sentReadRequests, hasLength(1));
  });

  test('并发：A 失败的回滚不覆盖 B 的成功', () async {
    await seedUnread();
    h.adapter.failNext();

    // A：会失败的那次（打开邮件那条路）。
    final a = h.repo.openMail(mailRef());
    // B：紧接着又来一次成功的标已读，世代号被推进。
    h.adapter.respond((options, body) async => h.ok());
    final b = h.repo.markRead(<MailRef>[mailRef()], read: true);

    await Future.wait<void>(<Future<void>>[a, b]);

    expect(
      await isUnread(),
      isFalse,
      reason: 'A 的回滚只该管它自己那一代；B 已经成功标上了',
    );
  });
}

// ------------------------------------------------------------------ 夹具

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
      email: 'me@example.net',
      userName: 'me',
    );
    await tokens.write(profile.id, 'fake-jwt');
    await db.profileDao.upsertMailboxes(profile.id, <MailboxAccount>[
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

  /// 信封：成功。
  Map<String, Object?> ok({Object? data}) =>
      <String, Object?>{'code': 200, 'message': 'success', 'data': data};

  /// 让「本地写库那一趟」跑完。客户端逻辑是 `await db.markRead(...)` 之后才
  /// 发请求，所以只要让出几轮事件循环就够 —— 刻意**不**依赖固定时长。
  Future<void> settleLocal() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 走真实收件同步那一趟（用 `/email/list` 而不是 `/email/latest`，
  /// 这样一次响应就能覆盖 `syncMailbox` 冷启动分支）。
  Future<void> sync() async {
    final profile = await ProfileRepository(
      db: db,
      tokens: TokenStore(),
      prefs: PrefsStore(await SharedPreferences.getInstance()),
    ).find(profileId);
    await repo.syncMailbox(
      profile: profile!,
      accountId: 3,
      type: MailType.receive,
    );
  }

  Future<void> dispose() async {
    await registry.dispose();
    await authEvents.dispose();
    await db.close();
  }
}

/// 一次被记下来的请求。
class _SentRequest {
  _SentRequest({
    required this.path,
    required this.method,
    required this.bodyBytes,
  });

  final String path;
  final String method;
  final List<int> bodyBytes;
}

/// 可控响应的假适配器。
///
/// 比 `mailbox_attribution_test.dart` 那个多了两件本次测试必需的能力：
/// - **hold / release**：把请求停在半空中，断言「服务端还没答」时本地的状态；
/// - **failNext**：让下一次请求以传输错误失败（模拟断网/超时）。
class _FakeAdapter implements HttpClientAdapter {
  Future<Object?> Function(RequestOptions, List<int>)? _handler;
  Object? _failure;

  /// 非 null 时请求挂在这里等 [release]。
  Completer<void>? _gate;

  final List<_SentRequest> sentReadRequests = <_SentRequest>[];

  void respond(Future<Object?> Function(RequestOptions, List<int>) handler) {
    _handler = handler;
    _failure = null;
  }

  /// 下一次请求停下来，直到 [release]。
  void holdNext() => _gate = Completer<void>();

  void release() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// 下一次请求以传输错误失败。
  void failNext() {
    _failure = DioException.connectionError(
      requestOptions: RequestOptions(path: '/email/read'),
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
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }

    if (options.path.contains('/email/read')) {
      sentReadRequests.add(_SentRequest(
        path: options.path,
        method: options.method,
        bodyBytes: bytes,
      ));
    }

    final gate = _gate;
    if (gate != null) await gate.future;

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
  }

  @override
  void close({bool force = false}) {}
}
