import 'package:flutter/foundation.dart';

/// 一条草稿的**跨端快照**。
///
/// ## 为什么字段全是原始类型
///
/// 与 `LocalMail` 同一条纪律：本类由**核心**构造、交给**扩展**消费。带核心的
/// 行类（`DbDraft`）或者 `features/compose` 的 UI 类型进来，依赖方向立刻反转，
/// 接缝也就废了。所以正文是 Quill Delta 的 **JSON 字符串**，收件人是裸地址
/// 数组，附件是本机路径数组 —— 扩展拿到它不需要认识核心的任何模型。
///
/// ## 它是**快照**，不是句柄
///
/// 构造时把两个列表复制成不可修改的副本：消费方（同步层）经常把它塞进队列
/// 延后处理，如果这里留着核心传进来的可变列表，一条迟到的 `add` 就能改掉
/// 「已经发出去的那份快照」，症状是云端多出一个用户从没加过的附件。
///
/// ## 明文，没有 E2EE
///
/// 与自部署 cloudmail 的既有取舍一致（见父仓 spec §7）：服务端可读，平台侧
/// 靠静态加密。把这条写在这里，是因为扩展作者最容易假设「同步接口默认端到端
/// 加密」而漏掉设置页那句提示。
@immutable
class DraftSnapshot {
  DraftSnapshot({
    required this.profileId,
    required this.accountEmail,
    required this.profileKey,
    required this.uid,
    required this.rev,
    required this.deleted,
    required this.subject,
    required List<String> recipients,
    required this.body,
    required List<String> attachmentPaths,
    required this.updatedAt,
  })  : recipients = List<String>.unmodifiable(recipients),
        attachmentPaths = List<String>.unmodifiable(attachmentPaths);

  /// 本机 profile 的 id。**只在本机有意义** —— 换设备之后同一个账号是另一个
  /// id，跨设备认同一份草稿靠的是 [uid] + [profileKey]，不是它。
  final String profileId;

  /// 这份草稿用哪个发件邮箱写回去（核心草稿行的 `account_email`）。
  ///
  /// 同步层也要它：服务端按账号归档时，这份草稿属于哪个地址不能靠猜。
  final String accountEmail;

  /// `sha256(站点根 + "\n" + lowercase(邮箱))`，十六进制小写。
  ///
  /// 服务端把它当**不透明字符串**存（它只需要「同一实例同一账号」这个等价
  /// 关系），所以外面不要再往里面塞语义、也不要拿它反解邮箱。规则只有核心
  /// 实现，扩展只透传 —— 两边各算一份迟早会在大小写/端口上分叉。
  final String profileKey;

  /// 跨设备稳定身份（UUIDv4）。本机生成，写进去之后**永不变**。
  final String uid;

  /// 版本号。本地每次落库 +1；远端快照原样带回来（**不 +1**，见
  /// [DraftStore.applyRemote]）。
  ///
  /// 云端 CAS 用它判断「我手里这份是不是基于我上次看到的那一版」，所以它只能
  /// 前进、不能跳号或者倒退。
  final int rev;

  /// true = 这条是**删除墓碑**，草稿本身已经不在了。
  ///
  /// 墓碑只由 [DraftStore.listTombstones] 产生；[DraftStore.watchAll] /
  /// [DraftStore.listAll] 给的都是活草稿（`deleted: false`）。服务端墓碑应用回
  /// 本地时，同步层调 [DraftStore.applyRemote]（`deleted: true`），核心删行而
  /// **不会**再写一条本地墓碑。
  final bool deleted;

  final String subject;

  /// 收件人（**只有 To**）。核心草稿只存 To，Cc/Bcc 不进草稿 —— 这不是本接缝
  /// 的取舍，是撰写页持久化的现状；扩展不要据此认为「服务端可以补 Cc」。
  final List<String> recipients;

  /// Quill Delta JSON。可能是数 MB（内联图片是 base64 嵌在里面的），同步层
  /// 自己决定要不要跳过超大正文（见 spec §6.3 的 1MB 上限）。
  final String body;

  /// 附件的**本机绝对路径**。跨设备不上传路径 —— 云端引用另有一套
  /// `{key,name,mime,size}`，由扩展自己映射。
  final List<String> attachmentPaths;

  /// 草稿最近一次被修改的时间（核心存 UTC）。
  ///
  /// **读回来可能是本地时区**：drift 把 `DateTime` 存成 Unix 秒，读出的
  /// `DateTime` 是同一个瞬间的本地表示（见核心的 `tables.dart`）。所以拿它去
  /// **比较、排序或者序列化**（发给服务端、写进扩展自己的库）之前先 `.toUtc()`；
  /// 直接 `toIso8601String()` 会带 `+08:00` 之类的偏移，服务端按字符串比较就会
  /// 把「同一时刻」判成不同值。
  final DateTime updatedAt;

  /// **不含 subject / body / recipients**（spec §7：日志脱敏）。
  ///
  /// 快照经常被同步层整条丢进 debug 日志，而它的字段全是用户的信内容。留
  /// `profileKey` 前缀够定位「哪个账号」，`uid` / `rev` 够定位「哪一条、哪一
  /// 版」；主题、正文、收件人一律不进字符串 —— 要看内容的只有撰写页。
  @override
  String toString() => 'DraftSnapshot(${_profileKeyPrefix(profileKey)}/$uid, '
      'rev=$rev, deleted=$deleted)';
}

/// 日志里的 `profileKey` 只露前 8 位：够区分账号，又不至于把服务端存的那个
/// 不透明串整条抄进日志（spec §7 的日志脱敏）。
String _profileKeyPrefix(String profileKey) =>
    profileKey.length <= 8 ? profileKey : profileKey.substring(0, 8);

/// 本机一个已登录 profile 的身份（加展示用的 host）。
///
/// ## 为什么接缝要单开这个出口
///
/// [DraftStore.listAll] / [DraftStore.watchAll] 只会给出**有草稿的** profile：
/// 一个刚登录、本机一条草稿都没有的账号在里面根本不存在。而云端的草稿是不
/// 知道「这台设备有没有草稿」的 —— 同步层必须能枚举本机所有账号，才能为每个
/// 账号拉一次云端草稿。少了这个出口，「在另一台设备上写的草稿，在这台本地零
/// 草稿的机器上」永远落不下来（只有等用户在本机随便写一条草稿，那个 profile
/// 才会被 [DraftStore.listAll] 顺带带出来）。
///
/// ## 字段的语义边界
///
/// - [profileId] **只在本机有意义**（换设备就是另一个 id），所以它不是同步
///   协议的键，只用来给 [DraftStore.applyRemote] 落地；
/// - [profileKey] 是跨设备认账号的唯一键，算法只在核心（[DraftSnapshot.profileKey]）；
/// - [accountEmail] 是登录邮箱（原样，不归一化），用于展示与「这封信从哪发」；
/// - [instanceHost] 是站点根（`Profile.host`，去掉结尾 `/api`），**不要**拿它
///   参与 key 计算（那会绕过核心的归一化，在大小写上分叉），只用于展示与
///   diagnostic。
@immutable
class DraftProfileRef {
  const DraftProfileRef({
    required this.profileId,
    required this.profileKey,
    required this.accountEmail,
    required this.instanceHost,
  });

  /// 本机 profile id（换设备就变）。
  final String profileId;

  /// `sha256(站点根 + "\n" + lowercase(邮箱))`，十六进制小写。
  final String profileKey;

  /// 登录邮箱（服务端登录用的那个，原样返回）。
  final String accountEmail;

  /// `Profile.host`：站点根（去掉了结尾 `/api`），用于展示 / diagnostic。
  final String instanceHost;

  /// 邮箱是诊断「这个账号为什么没同步」时唯一有用的信息（profileKey 是哈希，
  /// 人看不出是谁），所以留着；除此之外没有别的字段。
  @override
  String toString() => 'DraftProfileRef($profileId, '
      '${_profileKeyPrefix(profileKey)}, $accountEmail, $instanceHost)';
}

/// 一次变更的方向。
enum DraftChangeKind {
  /// 新增或修改。
  upsert,

  /// 删除。
  delete,
}

/// 一条变更事件。
///
/// **公开版目前不主动发这个流**：[DraftStore.watchAll] 直接推全量快照列表，
/// 由消费方自己 diff（草稿数量级很小，全量比增量省事、也不会漏掉「删除」）。
/// 这个类型留给需要显式事件的消费方，以及后面可能加的变更流。
@immutable
class DraftChange {
  const DraftChange({required this.snapshot, required this.kind});

  final DraftSnapshot snapshot;
  final DraftChangeKind kind;

  @override
  String toString() => 'DraftChange(${kind.name}, ${snapshot.uid})';
}

/// **本地草稿的读取 / 写回口**，由核心实现、在注册表上注册
/// （`AppExtensionRegistry.attachDraftStore`）。
///
/// ## 契约（实现方必须满足，消费方可以依赖）
///
/// - **本地库是真相源**：所有方法读写本机 drift 库，不触发任何网络；
/// - [profiles] 给出**所有**已登录 profile（含本机一条草稿都没有的），
///   [profileIdFor] 认不出的 key 返回 null；
/// - [listAll] **跳过 `uid` 为空的脏行**（迁移还没回填的历史行，云端认不出）；
/// - [watchAll] 每次相关表变化推**全量**列表（可能为空），消费方自行 diff；
///   每次订阅都会立刻收到一次当前值，所以「先 [listAll] 再订阅」不会丢变更；
/// - [applyRemote] 写的 `rev` **就是远端给的 rev**，不 +1；
/// - [applyRemote] 解析不出 profile（id 与 key 都对不上本机）时**整个调用
///   no-op**，绝不插孤儿行 —— 草稿表的 `uid` 是全局唯一索引，孤儿行会把那个
///   uid 永久占住；
/// - [byLocalId] 按**本机 id** 取行；`uid` 为空、`profileId` 对不上、行不存在
///   一律返回 null（写信页据此安静地不显示任何东西）；
/// - 不存在的 uid **不是错误**：[byUid] 返回 null，[clearTombstones] 静默跳过。
///
/// ## 与 `MailStore` 的分工
///
/// `MailStore` 只读（邮件缓存是服务端的副本）；本接缝**可写**，因为草稿的
/// 编辑本来就在本机发生、服务端只是同步目标。但仍然没有「删除」的公开方法：
/// 本地删除走核心的既有路径（`LocalDao.deleteDraft`，它顺手落墓碑），这样
/// 墓碑这条账本只有一个写者。
abstract class DraftStore {
  /// 本机**所有已登录 profile** 的身份（[DraftProfileRef]），按核心的实例排序
  /// （`sort` 升序、同序按创建时间）—— 同一份列表在两次调用之间稳定，同步层
  /// 可以据此做「上一轮轮询了哪些账号」的 diff。
  ///
  /// 为什么需要它：[listAll] 只会给出**有草稿的** profile。一个账号如果本机
  /// 一条草稿都没有，它在 [listAll] / [watchAll] 里根本不存在，同步层于是永远
  /// 不会为它拉云端草稿 —— 「在另一台设备上写、这台机器本地零草稿」的那份草稿
  /// 就永远落不下来。有了这个出口，同步层才能「对每个已登录账号各拉一次」。
  Future<List<DraftProfileRef>> profiles();

  /// 按 [profileKey] 找本机 profileId；本机没有这个账号时返回 null。
  ///
  /// [profileKey] 会先按核心口径归一化（去首尾空白、转小写十六进制）再比较 ——
  /// 服务端/配置文件里拿回来的大小写不该决定「找不找得到账号」。
  ///
  /// 同一 key 命中多个 profile（「退出又登回来」留下的历史行）时返回核心排序
  /// 里的**第一个**。注意 [byUid] / [clearTombstones] **不用**这个「第一个
  /// 赢」的取舍（那会让行恰好挂在第二个 id 上时查不到，见各自的说明）。
  Future<String?> profileIdFor(String profileKey);

  /// 任意草稿变化时推**全量**快照列表（所有 profile）。
  ///
  /// 为什么是全量而不是 [DraftChange] 增量：
  /// - 草稿最多几十条，全量重算的代价远低于增量协议的复杂度；
  /// - 「删除」在增量里最容易漏（drift 给的 `kind` 在原生 SQL 写路径上是
  ///   null），漏一条的症状是云端永远留着一份已经删掉的草稿；
  /// - 消费方（同步层）本来就要按 `(profileKey, uid, rev)` 对账，diff 是它的
  ///   本职工作。
  ///
  /// 消费方要自己防回环：收到本地变化 → 标脏 → 推送 → 拉到同一条 →
  /// [applyRemote] → 又收到变化。核心**不额外发事件**，也不做「这是不是我自己
  /// 写的」的判定（它分不出来）—— 防重入是同步层的事。
  Stream<List<DraftSnapshot>> watchAll();

  /// 所有 profile 的草稿（首次全量推送用），按最近修改倒序。
  ///
  /// 过滤 `uid` 为空的脏行；profile 已经被删掉的行也跳过（它们的 profileKey
  /// 算不出来，推上去服务端也无处归档）。
  Future<List<DraftSnapshot>> listAll();

  /// 按 `(profileKey, uid)` 找一条活草稿。找不到返回 null。
  ///
  /// 为什么用 `profileKey` 而不是 `profileId` 当键：同步层手里的 uid 来自云端，
  /// 它只认识那个不透明的账号键；`profileId` 是本机 id，换设备就对不上了。
  ///
  /// 实现口径：**先按 uid 跨 profile 取行，再用行所属 profile 算出的 key 与
  /// [profileKey] 比对**。不能「先把 profileKey 映射成某个 profileId、再按它
  /// 查行」—— 同一个 key 在本机可能对应两条 profile 行（退出又登回来的历史
  /// 残留），挑中的那个未必是拥有这行的那个；症状是「云草稿在这台设备上永远
  /// 对不上」。命中多行时取 key 匹配的第一行。
  Future<DraftSnapshot?> byUid(String profileKey, String uid);

  /// 按**本机草稿行 id** 找一条活草稿；[profileId] 与行上不一致时返回 null。
  ///
  /// 存在的理由只有一条：写信页手里只有本机草稿行的 `id`（地址里的
  /// `/compose?draft=12`），它要在**页面生命周期内**问扩展一句「这条草稿有
  /// 没有要提示用户的东西」（见 `AppExtension.draftWarning`）。同步层不用它
  /// —— 那边认的是 [DraftSnapshot.uid]，跨设备才说得通。
  ///
  /// 口径与 [listAll] 一致：
  /// - `uid` 为空的脏行按「找不到」处理（跨设备身份还没回填，云端认不出，
  ///   拿它说什么都不可靠）；
  /// - `profileId` 对不上（调用方拿错实例）也返回 null —— 绝不把另一台实例的
  ///   草稿内容交出去；
  /// - [draftId] 不是正数、或本机没有这一行 → null（不是错误）。
  Future<DraftSnapshot?> byLocalId(String profileId, int draftId);

  /// 应用一份远端快照（拉取到的 upsert，或者 `deleted: true` 的服务端墓碑）。
  ///
  /// **不递增 rev**：本地 `rev` 的含义是「本地内容版本」，远端给的 rev 直接落库
  /// —— 加一的话，每拉一次就凭空多一个本地版本，冲突判定会把「没改过」当成
  /// 「改过」，然后无限生成冲突副本。走的是 DAO 的
  /// `applyRemoteDraft`（精确 UPDATE/INSERT 指定 rev），**不是** `saveDraft`。
  ///
  /// **profile 必须能解析**（否则整个调用是空操作）：
  /// 1. [DraftSnapshot.profileId] 非空且本机存在 → 用它算出的 key 与
  ///    [DraftSnapshot.profileKey] 比对，不一致 → **no-op**（这份快照属于另一个
  ///    账号/实例，不是这一行）；
  /// 2. id 为空、或本机已经没有这个 profile（退登 / 删实例 / 别的设备上的旧
  ///    id）→ 用 `profileKey` 反查 profileId；
  /// 3. 还是找不到 → **no-op**。
  ///
  /// 为什么宁可 no-op 也不插行：草稿表的 `uid` 是**全局唯一索引**（`WHERE
  /// uid != ''`），一条孤儿行会占住那个 uid —— 真正的 profile 后来再想落地同一
  /// 份草稿只会撞索引失败，而且这条孤儿行永远不属于任何能同步的账号。用户删
  /// 了实例，云端的草稿在本机就是无处可去。
  ///
  /// 同一个事务里**清掉该 uid 的本地墓碑**：远端把这条又写回来了，说明「本机
  /// 删过」这件事已经过期，留着它会让同步层把这个 uid 再发一次删除、把刚拉
  /// 下来的草稿又抹掉。
  ///
  /// `deleted: true` 是**服务端删除**：删本机行（连同「打开中」标记），并且
  /// **不写**本地墓碑 —— 那会把一次远端删除记成一次本机删除，下次推送又发
  /// 回去，两端互相删。要不要应用（比如本地脏、rev 更高）由调用方判定。
  /// 这条分支**不做上面的 profile 解析**：它的语义只是「让本机不再有这条」，
  /// 按 `(profileId, uid)` 匹配不到任何行就静默完成（profile 已经不在时正好
  /// 什么都不用做）。
  Future<void> applyRemote(DraftSnapshot remote);

  /// 删掉这些墓碑（同步层把 `deleted=true` 推成功之后调用）。
  ///
  /// 不存在的 uid 静默跳过；[profileKey] 在本机没有对应 profile 时整个调用是
  /// 空操作（profile 都删了，墓碑也跟着 `_clearDataOf` 清了）。
  ///
  /// 同一个 key 命中**多个** profile 时逐个清（不是「第一个赢」）：墓碑挂在
  /// 写下它的那个 profileId 下面，只清第一个的话，第二个 id 下的墓碑会成为
  /// 一条永远清不掉的待推送删除 —— 每轮同步都把它再发一次。
  Future<void> clearTombstones(String profileKey, Iterable<String> uids);

  /// 还没推出去的删除（同步层启动时补发）。
  ///
  /// 返回的快照 `deleted` 恒为 true，`rev` 是墓碑 rev（= 删除前 rev + 1）；
  /// `subject` / `body` / `recipients` / `attachmentPaths` 都是空 —— 行已经删了，
  /// 这些内容本来就不该再被读出来。
  ///
  /// **`updatedAt` 是删除时间**，不是草稿最后修改时间（行都没了，那个时间也跟
  /// 着没了）。只该拿它判断「这次删除发生得早还是晚」，不要拿它和草稿的
  /// `rev` / `updatedAt` 做先后比较。它同样来自 drift，比较/序列化前 `.toUtc()`。
  Future<List<DraftSnapshot>> listTombstones();
}
