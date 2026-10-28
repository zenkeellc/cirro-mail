import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_defaults.dart';
import '../core/error/app_exception.dart';
import '../data/models/enums.dart';
import '../data/models/instance_capabilities.dart';
import '../data/models/mail_attachment.dart';
import '../data/models/mail_ref.dart';
import '../data/models/mail_row.dart';
import '../data/models/mailbox_account.dart';
import '../data/models/profile.dart';
import '../data/repositories/email_repository.dart';
import '../features/mail_list/mail_selection.dart';
import '../features/mail_list/mailbox_filter.dart';
import '../instance/profile_runtime.dart';
import 'core_providers.dart';
import 'profile_providers.dart';

/// 某个实例的能力结论（响应式 —— 探测/降级后 UI 自动跟着变）。
final capabilitiesProvider =
    StreamProvider.family<InstanceCapabilities, String>(
  (ref, profileId) => ref
      .watch(capabilityRepositoryProvider)
      .watch(profileId)
      .map((caps) => caps ?? const InstanceCapabilities()),
  name: 'capabilities',
);

/// 某个实例的邮箱列表。
final mailboxesProvider =
    StreamProvider.family<List<MailboxAccount>, String>(
  (ref, profileId) => ref.watch(accountRepositoryProvider).watch(profileId),
  name: 'mailboxes',
);

/// 某个实例的运行时（可能还没建好 —— 冷启动时 runtime 是懒建的）。
///
/// 用 provider 包一层是为了让 UI 拿到的是**当前 profile 对应的** runtime：
/// 加密实例换 baseUrl 之后 registry 会重建 runtime，这里跟着重建。
final runtimeProvider = Provider.family<ProfileRuntime?, String>(
  (ref, profileId) {
    final profile = ref.watch(profileByIdProvider(profileId));
    if (profile == null) return null;
    return ref.watch(runtimeRegistryProvider).ensure(profile);
  },
  name: 'runtime',
);

/// 某个实例的附件前缀（渲染正文、下载附件都要）。
final ossBaseProvider = Provider.family<String, String>(
  (ref, profileId) {
    final profile = ref.watch(profileByIdProvider(profileId));
    if (profile == null) return '';
    return ref.watch(configRepositoryProvider).ossBaseOf(profile);
  },
  name: 'ossBase',
);

/// 列表窗口大小：默认 200 条，「继续加载」一次长一页。
///
/// 列表查询只取最新 200 条（[MailDao.watchMailboxSet] / [MailDao.watchStarred]
/// 的默认 limit）。而「还有 N 封未同步 · 点击继续加载」把更旧的邮件同步进库
/// 之后，它们按 `createTime desc` 正好落在第 200 行**之外** —— 库长了、屏幕
/// 一动不动，用户看到的就是「点了也没把邮件同步进来」。所以窗口必须跟着
/// 翻页一起长，本 provider 就是这个**可观察**的窗口大小。
///
/// 状态只装一个 int：`ref.watch(mailListWindowProvider(query))` 的值一变，
/// [mailListProvider] 就换成新的 limit 重新订阅，列表随之多露出一页。
final mailListWindowProvider =
    NotifierProvider.family<MailListWindowController, int, MailListQuery>(
  MailListWindowController.new,
  name: 'mailListWindow',
);

class MailListWindowController extends Notifier<int> {
  MailListWindowController(this.query);

  /// 这个窗口属于哪张列表（只用于日志/调试，逻辑上不需要读它）。
  final MailListQuery query;

  /// 首屏展示多少条 —— 与历史实现里 `watchMailboxSet` 的默认 limit 一致。
  static const int base = 200;

  /// 一次露出多少条（= 一页）。
  static const int step = AppDefaults.mailPageSize;

  @override
  int build() => base;

  /// 把窗口放开 [by] 条。
  ///
  /// 不封顶：它只随用户主动加载增长，一次一页；而且长到的上限就是本地
  /// 已缓存的封数（`MailListController.loadMore` 只在缓存多过窗口时才放）。
  void revealMore({int by = step}) {
    if (by <= 0) return;
    state = state + by;
  }
}

/// 一个列表页要展示的行。
///
/// **统一从本地库读**，网络只在 `MailListController.refresh/loadMore` 里跑 ——
/// 这样「同步写库 → 列表自动刷新」是一条链路，UI 不需要自己管分页状态，
/// 也不会出现「网络返回了但界面没动」。
///
/// 星标走另一张缓存路径；其余一律 `watchMailboxSet` —— 它同时覆盖了
/// 「全部实例」「某实例全部邮箱」「跨实例的若干具体邮箱」三种形状，
/// 不必再按实例数分叉。
///
/// `limit` 来自 [mailListWindowProvider]（默认 200、翻一页长一页），不是写死的：
/// 写死的那版会让「继续加载」拉回来的更旧邮件永远落在窗口外。
final mailListProvider =
    StreamProvider.family<List<MailRow>, MailListQuery>(
  (ref, query) {
    final db = ref.watch(databaseProvider);
    final limit = ref.watch(mailListWindowProvider(query));
    return switch (query.folder) {
      MailFolder.starred => db.mailDao.watchStarred(
          profileIds: query.profileIds,
          limit: limit,
        ),
      _ => db.mailDao.watchMailboxSet(
          mailboxes: query.mailboxes,
          type: query.apiType,
          unreadOnly: query.unreadOnly,
          limit: limit,
        ),
    };
  },
  name: 'mailList',
);

/// 列表页的**操作入口**。
///
/// 单独一个 provider（而不是塞进 `mailListProvider`）的原因：
/// 「加载更多」「刷新」是命令式的动作，不是状态 —— 把它们做成状态只会
/// 让 UI 到处 `ref.read(...notifier)`，且无法在页面 dispose 后安全收尾。
final mailListControllerProvider =
    Provider.family<MailListController, MailListQuery>(
  (ref, query) => MailListController(ref: ref, query: query),
  name: 'mailListController',
);

class MailListController {
  MailListController({required this.ref, required this.query}) {
    unawaited(_hydrate());
  }

  final Ref ref;
  final MailListQuery query;

  /// 本页是否还有更旧的数据可以拉（服务端不返回 `hasMore`，
  /// 由「上一页是否拉满」推断，见 `EmailRepository.loadOlder`）。
  bool _hasMore = true;
  bool get hasMore => _hasMore;

  bool _loadingMore = false;
  bool get isLoadingMore => _loadingMore;

  final List<CancelToken> _inFlight = <CancelToken>[];

  /// 把「更旧的方向已经翻到底」这个结论从库里读回来，并顺手确认真实总数。
  ///
  /// 只活在内存里的话，每次冷启动都会**白白多发一次**「拉到底才发现没有」的
  /// 请求 —— 而这个结论对某一页来说是不会变的（除非服务端删了新数据）。
  /// [refresh] 会把 `_hasMore` 重置为 true，那时重新探测一次是对的。
  Future<void> _hydrate() async {
    if (query.folder == MailFolder.starred) return;
    if (!query.singleMailbox) return;
    final box = query.mailboxes.first;
    final scope = EmailRepository.scopeOf(
      accountId: box.accountId,
      type: query.apiType,
      allReceive: box.accountId == kAllMailboxes,
    );
    try {
      final state = await ref.read(databaseProvider).mailDao.syncState(
            box.profileId,
            scope,
          );
      if (state?.backfillDone == true) _hasMore = false;
    } catch (_) {
      // 读不出来就按「还没翻到底」处理，只是多一次请求。
    }
    // 打开列表就确认一次「服务端到底还有多少封」。`remote_total` 只在
    // 冷启动首页 / 翻页 / 侧栏探测时写，而 `/email/latest` 那轮常规同步
    // **不带 total** —— 不在这里补一发，底部那个数就是几天前的快照（本地删
    // 过信之后就凭空多出「还有 N 封未同步」，还怎么点都点不掉）。
    // TTL（`AppDefaults.mailboxTotalTtl`）之内不重复探，见 [_refreshRemoteTotal]。
    unawaited(_refreshRemoteTotal());
  }

  /// 把本页 scope 的服务端总数刷新一次（`remote_total` + 时间戳）。
  ///
  /// [force] 为 false 时按 [AppDefaults.mailboxTotalTtl] 跳过刚探过的；删信、
  /// 下拉刷新这类「数字一定变了」的动作传 true。
  ///
  /// 实现只有 `probeMailboxTotal` 那一个请求（`/email/list`，`size=1&full=0`），
  /// 失败静默：这是展示用的旁路，不该让列表页报错。
  Future<void> _refreshRemoteTotal({bool force = false}) async {
    if (query.folder == MailFolder.starred) return;
    if (!query.singleMailbox) return;
    final box = query.mailboxes.first;
    final profile = ref.read(profileByIdProvider(box.profileId));
    if (profile == null) return;
    final allReceive = box.accountId == kAllMailboxes;
    final dao = ref.read(databaseProvider).mailDao;
    final scope = EmailRepository.scopeOf(
      accountId: box.accountId,
      type: query.apiType,
      allReceive: allReceive,
    );
    try {
      if (!force) {
        final state = await dao.syncState(box.profileId, scope);
        final at = state?.remoteTotalAt;
        if (at != null &&
            DateTime.now().toUtc().difference(at) <
                AppDefaults.mailboxTotalTtl) {
          return;
        }
      }
      await ref.read(emailRepositoryProvider).probeMailboxTotal(
            profile: profile,
            accountId: box.accountId,
            type: query.apiType,
            allReceive: allReceive,
          );
    } catch (_) {
      // 探测失败就保持旧值/未知：数字是辅助信息，不是页面能否用的前提。
    }
  }

  /// 下拉刷新：让所有相关实例立刻同步一轮，然后（可选）把本页把守的
  /// 邮箱也补一次「更旧」的窗口。
  ///
  /// 传 `wait: true` 时会等这一轮同步结束再返回 —— 下拉刷新的转圈就该转到这里。
  Future<void> refresh({bool wait = true}) async {
    final scheduler = ref.read(syncSchedulerProvider);
    final single = _singleProfileId;
    if (wait) {
      await scheduler.refreshNow(profileId: single);
    } else {
      unawaited(scheduler.refreshNow(profileId: single));
    }
    _hasMore = true;
    // 同步那一轮走 `/email/latest`，响应里没有 total —— 光靠它底部那个数
    // 永远不会更新。刷新是一个「用户认为一切该对齐了」的动作，顺手重探一次。
    await _refreshRemoteTotal(force: true);
  }

  /// 无限滚动 / 底部那行「点击继续加载」：把**更旧的一页**放进列表。
  ///
  /// 做三件事，次序不能反：
  /// 1. **先放窗口**：本地缓存已经多过窗口时，先把窗口放开一页（不发请求，
  ///    用户立刻多看到一页）—— 这是「继续加载」的一半；
  /// 2. **再补总账**：`_hasMore == false` 只是快照（服务端删过信、本地窗口
  ///    变过、总数变过都会让它过期），用户**主动点了**就重给一次机会
  ///    （[retryExhausted]）。这次请求最差也会把 `remote_total` 刷成真值，
  ///    占位行上那个假数字随之消失；
  /// 3. **最后拉页**：`loadOlder` 写库之后窗口要跟着长到装得下新行 ——
  ///    不长的话它们落在 200 行窗口之外，屏幕纹丝不动，这正是用户报的
  ///    「点了也没把邮件同步到客户端」。
  ///
  /// 滚动触发时不传 [retryExhausted]：滚到底不该一直发「已经到底」的请求。
  Future<void> loadMore({bool retryExhausted = false}) async {
    if (_loadingMore) return;

    // 多邮箱 / 聚合（星标页的「全部实例」那一档也算）：不是翻页，是
    // **再同步一轮**。
    //
    // 以前这里是两句静默的 `return`（「多邮箱没有统一游标。」/ 星标那条
    // 在 `_singleProfileId == null` 时直接退出），而界面上给用户的承诺
    // 恰恰相反 —— `_ListFooter` 在聚合视图里明写着「聚合视图按实例分别
    // 拉取，滚到底会自动同步」。于是用户滚到底、等下去，列表纹丝不动、
    // 库里也一个字节没变，看起来就是「同步永远不成功」。承诺和实现必须
    // 落在同一件事上，所以这一支改成真的去推一轮，见
    // [_syncRoundForAggregate]。
    //
    // 判在星标之前：星标页只在**钉住单个实例**时才有「更旧一页」这回事
    // （`loadStarred` 要一个游标），「全部实例」那一档同样没有统一游标，
    // 不该走进去空转。
    if (!query.singleMailbox) return _syncRoundForAggregate();
    if (query.folder == MailFolder.starred) {
      return loadMoreStarred(retryExhausted: retryExhausted);
    }

    final box = query.mailboxes.first;
    final profile = ref.read(profileByIdProvider(box.profileId));
    if (profile == null) return;

    _loadingMore = true;
    final cancel = CancelToken();
    _inFlight.add(cancel);
    try {
      final window = ref.read(mailListWindowProvider(query));
      final cached = await _cachedCount();
      if (cached > window) {
        ref.read(mailListWindowProvider(query).notifier).revealMore();
        return;
      }

      // 到底了、但用户主动点了：见方法注释第 2 条。
      if (!_hasMore && !retryExhausted) return;
      _hasMore = true;

      _hasMore = await ref.read(emailRepositoryProvider).loadOlder(
            profile: profile,
            accountId: box.accountId,
            type: query.apiType,
            allReceive: box.accountId == kAllMailboxes,
            cancelToken: cancel,
          );

      // 这一页写进库的更旧邮件必须真能显示出来。
      final grown = await _cachedCount();
      if (grown > window) {
        ref
            .read(mailListWindowProvider(query).notifier)
            .revealMore(by: grown - window);
      }
    } on AppException {
      // 翻页失败不该弹错 —— 用户滚动到一半看到红条比「没反应」更糟。
      _hasMore = true;
    } finally {
      _inFlight.remove(cancel);
      _loadingMore = false;
    }
  }

  /// 本地这个列表口径下已经缓存了多少封（**不受 200 行窗口限制**）。
  ///
  /// 与列表查询同一份谓词（星标走 [MailDao.countStarred]，其余走
  /// [MailDao.countMailboxSet]）—— 两个数口径不一致的话，「窗口外面还有没有
  /// 邮件」这个判断就会错，窗口也就长不到该长的地方。
  Future<int> _cachedCount() {
    final dao = ref.read(databaseProvider).mailDao;
    if (query.folder == MailFolder.starred) {
      return dao.countStarred(profileIds: query.profileIds);
    }
    return dao.countMailboxSet(
      mailboxes: query.mailboxes,
      type: query.apiType,
      unreadOnly: query.unreadOnly,
    );
  }

  /// 本地这个口径下已缓存的封数是否**多过**当前展示窗口。
  ///
  /// [loadMore] 用它决定「先放本地一页」还是「去服务端拉一页」；列表预热
  /// （`MailListView._primeFirstPage`）也用它 —— 本地明明还有、窗口却卡着
  /// 的时候，进页面就该先露出一页，而不是白发一个「更旧」的请求。
  Future<bool> cachedBeyondWindow() async {
    final window = ref.read(mailListWindowProvider(query));
    return await _cachedCount() > window;
  }

  /// 多邮箱 / 聚合视图滚到底时的那一下：「**再同步一轮**」。
  ///
  /// 这里刻意**不去碰 `EmailRepository.loadOlder`**（那条是给单邮箱翻页的）。
  /// 两个理由：
  ///
  /// - 聚合视图没有统一游标，逐实例往回拉「更旧一页」得到的是几段各自独立
  ///   的旧区间，拼起来不是一条时间线；
  /// - `loadOlder` 会顺手 `_saveRemoteTotal`，把那台实例**全库口径**的
  ///   `total` 写进它当前 scope 那一行。在聚合视图里跑一遍，等于用一个
  ///   与 scope 对不上的数去覆盖「还有几封没同步 / 侧栏分母」的依据 ——
  ///   一个不报错、但会让界面上的数字从此长期偏掉的副作用。
  ///
  /// 真正的「其余邮件」（缺正文、有附件没下）由调度器那一轮负责：`syncOnce`
  /// 跑增量元数据 + 每轮 ≤20 封的正文回填。**附件它确实不碰** —— 那是
  /// 附件按需下载的设计，不是这里该顺手补的洞。
  ///
  /// 返回 `_hasMore = true`：聚合视图的「还有更多」永远为真，因为这里
  /// 没有「翻到底」这个概念 —— 让它变 false 会在列表底部换出「没有更多了」，
  /// 而那句话在聚合视图里是**假的**（信还在服务端）。
  Future<void> _syncRoundForAggregate() async {
    _loadingMore = true;
    try {
      // 有勾选就只推勾中的那几台；没勾选（= 全部实例）才是全局一轮。
      final ids = query.profileIds;
      final scheduler = ref.read(syncSchedulerProvider);
      if (ids.isEmpty) {
        await scheduler.refreshNow();
      } else {
        await Future.wait(ids.map((id) => scheduler.refreshNow(profileId: id)));
      }
    } catch (_) {
      // 一轮同步失败不该在这里弹错：`SyncEngine` 自己会记下失败与退避，
      // 同步页与顶栏那个图标是它该说话的地方。
    } finally {
      _hasMore = true;
      _loadingMore = false;
    }
  }

  Future<void> loadMoreStarred({bool retryExhausted = false}) async {
    final profileId = _singleProfileId;
    if (profileId == null) return;
    final profile = ref.read(profileByIdProvider(profileId));
    if (profile == null) return;

    _loadingMore = true;
    final cancel = CancelToken();
    _inFlight.add(cancel);
    try {
      // 星标列表同样被 200 行窗口截住（`watchStarred` 的默认 limit）：
      // 窗口外还有本地缓存就先放出来，否则写进来的旧星标一样看不见。
      final window = ref.read(mailListWindowProvider(query));
      final cached = await _cachedCount();
      if (cached > window) {
        ref.read(mailListWindowProvider(query).notifier).revealMore();
        return;
      }
      if (!_hasMore && !retryExhausted) return;
      _hasMore = true;

      final oldest = await ref
          .read(databaseProvider)
          .mailDao
          .oldestEmailIdOf(profileId, 0, allReceive: true);
      _hasMore = await ref.read(emailRepositoryProvider).loadStarred(
            profile: profile,
            beforeEmailId: oldest > 0 ? oldest : null,
            cancelToken: cancel,
          );
      final grown = await _cachedCount();
      if (grown > window) {
        ref
            .read(mailListWindowProvider(query).notifier)
            .revealMore(by: grown - window);
      }
    } catch (_) {
      _hasMore = true;
    } finally {
      _inFlight.remove(cancel);
      _loadingMore = false;
    }
  }

  /// 打开一封邮件时调用（进详情页/展开）。
  ///
  /// 次序**只有一份**，在 `EmailRepository.openMail` —— 这里只是转发，
  /// 不要在这儿再抄一遍。原来这个方法自己写着「先标已读、再补正文」那份
  /// 服务端优先的老次序；留着它，谁哪天接上它，已读延迟与离线不落盘那两个
  /// bug 就会原样回来，而且不会有任何测试红。
  ///
  /// 目前零调用方（列表点开走的是路由，详情页自己调 repository），保留是给
  /// 「列表内的展开/长按菜单」这类将来要做的入口留一个位置。
  Future<void> open(MailRow row) => ref
      .read(emailRepositoryProvider)
      .openMail(MailRef(profileId: row.profileId, emailId: row.emailId));

  /// 确保本地有完整正文。
  Future<bool> ensureFull(MailRef mailRef) async {
    try {
      return await ref.read(emailRepositoryProvider).ensureFull(mailRef);
    } catch (_) {
      // 补拉失败 → 详情页用摘要渲染（不是错误，实例可能不支持 full）。
      return false;
    }
  }

  Future<void> setStar(MailRef mailRef, {required bool starred}) =>
      ref.read(emailRepositoryProvider).setStar(mailRef, starred: starred);

  Future<void> markRead(Iterable<MailRef> refs, {required bool read}) =>
      ref.read(emailRepositoryProvider).markRead(refs, read: read);

  Future<void> delete(Iterable<MailRef> refs) async {
    await ref.read(emailRepositoryProvider).delete(refs);
    // 删信之后服务端的 total 立刻变小，而 `remote_total` 只是个快照 ——
    // 不刷的话底部会凭空多出「还有 N 封未同步」（正好是刚删掉的封数），
    // 而且这个假数字点也点不掉（总数一直偏大）。
    await _refreshRemoteTotal(force: true);
  }

  /// 取消本页所有在途请求（页面 dispose 时）。
  ///
  /// **有意留着、目前不接线**：`mailListControllerProvider` 是非 autoDispose 的
  /// `Provider.family`，同一个 query 的两处页面拿到的是**同一个** controller
  /// 实例 —— 在某一页 `dispose` 里调它，会顺手取消另一页正在飞的「加载更多」。
  /// 而 riverpod 3 里 `dispose` 阶段已经不能 `ref.read`，「只在还有订阅时取消」
  /// 这条路也走不通。这两件事都不是眼下要解决的，先留着不动。
  void cancelAll() {
    for (final token in _inFlight) {
      if (!token.isCancelled) token.cancel('page disposed');
    }
    _inFlight.clear();
  }

  /// 只有「一个邮箱」时才有单一实例可言（多邮箱可能是跨实例的）。
  String? get _singleProfileId =>
      query.singleMailbox ? query.mailboxes.first.profileId : null;
}

/// 详情页：本地行 + 附件。
final mailDetailProvider =
    StreamProvider.family<MailRow?, MailRef>((ref, mailRef) {
  final db = ref.watch(databaseProvider);
  return db.mailDao.watch(mailRef.profileId, mailRef.emailId);
}, name: 'mailDetail');

final mailAttachmentsProvider =
    StreamProvider.family<List<MailAttachment>, MailRef>(
  (ref, mailRef) => ref
      .watch(databaseProvider)
      .mailDao
      .watchAttachments(mailRef.profileId, mailRef.emailId),
  name: 'mailAttachments',
);

/// 当前实例（侧栏/底部导航用）。
final currentCapabilitiesProvider = Provider<InstanceCapabilities>(
  (ref) {
    final id = ref.watch(currentProfileIdProvider);
    if (id == null) return const InstanceCapabilities();
    return ref.watch(capabilitiesProvider(id)).value ?? const InstanceCapabilities();
  },
  name: 'currentCapabilities',
);

final currentMailboxesProvider = Provider<List<MailboxAccount>>(
  (ref) {
    final id = ref.watch(currentProfileIdProvider);
    if (id == null) return const <MailboxAccount>[];
    return ref.watch(mailboxesProvider(id)).value ?? const <MailboxAccount>[];
  },
  name: 'currentMailboxes',
);

/// 写邮件入口要不要显示（站点关掉发信、或该账号没有 `email:send` 权限）。
final canSendProvider = Provider<bool>(
  (ref) => ref.watch(currentCapabilitiesProvider).sendEnabled,
  name: 'canSend',
);

/// 全部邮箱的未读数：`profileId` → `accountId` → 未读数（一条流覆盖全部）。
///
/// 只是 [mailboxUnreadProvider] 的底座，UI 不该直接用它 —— 单个邮箱那一格
/// 用 family 那个取，才有稳定的 key 可言。
final mailboxUnreadMapProvider =
    StreamProvider<Map<String, Map<int, int>>>(
  (ref) => ref.watch(databaseProvider).mailDao.watchUnreadByMailbox(),
  name: 'mailboxUnreadMap',
);

/// 未读计数的分组维度：`(profileId, accountId)` → 未读数。
///
/// 目前只算「某实例的某个邮箱」，聚合视图按邮箱分组要用。
///
/// **从一个流里取值**，不是一次性的 `Future`：原来这里是
/// `FutureProvider.family`，只在 `databaseProvider` 变化时算一次 —— 读掉一封
/// 信之后侧栏那颗未读 pill 与筛选面板会一直停在旧数字（而「总未读」走的是
/// `watchUnreadByProfile` 真流，于是两个数字对不上）。
///
/// 底下是**一条** `groupBy` 查询覆盖全部邮箱，同 query 的多个订阅共享它 ——
/// 比原来「每个邮箱各查一次」更省（见 `MailDao.watchUnreadByMailbox`）。
final mailboxUnreadProvider =
    Provider.family<int, ({String profileId, int accountId})>(
  (ref, key) {
    final byMailbox =
        ref.watch(mailboxUnreadMapProvider).value ?? const <String, Map<int, int>>{};
    return byMailbox[key.profileId]?[key.accountId] ?? 0;
  },
  name: 'mailboxUnread',
);

/// 某个 scope 上「服务端一共有多少封」的那条结论（侧栏「未读 / 总数」的
/// 分母）。
///
/// [at] 不是装饰：**它是「已知」的判据**。库里 `remote_total` 的 0 表示
/// 「还不知道」（见 `SyncStates.remoteTotal`），所以「真的是个空邮箱」与
/// 「还没探过」在那一列上长得一样 —— `at == null` 才是「未知」。
///
/// 下面几条 provider 里，**只有 `at != null` 的行才会被收进 Map**，
/// 于是「查不到 = 未知」这一条就够了，`total` 不必再借一个假值（比如 -1）
/// 去表示未知。
typedef MailboxTotal = ({int total, DateTime at});

/// 一个实例全部 scope 的总数：`scope` → 结论（**只含已知的那些**）。
///
/// 与 [mailboxUnreadMapProvider] 同一条理由：几十格共用**一条**查询，
/// 而不是每格一条 —— 写一次库不要唤醒几十个订阅。
///
/// 内层键是 **scope 字符串**而不是 accountId：合并项那个 `all:type:0` 没有
/// 对应的 accountId，硬造一个假的（比如复用 `kAllMailboxes = 0`）就会与
/// 「真的有一个 accountId 为 0 的邮箱」撞上。
final profileMailboxTotalsProvider =
    StreamProvider.family<Map<String, MailboxTotal>, String>(
  (ref, profileId) => ref
      .watch(databaseProvider)
      .mailDao
      .watchSyncStatesOfProfile(profileId)
      .map((byScope) => <String, MailboxTotal>{
            for (final row in byScope.values)
              if (row.remoteTotalAt != null)
                row.scope: (total: row.remoteTotal, at: row.remoteTotalAt!),
          }),
  name: 'profileMailboxTotals',
);

/// 全部实例的总数：`profileId` → `scope` → 结论。
///
/// 它不是 StreamProvider 而是把上面那个 family 按当前实例列表**乘起来**的
/// 普通 Provider：侧栏同时要显示所有实例的行，而「有哪些实例」本来就是
/// `activeProfilesProvider` 流出来的 —— 在这里再写一条「全表的 stream」等于
/// 把同一张表读两遍（未读那条已经这么干了，是因为它按 profileId 分组聚合，
/// 这里则是逐行取列，没必要）。
final mailboxTotalsMapProvider =
    Provider<Map<String, Map<String, MailboxTotal>>>(
  (ref) => <String, Map<String, MailboxTotal>>{
    for (final profile in ref.watch(activeProfilesProvider))
      profile.id: ref.watch(profileMailboxTotalsProvider(profile.id)).value ??
          const <String, MailboxTotal>{},
  },
  name: 'mailboxTotalsMap',
);

/// 某一个邮箱的服务端总数。未知（含合并项）返回 `null`。
///
/// 合并项（`accountId == kAllMailboxes`）刻意返回 `null`：它的 scope 是
/// `all:type:0`，由同步引擎的冷启动基线维护 —— 「这个实例的全部邮箱」没有
/// 「这一个邮箱的总数」可言，而且实例行已经把这台实例的合计说了一遍。
final mailboxTotalProvider =
    Provider.family<int?, ({String profileId, int accountId})>(
  (ref, key) {
    if (key.accountId == kAllMailboxes) return null;
    final scope = EmailRepository.mailboxScope(key.accountId, MailType.receive);
    return ref.watch(mailboxTotalsMapProvider)[key.profileId]?[scope]?.total;
  },
  name: 'mailboxTotal',
);

/// 一个实例的实例级总数（`all:type:0` 那一行）。
///
/// **不要把各邮箱的总数相加**当实例合计：`allReceive` 口径覆盖的收件里
/// 包含归属未知（`account_id = 0`）的那些，逐邮箱相加与它必然对不上，
/// 而用户会拿它跟网页版对账。这一行由同步引擎一直在维护，没有就是 `null`。
final instanceTotalProvider = Provider.family<int?, String>(
  (ref, profileId) {
    final scope = EmailRepository.aggregateScope(MailType.receive);
    return ref.watch(mailboxTotalsMapProvider)[profileId]?[scope]?.total;
  },
  name: 'instanceTotal',
);

/// 参与筛选的全部实例的邮箱列表：`profileId` → 它的邮箱。
///
/// 面板要按实例分组渲染，所以这里给 Map 而不是扁平列表 —— 顺序由
/// `profileOrderOf` 从 `MailboxFilter` 集合里恢复（两边都从同一份
/// `activeProfilesProvider` 出发，不会打架）。
final Provider<Map<String, List<MailboxAccount>>> allMailboxesByProfileProvider =
    Provider<Map<String, List<MailboxAccount>>>(
  (ref) {
    final profiles = ref.watch(activeProfilesProvider);
    final result = <String, List<MailboxAccount>>{};
    for (final profile in profiles) {
      result[profile.id] =
          ref.watch(mailboxesProvider(profile.id)).value ??
              const <MailboxAccount>[];
    }
    return result;
  },
  name: 'allMailboxesByProfile',
);

/// 面板的**已生效**勾选态：从 prefs 折出来，并剔除已经不存在的实例/邮箱。
final Provider<MailboxSelection> mailboxFilterSelectionProvider =
    Provider<MailboxSelection>(
  (ref) {
    final all = allBoxesOf(ref.watch(allMailboxesByProfileProvider));
    return MailboxSelection.resolve(
      all,
      ref.watch(prefsStoreProvider).mailboxFilter,
    );
  },
  name: 'mailboxFilterSelection',
);

/// 面板里「勾一下就生效」的那一层。
///
/// 每一次 toggle 立刻写 prefs，不经过任何「应用」按钮（spec §2.3）。
/// 单独一层 Notifier 而不是直接改 prefs，是为了让「被最少留一个挡下来」
/// 这个结论有地方留住 —— UI 靠它弹提示。
final NotifierProvider<MailboxFilterDraft, MailboxSelection>
    mailboxFilterDraftProvider =
    NotifierProvider<MailboxFilterDraft, MailboxSelection>(
  MailboxFilterDraft.new,
  name: 'mailboxFilterDraft',
);

class MailboxFilterDraft extends Notifier<MailboxSelection> {
  @override
  MailboxSelection build() => ref.watch(mailboxFilterSelectionProvider);

  void toggle(MailboxFilter box) => _apply(state.toggle(box));

  void toggleProfile(String profileId) => _apply(state.toggleProfile(profileId));

  void selectAll() => _write(null);

  void _apply(MailboxSelection next) {
    if (next.rejected) {
      // 被「最少留一个」挡下来了：状态照旧（集合没变），只把「刚被拒过」
      // 这件事摆出来给 `ref.listen` 用。
      state = next;
      return;
    }
    _write(next.toPrefsValue());
  }

  void _write(List<MailboxFilter>? value) {
    unawaited(ref.read(prefsStoreProvider).setMailboxFilter(value));
    // prefs 不是响应式的：不手动重算的话，列表要等下一次无关的重建才变。
    ref.invalidate(mailboxFilterSelectionProvider);
  }
}

/// 把一个实例的邮箱列表转成发信页要用的「发件人候选」。
///
/// **`accountId <= 0` 的一律不算候选**：降级路径兜出来的那个邮箱 id 是 0
/// （`account_repository.dart` 的 `_fallbackOnly`：离线冷启动、连
/// `loginUserInfo` 都没拿到时用 `profile.email` 造一个），而服务端
/// `accountService.selectById(c, 0)` 查不到行 —— 拿它发信必定回一句
/// `senderAccountNotExist`。收信只看 `email`，所以那个 0 在别的用途上无害；
/// **发信是唯一一个 id 会被服务端按主键取行的用途**，所以过滤只加在这里。
List<MailboxAccount> senderCandidates(
  List<MailboxAccount> mailboxes,
  // 只留着稳住签名：过滤判据已经不需要它了（早先的兜底要读 profile.email，
  // 现在那条路删了）。`composeSendersProvider` 是唯一的调用方。
  Profile profile,
) {
  if (mailboxes.isNotEmpty) {
    return mailboxes.where((a) => a.accountId > 0).toList(growable: false);
  }
  // 早先这里会**造**一个 `MailboxAccount(email: profile.email)` 当兜底。现在不造了 ——
  // 造出来的那个 id 是 0，服务端 `selectById(c, 0)` 查不到行，拿它发信必定失败。
  // 空表就是空表：调用方据此显示「没有可用的发件邮箱」，比给一个必失败的行好。
  return const <MailboxAccount>[];
}

/// 邮件在哪些文件夹里可见（详情页的「星标/已读」控件要按这个判断）。
bool isReceiveFolder(MailFolder folder) => folder != MailFolder.send;

/// 多选的**唯一状态**。
///
/// 非 autoDispose（与 `mailboxFilterDraftProvider` 同一个理由）：这份状态要
/// 在「右栏面板」与「底部操作栏」两处被读到，中途任何一个 watcher 走了都
/// 不能把它清掉 —— 右栏面板本身在窄屏下根本不挂载。
///
/// **不放进 URL**：`?sel=` 现在表达的是「右栏开着哪一封」（可分享、可深链），
/// 而多选是一批临时的行下标，塞进 URL 既分享不出去，也会让 `pageKey` 抖动
/// （见 `Routes.mailOf` 的注释）。
final NotifierProvider<MailSelectionController, MailSelection>
    mailSelectionProvider =
    NotifierProvider<MailSelectionController, MailSelection>(
  MailSelectionController.new,
  name: 'mailSelection',
);

class MailSelectionController extends Notifier<MailSelection> {
  @override
  MailSelection build() => MailSelection.empty;

  /// 换了一块列表（切文件夹 / 换实例 / 换星标 Tab）：旧选择立刻作废。
  ///
  /// 由列表自己在 `initState` / `didUpdateWidget` 里叫 —— 它知道自己在哪一块
  /// 列表上，见 [MailListView] 的 `_syncScope`。
  void enter(String scope) {
    if (state.scope == scope) return;
    state = MailSelection(scope: scope);
  }

  /// 退出多选。
  void clear() {
    if (!state.isActive) return;
    state = MailSelection(scope: state.scope);
  }

  /// 只选中这一行（单击已选中的行也要走它，把别的都放掉）。
  void selectOnly(int index, {MailRef? anchor, bool clearAnchor = false}) {
    state = state.only(index, anchor: anchor, clearAnchor: clearAnchor);
  }

  /// Ctrl / Cmd 点击：切换一行。
  ///
  /// **减到空就退出多选**（`isActive` 掉了）—— 用户一路取消到最后一行的意思
  /// 显然是「不想选了」，而不是「留着多选模式空着」。
  void toggle(int index) {
    final next = state.toggle(index);
    // 退出多选时 scope 要留着（下一帧列表还会把同一个 scope 报回来，
    // 那时 `enter` 因为 scope 相同不会重置），否则列表会以为「换了一块
    // 列表」而重新建一次状态。
    state = next.isActive ? next : MailSelection(scope: state.scope);
  }

  /// Shift 点击：从锚点到这一行。
  void extendTo(int index, List<MailRef> ordered) {
    state = state.extendTo(index, ordered);
  }

  /// 长按：进入多选并起一条拖动带。
  void beginBand(int index, {MailRef? anchor}) {
    state = state.beginBand(index, anchor: anchor);
  }

  /// 拖动中：带子从 [start] 起、长 [length] 行。
  void updateBand(int start, int length) {
    // `isActive` 一旦掉下来（长度归 0）就退出多选，与 [toggle] 同一个口径。
    final next = state.bandAt(start, length);
    state = next.isActive ? next : MailSelection(scope: state.scope);
  }

  /// 松手：带子折成集合。
  void endBand(int rowCount) {
    final next = state.commitBand(rowCount);
    state = next.isActive ? next : MailSelection(scope: state.scope);
  }

  /// 全选当前列表里的这些行。
  void selectAll(int rowCount) {
    state = state.all(rowCount);
  }

  /// 右键落在某一行上：**在选中的里面就保持这一批**，不在就换成它。
  ///
  /// 这是「右键 = 选中该邮件」的实现（用户需求 2）。判断「在不在」走的是
  /// 解析后的行下标，与列表高亮用的是同一份结论 —— 两处各判一次的话，
  /// 右键一行、高亮另一行的 bug 迟早出现。
  void rightClick(int index, List<MailRef> ordered) {
    final picked = state.positions(ordered.length);
    if (picked.contains(index)) {
      // 在这一批里：不动选择（右键一封已选中的信，用户要处理的是**这一批**）。
      return;
    }
    state = state.only(index, anchor: ordered[index], clearAnchor: true);
  }
}

/// 多选统计 + 那一批行。
@immutable
class SelectedMails {
  const SelectedMails({
    this.rows = const <MailRow>[],
    this.refs = const <MailRef>[],
    this.indices = const <int>[],
    this.total = 0,
  });

  /// 选中、且**当前列表里还解析得出来**的那几封（按列表顺序）。
  final List<MailRow> rows;
  final List<MailRef> refs;

  /// [rows] 里每一封在**整块列表**里的行下标。
  ///
  /// 面板上的缩略表要能「点一下取消这一封」—— 那需要的是它在列表里的下标，
  /// 而不是它在这一小批里的名次。把它带上，就不用在下游再算一遍
  /// （`positions` 与这里必然同源）。
  final List<int> indices;

  /// 这一块列表**当前加载了多少行**（不是选了多少）。
  ///
  /// 「全选（本页 N 封）」那个 N 是它，不是 [count] —— 面板上只有
  /// `SelectedMails` 一个数据来源，不带上这一个数，全选就只能按「已选几封」
  /// 去选，点一下反而把选择缩到一封。
  final int total;

  int get count => rows.length;
  int get unread => rows.where((r) => r.isUnread).length;
  int get withAttachments =>
      rows.where((r) => r.hasFullBody && r.attachmentCount > 0).length;

  /// 涉及几个实例（统计里「实例 J 个」）。
  int get instances => rows.map((r) => r.profileId).toSet().length;

  /// 时间范围。拿不到时间的行不算进去；一封都没有时两个都是 null。
  ({DateTime from, DateTime to})? get span {
    DateTime? from;
    DateTime? to;
    for (final row in rows) {
      final at = row.createTime;
      if (at == null) continue;
      if (from == null || at.isBefore(from)) from = at;
      if (to == null || at.isAfter(to)) to = at;
    }
    if (from == null || to == null) return null;
    return (from: from, to: to);
  }
}

/// 当前选中的那几封（**看的是一块具体的列表**）。
///
/// 统计口径与按钮作用的对象是**同一个集合**：都来自 [MailSelection.positions]
/// 在 `mailListProvider(query)` 上的解析结果 —— 删掉的、被过滤掉的、越界的
/// 一律不算。这一点很重要：显示「已选 5 封」而实际只删了 3 封，是这类界面
/// 最糟的失败方式。
///
/// **这个 provider 绝不写回 [mailSelectionProvider]**（riverpod 会抛
/// 「Tried to modify a provider while the widget tree was building」）。
/// 「选中项一个都不剩了 → 退出多选」只由视图层的 `ref.listen` 做。
final selectedRowsProvider = Provider.family<SelectedMails, MailListQuery>(
  (ref, query) {
    final selection = ref.watch(mailSelectionProvider);
    final rows = ref.watch(mailListProvider(query)).value ?? const <MailRow>[];
    if (!selection.isActive || rows.isEmpty) {
      return SelectedMails(total: rows.length);
    }
    final picked = selection.positions(rows.length);
    return SelectedMails(
      rows: <MailRow>[for (final index in picked) rows[index]],
      refs: <MailRef>[
        for (final index in picked)
          MailRef(profileId: rows[index].profileId, emailId: rows[index].emailId),
      ],
      indices: picked,
      total: rows.length,
    );
  },
  name: 'selectedRows',
);

/// 一块列表的 scope 串（多选不跨列表串味的判据）。
///
/// 由查询反推而不是让每个调用方自己拼：`folder` / `unreadOnly` 的写法一旦
/// 在两处各写一遍，就一定会有一处忘了带 `unreadOnly` —— 那样「未读邮件」与
/// 「收件箱」会共用一份选择。
String selectionScopeForQuery(MailListQuery query, {String? listNode}) =>
    selectionScopeOf(
      listNode: listNode,
      folder: query.folder.name,
      unreadOnly: query.unreadOnly,
      mailboxSet: _mailboxSetOf(query.mailboxes),
    );

/// 「这一块列表看的是哪几个邮箱」的稳定串。
///
/// **排序后拼**，与 `MailListQuery` 那条「集合顺序不参与相等」的口径一致：
/// 用户在筛选面板里勾选的先后顺序不该让同一块列表变成另一个 scope（那会让
/// 他刚勾好的那一批选择莫名其妙地失效）。空集 = 全部实例（`*`）。
String _mailboxSetOf(List<MailboxFilter> boxes) {
  if (boxes.isEmpty) return '*';
  final wires = <String>[for (final box in boxes) box.wire]..sort();
  return wires.join(',');
}
