import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../branding/app_brand.dart';
import '../storage/window_channel.dart';
import 'app_version.dart';
import 'version_info.dart';

/// 桌面原生标题栏里那行字：`Cirro Mail v0.1.0+131`（商业版是
/// `Cirro Mail Pro v0.1.0+131` —— 名字走 [AppBrand]，不自带默认值）。
///
/// 拆成纯函数是为了能单独钉住格式（见 `test/window_title_test.dart`）：
///
/// - 版本**未知**时只留应用名 —— `v` + 空串那种标题比没有版本更糟；
/// - build 号 `0` 表示「不知道」，不显示 `+0`（`AppVersion.buildNumber` 的约定，
///   直接 `flutter run` 时只有 pubspec 的版本名、拿不到 build 号）；
/// - 版本名里**没有** `v` 前缀（`app_version.dart` 那边从 tag 剥掉了），所以
///   前缀在这里补。
String windowTitleFor({
  required String appName,
  required String version,
  required int buildNumber,
}) {
  final name = version.trim();
  if (name.isEmpty) return appName;
  final build = buildNumber > 0 ? '+$buildNumber' : '';
  return '$appName v$name$build';
}

/// 把版本号写进**原生**窗口标题栏的那一层。
///
/// 为什么不直接用 `MaterialApp.title`：那只影响引擎上报给任务切换器的名字，
/// 碰不到 macOS 的 `NSWindow.title`、Windows 的 `SetWindowTextW`、GNOME 的
/// `GtkHeaderBar` —— 用户说的「标题栏」正是这些地方。真正的原生写入在三个
/// runner 的 `setWindowTitle` 分支里，Dart 侧只经 [WindowChannel] 递过去。
///
/// 它**不改布局**：`build` 原样返回 [child]，只是挂一个「启动后读一次版本、
/// 再改标题」的副作用。放在 `ProviderScope` 里面、包住 App 的那棵树即可
/// （见 `lib/app.dart`）。
class WindowTitleHost extends ConsumerStatefulWidget {
  const WindowTitleHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WindowTitleHost> createState() => _WindowTitleHostState();
}

class _WindowTitleHostState extends ConsumerState<WindowTitleHost> {
  @override
  void initState() {
    super.initState();
    // 首帧之后再读：版本解析可能要走平台通道（`PackageInfo`），启动路径上
    // 不该让窗口先卡在它上面；而且这时候原生窗口一定已经建好了。
    WidgetsBinding.instance.addPostFrameCallback((_) => _pushWindowTitle());
  }

  Future<void> _pushWindowTitle() async {
    final AppVersion version;
    try {
      version = await ref.read(appVersionProvider.future);
    } catch (error) {
      // 版本是「有最好、没有也行」的信息（与设置页同一口径）：读不到就保持
      // 原生侧现有的标题，不把启动路径带崩。
      debugPrint('窗口标题：版本不可用，保持原样。$error');
      return;
    }
    if (!mounted) return;
    if (!version.isKnown) return;
    await WindowChannel.setTitle(
      windowTitleFor(
        // 产品名走接缝（商业版 `Cirro Mail Pro`）；窗口标题拿不到本地化，
        // 回落的是 `AppDefaults.appDisplayName`（见 `AppBrand.windowName`）。
        appName: AppBrand.windowName,
        version: version.name,
        buildNumber: version.buildNumber,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
