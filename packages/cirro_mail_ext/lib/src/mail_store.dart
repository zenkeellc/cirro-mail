import 'package:flutter/foundation.dart';

/// 本地已缓存邮件的一条**只读快照**。
///
/// ## 为什么字段全是原始类型
///
/// 这个类由**核心**构造（把本地库的一行折过来），交给**扩展**消费。如果它带
/// 核心的枚举（`MailType` / `UnreadState`……），核心就得反过来 import 扩展包里的
/// 类型 —— 依赖方向立刻反转，接缝也就废了。所以这里的语义用原始值表达，
/// 常量写在下面对应的字段上。
///
/// 同理，本类**只描述本地已有的东西**：它不含任何网络行为，扩展拿到它也不代表
/// 能给服务端发请求。
@immutable
class LocalMail {
  const LocalMail({
    required this.profileId,
    required this.emailId,
    this.accountId = 0,
    this.type = kTypeReceive,
    this.unread = kUnread,
    this.isStar = 0,
    this.sendEmail = '',
    this.name = '',
    this.subject = '',
    this.toEmail = '',
    this.toName = '',
    this.mailboxEmail = '',
    this.code = '',
    this.bodyText,
    this.content,
    this.hasFullBody = false,
    this.sentAt,
    this.cachedAt,
  });

  /// `email.type` —— 收件。
  static const int kTypeReceive = 0;

  /// `email.type` —— 发件。
  static const int kTypeSend = 1;

  /// `email.unread` —— **未读**。注意与字段名直觉相反：0 是未读、1 是已读
  /// （服务端 `emailConst.unread` 就是这么定的）。
  static const int kUnread = 0;

  /// `email.unread` —— 已读。
  static const int kRead = 1;

  /// 所属实例。多实例下这是必填的 —— 所有操作都要带上它。
  final String profileId;

  /// 服务端的主键。**只在同一个 [profileId] 内唯一** —— 两个实例各自从 1 开始
  /// 编号，跨实例比较没有意义，所以本地库的主键是 `(profileId, emailId)`。
  final int emailId;

  /// 这封邮件归属的邮箱（`email.accountId`）；`0` 表示尚未归位。
  final int accountId;

  /// 见 [kTypeReceive] / [kTypeSend]。
  final int type;

  /// 见 [kUnread] / [kRead]。
  final int unread;
  final int isStar;

  final String sendEmail;
  final String name;
  final String subject;
  final String toEmail;
  final String toName;

  /// 服务端投递到哪个邮箱地址。列表接口不返回，由核心按 `accountId` 本地补上；
  /// 补不上时是空串。
  final String mailboxEmail;

  /// 服务端 AI 抽取出的验证码（空串 = 没有）。
  final String code;

  /// 纯文本正文。**可能为 null 而 [content] 有值** —— 服务端在 `full=1` 且自己
  /// 存了 `text` 列时只发 `text`，否则只发 HTML `content`。两者为空的含义是
  /// 「正文还没拉到」（[hasFullBody] 为 false），不是「这封信没有正文」。
  final String? bodyText;

  /// HTML 正文。语义见 [bodyText]。
  final String? content;

  /// 是否已经拿到完整正文（`full=1`）。false 表示这是摘要行。
  final bool hasFullBody;

  /// 服务端给的收信时间。
  final DateTime? sentAt;

  /// 本地写入这一行的时间。**不是服务端字段** —— 见
  /// [MailStore.updatedSince] 为什么拿它当增量水位线。
  final DateTime? cachedAt;

  bool get isUnread => unread == kUnread;
  bool get isReceive => type == kTypeReceive;
  bool get hasCode => code.isNotEmpty;

  /// 有没有**任何**形式的正文。注意这与 [hasFullBody] 问的不是同一件事：
  /// 这里问的是「手上有没有内容」，那里问的是「拿到的是不是完整版」。
  bool get hasAnyBody =>
      (bodyText != null && bodyText!.isNotEmpty) ||
      (content != null && content!.isNotEmpty);

  @override
  String toString() =>
      'LocalMail($profileId/$emailId, "$subject", unread=$unread, '
      'full=$hasFullBody)';
}

/// 本地库发生的一次变更。
///
/// 为什么需要这套事件、而不是让扩展自己去听 drift 的 `tableUpdates`：
/// - `tableUpdates` 只说「某张表变了」，**不说是哪几行** —— 而增量重建索引要的
///   正是那几行；
/// - 它靠 `kind` 区分写入/删除，而核心有几条删除走的是原生 SQL，那里 `kind`
///   是 `null`；
/// - `DriftNativeOptions.shareAcrossIsolates` 默认为 false，**本 isolate 的 drift
///   句柄看不到另一个 isolate 的写入** —— 而本项目前台与后台各开一个连接。
///
/// 所以核心在写路径上**显式发布**，扩展订阅。这是「接缝自己说清楚发生了什么」，
/// 而不是让扩展去猜。
@immutable
sealed class MailStoreEvent {
  const MailStoreEvent(this.profileId);

  final String profileId;
}

/// 一批行被写入或更新（`emailId` 已经存在就是更新）。
class MailUpserted extends MailStoreEvent {
  const MailUpserted(super.profileId, this.emailIds);

  final List<int> emailIds;
}

/// 一批行被删掉了。
class MailDeleted extends MailStoreEvent {
  const MailDeleted(super.profileId, this.emailIds);

  final List<int> emailIds;
}

/// **整个实例的本地数据被清空了**（删实例、或者退出登录保留服务器）。
///
/// 单独一个事件而不是「一堆 [MailDeleted]」：清理走的是
/// `DELETE FROM mails WHERE profile_id = ?`，核心在删之前并不知道有哪些 id，
/// 为了发事件先查一遍不值得。语义上扩展要做的事也不同 —— 这里是「把这个实例
/// 的一切从我这儿抹掉」。
class MailStoreReset extends MailStoreEvent {
  const MailStoreReset(super.profileId);
}

/// **本地**邮件的读取口，由核心实现、在 [AppExtensionRegistry] 上注册。
///
/// 它给的永远是「本地库里已经有的东西」：不触发网络、不改变任何状态。扩展要不要
/// 拿这些数据做什么（建索引、统计……）是扩展自己的事。
///
/// ## 契约（实现方必须满足，消费方可以依赖）
///
/// - [pageAfter] 的分页方向是 `(profileId, emailId)` **严格升序**的键序；
/// - 不存在的 key **不是错误**，返回空列表；
/// - [updatedSince] 按 `cachedAt` 升序；
/// - [changes] 是**广播**流：**冷订阅收不到历史**。所以「先冷扫、再订阅」
///   这个顺序不是风格问题 —— 反过来的话，冷扫期间发生的变更就永远丢了。
abstract class MailStore {
  /// 按 `(profileId, emailId)` 升序分页。
  ///
  /// [afterProfileId] 为 null 表示从最早的开始。翻页时把上一页最后一行的
  /// `(profileId, emailId)` 原样传回来即可（`emailId` 只在同一个
  /// `profileId` 内有序，所以键是二元组）。
  ///
  /// [profileId] 非 null 时只扫那一个实例；[withContent] 为 false 时不取
  /// `bodyText`/`content`（只要元信息的场景，能省下可观的内存）。
  Future<List<LocalMail>> pageAfter({
    String? profileId,
    String? afterProfileId,
    int afterEmailId = 0,
    int limit = 500,
    bool withContent = true,
  });

  /// 本地已有的行数。[profileId] 非 null 时只数那一个实例。
  Future<int> count({String? profileId});

  /// [emailIds] 里**现在还在库里**的那些。
  ///
  /// 用来做对账：任何漏发的 [MailDeleted] 都能被这一步兜住 ——
  /// 扩展自己攒的派生数据最怕的是「库里的行没了、它那份还在」。
  Future<Set<int>> existingEmailIds(String profileId, Iterable<int> emailIds);

  /// 本地写入时间晚于 [since] 的行，按 `cachedAt` 升序。
  ///
  /// 这是**增量水位线**：`cachedAt` 只在真正写入一整行时刷新
  /// （`upsertPage` / `upsertFull`），而「标已读」「标星标」「把邮件归到某个
  /// 邮箱」都是局部 `UPDATE`，**不动它**。所以水位线之后的行不可能带着新的
  /// 正文 —— 扩展据此可以放心地只拿它来找「新到的、正文变了的」那些。
  ///
  /// **代价**：只改了已读/星标的行不会出现在这里。要跟踪这类变化得靠
  /// [changes]。
  Future<List<LocalMail>> updatedSince(DateTime since, {String? profileId});

  /// 本地变更的广播流。语义见 [MailStoreEvent]。
  Stream<MailStoreEvent> changes();
}
