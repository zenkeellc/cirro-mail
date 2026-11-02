import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/app_defaults.dart';
import 'app_version.dart';

/// 把「构建期注入」与「`PackageInfo`」合成一个 [AppVersion]。
///
/// 纯函数：不碰平台通道、不读 git，测试直接喂字符串。判据只有一条 ——
/// **构建期注入的值优先**（官方构建走这条路），没注入才退回 `PackageInfo`
/// （直接 `flutter run` 时只有它）。
///
/// 注入的 build 号不是数字时按 0 处理（不是报错）：真机上出现过 `--build-number`
/// 被换成描述串的情况，界面退化成不显示 `+N` 比整页打不开好。
AppVersion composeAppVersion({
  required String defineVersion,
  required String defineBuild,
  required String defineCommit,
  required String defineBuiltAt,
  required String defineChannel,
  String? packageVersion,
  String? packageBuildNumber,
}) {
  final injectedVersion = defineVersion.trim();
  final injectedBuild = defineBuild.trim();
  final version =
      injectedVersion.isNotEmpty ? injectedVersion : (packageVersion ?? '').trim();
  final buildRaw =
      injectedBuild.isNotEmpty ? injectedBuild : (packageBuildNumber ?? '').trim();
  final channel = defineChannel.trim().isEmpty
      ? AppDefaults.updateChannel
      : defineChannel.trim();
  return AppVersion(
    name: version,
    buildNumber: int.tryParse(buildRaw) ?? 0,
    commit: defineCommit.trim(),
    builtAt: DateTime.tryParse(defineBuiltAt.trim())?.toUtc(),
    channel: channel,
  );
}

/// 读当前构建的版本信息。
///
/// [packageInfoLoader] 只为测试存在：真机上是 `PackageInfo.fromPlatform()`，
/// 它在 `flutter_tester` 里只会抛 `MissingPluginException` —— 那不该让关于页
/// 或更新检查崩掉，所以这里吞掉异常、退回「只有注入值」。
Future<AppVersion> loadAppVersion({
  Future<PackageInfo?> Function()? packageInfoLoader,
  String defineVersion = AppDefaults.appVersionName,
  String defineBuild = AppDefaults.appBuildNumber,
  String defineCommit = AppDefaults.appGitCommit,
  String defineBuiltAt = AppDefaults.appBuildTime,
  String defineChannel = AppDefaults.updateChannel,
}) async {
  PackageInfo? info;
  try {
    info = packageInfoLoader != null
        ? await packageInfoLoader()
        : await PackageInfo.fromPlatform();
  } catch (error) {
    debugPrint('PackageInfo 不可用：$error');
  }
  return composeAppVersion(
    defineVersion: defineVersion,
    defineBuild: defineBuild,
    defineCommit: defineCommit,
    defineBuiltAt: defineBuiltAt,
    defineChannel: defineChannel,
    packageVersion: info?.version,
    packageBuildNumber: info?.buildNumber,
  );
}

/// 当前构建的版本。关于页、桌面窗口标题、更新检查共用这一份。
///
/// 每次启动解析一次即可 —— 版本在进程生命周期里不会变。
final FutureProvider<AppVersion> appVersionProvider =
    FutureProvider<AppVersion>(
  (Ref ref) => loadAppVersion(),
  name: 'appVersion',
);
