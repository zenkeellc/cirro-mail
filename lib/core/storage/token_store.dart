import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';

/// 每个 profile 一个 token，存系统密钥库（Keychain / Keystore / libsecret / DPAPI）。
///
/// 几个刻意的设计：
/// - **key 是 `token_<profileId>`**：多实例下不同实例的 token 互不干扰，
///   删实例时能精确清掉属于它那一个。
/// - **内存缓存**：`AuthInterceptor` 每次请求都要读 token，走一次平台通道太贵。
///   缓存只在这一个进程里有效，`read` 首次仍会打平台通道。
/// - **平台通道失败降级**：Linux 上没装 libsecret、或 macOS 上 keychain 被锁时
///   读写会抛 `PlatformException`。这时退化成「仅内存」—— 本次运行可用，
///   但明确告诉 UI「重启要重新登录」，而不是静默失败或明文落盘。
/// - **macOS 上优先 data protection 钥匙串**：老钥匙串的 ACL 只信任写它的
///   那个签名，构建一换就要用户点授权，于是开发机每次启动都弹框。选哪套
///   由 [resolveSecureStorage] 探测决定，缺失 entitlement 的构建自动退回
///   （Developer ID 分发包走的就是那条路）。
class TokenStore {
  /// 不显式传 `aOptions` —— 11.x 的默认 `AndroidOptions()` 已经是
  /// AES-GCM + RSA OAEP 包装（旧版的 `encryptedSharedPreferences` 开关
  /// 在这个大版本里被移除了）。
  ///
  /// 不传 [storage] 时走 [resolveSecureStorage]：macOS 上优先 data protection
  /// 钥匙串（没有逐 App ACL，不弹授权框），没有 entitlement 的构建自动退回
  /// 老钥匙串。测试可以注入一个走内存的假存储，就不必碰平台通道。
  TokenStore({FlutterSecureStorage? storage}) : _injectedStorage = storage;

  final FlutterSecureStorage? _injectedStorage;

  /// 真正用的存储。**懒解析**：构造 `TokenStore` 不碰平台通道（`bootstrap` 里
  /// 就是构造完直接拿去用，那时还不到读钥匙串的时候），首次读写才去解析。
  late final Future<FlutterSecureStorage> _storageFuture = _openStorage();

  Future<FlutterSecureStorage> _openStorage() async {
    final injected = _injectedStorage;
    return injected ?? await resolveSecureStorage();
  }

  /// profileId → token。命中的请求不再走平台通道。
  final Map<String, String> _cache = <String, String>{};

  /// token 已被读进缓存的 profileId（避免把「未缓存」当成「没有 token」）。
  final Set<String> _loaded = <String>{};

  /// 密钥库不可用（读或写抛过平台异常）。UI 据此提示用户。
  bool _degraded = false;
  bool get isDegraded => _degraded;

  static const String _prefix = 'token_';

  /// 推送配对码的 key 前缀。**跟实例 token 分开**：两者的生命周期不同 ——
  /// 退出实例登录会清掉 `token_<id>`，但「这台设备订阅了这个实例的推送」
  /// 是另一件事，不该被顺手清掉。
  static const String _pushPrefix = 'push_';

  static String keyFor(String profileId) => '$_prefix$profileId';

  static String pushKeyFor(String instanceId) => '$_pushPrefix$instanceId';

  /// 读 token。缓存优先；缓存里没有且没读过才打平台通道。
  Future<String?> read(String profileId) async {
    if (profileId.isEmpty) return null;
    final cached = _cache[profileId];
    if (cached != null) return cached;
    if (_loaded.contains(profileId)) return null;

    try {
      final storage = await _storageFuture;
      final value = await storage.read(key: keyFor(profileId));
      if (value != null && value.isNotEmpty) {
        _cache[profileId] = value;
        _loaded.add(profileId);
        _refreshWanted.remove(profileId);
        return value;
      }
      // 明确读到「不存在」也记一笔，省掉重复查询 —— 但**同时**记下
      // 「这个 id 以后值得再问一次钥匙串」：现在没有不等于登录失败了
      // （可能只是用户还没重登），而 `hasToken` 一旦被当成定论，
      // 同步引擎就会在第一轮报「未登录」并停掉整个循环。
      _loaded.add(profileId);
      _refreshWanted.add(profileId);
      return null;
    } on PlatformException catch (e) {
      _degraded = true;
      debugPrint('TokenStore.read 失败（降级为仅内存）：${e.message}');
      _loaded.add(profileId);
      _refreshWanted.add(profileId);
      return null;
    }
  }

  /// 同步读缓存（`AuthInterceptor` 用）。**没命中返回 null，不会去打平台通道。**
  /// 调用方要保证在发起请求前已经 [read] 过一次（`ProfileRuntime` 初始化时会做）。
  String? readCached(String profileId) => _cache[profileId];

  /// 绕过「读过就是没有」这条缓存，**真的**再问一次钥匙串。
  ///
  /// 存在的理由是「会话过期」这条最容易被误判的路径：401 发生时我们会把内存里
  /// 的 token 清掉（[delete]），可钥匙串里那份**可能根本没删掉** ——
  /// 删失败只写一行日志（见 [delete]）。只信内存的话，一次偶发的 401、
  /// 或服务端一次抖动，就会把一个其实还有效的登录态永久判死：用户看到
  /// 「需要重新登录」，而真正的 token 一直躺在钥匙串里。
  ///
  /// 所以恢复登录态时走这里：拿到就顺带写回缓存，拿不到才承认「确实没了」。
  Future<String?> readFresh(String profileId) async {
    if (profileId.isEmpty) return null;
    _refreshWanted.remove(profileId);
    try {
      final storage = await _storageFuture;
      final value = await storage.read(key: keyFor(profileId));
      if (value != null && value.isNotEmpty) {
        _cache[profileId] = value;
        _loaded.add(profileId);
        return value;
      }
    } on PlatformException catch (e) {
      _degraded = true;
      debugPrint('TokenStore.readFresh 失败：${e.message}');
    }
    _cache.remove(profileId);
    _loaded.add(profileId);
    return null;
  }

  /// [read] 读不到时，把「以后也许还得再问一次钥匙串」的 profileId 记在这儿。
  ///
  /// 为什么要有它：[read] 读到「不存在」会在 `_loaded` 里记一笔，之后永远返回
  /// null。而这里会读到「不存在」的两种情形是**必须重试**的：
  /// 冷启动时用户还没重新登录、以及上一次读恰好赶上钥匙串被锁。
  /// 于是 [hasToken] 在真正为 token 调用 [read] 之后才允许被信任 ——
  /// 漏掉这一步的代价是 `SyncEngine` 在第一轮就报「未登录」并停掉循环，
  /// 而用户的登录态其实完好。
  final Set<String> _refreshWanted = <String>{};

  /// [read] 读空时返回 true，表示「该再问一次」（见 [_refreshWanted]）。
  bool wantsRefresh(String profileId) => _refreshWanted.contains(profileId);

  Future<void> write(String profileId, String token) async {
    if (profileId.isEmpty || token.isEmpty) return;
    _cache[profileId] = token;
    _loaded.add(profileId);
    _refreshWanted.remove(profileId);
    try {
      final storage = await _storageFuture;
      await storage.write(key: keyFor(profileId), value: token);
      _degraded = false;
    } on PlatformException catch (e) {
      _degraded = true;
      debugPrint('TokenStore.write 失败（本次运行仍可用）：${e.message}');
    }
  }

  Future<void> delete(String profileId) async {
    _cache.remove(profileId);
    _loaded.add(profileId);
    try {
      final storage = await _storageFuture;
      await storage.delete(key: keyFor(profileId));
    } on PlatformException catch (e) {
      _degraded = true;
      debugPrint('TokenStore.delete 失败：${e.message}');
    }
  }

  /// 删实例时调用：清掉该 profile 的 token 与缓存。
  Future<void> deleteAllOf(Iterable<String> profileIds) async {
    for (final id in profileIds) {
      await delete(id);
    }
  }

  // ---- 推送配对凭证 ---------------------------------------------------------
  //
  // 走同一套安全存储（而不是 SharedPreferences）：配对码等于「往这台
  // 设备推这个实例的邮件元数据」的许可，泄漏了别人能读到来信人、主题
  // 和验证码。它不需要跟 token 一样每次请求都读，所以**不进内存缓存** ——
  // 只有推送相关的那几处会读它。

  Future<String?> readPushToken(String instanceId) async {
    if (instanceId.isEmpty) return null;
    try {
      final storage = await _storageFuture;
      final value = await storage.read(key: pushKeyFor(instanceId));
      return (value == null || value.isEmpty) ? null : value;
    } catch (e) {
      // 比上面那几个方法捕得更宽：除了 PlatformException，这里还可能碰到
      // `MissingPluginException`（插件没注册，例如某个平台构建里漏了），
      // 而它**不是** PlatformException。推送这条链路必须能安静降级成
      // 「没有推送」，不能因为读不出配对码就抛到调用方。
      _degraded = true;
      debugPrint('TokenStore.readPushToken 失败：$e');
      return null;
    }
  }

  Future<void> writePushToken(String instanceId, String token) async {
    if (instanceId.isEmpty || token.isEmpty) return;
    try {
      final storage = await _storageFuture;
      await storage.write(key: pushKeyFor(instanceId), value: token);
    } catch (e) {
      _degraded = true;
      debugPrint('TokenStore.writePushToken 失败：$e');
    }
  }

  Future<void> deletePushToken(String instanceId) async {
    if (instanceId.isEmpty) return;
    try {
      final storage = await _storageFuture;
      await storage.delete(key: pushKeyFor(instanceId));
    } catch (e) {
      _degraded = true;
      debugPrint('TokenStore.deletePushToken 失败：$e');
    }
  }

  /// 推送向导里「这一步我在别处做过了」的**见证值**（第 ⑤ 步的实例后台
  /// webhook、第 ⑥ 步的链路检查）。
  ///
  /// ## 为什么是「见证值」而不是一个 bool
  ///
  /// 这两步 App 都**验证不了**：一个发生在另一个网站，另一个要问中转端。
  /// 用户明确确认过之后必须记住（否则每次进来都从头提示一遍），但记住一个
  /// 裸 bool 是错的 —— 他确认的是**当时那三条值**，改了任何一条，那份确认
  /// 就作废了。所以存的是确认那一刻的输入指纹，读回来跟当前输入一比即可。
  ///
  /// ## 为什么在钥匙串而不是 prefs
  ///
  /// 指纹里含配对码，而配对码是这个项目里唯一一个明确不许落 prefs 的值
  /// （见 `PrefsStore` 的推送一节与 `PushService.configure` 的说明）。它本来
  /// 就在这把钥匙串里（`push_<instanceId>`），这里只是同一个秘密的第二种
  /// 用途，没有引入新的暴露面。
  ///
  /// key 是 `pushstep_<step>_<instanceId>`：**刻意与配对码的
  /// `push_<instanceId>` 分开**。两者都用 `push_` 打头的话，
  /// `writePushStepWitness('inst-1', 'webhook', …)` 写出来的 key 会是
  /// `pushwebhook_inst-1` —— 看着没事，但只要以后有个实例位 id 叫
  /// `webhook`，就会读到别人的一份确认。多一个 `step_` 段把这种可能压掉。
  Future<String?> readPushStepWitness(String instanceId, String step) async {
    if (instanceId.isEmpty || step.isEmpty) return null;
    try {
      final storage = await _storageFuture;
      final value = await storage.read(key: _stepKeyFor(instanceId, step));
      return (value == null || value.isEmpty) ? null : value;
    } catch (e) {
      _degraded = true;
      debugPrint('TokenStore.readPushStepWitness 失败：$e');
      return null;
    }
  }

  /// 写见证值。传空串等于删掉（`null` 在这里的语义是「失败」，不是「清空」）。
  Future<void> writePushStepWitness(
    String instanceId,
    String step,
    String value,
  ) async {
    if (instanceId.isEmpty || step.isEmpty) return;
    try {
      final storage = await _storageFuture;
      if (value.isEmpty) {
        await storage.delete(key: _stepKeyFor(instanceId, step));
      } else {
        await storage.write(key: _stepKeyFor(instanceId, step), value: value);
      }
    } catch (e) {
      _degraded = true;
      debugPrint('TokenStore.writePushStepWitness 失败：$e');
    }
  }

  static String _stepKeyFor(String instanceId, String step) =>
      'pushstep_${step}_$instanceId';

  @visibleForTesting
  void clearCache() {
    _cache.clear();
    _loaded.clear();
    _refreshWanted.clear();
  }
}
