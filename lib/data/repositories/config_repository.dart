import 'dart:async';

import '../../core/util/diag_log.dart';
import '../models/instance_capabilities.dart';
import '../models/profile.dart';
import '../models/website_config.dart';
import '../../instance/runtime_registry.dart';
import 'capability_repository.dart';

/// `websiteConfig` 的**进程内缓存**。
///
/// 为什么需要一个单独的 repository：这个端点在整条流程里被反复用到
/// （登录页回显标题、附件前缀、发信开关、域名列表、轮询间隔建议），
/// 而它**免鉴权、无副作用**，每次用到都打一遍是纯粹的浪费。
///
/// 三处刻意设计：
/// - **不落库**。`serverTitle` / `r2Domain` / `domainList` 已经随
///   [InstanceCapabilities] 落进了 `capabilities` 表，再存一份配置是双重真相。
///   这里的缓存只在进程内，重启后由能力表兜底，第一次请求再刷新。
/// - **TTL 短**（默认 5 分钟）而不是永久：用户可能在 Web 端改了站点标题、
///   开了发信，App 不该一直显示旧值。下拉刷新与设置页的「立即同步」都会
///   `force: true` 绕过它。
/// - **失败不抛**。缓存里有过一次成功结果时，网络抖动就直接用旧的；
///   只有从没成功过才把异常抛上去（登录页要靠它判断「地址填错了」）。
class ConfigRepository {
  ConfigRepository({
    required this.registry,
    required this.capabilities,
    this.ttl = const Duration(minutes: 5),
  });

  final RuntimeRegistry registry;
  final CapabilityRepository capabilities;
  final Duration ttl;

  final Map<String, WebsiteConfig> _cache = <String, WebsiteConfig>{};
  final Map<String, DateTime> _fetchedAt = <String, DateTime>{};
  final Map<String, Future<WebsiteConfig>> _inFlight =
      <String, Future<WebsiteConfig>>{};

  /// 取配置。命中缓存（且未过期）时同步返回，否则打一次网络。
  ///
  /// [force] 为 true 时忽略 TTL（下拉刷新、设置页自检、登录后的第二次拉取）。
  Future<WebsiteConfig> fetch(
    Profile profile, {
    bool force = false,
    bool allowStaleOnError = true,
  }) {
    final id = profile.id;
    final cached = _cache[id];
    if (!force && cached != null && !_isExpired(id)) return Future.value(cached);

    // 同一个实例的并发请求合成一次 —— 登录页与首页可能在启动时同时问。
    final running = _inFlight[id];
    if (running != null) return running;

    // ⚠️ 这里的回调**必须写成块体 `{ ... }`，不能写成表达式 `() => _inFlight.remove(id)`**。
    //
    // `whenComplete` 的签名是 `FutureOr<void> Function()`。写成表达式时它的返回值
    // 是 `Future<WebsiteConfig>?` —— 而 `Future<WebsiteConfig>` 可以赋给
    // `Future<void>`（`void` 是顶类型），所以**编译期毫无提示**；运行期
    // `whenComplete` 会去 await 这个返回的 future，而 `remove` 拿回来的
    // **恰好就是这个 `whenComplete` 自己的 future** —— 它开始等自己，永远不完成。
    //
    // 症状就是 App 里那个「测试连接一直转圈」：请求早就 200 回来了，`_cache`
    // 与 `_fetchedAt` 都写好了，`_inFlight` 也确实是空的（`remove` 是同步执行的），
    // 唯独 `await fetch(...)` 那一行永远没有下文 —— 也没有任何异常。
    // 块体返回 void，`whenComplete` 就不会去 await 任何东西。
    final pending = _load(profile, fallback: allowStaleOnError ? cached : null);
    final future = pending.whenComplete(() {
      _inFlight.remove(id);
    });
    _inFlight[id] = future;
    return future;
  }

  Future<WebsiteConfig> _load(
    Profile profile, {
    WebsiteConfig? fallback,
  }) async {
    final runtime = registry.peek(profile.id);
    if (runtime == null || runtime.isDisposed) {
      if (fallback != null) return fallback;
      throw StateError('实例未就绪：${profile.id}');
    }
    try {
      // 有 token 时拿到的配置**严格更好**（多一个 `domainList`），
      // 所以这里不是「要不要鉴权」而是「有没有 token」—— 没有的话服务端
      // 会拿一个空 Authorization 当假 token 拒掉（等价于没带，但多一次
      // 白跑）。`DiagLog.trace` 收的是一个**闭包**，所以这里要包一层而不是
      // 撕掉 `trace`。
      final config = await DiagLog.trace(
        'config',
        'GET ${runtime.profile.baseUrl}/setting/websiteConfig'
            '${runtime.hasToken ? ' (auth)' : ''}',
        () => runtime.settingApi.websiteConfig(
          authenticated: runtime.hasToken,
        ),
      );
      _cache[profile.id] = config;
      _fetchedAt[profile.id] = DateTime.now().toUtc();

      // 顺手把能从配置里读出来的能力/身份同步进库 —— 这样即便用户不开
      // 任何页面，`Profile.ossBase` 与侧栏标题也能在下次冷启动时是对的。
      //
      // ⚠️ 但这两步是**本地库读写**，不是 `fetch` 的契约内容。它们失败、
      // 或者干脆卡住（drift 后台 isolate 忙、库被另一个 isolate 占着写锁），
      // 都不该让调用方拿不到已经到手的那份配置 —— 调用方等的是「配置」，
      // 不是「配置已落库」。所以：不 await，并且单独 catch。
      //
      // 这一条的代价曾经很实在：这两步里任何一步抛错或挂起，都会让
      // `await _load(...)` 永不 resolve，UI 那边就是一个**永远转不完的圈**，
      // 而日志上网络请求明明已经 200 回来了。
      unawaited(_syncCapabilities(profile, config));

      return config;
    } catch (e) {
      // 有过成功结果时，抖动不该让 UI 变脸 —— 网络类错误直接用旧值。
      if (fallback != null) return fallback;
      DiagLog.log('config', '拉配置失败（${profile.id}）：${e.runtimeType}: $e');
      rethrow;
    }
  }

  /// 把配置里读得出的能力同步进库。**纯副作用，调用方不等待。**
  ///
  /// 失败只记日志：能力表落后一轮不影响任何一次展示，下一轮
  /// `fetch`/`probe` 会把它追上。反过来，若把这里的异常抛给 `fetch`，
  /// 就会把一个「本地库的小毛病」升级成「用户看不到站点配置」。
  Future<void> _syncCapabilities(Profile profile, WebsiteConfig config) async {
    try {
      final caps = await DiagLog.trace(
        'config',
        '读 capabilities(${profile.id})',
        () => capabilities.of(profile.id),
      );
      await DiagLog.trace(
        'config',
        '写 capabilities(${profile.id})',
        () => capabilities.save(
          profile.id,
          capabilities.applyWebsiteConfig(caps, config),
        ),
      );
    } catch (e) {
      DiagLog.log(
        'config',
        '同步 capabilities 失败（${profile.id}，不影响配置返回）：'
        '${e.runtimeType}: $e',
      );
    }
  }

  /// 同步读缓存（渲染正文要 `ossBase` 时用）。没缓存返回 null。
  WebsiteConfig? peek(String profileId) => _cache[profileId];

  /// 登录成功后由 `AuthRepository` 传进来的那次结果，直接种进缓存，
  /// 省掉一次立刻重复的请求。
  void seed(String profileId, WebsiteConfig config) {
    _cache[profileId] = config;
    _fetchedAt[profileId] = DateTime.now().toUtc();
  }

  void forget(String profileId) {
    _cache.remove(profileId);
    _fetchedAt.remove(profileId);
    _inFlight.remove(profileId);
  }

  bool _isExpired(String profileId) {
    final at = _fetchedAt[profileId];
    if (at == null) return true;
    return DateTime.now().toUtc().difference(at) > ttl;
  }

  /// 这个实例的附件前缀。优先用 `Profile.ossBase`（它落过库、冷启动就有），
  /// 其次用刚拉到的配置现算。
  String ossBaseOf(Profile profile) {
    if (profile.ossBase.isNotEmpty) return profile.ossBase;
    final config = _cache[profile.id];
    return profile.resolveOssBase(config?.r2Domain);
  }

  /// 诊断页用：当前缓存的那一份配置（可能是空的）。
  Map<String, String> describe(String profileId, {InstanceCapabilities? caps}) {
    final config = _cache[profileId];
    final at = _fetchedAt[profileId];
    return <String, String>{
      'title': config?.title ?? caps?.serverTitle ?? '-',
      'send': config == null ? '-' : (config.sendEnabled ? '开放' : '关闭'),
      'register': config == null ? '-' : (config.registerEnabled ? '开放' : '关闭'),
      'r2Domain': config?.r2Domain ?? caps?.r2Domain ?? '缺失（走 /api/oss/）',
      'autoRefresh': config == null ? '-' : '${config.autoRefresh}s',
      'domainList': config?.domainList.join(', ') ??
          (caps?.domainList.isEmpty ?? true ? '-' : caps!.domainList.join(', ')),
      'cachedAt': at == null
          ? '未缓存'
          : at.toLocal().toIso8601String().substring(11, 19),
    };
  }
}
