import '../../core/config/app_defaults.dart';
import '../../core/db/database.dart';
import '../../core/error/app_exception.dart';
import '../../instance/profile_runtime.dart';
import '../../instance/runtime_registry.dart';
import '../models/enums.dart';
import '../models/instance_capabilities.dart';
import '../models/mailbox_account.dart';
import '../models/profile.dart';
import '../models/user_info.dart';
import 'capability_repository.dart';

/// 邮箱（服务端的 `account` 表，UI 上叫「邮箱」）的同步与本地读写。
///
/// 核心是一条**降级路径**：
/// `GET /account/list` 在 `security.js` 的 `requirePerms` 里，需要
/// `account:query` 权限。自建实例的默认角色「普通用户」没有这个 perm
/// （它的 `send_type` 是 `ban`、`account_count` 是 10），所以新装实例的
/// 普通用户会拿到 403。这时不能报错，要用 `loginUserInfo.account`
/// 这一个主邮箱把收信/发信/看详情全撑起来 —— 只是看不到「其他邮箱」。
class AccountRepository {
  AccountRepository({
    required this.db,
    required this.registry,
    required this.capabilities,
    this.onDiskPurge,
  });

  final AppDatabase db;
  final RuntimeRegistry registry;
  final CapabilityRepository capabilities;

  /// 删邮箱后清**磁盘上**附件目录的方式。与
  /// `EmailRepository.onDiskPurge` 同一套接线（`core_providers` 里指向
  /// `attachmentRepositoryProvider.purgeMail`），可选的理由也一样。
  final Future<void> Function(String profileId, int emailId)? onDiskPurge;

  /// 本地已有的邮箱（UI 优先 watch 这个，网络刷新在后台跑）。
  Stream<List<MailboxAccount>> watch(String profileId) =>
      db.profileDao.watchMailboxes(profileId);

  Future<List<MailboxAccount>> of(String profileId) =>
      db.profileDao.mailboxesOf(profileId);

  /// 从服务端刷新邮箱列表。
  ///
  /// [fallback] 是 `loginUserInfo` 里那个主邮箱 —— 403 时用它兜底。
  /// 返回本次实际可用的邮箱列表（**不抛异常**：拿不到就返回本地缓存，
  /// 让 UI 用旧数据继续工作）。
  Future<List<MailboxAccount>> refresh(
    Profile profile, {
    UserInfo? fallback,
    bool wipeMissing = true,
  }) async {
    final runtime = registry.peek(profile.id);
    if (runtime == null || runtime.isDisposed) return of(profile.id);

    List<MailboxAccount> fetched;
    var cameFromServer = false;
    try {
      fetched = await _fetchAll(runtime);
      cameFromServer = true;
      await capabilities.save(
        profile.id,
        (await capabilities.of(profile.id))
            .copyWith(hasAccountQuery: ProbeState.available),
      );
    } on ApiException catch (e) {
      if (e.code == 403 || e.code == 501) {
        // 没权限（403）或该版本没这个端点（501）→ 降级到主邮箱，
        // 并在能力里记一笔，UI 据此显示「仅显示主邮箱」的提示。
        fetched = _fallbackOnly(fallback, profile);
        await capabilities.noteDenied(profile.id, CapabilityFlag.accountQuery);
      } else {
        return of(profile.id);
      }
    } on AppException {
      return of(profile.id);
    }

    // 服务端返回空（老版本、或该用户真的没邮箱）→ 也退到主邮箱，
    // 否则整个 App 会停在「没有可用邮箱」而无处可去。
    if (fetched.isEmpty) fetched = _fallbackOnly(fallback, profile);
    if (fetched.isEmpty) return of(profile.id);

    await db.profileDao.upsertMailboxes(profile.id, fetched);
    // **只在真的从 /account/list 拿到完整列表时**才删本地多余行 ——
    // 降级路径下删，会把用户其他邮箱的缓存一并抹掉。
    if (cameFromServer && wipeMissing) {
      await db.profileDao.removeMailboxesNotIn(
        profile.id,
        fetched.map((m) => m.accountId).where((id) => id > 0).toSet(),
      );
    }
    return of(profile.id);
  }

  /// 把 `loginUserInfo` 里的主邮箱记进本地（登录后第一件事）。
  ///
  /// 这一步保证「冷启动离线时也有一个邮箱可点」——
  /// [Profile.email] 是登录后写回的，不依赖任何带权限的接口。
  Future<void> seedPrimary(UserInfo user, Profile profile) async {
    final primary = MailboxAccount.fromLoginUserInfo(user.account);
    if (primary != null) {
      await db.profileDao.upsertMailboxes(profile.id, <MailboxAccount>[primary]);
      return;
    }
    if (profile.email.isEmpty) return;
    await db.profileDao.upsertMailboxes(profile.id, <MailboxAccount>[
      MailboxAccount(email: profile.email, name: profile.userName),
    ]);
  }

  /// 翻页取完所有邮箱（`size ≤ 30`，游标是 `(sort, accountId)` 组合）。
  Future<List<MailboxAccount>> _fetchAll(ProfileRuntime runtime) async {
    final result = <MailboxAccount>[];
    int? lastSort;
    int? lastAccountId;
    // 上限 10 页（300 个邮箱）—— 正常用户远小于这个数。加上限是防止
    // 服务端游标行为异常（例如忽略 lastSort）时无限循环。
    for (var page = 0; page < 10; page++) {
      final chunk = await runtime.accountApi.list(
        size: AppDefaults.accountPageSize,
        lastSort: lastSort,
        lastAccountId: lastAccountId,
      );
      if (chunk.isEmpty) break;
      result.addAll(chunk);
      if (chunk.length < AppDefaults.accountPageSize) break;
      final last = chunk.last;
      lastSort = last.sort;
      lastAccountId = last.accountId;
    }
    return result;
  }

  List<MailboxAccount> _fallbackOnly(UserInfo? fallback, Profile profile) {
    final primary = MailboxAccount.fromLoginUserInfo(fallback?.account);
    if (primary != null) return <MailboxAccount>[primary];
    // 连 loginUserInfo 都没拿到（离线冷启动）→ 用 profile 里记的邮箱造一个。
    // accountId 为 0：调用方会走 `allReceive=1` 的查询，正好不需要真实 id。
    if (profile.email.isEmpty) return const <MailboxAccount>[];
    return <MailboxAccount>[
      MailboxAccount(email: profile.email, name: profile.userName),
    ];
  }

  // ------------------------------------------------------- 邮箱管理动作
  //
  // UI **不直接碰 `accountApi`**：这四个是它唯一的入口。
  // 分工与仓库里其它 repository 一致 —— 服务端是唯一真相，本地跟着走；
  // 「服务端成功之后才动本地」在 [remove] 里尤其要紧（删邮箱是不可恢复的）。

  /// 加一个邮箱。返回服务端新建的那一行（失败时抛，由 UI 显示
  /// `ApiException.userMessage` —— 服务端回的是中文人话）。
  ///
  /// 成功的行**立刻落库**：用户点完「添加」当场就该在列表里看到它，
  /// 不必等下一次 `refresh`（那要等一轮 /account/list 往返）。
  Future<MailboxAccount?> add(
    Profile profile,
    String email, {
    String? turnstileToken,
  }) async {
    final runtime = _readyRuntime(profile);
    if (runtime == null) return null;
    final added =
        await runtime.accountApi.add(email, turnstileToken: turnstileToken);
    if (added == null) return null;
    await db.profileDao.upsertMailboxes(profile.id, <MailboxAccount>[added]);
    return added;
  }

  /// 删一个邮箱：**服务端物理删除**，不可恢复。
  ///
  /// 顺序是刻意的：服务端先删，**成功之后**才动本地。反过来的话，
  /// 一次网络抖动会让用户「本地看起来删掉了、服务端还在」，下一轮
  /// `refresh` 又冒出来 —— 而他可能已经把这个地址告诉别人了。
  ///
  /// 本地清理走 `MailDao.purgeMailbox`（连带 `mailbox:<id>:type:*` 的同步
  /// 游标），再用它返回的 `emailId` 逐封清磁盘附件。
  Future<void> remove(Profile profile, int accountId) async {
    final runtime = _readyRuntime(profile);
    if (runtime == null) return;
    await runtime.accountApi.delete(accountId);

    final purged = await db.mailDao.purgeMailbox(profile.id, accountId);
    final purge = onDiskPurge;
    if (purge != null) {
      for (final emailId in purged) {
        await purge(profile.id, emailId);
      }
    }
  }

  /// 改显示名。服务端 `setName` 只拦长度 > 30，**不拦空串** ——
  /// 空串由调用方在本地挡住（`displayName` 会退化成邮箱地址，看起来像改坏了）。
  Future<void> setName(Profile profile, int accountId, String name) async {
    final runtime = _readyRuntime(profile);
    if (runtime == null) return;
    await runtime.accountApi.setName(accountId, name);
  }

  /// 置顶。服务端把主邮箱的 `sort` 抬高、这个邮箱设成 `mainSort - 1`
  /// （即「紧跟主邮箱之后」），所以本地**不自己算顺序**，重拉一次就好。
  Future<void> setAsTop(Profile profile, int accountId) async {
    final runtime = _readyRuntime(profile);
    if (runtime == null) return;
    await runtime.accountApi.setAsTop(accountId);
    await refresh(profile);
  }

  /// 拿一个可用的 runtime；坏了/还没建好时返回 null（动作静默不做）。
  ///
  /// 与 `refresh` 开头那两句同一条口径：宁可什么也不做，也不要在没有
  /// runtime 的时候抛一个用户看不懂的异常。
  ProfileRuntime? _readyRuntime(Profile profile) {
    final runtime = registry.peek(profile.id);
    if (runtime == null || runtime.isDisposed) return null;
    return runtime;
  }

  /// 挑出当前选中的邮箱：显式指定 > 服务端标了「收全部」的 > 第一个。
  MailboxAccount? pick(List<MailboxAccount> list, int? accountId) {
    if (list.isEmpty) return null;
    if (accountId != null && accountId > 0) {
      for (final a in list) {
        if (a.accountId == accountId) return a;
      }
    }
    return list.primaryOrNull;
  }

  /// 该邮箱服务端是否开着 allReceive。
  ///
  /// 只是展示用：服务端的 `setAllReceive` 是**切换语义**（开一个清掉其他），
  /// 「收全部邮箱」在 App 里是用 `allReceive=1` 的查询实现的，不靠这个开关。
  bool isAllReceiveOwner(List<MailboxAccount> list, int accountId) =>
      list.any((a) => a.accountId == accountId && a.isAllReceive);

  /// 收件方向的服务端 `type` 值（可读性封装，避免各处写 0）。
  static int get receiveType => MailType.receive;

  static int get sendType => MailType.send;
}
