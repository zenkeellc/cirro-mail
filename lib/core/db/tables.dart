import 'package:drift/drift.dart';

/// 本地缓存库的表定义。
///
/// 多实例的核心约定：**一个库服务所有实例，每张业务表都带 `profileId`**。
/// 聚合时间线就是一条不带 `profileId` 过滤的查询；单实例视图就是加上过滤。
///
/// 时间列一律存 UTC（drift 默认把 `DateTime` 存成 Unix 秒，写之前
/// 统一 `.toUtc()`）。服务端给的是无时区标识的 UTC 字符串，
/// 见 `core/util/time_utils.dart`。

/// 实例（服务器 + 账号）。token **不在这里**，在系统密钥库。
///
/// 所有 drift 行类都显式命名成 `Db*`，与 `data/models/` 里同名的领域模型分开 ——
/// drift 默认会给 `Profiles` 生成 `Profile`，和领域模型 `Profile` 撞名，
/// 而两者职责不同（前者是表行，后者带 `ossBase`/`displayName` 等解析逻辑）。
@DataClassName('DbProfile')
class Profiles extends Table {
  /// UUID，也是 secure storage 的 key 后缀。
  TextColumn get id => text()();
  TextColumn get baseUrl => text()();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get serverTitle => text().withDefault(const Constant(''))();
  TextColumn get userName => text().withDefault(const Constant(''))();
  IntColumn get userId => integer().withDefault(const Constant(0))();
  TextColumn get ossBase => text().withDefault(const Constant(''))();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  IntColumn get colorIndex => integer().withDefault(const Constant(0))();

  /// token 被判 401 后置位。该实例的同步循环停下，但不影响其他实例。
  BoolColumn get needsLogin => boolean().withDefault(const Constant(false))();

  DateTimeColumn get lastSyncAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().nullable()();
  DateTimeColumn get lastActiveAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 每个实例一行的能力探测结果，见 `data/models/instance_capabilities.dart`。
@DataClassName('DbCapability')
class Capabilities extends Table {
  TextColumn get profileId => text()();
  TextColumn get payload => text()();
  DateTimeColumn get probedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {profileId};
}

/// 邮箱（服务端 `account` 表）。UI 上叫「邮箱」。
@DataClassName('DbMailbox')
class Mailboxes extends Table {
  TextColumn get profileId => text()();
  IntColumn get accountId => integer()();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get name => text().withDefault(const Constant(''))();
  IntColumn get status => integer().withDefault(const Constant(0))();

  /// 1 = 接收该用户所有邮箱的邮件。服务端的 `setAllReceive` 是**切换语义**
  /// （开一个会清掉其他），客户端要单邮箱开启或用合并视图代替。
  IntColumn get allReceive => integer().withDefault(const Constant(0))();

  IntColumn get sort => integer().withDefault(const Constant(0))();

  /// 服务端给的是时间字符串，原样保留（只用于「最近活跃」展示）。
  TextColumn get latestEmailTime => text().nullable()();

  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {profileId, accountId};
}

/// 邮件行。`content`/`bodyText` 只在拿到 `full=1` 之后才有值。
@DataClassName('DbMail')
class Mails extends Table {
  TextColumn get profileId => text()();
  IntColumn get emailId => integer()();

  /// 这封邮件归属的邮箱（`email.accountId`）。
  IntColumn get accountId => integer().withDefault(const Constant(0))();

  /// 该邮件被投递到的邮箱地址，聚合视图与通知深链要用（列表接口不返回，
  /// 由本地根据 accountId 补上）。
  TextColumn get mailboxEmail => text().withDefault(const Constant(''))();

  /// 0 收件 / 1 发件。
  IntColumn get type => integer().withDefault(const Constant(0))();
  IntColumn get status => integer().withDefault(const Constant(0))();
  TextColumn get sendEmail => text().withDefault(const Constant(''))();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get subject => text().withDefault(const Constant(''))();
  TextColumn get code => text().withDefault(const Constant(''))();
  TextColumn get toEmail => text().withDefault(const Constant(''))();
  TextColumn get toName => text().withDefault(const Constant(''))();

  /// 收件人/抄送/密送：**原样保存服务端的 JSON 字符串**，
  /// 解析交给 `Recipient.listFromJson`，这样坏数据不会污染库里其他行。
  TextColumn get recipientJson => text().withDefault(const Constant(''))();
  TextColumn get ccJson => text().withDefault(const Constant(''))();
  TextColumn get bccJson => text().withDefault(const Constant(''))();

  /// 退信/失败原因（可能是 JSON 字符串也可能是纯文本）。
  TextColumn get message => text().nullable()();

  /// **0 = 未读，1 = 已读**（与字段名直觉相反）。
  IntColumn get unread => integer().withDefault(const Constant(0))();
  IntColumn get isStar => integer().withDefault(const Constant(0))();

  /// 服务端这一行**是否带了 `isStar`**。
  ///
  /// `/email/list` 会 join `star` 表给出 `isStar`，但 `/email/latest` 走的是
  /// `emailBriefColumns`，**没有这个字段**。分不清「缺失」和「值 0」的话，
  /// 轮询一次就会把用户标好的星标全抹掉。
  BoolColumn get starKnown => boolean().withDefault(const Constant(false))();

  IntColumn get isDel => integer().withDefault(const Constant(0))();

  TextColumn get content => text().nullable()();

  /// 纯文本正文。**不叫 `text`** —— 那是 drift `Table` 上的列构造器方法名，
  /// 撞名会让整张表里所有 `text()` 调用都解析到本字段上。
  TextColumn get bodyText => text().nullable()();

  TextColumn get inReplyTo => text().nullable()();
  TextColumn get relation => text().nullable()();
  TextColumn get messageId => text().nullable()();
  TextColumn get resendEmailId => text().nullable()();

  DateTimeColumn get createTime => dateTime().nullable()();

  /// 是否已拿到完整正文。false 表示这是摘要行，进详情页要先补拉 `full=1`。
  BoolColumn get hasFullBody => boolean().withDefault(const Constant(false))();

  /// 本地写入时间（用于缓存淘汰与「同步中」判断）。
  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {profileId, emailId};
}

/// 附件。内嵌图（`type=1`）不在列表接口里返回，所以这里只会有普通附件。
@DataClassName('DbAttachment')
class Attachments extends Table {
  TextColumn get profileId => text()();
  IntColumn get attId => integer()();
  IntColumn get emailId => integer().withDefault(const Constant(0))();
  TextColumn get key => text().withDefault(const Constant(''))();
  TextColumn get filename => text().withDefault(const Constant(''))();
  TextColumn get mimeType => text().nullable()();
  IntColumn get size => integer().withDefault(const Constant(0))();
  IntColumn get type => integer().withDefault(const Constant(0))();
  TextColumn get contentId => text().nullable()();

  /// 本地已下载路径（绝对路径）。未下载为 null。
  TextColumn get localPath => text().nullable()();
  DateTimeColumn get downloadedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {profileId, attId};
}

/// 每个「实例 + 范围」的同步状态。`scope` 形如 `mailbox:12:type:0`。
@DataClassName('DbSyncState')
class SyncStates extends Table {
  TextColumn get profileId => text()();
  TextColumn get scope => text()();

  /// 增量游标：已知的最大 `emailId`。
  IntColumn get cursorEmailId => integer().withDefault(const Constant(0))();

  /// 已加载到的最小 `emailId`（往上翻页的游标）。
  IntColumn get oldestEmailId => integer().withDefault(const Constant(0))();

  /// 服务端在这个 scope 下的**精确总数**（`/email/list` 的 `total`）。
  ///
  /// 它是「还有几封没同步」的减数：`total - 本地条数`。服务端的 count 口径
  /// （`userId + type + accountId/allReceive + isDel=NORMAL`）与 [scope] 一一对应，
  /// 所以放在这一行而不是新开一张表。
  ///
  /// **0 表示「还不知道」** —— 只有不带游标的那次 list（冷启动基线 / 翻页）才拿得到
  /// `total`，`/email/latest` 与 `/star/list` 的响应里没有它。用它做减法前先判 0。
  IntColumn get remoteTotal => integer().withDefault(const Constant(0))();

  /// 上一次拿到 [remoteTotal] 的时刻。null = **还没探过**。
  ///
  /// 为什么「已知」不能只看 [remoteTotal]：那一列的 0 表示「还不知道」，
  /// 于是「真的是个空邮箱」与「还没探过」会撞在同一个值上 —— 表现是空邮箱
  /// 永远显示占位符，而且「要不要探」只能写成 `remoteTotal <= 0`，于是
  /// **每次展开都重探它**，TTL 也没有载体（`lastSyncAt` 是同步引擎的语义，
  /// 不能借）。有了这一列三态才分得开：
  /// `null` = 未知（显示占位符、需要探）；非 null = [remoteTotal] 就是真值
  /// （**0 也是真值**）；TTL = `now - remoteTotalAt`。
  DateTimeColumn get remoteTotalAt => dateTime().nullable()();

  /// 更旧的方向是否已经翻到底（`loadOlder` 返回 false 时置位）。
  ///
  /// 落库的理由：这个结论只活在 `MailListController._hasMore` 那个内存字段里的话，
  /// 每次冷启动都会白白多发一次「拉到底才发现没有」的请求。
  BoolColumn get backfillDone => boolean().withDefault(const Constant(false))();

  DateTimeColumn get lastSyncAt => dateTime().nullable()();

  /// 连续失败次数（成功后清零）。调度器用它指数退避。
  IntColumn get failCount => integer().withDefault(const Constant(0))();

  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {profileId, scope};
}

/// 发件箱：断网/切实例后重试，草稿不丢。一个实例同时只发一封。
@DataClassName('DbOutboxEntry')
class OutboxEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get profileId => text()();

  /// 整封邮件（含附件**路径**，不含 base64 —— base64 发送时才流式读盘）。
  TextColumn get payloadJson => text()();

  /// 待发送 / 发送中 / 已发送 / 永久失败。
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();

  /// 计划发送时间（UTC）。null = 随时可发。
  ///
  /// 这是「发送后一分钟内还能反悔」的唯一实现方式：`/email/send` **没有定时发送**，
  /// 所以延迟整个在客户端做 —— 到点之前这封信只是本地的一行记录，
  /// `LocalDao.nextDue` 挑不到它，一个字节都不会发出去。取消就是删掉这一行。
  DateTimeColumn get scheduledAt => dateTime().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
}

/// 收件人历史（自动补全）。只保留最近用过的若干条。
@DataClassName('DbRecipientHistory')
class RecipientsHistory extends Table {
  TextColumn get profileId => text()();
  TextColumn get address => text()();
  TextColumn get name => text().withDefault(const Constant(''))();
  DateTimeColumn get usedAt => dateTime().nullable()();
  IntColumn get useCount => integer().withDefault(const Constant(1))();

  @override
  Set<Column> get primaryKey => {profileId, address};
}

/// 本地草稿。**与 Web 端不互通**（Web 端草稿在浏览器 IndexedDB 里）。
@DataClassName('DbDraft')
class Drafts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get profileId => text()();
  TextColumn get accountEmail => text().withDefault(const Constant(''))();
  TextColumn get recipientsJson => text().withDefault(const Constant(''))();
  TextColumn get subject => text().withDefault(const Constant(''))();
  TextColumn get content => text().withDefault(const Constant(''))();

  /// 附件只存路径，不存内容。
  TextColumn get attachmentPathsJson => text().withDefault(const Constant('[]'))();
  DateTimeColumn get updatedAt => dateTime()();
}

/// 「稍后提醒」的一条排期（spec §7.1）。
///
/// **刻意不声明 drift 外键**（指向 `mails`）：SQLite 的 `PRAGMA foreign_keys`
/// 在本仓库的 `setup` 里没开（只开了 WAL 与 busy_timeout），声明了也不会被强制，
/// 只会让生成代码多一截。取而代之的是**在既有的删除漏斗里清一次** ——
/// `MailDao.deleteRefs` 已经在事务里删 `attachments` 与 `mails`，把这张表加进
/// 那个事务即可（那是本地删除的**唯一**路径）。
@DataClassName('DbReminder')
class Reminders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get profileId => text()();
  IntColumn get emailId => integer()();

  /// 冗余存一份标题与发件人：到点弹通知时那封邮件可能已经被删了，
  /// 而「你让我提醒你的那封信」这个信息只在这张表里。
  TextColumn get subject => text().withDefault(const Constant(''))();
  TextColumn get sender => text().withDefault(const Constant(''))();

  /// 提醒时间（**UTC**，与 `OutboxEntries.scheduledAt` 同一套约定）。
  DateTimeColumn get remindAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();

  /// 已经弹过了（主路径由系统排期弹出，降级路由 ticker 弹）。
  ///
  /// **弹过之后不删行**，只置这个时间戳：「删掉」在弹失败时会把提醒吞掉，
  /// 而用户完全不知道。留一行带 `firedAt` 的，既不会重复弹，也留着
  /// 「这封信我提醒过一次」这个事实。
  DateTimeColumn get firedAt => dateTime().nullable()();
}
