import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 把「有多少封未读」这个数字推到**系统图标**上的那一条通道。
///
/// 用户看到的落点按平台不同，但语义只有一条：**图标旁边/上面那个数字 =
/// 全部实例的收件未读总数**（`totalUnreadProvider` 的口径，与聚合入口角标
/// 同一个数），归零就消失。
///
/// | 平台 | 图标在哪 | 原生实现 |
/// |---|---|---|
/// | macOS | Dock 图标角标 + 菜单栏信封图标旁的数字 | `macos/Runner/AppDelegate.swift` |
/// | Windows | 任务栏窗口图标 + 通知区托盘图标 | `windows/runner/flutter_window.cpp` 与 `tray_icon.cpp` |
/// | Linux | 顶栏托盘图标 + 启动器（Unity LauncherEntry）角标 | `linux/runner/my_application.cc` 与 `tray_icon.cc` |
/// | Android | 桌面启动器图标角标（按启动器能力尽力而为） | `android/app/src/main/kotlin/…/MainActivity.kt` |
/// | iOS | 桌面图标角标 | `ios/Runner/AppDelegate.swift` |
///
/// ## 三个约定（原生侧必须一致）
///
/// 1. **方法名 `setBadge`，参数是 map `{"count": int}`**，与窗口通道那条
///    `setWindowTitle` 的传参风格一致（以后要加「只显示点不显示数字」之类的
///    字段时不用换协议）。
/// 2. `count <= 0` 表示**清除**，不是「显示 0」。
/// 3. 一切失败都**静默**：旧构建的原生侧没有这个方法（`MissingPluginException`）、
///    桌面被裁掉图标、手机启动器不支持数字角标，都不该把调用方拖下水 ——
///    徽章是「有最好、没有也行」的装饰。原生侧同理：任何一步画不出图都
///    只是不显示，不许抛。
///
/// 为什么不引第三方包：五个平台的 runner 都在本仓库里（桌面三个还各自有
/// 托盘/菜单栏图标的既有实现），加一个只在 Android/iOS 用的插件反而多一层
/// 版本与权限面；而且桌面侧的落点（Dock 角标 + 菜单栏数字 / 任务栏图标）
/// 没有现成包能一次覆盖。通道名与五个 runner 注册的名字**逐字一致**，
/// 商业版检出只改下面这一行前缀（与 `window_channel.dart` 里
/// `WindowChannel.channelName` 同一规矩）。
abstract final class IconBadge {
  /// 通道名。反向域名跟 **bundle id** 走 —— 商业版检出把这一行换成自己的
  /// 前缀，五个 runner 里注册的字符串跟着一起换。
  static const String channelName = 'com.zenkee.cirromail/badge';

  static const MethodChannel _channel = MethodChannel(channelName);

  /// 把 [count]（未读总数）推给原生侧；0 表示清除。
  ///
  /// 负数按 0 处理：调用方不该传负数，但「清空」永远比「显示 -1」安全。
  static Future<void> set(int count) async {
    final value = count < 0 ? 0 : count;
    try {
      await _channel.invokeMethod<void>('setBadge', <String, Object?>{
        'count': value,
      });
    } catch (error) {
      // 旧构建 / 原生侧没接住 / 实现抛了 —— 全部吞掉。徽章丢一次不值得在
      // 日志里刷异常（下一次未读数变化会重新推一遍）。
      if (kDebugMode) {
        debugPrint('图标徽章：原生侧没有接住 setBadge，本次跳过：$error');
      }
    }
  }
}
