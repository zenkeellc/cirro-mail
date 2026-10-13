import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面端那个「关掉窗口但 App 还在后台活着」的外壳，从 Dart 这一侧能做的
/// 那一件事：**把主窗口叫回来**。
///
/// macOS 走 `NSStatusItem`（菜单栏），Windows 走托盘（任务栏通知区），Linux
/// 走顶栏图标的 StatusNotifierItem / `GtkStatusIcon`，三边是同一个东西的三个
/// 平台实现。通道名和方法名**三边逐字一样**，所以 Dart 只需要这一份代码。
///
/// 为什么需要它（而不是只靠原生侧那几个回调）：点系统通知时，桌面系统会把
/// App 激活，但桌面版的推送不像手机上那样自带「打开某个界面」的语义 ——
/// 屏幕上什么都不会发生（macOS 的 `applicationShouldHandleReopen` 只覆盖
/// 「点 Dock 图标」那一路；Windows 的托盘更是在用户自己点之前完全没有窗口）。
/// 而用户真正想看到的是**点开的那封信**，导航只有 Dart 侧知道。所以点通知这
/// 条路上，Dart 先把这个调用打过去把窗口拉起来，再 `router.go(...)`。
///
/// 反向域名用的就是 bundle id（`com.zenkee.mailapp`），和原生侧注册的那个
/// 字符串必须逐字一致 —— macOS 在 `macos/Runner/AppDelegate.swift`，Windows 在
/// `windows/runner/flutter_window.cpp`，Linux 在
/// `linux/runner/my_application.cc`。
///
/// 非桌面平台、以及原生侧还没跟上（旧构建）时，这里全是**静默空操作** ——
/// 窗口起不来是小事，因为「叫窗口」失败而把导航也带崩才是大事。
abstract final class WindowChannel {
  static const MethodChannel _channel =
      MethodChannel('com.zenkee.mailapp/window');

  /// 把主窗口显示出来并抢到前台。窗口本来就开着时是幂等的。
  static Future<void> show() async {
    if (kIsWeb || !_isDesktop) return;
    try {
      await _channel.invokeMethod<void>('showMainWindow');
    } catch (_) {
      // 原生侧没有这个方法 / 通道没接上 —— 不值得把调用方也拖下水。
    }
  }

  /// 把主窗口藏起来，App 留在菜单栏 / 托盘里继续收信（`Cmd/Ctrl+W`）。
  ///
  /// ## 为什么是「藏起来」而不是「退出」
  ///
  /// 这个 App 的窗口关闭按钮**本来就是**这个语义：三个桌面的 runner 都把
  /// 关窗改成了藏窗（macOS 的 `applicationShouldTerminateAfterLastWindowClosed`
  /// 返回 false + `window.orderOut`、Windows 的 `WM_CLOSE` → `HideToTray`、
  /// Linux 的 `delete-event` 返回 TRUE + `gtk_widget_hide`）。
  /// `Cmd+W` 只是给同一条路径加一个键盘入口 —— 如果它做成退出，用户会得到
  /// 一个「按了 `Cmd+W` 收信就全停了」的 App，而那条原生路径还在。
  ///
  /// 与 [show] 一样是静默空操作：非桌面平台、旧构建、通道没接上都不抛。
  static Future<void> hide() async {
    if (kIsWeb || !_isDesktop) return;
    try {
      await _channel.invokeMethod<void>('hideMainWindow');
    } catch (_) {
      // 同上：藏窗失败不值得把按键那一路也带崩。
    }
  }

  static bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}
