import 'dart:convert';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:crypto/crypto.dart';

import '../../data/models/profile.dart';
import 'database.dart';
import 'mappers.dart' show decodeAttachmentPaths;

/// `profileKey` 的**唯一**算法：`sha256(站点根 + "\n" + lowercase(邮箱))`。
///
/// 为什么要有这么一个不透明键（而不是直接用 `profileId`）：跨设备认账号靠的
/// 是「同一个实例、同一个登录邮箱」，而 `profileId` 是本机 UUID，换台设备就是
/// 另一个。服务端只需要这个等价关系，所以它把键当不透明字符串存。
///
/// 归一化只有两处，**少一处就会在别人的机器上分叉**：
/// - `host` 统一小写（`Mail.Example.com` 与 `mail.example.com` 是同一个站）；
///   `Profile.host` 已经去掉了结尾 `/api`，这里不再动路径与端口；
/// - 邮箱去首尾空白再小写（服务端登录时就是这么比的）。
///
/// 中间的分隔符是换行而不是 `:`/`|`：邮箱里不可能出现换行，所以
/// `("a\nb", "c")` 与 `("a", "b\nc")` 不会撞成同一个键。
String draftProfileKey(String hostRoot, String email) => sha256
    .convert(
      utf8.encode('${hostRoot.toLowerCase()}\n${email.trim().toLowerCase()}'),
    )
    .toString();

/// [DraftStore] 的 drift 实现 —— 核心对扩展暴露「本地草稿」的唯一窗口。
///
/// ## 它做什么、不做什么
///
/// - **读写本地库**：`DraftStore` 可写（草稿的编辑本来就在本机发生），但写
///   只发生在 [applyRemote] 与 [clearTombstones] 这两个**同步层专用**的入口，
///   没有「随便改一条草稿」的方法 —— 用户编辑走撰写页与 `ComposeDraftSaver`。
/// - **不做冲突判定**：本地脏、rev 更高时要不要应用远端，是同步层的事
///   （spec §6.5）。这里只保证「按你给的 rev 落库，绝不 +1」。
/// - **不做网络**。
///
/// ## profile 映射
///
/// 草稿表里只有 `profileId`，而快照里要 `accountEmail` / `profileKey` —— 两者
/// 都得从 `profiles` 表拿。所以每个读路径都要 join 一次 profile 映射：
/// `profileId → Profile` 的映射**读的时候现算**，不缓存。缓存的话，用户改了
/// 登录邮箱或删了实例之后，同步层会拿着一份过期的 profileKey 继续推。
///
/// profile 已经不在表里的草稿行**跳过**：它的 profileKey 算不出来，推上去
/// 服务端也无处归档（正常路径不会出现 —— `ProfileDao._clearDataOf` 会连草稿
/// 一起清，这里只防「清到一半被杀」的残行）。
class CoreDraftStore implements DraftStore {
  CoreDraftStore(this._db);

  final AppDatabase _db;

  @override
  Stream<List<DraftSnapshot>> watchAll() {
    // 只订阅 `drafts` 这一张表：删草稿是**硬删**（行消失 → 这里推一次少了
    // 一条的全量），新增/修改是写入（推一次新的全量）。墓碑变化不在这里推 ——
    // 同步层用 [listTombstones] 拉，它不需要「墓碑出现」这个瞬时事件。
    //
    // profile 每次都重新读（`allProfiles`，不缓存在字段里）：用户改了实例的
    // 登录邮箱，profileKey 就变了，而 `drafts` 表一行都没动。代价是每次草稿
    // 变化多一条 `SELECT * FROM profiles`（实例数是个位数），换来的是不会拿
    // 着一份过期的账号键去推。**注意**：只改 profile、不动草稿时这里不会自己
    // 推一次；下次草稿变化或下一轮 [listAll] 会带上新键。
    return _db.localDao.watchDrafts().asyncMap(_snapshotsOfDrafts);
  }

  @override
  Future<List<DraftSnapshot>> listAll() async =>
      _snapshotsOfDrafts(await _db.localDao.listAllDrafts());

  @override
  Future<DraftSnapshot?> byUid(String profileKey, String uid) async {
    if (uid.isEmpty) return null;
    final profile = (await _profilesByKey())[profileKey];
    if (profile == null) return null;
    final row = await _db.localDao.findDraftByUid(profile.id, uid);
    if (row == null) return null;
    return _snapshotOf(row, profile);
  }

  @override
  Future<void> applyRemote(DraftSnapshot remote) {
    if (remote.deleted) {
      // 服务端说这条没了：删本机行，**不**写本地墓碑（否则会把一次远端删除
      // 记成一次本机删除、再推回去，两端互相删）。见 DAO 的
      // `deleteRemoteDraft`。
      return _db.localDao.deleteRemoteDraft(remote.profileId, remote.uid);
    }
    // 走 `applyRemoteDraft` 而不是 `saveDraft`：后者会把 rev +1（本地内容
    // 版本语义），而这里写的必须是远端给的 rev。见 DAO 里那段注释。
    return _db.localDao.applyRemoteDraft(
      profileId: remote.profileId,
      uid: remote.uid,
      rev: remote.rev,
      accountEmail: remote.accountEmail,
      // 与撰写页（`encodeRecipientAddresses`）**同一种编码**：裸地址数组的
      // JSON。写成服务端那种 `[{address,name}]` 的话，写回之后用户再打开这条
      // 草稿会看到收件人全空（`decodeRecipientAddresses` 只认假数组）。
      recipientsJson: _encodeRecipients(remote.recipients),
      subject: remote.subject,
      content: remote.body,
      attachmentPaths: remote.attachmentPaths,
      updatedAt: remote.updatedAt,
    );
  }

  @override
  Future<void> clearTombstones(String profileKey, Iterable<String> uids) async {
    final list = uids.toList(growable: false);
    if (list.isEmpty) return;
    final profile = (await _profilesByKey())[profileKey];
    if (profile == null) return;
    await _db.localDao.deleteTombstones(profile.id, list);
  }

  @override
  Future<List<DraftSnapshot>> listTombstones() async {
    final rows = await _db.localDao.listDraftTombstones();
    if (rows.isEmpty) return const <DraftSnapshot>[];
    final profiles = await _profilesById();
    final out = <DraftSnapshot>[];
    for (final row in rows) {
      final profile = profiles[row.profileId];
      if (profile == null) continue;
      out.add(
        DraftSnapshot(
          profileId: row.profileId,
          accountEmail: profile.email,
          profileKey: _profileKeyOf(profile),
          uid: row.uid,
          rev: row.rev,
          deleted: true,
          // 墓碑没有内容：行已经删了，正文/收件人/附件都不该再被读出来。
          subject: '',
          recipients: const <String>[],
          body: '',
          attachmentPaths: const <String>[],
          updatedAt: row.deletedAt,
        ),
      );
    }
    return out;
  }

  // ------------------------------------------------------------ 内部

  String _profileKeyOf(Profile profile) =>
      draftProfileKey(profile.host, profile.email);

  /// `profileId → Profile`。`allProfiles` 已按 `sort` / `createdAt` 排好，
  /// 这里保持插入顺序（见 [_profilesByKey] 的「第一个赢」说明）。
  Future<Map<String, Profile>> _profilesById() async {
    final profiles = await _db.profileDao.allProfiles();
    return <String, Profile>{for (final p in profiles) p.id: p};
  }

  /// `profileKey → Profile`。
  ///
  /// **同一个 key 只保留第一个**（`sort` 最小的那个）：`profileKey` 的语义是
  /// 「同一实例同一账号」，正常情况下同一台设备只会有一个这样的 profile；
  /// 出现两个多半是「退出登录又登回来」留下的历史行，两个 id 指向同一个云端
  /// 账号。取第一个是为了让 [byUid] / [clearTombstones] 的结果稳定，而不是
  /// 每次查询挑到不同的那一行。
  Future<Map<String, Profile>> _profilesByKey() async {
    final profiles = await _db.profileDao.allProfiles();
    final map = <String, Profile>{};
    for (final p in profiles) {
      map.putIfAbsent(_profileKeyOf(p), () => p);
    }
    return map;
  }

  Future<List<DraftSnapshot>> _snapshotsOfDrafts(List<DbDraft> rows) async {
    // 空列表是最常见的返回值（库刚开、用户没有草稿）。这时不用白读一次
    // profiles 表 —— 订阅方每次收到 `[]` 都会跑一遍这里。
    if (rows.isEmpty) return const <DraftSnapshot>[];
    final profiles = await _profilesById();
    final out = <DraftSnapshot>[];
    for (final row in rows) {
      // uid 为空的是「迁移还没回填」的脏行：云端认不出它们，进快照只会让
      // 同步层把它们当成新草稿一遍遍推送。它们留在本地，等下一次落库补上身份。
      if (row.uid.isEmpty) continue;
      final profile = profiles[row.profileId];
      if (profile == null) continue;
      out.add(_snapshotOf(row, profile));
    }
    return out;
  }

  DraftSnapshot _snapshotOf(DbDraft row, Profile profile) => DraftSnapshot(
        profileId: row.profileId,
        // 草稿行上的 `account_email` 才是「这封信从哪个地址发」，空的时候
        // 回落到账号邮箱：迁移前的草稿行、以及从没选过发件人的空草稿都是空串。
        accountEmail:
            row.accountEmail.isEmpty ? profile.email : row.accountEmail,
        profileKey: _profileKeyOf(profile),
        uid: row.uid,
        rev: row.rev,
        deleted: false,
        subject: row.subject,
        recipients: _decodeRecipients(row.recipientsJson),
        body: row.content,
        attachmentPaths: decodeAttachmentPaths(row.attachmentPathsJson),
        updatedAt: row.updatedAt,
      );

  /// 与 `features/compose/compose_text.dart` 的
  /// `encodeRecipientAddresses` **逐字一致**（空 → 空串，否则 JSON 数组）。
  ///
  /// 不 import 那个文件：它在 `features/` 里，`core/db` 反过来依赖 UI 层会把
  /// 依赖方向拧歪（`compose_text.dart` 自己也不该被 db 层拉进来）。两处各写
  /// 三行、编码格式写死在注释里，比一条反向 import 划算。
  String _encodeRecipients(List<String> addresses) =>
      addresses.isEmpty ? '' : jsonEncode(addresses);

  /// 与 `decodeRecipientAddresses` 同一套宽容策略：坏 JSON / 不是数组 →
  /// 空列表，不让一条坏草稿把整个同步层带崩。**只认裸地址数组**（草稿自己的
  /// 编码）；服务端那种 `[{"address":…}]` 形状在这里当空处理。
  List<String> _decodeRecipients(String raw) {
    if (raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
    } catch (_) {
      // 坏数据当空，理由见上。
    }
    return const <String>[];
  }
}
