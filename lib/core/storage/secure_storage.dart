import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 系统密钥库（Keychain / Keystore / libsecret / DPAPI）的**唯一入口**。
///
/// ## 为什么 macOS 不能直接用一句 `const FlutterSecureStorage()`
///
/// `flutter_secure_storage` 在 macOS 上的默认实现是 **data protection
/// keychain**（iOS 那套，`usesDataProtectionKeychain: true`）。它按
/// entitlement 授权，要求 App 带 `com.apple.application-identifier` ——
/// Xcode 用描述文件签名时会自动带上；手工 ad-hoc / Developer ID 签名的产物
/// 没有这条权利，任何**写**都会 `-34018`（`errSecMissingEntitlement`）。
/// 早先因此一律关掉它、走老钥匙串（见 [macLegacyStorage] 的注释）。
///
/// 但老钥匙串的每条记录都带一份「只信任创建它的那个 App 签名」的 ACL：构建
/// 一换签名（ad-hoc 每次重编都换），App 一读就会弹出
/// 「想要访问钥匙串中的机密信息」并要登录密码。开发机上装的包混着
/// ad-hoc / Apple Development / Developer ID 几种签名，于是**每次启动都弹**。
/// data protection 钥匙串没有这层逐 App ACL，自然不弹授权框。
///
/// ## 怎么选
///
/// 不猜签名、也不去读描述文件（两者都可能与真实签名状态不一致），而是**真写
/// 一次**：往 data protection 钥匙串写一条探测项、马上删掉（[probeKey]）。
///
/// - 写成功 ⇒ 这条构建有权利，用它，此后不再弹钥匙串授权框；
/// - 写失败 ⇒ 退回 [macLegacyStorage]，与从前逐字节一致（这正是没有
///   entitlement 的 Developer ID 发布包要走的路）。
///
/// 探测异常**只打日志、不拦启动**：钥匙串临时被锁（`-25308`）这类情况也不该
/// 让 App 起不来。
///
/// 探测每个进程只做一次并缓存：`TokenStore` 与 `AiApiKeyStore` 共用同一结果；
/// 后台 isolate 是独立的引擎，会各探各的（代价就是两次钥匙串调用）。
///
/// **缓存的是「选中的实例」，不是 Future**：`Future` 会被创建它的 Zone 绑住
/// （fake async 的 widget 测试里，上一个用例的 Zone 不再被驱动），把同一个
/// Future 交给下一个用例 await 就会永远挂住。所以这里只在**解析完成之后**
/// 才写缓存 —— 同时进来的两个调用会各探一次，探测本身是幂等的（写一条再删
/// 一条同一个 key），代价可以忽略。
Future<FlutterSecureStorage> resolveSecureStorage() async {
  final cached = _cachedChoice;
  if (cached != null) return cached;
  final chosen = await _resolveSecureStorage();
  _cachedChoice = chosen;
  return chosen;
}

FlutterSecureStorage? _cachedChoice;

Future<FlutterSecureStorage> _resolveSecureStorage() async {
  // Web 上没有钥匙串；其余平台（Android/Windows/Linux/iOS）插件默认即可，
  // 那些平台不存在「按签名做 ACL」这回事。
  if (kIsWeb || !Platform.isMacOS) return const FlutterSecureStorage();
  return pickMacSecureStorage(
    dataProtection: macDataProtectionStorage,
    legacy: macLegacyStorage,
    probe: probeDataProtection,
  );
}

/// macOS 的 data protection 钥匙串实例：按 entitlement 授权，没有逐 App ACL，
/// 所以**不会弹**钥匙串授权框。
///
/// 注意它只在 App 带 `com.apple.application-identifier` 时才可用 —— 这正是
/// [resolveSecureStorage] 要探测的原因。
@visibleForTesting
const FlutterSecureStorage macDataProtectionStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: true),
);

/// macOS 的老式登录钥匙串实例：任何签名都能用，但每条记录的 ACL 只信任写它的
/// 那个签名，签名一变就要用户点「允许」/输密码。
///
/// 这是没有 provisioning profile 的构建（手工 ad-hoc、Developer ID 分发包）
/// 的**必须**选择 —— 关掉 data protection 后就不需要任何 entitlement。
@visibleForTesting
const FlutterSecureStorage macLegacyStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);

/// 探测用的 key：写完立刻删，不会留在钥匙串里，也不会被业务读到。
@visibleForTesting
const String probeKey = 'secure_storage_capability_probe';

/// 探测 data protection 钥匙串是否真的可写。
///
/// **必须是写**，不能只读：没有 entitlement 时，读一条不存在的记录返回的是
/// `errSecItemNotFound`（查不到 ≠ 没权限），只有写入才会暴露 `-34018`。
/// 只读探测会把「没权利」误判成「可用」，之后每个 token 都写不进去。
@visibleForTesting
Future<void> probeDataProtection(FlutterSecureStorage storage) async {
  await storage.write(key: probeKey, value: '1');
  await storage.delete(key: probeKey);
}

/// 选 macOS 钥匙串的**纯逻辑**：探测成功用 [dataProtection]，任何异常退回
/// [legacy]。
///
/// 抽成这个形状是为了能测：测试进程本身没有 App 的 entitlement，真探测一定
/// 抛 `-34018`，所以测试注入一个假的 [probe] 就能覆盖两条分支而不碰真钥匙串。
@visibleForTesting
Future<FlutterSecureStorage> pickMacSecureStorage({
  required FlutterSecureStorage dataProtection,
  required FlutterSecureStorage legacy,
  required Future<void> Function(FlutterSecureStorage storage) probe,
}) async {
  try {
    await probe(dataProtection);
    debugPrint('macOS 钥匙串：data protection 可用（不再有钥匙串授权框）');
    return dataProtection;
  } catch (e) {
    // 捕得比 PlatformException 宽：插件没注册时抛的是 MissingPluginException，
    // 它**不是** PlatformException。选钥匙串失败不该让启动失败。
    debugPrint('macOS 钥匙串：data protection 不可用，本次运行退回老钥匙串：$e');
    return legacy;
  }
}

/// 仅测试用：清掉进程内缓存的钥匙串选择（同一个测试文件里换假钥匙串时要用）。
@visibleForTesting
void resetSecureStorageCache() {
  _cachedChoice = null;
}
