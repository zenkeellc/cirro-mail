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
  /// 让所有旧 token 当场作废、KV 抖动、或者恰恰被第 11 台设备挤了出去）。
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
    if (!runtime.hasToken) return SessionProbe.expired;

    final now = DateTime.now().toUtc();
    if (!force) {
      final last = _probedAt[profile.id];
      if (last != null && now.difference(last) < _probeCooldown) {
        return SessionProbe.unknown;
      }
    }
    _probedAt[profile.id] = now;

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
  /// 做四件事，**顺序不能反**：
  /// 1. 停掉该实例的在途请求；
  /// 2. 清掉密钥库里的 token（否则下一轮请求又会带上这个废 token 再吃一次 401）；
  /// 3. 记下「需要重登」——**不删 profile**，用户重登即可，
  ///    而且此时 `email` 还在，登录页能预填；
  /// 4. **落库**（`onAuthExpired`）—— 内存标记活不过重启，而 `redirect`
  ///    看的是 `Profile.isLoggedIn`，不落库就会出现「重启后又像是登录着的」。
  void _onAuthExpired(AuthExpiredEvent event) {
    final runtime = _runtimes[event.profileId];
    runtime?.cancelAll();
    unawaited(tokens.delete(event.profileId));
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
