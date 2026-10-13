import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/error/app_exception.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/network/dio_factory.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/send_payload.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/data/repositories/send_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 发信链路：`SendRepository.sendNow` → `EmailApi.sendStream`
/// → **dio 真正写到线上的那些字节**。
///
/// 这里要钉住的是三件「只有到适配器那一层才看得见」的事：
///
/// 1. **`Content-Length` 与真实 body 长度相等**。发信 body 是流式的，
///    dio 推断不出长度，所以由 `StreamBodyBuilder.contentLength` 显式算。
///    算小了服务端会**截断**请求体（症状是 JSON 解析失败，极难查），
///    算大了请求会挂住等永远不来的字节。所以断言的是适配器收到的
///    `contentLength` 与它实际读到的字节数。
/// 2. **body 是真 JSON，且附件是裸 base64**（带 `data:` 前缀会解出垃圾）。
/// 3. **outbox 的重试分类**：确定没送达的（连不上）会重试，
///    可能已经送达的（超时）**不会** —— `/email/send` 没有幂等键。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness harness;

  setUp(() async {
    harness = await _Harness.create();
  });

  test('发一封带附件的信：Content-Length 与真实字节相等，body 是合法 JSON', () async {
    final bytes = List<int>.generate(1000, (i) => i % 251);
    final att = await harness.seedAttachmentFile('报价单.pdf', bytes);
    harness.respondWithCreated(accountId: 3, sendEmail: 'me@example.net');

    final payload = harness.payload(
      attachments: <SendAttachment>[
        SendAttachment(
          path: att.path,
          filename: '报价单.pdf',
          size: bytes.length,
          mimeType: 'application/pdf',
        ),
      ],
    );

    final rows = await harness.send.sendNow(
      payload,
      profileId: harness.profileId,
    );

    expect(rows, hasLength(1), reason: '服务端返回的行要落进本地库');

    final sent = harness.adapter.lastRequest!;
    expect(
      sent.declaredLength,
      sent.bodyBytes.length,
      reason: 'Content-Length 必须与真实 body 长度一致，'
          '不然服务端会截断或多等字节',
    );

    final decoded = jsonDecode(utf8.decode(sent.bodyBytes)) as Map<String, dynamic>;
    expect(decoded['accountId'], 3);
    expect(decoded['sendEmail'], 'me@example.net');
    expect(decoded['receiveEmail'], <String>['to@example.com']);
    expect(decoded['content'], '<p>正文</p>');

    final attachments = decoded['attachments'] as List<dynamic>;
    expect(attachments, hasLength(1));
    final first = attachments.single as Map<String, dynamic>;
    expect(first['filename'], '报价单.pdf');
    expect(first['content'], base64.encode(bytes));
    expect(first['content'], isNot(contains('data:')));
    // 两个 mime 字段都要（Resend 路径读 contentType，saveSendAttr 读 type）。
    expect(first['contentType'], 'application/pdf');
    expect(first['type'], 'application/pdf');

    // 附件行也要落库（详情页的附件面板）。
    final stored = await harness.db.mailDao.attachmentsOf(
      harness.profileId,
      900,
    );
    expect(stored, isNotEmpty);
  });

  test('多个附件：body 合法、长度仍然精确（逗号不会多也不会少）', () async {
    final a = await harness.seedAttachmentFile('a.bin', const <int>[1, 2, 3]);
    final b = await harness.seedAttachmentFile('b.bin', const <int>[4, 5]);
    final c = await harness.seedAttachmentFile('c.bin', const <int>[]);
    harness.respondWithCreated();

    await harness.send.sendNow(
      harness.payload(
        attachments: <SendAttachment>[
          SendAttachment(path: a.path, filename: 'a.bin', size: 3, mimeType: 'application/octet-stream'),
          SendAttachment(path: b.path, filename: 'b.bin', size: 2, mimeType: 'application/octet-stream'),
          SendAttachment(path: c.path, filename: 'c.bin', size: 0, mimeType: 'application/octet-stream'),
        ],
      ),
      profileId: harness.profileId,
    );

    final sent = harness.adapter.lastRequest!;
    expect(sent.declaredLength, sent.bodyBytes.length);
    final decoded = jsonDecode(utf8.decode(sent.bodyBytes)) as Map<String, dynamic>;
    expect(decoded['attachments'], hasLength(3));
  });

  test('本地校验不过的信根本不发出去（服务端会在插库之后才拦，会留脏行）', () async {
    harness.respondWithCreated();

    // 11 个附件 —— 服务端上限是 10。
    final attachments = <SendAttachment>[];
    for (var i = 0; i < 11; i++) {
      final f = await harness.seedAttachmentFile('f$i.bin', const <int>[1]);
      attachments.add(
        SendAttachment(path: f.path, filename: 'f$i.bin', size: 1, mimeType: 'application/octet-stream'),
      );
    }

    await expectLater(
      harness.send.sendNow(
        harness.payload(attachments: attachments),
        profileId: harness.profileId,
      ),
      throwsA(
        isA<SendValidationException>().having(
          (e) => e.reasons,
          'reasons',
          contains('附件最多 10 个'),
        ),
      ),
    );

    expect(harness.adapter.lastRequest, isNull, reason: '校验没过就不该发请求');
  });

  test('收件人为空的信也拦在本地', () async {
    harness.respondWithCreated();
    await expectLater(
      harness.send.sendNow(
        harness.payload(recipients: const <String>['  ']),
        profileId: harness.profileId,
      ),
      throwsA(
        isA<SendValidationException>().having(
          (e) => e.reasons,
          'reasons',
          contains('请至少填写一个收件人'),
        ),
      ),
    );
    expect(harness.adapter.lastRequest, isNull);
  });

  group('outbox 的重试分类', () {
    test('网络不通 → 入队后留在 pending（下次会自动重试）', () async {
      harness.failWith(
        DioException.connectionError(
          requestOptions: RequestOptions(path: '/email/send'),
          reason: 'connection refused',
        ),
      );

      await expectLater(
        harness.send.sendNow(harness.payload(), profileId: harness.profileId),
        throwsA(isA<NetworkException>()),
      );

      // 调用方（写邮件页）在「确定没发出去」时入队。
      final id = await harness.send.enqueue(
        harness.payload(),
        profileId: harness.profileId,
      );
      await harness.send.flush(profileIds: <String>[harness.profileId]);

      final entry = await harness.outboxEntry(id);
      expect(entry, isNotNull);
      expect(
        entry!.status,
        'pending',
        reason: '连不上 = 确定没送达，可以安全自动重试',
      );
      expect(entry.attempts, 1);
    });

    test('请求超时 → 标成 failed（等用户确认，不自动重发）', () async {
      // `/email/send` 没有幂等键：超时可能已经发出去了，自动重试 = 重复投递。
      harness.failWith(
        DioException.receiveTimeout(
          requestOptions: RequestOptions(path: '/email/send'),
          timeout: const Duration(seconds: 1),
        ),
      );

      final id = await harness.send.enqueue(
        harness.payload(),
        profileId: harness.profileId,
      );
      await harness.send.flush(profileIds: <String>[harness.profileId]);

      final entry = await harness.outboxEntry(id);
      expect(entry, isNotNull);
      expect(
        entry!.status,
        'failed',
        reason: '超时可能已经送达，绝不能自动重发',
      );
      expect(entry.lastError, isNotNull);
    });

    test('服务端业务拒绝（403 配额）→ permanent failed', () async {
      harness.respondEnvelope(<String, Object?>{
        'code': 403,
        'message': '今日发信额度已用完',
      });
      final id = await harness.send.enqueue(
        harness.payload(),
        profileId: harness.profileId,
      );
      await harness.send.flush(profileIds: <String>[harness.profileId]);

      final entry = await harness.outboxEntry(id);
      expect(entry!.status, 'failed');
      expect(entry.lastError, contains('额度'));
    });

    test('发送成功 → outbox 条目被删掉（不留「待发」的假象）', () async {
      harness.respondWithCreated();
      final id = await harness.send.enqueue(
        harness.payload(),
        profileId: harness.profileId,
      );
      await harness.send.flush(profileIds: <String>[harness.profileId]);

      expect(await harness.outboxEntry(id), isNull);
      expect(
        await harness.send.attentionCount(),
        0,
      );
    });

    test('一条坏记录不会把整个发件箱堵死', () async {
      // 草稿 JSON 损坏（比如附件路径被清过、库被手改过）。
      harness.respondWithCreated();
      final badId = await harness.db.localDao.enqueue(
        profileId: harness.profileId,
        payloadJson: '{不是合法 JSON',
      );
      final goodId = await harness.send.enqueue(
        harness.payload(),
        profileId: harness.profileId,
      );

      await harness.send.flush(profileIds: <String>[harness.profileId]);

      final bad = await harness.outboxEntry(badId);
      expect(bad!.status, 'failed', reason: '坏记录要就地判死，而不是一直重试');
      expect(await harness.outboxEntry(goodId), isNull, reason: '后面那封照发');
    });

    test('附件文件在排队期间被删 → 判死，而不是每次同步都失败一次', () async {
      final att = await harness.seedAttachmentFile('gone.bin', const <int>[1]);
      final id = await harness.send.enqueue(
        harness.payload(
          attachments: <SendAttachment>[
            SendAttachment(
              path: att.path,
              filename: 'gone.bin',
              size: 1,
              mimeType: 'application/octet-stream',
            ),
          ],
        ),
        profileId: harness.profileId,
      );

      await att.delete();
      await harness.send.flush(profileIds: <String>[harness.profileId]);

      final entry = await harness.outboxEntry(id);
      expect(entry!.status, 'failed');
      expect(entry.attempts, 1, reason: '只试一次，不做无谓的循环');
    });

    test('进程被杀留下的 sending 孤儿会被退回 pending', () async {
      final id = await harness.send.enqueue(
        harness.payload(),
        profileId: harness.profileId,
      );
      await harness.db.localDao.markSending(id);

      expect(await harness.send.recoverStuck(), 1);
      expect((await harness.outboxEntry(id))!.status, 'pending');
    });

    test('角标数的是「需要留意的信」，不是「会自动重试的信」', () async {
      // 一封能自动发的、一封超时（可能已送达）、一封判死的 —— 三封都还躺在
      // 发件箱里，角标就得是 3。只数 pending 的话，用户在界面上完全看不出
      // 有一封超时的信可能已经发出去了。
      harness.respondWithCreated();
      await harness.send.enqueue(harness.payload(), profileId: harness.profileId);
      final timedOut = await harness.send.enqueue(
        harness.payload(),
        profileId: harness.profileId,
      );
      await harness.db.localDao.markFailed(timedOut, '请求超时', permanent: true);

      expect(await harness.send.attentionCount(), 2, reason: 'pending 1 + failed 1');

      final last = await harness.send.enqueue(
        harness.payload(),
        profileId: harness.profileId,
      );
      expect(await harness.send.attentionCount(), 3);

      // 发出去（或用户删掉）之后才从角标里消失。
      await harness.send.discard(last);
      expect(await harness.send.attentionCount(), 2);
    });
  });

  // 「发送后一分钟内还能反悔」：`/email/send` 没有定时发送，延迟整个在客户端做——
  // 到点之前这封信只是本地的一行，`nextPending` 挑不到它，一个字节都不会出去。
  group('发送队列（延迟发送）', () {
    test('计划时间还没到的信，flush 一个字节都不发', () async {
      harness.respondWithCreated();
      final id = await harness.send.enqueueScheduled(
        harness.payload(),
        profileId: harness.profileId,
        delay: const Duration(minutes: 1),
      );

      final sent = await harness.send.flush(
        profileIds: <String>[harness.profileId],
      );

      expect(sent, 0);
      expect(
        harness.adapter.lastRequest,
        isNull,
        reason: '到点之前不该有任何请求 —— 这是「后悔」窗口存在的前提',
      );
      final entry = await harness.outboxEntry(id);
      expect(entry!.status, 'pending', reason: '还在队列里等着，不是判死');
      expect(entry.scheduledAt, isNotNull);
      expect(await harness.send.scheduledCount(), 1);
    });

    test('计划时间已过的信照常发出', () async {
      harness.respondWithCreated();
      final id = await harness.send.enqueue(
        harness.payload(),
        profileId: harness.profileId,
        scheduledAt: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      );

      await harness.send.flush(profileIds: <String>[harness.profileId]);

      expect(await harness.outboxEntry(id), isNull, reason: '发出了，条目被删');
      expect(await harness.send.scheduledCount(), 0);
    });

    test('sendDueNow 清掉计划时间并立刻发出', () async {
      harness.respondWithCreated();
      final id = await harness.send.enqueueScheduled(
        harness.payload(),
        profileId: harness.profileId,
        delay: const Duration(minutes: 5),
      );

      expect(await harness.send.sendDueNow(id), isTrue);

      expect(harness.adapter.lastRequest, isNotNull, reason: '绕过了计划时间');
      expect(await harness.outboxEntry(id), isNull);
    });

    test('nextScheduledAt 给出最近一封的发送时刻（微标签倒计时用）', () async {
      // 两封不同排期，取最早的那个 —— 微标签上的倒计时要跟第一封对上。
      await harness.send.enqueueScheduled(
        harness.payload(),
        profileId: harness.profileId,
        delay: const Duration(minutes: 5),
      );
      await harness.send.enqueueScheduled(
        harness.payload(),
        profileId: harness.profileId,
        delay: const Duration(minutes: 1),
      );

      expect(await harness.send.scheduledCount(), 2);
      final at = await harness.send.nextScheduledAt();
      expect(at, isNotNull);
      expect(
        at!.isBefore(DateTime.now().toUtc().add(const Duration(minutes: 2))),
        isTrue,
        reason: '最近的一封是 1 分钟后那封',
      );
    });

    test('取消队列 = 删掉条目，之后再也发不出去', () async {
      harness.respondWithCreated();
      final id = await harness.send.enqueueScheduled(
        harness.payload(),
        profileId: harness.profileId,
        delay: const Duration(minutes: 1),
      );

      await harness.send.discard(id);
      await harness.send.flush(profileIds: <String>[harness.profileId]);

      expect(await harness.outboxEntry(id), isNull);
      expect(harness.adapter.lastRequest, isNull);
      expect(await harness.send.scheduledCount(), 0);
    });
  });
}

// ---------------------------------------------------------------- 测试环境

class _SentRequest {
  _SentRequest({
    required this.bodyBytes,
    required this.declaredLength,
    required this.headers,
  });

  final List<int> bodyBytes;
  final int? declaredLength;
  final Map<String, List<String>> headers;
}

class _Harness {
  _Harness._({
    required this.db,
    required this.profiles,
    required this.send,
    required this.registry,
    required this.profileId,
    required this.tempDir,
    required this.adapter,
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
    final tempDir = await Directory.systemTemp.createTemp('send_test');

    final registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      // 用**真的** `DioFactory.build`（带鉴权头 + 信封拆包拦截器）再换掉
      // 适配器：发信要走完整的拦截器链，测试才有意义 ——
      // 一个裸 Dio 会漏掉 `{code:403}` 的信封，把它当成一封发成功的信。
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
    await db.profileDao.upsertMailboxes(
      profile.id,
      <MailboxAccount>[
        const MailboxAccount(accountId: 3, email: 'me@example.net', name: '我'),
      ],
    );

    // `EmailRepository` 的构造签名与线上一致 —— 发信要顺带把返回行落库。
    final emails = EmailRepository(
      db: db,
      registry: registry,
      capabilities: CapabilityRepository(db),
      profiles: profiles,
      prefs: prefs,
    );
    final send = SendRepository(
      db: db,
      registry: registry,
      profiles: profiles,
      emails: emails,
    );

    final harness = _Harness._(
      db: db,
      profiles: profiles,
      send: send,
      registry: registry,
      profileId: profile.id,
      tempDir: tempDir,
      adapter: adapter,
    );

    // runtime 要建好并且 token 在缓存里 —— 发信那条 Dio 带鉴权。
    final runtime = registry.ensure((await profiles.find(profile.id))!);
    await runtime.warmUp();

    addTearDown(() async {
      await registry.dispose();
      await authEvents.dispose();
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
    return harness;
  }

  final AppDatabase db;
  final ProfileRepository profiles;
  final SendRepository send;
  final RuntimeRegistry registry;
  final String profileId;
  final Directory tempDir;
  final _FakeAdapter adapter;

  SendPayload payload({
    List<String> recipients = const <String>['to@example.com'],
    List<SendAttachment> attachments = const <SendAttachment>[],
  }) =>
      SendPayload(
        accountId: 3,
        sendEmail: 'me@example.net',
        name: '我',
        subject: '标题',
        text: '正文',
        content: '<p>正文</p>',
        recipients: recipients,
        sendKind: SendKind.normal,
        attachments: attachments,
      );

  Future<File> seedAttachmentFile(String name, List<int> bytes) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<DbOutboxEntry?> outboxEntry(int id) async {
    final rows = await db.localDao.allPending();
    for (final row in rows) {
      if (row.id == id) return row;
    }
    // 也可能已经是 failed/sent —— 直接从表里捞。
    final all = await db.select(db.outboxEntries).get();
    for (final row in all) {
      if (row.id == id) return row;
    }
    return null;
  }

  void respondWithCreated({int accountId = 3, String sendEmail = 'me@example.net'}) =>
      adapter.respond((options, body) async => <String, Object?>{
            'code': 200,
            'message': 'success',
            'data': <Object?>[
              <String, Object?>{
                'emailId': 900,
                'accountId': accountId,
                'sendEmail': sendEmail,
                'subject': '标题',
                'unread': 1,
                'type': 1,
                'status': 1,
                'isStar': 0,
                'createTime': '2026-10-08 12:00:00',
                'attList': <Object?>[
                  <String, Object?>{
                    'attId': 501,
                    'emailId': 900,
                    'key': 'attachments/abc.pdf',
                    'filename': '报价单.pdf',
                    'mimeType': 'application/pdf',
                    'size': 1000,
                    'type': 0,
                  },
                ],
              },
            ],
          });

  void respondEnvelope(Map<String, Object?> envelope) =>
      adapter.respond((options, body) async => envelope);

  void failWith(DioException error) => adapter.fail(error);
}

/// 适配器层：把 dio 真正写出的 body 抓下来。
///
/// 这是唯一能看到 `Content-Length` 与实际字节数是否一致的地方 ——
/// 在 repository 那一层只能看到自己算出来的那个数字。
class _FakeAdapter implements HttpClientAdapter {
  Future<Object?> Function(RequestOptions, List<int>)? _handler;
  DioException? _error;

  _SentRequest? lastRequest;

  void respond(Future<Object?> Function(RequestOptions, List<int>) handler) {
    _handler = handler;
    _error = null;
  }

  void fail(DioException error) {
    _error = error;
    _handler = null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // 把流式 body 吸干 —— 这就是「服务端看到的字节」。
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    lastRequest = _SentRequest(
      bodyBytes: bytes,
      declaredLength: int.tryParse(
        '${options.headers['Content-Length'] ?? options.headers['content-length'] ?? ''}',
      ),
      headers: options.headers.map(
        (k, v) => MapEntry(k, <String>['$v']),
      ),
    );

    final error = _error;
    if (error != null) throw error;

    final handler = _handler;
    if (handler == null) {
      throw StateError('测试没有预设响应：${options.uri}');
    }
    final payload = await handler(options, bytes);
    final encoded = utf8.encode(jsonEncode(payload));
    return ResponseBody(
      Stream<Uint8List>.fromIterable(<Uint8List>[Uint8List.fromList(encoded)]),
      200, // HTTP 状态恒为 200。
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json;charset=utf-8'],
        Headers.contentLengthHeader: <String>['${encoded.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
