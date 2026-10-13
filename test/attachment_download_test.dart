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
import 'package:mail_app/core/storage/attachment_cache.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mail_attachment.dart';
import 'package:mail_app/data/repositories/attachment_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 附件下载的**整条链路**：`AttachmentRepository.download`
/// → `ProfileRuntime.ossApi` → 真实落盘 + 落库。
///
/// 计划里的验收项原文：
/// > **故意请求不存在的 key，确认提示「附件不可用」而不是写出 72 字节 JSON**
///
/// `oss_download_test.dart` 只钉住了 `OssApi` 那一层。真正会出事的层次在
/// 这上面 —— 一个只看「`downloadTo` 有没有抛」的调用方，会把
/// `OssApi` 之外的失败（写盘 0 字节、流提前结束、磁盘满）当成成功，
/// 于是库里留下「已下载」、磁盘上留着一个空文件。
///
/// 所以这里断言的是**磁盘与库的最终状态**，而不是异常类型：
/// 抛出「附件不可用」的同时，`attachments.local_path` 必须还是 null。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness harness;

  setUp(() async {
    harness = await _Harness.create();
  });

  test('对象不存在（HTTP 200 + JSON 信封）→ 抛「附件不可用」，磁盘与库都不留痕', () async {
    harness.respondJson(<String, Object?>{
      'code': 500,
      'message': "Cannot read properties of null (reading 'body')",
    });
    final att = await harness.seedAttachment(
      attId: 11,
      filename: '合同.pdf',
      key: 'attachments/deadbeef.pdf',
      size: 72,
    );

    await expectLater(
      harness.repo.download(att, profileId: harness.profileId),
      throwsA(
        isA<AttachmentNotAvailableException>().having(
          (e) => e.userMessage,
          'userMessage',
          '附件不可用',
        ),
      ),
    );

    await harness.expectNothingOnDisk(att);
  });

  test('文件真的下载下来 → 落盘 + 库里记上路径（缓存管理页据此显示）', () async {
    final bytes = List<int>.generate(2048, (i) => i % 256);
    harness.respondBytes(bytes);
    final att = await harness.seedAttachment(
      attId: 12,
      filename: '报告.pdf',
      key: 'attachments/cafe.pdf',
      size: bytes.length,
    );

    final path = await harness.repo.download(att, profileId: harness.profileId);

    expect(await File(path).readAsBytes(), bytes);
    expect(path, contains(harness.profileId), reason: '落点要按实例分层');
    expect(path, endsWith('报告.pdf'));

    final stored = await harness.repo.downloaded();
    expect(stored.map((a) => a.attId), contains(12));
    expect(stored.single.localPath, path);

    // 已下载 + 文件还在 → 再要一次不该打网络。要拿**刷新过**的那一行：
    // `localPath` 是库里的状态，手上这个 att 对象还是下载前的。
    // 「不该打网络」用适配器收到的 URL 来断言 —— 这条路上一旦发请求，
    // 适配器没有预设响应会直接炸，比事后看日志可靠。
    harness.respondNothing();
    harness.adapter.requested.clear(); // 忘了上面那次真实的下载。
    final fresh = (await harness.repo.downloaded()).single;
    expect(
      await harness.repo.ensureLocal(fresh, profileId: harness.profileId),
      path,
    );
    expect(harness.adapter.requested, isEmpty, reason: '不该为已下载的文件再发请求');
  });

  test('响应体是 0 字节 → 也算「附件不可用」，不留下空文件', () async {
    // 这条覆盖的是「content-type 没撒谎、但内容确实空了」——
    // 比如中间代理把 body 吞掉，或者对象是个 0 字节的占位。
    harness.respondBytes(const <int>[]);
    final att = await harness.seedAttachment(
      attId: 13,
      filename: 'empty.bin',
      key: 'attachments/empty.bin',
      size: 0,
    );

    await expectLater(
      harness.repo.download(att, profileId: harness.profileId),
      throwsA(isA<AttachmentNotAvailableException>()),
    );

    await harness.expectNothingOnDisk(att);
  });

  test('库里记着「已下载」但文件被系统清了 → 重下，而不是让用户点到空气', () async {
    final bytes = List<int>.generate(512, (i) => i % 256);
    harness.respondBytes(bytes);
    final att = await harness.seedAttachment(
      attId: 14,
      filename: 'a.bin',
      key: 'attachments/a.bin',
      size: bytes.length,
    );

    final first = await harness.repo.download(att, profileId: harness.profileId);
    await File(first).delete();

    // 库里的 localPath 还指着那个已经不在的文件。
    final stale = (await harness.repo.downloaded()).single;
    expect(stale.localPath, first, reason: '前提：库里仍记着旧路径');

    final again = await harness.repo.ensureLocal(
      stale,
      profileId: harness.profileId,
    );
    expect(await File(again).exists(), isTrue);
    expect(await File(again).readAsBytes(), bytes);
  });

  test('两个同名附件不互相覆盖', () async {
    final att1 = await harness.seedAttachment(
      attId: 21,
      filename: 'image.png',
      key: 'attachments/one.png',
    );
    final att2 = await harness.seedAttachment(
      attId: 22,
      filename: 'image.png',
      key: 'attachments/two.png',
    );

    harness.respondBytes(const <int>[1, 1, 1]);
    final p1 = await harness.repo.download(att1, profileId: harness.profileId);
    harness.respondBytes(const <int>[2, 2, 2]);
    final p2 = await harness.repo.download(att2, profileId: harness.profileId);

    expect(p1, isNot(p2));
    expect(await File(p1).readAsBytes(), const <int>[1, 1, 1]);
    expect(await File(p2).readAsBytes(), const <int>[2, 2, 2]);
  });

  test('实例不存在 / runtime 没建好 → 「附件不可用」，而不是空指针', () async {
    harness.respondBytes(const <int>[9]);
    final att = MailAttachment(
      attId: 31,
      emailId: 7,
      key: 'attachments/x.bin',
      filename: 'x.bin',
    );

    await expectLater(
      harness.repo.download(att, profileId: 'not-a-real-profile'),
      throwsA(isA<AttachmentNotAvailableException>()),
    );
  });

  test('key 为空的附件 → 不去请求，直接「附件不可用」', () async {
    // 老分支上有些行确实没有 key（附件上传失败留下的）。
    harness.respondNothing();
    final att = await harness.seedAttachment(
      attId: 41,
      filename: 'ghost.bin',
      key: '',
    );

    await expectLater(
      harness.repo.download(att, profileId: harness.profileId),
      throwsA(isA<AttachmentNotAvailableException>()),
    );
    expect(harness.adapter.requested, isEmpty, reason: 'key 为空时不该发请求');
  });

  test('清掉一个实例的附件 → 磁盘目录与库里的下载记录一起清', () async {
    harness.respondBytes(const <int>[7, 7, 7]);
    final att = await harness.seedAttachment(
      attId: 51,
      emailId: 9,
      filename: 'z.bin',
      key: 'attachments/z.bin',
    );
    final path = await harness.repo.download(att, profileId: harness.profileId);
    expect(await File(path).exists(), isTrue);

    await harness.repo.clearProfile(harness.profileId);

    expect(await File(path).exists(), isFalse);
    expect(await harness.repo.downloaded(), isEmpty);
    expect((await harness.repo.usage()).files, 0);
  });
}

// ---------------------------------------------------------------- 测试环境

/// 内存库 + 内存密钥库 + 临时附件目录 + 假的下载适配器。
class _Harness {
  _Harness._({
    required this.db,
    required this.profiles,
    required this.repo,
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
    final profiles =
        ProfileRepository(db: db, tokens: tokens, prefs: prefs);
    final authEvents = AuthEvents();

    // 每个测试一个新目录：附件落盘是真实文件系统操作，不能共享状态。
    final tempDir = await Directory.systemTemp.createTemp('attach_test');
    final cache = AttachmentCache(root: tempDir);
    final adapter = _FakeAdapter();

    final registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      buildDownloadDio: () => Dio(
        BaseOptions(validateStatus: (_) => true),
      )..httpClientAdapter = adapter,
    );

    final profile = await profiles.create(baseUrl: 'https://mail.example.net');
    // 让 ossBase 有确定的形态（无 r2Domain → /api/oss/）。
    final harness = _Harness._(
      db: db,
      profiles: profiles,
      repo: AttachmentRepository(
        db: db,
        registry: registry,
        cache: cache,
        profiles: profiles,
      ),
      registry: registry,
      profileId: profile.id,
      tempDir: tempDir,
      adapter: adapter,
    );

    // 建出 runtime（不 warmUp —— 下载走的是无鉴权的那条 Dio）。
    harness.registry.ensure((await profiles.find(profile.id))!);

    addTearDown(() async {
      await harness.registry.dispose();
      await authEvents.dispose();
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
    return harness;
  }

  final AppDatabase db;
  final ProfileRepository profiles;
  final AttachmentRepository repo;
  final RuntimeRegistry registry;
  final String profileId;
  final Directory tempDir;
  final _FakeAdapter adapter;

  /// 往库里塞一个附件行（模拟 `full=1` 已经补拉过正文）。
  Future<MailAttachment> seedAttachment({
    required int attId,
    int emailId = 100,
    required String filename,
    required String key,
    int size = 128,
  }) async {
    final att = MailAttachment(
      attId: attId,
      profileId: profileId,
      emailId: emailId,
      key: key,
      filename: filename,
      size: size,
      mimeType: 'application/octet-stream',
    );
    await db.mailDao.upsertAttachments(profileId, emailId, <MailAttachment>[att]);
    return att;
  }

  void respondBytes(List<int> bytes) => adapter.respond(
        bytes,
        contentType: 'application/octet-stream',
      );

  void respondJson(Map<String, Object?> data) => adapter.respond(
        utf8.encode(jsonEncode(data)),
        contentType: 'application/json;charset=utf-8',
      );

  /// 不预设任何响应 —— 真发生请求就会失败，「不该打网络」的路径用它。
  void respondNothing() => adapter.respondNothing();

  /// 磁盘上没有这个附件的任何落点，且库里没有下载记录。
  Future<void> expectNothingOnDisk(MailAttachment att) async {
    final dir = await repo.cache.directoryFor(profileId, att.emailId);
    final files = await dir
        .list()
        .where((e) => e is File)
        .map((e) => e.path)
        .toList();
    expect(files, isEmpty, reason: '不该留下任何文件（含 .part）');

    final rows = await db.mailDao.attachmentsOf(profileId, att.emailId);
    final row = rows.firstWhere((a) => a.attId == att.attId);
    expect(row.localPath, isNull, reason: '库里不能记成「已下载」');
    expect(row.downloadedAt, isNull);
  }
}
/// 只回预设响应的下载适配器，并记下被请求过的 URL。
class _FakeAdapter implements HttpClientAdapter {
  List<int>? _bytes;
  String _contentType = 'application/octet-stream';

  /// 已收到的请求 URL（断言「不该发请求」时用）。
  final List<String> requested = <String>[];

  void respond(List<int> bytes, {required String contentType}) {
    _bytes = bytes;
    _contentType = contentType;
  }

  void respondNothing() => _bytes = null;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.toString());
    final bytes = _bytes;
    if (bytes == null) {
      throw StateError('测试没有预设响应，但发生了请求：${options.uri}');
    }
    return ResponseBody(
      Stream<Uint8List>.fromIterable(<Uint8List>[Uint8List.fromList(bytes)]),
      200, // HTTP 状态恒为 200。
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[_contentType],
        Headers.contentLengthHeader: <String>['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
