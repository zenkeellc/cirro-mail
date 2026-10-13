import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
  }
}
