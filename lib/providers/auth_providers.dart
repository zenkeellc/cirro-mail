import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/user_info.dart';
import '../data/models/website_config.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/capability_repository.dart';
import '../instance/profile_runtime.dart';
import 'core_providers.dart';
import 'profile_providers.dart';

/// 某个实例的登录编排器。
///
/// 放在单独的 provider 文件里（而不是 `core_providers.dart`）：它需要同时
/// 拿到 runtime 与 profile，而 `core_providers` 在依赖图上位于
/// `profile_providers` **下面**（后者 import 前者），把 family 建在
/// `core_providers` 里会成环。
///
/// runtime 是**懒建**的：只有真正要登录/登出某个实例时才会 `ensure`，
/// 冷启动不会为 10 个实例各建一条 Dio。
final authRepositoryProvider = Provider.family<AuthRepository, String>(
  (ref, profileId) {
    final registry = ref.watch(runtimeRegistryProvider);
    final profile = ref.watch(profileByIdProvider(profileId));
    if (profile == null) {
      // 实例已被删除（设置页里删掉后旧页面还可能重建一次）。
      // 抛在这里比返回 null 好 —— 调用方不该拿到一个「假」的编排器。
      throw StateError('实例不存在：$profileId');
    }
    final runtime = registry.ensure(profile);
    return AuthRepository(
      runtime: runtime,
      tokens: ref.watch(tokenStoreProvider),
      prefs: ref.watch(prefsStoreProvider),
      registry: registry,
      profiles: ref.watch(profileRepositoryProvider),
      accounts: ref.watch(accountRepositoryProvider),
      configs: ref.watch(configRepositoryProvider),
      // 登录落库后立刻在后台探一轮能力：用户不必为四五个探测请求付延迟，
      // 但界面很快就能收敛到「这个实例支持什么」。
      onLoggedIn: (user, config) => probeInBackground(
        ref.watch(capabilityRepositoryProvider),
        runtime,
        config: config,
        userInfo: user,
      ),
    );
  },
  name: 'authRepository',
);

/// 后台能力探测。**不返回 Future** —— 调用方不该有「要不要 await」这个选项：
/// 探测失败是可以接受的（UI 保持乐观，等真正调到 403/501 再降级），
/// 把它挂在登录路径上只会让登录慢两三秒。
void probeInBackground(
  CapabilityRepository caps,
  ProfileRuntime runtime, {
  WebsiteConfig? config,
  UserInfo? userInfo,
}) {
  unawaited(
    caps
        .probe(runtime, websiteConfig: config, userInfo: userInfo)
        .then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        // 探测失败不是错误 —— 下次打开诊断页或重新登录会再探一次。
        debugPrint('能力探测失败（保持乐观）：$error');
      },
    ),
  );
}
