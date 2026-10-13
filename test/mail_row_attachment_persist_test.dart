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
import 'package:mail_app/data/models/mail_attachment.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「一页响应里带回来的附件要落库」。
///
/// 这条链路上丢过附件：`_persist` 只写 `mails` 表，附件被直接丢掉。
/// 而**没有任何别的东西会来补**：`backfillBodies` 只挑 `hasFullBody == false`
/// 的行，而这一页的行早就是 `true` 了。所以开着「后台预取完整正文」
/// （`prefetchFull`，默认开）时，这些附件永远不会落库 ——
/// 表现是详情页的附件面板一片空白，列表上的附件标记也永远不出现。
///
/// 这里走的是真实的冷启动路径（游标 0 → `full=1` 拉第一页），不是直接调
/// `_persist`：那条路径本身没有对外入口，能钉住它的只有「同步一轮之后库里
/// 有没有」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() async {
    h = await _Harness.create();
  });

  tearDown(() async => h.dispose());

  test('预取路径带回来的 attList 要写进 attachments 表', () async {
    h.respondPage(<Map<String, Object?>>[
      _row(emailId: 101, subject: '带附件', attList: <Map<String, Object?>>[
        _att(attId: 900, emailId: 101, filename: '报价单.pdf'),
        _att(attId: 901, emailId: 101, filename: '合同.docx'),
      ]),
      _row(emailId: 102, subject: '没附件'),
    ]);

    await h.sync();

    final stored = await h.mailDao.attachmentsOf(h.profileId, 101);
    expect(stored.map((a) => a.filename), <String>['报价单.pdf', '合同.docx'],
        reason: '预取那一页是 full=1 拉的，附件必须跟着落库 —— '
            '没有别的路径会回来补它们');
    expect(await h.mailDao.attachmentsOf(h.profileId, 102), isEmpty);
  });

  test('附件数进列表行：摘要行不显示，同步齐了才显示', () async {
    h.respondPage(<Map<String, Object?>>[
      _row(emailId: 101, subject: '带附件', attList: <Map<String, Object?>>[
        _att(attId: 900, emailId: 101, filename: 'a.pdf'),
      ]),
    ]);

    await h.sync();

    final rows = await h.mailDao.watchMailboxSet().first;
    final row = rows.singleWhere((r) => r.emailId == 101);
    expect(row.hasFullBody, isTrue, reason: '预取开着，这一页就是完整版');
    expect(row.attachmentCount, 1);

    // 再写一封「只有摘要」的行：附件数还不该有值。
    await h.mailDao.upsertPage(<MailRow>[
      MailRow(
        emailId: 103,
        profileId: h.profileId,
        toEmail: 'kedong@example.net',
        subject: '还没补正文的',
        type: MailType.receive,
      ),
    ]);
    final after = await h.mailDao.watchMailboxSet().first;
    final brief = after.singleWhere((r) => r.emailId == 103);
    expect(brief.hasFullBody, isFalse);
    expect(brief.attachmentCount, 0,
        reason: '摘要行的 0 是「还不知道」—— UI 靠 hasFullBody 区分');
  });

  test('附件后来才下下来时，列表那条流会自己再发一次', () async {
    h.respondPage(<Map<String, Object?>>[
      _row(emailId: 101, subject: '带附件'),
    ]);
    await h.sync();

    final stream = h.mailDao.watchMailboxSet();
    final seen = <int>[];
    final sub = stream.listen((rows) {
      if (rows.isNotEmpty) seen.add(rows.first.attachmentCount);
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.last, 0);

    // 附件是**另一条**路径写进来的（补正文那一趟顺带带回附件）。
    await h.mailDao.upsertAttachments(h.profileId, 101, <MailAttachment>[
      const MailAttachment(
        attId: 900,
        emailId: 101,
        key: 'attachments/900',
        filename: 'a.pdf',
      ),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(seen.last, 1,
        reason: '子查询读的表变了，drift 要重新发一次 —— '
            '数不对的话列表上那个标记永远不会出现');
    await sub.cancel();
  });
}

// ------------------------------------------------------------------ 夹具

Map<String, Object?> _row({
  required int emailId,
  required String subject,
  List<Map<String, Object?>> attList = const <Map<String, Object?>>[],
}) =>
    <String, Object?>{
      'emailId': emailId,
      'sendEmail': '',
      'name': '张三',
      'toEmail': 'kedong@example.net',
      'subject': subject,
      'type': MailType.receive,
      'status': 0,
      'unread': 0,
      'isDel': 0,
      'createTime': '2026-10-09 10:00:00',
      // `full=1` 的响应才有这两个字段 —— `MailRow.fromJson` 正是拿它们
      // 判断「这一行是完整版」。
      'content': '<p>hi</p>',
      'attList': attList,
    };

Map<String, Object?> _att({
  required int attId,
  required int emailId,
  required String filename,
}) =>
    <String, Object?>{
      'attId': attId,
      'emailId': emailId,
      'key': 'attachments/$attId',
      'filename': filename,
      'mimeType': 'application/pdf',
      'size': 1024,
      'type': 0,
    };

class _Harness {
  _Harness._({
    required this.db,
    required this.mailDao,
    required this.repo,
    required this.profileId,
    required this.accountId,
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
      accountId: 10,
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
  final int accountId;
  final RuntimeRegistry registry;
  final _FakeAdapter adapter;
  final AuthEvents authEvents;

  /// 返回 `/email/list` 的一页（`full=1` 形态：带 `content` 与 `attList`）。
  void respondPage(List<Map<String, Object?>> rows) => adapter.respondJson(
        <String, Object?>{
          'code': 200,
          'data': <String, Object?>{
            'list': rows,
            'total': rows.length,
            'latestEmail': <String, Object?>{
              'emailId': rows.isEmpty ? 0 : rows.first['emailId'],
              'accountId': accountId,
              'userId': 42,
            },
          },
        },
      );

  /// 冷启动路径：本地没有游标 → 走「拉第一页建立基线」那一支，
  /// `full` 取 `prefs.prefetchFull`（默认 true）。
  Future<int> sync() async {
    final profile = await ProfileRepository(
      db: db,
      tokens: TokenStore(),
      prefs: PrefsStore(await SharedPreferences.getInstance()),
    ).find(profileId);
    return repo.syncMailbox(
      profile: profile!,
      accountId: accountId,
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
