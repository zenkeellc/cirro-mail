import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/config/app_defaults.dart';
import '../../core/db/database.dart';
import '../../core/error/app_exception.dart';
import '../../core/storage/prefs_store.dart';
import '../../core/util/email_address.dart';
import '../../instance/runtime_registry.dart';
import '../models/enums.dart';
import '../models/mail_page.dart';
import '../models/mail_ref.dart';
import '../models/mail_row.dart';
import '../models/profile.dart';
import '../api/email_api.dart';
import 'capability_repository.dart';
import 'profile_repository.dart';

/// 邮件的读写编排：拉取 → 落库 → 写操作「服务端优先、本地跟随」。
///
/// 三条贯穿全文件的原则：
/// 1. **写操作一律带 [MailRef]**。聚合列表里不同实例的 `emailId` 会重号，
///    用裸 int 迟早会改到别的实例的同号邮件。
/// 2. **已读本地优先，星标/删除服务端优先**。标已读是用户点开一封邮件就
///    要看见的结果，等一个往返还等于是「点了没反应」；而且服务端的 `unread`
///    是单调的（只会被置 1），本地先标不会比服务端更超前 —— 所以先在本地写、
///    再发 `PUT`，失败回滚。星标（`/email/latest` 不带 `isStar`，靠 `starKnown`
///    分辨「缺字段」与「值为 0」）与删除（物理删除，不可恢复）都不满足这个
///    条件，仍然服务端成功后才改本地。
/// 3. **本地库负责列表，网络负责增量**。UI 只 watch 本地；
///    [syncMailbox] 把新数据灌进去后列表自然刷新 —— 不需要 UI 自己管分页状态。
class EmailRepository {
  EmailRepository({
    required this.db,
    required this.registry,
    required this.capabilities,
    required this.profiles,
    required this.prefs,
    this.onDiskPurge,
    this.onAccountIdsRepaired,
  });

  final AppDatabase db;
  final RuntimeRegistry registry;
  final CapabilityRepository capabilities;
  final ProfileRepository profiles;

  /// 「本地有行从 `account_id = 0` 被归位了」的通知。
  ///
  /// 归位这件事本身只写库（`reassignAccountIds`），但 UI 需要知道**发生过** ——
  /// 用户报告「切成某个邮箱列表是空的」，而修好之后列表会自己冒出来，
  /// 中间那几秒他需要一个解释，否则只会以为又卡住了。
  /// 做成回调而不是让 repository 去碰任何 UI/provider：那一层不在这儿。
  final void Function(String profileId, int repaired)? onAccountIdsRepaired;

  /// 「后台预取完整正文」这个开关存在 prefs 里（设置页可关）。
  ///
  /// 早先这个设置**是个死开关** —— 有开关、有文案、默认开，但没有任何地方
  /// 读它：`list()` 从不传 `full`，于是每一行都只落摘要，正文永远等用户
  /// 打开时补拉。需求三的「灰点会自己消失」正是靠这里传 `full: true`。
  final PrefsStore prefs;

  /// 删邮件后清**磁盘上**附件目录的方式。
  ///
  /// 刻意做成**可选**且是一个回调，而不是直接持有 `AttachmentRepository`：
  /// 1. 可选 —— 5 个既有测试与 `background_sync_task.dart` 都用 5 参形式，
  ///    改成必填是一次与本功能无关的破坏；
  /// 2. 回调 —— repository 之间不该互相持有，接线在 `core_providers` 里做
  ///    （`attachmentRepositoryProvider.purgeMail`）。
  ///
  /// 没接时**只是不清磁盘**（与改之前的行为一致），绝不抛错：
  /// 「漏清」是既有毛病，「崩」是新增的毛病。
  final Future<void> Function(String profileId, int emailId)? onDiskPurge;

  // ------------------------------------------------------------ 范围与游标

  /// 同步状态的 scope 字符串。
  ///
  /// 「收全部邮箱」与「某个邮箱」必须是**两个** scope —— 它们的游标含义不同
  /// （前者是全账号的 emailId 序列，后者只覆盖一个邮箱），混用会互相污染。
  ///
  /// 下面两个具名函数是它的两个分支，**由 [scopeOf] 委托给它们**：侧栏要按
  /// `scope` 去查一行同步状态（见 `mailboxTotalsMapProvider`），而调用方手里
  /// 通常只有 `accountId`，没有「要不要 allReceive」这个中间量 —— 直接调
  /// 具名函数比每次现拼字符串少一处会走散的口径。
  static String scopeOf({
    required int accountId,
    required int type,
    required bool allReceive,
  }) =>
      allReceive ? aggregateScope(type) : mailboxScope(accountId, type);

  /// 某一个邮箱的 scope。
  static String mailboxScope(int accountId, int type) =>
      'mailbox:$accountId:type:$type';

  /// 整个实例（`allReceive`）的 scope。
  static String aggregateScope(int type) => 'all:type:$type';

  // ---------------------------------------------------------------- 同步

  /// 增量同步一个邮箱（或整个账号）的新邮件。
  ///
  /// 返回「新写入的行数」—— UI 用它决定要不要提示「有 N 封新邮件」。
  /// **不抛异常**：同步失败只记 [SyncStates] 里的失败计数与原因，
  /// 让调度器退避，绝不让一个后台任务把 UI 打挂。
  Future<int> syncMailbox({
    required Profile profile,
    required int accountId,
    int type = MailType.receive,
    bool allReceive = false,
    CancelToken? cancelToken,
  }) async {
    final scope = scopeOf(accountId: accountId, type: type, allReceive: allReceive);
    final runtime = registry.peek(profile.id);
    if (runtime == null || runtime.isDisposed) return 0;
    if (!runtime.hasToken) return 0;

    final state = await db.mailDao.syncState(profile.id, scope);
    final cursor = state?.cursorEmailId ?? 0;
    final caps = await capabilities.of(profile.id);

    try {
      if (cursor <= 0) {
        // 冷启动 / 游标被作废：拉第一页建立基线。
        //
        // `full: prefs.prefetchFull` —— 用户开着「后台预取完整正文」时，
        // 这一页直接带正文回来（见 [prefs] 的注释）。这一趟本来就要发，
        // 顺带把 50 封的正文一次拿回来，比之后一封一个请求便宜得多。
        final page = await runtime.emailApi.list(
          profileId: profile.id,
          accountId: accountId,
          type: type,
          size: AppDefaults.mailPageSize,
          full: prefs.prefetchFull,
          allReceive: allReceive,
          cancelToken: cancelToken,
        );
        final count = await _persist(profile.id, page, forceAccountId: !allReceive ? accountId : null);
        await db.mailDao.saveSyncState(
          profileId: profile.id,
          scope: scope,
          cursorEmailId: latestCursorOf(page),
          oldestEmailId: page.list.isEmpty
              ? 0
              : page.list.map((r) => r.emailId).reduce((a, b) => a < b ? a : b),
          lastSyncAt: DateTime.now().toUtc(),
          clearError: true,
          failCount: 0,
        );
        // 这一趟**不带游标**，所以 `total` 是全量口径 —— 只有这里能拿到，
        // 带游标的增量响应里没有它（见 [SyncStates.remoteTotal]）。
        await _saveRemoteTotal(profile.id, scope, page);
        await capabilities.noteFullSupport(
          profile.id,
          supported: page.list.isEmpty || page.list.first.hasFullBody,
        );
        return count;
      }

      if (caps.latestEnabled) {
        return await _syncViaLatest(
          profile: profile,
          accountId: accountId,
          type: type,
          allReceive: allReceive,
          scope: scope,
          cursor: cursor,
          cancelToken: cancelToken,
        );
      }

      // 老版本没有 /email/latest：退化成「拉第一页 + 与本地最新比对」。
      return await _syncViaFirstPage(
        profile: profile,
        accountId: accountId,
        type: type,
        allReceive: allReceive,
        scope: scope,
        cursor: cursor,
        cancelToken: cancelToken,
      );
    } on AppException catch (e) {
      if (e is AuthExpiredException) {
        // 401 已经在拦截器里广播过（Registry 会标 needsLogin）。
        // 这里只管停下来，别继续打请求。
        await db.mailDao.recordFailure(
          profileId: profile.id,
          scope: scope,
          error: e.userMessage,
        );
        return 0;
      }
      await db.mailDao.recordFailure(
        profileId: profile.id,
        scope: scope,
        error: e.userMessage,
      );
      return 0;
    }
  }

  Future<int> _syncViaLatest({
    required Profile profile,
    required int accountId,
    required int type,
    required bool allReceive,
    required String scope,
    required int cursor,
    CancelToken? cancelToken,
  }) async {
    final runtime = registry.peek(profile.id);
    if (runtime == null) return 0;

    final rows = await runtime.emailApi.latest(
      profileId: profile.id,
      cursorEmailId: cursor,
      accountId: accountId,
      allReceive: allReceive,
      cancelToken: cancelToken,
    );
    if (rows.isEmpty) {
      await db.mailDao.saveSyncState(
        profileId: profile.id,
        scope: scope,
        cursorEmailId: cursor,
        lastSyncAt: DateTime.now().toUtc(),
        failCount: 0,
        clearError: true,
      );
      return 0;
    }

    // 空洞检测：服务端用的是 `gt(emailId, cursor)`，理论上不会给出
    // `emailId <= cursor` 的行。真出现了说明有东西绕过了这个过滤
    // （跨版本分支、站内信直插库），此时游标不再可信 —— 作废它，
    // 让下一轮走「全量首页重扫」，宁可重复也不要漏信。
    final minId = rows.map((r) => r.emailId).reduce((a, b) => a < b ? a : b);
    if (minId <= cursor) {
      await db.mailDao.invalidateCursor(profile.id, scope);
      final page = await runtime.emailApi.list(
        profileId: profile.id,
        accountId: accountId,
        type: type,
        size: AppDefaults.mailPageSize,
        full: prefs.prefetchFull,
        allReceive: allReceive,
        cancelToken: cancelToken,
      );
      final count = await _persist(profile.id, page,
          forceAccountId: allReceive ? null : accountId);
      await db.mailDao.saveSyncState(
        profileId: profile.id,
        scope: scope,
        cursorEmailId: latestCursorOf(page),
        oldestEmailId: page.list.isEmpty
            ? 0
            : page.list.map((r) => r.emailId).reduce((a, b) => a < b ? a : b),
        lastSyncAt: DateTime.now().toUtc(),
        failCount: 0,
        clearError: true,
      );
      await _saveRemoteTotal(profile.id, scope, page);
      return count;
    }

    final count = await _persist(
      profile.id,
      MailPage(list: rows),
      forceAccountId: allReceive ? null : accountId,
    );
    // `/email/latest` 用 `emailBriefColumns`，行里**没有 `isStar`** ——
    // `MailRow.starKnown` 会挡住覆盖，这里不必额外处理。
    await db.mailDao.advanceCursor(
      profileId: profile.id,
      scope: scope,
      cursorEmailId:
          rows.map((r) => r.emailId).reduce((a, b) => a > b ? a : b),
    );
    return count;
  }

  /// 没有 `/email/latest` 时的退化路径：拉第一页，只写「比本地游标新」的行。
  ///
  /// 这条路径**有漏信的固有风险**（第一页只有 50 条，两轮之间来了 50 封以上
  /// 就会漏），所以只在实例确实没这个端点时用，并且把「首页里出现
  /// `emailId <= cursor` 的行」当作正常情况（那只是老邮件），
  /// 只按 `> cursor` 过滤，不触发重扫。
  Future<int> _syncViaFirstPage({
    required Profile profile,
    required int accountId,
    required int type,
    required bool allReceive,
    required String scope,
    required int cursor,
    CancelToken? cancelToken,
  }) async {
    final runtime = registry.peek(profile.id);
    if (runtime == null) return 0;

    final page = await runtime.emailApi.list(
      profileId: profile.id,
      accountId: accountId,
      type: type,
      size: AppDefaults.mailPageSize,
      allReceive: allReceive,
      cancelToken: cancelToken,
    );
    final fresh = page.list.where((r) => r.emailId > cursor).toList(growable: false);
    final count = fresh.isEmpty
        ? 0
        : await _persist(
            profile.id,
            MailPage(list: fresh),
            forceAccountId: allReceive ? null : accountId,
          );
    await db.mailDao.advanceCursor(
      profileId: profile.id,
      scope: scope,
      cursorEmailId: latestCursorOf(page),
    );
    // 这一页是**不带游标**的全量口径，`total` 就在手上 —— 顺手把「服务端
    // 一共有多少封」刷新掉。漏了这一步的话，没有 `/email/latest` 的老版本
    // 实例上 `remote_total` 一辈子只有冷启动那一次的值（列表底部的
    // 「还有 N 封未同步」会一直拿它当减数）。
    await _saveRemoteTotal(profile.id, scope, page);
    return count;
  }

  /// 往上翻页（加载更旧的邮件）。
  ///
  /// 返回是否还有更多（按「这一页拉满了」推断 —— 服务端不返回 `hasMore`）。
  ///
  /// 翻到底时把结论写进 `SyncStates.backfillDone`：那个结论只活在
  /// `MailListController._hasMore` 里的话，每次冷启动都会白白多发一次
  /// 「拉到底才发现没有」的请求。
  Future<bool> loadOlder({
    required Profile profile,
    required int accountId,
    int type = MailType.receive,
    bool allReceive = false,
    CancelToken? cancelToken,
  }) async {
    final runtime = registry.peek(profile.id);
    if (runtime == null || runtime.isDisposed) return false;

    final scope = scopeOf(accountId: accountId, type: type, allReceive: allReceive);
    final oldest = await db.mailDao.oldestEmailIdOf(
      profile.id,
      accountId,
      type: type,
      allReceive: allReceive,
    );
    final page = await runtime.emailApi.list(
      profileId: profile.id,
      accountId: accountId,
      type: type,
      // 本地最老那一封的 id 就是游标：服务端用 `lt(emailId)`。
      beforeEmailId: oldest > 0 ? oldest : null,
      size: AppDefaults.mailPageSize,
      full: prefs.prefetchFull,
      allReceive: allReceive,
      cancelToken: cancelToken,
    );
    await _persist(profile.id, page,
        forceAccountId: allReceive ? null : accountId);
    await _saveRemoteTotal(profile.id, scope, page);
    await capabilities.noteFullSupport(
      profile.id,
      supported: page.list.isEmpty || page.list.first.hasFullBody,
    );
    final hasMore = page.list.length >= AppDefaults.mailPageSize;
    if (!hasMore) {
      await db.mailDao.markBackfillDone(profile.id, scope);
    }
    return hasMore;
  }

  /// 把 `/email/list` 的 `total` 落库（「还有 N 封没同步」的减数）。
  ///
  /// 不带游标的全量首页、以及带 `beforeEmailId` 的翻页响应里 `total` 依然是
  /// 全量值，所以两条路径都顺手更新它。
  ///
  /// 走 [MailDao.recordMailboxTotal]（列级 UPDATE + 时间戳）而不是
  /// `saveRemoteTotal`：那个方法把 `0` 当成「还不知道」直接丢掉，于是「服务端
  /// 已经删空/清空」这个最该被看见的结论永远写不进去，底部会一直挂着一个
  /// 正数。`recordMailboxTotal` 的「已知」判据是 `remoteTotalAt`（非 null），
  /// 0 配上时间戳是一条正经结论。
  Future<void> _saveRemoteTotal(
    String profileId,
    String scope,
    MailPage page,
  ) async {
    final total = page.total;
    if (total == null) return;
    // 服务端的 total 是全库口径（含已删）；本地只缓存视图内的邮件。
    // 直接相减会得到一个永远为正的差值 —— 那是 [SyncStates.remoteTotal]
    // 的注解里说的「减数」，不是「差」。差值在对不上的时候会被上层
    // 夹到 0 显示，不要让这里猜。
    await db.mailDao.recordMailboxTotal(
      profileId: profileId,
      scope: scope,
      total: total,
      at: DateTime.now().toUtc(),
    );
  }

  /// 探一个 scope 的服务端总数（侧栏「未读 / 总数」的分母、以及列表底部
  /// 「还有 N 封未同步」的减数）。
  ///
  /// **只读**：拉回来的那一页（这页只要一条，见下）**一行都不落库**。这不是
  /// 同步 —— 不碰游标、不碰邮件表、不碰退避计数。落库的只有
  /// `sync_states.remote_total` 与 `remote_total_at` 两列（见
  /// [MailDao.recordMailboxTotal]），而且**服务端真的回 0 也照写**：空邮箱
  /// 是一条正经结论，配上时间戳之后与「还没探过」分得开。
  ///
  /// [allReceive] 与同步/翻页那边同一个语义：true = 整个实例（scope
  /// `all:type:x`），false = 这一个邮箱（`mailbox:<id>:type:x`）。必须显式
  /// 传给请求 —— 见 `EmailApi.list` 的注释：缺省会让服务端回落成账户上的
  /// 「合并接收」开关，探单邮箱时拿回整账户的总数。
  ///
  /// `size: 1` 就够：服务端的 `total` 是**过滤后的全量计数**，与
  /// `size` / `beforeEmailId` 都无关（worker 的 `countFilters` 走
  /// `withCursor: false`，见 `email-service.js`）。`full: false` 是因为正文
  /// 一个字节都不需要 —— 带上它除了多传几十 KB 之外没有任何用处。
  ///
  /// 失败（含没登录、runtime 没了）一律返回 `null` 且**什么都不写**：不落
  /// 时间戳意味着 TTL 判据认为它仍然未知，下次展开会自动重试 —— 这正是
  /// 想要的，不需要谁去做定时重试。
  Future<int?> probeMailboxTotal({
    required Profile profile,
    required int accountId,
    int type = MailType.receive,
    bool allReceive = false,
    CancelToken? cancelToken,
  }) async {
    final runtime = registry.peek(profile.id);
    if (runtime == null || runtime.isDisposed || !runtime.hasToken) return null;

    final scope = scopeOf(accountId: accountId, type: type, allReceive: allReceive);
    try {
      final page = await runtime.emailApi.list(
        profileId: profile.id,
        accountId: accountId,
        type: type,
        size: 1,
        full: false,
        allReceive: allReceive,
        cancelToken: cancelToken,
      );
      final total = page.total;
      if (total == null) return null;
      await db.mailDao.recordMailboxTotal(
        profileId: profile.id,
        scope: scope,
        total: total,
        // 与 `_saveRemoteTotal` 的默认值同一条约定：时间戳一律 UTC。
        at: DateTime.now().toUtc(),
      );
      return total;
    } on AppException {
      return null;
    }
  }

  /// 给还没拿到正文的行补拉 `full=1`（需求三的灰点会自己消失）。
  ///
  /// 为什么是「一批一批来」而不是一个接口全拿：服务端没有「按 emailId 批量取」
  /// 的接口，`/email/list` 只能按 `emailId` 区间取一段（`beforeEmailId` 是
  /// 排他的 `lt`）。所以拿本地最缺正文的那批行的 id 区间发一次请求，
  /// 再从响应里挑出真正要的那几行 —— 一次请求最多补回 50 封。
  ///
  /// 按实例并发。**成本模型值得写清楚**：这个实例声称支持 `full=1` 时，
  /// 每调一次 [mailDao.newestMissingBody] 就一定会打一个真实请求
  /// （哪怕那批行的正文早就被别的路径补上了，我们也是拿着 `hasFullBody = 0`
  /// 的本地行去问的）。多实例下串行 await 会让整轮同步的耗时线性叠加，
  /// 而它们之间没有任何共享状态，所以这里放开并发。
  ///
  /// 返回本轮补齐的封数合计。**不抛异常**：补正文失败不该影响增量同步，
  /// 下一轮自然会再试（那些行的 `hasFullBody` 还是 false）。
  Future<int> backfillAllBodies({
    required Iterable<Profile> profiles,
    int type = MailType.receive,
    CancelToken? cancelToken,
  }) async {
    final list = profiles.toList(growable: false);
    if (list.isEmpty) return 0;
    final counts = await Future.wait(
      list.map(
        (profile) => backfillBodies(
          profile: profile,
          // 合并视图：收信方向永远以 `allReceive` 为准（见 `scopeOf` 的注释），
          // `accountId` 只是服务端在 allReceive 缺省时才用的兜底，这里给 0。
          accountId: 0,
          type: type,
          allReceive: true,
          cancelToken: cancelToken,
        ),
      ),
    );
    return counts.fold<int>(0, (sum, value) => sum + value);
  }

  Future<int> backfillBodies({
    required Profile profile,
    required int accountId,
    int type = MailType.receive,
    bool allReceive = false,
    int limit = AppDefaults.bodyBackfillPerRound,
    CancelToken? cancelToken,

    /// 「这几封正在拉」——每批开始时给一次，整批结束时给一次空集。
    ///
    /// 做成回调而不是让 `SyncEngine` 去猜：真正的「在飞」发生在**这个函数
    /// 内部**（它自己算 `missing`、自己发那一个请求），外面完全看不见它此刻
    /// 处理的是哪几封。面板要显示的「正在同步」正是这一段。
    ///
    /// 参数是「本批」而不是「累计」：调用方负责合并（同一个 engine 可能同时
    /// 有正文与附件两批在飞）。
    void Function(List<MailRef> inFlight)? onInFlight,
  }) async {
    // 用户把「后台预取」关掉了就不再偷偷补 —— 那个开关的文案就是
    // 「费流量，可关」，不认它就是骗人。
    if (!prefs.prefetchFull) return 0;

    final runtime = registry.peek(profile.id);
    if (runtime == null || runtime.isDisposed || !runtime.hasToken) return 0;

    final caps = await capabilities.of(profile.id);
    if (!caps.fullFlagEnabled) return 0;

    try {
      final missing = await db.mailDao.newestMissingBody(
        profile.id,
        accountId,
        type: type,
        allReceive: allReceive,
        limit: limit,
      );
      if (missing.isEmpty) return 0;

      final ids = missing.map((r) => r.emailId).toList(growable: false);
      final maxId = ids.reduce((a, b) => a > b ? a : b);
      final minId = ids.reduce((a, b) => a < b ? a : b);

      // 这一批马上要发请求了 —— 先把「在飞」报出去，面板那几行才会开始转圈。
      onInFlight?.call(missing
          .map((r) => MailRef(profileId: profile.id, emailId: r.emailId))
          .toList(growable: false));

      // 区间大小 = 这批行跨过的 id 范围；服务端一页最多 50 条，
      // 所以两者取小。`lt` 是排他的，加 1 才能把 maxId 自己包进来。
      final span = (maxId - minId + 1).clamp(1, AppDefaults.mailPageSize);
      try {
        final page = await runtime.emailApi.list(
          profileId: profile.id,
          accountId: accountId,
          type: type,
          beforeEmailId: maxId + 1,
          size: span,
          full: true,
          allReceive: allReceive,
          mailboxEmail: missing.first.mailboxEmail,
          cancelToken: cancelToken,
        );

        var filled = 0;
        for (final row in page.list) {
          if (!row.hasFullBody) continue;
          if (!ids.contains(row.emailId)) continue;
          await db.mailDao.upsertFull(row);
          if (row.attList.isNotEmpty) {
            await db.mailDao
                .upsertAttachments(profile.id, row.emailId, row.attList);
          }
          filled++;
        }

        // 一个都没拿到：说明这个实例声称支持 `full`，实际不给正文。
        // 记下来，别再每轮都白跑一趟（与 `ensureFull` 同一套降级）。
        if (filled == 0 && page.list.isNotEmpty) {
          await capabilities.noteFullSupport(profile.id, supported: false);
        }
        return filled;
      } finally {
        // **必须 finally**：中途抛异常（或者这一整趟被 cancel）时这一批要
        // 立刻从「在飞」里撤掉，否则面板上那几行会永远转圈，而没有任何东西
        // 会来解开它。空集 = 「这一批结束了」，见 `SyncEngine._mergeInFlight`。
        onInFlight?.call(const <MailRef>[]);
      }
    } on AppException {
      return 0;
    }
  }

  /// 星标文件夹（不是从邮件列表来的，单独一条接口，游标口径与邮件一致）。
  Future<bool> loadStarred({
    required Profile profile,
    int? beforeEmailId,
    CancelToken? cancelToken,
  }) async {
    final runtime = registry.peek(profile.id);
    if (runtime == null || runtime.isDisposed) return false;
    final page = await runtime.starApi.list(
      profileId: profile.id,
      beforeEmailId: beforeEmailId,
      size: AppDefaults.starPageSize,
      cancelToken: cancelToken,
    );
    await _persist(profile.id, page);
    // `star/list` 只返回被标星的邮件，本地这些行要显式置星
    // （`/email/latest` 那条路径不会带 `isStar`）。
    await db.mailDao.setStarByEmailIds(
      profile.id,
      page.list.map((r) => r.emailId),
    );
    return page.list.length >= AppDefaults.starPageSize;
  }

  // ---------------------------------------------------------------- 详情

  /// 确保本地拿到完整正文（`full=1`）。
  ///
  /// 没有单封详情接口，只能按 `accountId + emailId 区间` 拉一小段
  /// （`beforeEmailId = emailId + 1` 让服务端的 `lt` 把目标包含进来）。
  /// 返回是否有更新。
  Future<bool> ensureFull(MailRef ref) async {
    final row = await db.mailDao.find(ref.profileId, ref.emailId);
    if (row == null) return false;
    if (row.hasFullBody) return true;

    final caps = await capabilities.of(ref.profileId);
    if (!caps.fullFlagEnabled) {
      // 实例不支持 full（或响应里从不带 content）—— 别白跑一趟。
      return false;
    }

    final profile = await profiles.find(ref.profileId);
    if (profile == null) return false;
    final runtime = registry.peek(ref.profileId);
    if (runtime == null || runtime.isDisposed) return false;

    // `accountId == 0` 说明这行的归属没落下来（老数据，或这封信不在任何
    // 已知邮箱名下）。此时**必须**带上 `allReceive`：
    //  - 服务端在 `allReceive` 缺省时会去查 `accountId = 0` 的账户行，
    //    查不到就 `accountRow.allReceive` 空指针 → 500；
    //  - 而 `allReceive=1` 本来就忽略 accountId，对这一页的取法反而更准
    //    （`emailId <= ref` 的最大一条，目标只要在库里就必然被选中）。
    final page = await runtime.emailApi.list(
      profileId: ref.profileId,
      accountId: row.accountId,
      type: row.type,
      beforeEmailId: ref.emailId + 1,
      size: 1,
      full: true,
      allReceive: row.accountId == 0,
      mailboxEmail: row.mailboxEmail,
    );

    final found = pickById(page.list, ref.emailId);
    if (found == null || !found.hasFullBody) {
      // 目标不在服务端的这一段里（已被删除，或是 allReceive 视图里的邮件
      // 而本地 accountId 记错了）。降级：不报错，详情页用摘要渲染。
      await capabilities.noteFullSupport(ref.profileId, supported: false);
      return false;
    }

    await db.mailDao.upsertFull(found);
    if (found.attList.isNotEmpty) {
      await db.mailDao.upsertAttachments(
        ref.profileId,
        ref.emailId,
        found.attList,
      );
    }
    return true;
  }

  /// 打开一封邮件时调用的两个动作。
  ///
  /// **已读先落本地**（同一帧 UI 就变），随后 `PUT /email/read` 与
  /// `GET /email/list?full=1`（[ensureFull]）**并发**跑去补服务端与正文。
  ///
  /// 原来是把这两个网络往返**串在本地写之前**，于是用户点开一封信要等两个
  /// 往返（约 1 秒，冷启动更久）列表才变已读 —— 那正是「点了没反应」的来源。
  /// 标已读失败**不阻断打开**：回滚成本地未读，让它下一轮同步再被服务端
  /// 带回来（`_pushRead` 是幂等的，超时也可能已经生效）。
  Future<void> openMail(MailRef ref) async {
    final row = await db.mailDao.find(ref.profileId, ref.emailId);
    if (row == null) {
      // 本地没有这封（还没同步下来）：只有补正文可做。
      await ensureFull(ref);
      return;
    }

    if (row.isUnread) {
      // **先 await 本地落盘，再并发两趟网络** —— 不要靠 `ensureFull`
      // 请求本身的延迟去赌「PUT 一定后于取页返回」的时序。
      await db.mailDao.markRead(<MailRef>[ref], read: true);
      final stamp = _stampRead(<MailRef>[ref]);
      await Future.wait<void>(<Future<void>>[
        _pushRead(<MailRef>[ref]).then(
          (_) => _releaseReadStamp(<MailRef>[ref], stamp),
          onError: (Object _) => _rollbackRead(<MailRef>[ref], stamp),
        ),
        ensureFull(ref),
      ]);
      return;
    }

    await ensureFull(ref);
  }

  /// 深链兜底：目标不在当前窗口内时，往回翻页找（上限 [AppDefaults.deepLinkMaxPages]）。
  Future<MailRow?> locateAcrossPages(MailRef ref) async {
    final local = await db.mailDao.find(ref.profileId, ref.emailId);
    if (local != null) return local;

    final profile = await profiles.find(ref.profileId);
    if (profile == null) return null;
    final runtime = registry.peek(ref.profileId);
    if (runtime == null || runtime.isDisposed) return null;

    var cursor = 0;
    for (var i = 0; i < AppDefaults.deepLinkMaxPages; i++) {
      // 用 allReceive 的收件视图往回翻 —— 通知里的邮件都是收件，
      // 而且我们并不知道它落在哪个邮箱上（这正是「找不到」的原因）。
      final page = await runtime.emailApi.list(
        profileId: ref.profileId,
        accountId: 0,
        type: MailType.receive,
        beforeEmailId: cursor > 0 ? cursor : null,
        size: AppDefaults.mailPageSize,
        allReceive: true,
      );
      if (page.list.isEmpty) return null;
      await _persist(ref.profileId, page);
      final hit = pickById(page.list, ref.emailId);
      if (hit != null) return hit;
      cursor = page.list.map((r) => r.emailId).reduce((a, b) => a < b ? a : b);
    }
    return null;
  }

  // -------------------------------------------------------------- 写操作

  /// 「这一封的已读状态」最后一次是被**哪一次操作**写的。用来判断一次失败的
  /// PUT 还敢不敢回滚 —— 见 [markRead] 的 catch。
  ///
  /// 真会撞上的只有一条路径：详情页菜单在 [openMail] 的 PUT 还在飞的时候
  /// 又被点了一次。`openMail` 自己有 `isUnread` 前置判断挡住了重复发，
  /// 菜单那条没有。
  ///
  /// 用**全局自增序号**而不是「每封各自 +1」：序号永不复用，于是「过期的那次
  /// 回滚」不可能撞上一个碰巧同号的新操作。每操作结束（成功或回滚完）就把
  /// 还是自己那一代的条目删掉，这张表因此只装着**在途**的那几封。
  final Map<MailRef, int> _readGeneration = <MailRef, int>{};
  int _readOpSeq = 0;

  /// 标已读 / 标未读。
  ///
  /// **本地优先**：先写本地库（UI 同帧变），再发 `PUT /email/read`；发失败就
  /// 把这次改过的那几行回滚成未读，并把异常抛给调用方（详情菜单要弹提示）。
  ///
  /// **回滚判据是「任何失败」，不是 outbox 那套「确定没送达 / 可能已送达」**：
  /// `PUT /email/read` 是**幂等**的（`emailIds` 直接 inArray 置 1），超时也可能
  /// 已经生效；而 `MailDao._merge` 让本地 `unread` 单调之后，服务端**再也没法**
  /// 把本地打回未读。所以「只对确定性拒绝回滚」会让一次其实已送达的请求把本地
  /// 永远留在未读。全量回滚 + 单调合并正好自愈：真送达了 → 下一轮同步带回
  /// `unread = 1` → 本地自己变回已读。
  ///
  /// **服务端只支持标已读**（`PUT /email/read` 里写死 `unread = READ`），
  /// 所以 [read] 为 false 时只改本地。而本地 `unread` 是单调的
  /// （`MailDao._merge`：服务端行只能抬成已读），所以这个「未读」留不住 ——
  /// 下一次同步把服务端的 `unread = 1` 带回来就把它盖回已读。这是这套设计的
  /// 已知代价，不是 bug：整个服务端只有一处写 `unread`（置 1），没有反向接口。
  Future<void> markRead(
    Iterable<MailRef> refs, {
    required bool read,
    bool syncServer = true,
  }) async {
    final list = refs.toList(growable: false);
    if (list.isEmpty) return;

    // 只有「标已读」才有对应的服务端动作（见上面的 doc）。
    if (!read || !syncServer) {
      await db.mailDao.markRead(list, read: read);
      return;
    }

    await db.mailDao.markRead(list, read: true);
    final stamp = _stampRead(list);
    try {
      await _pushRead(list);
      _releaseReadStamp(list, stamp);
    } catch (_) {
      await _rollbackRead(list, stamp);
      rethrow;
    }
  }

  /// 记下这次操作在每封邮件上的序号，返回 `MailRef → 序号`。
  Map<MailRef, int> _stampRead(List<MailRef> refs) {
    final op = ++_readOpSeq;
    return <MailRef, int>{
      for (final ref in refs) ref: _readGeneration[ref] = op,
    };
  }

  /// 把 [refs] 打回未读 —— 只回滚「还是这一次操作、之后没人再动过」的行。
  ///
  /// 序号对不上的那几行说明期间有一次**更新的**写（又标了一次已读），
  /// 拿这轮的结果去盖就会把后一次成功的操作一起抹掉。
  Future<void> _rollbackRead(
    List<MailRef> refs,
    Map<MailRef, int> stamp,
  ) async {
    final stale = <MailRef>[
      for (final ref in refs)
        if (_readGeneration[ref] == stamp[ref]) ref,
    ];
    if (stale.isNotEmpty) await db.mailDao.markRead(stale, read: false);
    _releaseReadStamp(refs, stamp);
  }

  /// 这次操作在 [refs] 上收工了：把还属于自己的条目从在途表里删掉。
  ///
  /// 删掉之后那封邮件就「回到没人在途」，下一次写入自然拿到一个更大的序号 ——
  /// 所以这个删除**不会**让两张表的语义分叉。
  void _releaseReadStamp(List<MailRef> refs, Map<MailRef, int> stamp) {
    for (final ref in refs) {
      if (_readGeneration[ref] == stamp[ref]) _readGeneration.remove(ref);
    }
  }

  /// 真的发 `PUT /email/read`。按实例分组：一个 [MailRef] 只能发给他自己
  /// 那个实例。**失败会抛**，由 [markRead] 决定要不要回滚。
  Future<void> _pushRead(List<MailRef> refs) async {
    final byProfile = <String, List<int>>{};
    for (final ref in refs) {
      byProfile.putIfAbsent(ref.profileId, () => <int>[]).add(ref.emailId);
    }
    for (final entry in byProfile.entries) {
      final runtime = registry.peek(entry.key);
      // 实例已被删/已停：本地照写、不发请求、也不回滚 —— 那台实例的本地行
      // 本来也不该还在，把它打回未读只会让界面白闪一下。
      if (runtime == null || runtime.isDisposed) continue;
      await runtime.emailApi.markRead(entry.value);
    }
  }

  /// 星标切换。服务端成功后才改本地。
  Future<void> setStar(MailRef ref, {required bool starred}) async {
    final runtime = registry.peek(ref.profileId);
    if (runtime == null || runtime.isDisposed) {
      throw const NetworkException(detail: '实例未就绪');
    }
    if (starred) {
      await runtime.starApi.add(ref.emailId);
    } else {
      await runtime.starApi.cancel(ref.emailId);
    }
    await db.mailDao.markStar(ref, starred: starred);
  }

  /// 一批邮件的星标切换（多选）。
  ///
  /// **服务端只有单封接口**（`POST /star/add`、`GET /star/cancel`），所以这里
  /// 是 N 个请求，不是一次批量 —— 与 [markRead] / [delete] 那两个真有批量
  /// 接口的不一样，别指望它便宜。
  ///
  /// **全部成功之后才落本地**（与 [setStar] 同一条约定）：先落本地的话，
  /// 中途某一封失败会让本地显示成已加星而服务端没有，而星标**不像已读那样
  /// 有单调合并兜底** —— 它下一次同步就会被服务端的「没加星」打回去，
  /// 用户看到的是「标了又自己掉了」。
  ///
  /// 某个实例的 runtime 不在（已删 / 已停）时**跳过那一封**而不是整批抛错：
  /// 与 [setStar] 对单封抛 `实例未就绪` 不同，那时用户的操作对象里还有别的
  /// 实例的信，为其中一台不可用的实例整批失败，等于把还能做的也一起弄没。
  Future<void> setStarAll(Iterable<MailRef> refs, {required bool starred}) async {
    final list = refs.toList(growable: false);
    if (list.isEmpty) return;

    final done = <MailRef>[];
    for (final ref in list) {
      final runtime = registry.peek(ref.profileId);
      if (runtime == null || runtime.isDisposed) continue;
      if (starred) {
        await runtime.starApi.add(ref.emailId);
      } else {
        await runtime.starApi.cancel(ref.emailId);
      }
      done.add(ref);
    }
    if (done.isEmpty) return;
    // 逐条落库（`markStar` 是单封的）。这一批最多几十封，不值得为它新开一个
    // 批量 DAO 方法 —— 多选动作不频繁，一次 N 条 update 完全够用。
    for (final ref in done) {
      await db.mailDao.markStar(ref, starred: starred);
    }
  }

  /// 删除。站点开了 `syncDelete`（默认开）时是**物理删除**，不可恢复。
  Future<void> delete(Iterable<MailRef> refs) async {
    final list = refs.toList(growable: false);
    if (list.isEmpty) return;
    final byProfile = <String, List<int>>{};
    for (final ref in list) {
      byProfile.putIfAbsent(ref.profileId, () => <int>[]).add(ref.emailId);
    }
    for (final entry in byProfile.entries) {
      final runtime = registry.peek(entry.key);
      if (runtime == null || runtime.isDisposed) continue;
      await runtime.emailApi.delete(entry.value);
    }
    await db.mailDao.deleteRefs(list);
    // 库里删干净了，磁盘上的附件目录跟着走。
    //
    // `deleteRefs` 的注释把这件事留给 `AttachmentCache` 决定（附件文件可能
    // 被别的邮件共用，所以库记录的删除与文件的删除要分开做）—— 但此前
    // **四个调用方谁都没接这一步**，于是删的任何一封带附件的邮件，文件都
    // 留在盘上（规格 §6.1）。这里接上，顺便让「删邮箱」与「删单封」用同一套
    // 收尾，不会出现「邮箱删了干净、单封删了不干净」。
    final purge = onDiskPurge;
    if (purge != null) {
      for (final ref in list) {
        await purge(ref.profileId, ref.emailId);
      }
    }
  }

  // ------------------------------------------------------------ 落库辅助

  /// 把发信接口返回的行写进本地。
  ///
  /// 服务端的 `/email/send` 直接返回**刚创建的那几行**（`status=1` 已发），
  /// 落库之后发件箱立刻就能看到，不必等下一轮轮询 —— 而轮询只覆盖收件方向
  /// （`/email/latest` 只有收件），不落库的话用户发完信在「已发送」里
  /// 要等到下次打开列表才看得见。
  Future<int> persistSendResult(String profileId, List<MailRow> rows) async {
    if (rows.isEmpty) return 0;
    final written = await _persist(
      profileId,
      MailPage(list: rows, total: rows.length),
    );
    // 附件和邮件行是两张表（`upsertPage` 只管前者），`attList` 要显式再写一次
    // —— 不然发完信点进详情，附件面板是空的。
    for (final row in rows) {
      if (row.attList.isEmpty) continue;
      await db.mailDao.upsertAttachments(profileId, row.emailId, row.attList);
    }
    return written;
  }

  /// 把一页服务端数据写进本地。
  ///
  /// 两件补数据的事：
  /// - `mailboxEmail`：列表接口不返回「投递到哪个邮箱」，但本地 `mailboxes`
  ///   表有 `accountId → email` 的映射，用它补齐（聚合视图要显示这个）。
  /// - `accountId`：先用行里带的；行里没有（摘要列不带这个字段）就用
  ///   `toEmail`/`sendEmail` 反查 `mailboxes`，最后才用调用方给的兜底值。
  Future<int> _persist(
    String profileId,
    MailPage page, {
    int? forceAccountId,
  }) async {
    if (page.list.isEmpty) return 0;

    final mailboxes = await db.profileDao.mailboxesOf(profileId);
    final emailByAccountId = <int, String>{
      for (final m in mailboxes) m.accountId: m.email,
    };
    // 反查表：归一化地址 → accountId。`+tag` / 大小写的匹配规则在
    // `email_address.dart` 里，写库与回填共用同一份。
    final accountIdByEmail = <String, int>{
      for (final m in mailboxes) normalizeEmail(m.email): m.accountId,
    };

    final rows = page.list.map((row) {
      // `accountId` 的归属：服务端行里带了就用它，没带就自己推。
      //
      // 为什么需要「自己推」这一步：服务端 `emailBriefColumns`（`/email/latest`
      // 恒定用它）里**没有** `accountId`，而 App 收件方向永远用 `allReceive: true`
      // 同步（一个请求覆盖所有邮箱），`forceAccountId` 也是 null —— 于是收信
      // 落库一律是 `account_id = 0`。本地列表按邮箱过滤时（切换邮箱）这些行
      // 一封都选不出来，列表就是空白的。
      //
      // 好在地址是准的：收信的 `toEmail` 是**投递到哪个邮箱**，发信的
      // `sendEmail` 是**从哪个邮箱发出去的**，两者都能反查本地 `mailboxes` 表。
      // 这样补不需要服务端改一行，也不受「合并视图本来就不知道邮箱」影响。
      final int accountId;
      if (row.accountId != 0) {
        accountId = row.accountId;
      } else {
        final address = row.type == MailType.send ? row.sendEmail : row.toEmail;
        accountId =
            accountIdForEmail(accountIdByEmail, address) ?? (forceAccountId ?? 0);
      }
      // 列表接口不返回「投递到哪个邮箱」，用本地 mailboxes 表补上
      // （聚合视图每行都要显示这个）。
      final mailboxEmail = row.mailboxEmail.isNotEmpty
          ? row.mailboxEmail
          : emailByAccountId[accountId] ?? '';
      return row.copyWith(
        accountId: accountId,
        mailboxEmail: mailboxEmail,
      );
    }).toList(growable: false);

    // 回填：本地已有的行若还挂着 `account_id = 0`（本修复之前同步下来的），
    // 借这一次同步把它们按 `toEmail`/`sendEmail` 重新归位。
    //
    // 为什么要有这一步：行一旦以 0 落库，两个合并规则都会把它锁死 ——
    // `_merge` 只在「新值非 0」时才覆盖，而摘要行永远给不出非 0 的
    // `accountId`。不显式 UPDATE 一次，老数据的空白邮箱列表就永远好不了。
    // 判定条件 `account_id = 0` 保证这是幂等的、且不会覆盖服务端给的归属。
    //
    // 不计入返回值：「新写入的行数」是 `syncMailbox` 的语义（UI 靠它提示
    // 「有 N 封新邮件」），回填改的是老行，不是新信。
    final repaired =
        await db.mailDao.reassignAccountIds(profileId, accountIdByEmail);
    if (repaired > 0) onAccountIdsRepaired?.call(profileId, repaired);

    await db.mailDao.upsertPage(rows, cachedAt: DateTime.now().toUtc());

    // 附件落库。**这一趟不能省** —— 摘要行不带 `attList`，但开着
    // 「后台预取完整正文」（`prefs.prefetchFull`，默认开）时这一页是 `full=1`
    // 拉的，响应里**带着**附件。
    //
    // 以前这里不写附件，后果比「列表上看不见回形针」严重得多：
    // - `backfillBodies` 也不会来捡 —— 它只挑 `hasFullBody == false` 的行，
    //   而这一页的行早就是 `true` 了。于是这些附件**永远不会**落库；
    // - 详情页的附件面板在「预取开着」这条路径上一直是空的。
    // 单封补拉的路径（`ensureFull` / `backfillBodies`）一直是写的，只有这条
    // 「一次带一页回来」的路径漏了。
    for (final row in rows) {
      if (row.attList.isEmpty) continue;
      await db.mailDao.upsertAttachments(profileId, row.emailId, row.attList);
    }
    return rows.length;
  }

  /// 把本地已有的 `account_id = 0` 的老行按 `toEmail`/`sendEmail` 归位。
  ///
  /// 与 [_persist] 里那次是**同一次搬运**，区别只在于没有「顺便灌一页新邮件」
  /// 这件事可搭车。存在的场景是登录刚完成、或用户手动点了一次修复：
  /// 老数据的行在 `_persist` 之前就已经躺在库里，而那时同步可能还没跑过
  /// 任何一页 —— 用户看到的就是「切到某个邮箱，列表是空的」，
  /// 明明信就在本地。
  ///
  /// **幂等**且不动服务端给过归属的行（`reassignAccountIds` 只挑
  /// `account_id = 0`）。返回改写的行数。
  Future<int> repairOrphanedAccounts(String profileId) async {
    final mailboxes = await db.profileDao.mailboxesOf(profileId);
    if (mailboxes.isEmpty) return 0;
    final accountIdByEmail = <String, int>{
      for (final m in mailboxes) normalizeEmail(m.email): m.accountId,
    };
    final repaired =
        await db.mailDao.reassignAccountIds(profileId, accountIdByEmail);
    if (repaired > 0) onAccountIdsRepaired?.call(profileId, repaired);
    return repaired;
  }
}
