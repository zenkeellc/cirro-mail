import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/update/update_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../router.dart' as app_router;

/// 把「检查新版本」接进 App 的那一层。
///
/// 与 `NotificationHost` 同一个形状：包一层 `child` 原样返回，自己不画任何
/// 东西，只做两件事：
///
/// 1. 启动时调 [UpdateController.autoCheckIfDue]（开关 + 每天最多一次在
///    controller 里判断，这里不重复）；
/// 2. 有可用更新、且这个版本还没提示过时，用 `ScaffoldMessenger` 弹一条
///    SnackBar：动作「下载」直接交给系统浏览器（`LaunchMode.externalApplication`），
///    点提示文字「查看」去设置页（关于是最后一项）。
///
/// ## 挂在哪里
///
/// 必须挂在 **`MaterialApp.router` 里面**：它要 `ScaffoldMessenger`（由
/// `MaterialApp` 提供）和 `routerProvider`（导航）。这也意味着它比每个页面的
/// `Scaffold` 都早存在 —— SnackBar 挂在 App 级的 messenger 上，当前路由换了
/// 也不会被一起拆掉。
///
/// ## 为什么提示只出现一次
///
/// 判据在 [UpdateController.shouldNotify]：prefs 里记着「已经提示过的版本串」，
/// 同一个版本只提示一次；下个版本发布后清单里的版本串变了，提示自然重新出现。
/// 用户点「稍后」/ 关掉 SnackBar 不会清掉这个记录，否则每次冷启动都会再弹。
class UpdateHost extends ConsumerStatefulWidget {
  const UpdateHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdateHost> createState() => _UpdateHostState();
}

class _UpdateHostState extends ConsumerState<UpdateHost> {
  /// 同一帧里状态可能变化多次（比如手动检查 + 启动检查），用这个闸门保证
  /// 一次「发现新版本」只排一条 SnackBar。
  bool _notifyScheduled = false;

  @override
  void initState() {
    super.initState();
    // **必须延到首帧之后**：`check()` 一进去就同步把状态改成 checking，而在
    // initState / build 里改 provider 会被 riverpod 的调试断言拦下（生产里
    // 也可能导致 UI 状态不一致）。放到 post-frame 里既不拖慢首帧，也不在
    // build 期间碰 provider。
    //
    // 不 await：启动路径不该等一个网络请求，失败也只落在状态里，不影响
    // App 起来。真正到期的判断（开关 / 24 小时）在 controller 里。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(updateCheckProvider.notifier).autoCheckIfDue());
    });
  }

  @override
  Widget build(BuildContext context) {
    // 手动「检查」也会走到这里 —— 提示不只在启动那一次。
    ref.listen<UpdateCheckState>(updateCheckProvider, (previous, next) {
      if (next.status == UpdateCheckStatus.available) _scheduleSnackBar();
    });
    return widget.child;
  }

  /// SnackBar 只能在 build/frame 之后弹：`ref.listen` 的回调可能正好发生在
  /// 一次 build 里，直接 `showSnackBar` 会踩 `setState during build`。
  void _scheduleSnackBar() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!mounted) return;
      _maybeShowSnackBar();
    });
  }

  void _maybeShowSnackBar() {
    final state = ref.read(updateCheckProvider);
    final release = state.release;
    if (state.status != UpdateCheckStatus.available || release == null) return;

    final controller = ref.read(updateCheckProvider.notifier);
    if (!controller.shouldNotify) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    final l10n = AppLocalizations.of(context);
    final url = release.downloadUrlFor(defaultTargetPlatform);

    messenger.showSnackBar(
      SnackBar(
        // 12 秒：比默认 4 秒长一点 —— 这条消息里有个「下载」按钮，
        // 用户得来得及读完版本号并决定要不要点。
        duration: const Duration(seconds: 12),
        // SnackBar 只支持**一个** action，所以两个入口分开：
        // action = 下载（系统浏览器），点正文 = 查看（去设置页）。
        content: InkWell(
          onTap: _openSettings,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(l10n.updateAvailable(release.display)),
          ),
        ),
        action: SnackBarAction(
          label: url == null ? l10n.updateView : l10n.updateDownload,
          onPressed: url == null
              ? _openSettings
              : () => unawaited(_openDownload(url)),
        ),
      ),
    );

    // 弹出来才算「提示过」——没弹（没有 messenger / 已有版本记录）时不写，
    // 否则这次提示就永远丢了。
    unawaited(controller.markNotified());
  }

  /// 去设置页。
  ///
  /// 设置页的分类是页内状态、**没有独立路由**（`/settings` 只到分类首页，
  /// 见 `SettingsScreen` 的类注释），所以这里只能落到设置首页，用户再点
  /// 「关于」。等设置页支持 `?section=about` 之后，把这里换成深链即可。
  void _openSettings() {
    ref.read(app_router.routerProvider).go(app_router.Routes.settings);
  }

  Future<void> _openDownload(String url) async {
    try {
      await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      // 清单里的地址是不可信输入：打不开就静默记一行，不拦 App。
      debugPrint('打开更新下载地址失败 $url：$error');
    }
  }
}
