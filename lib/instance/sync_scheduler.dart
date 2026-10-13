import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/profile.dart';
import '../data/repositories/account_repository.dart';
import '../data/repositories/capability_repository.dart';
import '../data/repositories/email_repository.dart';
import '../data/repositories/send_repository.dart';
import '../core/db/database.dart';
import '../core/notify/new_mail_bus.dart';
import '../core/storage/prefs_store.dart';
import '../core/util/diag_log.dart';
import '../data/models/mail_row.dart';
import 'runtime_registry.dart';
import 'sync_engine.dart';

/// 一个**串行**的多实例调度器。
///
/// 为什么串行：N 个实例同时打请求会把手机的射频与电池打爆，而且多实例
/// 往往指向同一个/相邻的服务器。串行化之后，一轮里最多只有一个请求在飞，
/// 每个实例按同一个间隔（用户在设置页调的那个数）各自计时，失败各自退避。
///
/// 心跳：一个 1 秒的 [Timer.periodic]，只做「哪个 engine 到期了」的判定，
/// 本身不发请求。改间隔不需要重启 timer（[currentInterval] 是即时读的）。
class SyncScheduler {
  SyncScheduler({
    required this.db,
    required this.registry,
    required this.emails,
    required this.accounts,
    required this.capabilities,
    required this.prefs,
    this.bus,
    this.sends,
    this.onNewMail,
    this.onSessionRecovered,
  });

  final AppDatabase db;
  final RuntimeRegistry registry;
  final EmailRepository emails;
  final AccountRepository accounts;
  final CapabilityRepository capabilities;
  final PrefsStore prefs;

  /// 发件箱。**挂在调度器上而不是各写各的定时器**：发信与收信抢的是同一条
  /// 网络与同一个服务端，两边各跑一套时钟就会出现「正在发 15MB 附件的同时
  /// 又发起一轮收信」，在手机上既费电又容易双双超时。
  ///
  /// 可空：测试与「只收不发」的场景不需要它。
  final SendRepository? sends;

  /// 新邮件总线（通知服务订阅它）。为 null 时只回调 [onNewMail]。
  final NewMailBus? bus;

  /// 新邮件回调（测试与 UI 提示用）。在 engine 写库之后收到。
  final void Function(String profileId, List<MailRow> fresh)? onNewMail;

  /// 把「需要重登」这个**落库的**标记清掉（401 翻案时用）。
  ///
  /// 与 [RuntimeRegistry.onAuthExpired] 对称：那边负责写 `needs_login = 1`，
  /// 这边负责撤销它。做成回调而不是在这里直接持有 `ProfileRepository`，
  /// 理由与 registry 里那条一样 —— 调度器不该反向依赖仓储层。
  final Future<void> Function(String profileId)? onSessionRecovered;

  /// 心跳的慢活回调：每 [slowEveryTicks] 拍（≈20 秒）调一次。
  ///
  /// **为什么是个可变字段而不是构造参数**：要用它的是 `ReminderTicker`
  /// （在 `lib/features/notifications/`），而本文件**一个 `features/` 的
  /// import 都没有** —— 它是 `lib/instance/` 的东西，只认识仓储层。
  /// 做成构造参数就得在 `core_providers.dart` 里 import feature 层，
  /// 那是把依赖方向掰反了。改成让 `NotificationHost`（本来就是干接线的）
  /// 在挂载时赋值，两边都不用知道对方。
  ///
  /// 不赋值时为 null，心跳照跳，只是没有慢活。
  void Function()? onSlowTick;

  /// 慢活每多少拍一次。20 拍 × 1 秒 ≈ 20 秒。
  static const int slowEveryTicks = 20;
  int _slowTicks = 0;

  final Map<String, SyncEngine> _engines = <String, SyncEngine>{};

  /// 最近一次 [start] 拿到的 profile 列表。
  ///
  /// 「立即同步」需要在**没有** engine 的时候也能建一个（否则那个按钮点了
  /// 什么都不发生，用户只会以为同步坏了）。`SyncEngine` 的构造函数要
  /// 完整的 `Profile`，而 `refreshNow` 只拿到 profileId，所以留一份列表 ——
  /// 它本来就是调度器的作用域（谁在被调度）。
  List<Profile> _lastProfiles = const <Profile>[];

  Timer? _ticker;
  bool _running = false;
  bool _ticking = false;

  /// 这一轮要不要连「已发送」一起轮询。
  ///
  /// 它是**全局**开关而不是每个实例一个：`/email/latest` 只覆盖收件，
  /// 发件方向得靠「列表首页比对游标」，贵的多。只有用户真的打开过
  /// 「已发送」文件夹时才值得开。
  bool _includeSent = false;

  /// 当前有没有一轮同步在跑（UI 的「同步中」指示用）。
  final ValueNotifier<bool> busy = ValueNotifier<bool>(false);

  /// 同步状态有任何变化就发一个信号（同步状态面板据此重算）。
  ///
  /// 一轮同步的**开始与结束各发一次**：面板要显示的既有「正在同步」这个
  /// 瞬时态，也有「已同步 N 封 / 上次成功 HH:mm:ss」这种结束后才变的数字。
  /// 只在结束时发的话，一轮跑 30 秒的过程中面板会一直说「等待中」。
  ///
  /// 用广播流而不是 `ValueNotifier`：面板可能同时开着两个入口（宽屏侧栏
  /// 与窄屏 AppBar 上的按钮），`ValueNotifier` 的 listener 列表会被
  /// `ref.watch` 的重复订阅搞得很难收拾。
  Stream<int> get pulses => _pulses.stream;

  final StreamController<int> _pulses = StreamController<int>.broadcast();
  int _pulseSeq = 0;

  void _pulse() {
    if (!_pulses.isClosed) _pulses.add(++_pulseSeq);
  }

  /// 某个实例的引擎（面板读运行态用）。没有 engine 时返回 null。
  SyncEngine? engineFor(String profileId) => _engines[profileId];

  /// 这个实例是不是因为 token 失效而停了（面板要显示「需重新登录」）。
  bool needsLogin(String profileId) =>
      registry.needsLoginMessage(profileId) != null;

  /// 实例被标记「需重新登录」时通知 UI（与 `RuntimeRegistry.invalidated` 同源）。
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  bool get isRunning => _running;

  /// 当前活跃（用户正看着）的实例。
  ///
  /// 间隔已经不分档，这个 id 现在只剩两件事：**调度优先级**（同时到期时
  /// 先拉用户正看着的那台）与「切过来立刻拉一轮」。以前它还决定用哪一档
  /// 间隔，所以名字里的「活跃」别再往间隔上联想。
  String? _activeProfileId;

  SyncEngine engineOf(String profileId) => _engines.putIfAbsent(
        profileId,
        () => throw StateError('engine 未注册：$profileId（先调用 ensure）'),
      );

  SyncEngine? peekEngine(String profileId) => _engines[profileId];

  /// 为一批 profile 建立 engine 并开始调度。
  ///
  /// 已存在的 engine 会被复用（保持它的退避状态与上次成功时间）——
  /// 每次重启 App 都重置退避会让「服务端挂了」变成「每秒重试」。
  ///
  /// **`needsLogin` 的实例不再一律跳过**（这里是 1～3 号 bug 的共同根因）：
  /// 那个标记说的是「上一次某个请求吃过 401」，而不是「token 一定废了」。
  /// 冷启动时它从库里读出来（`profiles.needs_login = 1` 是落库的），此时
  /// 钥匙串里完全可能躺着一个还有效的 token，刚才那次 `warmUp` 不就已经
  /// 把它捞回缓存了吗。所以判据改成**看结果**：预热之后手里有 token 就
  /// 照常建 engine 跑一轮；真有 token 却还是 401，`SyncEngine` 会自己
  /// 停下并在界面上报「需要重新登录」—— 那才是唯一有资格说这句话的时刻。
  Future<void> start(
    Iterable<Profile> profiles, {
    String? activeProfileId,
    bool includeSent = false,
  }) async {
    final list = profiles.toList(growable: false);
    _lastProfiles = list;
    _activeProfileId = activeProfileId;
    _includeSent = includeSent;
    for (final profile in list) {
      final engine = await _ensureEngineFor(profile);
      if (engine == null) continue;
      engine.start();
      engine.setActive(profile.id == activeProfileId);
    }
    _tick();
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _running = true;
  }

  /// 让某个实例处于「有一个能跑的 engine」的状态；不满足条件时返回 null。
  ///
  /// **原来这里第一行是 `if (profile.userId <= 0) return null;`，已经删掉**
  /// —— 它看着像一道「没登录就别同步」的合理闸门，实际上同时是两件事的根因：
  ///
  /// - **新建的实例永远进不来**。`ProfileRepository.create()` 把 `userId`
  ///   留成 0，只有登录成功那一刻才由 `markLoggedIn` 写进去；而
  ///   `AuthRepository.login()` **第 3 步就把 token 存进钥匙串了**（必须，
  ///   见那边的注释），第 4 步 `loginUserInfo` 才回来。所以「token 已经在手、
  ///   userId 还没落库」是一段**真实存在**的状态 —— 那段状态里这个实例
  ///   明明能收信，却被这一行挡在调度之外，用户看到的是「加完了、
  ///   设置页里也在、就是不同步」。判「能不能收信」的依据是**手里有没有
  ///   可用的 token**，而那是下面这两条闸的事，不是 `userId` 的事。
  /// - **它和上面那个「需重登」的验活撞车**。`updateBaseUrl` 会把 `userId`
  ///   清成 0 并置 `needsLogin` —— 而那正是最需要跑一轮「验活」的实例
  ///   （用户刚把地址改对，token 却已经被删了/待重登）。
  ///
  /// 现在剩下的两条闸缺一不可，第 1 条是 1～3 号 bug 的直接根因：
  ///
  /// 1. **runtime 必须存在**。`SyncEngine.syncOnce` 开头就是
  ///    `registry.peek(profile.id)`，拿不到就直接返回空列表 —— 它不报错、
  ///    不记失败，只是**什么都不做**。而 UI isolate 里除了发信那条路以外
  ///    没有任何地方建过 runtime，于是「调度器在跑、诊断页显示等待中、
  ///    库里的邮件却永远不更新」。这一步顺带 `warmUp`，所以下面的
  ///    `hasToken` 才是可信的（它只看内存缓存）。
  /// 2. **token 必须可用**。没有 token 时不建 engine：它每一轮都会空转一次
  ///    「未登录」并且永远等不到用户重登（`_stopped` 是粘的）。用户重登后
  ///    `markLoggedIn` 改 `profiles` 流 → `SyncController` 重算 → 再走一遍这里。
  ///
  /// 第 3 条（「需要重登」这个标记要先验活）见 [RuntimeRegistry.probeSession]：
  /// 它只在**内存里**有这个标记时才会走到 —— 冷启动时那是空的，于是
  /// 「库里标着 needs_login、钥匙串里其实还有一个能用的 token」那种情况
  /// 由下面 `hasToken` 直接放行，真 401 了由 `SyncEngine` 停下并报出来。
  Future<SyncEngine?> _ensureEngineFor(Profile profile) async {
    final runtime = await registry.ensureReady(profile);
    if (runtime.isDisposed) return null;

    if (registry.needsLoginMessage(profile.id) != null) {
      switch (await registry.probeSession(profile)) {
        case SessionProbe.expired:
          // 确认废了：不建 engine，等用户重登。
          DiagLog.log('sync', '${profile.id} 的 token 确认失效，等用户重登');
          return null;
        case SessionProbe.unknown:
          // 验不出来（断网、服务端抖动）—— 既不改判也不推翻，保持现状。
          DiagLog.log('sync', '${profile.id} 的会话状态未知，跳过这一轮');
          return null;
        case SessionProbe.valid:
          // 虚惊一场：撤销标记得连库一起撤。光清内存是不够的 ——
          // 那个标记是落库的，不清库的话下次冷启动又会被排除在外。
          DiagLog.log('sync', '${profile.id} 的会话其实还有效，撤销「需重登」');
          registry.clearNeedsLogin(profile.id);
          final persist = onSessionRecovered;
          if (persist != null) unawaited(persist(profile.id));
      }
    }

    if (!runtime.hasToken) {
      DiagLog.log('sync', '跳过 ${profile.id}：没有可用的 token');
      return null;
    }

    return _engines.putIfAbsent(profile.id, () => _makeEngine(profile));
  }

  SyncEngine _makeEngine(Profile profile) => SyncEngine(
        profile: profile,
        registry: registry,
        emails: emails,
        accounts: accounts,
        capabilities: capabilities,
        prefs: prefs,
        onNewMail: (id, fresh) => _onNewMail(id, fresh),
      );

  /// 停止全部调度（App 退到后台、或用户关了通知与轮询）。
  void stop() {
    _ticker?.cancel();
    _ticker = null;
    for (final engine in _engines.values) {
      engine.stop();
    }
    _running = false;
  }

  /// 新增/移除实例后调用，让 engine 集合跟上。
  Future<void> syncProfiles(
    Iterable<Profile> profiles, {
    String? activeProfileId,
  }) async {
    final ids = profiles.map((p) => p.id).toSet();
    // 已消失的实例：停掉并丢弃它的 engine。
    for (final gone in _engines.keys.toList(growable: false)) {
      if (!ids.contains(gone)) {
        _engines.remove(gone)?.stop();
      }
    }
    _activeProfileId = activeProfileId;
    await start(profiles, activeProfileId: activeProfileId);
    // 用户切换实例时立即拉一次，不等一个完整间隔。
    final active = _activeProfileId;
    if (active != null) _engines[active]?.requestNow();
  }

  /// 用户切到某个实例（或从详情页返回列表）—— 标记优先级并立即同步一次。
  void setActiveProfile(String? profileId) {
    if (_activeProfileId == profileId) return;
    _activeProfileId = profileId;
    for (final entry in _engines.entries) {
      entry.value.setActive(entry.key == profileId);
    }
    if (profileId != null) _engines[profileId]?.requestNow();
  }

  /// 打开 / 离开「已发送」文件夹时调用 —— 决定要不要连发件方向一起轮询。
  void setIncludeSent(bool includeSent) {
    if (_includeSent == includeSent) return;
    _includeSent = includeSent;
    if (includeSent) {
      // 立刻补一次，用户不用等一个完整间隔才看到已发送的增量。
      unawaited(refreshNow());
    }
  }

  /// 用户手动触发（下拉刷新、设置页「立即同步」、同步面板每张卡上的那个按钮）。
  ///
  /// [profileId] 为空表示全部实例（聚合适图的下拉刷新）。
  ///
  /// **没有 engine 时现建一个**：这正是同步面板上「立即同步」曾经按了
  /// 毫无反应的原因 —— 那个按钮传的是 profileId，而 `_engines[id]` 为 null
  /// 时 `?.requestNow()` 是一个静默的空操作，连日志都没有一行。现在改成
  /// 按需补建（先预热 token，拿不到就老实说「还没登录」并返回 false）。
  ///
  /// 返回本轮是否真的跑了一个 engine；调用方据此决定要不要给用户一句
  /// 「没反应是因为什么」。
  Future<bool> refreshNow({String? profileId}) async {
    if (profileId != null) {
      final engine = _engines[profileId] ?? await _buildEngineNow(profileId);
      if (engine == null) return false;
      // **必须 start**：按需补建出来的 engine 还是 `_stopped` 状态，
      // 而 `isDue` 第一件事就是看 `_stopped` —— 只 `requestNow()` 的话
      // 这一轮根本不会被 `_tick` 挑中。对已经在跑的 engine 重复 start
      // 是无害的（只是把下次运行时间调到现在）。
      engine.start();
      engine.requestNow();
    } else if (_engines.isEmpty) {
      // 一个 engine 都没有（冷启动还没走到 `start`、或全部实例都处于
      // 需要重登）。至少把「当前还该被调度的实例」补上。
      await _ensureEngines();
      for (final engine in _engines.values) {
        engine.requestNow();
      }
      if (_engines.isEmpty) return false;
    } else {
      for (final engine in _engines.values) {
        engine.requestNow();
      }
    }
    await _tick();
    return true;
  }

  /// 给「该同步但现在没有 engine」的实例补建 engine（见 `refreshNow`）。
  Future<void> _ensureEngines() async {
    if (_lastProfiles.isEmpty) return;
    await start(_lastProfiles, activeProfileId: _activeProfileId);
  }

  /// 为一个实例现建 engine。拿不到可用的登录态就返回 null（不是错误：
  /// 用户还没登录完，或这个实例真的需要重登）。
  Future<SyncEngine?> _buildEngineNow(String profileId) async {
    Profile? profile;
    for (final candidate in _lastProfiles) {
      if (candidate.id == profileId) {
        profile = candidate;
        break;
      }
    }
    if (profile == null) return null;
    // 与 `start` 走同一条判据：建 runtime → 预热 → 验活「需要重登」标记
    // → 有 token 才建 engine。两处各写一份的话，迟早会出现
    // 「面板点得动、自动调度却不动」这种两边结论不一致的怪事。
    return _ensureEngineFor(profile);
  }

  /// 一轮判定：挑出**最早到期**的那个 engine 跑一次，然后返回。
  ///
  /// 刻意一次只跑一个（不是「所有到期的都跑」）—— 串行化的意义就在这里，
  /// 一秒一跳的心跳会让下一个到期的实例在下一跳被处理。
  Future<void> _tick() async {
    // 慢活：每 20 拍一次。**放在 `_ticking` 闸门之前、且不 await** ——
    // 一轮同步可能跑几秒，闸门会吃掉那几拍；计数器放在闸门之后的话，
    // 同步一直忙的时候提醒就一直不查。不 await 的理由前面说过：
    // 提醒晚半秒弹没关系，心跳被拖慢就有关系了。
    if (++_slowTicks >= slowEveryTicks) {
      _slowTicks = 0;
      onSlowTick?.call();
    }

    // 心跳是 1s 一跳，而一轮同步可能跑几秒。没有这个闸门的话，
    // 一次拉取期间会叠进好几个 _tick()（它们虽然都会因为 `isDue == false`
    // 而空转，但每次都要遍历一遍实例表）。
    if (_ticking) return;
    _ticking = true;
    try {
      await _runOne();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _runOne() async {
    if (_engines.isEmpty) return;

    SyncEngine? picked;
    for (final engine in _engines.values) {
      if (!engine.isDue) continue;
      // 活跃实例优先：用户正看着的那个应最先更新。
      if (picked == null) {
        picked = engine;
        continue;
      }
      final pickedActive = picked.profile.id == _activeProfileId;
      final engineActive = engine.profile.id == _activeProfileId;
      if (engineActive && !pickedActive) {
        picked = engine;
        continue;
      }
      if (engineActive == pickedActive &&
          (engine.nextRunAt ?? DateTime.now().toUtc())
              .isBefore(picked.nextRunAt ?? DateTime.now().toUtc())) {
        picked = engine;
      }
    }

    if (picked == null) return;
    busy.value = true;
    _pulse();
    try {
      // **必须 await**：调度器的核心约束就是「同一时刻最多一个同步在跑」，
      // 不 await 就等于把串行化丢掉了（dart 里 fire-and-forget 的
      // async 调用会立刻返回，下一跳会立刻再挑一个实例发请求）。
      await picked.syncOnce(includeSent: _includeSent);
    } catch (e) {
      // engine 自己吞掉所有异常并记状态；这里只是最后一道保险，
      // 保证一个实例的意外不会停掉整个调度器。
      debugPrint('SyncScheduler: ${picked.profile.id} 同步异常：$e');
    } finally {
      busy.value = false;
      _pulse();
    }
  }

  void _onNewMail(String profileId, List<MailRow> fresh) {
    onNewMail?.call(profileId, fresh);
    bus?.emit(profileId, fresh);
  }

  // ------------------------------------------------------------- 发件箱

  /// 发件箱里还有多少封要发（UI 角标）。
  ValueNotifier<int> get outboxPending => _outboxPending;

  final ValueNotifier<int> _outboxPending = ValueNotifier<int>(0);

  Timer? _outboxTicker;
  bool _flushing = false;

  /// 每 [interval] 试一次把发件箱送出去，并**立刻**先试一轮。
  ///
  /// 为什么要一个独立的慢时钟（而不是搭在 1 秒的心跳上）：发件箱多数时候是
  /// 空的，一秒一次地查库纯属浪费；而它也不能只等用户手动触发 ——
  /// 「断网时点发送 → 进发件箱 → 网络恢复自动发出去」是 M3 的验收条件。
  ///
  /// 断网时 [SendRepository.flush] 会把条目留在 `pending` 并因网络异常立即返回，
  /// 没有重试风暴的风险。
  void startOutbox({Duration interval = const Duration(seconds: 20)}) {
    _outboxTicker?.cancel();
    unawaited(_flushOutbox());
    _outboxTicker = Timer.periodic(interval, (_) => unawaited(_flushOutbox()));
  }

  void stopOutbox() {
    _outboxTicker?.cancel();
    _outboxTicker = null;
  }

  /// 现在就把发件箱送一遍（下拉刷新 / 设置页「立即重试」/ 网络恢复时调）。
  Future<void> flushOutbox() => _flushOutbox();

  Future<void> _flushOutbox() async {
    final sends = this.sends;
    if (sends == null || _flushing) return;
    _flushing = true;
    try {
      // 只发「已登录且有 engine」的实例：给一个 token 已失效的实例发货，
      // 每次都会拿到 401、被判成可重试、永远发不出去。
      final ids = _engines.keys.toList(growable: false);
      if (ids.isNotEmpty) await sends.flush(profileIds: ids);

      // 角标数的是「还没发出去的信」，不是「下次会被自动重试的信」：
      // 判死的（failed）和结果不明的（unknown）都还躺在发件箱里等用户处理，
      // 只数 pending 的话它们就彻底没有存在感了。
      final pending = await sends.attentionCount();
      if (!_disposed) _outboxPending.value = pending;
    } catch (e) {
      // `flush` 自己吞掉每一条的失败；能到这里说明是库或调度的问题。
      debugPrint('SyncScheduler: 发件箱刷新异常：$e');
    } finally {
      _flushing = false;
    }
  }

  /// 上次异常退出留下的「发送中」孤儿，交给 `SendRepository.recoverStuck`
  /// 在启动时一次性收拾 —— 调度器只负责把它跑起来。
  Future<void> recoverOutbox() async {
    try {
      await sends?.recoverStuck();
    } catch (e) {
      debugPrint('SyncScheduler: 复位发件箱异常：$e');
    }
    await _flushOutbox();
  }

  /// 诊断页用：每个实例一行的运行状态。
  List<({String profileId, String profileName, String status})> diagnostics() {
    return _engines.values
        .map((e) => (
              profileId: e.profile.id,
              profileName: e.profile.displayName,
              status: e.describe(),
            ))
        .toList(growable: false);
  }

  bool _disposed = false;

  Future<void> dispose() async {
    _disposed = true;
    stop();
    stopOutbox();
    _engines.clear();
    busy.dispose();
    lastError.dispose();
    _outboxPending.dispose();
    unawaited(_pulses.close());
  }
}
