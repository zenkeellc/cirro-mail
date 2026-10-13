/// 服务端 `when`/`isStar` 等 0/1 字段的语义集中在这里，
/// 避免各处再写魔法数字。
library;

/// `email.type`
class MailType {
  const MailType._();
  static const int receive = 0;
  static const int send = 1;
}

/// `email.status`
class MailStatus {
  const MailStatus._();
  static const int receive = 0;
  static const int sent = 1;
  static const int delivered = 2;
  static const int bounced = 3;
  static const int complained = 4;
  static const int delayed = 5;
  static const int saving = 6;
  static const int noRecipient = 7;
  static const int failed = 8;
}

/// `email.unread` —— **注意语义与字段名相反**：
/// 0 = 未读，1 = 已读（见 worker `emailConst.unread`）。
class UnreadState {
  const UnreadState._();
  static const int unread = 0;
  static const int read = 1;
}

/// `attachments.type`
class AttachmentType {
  const AttachmentType._();
  static const int attachment = 0;
  static const int embedded = 1;
}

/// `account.allReceive`
class AllReceive {
  const AllReceive._();
  static const int off = 0;
  static const int on = 1;
}

/// `/email/send` 的 `sendType`
enum SendKind {
  normal('new'),
  reply('reply'),
  forward('forward');

  const SendKind(this.wire);

  /// 服务端识别的字面量。
  final String wire;

  static SendKind fromWire(String? value) {
    for (final kind in SendKind.values) {
      if (kind.wire == value) return kind;
    }
    return SendKind.normal;
  }
}

/// 文件夹维度。用本地值而不是服务端字段，聚合视图要用。
enum MailFolder {
  receive,
  send,
  starred;

  int get apiType => this == MailFolder.send ? MailType.send : MailType.receive;
}

/// 服务端 role.sendType
class SendPolicy {
  const SendPolicy._();
  static const String unlimited = 'unlimited';
  static const String internal = 'internal';
  static const String banned = 'ban';
  static const String byCount = 'count';
  static const String byDay = 'day';
}
