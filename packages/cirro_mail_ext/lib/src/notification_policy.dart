import 'package:flutter/foundation.dart';

/// 一封「新到的信」在**要不要弹通知**这件事上的最小信息。
///
/// 同上（见 `mail_store.dart`）：字段全是原始类型，由核心构造、扩展消费。
///
/// ## 只带通知用得上的东西
///
/// 核心在问扩展之前**已经**做完它自己的通用判定（未读 + 收件方向），所以这里
/// 不会出现「已读的」或者「自己发出去的」。扩展的规则只该建在这几个字段上。
///
/// **刻意不带完整正文**：通知路径是热路径（每一轮轮询、每一次后台唤醒都要过），
/// 而带正文就等于把整页邮件的内容读进内存。需要「这封信里有没有验证码」时，
/// 用 [hasCode]（服务端已经抽好的）与 [bodyPreview] 就够了。
@immutable
class NotificationCandidate {
  const NotificationCandidate({
    required this.profileId,
    required this.emailId,
    this.accountId = 0,
    this.type = 0,
    this.unread = 0,
    this.hasCode = false,
    this.sendEmail = '',
    this.name = '',
    this.subject = '',
    this.bodyPreview = '',
  });

  final String profileId;
  final int emailId;
  final int accountId;

  /// 0 收件 / 1 发件 —— 与 `LocalMail` 的常量同义。
  final int type;
  final int unread;

  /// 服务端 AI 抽出来的验证码非空。判断「这封信是不是验证码邮件」优先用这个：
  /// 它是服务端算好的，不受本地有没有拉到正文影响。
  final bool hasCode;

  final String sendEmail;
  final String name;
  final String subject;

  /// 摘要文本。行是摘要行时是 300 字以内的预览，是完整行时是正文开头。
  final String bodyPreview;

  @override
  String toString() => 'NotificationCandidate($profileId/$emailId, $sendEmail, '
      '"$subject", hasCode=$hasCode)';
}
