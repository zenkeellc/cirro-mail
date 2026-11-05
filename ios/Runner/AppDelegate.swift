import Flutter
import UIKit
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 应用图标角标通道（Dart 侧 `lib/core/notify/icon_badge.dart`）。
  ///
  /// 存成属性而不是注册完就丢：FlutterMethodChannel 的 handler 虽然挂在
  /// messenger 上，但 Flutter 官方插件一律由 registrar 持有通道对象；留一个
  /// 强引用既符合惯例，也让「AppDelegate 到底注册了什么」有据可查。
  private var iconBadgeChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 后台任务的标识符必须在 App 启动期间登记给 BGTaskScheduler，
    // 否则系统在重新拉起 App 时根本不会把任务投递过来
    // （`registerPeriodicTask(withIdentifier:)` 的文档原话：
    // "This method must be called during app initialization"）。
    //
    // 这一个字符串在上游三处必须完全一致，改一处就要一起改：
    //   1. 这里；2. Info.plist 的 BGTaskSchedulerPermittedIdentifiers；
    //   3. Dart 侧 `BackgroundSyncTask.uniqueName`。
    // 对不上不会有任何警告 —— 系统只会在启动时直接抛一个
    // "BGTaskSchedulerErrorDomain" 的崩溃，或者干脆永远不唤醒。
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: "cloudmail.periodicSync")

    // 这个 App 用的是 UIScene（见 SceneDelegate.swift + Info.plist 的
    // UIApplicationSceneManifest）。插件的注释里点名了这种情况：
    // 场景化 App 里 `didFinishLaunching` 在场景连接之前就返回了，
    // 插件自己的 application 回调来不及把 launch handler 重新登记上，
    // 所以必须由 AppDelegate 显式补一句。
    WorkmanagerPlugin.registerLaunchHandlers()

    // 后台任务跑在**另一个** Flutter 引擎里（`BackgroundWorker.swift` 建的），
    // 那个引擎没有 GeneratedPluginRegistrant 的调用点，插件要靠这个回调
    // 手工注册。不给的话，后台 isolate 里 shared_preferences /
    // flutter_secure_storage / path_provider 全是 MissingPluginException ——
    // 而我们的后台同步正是靠这几个读 token 和偏好设置的。
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 未读数字角标通道。
    //
    // 为什么注册点在这里、而不是上面那段启动初始化里：这个 App 用
    // UIScene + storyboard 隐式引擎，`didFinishLaunching` 返回时引擎可能
    // 还没建出来，拿不到 binaryMessenger；
    // `didInitializeImplicitFlutterEngine` 是引擎就绪后系统给的唯一时机 ——
    // FlutterEngine.h 里 `FlutterImplicitEngineDelegate` 的注释原话就是
    // 在这里注册 "application-level method channels"。
    //
    // messenger 用 `engineBridge.applicationRegistrar`（引擎/应用级），
    // 不是某个插件的 registrar：这条通道不属于任何插件。
    let channel = FlutterMethodChannel(
      name: "com.zenkee.cirromail/badge",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setBadge" else {
        // 旧构建 / 其他平台多出来的方法：明确回不支持，Dart 侧 catch 后
        // 静默跳过（见 `IconBadge.set` 的注释）。
        result(FlutterMethodNotImplemented)
        return
      }
      // 参数是 map {"count": int}；缺失/类型不对按 0（清除）处理 ——
      // 角标是装饰，不值得为一次参数异常让 Dart 侧拿到 error。
      let count = (call.arguments as? [String: Any])?["count"] as? Int ?? 0
      self?.setApplicationIconBadge(count)
      result(nil)
    }
    iconBadgeChannel = channel
  }

  /// 把未读总数写到桌面图标角标上；count <= 0 表示清除。
  ///
  /// 重要：iOS 的角标**依赖通知授权**。Dart 侧
  /// `lib/features/notifications/notification_service.dart` 申请权限时带了
  /// `badge: true`；用户允许之后这里写数字才会显示。用户拒绝通知权限、或者
  /// 在系统设置里单独关掉「标记 App 图标」时，下面两条路径都会被系统
  /// **静默忽略**（不报错、不显示）—— App 侧没有可靠手段探测，也不需要
  /// 重试，这是系统行为，不是实现漏洞。
  ///
  /// 所以「一直显示」在 iOS 上要打一个折扣：没授权就没有角标。本 App 只在
  /// 两个时机申请通知权限 —— 用户主动开推送（`push_service.dart`）、第一封
  /// 新信要弹通知时（`notification_service.dart` 的 `ensurePermission`）。
  /// 首装且未授权时，桌面图标上不会出现数字，要等上面任一时机用户点了
  /// 「允许」。见 `docs/icon-badge.md` 的 iOS 一节。
  private func setApplicationIconBadge(_ count: Int) {
    let value = max(0, count)
    if #available(iOS 16.0, *) {
      // iOS 16 起有了官方 API：不要求 App 在前台，系统自己把数字落到图标上。
      // 没授权时回调里给的是 "Notifications are not allowed for this
      // application"，这是预期内的 —— 只在 Debug 里打一行，真机上不然连
      // 「为什么没角标」都查不到。
      UNUserNotificationCenter.current().setBadgeCount(value) { error in
        #if DEBUG
          if let error = error {
            NSLog(
              "Cirro Mail: 设置图标角标失败（多半是通知未授权）：%@",
              error.localizedDescription)
          }
        #endif
      }
    } else {
      // iOS 16 以前没有官方入口，只能直接改 UIApplication 的属性。
      // 该属性要求主线程（method channel 的 handler 本来就在主线程，
      // 这里再 dispatch 一次只是为了将来若从别的队列调用也安全）。
      DispatchQueue.main.async {
        UIApplication.shared.applicationIconBadgeNumber = value
      }
    }
  }
}
