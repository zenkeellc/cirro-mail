import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_defaults.dart';
import '../core/db/database.dart';
import '../data/models/enums.dart';
import '../data/models/mail_ref.dart';
import '../data/models/mail_row.dart';
import '../data/models/profile.dart';
import '../data/repositories/capability_repository.dart';
import '../data/repositories/email_repository.dart';
import '../features/compose/compose_controller.dart' show draftsProvider;
import '../features/sync/sync_queue.dart';
import '../features/sync/sync_stage.dart';
import '../instance/profile_runtime.dart';
import 'core_providers.dart';
import 'mail_providers.dart';
import 'profile_providers.dart';

/// 设备当前的联网状态。
///
/// 断网时**不停调度器**，只是让它的每一轮立刻失败并进入退避 —— 停掉再启
/// 会丢掉每个实例各自的退避进度，而且 connectivity 在桌面平台并不可靠
/// （Windows/Linux 上常常一直报 none）。所以它只用来：
/// - 给 UI 显示一条「离线」横幅；
/// - 网络恢复的**那一瞬间**立刻补一次（`refreshNow`），而不是等退避走完。
final StreamProvider<bool> onlineProvider = StreamProvider<bool>(
  (ref) async* {
    final connectivity = Connectivity();
    // 先给一个当前状态，避免首帧就显示「离线」。
    yield _isOnline(await connectivity.checkConnectivity());
    await for (final result in connectivity.onConnectivityChanged) {
      yield _isOnline(result);
    }
  },
  name: 'online',
);

bool _isOnline(List<ConnectivityResult> results) {
  if (results.isEmpty) return true; // 拿不到结论时按在线处理，别误报离线。
  return results.any((r) => r != ConnectivityResult.none);
}

/// 每个实例的未读数。
///
/// **服务端没有未读计数接口**，只能算本地库。冷启动第一次同步完成前这个值
/// 偏低（甚至全是 0），UI 要显示「同步中」而不是把这个 0 当真。
final StreamProvider<Map<String, int>> unreadByProfileProvider =
    StreamProvider<Map<String, int>>(
  (ref) => ref.watch(databaseProvider).mailDao.watchUnreadByProfile(),
  name: 'unreadByProfile',
);

/// 当前实例的未读数（底部导航角标）。
final Provider<int> currentUnreadProvider = Provider<int>(
  (ref) {
    final id = ref.watch(currentProfileIdProvider);
    if (id == null) return 0;
    return ref.watch(unreadByProfileProvider).value?[id] ?? 0;
  },
  name: 'currentUnread',
);

/// 全部实例的未读总数（聚合入口的角标）。
final Provider<int> totalUnreadProvider = Provider<int>(
  (ref) => (ref.watch(unreadByProfileProvider).value ?? const <String, int>{})
      .values
      .fold<int>(0, (a, b) => a + b),
  name: 'totalUnread',
);

/// 某一个实例的未读数。
///
/// 侧栏实例行右侧那格「未读 / 总数」的分子 —— 与 [currentUnreadProvider]
/// 读的是同一条流（`watchUnreadByProfile`），只是这一个用**任意** id，
/// 不跟当前实例走。实例行要的是「这一台的收件未读」，与「我现在在看哪台」
/// 无关。
final profileUnreadProvider = Provider.family<int, String>(
  (ref, profileId) =>
      ref.watch(unreadByProfileProvider).value?[profileId] ?? 0,
  name: 'profileUnread',
);

/// 发件箱的全部条目（含 `failed` / `unknown`，见 `LocalDao.watchOutbox`）。
///
/// **不做实例过滤**：发件箱是一个「本机待办清单」，用户想看到的正是
/// 「我这台设备上还有哪些信没发出去」，跨实例合起来看才有意义。
final StreamProvider<List<DbOutboxEntry>> outboxProvider =
    StreamProvider<List<DbOutboxEntry>>(
  (ref) => ref.watch(sendRepositoryProvider).watchOutbox(),
  name: 'outbox',
);

/// 发件箱条目数（底部导航/设置页角标）。
final Provider<int> outboxCountProvider = Provider<int>(
  (ref) => ref.watch(outboxProvider).value?.length ?? 0,
  name: 'outboxCount',
);

/// 发送队列的微标签数据（需求六）：还在排队等发送的信有多少、下一封什么时候走。
///
/// 由 [outboxProvider] 派生而不是自己开一条 drift watch：这两个数说的都是
/// 同一张表的事，分成两条流迟早会在某一帧上给出互相矛盾的数字
/// （标签说 2 封，点开面板只有 1 封）。
///
/// 口径与 [outboxCountProvider]（角标）**刻意不同**：
/// - 角标数的是「发件箱里有几封要留意」，含判死与结果不明；
/// - 这个数的是「还排着队没发出去的」，只数 `pending`。
///   两者混用会让用户对不上账。
///
/// `nextAt` = 队列里最早的一个 `scheduledAt`；全都能立刻发时为 null。
final Provider<({int count, DateTime? nextAt})> sendQueueProvider = Provider(
  (ref) {
    final entries = ref.watch(outboxProvider).value;
    if (entries == null) return (count: 0, nextAt: null);
    var count = 0;
    DateTime? nextAt;
    for (final entry in entries) {
      if (entry.status != 'pending') continue;
      count++;
      final at = entry.scheduledAt;
      if (at == null) continue;
      if (nextAt == null || at.isBefore(nextAt)) nextAt = at;
    }
    return (count: count, nextAt: nextAt);
  },
  name: 'sendQueue',
);

/// 「还有几封没同步」—— 列表底部占位行用（需求三）。
///
/// 口径：`服务端 total − 本地已有条数`，两者必须是**同一个 scope**
/// （同实例、同邮箱、同方向），否则这个差值是错的。
///
/// null 表示**不知道**，两种情形都返回 null：
/// - `remoteTotal == 0`：还没完整拉过一次 `/email/list`（`/email/latest`
///   的响应里没有 `total`）；
/// - 查询不是单实例单邮箱口径（聚合视图没有统一游标）。
///
/// 做成 `StreamProvider.family` 而不是一次性 Future：本地条数每同步一封就变，
/// 那个数要**实时**往下掉，占位行上的数字才会跟着动。
final unsyncedPlaceholderProvider =
    StreamProvider.family<int?, MailListQuery>((ref, query) {
  // 只有单个邮箱才谈得上「翻到底」—— 多邮箱的各实例游标是独立序列。
  if (!query.singleMailbox) return Stream<int?>.value(null);
  if (query.folder == MailFolder.starred) return Stream<int?>.value(null);

  final box = query.mailboxes.first;
  final profileId = box.profileId;
  final allReceive = box.accountId == kAllMailboxes;
  final scope = EmailRepository.scopeOf(
    accountId: box.accountId,
    type: query.apiType,
    allReceive: allReceive,
  );
  final dao = ref.watch(databaseProvider).mailDao;

  return dao.watchSyncState(profileId, scope).asyncMap((state) async {
    final total = state?.remoteTotal ?? 0;
    if (total <= 0) return null;
    final local = await dao.countMailbox(
      profileId,
      box.accountId,
      type: query.apiType,
      allReceive: allReceive,
    );
    // 服务端的 total 可能含已被本地删掉的行，差出负数没有意义 ——
    // 夹到 0，让上层统一按「没有未同步的」处理。
    return (total - local).clamp(0, total);
  });
}, name: 'unsyncedPlaceholder');

/// 「立即全部发出」按钮的忙碌态 —— 只覆盖用户手动触发的那一次。
final NotifierProvider<OutboxFlushController, bool> outboxFlushingProvider =
    NotifierProvider<OutboxFlushController, bool>(
  OutboxFlushController.new,
  name: 'outboxFlushing',
);

class OutboxFlushController extends Notifier<bool> {
  @override
  bool build() => false;

  Future<void> flush() async {
    if (state) return;
    state = true;
    try {
      await ref.read(syncSchedulerProvider).flushOutbox();
    } finally {
      if (ref.mounted) state = false;
    }
  }
}

/// 调度器的运行控制。
///
/// 它是整条同步链路的唯一入口：谁来启、谁该停、App 前后台怎么切、断网恢复
/// 要不要立刻补一次。`SyncScheduler` 本身只做「谁先谁后」，不做生命周期决策。
///
/// 三条规则：
/// 1. **有已登录实例就跑**。没有（首次启动、全部登出）时不建时钟，省电。
/// 2. **App 进后台就停**（Android/iOS）。桌面端不适用 —— 桌面窗口 `paused`
///    意味着最小化，但用户仍然期望后台收信，所以桌面保持运行。
/// 3. **恢复前台立刻补一次**，不等一个完整间隔。
class SyncController extends Notifier<SyncStatus> {
  StreamSubscription<String>? _invalidSub;
  AppLifecycleListener? _lifecycle;
  /// 用户**要不要**收信。只有两处会把它变成 false：设置页那个总开关
  /// （[pause]），以及移动端进后台。桌面端**不进后台**（见 [_onPause]）。
  bool _foreground = true;

  /// 移动端才有意义：进后台就别再等网络恢复补拉（那条补拉是给「用户正
  /// 看着」准备的）。桌面端后台照跑，见 [_onPause]。
  ///
  /// 以前它是和「要不要收信」挤在同一个 [_foreground] 标志位上的，于是
  /// 有了这样一个洞：macOS 上关掉窗口 → `_foreground = false` → 下一轮
  /// 同步写 `profiles` 表（每次成功都会写 `lastSyncAt`）→ `build()` 重算 →
  /// 走到 `else` 分支把调度器停掉。**窗口一关，收信就静默地死了**，用户
  /// 还以为它在后台跑。「留在菜单栏」正是建立在「关窗之后仍然收信」上的，
  /// 所以这两件事必须分开。
  bool _inBackground = false;
  bool _lastOnline = true;

  /// 发件箱的「孤儿复位」只做一次（见 `build` 里的调用点）。
  bool _recoveredOutbox = false;

  /// 冷启动补探过权限的实例（每个 App 运行最多一次）。
  /// 与 `_recoveredOutbox` 同一套「只做一次」的写法 —— 命中即 add。
  final Set<String> _permProbed = <String>{};

  /// 上一次真正推给调度器的实例集合（见 `build` 里那道闸门）。
  String _scheduleSignature = '';

  /// 发件箱的慢时钟有没有起过。
  bool _outboxStarted = false;

  /// 「被调度的集合」的指纹：只有它变了才需要把实例重新推给调度器。
  ///
  /// 取的是**调度相关的**字段（和 `router.dart` 里 `_AuthRefresh` 同一套），
  /// 刻意不含 `lastSyncAt` —— 那个字段每轮同步成功都会写一次，把它算进来
  /// 就等于「每轮同步都重推一遍」，而重推的代价是把每个 engine 的排期
  /// 又拨到现在（`SyncEngine.start`），与仍在飞的那一轮打架。
  static String _signatureOf(List<Profile> profiles) => profiles
      .map((p) => '${p.id}:${p.userId}:${p.needsLogin}:${p.baseUrl}')
      .join('|');

  @override
  SyncStatus build() {
    // **被调度的集合**是 `syncCandidates`，不是 `activeProfiles`。
    // 两者的差别只有一条：需重登的那批实例仍然在调度里（它们要有一轮
    // 「验活」的机会，见 `syncCandidatesProvider` 的注释）。少了这一条，
    // 「401 → 标记 → 被排除 → 永远不再验 → 标记永远留着」就闭环了，
    // 用户看到的是「这台实例再也不会自己收信」。
    final profiles = ref.watch(syncCandidatesProvider);
    // 「这个产品现在健康吗」还是按**真正能用的**实例算：一个都没登进去时
    // 不该显示「同步中」。
    final loggedIn = ref.watch(activeProfilesProvider).isNotEmpty;

    _invalidSub ??= ref
        .read(runtimeRegistryProvider)
        .invalidated
        .listen((profileId) {
      // 某个实例被标「需重登」/ 换了服务器 → 重算调度集合。
      //
      // 注意这里**用的是 `syncCandidatesProvider`**：被标了「需重登」的
      // 实例仍然留在集合里，`SyncScheduler.start` 会去问一次服务端它到底
      // 还算不算数 —— 结论是「还有效」就把标记撤掉（那正是这把钥匙的用途），
      // 「确实废了」才真的把它排除。先前这里读到的是 `activeProfiles`，
      // 于是那个标记一落库，实例就再没有任何机会被验证。
      //
      // 不用 invalidate 自己再触发一次 build（那会和 profile 流的更新打架）。
      final remaining = ref.read(syncCandidatesProvider);
      unawaited(ref.read(syncSchedulerProvider).syncProfiles(remaining));
      debugPrint('SyncController: $profileId 状态变化，调度集合已重算');
    });

    // 每次 build 都重新注册：Riverpod 会在 provider 重算时**自动移除**上一次
    // 的订阅，所以不能用一个标志位跳过（那样第一次重算之后就再也不监听了）。
    ref.listen<AsyncValue<bool>>(
      onlineProvider,
      (previous, next) {
        final online = next.value ?? true;
        final recovered = online && !_lastOnline;
        _lastOnline = online;
        if (recovered && _foreground && !_inBackground) {
          // 网络恢复：立刻补一轮，不等每个实例各自的退避走完。
          final scheduler = ref.read(syncSchedulerProvider);
          unawaited(scheduler.refreshNow());
          // 发件箱也要立刻补一次：「断网点发送 → 进发件箱 → 网络恢复自动发出」
          // 是这个功能的验收条件，靠 20 秒的慢时钟最多要等 20 秒。
          unawaited(scheduler.flushOutbox());
        }
      },
      fireImmediately: true,
    );

    _lifecycle ??= AppLifecycleListener(
      onResume: _onResume,
      onPause: _onPause,
      onHide: _onPause,
    );

    if (_foreground && profiles.isNotEmpty) {
      // **只在集合真的变了的时候重推**（`syncCandidatesProvider` 是
      // `profiles` 表的 live query，而这张表每轮同步成功都会被写一次
      // `lastSyncAt`，于是 build 会被反复重算 —— 不加这道闸门，每次重算
      // 都会 `start(...)` 一遍，把所有 engine 的排期拨到现在）。
      // 集合没变时 `SyncScheduler` 那边本来也不该有任何动作，所以这里
      // 跳过是等价的，而不是「少做了一步」。
      //
      // 记住的是**指纹**而不是「上一次的列表实例」：`profiles` 表每次写
      // 都会产出一批新的 `Profile` 对象，比对象身份永远不相等。
      final signature = _signatureOf(profiles);
      if (signature != _scheduleSignature) {
        _scheduleSignature = signature;
        // 同步调用即可：`syncProfiles` 建时钟是同步的，
        // 它内部的 `_tick()` 是 fire-and-forget。
        unawaited(ref.read(syncSchedulerProvider).syncProfiles(profiles));

        // 冷启动补一次「权限派生」的能力闸，每个实例每次 App 运行最多一次。
        // 为什么挂在这里（而不是新开一个 `AppLifecycleListener`、也不是塞进
        // `SyncScheduler`）：这个分支冷启动时必然跑一次（`_scheduleSignature`
        // 初值为空），而且这个 provider 本来就带生命周期语义。
        //
        // 两道闸拦的是两件不同的事：signature 拦「同一轮 build 重复推」，
        // `_permProbed` 拦「跨 build / 跨 provider 重建」。
        //
        // 用 `mail_providers.dart` 的 `runtimeProvider(profileId)`：它内部就是
        // `registry.ensure(profile)`，且**没有自己的 onDispose** —— runtime 的
        // 生命周期归 registry 单例管（见 `runtimeRegistryProvider` 的
        // `ref.onDispose(registry.dispose)`）。
        // **必须**是 `ref.read` 而不是 `ref.watch`：`watch` 会让本 provider
        // 订阅那一个 family 实例，profile 一变就整套重算。
        // `runtimeProvider` 可能返回 null（实例还没进流）——
        // `probePermsInBackground` 自己判空返回。
        //
        // **不给 build 增加延迟**：`probePermsInBackground` 内部是 fire-and-forget。
        // 这条路径每轮心跳都在跑，不能在这里 await。
        for (final p in profiles) {
          if (!_permProbed.add(p.id)) continue;
          probePermsInBackground(
            ref.read(capabilityRepositoryProvider),
            ref.read(runtimeProvider(p.id)),
          );
        }
      }
      // 发件箱跟收信共用这个调度器（见 `SyncScheduler.sends` 的注释：
      // 两边各跑一套时钟会出现「发 15MB 附件的同时又发起一轮收信」）。
      //
      // 和上面同一条理由：`startOutbox` 会**先立刻 flush 一次**再起时钟，
      // 每次 build 都调一遍等于每轮同步又额外触发一次发件箱刷新。
      if (!_outboxStarted) {
        _outboxStarted = true;
        ref.read(syncSchedulerProvider).startOutbox();
      }
      // 「上次异常退出留下的 sending 孤儿」只收拾一次 —— build 会因为
      // profiles 流的变化反复重算，每次重算都判一次会把用户正在发的信误判。
      if (!_recoveredOutbox) {
        _recoveredOutbox = true;
        unawaited(ref.read(syncSchedulerProvider).recoverOutbox());
      }
    } else {
      // 停下来的时候把这两个「起过一次」的标记清掉，下次恢复前台/重新登录
      // 时才会真的再起一遍。
      _outboxStarted = false;
      _scheduleSignature = '';
      final scheduler = ref.read(syncSchedulerProvider);
      scheduler.stop();
      scheduler.stopOutbox();
    }

    // 重算时 Riverpod 会先跑这里再跑 build —— 所以把跨 build 持有的资源
    // 一并清掉并把字段复位，让下一次 build 重新建立。
    ref.onDispose(() {
      unawaited(_invalidSub?.cancel());
      _invalidSub = null;
      _lifecycle?.dispose();
      _lifecycle = null;
    });

    return SyncStatus(
      running: _foreground && profiles.isNotEmpty && loggedIn,
      profileCount: profiles.length,
    );
  }

  void _onPause() {
    // 桌面端不适用「进后台就停」——最小化、乃至关掉最后一个窗口之后，
    // 用户仍然期望收信（关窗之后 App 还在菜单栏里活着，见 macos/Runner/
    // AppDelegate.swift）。桌面上这里**什么都不做**：调度器该停的两种情况
    // 是「用户自己关掉了收信」和「移动端进了后台」。
    if (_isDesktop) return;
    _inBackground = true;
    if (!_foreground) return;
    final scheduler = ref.read(syncSchedulerProvider);
    scheduler.stop();
    scheduler.stopOutbox();
    state = state.copyWith(running: false);
  }

  void _onResume() {
    final wasBackground = _inBackground;
    _inBackground = false;
    // 回到前台是「验活」最合适的时机之一：用户打开 App 就意味着网络大概通了，
    // 而这两行以前读的是 `activeProfiles` —— 掉线的实例进不了集合，
    // 于是**永远不会**被重新验证一次。
    final profiles = ref.read(syncCandidatesProvider);
    if (profiles.isEmpty) return;
    final scheduler = ref.read(syncSchedulerProvider);
    unawaited(scheduler.syncProfiles(profiles));
    scheduler.startOutbox();
    if (wasBackground) {
      scheduler.refreshNow();
      unawaited(scheduler.flushOutbox());
    }
    state = state.copyWith(running: true);
  }

  /// 用户在设置页关掉了「后台轮询与通知」。
  void pause() {
    _foreground = false;
    final scheduler = ref.read(syncSchedulerProvider);
    scheduler.stop();
    scheduler.stopOutbox();
    state = state.copyWith(running: false);
  }

  /// 用户重新打开。
  void resume() {
    _foreground = true;
    final profiles = ref.read(syncCandidatesProvider);
    if (profiles.isEmpty) return;
    final scheduler = ref.read(syncSchedulerProvider);
    unawaited(scheduler.syncProfiles(profiles));
    scheduler.startOutbox();
    scheduler.refreshNow();
    state = state.copyWith(running: true);
  }

  /// 用户切到某个实例（侧栏点击）。
  void setActiveProfile(String? profileId) =>
      ref.read(syncSchedulerProvider).setActiveProfile(profileId);

  /// 打开 / 离开「已发送」文件夹。
  void setIncludeSent(bool includeSent) =>
      ref.read(syncSchedulerProvider).setIncludeSent(includeSent);
}

final NotifierProvider<SyncController, SyncStatus> syncControllerProvider =
    NotifierProvider<SyncController, SyncStatus>(
  SyncController.new,
  name: 'syncController',
);

/// 调度器的对外状态快照。
@immutable
class SyncStatus {
  const SyncStatus({this.running = false, this.profileCount = 0});

  final bool running;
  final int profileCount;

  SyncStatus copyWith({bool? running, int? profileCount}) => SyncStatus(
        running: running ?? this.running,
        profileCount: profileCount ?? this.profileCount,
      );

  @override
  bool operator ==(Object other) =>
      other is SyncStatus &&
      other.running == running &&
      other.profileCount == profileCount;

  @override
  int get hashCode => Object.hash(running, profileCount);
}

/// 每个实例的运行摘要（诊断页）。
final Provider<List<({String profileId, String profileName, String status})>>
    schedulerDiagnosticsProvider = Provider(
  (ref) => ref.watch(syncSchedulerProvider).diagnostics(),
  name: 'schedulerDiagnostics',
);

/// 同步状态面板的一行（需求一）。
///
/// 它是「把三个本来就存在的数据源拼成一句人话」：
/// - **运行态**来自 `SyncEngine` 的内存快照（同步中 / 等待中 / 已停止 / 要重登）；
/// - **已同步**来自本地库（`watchReceiveCountByProfile`，实时）；
/// - **未同步**来自 `SyncStates.remoteTotal` 减上面那个数。
///
/// [unsynced] 为 null 表示**不知道**（还没完整拉过一次 `/email/list`，
/// `remoteTotal == 0`）—— 界面上要显示「—」而不是 0，两者含义完全不同：
/// 0 是「同步完了」，null 是「还没算出来」。
@immutable
class SyncOverview {
  const SyncOverview({
    required this.profileId,
    required this.profileName,
    required this.syncing,
    required this.stopped,
    required this.needsLogin,
    required this.lastSuccessAt,
    required this.nextRunAt,
    required this.failCount,
    required this.lastError,
    required this.localCount,
    required this.unsynced,
  });

  final String profileId;
  final String profileName;

  final bool syncing;
  final bool stopped;

  /// token 被判 401，该实例的循环已经停了，等用户重登。
  final bool needsLogin;

  final DateTime? lastSuccessAt;
  final DateTime? nextRunAt;
  final int failCount;
  final String? lastError;

  /// 本地已缓存的收件数。
  final int localCount;

  /// 还差几封（`remoteTotal - localCount`）；null = 还不知道。
  final int? unsynced;

  /// 「等待中」那行要显示的倒计时（秒）。null = 没有排期。
  int? get secondsToNextRun {
    final next = nextRunAt;
    if (next == null) return null;
    final left = next.difference(DateTime.now().toUtc()).inSeconds;
    return left > 0 ? left : 0;
  }
}

/// 某一轮快照里还没轮到（或压根不在表里）的实例。
///
/// 设置页拿它来给「这台实例现在是什么状态」——`syncOverviewProvider`
/// 第一次算完之前是 `AsyncLoading`，那时该显示「同步中」而不是空白。
SyncOverview? syncOverviewOf(Ref ref, String profileId) =>
    _pick(ref.watch(syncOverviewProvider).value, profileId);

/// [syncOverviewOf] 的 `WidgetRef` 版本（屏幕里拿的通常是这个）。
///
/// 两个入口而不是一个泛型：`Ref` 与 `WidgetRef` 没有公共父类，
/// 而 `watch` 的返回类型在两边是一样的 —— 共用 [_pick] 才是去重的地方。
SyncOverview? syncOverviewOfWidget(WidgetRef ref, String profileId) =>
    _pick(ref.watch(syncOverviewProvider).value, profileId);

SyncOverview? _pick(List<SyncOverview>? rows, String profileId) {
  if (rows == null) return null;
  for (final row in rows) {
    if (row.profileId == profileId) return row;
  }
  return null;
}

/// 同步状态面板的数据源。
///
/// 两路信号合成一条流：
/// - 本地收件计数（drift watch，每落一封就变）；
/// - 调度器的 [SyncScheduler.pulses]（每轮同步前后各一次，用来把「正在同步」
///   这个瞬时态和「上次成功」这类结束才变的数字都带上）。
///
/// `remoteTotal` **不**做成第三条 watch：它只在完整拉过一次列表时变，
/// 每次重算时现读一次本地库（一次带主键的查询）比多挂一条订阅省事得多。
final StreamProvider<List<SyncOverview>> syncOverviewProvider =
    StreamProvider<List<SyncOverview>>(
  (ref) async* {
    final scheduler = ref.watch(syncSchedulerProvider);
    // 面板要列出**所有该被调度的**实例 —— 含那些标着「需重登」的。
    // 用 `activeProfiles` 的话，恰恰是最需要被看见的那台（停摆的、
    // 等重登的）会从面板里消失，用户根本不知道该点什么。
    final profiles = ref.watch(syncCandidatesProvider);
    if (profiles.isEmpty) {
      yield const <SyncOverview>[];
      return;
    }

    final dao = ref.watch(databaseProvider).mailDao;
    var counts = const <String, int>{};

    Future<List<SyncOverview>> snapshot() async {
      final rows = <SyncOverview>[];
      for (final profile in profiles) {
        final engine = scheduler.engineFor(profile.id);
        final local = counts[profile.id] ?? 0;
        final state = await dao.syncState(
          profile.id,
          EmailRepository.scopeOf(
            accountId: kAllMailboxes,
            type: MailType.receive,
            allReceive: true,
          ),
        );
        final remote = state?.remoteTotal ?? 0;
        rows.add(
          SyncOverview(
            profileId: profile.id,
            profileName: profile.displayName,
            syncing: engine?.isSyncing ?? false,
            stopped: engine?.isStopped ?? true,
            needsLogin: scheduler.needsLogin(profile.id),
            lastSuccessAt: engine?.lastSuccessAt,
            nextRunAt: engine?.nextRunAt,
            failCount: engine?.failCount ?? 0,
            lastError: engine?.lastError,
            localCount: local,
            // 0 = 还不知道（见 `SyncStates.remoteTotal`），别拿它去减。
            unsynced: remote <= 0 ? null : (remote - local).clamp(0, remote),
          ),
        );
      }
      return rows;
    }

    yield await snapshot();

    final signals = StreamController<void>();
    final subs = <StreamSubscription<Object?>>[
      dao.watchReceiveCountByProfile().listen((value) {
        counts = value;
        signals.add(null);
      }),
      scheduler.pulses.listen((_) => signals.add(null)),
    ];
    ref.onDispose(() {
      for (final sub in subs) {
        unawaited(sub.cancel());
      }
      unawaited(signals.close());
    });

    await for (final _ in signals.stream) {
      yield await snapshot();
    }
  },
  name: 'syncOverview',
);

/// 「新邮件」的 UI 侧订阅点。
///
/// 页面用 `ref.listen(newMailProvider, ...)` 弹 SnackBar；通知服务（M5）
/// 直接订阅 `newMailBusProvider`，两者互不打扰。
final StreamProvider<({String profileId, List<MailRow> mails})> newMailProvider =
    StreamProvider<({String profileId, List<MailRow> mails})>(
  (ref) => ref
      .watch(newMailBusProvider)
      .stream
      .map((e) => (profileId: e.profileId, mails: e.mails)),
  name: 'newMail',
);

bool get _isDesktop {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}

/// 未读角标的显示口径：某实例第一次同步还没跑完时不要显示一个错误的 0。
extension UnreadDisplayX on AsyncValue<Map<String, int>> {
  /// true 表示「还不知道」，UI 该显示同步中而不是数字。
  bool get isUnreadUnknown => !hasValue;
}

/// 列表里该显示哪个未读标记（含发件方向的语义修正）。
bool showsUnreadBadge(MailRow row) =>
    row.isUnread && row.type == MailType.receive;

/// 主屏「发件箱」入口的角标：还躺在本地队列里等着被送出去的信。
///
/// 口径与 [outboxCountProvider] **刻意一致**（含 `failed` / `unknown`）：
/// 那个数在设置页用了很久，两个入口说的是同一件事就不该有两个数。
final Provider<int> outboxPendingCountProvider = Provider<int>(
  (ref) => ref.watch(outboxCountProvider),
  name: 'outboxPendingCount',
);

/// 主屏「草稿箱」入口的角标。0 不显示（与发件箱相反，见 spec §2.1 那张表）。
final Provider<int> draftCountProvider = Provider<int>(
  (ref) => ref.watch(draftsProvider(null)).value?.length ?? 0,
  name: 'draftCount',
);

/// 冷启动补一次「权限派生」的能力闸。
///
/// 为什么需要它：`CapabilityRepository.probe()` 只在登录时跑一次，而
/// `hasAccountDelete` / `hasAccountRename` 的 UI 判据是
/// `== ProbeState.available` —— 一个已登录用户**冷启动后永远看不到删 /
/// 改名**（`unknown` 直接隐藏，见 `instance_capabilities.dart` 的 getter）。
/// `UserInfo` 又不落库，所以除了重新登录，没有第二条路能拿到权限 ——
/// 除非这里补一次：只打 `/my/loginUserInfo`（一个请求），不重跑整轮 `probe()`。
///
/// **先 warmUp**：冷启动时 runtime 是 `registry.ensure` 刚建出来的，内存里
/// 还没有 token（它在钥匙串里），而 `hasToken` / `readCached` 只看内存 ——
/// 不预热就发请求会**不带 Authorization**，服务端回 401，于是这条路会凭空
/// 把一个好好的登录态标成「需重登」。`SyncScheduler._ensureEngineFor` 里有
/// 同样的一道闸（`!runtime.hasToken → 不建 engine`），这里照抄它的语义。
///
/// 失败**不抛**（与 `probeInBackground` 同一契约）：冷启动时断网很正常，
/// 那只是「这一轮没探到」，下次运行再来。
void probePermsInBackground(
  CapabilityRepository caps,
  ProfileRuntime? runtime,
) {
  if (runtime == null || runtime.isDisposed) return;
  unawaited(() async {
    try {
      if (!runtime.hasToken) await runtime.warmUp();
      if (runtime.isDisposed || !runtime.hasToken) return;
      final user = await runtime.myApi.loginUserInfo();
      if (runtime.isDisposed) return;
      await caps.applyPerms(runtime.profileId, user);
    } catch (e) {
      // 与 `probeInBackground` 同一契约：探测失败不是错误。
      // 注意：token 已废时这次会拿到 401，而那已经由
      // `RuntimeRegistry._onAuthExpired` 走完四步收尾（取消在途、删 token、
      // 置内存标记、**落库 `profiles.needs_login = 1`**）—— 这里只需要
      // 安静地记一笔，别再重复处理。
      debugPrint('权限补探失败（可能 token 已失效，走既有 401 链路）：$e');
    }
  }());
}

// ---------------------------------------------------------------- 邮件级同步

/// 一个实例此刻在飞的邮件（面板的「正在同步」）。
///
/// **没有 engine 的实例给空集**，而不是给它造一个空转的 `ValueNotifier`：
/// `SyncScheduler.inFlightOf` 在没有 engine 时返回 null（它刻意不返回空
/// notifier），硬造一个的话每次调用都是**新对象**，`watch` 它会无限重建。
///
/// **已知的小毛病**：engine 被换掉时（重登、换服务器）这个订阅会留在旧
/// engine 上，而旧 engine 已经被 `stop()` 清空了在飞清单，于是这里会一直
/// 读到空集，直到这一页被重建。不影响正确性（那一页本来就会跟着重建），
/// 只是「重登之后不换页面」这一种情况下会少显示几行转圈。修它要给调度器
/// 加一层「引擎更替」的通知，不值得，记在 Task 12 的收尾清单里。
final inFlightByProfileProvider =
    StreamProvider.family<Set<MailRef>, String>((ref, profileId) {
  final engine = ref.watch(syncSchedulerProvider).engineFor(profileId);
  if (engine == null) {
    return Stream<Set<MailRef>>.value(const <MailRef>{});
  }
  return engine.inFlightStream;
}, name: 'inFlightByProfile');

/// 一个实例「还没同步完」的邮件（待同步 + 正在同步），新的在前。
///
/// 两个来源：
/// - **待同步**：`watchMissingBody`（缺正文）与 `watchMissingAttachments`
///   （缺附件）两批，按邮件去重 —— 两个都缺的信会同时出现在两条流里；
/// - **正在同步**：[inFlightByProfileProvider]。
///
/// 为什么只出「阶段」而不出「附件还差几个」：附件计数是**另一条异步查询**
/// （`watchAttachmentStats`），而这个 provider 的构造是同步的。硬塞进来要么
/// 手写一整套 `StreamController`，要么把计数搬进 `watchMissingAttachments`
/// 的 SQL（那会让它从「邮件列表」变成「邮件 + 计数」，两个用途就黏住了）。
/// 所以计数单独走 [syncAttachmentStatsProvider]，由界面拼。
///
/// 写法照抄同文件里的 `syncOverviewProvider`：一个 `StreamController<void>`
/// 触发 + 一个 `ref.onDispose`/`finally` 收摊。
final syncPendingProvider =
    StreamProvider.family<List<SyncItem>, String>((ref, profileId) async* {
  final dao = ref.watch(databaseProvider).mailDao;

  var missingBody = const <MailRow>[];
  var missingAtt = const <MailRow>[];
  var inFlight = const <MailRef>{};

  List<SyncItem> snapshot() {
    // 按 MailRef 去重，保序：正文那批在前 —— 它的排序口径
    // （createTime desc）与列表页一致，用户看得见的最上面那几行先出现。
    // `LinkedHashMap` 的插入序就是这里要的顺序（Dart 的 map 字面量也是）。
    final byRef = <MailRef, MailRow>{};
    for (final row in <MailRow>[...missingBody, ...missingAtt]) {
      byRef[MailRef(profileId: row.profileId, emailId: row.emailId)] = row;
    }
    return <SyncItem>[
      for (final entry in byRef.entries)
        SyncItem(
          row: entry.value,
          stage: syncStageOf(
            row: entry.value,
            // 计数不在这里 —— 见本 provider 的注释。
            attachmentTotal: 0,
            attachmentMissing: 0,
            inFlight: inFlight.contains(entry.key),
          ),
          attachmentTotal: 0,
          attachmentMissing: 0,
        ),
    ];
  }

  yield snapshot();

  final signals = StreamController<void>();
  final subs = <StreamSubscription<Object?>>[
    dao.watchMissingBody(profileId).listen((value) {
      missingBody = value;
      signals.add(null);
    }),
    dao.watchMissingAttachments(profileId).listen((value) {
      missingAtt = value;
      signals.add(null);
    }),
  ];

  // engine 的在飞清单变化 —— 它只改「哪几行在转圈」，不改清单的**成员**
  // （成员由上面两条 drift 流决定），所以这里只给一个信号。
  //
  // 用 `ref.listen`（而不是把 `ref.watch` 的值塞进那个 `List<...>` 里）：
  // 后者需要在这一段里同步拿到一个流再往里挂订阅，而 `ref.watch` 在
  // `StreamProvider` 上给的是 `AsyncValue`，写出来是三层嵌套的
  // `when` —— `ref.listen` 是同一个东西的直白写法（它本来就是「值变了叫我」）。
  ref.listen<AsyncValue<Set<MailRef>>>(
    inFlightByProfileProvider(profileId),
    (previous, next) {
      inFlight = next.value ?? const <MailRef>{};
      if (!signals.isClosed) signals.add(null);
    },
    fireImmediately: true,
  );

  try {
    await for (final _ in signals.stream) {
      yield snapshot();
    }
  } finally {
    for (final sub in subs) {
      unawaited(sub.cancel());
    }
    await signals.close();
  }
}, name: 'syncPending');

/// 一批邮件的附件统计（总数 / 未下载数）。
///
/// 单独一条 family（`(profileId, ids)`）：一行要显示「3 个附件，还差 2 个」，
/// 而 [syncPendingProvider] 只给得出邮件。key 里的 `ids` 是**屏上那批行的
/// emailId**，所以列表变了 key 就变、自动重订阅。
final syncAttachmentStatsProvider = StreamProvider.family<
    Map<int, ({int total, int missing})>,
    ({String profileId, List<int> ids})>((ref, arg) {
  return ref
      .watch(databaseProvider)
      .mailDao
      .watchAttachmentStats(arg.profileId, arg.ids);
}, name: 'syncAttachmentStats');

/// 「已经同步好的」那一档（同步页的第二个 tab）。
///
/// 用 [MailDao.watchMailbox]（`accountId = kAllMailboxes` + `allReceive`）
/// 而不是新写一条 SQL：那正是列表页用的查询 —— 「这个实例全部邮箱的收信、
/// 按时间倒序」，与这一档要的完全一致。另写一条只会留下第二份会走散的排序
/// 与过滤口径。
///
/// `allReceive: true` 时 `accountId` 只是个兜底（`_mailboxPredicate` 走的是
/// 「只要 profile_id 对上」那一支），给 [kAllMailboxes] 是对的 —— 它本来
/// 就表示「这个实例的全部邮箱」。
///
/// **它不判「附件下完没有」**：`hasFullBody` 只说明正文齐了。判附件要在
/// 每一行上再查一次 `attachments`（或者挂 N 条统计流），代价远大于收益
/// —— 少数「正文齐、附件还在下」的信会在这一档里露一次脸，可接受。
/// 待同步那一档（[syncPendingProvider]）会把它们列出来。
///
/// `limit` 放进 key 里（而不是写死）：它决定这一档要订阅多少行，
/// 换数量时 key 跟着变、自动重订阅。
final syncedMailsProvider =
    StreamProvider.family<List<MailRow>, ({String profileId, int limit})>(
  (ref, arg) => ref.watch(databaseProvider).mailDao.watchMailbox(
        arg.profileId,
        kAllMailboxes,
        type: MailType.receive,
        allReceive: true,
        limit: arg.limit,
      ),
  name: 'syncedMails',
);

/// 手动补一封 / 补一批。**同一个时刻只允许一件在跑**（避免连点把附件下载
/// 队列打爆），所以是一个 `Notifier<MailRef?>` 而不是一串并发 Future。
///
/// `state` 是「此刻正在补的那一封」—— 面板每一行据此显示转圈。批量的时候
/// 它逐封地变，所以「有东西在跑 = `state != null`」这条判据对单封与批量
/// 都成立，不需要再引入第二个标志位给界面看。
class ManualSyncController extends Notifier<MailRef?> {
  /// 批量正在跑。只用来挡住重入（界面看的是 `state`）。
  bool _batch = false;

  @override
  MailRef? build() => null;

  /// 补一封。已在补的那封不会再补一次（返回 null）。
  ///
  /// 批量正在进行时也返回 null：批量的每一封都会经由 [_run] 把 `state`
  /// 摆好，这时再插一封进去会把它抢掉，界面上正在转圈的那一行会突然换成
  /// 另一封，而前一封其实还在下。
  Future<ManualSyncResult?> sync(MailRef mail) async {
    if (_batch || state != null) return null;
    return _run(mail);
  }

  /// 「立即全部同步」：把「待同步」清单里的邮件**逐封补齐**（正文 + 附件）。
  ///
  /// 与实例卡片上那个「立即同步」**不是同一条路径**，这一点值得写清楚：
  /// 那个走 `SyncScheduler.refreshNow` → `SyncEngine.syncOnce`，只做增量
  /// 元数据 + 每轮 ≤20 封的正文回填，**从不下载附件**。用户在同步页上看到
  /// 一份「待同步」清单、按下「立即全部同步」，期望的显然是**这份清单变短**
  /// —— 而 `syncOnce` 做不到：它补的那一批由 `newestMissingBody(limit: 20)`
  /// 决定，与清单里是哪几行无关；附件它更是碰都不碰。这就是「点了同步却
  /// 没有同步这些邮件」的直接原因。
  ///
  /// [profileId] 为空表示全部实例。
  ///
  /// **没有可用 token 的实例整台跳过**（计入 [SyncBatchResult.skippedInstances]），
  /// 而不是逐封跑出一串「补了 0 封」—— 理由见循环里那处注释。
  Future<SyncBatchResult> syncAll({String? profileId}) async {
    if (_batch) return const SyncBatchResult();
    _batch = true;
    final dao = ref.read(databaseProvider).mailDao;
    final candidates = ref.read(syncCandidatesProvider);
    var mails = 0;
    var bodyFilled = 0;
    var attachments = 0;
    var skippedInstances = 0;
    var exhausted = false;
    try {
      for (final profile in candidates) {
        if (profileId != null && profile.id != profileId) continue;

        // **先判这台实例到底能不能跑**，再决定要不要取清单。
        //
        // 取清单之前判的意义：一台没登录态的实例，清单里可能有 200 封
        // 「缺正文」的信（本地就是这么存的），逐封跑完会得到 200 个
        // 「skipped」—— 用户面对的是一个转了好几分钟、最后说「没有待同步
        // 的邮件了」的按钮。而这台实例的真实状态是「收不了信」，那件事
        // 已经有别的地方在说（实例卡片上的「需重新登录」）。
        //
        // 判据与 `syncOneMail` 开头那道闸**同一处语义**：手里得有可用
        // 的 token。
        final live = ref.read(runtimeRegistryProvider).peek(profile.id);
        if (live == null || live.isDisposed || !live.hasToken) {
          skippedInstances++;
          continue;
        }

        // 取数放在循环里、每个实例各取一次：前一个实例补完的那几封不该
        // 再把后面实例的时间花掉，而这里每一个 await 之后清单都可能已经变了。
        final pending = await dao.pendingSyncRefs(profile.id);
        for (final mail in pending) {
          final result = await _run(mail);
          if (result == null) continue;
          mails++;
          if (result.bodyFilled) bodyFilled++;
          attachments += result.filled;
        }
        // 取数有上限（`pendingSyncRefs` 的 limit）。到顶说明还有没轮到的，
        // 说清楚，别让用户以为「同步完了但清单还是满的」。
        if (pending.length >= AppDefaults.syncBatchLimit) exhausted = true;
      }
    } finally {
      _batch = false;
    }
    return SyncBatchResult(
      mails: mails,
      bodyFilled: bodyFilled,
      attachments: attachments,
      maybeMore: exhausted,
      skippedInstances: skippedInstances,
    );
  }

  Future<ManualSyncResult?> _run(MailRef mail) async {
    state = mail;
    try {
      return await syncOneMail(ref, mail: mail);
    } finally {
      if (ref.mounted) state = null;
    }
  }
}

/// 批量补拉的收尾统计（界面据此给一句话）。
@immutable
class SyncBatchResult {
  const SyncBatchResult({
    this.mails = 0,
    this.bodyFilled = 0,
    this.attachments = 0,
    this.maybeMore = false,
    this.skippedInstances = 0,
  });

  /// 轮到了几封（含没补到东西的 —— 它也是「试过了」）。
  final int mails;

  /// 其中正文真的补上了的封数。
  final int bodyFilled;

  /// 一共下好了几个附件。
  final int attachments;

  /// 清单到上限了，可能还有没轮到的。
  final bool maybeMore;

  /// 有几台实例**根本没被碰**（没登录态 / 实例已删）。
  ///
  /// 这个数必须能传到那句话上：它是「按了按钮、转了一会儿、结果什么都没补」
  /// 这件事唯一说得通的原因，而用户看不到它的话，剩下的解释只有「同步坏了」。
  final int skippedInstances;

  /// 一封都没轮到（清单本来就是空的，或者整台实例被跳过了）。
  bool get empty => mails == 0;

  /// 一封都没补成，**而且**有实例是被跳过的 —— 那句话得说「为什么」。
  ///
  /// 与 [empty] 分开：`empty` 只说「这一批没轮到东西」，可能是「本来就没有
  /// 待同步的」（好消息），也可能是「这台实例收不了信」（坏消息）。
  /// 两者在同一句话里出现会把人往错的方向带。
  bool get blocked => mails == 0 && skippedInstances > 0;
}

final manualSyncProvider =
    NotifierProvider<ManualSyncController, MailRef?>(ManualSyncController.new,
        name: 'manualSync');
