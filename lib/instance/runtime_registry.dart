import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/error/app_exception.dart';
import '../core/network/auth_events.dart';
import '../core/storage/prefs_store.dart';
import '../core/storage/token_store.dart';
import '../core/util/diag_log.dart';
import '../data/models/profile.dart';
import 'profile_runtime.dart';

/// `profileId → ProfileRuntime`。
///
/// 全应用**唯一**持有 runtime 的地方。UI 永远不自己 `new` 一个 runtime ——
/// 那样会绕过「一个实例一条 Dio、一个实例一套退避」的约束。
///
/// 三件事由它负责：
/// 1. **懒建**：切到某个实例时才建它的 runtime（冷启动不会为 10 个实例
///    各建一条 Dio）；
/// 2. **重建**：`baseUrl` 变了要丢掉旧的 runtime（Dio 的 baseUrl 虽然可变，
///    但改一半会出现「部分请求打到老服务器」的竞态）；
/// 3. **401 的单一入口**：把 `AuthEvents` 的广播落到具体实例上，
///    只标这一个 profile 需要重登，**不动其他实例**。
class RuntimeRegistry {
  RuntimeRegistry({
    required this.authEvents,
    required this.tokens,
    required this.prefs,
    this.onAuthExpired,
    this.onSessionRecovered,
    this.enableLog = false,
    this.buildDownloadDio,
    this.buildApiDio,
  }) {
    _authSub = authEvents.stream.listen(_onAuthExpired);
  }

  final AuthEvents authEvents;
  final TokenStore tokens;
  final PrefsStore prefs;

  /// 401 落库的出口（把 `needsLogin` 写进 `profiles` 表）。
  ///
  /// 为什么不在这个类里直接写库：它只该管「运行时的实例句柄」，
  /// 一旦让它持有 `ProfileRepository`，删实例/建实例的路径就多出一条
  /// 从 runtime 反向影响库的边，很难说清谁先谁后。所以这里只留一个回调，
  /// 由 `core_providers` 把两边接起来。
  ///
  /// **这一步不能省**：内存里的 `_needsLoginMessages` 只活到进程结束，
  /// 而 `Profile.isLoggedIn` 才是 `router` 的 `redirect` 依据 —— 不落库的话，
  /// 坏 token 在杀掉重启之后又变回「已登录」，用户卡在一个每次请求都 401 的
  /// 收件箱里，还跳不回登录页。
  final void Function(String profileId)? onAuthExpired;

  /// 「401 之后复验发现其实是虚惊一场」的出口：把这台实例落库的
  /// `needs_login` 撤掉。
  ///
  /// 与 [onAuthExpired] 是一对。复验走 [probeSession]：token 没有 `exp`，
  /// 客户端验不了签名，唯一能问的地方就是服务端，所以**必须**有一次真请求
  /// 才能翻案；翻案成功之后只撤内存标记是不够的 —— 标记是落库的，
  /// 不撤库的话下次冷启动又会把用户挡在登录页外面。
  ///
  /// 返回值是 `Future`：调用方（401 复验）会 await 它，好让「复验结束」
  /// 这件事有一个确定的时刻，后台 isolate 里也才来得及在关库前写完。
  final Future<void> Function(String profileId)? onSessionRecovered;

  final bool enableLog;

  /// 建下载 Dio 的工厂。默认走真实的 `DioFactory.buildDownloadDio`；
  /// 测试里注入一个带假适配器的，才能在不发真请求的前提下验证
  /// 「对象不存在时（HTTP 200 + JSON 信封）不落盘」（见 `attachment_download_test`）。
  final Dio Function()? buildDownloadDio;

  /// 建**带鉴权**那条 Dio 的工厂。默认走 `ProfileRuntime.create` 里的
  /// `DioFactory.build`。测试里注入它是为了拿到「dio 真正发出去的字节」
  /// —— 发信链路上 `Content-Length` 与流式 body 必须一致，
  /// 这一点只有在适配器那一层才看得到。
  final Dio Function(Profile profile)? buildApiDio;

  final Map<String, ProfileRuntime> _runtimes = <String, ProfileRuntime>{};

  /// runtime 被丢弃（重建或删除）时通知上层，让 UI 里的 provider 失效。
  final StreamController<String> _invalidated =
      StreamController<String>.broadcast();

  Stream<String> get invalidated => _invalidated.stream;

  /// 需要重新登录的实例（UI 上标记红点）。由 401 与用户手动切服务产生。
  final Map<String, String> _needsLoginMessages = <String, String>{};

  String? needsLoginMessage(String profileId) => _needsLoginMessages[profileId];

  StreamSubscription<AuthExpiredEvent>? _authSub;

  /// 拿到某个实例的运行时。已存在且地址没变就直接返回。
  ///
  /// 注意**不会**自动 `warmUp` —— 调用方要发带鉴权的请求前得自己 await 一次，
  /// 或者用 [ensureReady]。
  ProfileRuntime ensure(Profile profile) {
    final existing = _runtimes[profile.id];
    if (existing != null && existing.baseUrl == profile.baseUrl) {
      DiagLog.log('registry', '复用 runtime ${profile.id} (${profile.baseUrl})');
      return existing;
    }
    if (existing != null) {
      // 换了服务器：旧 Dio 的 baseUrl 和 token 都不再适用。
      DiagLog.log(
        'registry',
        '地址变了，丢弃旧 runtime ${profile.id}：'
        '${existing.baseUrl} → ${profile.baseUrl}',
      );
      existing.dispose();
    }
    final created = ProfileRuntime.create(
      profile: profile,
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      enableLog: enableLog,
      apiDio: buildApiDio?.call(profile),
      downloadDio: buildDownloadDio?.call(),
    );
    _runtimes[profile.id] = created;
    DiagLog.log(
      'registry',
      '新建 runtime ${profile.id} (${profile.baseUrl}) '
      '当前共 ${_runtimes.length} 条',
    );
    return created;
  }

  /// 拿到运行时并把 token 读进缓存（发第一个请求前调用这个）。
  Future<ProfileRuntime> ensureReady(Profile profile) async {
    final runtime = ensure(profile);
    await runtime.warmUp();
    return runtime;
  }

  /// 只按 id 拿一个**已经建好**的运行时（UI 里已经同步拿不到 profile 时用）。
  ProfileRuntime? peek(String profileId) => _runtimes[profileId];

  /// 丢掉某个实例的运行时（删实例、登出时）。
  void discard(String profileId) {
    final runtime = _runtimes.remove(profileId);
    DiagLog.log(
      'registry',
      '丢弃 runtime $profileId（${runtime == null ? '本来就没有' : runtime.baseUrl}）'
      '，剩余 ${_runtimes.length} 条',
    );
    runtime?.dispose();
    _needsLoginMessages.remove(profileId);
    _probedAt.remove(profileId);
    _revalidating.remove(profileId);
    if (!_invalidated.isClosed) _invalidated.add(profileId);
  }

  /// 清掉「需要重登」标记（重新登录成功后）。
  void clearNeedsLogin(String profileId) {
    if (_needsLoginMessages.remove(profileId) != null) {
      if (!_invalidated.isClosed) _invalidated.add(profileId);
    }
    // 标记撤了，冷却也一起撤：下一次 `start` 不该被上一次探测的结论挡住
    // （那会让「刚重登成功」的实例在两分钟内拒绝被重新调度）。
    _probedAt.remove(profileId);
  }

  /// 上一次**尝试**探测的时刻。
  ///
  /// 记「尝试」而不是「结论」：连续失败（断网）时也得被冷却挡住，
  /// 否则每次界面事件都会再打一发请求 —— 而这条路只在实例已经被判
  /// 「需重登」时才会走到，那正是最不该雪上加霜的时候。
  /// 用户手动的「立即同步」传 [force] = true 绕开它。
  final Map<String, DateTime> _probedAt = <String, DateTime>{};

  /// 两次自动会话探测之间的最短间隔（手动 [force] 不走这个）。
  ///
  /// `start()` 会被调得很频繁（切实例、从后台回来、改个邮箱、重算
  /// `profilesProvider`），而带「需要重登」标记的实例每次都会走到探测
  /// 这一步 —— 不设闸门的话，一个**确实**失效的实例会按「界面事件的
  /// 频率」去打 401，那既费流量又会让服务端一直记 401 日志。
  static const Duration _probeCooldown = Duration(minutes: 2);

  /// 当面问一次服务端：这个实例的登录态到底还算不算数。
  ///
  /// 存在的理由：「需要重登」这个标记是**落库的、跨重启的**，而它当初的
  /// 唯一依据是一次 401 —— 那一次完全可能是虚惊（服务端刚换过 `jwt_secret`
  /// 让所有旧 token 当场作废、KV 抖动、或者恰恰被第 12 台设备挤了出去）。
  /// 只信那个标记的话，一个明明还能登录的实例就永远翻不了身，用户看到的
  /// 是「账户好好的，可这个实例再也不自己收信了」。
  ///
  /// 为什么必须打这一次请求、没法在本地判断：token 是服务端签的 JWT，
  /// 客户端验不了签名；而它**没有 `exp`**（见 `AuthApi` 的注释），
  /// 有效与否只体现在 KV 里那份 token 列表上。`/my/loginUserInfo` 很轻，
  /// 而且是登录后本来就要调的第一个接口，用它当探针最合适。
  ///
  /// [force] = true 表示「用户刚点了立即同步」这类明确的意图，忽略冷却。
  Future<SessionProbe> probeSession(
    Profile profile, {
    bool force = false,
  }) async {
    final runtime = _runtimes[profile.id];
    if (runtime == null || runtime.isDisposed) return SessionProbe.unknown;

    final now = DateTime.now().toUtc();
    if (!force) {
      final last = _probedAt[profile.id];
      if (last != null && now.difference(last) < _probeCooldown) {
        return SessionProbe.unknown;
      }
    }
    _probedAt[profile.id] = now;

    // 缓存里没有 token 时**先问一次钥匙串**：401 的处理只摘了内存缓存，
    // 钥匙串那份是刻意留着的（见 `TokenStore.invalidateMemory`）。
    // 少了这一步，复验在「本次运行内」永远拿不到 token，只能等重启 ——
    // 而需要复验的恰恰就是「刚刚吃了 401」这一刻。
    //
    // 放在冷却判断之后：冷却期内的重复调用不该为此去碰两次平台通道。
    if (!runtime.hasToken) {
      await runtime.warmUp();
      if (!runtime.hasToken) return SessionProbe.expired;
    }

    try {
      await runtime.myApi.loginUserInfo();
      return SessionProbe.valid;
    } catch (error) {
      if (error is AuthExpiredException) return SessionProbe.expired;
      // 断网 / 超时 / 服务端 5xx：**不带结论**。既不能据此判死
      // （那会把一次断网变成「需要重新登录」），也不能据此翻案。
      DiagLog.log('registry', '会话探测无结论（${profile.id}）：$error');
      return SessionProbe.unknown;
    }
  }

  /// 401 的唯一落点。
  ///
  /// 做五件事，**顺序不能反**：
  /// 1. 停掉该实例的在途请求；
  /// 2. 把 token 从**内存缓存**里摘掉（后续请求先别带着它吃 401）——
  ///    但钥匙串里那一份**先留着**，见下面的复验（复验无结论时它会回到
  ///    内存缓存，那是下一次再验的凭据）；
  /// 3. 记下「需要重登」——**不删 profile**，用户重登即可，
  ///    而且此时 `email` 还在，登录页能预填；
  /// 4. **落库**（`onAuthExpired`）—— 内存标记活不过重启，而 `redirect`
  ///    看的是 `Profile.isLoggedIn`，不落库就会出现「重启后又像是登录着的」；
  /// 5. **复验一次**（[_revalidateSession]）：一次 401 未必是 token 真的废了，
  ///    拿钥匙串里那份再问一次服务端，虚惊一场就撤销标记、恢复登录态。
  ///
  /// 第 2 步为什么不再直接 [TokenStore.delete]：删掉是**不可逆**的。以前就是
  /// 这个顺序 —— 先删再想救，于是 `probeSession` 里那句
  /// 「`hasToken == false` 就是过期」把唯一的翻案路径也一起判死了，
  /// 一次瞬时 401（KV 跨 colo 还没同步、被别的设备顶掉、服务端抖动）
  /// 就能把一个其实还有效的登录态永久打死。
  void _onAuthExpired(AuthExpiredEvent event) {
    final runtime = _runtimes[event.profileId];
    runtime?.cancelAll();
    tokens.invalidateMemory(event.profileId);
    _needsLoginMessages[event.profileId] = event.message;
    if (!_invalidated.isClosed) _invalidated.add(event.profileId);

    // 收尾动作，失败只记日志：磁盘/库的毛病不该把 401 的处理路径也拖垮。
    final persist = onAuthExpired;
    if (persist != null) {
      try {
        persist(event.profileId);
      } catch (error, stack) {
        debugPrint('标记 needsLogin 失败（${event.profileId}）：$error\n$stack');
      }
    }

    unawaited(_revalidateSession(event.profileId));
  }

  /// 正在复验的实例。**防重入**用。
  ///
  /// 复验自己也会发请求：如果那一次也回 401，`_onAuthExpired` 会被**再**
  /// 触发一遍，然后又排一次复验 —— 没有这道闸就是一条无限递归。
  /// 闸门只挡「再排一轮复验」：复验期间来的 401 事件本身照常处理
  /// （标记、落库都是幂等的），但结论由正在跑的那一轮统一给出 ——
  /// 它要么是复验本身的那一次，要么是复验期间别的在途请求。
  final Set<String> _revalidating = <String>{};

  /// 拿钥匙串里那份 token 再问一次服务端，决定「真失效」还是「虚惊一场」。
  ///
  /// 三种结论分开处理：
  /// - `valid`：撤销内存标记 + 落库撤标记（[onSessionRecovered]），token
  ///   已经被 `warmUp` 写回缓存，登录态原地恢复；
  /// - `expired`：这时才 [TokenStore.delete]，标记保持（用户重登）；
  /// - `unknown`：网络/服务端 5xx，**不下结论** —— 钥匙串那份继续留着，
  ///   标记也继续留着。复验时 `warmUp` 已经把它读回了缓存，所以它同时也是
  ///   「下一次再验」的凭据；下一次冷启动（或用户手动重试）时调度器那条
  ///   既有的「验活」路径会拿它再问一次，问通了就翻案。
  Future<void> _revalidateSession(String profileId) async {
    if (!_revalidating.add(profileId)) return;
    try {
      final runtime = _runtimes[profileId];
      if (runtime == null || runtime.isDisposed) return;

      final probe = await probeSession(runtime.profile, force: true);
      switch (probe) {
        case SessionProbe.valid:
          await _recoverSession(profileId);
        case SessionProbe.expired:
          // 到这里才是真的废了：撤掉钥匙串那份，免得下次冷启动又把
          // 一个确定无效的 token 读回来、白跑一轮 401。
          await tokens.delete(profileId);
        case SessionProbe.unknown:
          DiagLog.log('registry', '401 复验无结论，保留钥匙串 token（$profileId）');
      }
    } catch (error, stack) {
      // 复验是**补救**路径，绝不能反过来把 401 的处理拖垮。
      debugPrint('401 复验异常（$profileId）：$error\n$stack');
    } finally {
      _revalidating.remove(profileId);
    }
  }

  /// 复验成功：撤销「需要重登」，并落库。
  Future<void> _recoverSession(String profileId) async {
    final wasFlagged = _needsLoginMessages.remove(profileId) != null;
    // 探测的冷却一起撤：下一次 `start` 不该被上一次探测的结论挡住。
    _probedAt.remove(profileId);

    final persist = onSessionRecovered;
    if (persist != null) {
      try {
        await persist(profileId);
      } catch (error, stack) {
        debugPrint('撤销 needsLogin 失败（$profileId）：$error\n$stack');
      }
    }

    // **落库之后**再通知监听者：先通知的话，调度器重建时读到的还是
    // `needs_login = 1`，会拿刚验过的 token 再打一次「验活」请求 ——
    // 白跑一趟，而且结论和刚做过的这次一样。
    if (wasFlagged && !_invalidated.isClosed) _invalidated.add(profileId);
  }

  Future<void> dispose() async {
    await _authSub?.cancel();
    _authSub = null;
    for (final runtime in _runtimes.values) {
      runtime.dispose();
    }
    _runtimes.clear();
    await _invalidated.close();
  }
}

/// [RuntimeRegistry.probeSession] 的结论。
enum SessionProbe {
  /// 服务器认这个 token（`/my/loginUserInfo` 正常返回）。
  valid,

  /// 服务器明确说了「你的登录态不算数」（401）。
  expired,

  /// 问不出结论：断网、超时、服务端 5xx —— 既不能据此判死，
  /// 也不能据此翻案。
  unknown,
}
