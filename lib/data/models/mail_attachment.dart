import '../../core/util/json_utils.dart';
import '../../core/util/url_utils.dart';
import 'enums.dart';

/// `attachments` 表的一行。
///
/// 关键点：`/email/list?full=1` 返回的 `attList` **只包含 `type == 0`（普通附件）**，
/// 内嵌图（`type == 1`）不在其中 —— 它们只存在于 `content` 的 HTML 里。
class MailAttachment {
  const MailAttachment({
    required this.attId,
    this.profileId = '',
    this.emailId = 0,
    this.accountId = 0,
    this.userId = 0,
    this.key = '',
    this.filename = '',
    this.mimeType,
    this.size = 0,
    this.type = AttachmentType.attachment,
    this.disposition,
    this.contentId,
    this.encoding,
    this.localPath,
    this.downloadedAt,
  });

  final int attId;

  /// 所属实例。**服务端不返回**，是本地落库时补上的 —— 聚合视图里附件
  /// 也要能回到自己的实例（缓存管理页要按实例分组、按实例清理）。
  final String profileId;

  final int emailId;
  final int accountId;
  final int userId;

  /// 形如 `attachments/<sha256><ext>`；也可能是完整 URL（历史数据）。
  final String key;

  final String filename;
  final String? mimeType;
  final int size;
  final int type;
  final String? disposition;
  final String? contentId;
  final String? encoding;

  /// 本地已下载路径（仅本地缓存字段，非服务端返回）。
  final String? localPath;
  final DateTime? downloadedAt;

  bool get isEmbedded => type == AttachmentType.embedded;

  bool get isDownloaded => localPath != null && localPath!.isNotEmpty;

  /// 这个附件属于哪个实例。
  ///
  /// 优先用传入的 [fallback]（调用方通常从上下文里知道），因为库里存的
  /// `profileId` 在少数路径上可能是空的（比如刚从服务端解析出来、还没落库）。
  String? ownerIdOf(String? fallback) {
    if (profileId.isNotEmpty) return profileId;
    if (fallback != null && fallback.isNotEmpty) return fallback;
    return null;
  }

  /// 可否作为普通附件展示/下载（内嵌图不在附件面板里）。
  bool get isDownloadable =>
      !isEmbedded && (contentId == null || contentId!.isEmpty);

  String get displayName =>
      filename.isNotEmpty ? filename : '附件-$attId';

  String get extension {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return '';
    return filename.substring(dot + 1).toLowerCase();
  }

  /// 下载 URL。**必须**经过 [UrlUtils.resolveKey]。
  String url(String ossBase) => UrlUtils.resolveKey(key, ossBase);

  factory MailAttachment.fromJson(Map<String, dynamic> json) {
    return MailAttachment(
      attId: JsonUtils.intValue(json, 'attId'),
      emailId: JsonUtils.intValue(json, 'emailId'),
      accountId: JsonUtils.intValue(json, 'accountId'),
      userId: JsonUtils.intValue(json, 'userId'),
      key: JsonUtils.string(json, 'key'),
      filename: JsonUtils.string(json, 'filename'),
      mimeType: JsonUtils.stringOrNull(json, 'mimeType'),
      size: JsonUtils.intValue(json, 'size'),
      type: JsonUtils.intValue(json, 'type'),
      disposition: JsonUtils.stringOrNull(json, 'disposition'),
      contentId: JsonUtils.stringOrNull(json, 'contentId'),
      encoding: JsonUtils.stringOrNull(json, 'encoding'),
    );
  }

  MailAttachment copyWith({
    String? profileId,
    String? localPath,
    DateTime? downloadedAt,
  }) =>
      MailAttachment(
        attId: attId,
        profileId: profileId ?? this.profileId,
        emailId: emailId,
        accountId: accountId,
        userId: userId,
        key: key,
        filename: filename,
        mimeType: mimeType,
        size: size,
        type: type,
        disposition: disposition,
        contentId: contentId,
        encoding: encoding,
        localPath: localPath ?? this.localPath,
        downloadedAt: downloadedAt ?? this.downloadedAt,
      );

  @override
  String toString() => 'MailAttachment($attId, $filename, $size)';
}
