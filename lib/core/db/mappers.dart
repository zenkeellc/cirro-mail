import 'dart:convert';

import '../../data/models/instance_capabilities.dart';
import '../../data/models/mail_attachment.dart';
import '../../data/models/mail_row.dart';
import '../../data/models/mailbox_account.dart';
import '../../data/models/profile.dart';
import '../../data/models/recipient.dart';
import '../../data/models/user_role.dart';
import 'database.dart';

/// 领域模型 ↔ drift 行 的转换。
///
/// 集中在一处的原因：drift 生成的 `DbMail` 等类型只在 `core/db` 里出现，
/// 上层（repository / UI）只认 `data/models` 的类。这样将来换存储实现
/// （或加 Web 支持换成别的后端）时只改这一个文件。
///
/// 两个约定：
/// - 时间列一律 UTC（drift 把 DateTime 存成 Unix 秒）。服务端给的是
///   无时区标识的 UTC 字符串，已在 `TimeUtils.parseServerTime` 里补过 `Z`。
/// - `recipient`/`cc`/`bcc` 在库里存 **JSON 字符串**（与服务端同形），
///   解析交给 `Recipient.listFromJson` —— 坏数据只影响一行，不会让整表读不出来。

String encodeRecipients(List<Recipient> list) =>
    list.isEmpty ? '' : jsonEncode(list.map((r) => r.toJson()).toList());

List<Recipient> decodeRecipients(String? raw) => Recipient.listFromJson(raw);

// ---------------------------------------------------------------- profiles

DbProfile profileToDb(Profile p) => DbProfile(
      id: p.id,
      baseUrl: p.baseUrl,
      name: p.name,
      email: p.email,
      serverTitle: p.serverTitle,
      userName: p.userName,
      userId: p.userId,
      ossBase: p.ossBase,
      sort: p.sort,
      colorIndex: p.colorIndex,
      needsLogin: p.needsLogin,
      lastSyncAt: p.lastSyncAt,
      createdAt: p.createdAt,
      lastActiveAt: p.lastActiveAt,
    );

Profile profileFromDb(DbProfile row) => Profile(
      id: row.id,
      baseUrl: row.baseUrl,
      name: row.name,
      email: row.email,
      serverTitle: row.serverTitle,
      userName: row.userName,
      userId: row.userId,
      ossBase: row.ossBase,
      sort: row.sort,
      colorIndex: row.colorIndex,
      needsLogin: row.needsLogin,
      lastSyncAt: row.lastSyncAt,
      createdAt: row.createdAt,
      lastActiveAt: row.lastActiveAt,
    );

// ----------------------------------------------------------- capabilities

DbCapability capabilitiesToDb(String profileId, InstanceCapabilities caps) =>
    DbCapability(
      profileId: profileId,
      payload: jsonEncode(caps.toJson()),
      probedAt: caps.probedAt,
    );

InstanceCapabilities capabilitiesFromDb(DbCapability row) {
  try {
    final decoded = jsonDecode(row.payload);
    if (decoded is Map) {
      return InstanceCapabilities.fromJson(decoded.cast<String, dynamic>());
    }
  } catch (_) {
    // 库里的 JSON 坏了（或跨版本写入的旧格式）→ 当作「未探测」，
    // 而不是让整个实例不可用。
  }
  return const InstanceCapabilities();
}

// --------------------------------------------------------------- mailboxes

DbMailbox mailboxToDb(String profileId, MailboxAccountLike account) => DbMailbox(
      profileId: profileId,
      accountId: account.accountId,
      email: account.email,
      name: account.name,
      status: account.status,
      allReceive: account.allReceive,
      sort: account.sort,
      latestEmailTime: account.latestEmailTime,
      syncedAt: DateTime.now().toUtc(),
    );

// -------------------------------------------------------------------- mails

DbMail mailToDb(MailRow row, {DateTime? cachedAt}) => DbMail(
      profileId: row.profileId,
      emailId: row.emailId,
      accountId: row.accountId,
      mailboxEmail: row.mailboxEmail,
      type: row.type,
      status: row.status,
      sendEmail: row.sendEmail,
      name: row.name,
      subject: row.subject,
      code: row.code,
      toEmail: row.toEmail,
      toName: row.toName,
      recipientJson: encodeRecipients(row.recipients),
      ccJson: encodeRecipients(row.cc),
      bccJson: encodeRecipients(row.bcc),
      message: row.message,
      unread: row.unread,
      isStar: row.isStar,
      starKnown: row.starKnown,
      isDel: row.isDel,
      content: row.content,
      bodyText: row.text,
      inReplyTo: row.inReplyTo,
      relation: row.relation,
      messageId: row.messageId,
      resendEmailId: row.resendEmailId,
      createTime: row.createTime,
      hasFullBody: row.hasFullBody,
      cachedAt: cachedAt ?? DateTime.now().toUtc(),
    );

MailRow mailFromDb(DbMail row) => MailRow(
      emailId: row.emailId,
      profileId: row.profileId,
      sendEmail: row.sendEmail,
      name: row.name,
      subject: row.subject,
      code: row.code,
      toEmail: row.toEmail,
      toName: row.toName,
      type: row.type,
      status: row.status,
      message: row.message,
      unread: row.unread,
      isDel: row.isDel,
      isStar: row.isStar,
      starKnown: row.starKnown,
      accountId: row.accountId,
      userId: 0,
      content: row.content,
      text: row.bodyText,
      recipients: decodeRecipients(row.recipientJson),
      cc: decodeRecipients(row.ccJson),
      bcc: decodeRecipients(row.bccJson),
      inReplyTo: row.inReplyTo,
      relation: row.relation,
      messageId: row.messageId,
      resendEmailId: row.resendEmailId,
      createTime: row.createTime,
      // 附件由 AttachmentDao 单独查，这里不填 —— 避免每读一行都多一次查询。
      hasFullBody: row.hasFullBody,
      mailboxEmail: row.mailboxEmail,
    );

// -------------------------------------------------------------- attachments

DbAttachment attachmentToDb(String profileId, int emailId, MailAttachment a) =>
    DbAttachment(
      profileId: profileId,
      attId: a.attId,
      emailId: a.emailId == 0 ? emailId : a.emailId,
      key: a.key,
      filename: a.filename,
      mimeType: a.mimeType,
      size: a.size,
      type: a.type,
      contentId: a.contentId,
      localPath: a.localPath,
      downloadedAt: a.downloadedAt,
    );

MailAttachment attachmentFromDb(DbAttachment row) => MailAttachment(
      attId: row.attId,
      profileId: row.profileId,
      emailId: row.emailId,
      key: row.key,
      filename: row.filename,
      mimeType: row.mimeType,
      size: row.size,
      type: row.type,
      contentId: row.contentId,
      localPath: row.localPath,
      downloadedAt: row.downloadedAt,
    );

// ------------------------------------------------------------------ drafts

/// 草稿只存附件**路径**，不存内容 —— 大附件不能进本地的另一份拷贝。
String encodeAttachmentPaths(List<String> paths) =>
    paths.isEmpty ? '[]' : jsonEncode(paths);

List<String> decodeAttachmentPaths(String? raw) {
  if (raw == null || raw.isEmpty) return const <String>[];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.map((e) => e.toString()).toList(growable: false);
    }
  } catch (_) {
    // 坏数据当空处理。
  }
  return const <String>[];
}

/// `UserRole` 目前不进库（每次登录随 `loginUserInfo` 拿），
/// 这里留一个转换函数供诊断页序列化用。
Map<String, dynamic> roleToJson(UserRole role) => <String, dynamic>{
      'roleId': role.roleId,
      'name': role.name,
      'key': role.key,
      'sendCount': role.sendCount,
      'sendType': role.sendType,
      'accountCount': role.accountCount,
      'availDomain': role.availDomain,
      'banEmail': role.banEmail,
    };
