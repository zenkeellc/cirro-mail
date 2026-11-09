import 'dart:convert';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;

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
/// 映射是**双向**的：读（快照）走 `profileId → key`；写（[applyRemote]）与
/// 按 key 定位（[byUid] / [clearTombstones] / [profileIdFor]）走 `key → profileId`。
/// 后者不能实现成「同 key 第一个 profile 赢」—— 同一台设备上「退出又登回来」
/// 会留下两条指向同一云端账号的 profile 行，行/墓碑挂在哪个 id 下面是不定的，
/// 只认第一个就会漏掉另一半（见 [_profileIdsForKey]）。
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
  Future<List<DraftProfileRef>> profiles() async {
    final profiles = await _db.profileDao.allProfiles();
    return <DraftProfileRef>[
      for (final profile in profiles)
        DraftProfileRef(
          profileId: profile.id,
          profileKey: _profileKeyOf(profile),
          accountEmail: profile.email,
          // `Profile.host` 已经去掉了结尾 `/api`，正是「站点根」。只给展示/诊断
          // 用 —— 算 key 一律走 [_profileKeyOf]，别让调用方拿它自己再算一遍。
          instanceHost: profile.host,
        ),
    ];
  }

  @override
  Future<String?> profileIdFor(String profileKey) async {
    final ids = await _profileIdsForKey(profileKey);
    return ids.isEmpty ? null : ids.first;
  }

  @override
  Future<List<DraftSnapshot>> listAll() async =>
      _snapshotsOfDrafts(await _db.localDao.listAllDrafts());

  @override
  Future<DraftSnapshot?> byUid(String profileKey, String uid) async {
    final key = _normalizeKey(profileKey);
    if (uid.isEmpty || key.isEmpty) return null;
    // 先按 uid 跨 profile 取行，再用**行自己的** profile 算 key 比对 ——
    // 不能先「profileKey → 第一个 profileId」再按它查行（同一 key 在本机可能
    // 有两条 profile 行，行未必挂在第一个下面）。
    final rows = await _db.localDao.draftsByUid(uid);
    if (rows.isEmpty) return null;
    final profiles = await _profilesById();
    for (final row in rows) {
      final profile = profiles[row.profileId];
      if (profile == null) continue;
      if (_profileKeyOf(profile) != key) continue;
      return _snapshotOf(row, profile);
    }
    return null;
  }

  @override
  Future<DraftSnapshot?> byLocalId(String profileId, int draftId) async {
    // 正数才是「库里的行」；0 / 负数在写信页表示「这一页还没有草稿行」。
    if (profileId.isEmpty || draftId <= 0) return null;
    final row = await _db.localDao.findDraft(draftId);
    // profile 对不上 = 调用方拿错了实例。与 [byUid] 同一条纪律：宁可查不到，
    // 也不把另一台实例的草稿内容交出去。
    if (row == null || row.profileId != profileId) return null;
    // uid 为空是「迁移还没回填」的脏行（与 [listAll] 同一口径）：跨设备身份都
    // 还没有，扩展拿它做任何判断都不可靠。
    if (row.uid.isEmpty) return null;
    // 行还在、profile 却被删掉了（`_clearDataOf` 清到一半的残行）：key 算不
    // 出来，快照给不完整，当找不到。
    final profile = await _db.profileDao.findProfile(row.profileId);
    if (profile == null) return null;
    return _snapshotOf(row, profile);
  }

  @override
  Future<void> applyRemote(DraftSnapshot remote) async {
    if (remote.deleted) {
      // 服务端说这条没了：删本机行，**不**写本地墓碑（否则会把一次远端删除
      // 记成一次本机删除、再推回去，两端互相删）。见 DAO 的
      // `deleteRemoteDraft`。这条分支不做 profile 解析：它只是「让本机不再有
      // 这条」，按 (profileId, uid) 匹配不到行就静默完成。
      return _db.localDao.deleteRemoteDraft(remote.profileId, remote.uid);
    }
    if (remote.uid.isEmpty) return;
    final profileId = await _resolveProfileId(remote);
    if (profileId == null) {
      // 空操作是**目的**，不是遗漏：uid 在草稿表上是全局唯一索引，插一条
      // profileKey 解析不出来的行会永久占住那个 uid，真正的 profile 之后想
      // 落地同一份草稿只会撞索引失败。
      debugPrint('DraftStore.applyRemote: 解析不出 profile，已跳过 '
          '(profileId=${remote.profileId}, '
          'key=${_keyPrefix(remote.profileKey)}, uid=${remote.uid})');
      return;
    }
    // 走 `applyRemoteDraft` 而不是 `saveDraft`：后者会把 rev +1（本地内容
    // 版本语义），而这里写的必须是远端给的 rev。见 DAO 里那段注释。
    await _db.localDao.applyRemoteDraft(
      profileId: profileId,
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
    // 逐个清所有 key 匹配的 profile：墓碑挂在写下它的那个 profileId 下面，
    // 只清「第一个」会留下一条永远发不出去、每轮都重发的删除。
    for (final profileId in await _profileIdsForKey(profileKey)) {
      await _db.localDao.deleteTombstones(profileId, list);
    }
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
          // `updatedAt` = **删除时间**（墓碑的 `deleted_at`），不是草稿最后
          // 修改时间 —— 行都没了，那个时间也跟着没了。同步层只该拿它判断
          // 「这次删除发生得早还是晚」。
          updatedAt: row.deletedAt,
        ),
      );
    }
    return out;
  }

  // ------------------------------------------------------------ 内部

  String _profileKeyOf(Profile profile) =>
      draftProfileKey(profile.host, profile.email);

  /// `profileKey` 的入参归一化：去首尾空白 + 小写。
  ///
  /// `draftProfileKey` 产出的是小写十六进制，但同步层手里的 key 可能来自服务端
  /// JSON、配置文件或用户手填 —— 大小写不该决定「找不找得到账号」。这里只做
  /// 大小写/空白，**不做**任何哈希或语义猜测。
  String _normalizeKey(String profileKey) => profileKey.trim().toLowerCase();

  /// 日志里的 profileKey 前缀（与 `DraftSnapshot.toString` 同一口径）。
  String _keyPrefix(String profileKey) {
    final key = _normalizeKey(profileKey);
    return key.length <= 8 ? key : '${key.substring(0, 8)}…';
  }

  /// `profileId → Profile`。`allProfiles` 已按 `sort` / `createdAt` 排好，
  /// 这里保持插入顺序（见 [_profileIdsForKey] 的「多个匹配」说明）。
  Future<Map<String, Profile>> _profilesById() async {
    final profiles = await _db.profileDao.allProfiles();
    return <String, Profile>{for (final p in profiles) p.id: p};
  }

  /// 计算 key 等于 [profileKey] 的所有 profileId，按核心实例排序。
  ///
  /// **返回全部而不是「第一个」**：同一个 key 可能对应两条 profile 行（退出又
  /// 登回来留下的历史行，两个 id 指向同一个云端账号）。`byUid` 要按行自己的
  /// profile 匹配，`clearTombstones` 要把所有匹配 profile 下的墓碑都清掉 ——
  /// 只要一个「第一个赢」的映射，就会漏掉挂在第二个 id 上的行/墓碑。
  /// [profileIdFor] 取 `first`，那是它自己的单值契约。
  Future<List<String>> _profileIdsForKey(String profileKey) async {
    final key = _normalizeKey(profileKey);
    if (key.isEmpty) return const <String>[];
    final profiles = await _db.profileDao.allProfiles();
    return <String>[
      for (final profile in profiles)
        if (_profileKeyOf(profile) == key) profile.id,
    ];
  }

  /// 为一份远端快照解析要落地的本机 profileId；解析不出来返回 null（= 调用方
  /// 必须 no-op）。
  ///
  /// 优先级是「同一台设备上更可信的证据优先」：
  /// 1. `remote.profileId` 本机存在 → 用它算出的 key 校验，**不一致就拒绝**
  ///    （调用方拿错快照/写错 id 时，绝不能落进另一个账号）；
  /// 2. id 为空、或本机已经没有这个 profile（退登 / 删实例 / 别的设备上的
  ///    旧 id）→ 用 key 反查，这是唯一还能认回账号的证据；
  /// 3. 都找不到 → null。
  ///
  /// 第 1 步为什么不用「key 对得上就按 key 落地」：id 明确指到一个**别的**账号
  /// 时，按 key 落进另一个账号会把「调用方搞错了」这种 bug 变成一个安静的
  /// 串号写入。
  Future<String?> _resolveProfileId(DraftSnapshot remote) async {
    final key = _normalizeKey(remote.profileKey);
    final profiles = await _profilesById();
    if (remote.profileId.isNotEmpty) {
      final byId = profiles[remote.profileId];
      if (byId != null) {
        if (_profileKeyOf(byId) == key) return byId.id;
        debugPrint('DraftStore.applyRemote: profileId=${remote.profileId} 的 '
            'profileKey 与快照不一致（uid=${remote.uid}），跳过');
        return null;
      }
    }
    // id 为空或本机已无此 profile：用 key 反查（同 key 多条时按核心排序取第一个）。
    final ids = await _profileIdsForKey(key);
    return ids.isEmpty ? null : ids.first;
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
