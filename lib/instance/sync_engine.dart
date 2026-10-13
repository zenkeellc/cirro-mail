import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/models/enums.dart';
import '../core/config/app_defaults.dart';
import '../core/error/app_exception.dart';
import '../core/storage/prefs_store.dart';
import '../data/models/mail_ref.dart';
import '../data/models/mail_row.dart';
import '../data/models/mailbox_account.dart';
import '../data/models/profile.dart';
import '../data/repositories/account_repository.dart';
import '../data/repositories/capability_repository.dart';
import '../data/repositories/email_repository.dart';
import 'runtime_registry.dart';

/// **单个实例**的同步循环。
///
/// 与 [SyncScheduler] 的分工：engine 只负责「这个实例这一轮要拉什么、什么时候
/// 该重试」，调度（谁先谁后、并发几个）全在 scheduler。
///
/// 四条状态机规则：
/// - **401 → 停**。该实例的循环直接停到用户重登为止（对齐 Web 端
///   `autoRefresh = 0` 时干脆不轮询的做法）。继续打只会一直吃 401。
/// - **退避**：网络类失败 3s → 6s → 12s → … 封顶 60s（[AppDefaults]）。
///   业务错误（403/501）不退避太久 —— 那是配置问题，不是抖动。
/// - **串行**：同一个 engine 同时只有一个 sync 在跑（[_inFlight]）。
/// - **一个间隔**：所有实例都用 [PrefsStore.pollInterval]（用户在设置页调的
///   那个数）。以前有「活跃 30s / 空闲 10min」两档，[setActive] 就是那时留下
///   的开关 —— 现在它只在**用户切过来 / 从后台恢复**时把排期拨到现在
///   （「切过来马上拉一轮」仍然是想要的行为），不再改间隔。
class SyncEngine {
  SyncEngine({
    required this.profile,
    required this.registry,
    required this.emails,
    required this.accounts,
    required this.capabilities,
    required this.prefs,
    required this.onNewMail,
  });

  final Profile profile;
  final RuntimeRegistry registry;
  final EmailRepository emails;
  final AccountRepository accounts;
  final CapabilityRepository capabilities;
  final PrefsStore prefs;

  /// 新邮件回调（通知与「N 封新邮件」提示用）。在**写库之后**调用。
  final void Function(String profileId, List<MailRow> fresh) onNewMail;

  CancelToken? _inFlight;
  bool _syncing = false;
  bool _stopped = true;
  bool _active = false;

  int _failCount = 0;
  String? _lastError;
  DateTime? _lastSuccessAt;
  DateTime? _nextRunAt;

  bool get isSyncing => _syncing;
  bool get isStopped => _stopped;
  bool get isActive => _active;
  int get failCount => _failCount;
  String? get lastError => _lastError;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  DateTime? get nextRunAt => _nextRunAt;

  /// 此刻正在补拉正文 / 附件的邮件（面板的「正在同步」就是它）。
  ///
  /// **内存态、不落库**：它是「现在这一刻」的事实，冷启动时没有意义 ——
  /// 上次进程被杀时在飞的那几封，重启后仍然是「待同步」，会被自动队列重新
  /// 捡起来。落库只会留下一堆永远解不开的假「正在同步」。
  Set<MailRef> get inFlight => _inFlightMails.value;

  final ValueNotifier<Set<MailRef>> _inFlightMails =
      ValueNotifier<Set<MailRef>>(const <MailRef>{});

  /// 在飞清单的流：先给当前值，之后每次变化推一次。
  ///
  /// `ValueNotifier` 没有 `asStream`（它只有 `addListener`），所以这里自己
  /// 搭一个：订阅者（provider）取消订阅时 `finally` 里把监听摘掉 ——
  /// 不摘的话，被丢掉的那个 engine 还会继续往一个没人听的 controller 里推。
  Stream<Set<MailRef>> get inFlightStream async* {
    yield _inFlightMails.value;
    final controller = StreamController<Set<MailRef>>();
    void listener() => controller.add(_inFlightMails.value);
    _inFlightMails.addListener(listener);
    try {
      yield* controller.stream;
    } finally {
      _inFlightMails.removeListener(listener);
      await controller.close();
    }
  }

  /// 合并一批在飞的邮件。空列表表示「这一批结束了」。
  ///
  /// 合并而不是覆盖：一轮 `syncOnce` 里正文补拉与发件方向是**先后**两段，
  /// 而手动补一封（`syncOneMail`）可能与自动那一轮重叠。覆盖的话，手动补的
  /// 那一封会把手动之外的行擦掉。
  void _mergeInFlight(List<MailRef> refs) {
    if (refs.isEmpty) {
      // 空集 = 「这一批结束了」，撤掉本 engine 在所有批次里的痕迹。
      // 用「全部清空」而不是「减去 refs」：调用方只能告诉我们「我这批完了」，
      // 而减一个空集是空操作。
      _inFlightMails.value = const <MailRef>{};
      return;
    }
    _inFlightMails.value = <MailRef>{..._inFlightMails.value, ...refs};
  }

  /// 现在该不该跑这一轮。
  bool get isDue {
    if (_stopped) return false;
    if (_syncing) return false;
    // 需要重登的实例不自动跑 —— 用户重登后由 resume 重新开始。
    if (registry.needsLoginMessage(profile.id) != null) return false;
    final next = _nextRunAt;
    if (next == null) return true;
    return !DateTime.now().toUtc().isBefore(next);
  }

  /// 当前生效的间隔：用户设的那个数，失败时按退避拉长。
  ///
  /// 退避本身是秒级的（3s 起、封顶 60s），而用户能选的最短间隔是 1 分钟，
  /// 所以正常情况下这里返回的就是用户设的那一档 —— 取较大值是为了间隔被
  /// 调到 1 分钟以内时（比如测试直接塞 prefs）也说得通。
  Duration get currentInterval {
    final base = prefs.pollInterval;
    if (_failCount == 0) return base;
    var backoff = AppDefaults.pollBackoffStart;
    for (var i = 1; i < _failCount; i++) {
      backoff *= 2;
      if (backoff >= AppDefaults.pollBackoffMax) {
        backoff = AppDefaults.pollBackoffMax;
        break;
      }
    }
    return backoff > base ? backoff : base;
  }

  void start() {
    // 先记下「原来是不是停着的」，**再**把标志位翻过来。
    //
    // 原来这两句是反的（先 `_stopped = false`、再 `if (_stopped)`），于是一个
    // 恒为假的判断：从停止态恢复时**永远**不会把排期拨到现在，`start()` 的
    // 全部意图（下面那段注释）就此落空。它一直没炸是因为 `_stopped` 为真时
    // `_scheduleNext` 会把 `_nextRunAt` 置成 null，而 `isDue` 对 null 返回
    // true —— 也就是说「立刻跑」是**间接**成立的。但这条路径很脆：哪天给
    // `_scheduleNext` 加一条「停止时也记个未来的时间」，这里就会变成
    // 「按了立即同步却要等一个完整间隔」，而且不会有测试红。
    final wasStopped = _stopped;
    _stopped = false;
    // 只在**真的被停过**之后才把下次运行时间拉到现在。
    //
    // 以前这里是无条件 `_nextRunAt = now`，而它有个很隐蔽的后果：
    // `SyncController.build` 会因为 `profiles` 表的任何写入而重算
    // （`SyncEngine` 每轮成功都会写 `lastSyncAt`，那条流一转，build 就跟着
    // 重跑），重跑里那次 `scheduler.syncProfiles(...)` → `start(...)` 于是
    // 把每个 engine 的排期又推到现在 —— 与**仍在飞的那一轮**交错。表现就是
    // 同步几乎不停、顶栏那个图标一直转圈，而退避/间隔形同虚设。
    //
    // 对已经在跑的 engine 重复 start 本来就没有语义（它已经在被调度了），
    // 所以这里只在从停止态恢复时重置。
    if (wasStopped) _nextRunAt = DateTime.now().toUtc();
  }

  void stop() {
    _stopped = true;
    _inFlight?.cancel('engine stopped');
    _inFlight = null;
    // 停下来了，就不该再有「正在同步」的行 —— 面板上留着几行永远转圈的
    // 转圈，是这一整套里最难查的一种坏。`backfillBodies` 的 `finally`
    // 也会撤（取消会走它的异常路径），这里是第二道保险。
    _inFlightMails.value = const <MailRef>{};
  }

  /// 用户切到这个实例（或从后台恢复）—— 立即拉一轮，不等间隔。
  ///
  /// 间隔已经不分档了，所以这里剩下的唯一作用是「拨快这一台」：切过来就
  /// 马上拉，而不是等用户可能已经等过的那一整个间隔。`_active` 只记「用户
  /// 现在看着哪一台」，不再参与间隔计算。
  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    if (active) {
      _nextRunAt = DateTime.now().toUtc();
    } else {
      _scheduleNext();
    }
  }

  /// 用户手动「立即同步」。
  void requestNow() {
    _nextRunAt = DateTime.now().toUtc();
    _failCount = 0;
    _lastError = null;
  }

  /// 跑一轮。
  ///
  /// **不抛异常** —— 所有失败都记进状态，由 UI 与诊断页展示。
  /// 返回本轮写入的新邮件（可能是空列表）。
  Future<List<MailRow>> syncOnce({bool includeSent = false}) async {
    if (_syncing) return const <MailRow>[];
    final runtime = registry.peek(profile.id);
    if (runtime == null || runtime.isDisposed) return const <MailRow>[];
    if (!runtime.hasToken) {
      _lastError = '未登录';
      _scheduleNext();
      return const <MailRow>[];
    }

    _syncing = true;
    final cancel = CancelToken();
    _inFlight = cancel;
    final fresh = <MailRow>[];

    try {
      // 确保 token 在缓存里 —— 它是同步读的，没预热过首个请求会 401。
      await runtime.warmUp();

      // 邮箱列表先刷一次（新装的实例、或用户在 Web 端加了邮箱）。
      // 失败不影响收信：降级到本地已有的邮箱集合。
      final mailboxes = await _mailboxes();

      if (mailboxes.isEmpty) {
        _failCount = 0;
        _lastSuccessAt = DateTime.now().toUtc();
        _scheduleNext();
        return const <MailRow>[];
      }

      // 老行归位（`account_id = 0` → 按投递地址反查）。
      //
      // 放在这里而不是只靠 `_persist`：那个函数在**这一页没有新邮件**时
      // 会提前返回（`page.list.isEmpty` 就直接 return），于是「本地有一批
      // 0 归属的老行、而服务端恰好没有新信」这种最常见的情形永远修不到 ——
      // 用户看到的就是「切到某个邮箱，列表空的」，明明信就躺在库里。
      // 这个调用幂等且很便宜（一次按 `profileId` 的查询，修完就恒为空）。
      await emails.repairOrphanedAccounts(profile.id);

      // 收件：合并视图（一个请求覆盖所有邮箱）优先，比逐个邮箱轮询省得多。
      fresh.addAll(await _syncScope(
        accountId: mailboxes.primaryOrNull?.accountId ?? 0,
        type: MailType.receive,
        allReceive: true,
        cancelToken: cancel,
      ));

      // 正文补拉：增量同步只拿得到摘要（`/email/latest` 走 brief 列），
      // 列表里的灰点要靠这一趟才会消失。放在增量之后、`includeSent` 之前 ——
      // 它是**锦上添花**，不该拖住更重要的发件方向那一轮。
      //
      // 失败静默：补正文失败不影响增量（`backfillBodies` 内部已经吞掉异常）。
      await emails.backfillBodies(
        profile: profile,
        accountId: mailboxes.primaryOrNull?.accountId ?? 0,
        cancelToken: cancel,
        onInFlight: _mergeInFlight,
      );

      if (includeSent) {
        // 发件方向只在用户打开「已发送」时才轮 —— `/email/latest` 只有收件，
        // 走列表首页比对，成本更高。
        fresh.addAll(await _syncScope(
          accountId: mailboxes.primaryOrNull?.accountId ?? 0,
          type: MailType.send,
          allReceive: true,
          cancelToken: cancel,
        ));
      }

      _failCount = 0;
      _lastError = null;
      final now = DateTime.now().toUtc();
      _lastSuccessAt = now;
      // 落一次「上次成功」，供设置页与诊断页展示。
      //
      // 改之前 `setLastSyncAt` **一个调用者都没有**，`profiles.last_sync_at`
      // 永远是 NULL —— 设置页那句「正在同步」其实是这个 null 的兜底文案，
      // 而不是「真的在同步」，用户看到的就是「明明没动，却一直显示正在同步」。
      //
      // 失败只记日志：这是展示用的旁路，写不进去不该影响这一轮同步的结果。
      try {
        await emails.profiles.setLastSyncAt(profile.id, now);
      } catch (e) {
        debugPrint('SyncEngine: 写 lastSyncAt 失败（${profile.id}）：$e');
      }
      // 回调在**写库之后**发生，所以订阅者拿到的行已经是本地合并过的最终形态。
      if (fresh.isNotEmpty) onNewMail(profile.id, fresh);
    } on AppException catch (e) {
      _handleFailure(e);
    } catch (e) {
      _handleFailure(NetworkException(detail: e.toString()));
    } finally {
      _syncing = false;
      _inFlight = null;
      _scheduleNext();
    }

    return fresh;
  }

  Future<List<MailboxAccount>> _mailboxes() async {
    final local = await accounts.of(profile.id);
    try {
      return await accounts.refresh(profile);
    } on AppException {
      // 降级：用本地已有的邮箱继续收信，别让一次邮箱列表失败打断同步。
      return local;
    }
  }

  Future<List<MailRow>> _syncScope({
    required int accountId,
    required int type,
    required bool allReceive,
    required CancelToken cancelToken,
  }) async {
    final before = await _newestId(accountId, type, allReceive);
    await emails.syncMailbox(
      profile: profile,
      accountId: accountId,
      type: type,
      allReceive: allReceive,
      cancelToken: cancelToken,
    );
    return _freshSince(before, accountId, type, allReceive);
  }

  Future<int> _newestId(int accountId, int type, bool allReceive) =>
      emails.db.mailDao.newestEmailIdOf(
        profile.id,
        accountId,
        type: type,
        allReceive: allReceive,
      );

  /// 本轮新出现的行（`emailId > before`）。写库之后回查一次，
  /// 比让 repository 把行再传回来简单，也保证拿到的是**合并后**的本地行。
  Future<List<MailRow>> _freshSince(
    int before,
    int accountId,
    int type,
    bool allReceive,
  ) async {
    final rows = await emails.db.mailDao.pageOfMailbox(
      profile.id,
      accountId,
      type: type,
      allReceive: allReceive,
      size: 50,
    );
    return rows.where((r) => r.emailId > before).toList(growable: false);
  }

  void _handleFailure(AppException e) {
    if (e is AuthExpiredException) {
      // 401 已经在拦截器里广播（Registry 标了 needsLogin）→ 停循环。
      _stopped = true;
      _lastError = e.userMessage;
      return;
    }
    _failCount++;
    _lastError = e.userMessage;
  }

  void _scheduleNext() {
    if (_stopped) {
      _nextRunAt = null;
      return;
    }
    _nextRunAt = DateTime.now().toUtc().add(currentInterval);
  }

  /// 诊断页用的一行摘要。
  String describe() {
    final parts = <String>[
      if (_stopped) '已停止' else if (_syncing) '同步中' else '等待中',
      '间隔 ${currentInterval.inSeconds}s',
      if (_failCount > 0) '连续失败 $_failCount 次',
      if (_lastError != null) '上次错误：$_lastError',
      if (_lastSuccessAt != null)
        '上次成功：${_lastSuccessAt!.toLocal().toIso8601String().substring(11, 19)}',
    ];
    return parts.join(' · ');
  }

  @visibleForTesting
  void debugSetFailCount(int value) => _failCount = value;
}
