import '../../core/util/json_utils.dart';
import '../../core/util/time_utils.dart';
import 'enums.dart';
import 'mail_attachment.dart';
import 'recipient.dart';

/// `email` 表的一行。
///
/// 两个形态（由 `full` 参数决定，见 worker `lib/email-list-columns.js`）：
/// - `full=0`（摘要）：`text` 被截断到 300 字符并压缩空白；有 `text` 时 `content` 为 null，
///   只有在没有 `text` 的情况下才回退给一个压缩过的 `content`。
/// - `full=1`（完整）：完整 `content` / `text` / `attList`。
///
/// 因此 `content == null` 不等于「这封邮件没正文」，只表示「摘要模式下没带」。
class MailRow {
  const MailRow({
    required this.emailId,
    required this.profileId,
    this.sendEmail = '',
    this.name = '',
    this.subject = '',
    this.code = '',
    this.toEmail = '',
    this.toName = '',
    this.type = MailType.receive,
    this.status = MailStatus.receive,
    this.message,
    this.unread = UnreadState.unread,
    this.isDel = 0,
    this.isStar = 0,
    this.accountId = 0,
    this.userId = 0,
    this.content,
    this.text,
    this.recipients = const <Recipient>[],
    this.cc = const <Recipient>[],
    this.bcc = const <Recipient>[],
    this.inReplyTo,
    this.relation,
    this.messageId,
    this.resendEmailId,
    this.createTime,
    this.attList = const <MailAttachment>[],
    this.attachmentCount = 0,
    this.hasFullBody = false,
    this.mailboxEmail = '',
    this.starKnown = true,
  });

  final int emailId;

  /// 所属实例。多实例聚合下这是必填的 —— 所有写操作都要带上它。
  final String profileId;

  final String sendEmail;
  final String name;
  final String subject;

  /// Workers AI 自动识别出的验证码。
  final String code;

  final String toEmail;
  final String toName;
  final int type;
  final int status;

  /// 退信/失败原因，可能是 JSON 字符串也可能是纯文本。
  final String? message;

  /// **0 = 未读，1 = 已读**（与字段名直觉相反）。
  final int unread;

  final int isDel;
  final int isStar;
  final int accountId;
  final int userId;

  /// HTML 正文；摘要模式下通常为 null。
  final String? content;

  /// 纯文本正文；摘要模式下被截断到 300 字符。
  final String? text;

  final List<Recipient> recipients;
  final List<Recipient> cc;
  final List<Recipient> bcc;
  final String? inReplyTo;
  final String? relation;
  final String? messageId;
  final String? resendEmailId;
  final DateTime? createTime;
  final List<MailAttachment> attList;

  /// 这封邮件有几个附件（普通附件，不含内嵌图）。
  ///
  /// **只有列表查询会填它**：列表数据全部来自本地库，而附件在另一张表里
  /// （`mailFromDb` 不查附件表 —— 注释见 `core/db/mappers.dart`）。
  /// `MailDao.watchMailboxSet` / `watchStarred` 用一个相关子查询把它带出来，
  /// 其余路径（详情页的 `find`/`watch`）一律留在 0，用 [attList] 自己数。
  ///
  /// 0 有两种含义：真的没有附件，或者这一行不是从列表查询来的。列表行要知道
  /// 「有没有附件」时还得同时看 [hasFullBody] —— 附件数没同步回来之前，
  /// 0 和「还不知道」分不开（见 `MailRowTile` 的附件标记）。
  final int attachmentCount;

  /// 是否已经拿到完整正文（用于决定要不要补拉 `full=1`）。
  final bool hasFullBody;

  /// 这封邮件被投递到的邮箱地址（聚合视图与通知深链要用）。
  final String mailboxEmail;

  /// 服务端这一行**是否带了 `isStar`**。
  ///
  /// `/email/list` 会 join `star` 表给出 `isStar`，但 `/email/latest` 用的是
  /// `emailBriefColumns`，**没有 `isStar`**。本地 upsert 时若分不清「字段缺失」
  /// 与「值为 0」，轮询一次就会把用户标好的星标全抹掉。
  final bool starKnown;

  bool get isUnread => unread == UnreadState.unread;
  bool get isStarred => isStar == 1;
  bool get isSend => type == MailType.send;

  String get displaySubject => subject.isEmpty ? '(无主题)' : subject;

  /// 列表里显示的发件人：优先昵称，其次地址。
  String get displaySender => name.isNotEmpty ? name : sendEmail;

  /// 预览文本：优先 `text`，没有就从 `content` 里粗略剥标签。
  String get preview {
    final plain = text?.trim() ?? '';
    if (plain.isNotEmpty) return plain.replaceAll(RegExp(r'\s+'), ' ');
    final html = content ?? '';
    if (html.isEmpty) return '';
    return html
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&nbsp;'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// 退信原因（已从 JSON 包装里取出）。
  String? get bounceMessage => JsonUtils.bounceMessage(message);

  factory MailRow.fromJson(
    Map<String, dynamic> json, {
    required String profileId,
    String mailboxEmail = '',
  }) {
    final hasContent = json.containsKey('content');
    final hasAtt = json['attList'] is List;
    final attList = JsonUtils.mapList(json, 'attList')
        .map(MailAttachment.fromJson)
        .toList(growable: false);
    return MailRow(
      emailId: JsonUtils.intValue(json, 'emailId'),
      profileId: profileId,
      sendEmail: JsonUtils.string(json, 'sendEmail'),
      name: JsonUtils.string(json, 'name'),
      subject: JsonUtils.string(json, 'subject'),
      code: JsonUtils.string(json, 'code'),
      toEmail: JsonUtils.string(json, 'toEmail'),
      toName: JsonUtils.string(json, 'toName'),
      type: JsonUtils.intValue(json, 'type'),
      status: JsonUtils.intValue(json, 'status'),
      message: JsonUtils.stringOrNull(json, 'message'),
      unread: JsonUtils.intValue(json, 'unread'),
      isDel: JsonUtils.intValue(json, 'isDel'),
      isStar: JsonUtils.intValue(json, 'isStar'),
      starKnown: json.containsKey('isStar'),
      accountId: JsonUtils.intValue(json, 'accountId'),
      userId: JsonUtils.intValue(json, 'userId'),
      content: JsonUtils.stringOrNull(json, 'content'),
      text: JsonUtils.stringOrNull(json, 'text'),
      recipients: Recipient.listFromJson(json['recipient']),
      cc: Recipient.listFromJson(json['cc']),
      bcc: Recipient.listFromJson(json['bcc']),
      inReplyTo: JsonUtils.stringOrNull(json, 'inReplyTo'),
      relation: JsonUtils.stringOrNull(json, 'relation'),
      messageId: JsonUtils.stringOrNull(json, 'messageId'),
      resendEmailId: JsonUtils.stringOrNull(json, 'resendEmailId'),
      createTime: TimeUtils.parseServerTime(json['createTime']),
      attList: attList,
      // 服务端这一行带了 `attList` 就是权威的附件数（`full=1` 才有）；
      // 没带就留在 0，由列表查询那边的子查询去填。
      attachmentCount: attList.length,
      hasFullBody: hasContent || hasAtt,
      mailboxEmail: mailboxEmail,
    );
  }

  MailRow copyWith({
    int? unread,
    int? isStar,
    int? status,
    String? message,
    String? content,
    String? text,
    List<MailAttachment>? attList,
    int? attachmentCount,
    bool? hasFullBody,
    String? mailboxEmail,
    bool? starKnown,
    int? accountId,
  }) =>
      MailRow(
        emailId: emailId,
        profileId: profileId,
        sendEmail: sendEmail,
        name: name,
        subject: subject,
        code: code,
        toEmail: toEmail,
        toName: toName,
        type: type,
        status: status ?? this.status,
        message: message ?? this.message,
        unread: unread ?? this.unread,
        isDel: isDel,
        isStar: isStar ?? this.isStar,
        starKnown: starKnown ?? this.starKnown,
        userId: userId,
        content: content ?? this.content,
        text: text ?? this.text,
        recipients: recipients,
        cc: cc,
        bcc: bcc,
        inReplyTo: inReplyTo,
        relation: relation,
        messageId: messageId,
        resendEmailId: resendEmailId,
        createTime: createTime,
        attList: attList ?? this.attList,
        attachmentCount: attachmentCount ?? this.attachmentCount,
        hasFullBody: hasFullBody ?? this.hasFullBody,
        mailboxEmail: mailboxEmail ?? this.mailboxEmail,
        accountId: accountId ?? this.accountId,
      );

  /// 合并「完整版」数据到已有行上。
  ///
  /// **不要把已读状态盖回未读** —— `/email/list?full=1` 的响应可能早于
  /// `PUT /email/read` 返回（Web 端 `store/email.js` 里踩过这个坑）。
  ///
  /// 真正把住这道门的是 `MailDao._merge`（本地 `unread` 单调，服务端行只能
  /// 抬成已读）—— 这个方法本身不碰 `unread`（`copyWith` 没传就不改），
  /// 两者是同一个约定在两层的体现。
  MailRow mergeFull(MailRow full) {
    return copyWith(
      content: full.content ?? content,
      text: full.text ?? text,
      attList: full.attList.isNotEmpty ? full.attList : attList,
      hasFullBody: true,
      status: full.status,
      message: full.message,
      mailboxEmail:
          mailboxEmail.isNotEmpty ? mailboxEmail : full.mailboxEmail,
    );
  }

  @override
  String toString() => 'MailRow($profileId#$emailId, "$subject")';
}
