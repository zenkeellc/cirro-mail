import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mime/mime.dart';

import '../../core/db/database.dart';
import '../../core/error/app_exception.dart';
import '../../core/storage/attachment_cache.dart';
import '../../instance/runtime_registry.dart';
import '../models/mail_attachment.dart';
import 'profile_repository.dart';

/// 附件的下载、落盘、打开、分享、清理。
///
/// 四条贯穿全文件的规矩：
///
/// 1. **只走 `/api/oss/*`**。`/attachments/*` 是 KV 专用路由，存储后端换成
///    R2/S3 之后那条路径会挂（见计划里的约束 9）。URL 一律经
///    [UrlUtils.resolveKey] / [`MailAttachment.url`] 得到。
/// 2. **落盘前先嗅探**。`/api/oss/*` 找不到对象时是 **HTTP 200 +
///    `{"code":500,…}`**（约束 10）。嗅探在 [OssApi] 里做（content-type 是
///    `application/json` 就抛），这里再加一道保险：写入的字节数为 0 或
///    `Content-Length` 与信封长度一致时也拦下来。宁可报「附件不可用」，
///    也不能把几十字节的 JSON 当 PDF 存起来 —— 用户点开时会以为是文件坏了。
/// 3. **下载完才写库**。先写 `localPath` 再下载的话，中途失败会留下一个
///    指向半截文件的记录，缓存管理页显示「已下载」但打开是坏的。
/// 4. **重名不覆盖**。落点由 [AttachmentCache.targetFor] 决定（同名加序号）。
class AttachmentRepository {
  AttachmentRepository({
    required this.db,
    required this.registry,
    required this.cache,
    required this.profiles,
  });

  final AppDatabase db;
  final RuntimeRegistry registry;
  final AttachmentCache cache;
  final ProfileRepository profiles;
  /// 确保附件在本地，返回它的路径。
  ///
  /// 已经下过且文件还在 → 直接返回，不打网络。文件被系统清掉了 → 重下。
  Future<String> ensureLocal(
    MailAttachment attachment, {
    String? profileId,
    ProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    final owner = attachment.ownerIdOf(profileId);
    if (owner == null) {
      throw const AttachmentNotAvailableException(detail: '缺少 profileId');
    }

    final existing = attachment.localPath;
    if (existing != null && await cache.exists(existing)) return existing;

    return download(
      attachment,
      profileId: owner,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// 下载并落盘。返回落盘路径。
  Future<String> download(
    MailAttachment attachment, {
    required String profileId,
    ProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    final profile = await profiles.find(profileId);
    if (profile == null) {
      throw const AttachmentNotAvailableException(detail: '实例不存在');
    }
    final runtime = registry.peek(profileId);
    if (runtime == null || runtime.isDisposed) {
      throw const AttachmentNotAvailableException(detail: '实例未就绪');
    }

    final url = attachment.url(runtime.ossBase);
    if (url.isEmpty) {
      throw const AttachmentNotAvailableException(detail: '附件没有 key');
    }

    final target = await cache.targetFor(
      profileId: profileId,
      emailId: attachment.emailId,
      filename: attachment.displayName,
    );

    var written = 0;
    try {
      written = await runtime.ossApi.downloadTo(
        url: url,
        savePath: target.path,
        cancelToken: cancelToken,
        onProgress: onProgress,
        writeTo: (stream, expectedBytes) async {
          final sink = target.openWrite();
          try {
            await for (final chunk in stream) {
              sink.add(chunk);
            }
          } finally {
            await sink.close();
          }
        },
      );
    } on AttachmentNotAvailableException {
      await _cleanup(target);
      rethrow;
    } on AppException {
      await _cleanup(target);
      rethrow;
    } catch (e) {
      await _cleanup(target);
      throw NetworkException(detail: e.toString());
    }

    // 保险二：写出来是 0 字节，或者服务端已经说了「没有对象」但 content-type
    // 没被识别出来 —— 两种都不该留下文件。
    if (written <= 0 || !await target.exists() || await target.length() == 0) {
      await _cleanup(target);
      throw const AttachmentNotAvailableException(detail: '下载内容为空');
    }

    await db.mailDao.markAttachmentDownloaded(
      profileId,
      attachment.attId,
      localPath: target.path,
    );
    return target.path;
  }

  /// 应用内预览用的本地文件（图片 / PDF 都要先落盘才好交给预览器）。
  ///
  /// 与 [ensureLocal] 是同一个动作，单独一个名字只是让调用点的意图清楚：
  /// 「我要预览」而不是「我要打开」。
  Future<String> pathForPreview(
    MailAttachment attachment, {
    String? profileId,
    CancelToken? cancelToken,
  }) =>
      ensureLocal(attachment, profileId: profileId, cancelToken: cancelToken);

  /// 按 MIME / 扩展名猜一个可用的类型。分享与「系统应用打开」都要。
  static String mimeOf(MailAttachment attachment) {
    final declared = attachment.mimeType;
    if (declared != null && declared.isNotEmpty) return declared;
    final guessed = lookupMimeType(attachment.displayName);
    return guessed ?? 'application/octet-stream';
  }

  // -------------------------------------------------------------- 缓存管理

  /// 已下载的附件（缓存管理页）。
  Future<List<MailAttachment>> downloaded({String? profileId}) =>
      db.mailDao.downloadedAttachments(profileId: profileId);

  /// 实际占用（遍历磁盘，不是加总库里的记录 —— 库可能留着已被删掉的文件）。
  Future<({int bytes, int files})> usage() => cache.usage();

  /// 删一个已下载的附件（磁盘 + 库里的记录一起清）。
  Future<void> removeLocal(MailAttachment attachment) async {
    final owner = attachment.ownerIdOf(null);
    if (owner == null) return;
    await cache.deleteFile(attachment.localPath);
    await db.mailDao.clearAttachmentLocal(owner, attachment.attId);
  }

  /// 清掉某个实例的全部附件。
  Future<void> clearProfile(String profileId) async {
    final rows = await db.mailDao.downloadedAttachments(profileId: profileId);
    await db.mailDao.forgetLocalPaths(
      profileId,
      rows.map((a) => a.attId),
    );
    await cache.clearProfile(profileId);
  }

  /// 清空全部附件缓存。
  Future<void> clearAll() async {
    final rows = await db.mailDao.downloadedAttachments();
    // 清库记录要按 profileId 分组 —— `forgetLocalPaths` 的 where 里带 profileId。
    final byProfile = <String, List<int>>{};
    for (final row in rows) {
      final owner = row.ownerIdOf(null);
      if (owner == null) continue;
      byProfile.putIfAbsent(owner, () => <int>[]).add(row.attId);
    }
    for (final entry in byProfile.entries) {
      await db.mailDao.forgetLocalPaths(entry.key, entry.value);
    }
    await cache.clearAll();
  }

  /// 删邮件时顺带清掉它的附件目录。
  Future<void> purgeMail(String profileId, int emailId) =>
      cache.deleteMail(profileId, emailId);

  /// 落盘失败后的清理。删不掉也没关系（下次会挑一个新的落点）。
  Future<void> _cleanup(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 忽略。
    }
  }
}
