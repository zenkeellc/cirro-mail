import 'dart:convert';

import 'enums.dart';

/// 待发送的邮件正文数据。
///
/// **这是 `/email/send` 的契约，不是 UI 表单** —— UI 表单在
/// `features/compose/compose_controller.dart`，组装成这里再校验。
///
/// 服务端的硬约束（`service/email-service.js::send`，见计划「关键约束 13」）：
/// 1. `content` 必须是非 null 字符串 —— 服务端无条件
///    `attService.toImageUrlHtml(c, content)` → `parseHTML(content)`，
///    传 null 直接 500；
/// 2. `receiveEmail` 必须是非空数组 —— 服务端无条件 `.every(...)`；
/// 3. 附件对象要**同时**带 `contentType`（Resend/CF Email 路径用）与
///    `type`（`saveSendAtt` 写 `mime_type` 用），两个都要是 mime 字符串；
///    只带一个会让另一条路径拿到 undefined；
/// 4. ≤10 个附件 / ≤10 张内嵌图的检查发生在**插库之后**，
///    超限会留一条脏 `SAVING` 行 → **必须客户端先校验**；
/// 5. 接口**不支持 cc/bcc**（服务端只用 `receiveEmail` 拼 `recipient`）。
class SendPayload {
  SendPayload({
    required this.accountId,
    required this.sendEmail,
    required this.recipients,
    this.name = '',
    this.subject = '',
    this.text = '',
    this.content = '',
    this.sendKind = SendKind.normal,
    this.replyToEmailId = 0,
    this.attachments = const <SendAttachment>[],
  });

  /// 发信用的邮箱（`account.accountId`，必须属于当前用户）。
  final int accountId;

  /// 发件地址（`account.email`）。
  final String sendEmail;

  /// 发件人显示名；留空时服务端会从邮箱截取。
  final String name;

  /// 收件人，非空。
  final List<String> recipients;

  final String subject;

  /// 纯文本正文。
  final String text;

  /// HTML 正文。**永远不要传 null**。
  final String content;

  final SendKind sendKind;

  /// 回复/转发时的原邮件 id（服务端只在 `sendType == 'reply'` 时用它取 messageId）。
  final int replyToEmailId;

  final List<SendAttachment> attachments;

  /// 附件总量（字节）。
  int get attachmentBytes =>
      attachments.fold<int>(0, (sum, a) => sum + a.size);

  /// 正文里的 `data:image/...` 数量 —— 服务端会把这些转成 cid 内嵌附件，
  /// 同样吃 10 张的上限，所以本地校验必须算进来。
  int get inlineImageCount {
    final pattern = RegExp('src\\s*=\\s*["\']data:image', caseSensitive: false);
    return pattern.allMatches(content).length;
  }

  /// 客户端预校验。返回空列表表示可以发。
  ///
  /// 这些检查在服务端是「插库后」做的（约束 4），所以不先做会留下脏数据。
  List<SendValidationError> validate({
    int maxAttachmentCount = 10,
    int maxInlineImages = 10,
    int maxTotalBytes = 20 * 1024 * 1024,
  }) {
    final errors = <SendValidationError>[];

    if (accountId <= 0 || sendEmail.isEmpty) {
      errors.add(SendValidationError.sender);
    }
    final cleanRecipients =
        recipients.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (cleanRecipients.isEmpty) {
      errors.add(SendValidationError.noRecipient);
    } else if (cleanRecipients.any((e) => !_looksLikeEmail(e))) {
      errors.add(SendValidationError.badRecipient);
    }
    if (content.trim().isEmpty) {
      errors.add(SendValidationError.emptyContent);
    }
    if (attachments.length > maxAttachmentCount) {
      errors.add(SendValidationError.tooManyAttachments);
    }
    if (inlineImageCount > maxInlineImages) {
      errors.add(SendValidationError.tooManyInlineImages);
    }
    if (attachmentBytes > maxTotalBytes) {
      errors.add(SendValidationError.tooLarge);
    }
    return errors;
  }

  SendPayload copyWith({
    int? accountId,
    String? sendEmail,
    List<String>? recipients,
    String? name,
    String? subject,
    String? text,
    String? content,
    SendKind? sendKind,
    int? replyToEmailId,
    List<SendAttachment>? attachments,
  }) =>
      SendPayload(
        accountId: accountId ?? this.accountId,
        sendEmail: sendEmail ?? this.sendEmail,
        recipients: recipients ?? this.recipients,
        name: name ?? this.name,
        subject: subject ?? this.subject,
        text: text ?? this.text,
        content: content ?? this.content,
        sendKind: sendKind ?? this.sendKind,
        replyToEmailId: replyToEmailId ?? this.replyToEmailId,
        attachments: attachments ?? this.attachments,
      );

  /// **小报文**路径（无附件 / 单测用）。
  ///
  /// 带附件的真实发送**不要用这个** —— 它会一次性 materialize 整个 base64，
  /// 走 `features/compose/stream_body_builder.dart` 的流式组装。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'accountId': accountId,
        'name': name,
        'sendEmail': sendEmail,
        'receiveEmail': recipients,
        'subject': subject,
        'content': content,
        'text': text,
        'sendType': sendKind.wire,
        'emailId': replyToEmailId,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
      };

  static bool _looksLikeEmail(String value) {
    final at = value.indexOf('@');
    if (at <= 0 || at == value.length - 1) return false;
    final domain = value.substring(at + 1);
    return !domain.contains(' ') && domain.contains('.');
  }
}

/// `/email/send` 的 `attachments[]` 一项。
///
/// `content` 是**不带 `data:` 前缀**的裸 base64。
/// 服务端 `saveSendAtt` 做 `fileUtils.base64ToUint8Array(att.content)`，
/// 带前缀会解出垃圾字节（并且 `getExtFileName` 拿不到正确扩展名）。
class SendAttachment {
  const SendAttachment({
    required this.path,
    required this.filename,
    required this.size,
    required this.mimeType,
    this.contentBase64,
  });

  /// 本地文件路径（`file_picker` 用 `withData: false`，只留路径）。
  final String path;

  final String filename;
  final int size;
  final String mimeType;

  /// 仅测试与极小报文用；真实发送走流式读 [path]。
  final String? contentBase64;

  /// 预估的 base64 字符数（小数向上取整到 4 的倍数，与 Dart 的
  /// `base64.encoder` 输出长度一致）。
  int get base64Length => 4 * ((size + 2) ~/ 3);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'content': contentBase64 ?? '',
        'filename': filename,
        'size': size,
        // 两个 mime 字段都要 —— 分别被 Resend/CF Email 路径与 saveSendAtt 读取。
        'contentType': mimeType,
        'type': mimeType,
      };
}

enum SendValidationError {
  sender,
  noRecipient,
  badRecipient,
  emptyContent,
  tooManyAttachments,
  tooManyInlineImages,
  tooLarge;

  String get message => switch (this) {
        SendValidationError.sender => '发件邮箱不可用',
        SendValidationError.noRecipient => '请至少填写一个收件人',
        SendValidationError.badRecipient => '收件人地址格式不正确',
        SendValidationError.emptyContent => '正文不能为空',
        SendValidationError.tooManyAttachments => '附件最多 10 个',
        SendValidationError.tooManyInlineImages => '正文内嵌图片最多 10 张',
        SendValidationError.tooLarge => '附件总量超出上限',
      };
}

/// 便于日志/诊断：不需要真的把 base64 打出来。
String debugDescribePayload(SendPayload payload) =>
    'SendPayload(account=${payload.accountId}, to=${payload.recipients.length}, '
    'subject=${jsonEncode(payload.subject)}, att=${payload.attachments.length}, '
    'bytes=${payload.attachmentBytes}, kind=${payload.sendKind.wire})';
