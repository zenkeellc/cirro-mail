// 这一条修的也是一个**今天就已经存在**的漏（规格 §6.1）：
//
//   `EmailRepository.delete` 只做了「打服务端 + `deleteRefs` 删库」，
//   **没有清磁盘** —— 而 `MailDao.deleteRefs` 的注释
//   （`mail_dao.dart:277`）写着「磁盘上的文件留给 `AttachmentCache` 决定」，
//   可四个调用方（`mail_action_runner.dart` 两处、`mail_detail_screen.dart`、
//   `MailProvider.delete`）谁都没调。
//
// 也就是说：**今天删任何一封带附件的邮件，附件文件都留在盘上**，只有
// 设置页的「清空附件缓存」或删实例才回收。
//
// 修法是把 `AttachmentRepository.purgeMail` 接进来 —— 而它的现状是
// **零外部调用者**。接线走 `EmailRepository` 的一个**可选**构造参数
// （不是必填）：5 个既有测试与 `background_sync_task.dart:205` 都用 5 参形式，
// 把它们全改成必填是一次与本功能无关的破坏。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/network/dio_factory.dart';
import 'package:mail_app/core/storage/attachment_cache.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tempDir;
  late AttachmentCache cache;
  late EmailRepository repo;
  late RuntimeRegistry registry;
  late AuthEvents authEvents;
  late ProfileRepository profiles;
  const profileId = 'p1';

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 照 `attachment_download_test.dart` 的样板：把缓存的根指到临时目录，
    // `path_provider` 在单测里没有平台通道。
    tempDir = await Directory.systemTemp.createTemp('mbprobe_delete_');
    cache = AttachmentCache(root: tempDir);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final tokens = TokenStore();
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);
    authEvents = AuthEvents();

    registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      buildApiDio: (profile) => DioFactory.build(
        userApi: profile.baseUrl,
        profileId: profile.id,
        authEvents: authEvents,
        readToken: () => 'fake-jwt',
        readLanguage: () => 'zh',
      )..httpClientAdapter = _OkAdapter(),
    );
    final profile = await profiles.create(baseUrl: 'https://mail.example.net');
    await profiles.markLoggedIn(
      profile.id,
      userId: 42,
      email: 'me@example.net',
      userName: 'me',
    );
    repo = EmailRepository(
      db: db,
      registry: registry,
      capabilities: CapabilityRepository(db),
      profiles: profiles,
      prefs: prefs,
      // 生产接线是 `attachmentRepositoryProvider.purgeMail`；
      // 这里给到真实的 `AttachmentCache`，才验得出「目录真的没了」。
      onDiskPurge: (pid, emailId) => cache.deleteMail(pid, emailId),
    );
  });

  tearDown(() async {
    await registry.dispose();
    await authEvents.dispose();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('删一封带附件的邮件之后，磁盘上的目录不在了', () async {
    await db.mailDao.upsertPage(<MailRow>[
      const MailRow(
        emailId: 501,
        profileId: profileId,
        accountId: 8,
        toEmail: 'me@example.net',
        type: MailType.receive,
        subject: '带附件的信',
      ),
    ]);
    // 真的写一个文件进去（不是只建目录）。
    final dir = await cache.directoryFor(profileId, 501);
    final file = File('${dir.path}/invoice.pdf');
    await file.writeAsBytes(<int>[1, 2, 3]);
    expect(await dir.exists(), isTrue);

    await repo.delete(<MailRef>[
      const MailRef(profileId: profileId, emailId: 501),
    ]);

    expect(await db.mailDao.find(profileId, 501), isNull, reason: '库里要删');
    expect(
      await dir.exists(),
      isFalse,
      reason: '磁盘上的附件目录也要没 —— 此前它一直留着，'
          '只有「清空附件缓存」或删实例才回收',
    );
  });

  test('别的邮件的目录不受影响', () async {
    await db.mailDao.upsertPage(<MailRow>[
      const MailRow(emailId: 502, profileId: profileId, accountId: 8),
      const MailRow(emailId: 503, profileId: profileId, accountId: 8),
    ]);
    final keep = await cache.directoryFor(profileId, 503);
    await File('${keep.path}/keep.pdf').writeAsBytes(<int>[9]);

    await repo.delete(<MailRef>[
      const MailRef(profileId: profileId, emailId: 502),
    ]);

    expect(await keep.exists(), isTrue);
  });

  test('没有接线 onDiskPurge 时，删库照常（不能因为没接就从「漏」变「崩」）',
      () async {
    final bare = EmailRepository(
      db: db,
      registry: registry,
      capabilities: CapabilityRepository(db),
      profiles: profiles,
      prefs: PrefsStore(await SharedPreferences.getInstance()),
    );
    await db.mailDao.upsertPage(<MailRow>[
      const MailRow(emailId: 504, profileId: profileId, accountId: 8),
    ]);
    await bare.delete(<MailRef>[
      const MailRef(profileId: profileId, emailId: 504),
    ]);
    expect(await db.mailDao.find(profileId, 504), isNull);
  });
}

/// 删除打的是 `DELETE /email/delete`，一律回 200 空信封。
class _OkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        jsonEncode(<String, Object?>{'code': 200, 'data': null}),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
