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
  final DateTime updatedAt;

  @override
  String toString() => 'DraftSnapshot($profileKey/$uid, rev=$rev, '
      'deleted=$deleted, "$subject", '
      '${recipients.length} 收件人 / ${attachmentPaths.length} 附件)';
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
/// - [listAll] **跳过 `uid` 为空的脏行**（迁移还没回填的历史行，云端认不出）；
/// - [watchAll] 每次相关表变化推**全量**列表（可能为空），消费方自行 diff；
///   每次订阅都会立刻收到一次当前值，所以「先 [listAll] 再订阅」不会丢变更；
/// - [applyRemote] 写的 `rev` **就是远端给的 rev**，不 +1；
/// - 不存在的 uid **不是错误**：[byUid] 返回 null，[clearTombstones] 静默跳过。
///
/// ## 与 `MailStore` 的分工
///
/// `MailStore` 只读（邮件缓存是服务端的副本）；本接缝**可写**，因为草稿的
/// 编辑本来就在本机发生、服务端只是同步目标。但仍然没有「删除」的公开方法：
/// 本地删除走核心的既有路径（`LocalDao.deleteDraft`，它顺手落墓碑），这样
/// 墓碑这条账本只有一个写者。
abstract class DraftStore {
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
  Future<DraftSnapshot?> byUid(String profileKey, String uid);

  /// 应用一份远端快照（拉取到的 upsert，或者 `deleted: true` 的服务端墓碑）。
  ///
  /// **不递增 rev**：本地 `rev` 的含义是「本地内容版本」，远端给的 rev 直接落库
  /// —— 加一的话，每拉一次就凭空多一个本地版本，冲突判定会把「没改过」当成
  /// 「改过」，然后无限生成冲突副本。走的是 DAO 的
  /// `applyRemoteDraft`（精确 UPDATE/INSERT 指定 rev），**不是** `saveDraft`。
  ///
  /// 同一个事务里**清掉该 uid 的本地墓碑**：远端把这条又写回来了，说明「本机
  /// 删过」这件事已经过期，留着它会让同步层把这个 uid 再发一次删除、把刚拉
  /// 下来的草稿又抹掉。
  ///
  /// `deleted: true` 是**服务端删除**：删本机行（连同「打开中」标记），并且
  /// **不写**本地墓碑 —— 那会把一次远端删除记成一次本机删除，下次推送又发
  /// 回去，两端互相删。要不要应用（比如本地脏、rev 更高）由调用方判定。
  Future<void> applyRemote(DraftSnapshot remote);

  /// 删掉这些墓碑（同步层把 `deleted=true` 推成功之后调用）。
  ///
  /// 不存在的 uid 静默跳过；[profileKey] 在本机没有对应 profile 时整个调用是
  /// 空操作（profile 都删了，墓碑也跟着 `_clearDataOf` 清了）。
  Future<void> clearTombstones(String profileKey, Iterable<String> uids);

  /// 还没推出去的删除（同步层启动时补发）。
  ///
  /// 返回的快照 `deleted` 恒为 true，`rev` 是墓碑 rev（= 删除前 rev + 1）；
  /// `subject` / `body` / `recipients` / `attachmentPaths` 都是空 —— 行已经删了，
  /// 这些内容本来就不该再被读出来。
  Future<List<DraftSnapshot>> listTombstones();
}
