import Cocoa
import FlutterMacOS
import firebase_messaging

@main
class AppDelegate: FlutterAppDelegate {
  /// 菜单栏图标。**必须自己强引用** —— `NSStatusBar.system.statusItem` 不替
  /// 调用方持有它，存成局部变量的话图标下一次 runloop 就消失了。
  private var statusItem: NSStatusItem?

  /// 主窗口的强引用。
  ///
  /// `FlutterAppDelegate.mainFlutterWindow` 是 **weak** 的 IBOutlet：窗口关掉
  /// 之后那份引用随时可能变 nil，再想 `makeKeyAndOrderFront` 就没东西可点。
  /// nib 里这个窗口是 `releasedWhenClosed="NO"`（不会被销毁），所以这里自己
  /// 再持一份就够了 —— 这是「关窗不退出」这条行为的支点。
  private var retainedWindow: NSWindow?

  /// Dart 那一侧用来「把窗口叫回来」的通道，必须强持有：通道对象一释放，
  /// 挂在上面的 handler 就跟着没了。
  ///
  /// 它兜住的是**点通知**那条路 —— 系统会激活 App，但桌面版推送不像手机上
  /// 那样自带「打开某个界面」的语义。见 `lib/core/storage/window_channel.dart`
  /// （Windows 那侧注册的是同名同方法的通道，两边共用那一份 Dart）。
  private var windowChannel: FlutterMethodChannel?

  /// 关掉窗口之后用来顶着 App Nap 的那个「活动」。见 [updateWindowlessActivity]。
  private var windowlessActivity: NSObjectProtocol?
  /// 关掉窗口后 App 不许跟着退。这是「留在菜单栏」的**前提**：只要它还返回
  /// true，下面那套菜单栏图标根本没有机会存在。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // **先判「是不是已经有一份在跑了」。** 位置在这里是有原因的，别往上挪也
    // 别往下挪：
    //
    // - 往上挪不了：`MainMenu.xib` 是在 `NSApplicationMain` 的顶层代码阶段
    //   （`applicationWillFinishLaunching` 之前）load 的，窗口那时候就已经
    //   建出来了；`FlutterViewController` 也是 nib 里那个 `MainFlutterWindow`
    //   在 `awakeFromNib` 里建的。所以「在建引擎之前就退出」这件事在本方法
    //   之前做不到 —— 要做到得手写 `main.swift` 并自己 load nib，代价太大。
    // - 往下挪不行：这个方法紧接着就会把窗口放出来（末尾那句
    //   `showMainWindow()`）。放在那之后，第二份进程就会先弹一下窗口再消失。
    //
    // 走到失败分支时，对面那份实例已经被请求过「把窗口摆到前面」了
    // （`SingleInstance` 里做了两件事：`activate` + 一条分布式通知），
    // 我们直接退出就行。
    guard SingleInstance.acquireAndWakeIfSecond() else {
      exit(EXIT_SUCCESS)
    }

    // **不要在这里调 `super`。** 本工程实测这一版的 `FlutterAppDelegate`
    // 里那个方法不返回（先调它，下面这些代码一行都跑不到，菜单栏图标就建
    // 不出来，App 看上去像卡在启动里）。引擎自己要做的启动工作在
    // `applicationWillFinishLaunching` 里已经做完了 —— 那个方法
    // `FlutterAppDelegate` 确实实现了，而且早于这里。
    retainedWindow = mainFlutterWindow
    setUpStatusItem()
    setUpWindowChannel()
    setUpWindowObservers()
    updateWindowlessActivity()

    // 上面那个 `setUpWindowObservers` 之外的另一条唤醒路径：**另一个进程**
    // （用户又跑了一次 `mail_app`，或者 `open -n`）在请我们把窗口摆到前面。
    //
    // 为什么不能只靠 `NSRunningApplication.activate`：本机探针实测，**关掉窗口
    // 之后 App 仍然是「前台那个」**，此时对面调 `activate` 返回 true，而这里
    // 一个回调都收不到（`applicationDidBecomeActive` 不触发，因为 App 本来就是
    // 活跃的）。分布式通知这条路不挑前台状态，照样送到。
    //
    // 观察**不需要**任何 entitlement，沙箱下照常工作（投递方要绕开
    // `NSDistributedNotificationCenter`，原因见 `SingleInstance` 文件头）。
    // 通知的名字与发送方共用 `SingleInstance.showWindowNotification` 一个常量。
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(showMainWindow),
      name: SingleInstance.showWindowNotification,
      object: nil
    )

    // 首屏。`MainMenu.xib` 里那个窗口写的是 `visibleAtLaunch="NO"` —— 不能让它
    // 自己在 nib 加载时冒出来，否则**第二个进程也会先弹一下窗口再退出**（nib 是
    // 在 `NSApplicationMain` 顶层代码阶段 load 的，比上面那个守卫早约 100ms，
    // 本机实测）。所以显示改由这里负责，而且只在守卫通过之后。
    showMainWindow()
  }

  /// 点 Dock 图标（或 Finder 里再开一次）时把窗口带回来。
  ///
  /// 这条和下面的 [applicationDidBecomeActive] 是**互补**的，不是重复：
  /// 关掉窗口时 App 仍然是活跃的那个，于是点 Dock 图标不会触发
  /// `didBecomeActive`，只有这个回调会来。
  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      showMainWindow()
    }
    return true
  }

  /// App 被激活时，如果没有可见窗口就补一个出来。
  ///
  /// 这条覆盖的是**点通知**：系统会激活 App，但桌面版不像 iOS 那样自带
  /// 「打开某个界面」的语义 —— 用户点了邮件通知，屏幕上却什么都没发生，
  /// 只会以为 App 卡死了。Cmd-Tab 切回来也算同一种情况。
  override func applicationDidBecomeActive(_ notification: Notification) {
    super.applicationDidBecomeActive(notification)
    if let window = retainedWindow ?? mainFlutterWindow, !window.isVisible {
      showMainWindow()
    }
  }

  // MARK: - 远程通知（后台收信）

  /// App **不在前台**时收到远程通知。
  ///
  /// ## 为什么得在这儿写一遍
  ///
  /// `FLTFirebaseMessagingPlugin` 自己实现了这个方法（`FLTFirebaseMessagingPlugin.m`），
  /// 里面按 `NSApp.isActive` 分叉发 `Messaging#onMessage` / `Messaging#onBackgroundMessage`。
  /// 但在 macOS 上那段是**死代码**，因为这个方法在 `NSApplicationDelegate` 里是
  /// **可选的**、只有 delegate 自己实现了系统才会调：
  ///
  /// - `FlutterAppDelegate` 没实现它（框架里 16 个实例方法，不含这个）；
  /// - macOS 版框架也没有 `FlutterPluginAppLifeCycleDelegate` 那种转发器；
  /// - `GULAppDelegateSwizzler` 在 macOS 上只代理
  ///   `didRegisterForRemoteNotificationsWithDeviceToken:` /
  ///   `didFailToRegisterForRemoteNotificationsWithError:`，plain 这个连 donor
  ///   都没有（`fetchCompletionHandler` 那一支整段被 `#if !TARGET_OS_OSX` 排掉）。
  ///
  /// 于是 `NSApp.delegate` 不响应该选择器 → 系统根本不调用 → 插件那段永远进不去。
  /// 这里把它接上，再原样转给插件：解码（`remoteMessageUserInfoToDict:`）、
  /// `gcm.message_id` 判定、与 `getInitialMessage()` 共享的初始通知状态机都在
  /// 插件里，自己另开一条通道就是第二套真相。
  ///
  /// ## 两个守卫
  ///
  /// - **`!NSApp.isActive`**：前台时 `willPresentNotification` 那条路已经发过一次
  ///   `Messaging#onMessage`（FCM 插件抢在 `flutter_local_notifications` 之后
  ///   拿到了 `UNUserNotificationCenter.delegate`），那边再走一遍就会重复投递。
  /// - **`gcm.message_id`**：只接 FCM 的推送，与插件内部同一个判据。
  ///
  /// `override` 是必须的：`FlutterAppDelegate` 声明了 `NSApplicationDelegate`
  /// 的一致性，于是这些**可选**协议方法在子类里实现时也算覆盖 —— 即便父类
  /// 自己一个都没写。父类没有实现，所以没有 `super` 可调。
  override func application(
    _ application: NSApplication,
    didReceiveRemoteNotification userInfo: [String: Any]
  ) {
    guard !NSApp.isActive else { return }
    guard userInfo["gcm.message_id"] != nil else { return }

    // 插件在公开头里只声明了 `+sharedInstance`；这个 delegate 方法只在 `.m`
    // 里实现，所以只能走运行时。`responds(to:)` 那一问是给「这份构建没带
    // Firebase」留的退路 —— 那种情况下什么也不做就是对的行为。
    let selector = NSSelectorFromString("application:didReceiveRemoteNotification:")
    let plugin = FLTFirebaseMessagingPlugin.sharedInstance() as AnyObject
    if plugin.responds(to: selector) {
      _ = plugin.perform(selector, with: userInfo)
    }
  }

  // MARK: - 菜单栏

  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      // 用 SF Symbol 而不是 App 图标：App 图标是彩色的、且不是 template，
      // 塞进菜单栏会又大又花；SF Symbol 会跟着浅/深色和菜单栏高亮自动反色。
      let image = NSImage(
        systemSymbolName: "envelope.fill",
        accessibilityDescription: statusItemLabel
      )
      image?.isTemplate = true
      button.image = image
      button.toolTip = statusItemLabel
    }

    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(
        title: openWindowLabel,
        action: #selector(showMainWindow),
        keyEquivalent: ""
      ))
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: quitLabel,
        action: #selector(quit),
        keyEquivalent: "q"
      ))
    // 目标显式指到 self。菜单栏图标那一支**没有窗口**，默认沿响应链找
    // action 的话响应链可能是空的 —— 表现就是「点下去毫无反应」。
    for menuItem in menu.items where !menuItem.isSeparatorItem {
      menuItem.target = self
    }
    item.menu = menu
    statusItem = item
  }

  // MARK: - 给 Dart 的通道

  /// 把「叫窗口」这件事开放给 Dart。
  ///
  /// 原生这几条回调（`applicationShouldHandleReopen` / `applicationDidBecomeActive`）
  /// 只能覆盖「用户主动回到 App」的路径，覆盖不了**点通知**：点通知时 App 确实
  /// 被激活了，但系统只给一个激活，不给「打开哪封信」的语义，而导航在 Dart 手里。
  /// 于是 Dart 在跳转前先通过这条通道把窗口叫起来。
  private func setUpWindowChannel() {
    guard let window = retainedWindow ?? mainFlutterWindow,
      let controller = window.contentViewController as? FlutterViewController
    else { return }
    let channel = FlutterMethodChannel(
      name: "com.zenkee.mailapp/window",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      // 两个方法共用一条通道：`showMainWindow`（点通知时把窗口叫起来）与
      // `hideMainWindow`（`Cmd+W` 藏窗）。**不是**两个通道 —— 通道名是
      // Dart 侧 [WindowChannel] 的一个常量，多开一条就要多维护一处字符串。
      guard call.method == "showMainWindow" || call.method == "hideMainWindow" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // 通道回调不保证落在主线程上，而 AppKit 只认主线程。
      DispatchQueue.main.async {
        if call.method == "showMainWindow" {
          self?.showMainWindow()
        } else {
          self?.hideMainWindow()
        }
        result(nil)
      }
    }
    windowChannel = channel
  }

  /// 藏窗（`Cmd+W`），语义与点窗口的关闭按钮、`Cmd+H` 都不同：
  ///
  /// - **不用 `NSApp.hide`（`Cmd+H`）** —— 那会把整个 App 藏到别的程序后面，
  ///   Dock 图标与菜单栏图标一起被收走，用户按 `Cmd+Tab` 回来时窗口还不一定在；
  /// - **不用 `performClose`** —— 那会走一遍 `windowShouldClose` / `willClose`，
  ///   而 `willClose` 那条路（`applicationShouldTerminateAfterLastWindowClosed`
  ///   那一套）我们已经在别处掌着，两处都动容易漂。`orderOut` 是「只把窗口
  ///   摘出屏幕」，不改任何 App 级状态。
  ///
  /// `orderOut` 之后 `isVisible` 变 false，于是现成的 `updateWindowlessActivity()`
  /// 会接着用 `NSProcessInfo.beginActivity` 顶着 App Nap —— 这正是「窗口不在
  /// 眼前也要继续轮询收信」需要的那一步。菜单栏那个 `NSStatusItem`（`:149` 那条
  /// `showMainWindow`）不受影响，点它能把窗口叫回来。
  @objc private func hideMainWindow() {
    guard let window = retainedWindow ?? mainFlutterWindow else { return }
    retainedWindow = window
    window.orderOut(nil)
    updateWindowlessActivity()
  }

  @objc private func showMainWindow() {
    guard let window = retainedWindow ?? mainFlutterWindow else { return }
    retainedWindow = window
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    // Cmd+H 藏起来的窗口，只调 makeKeyAndOrderFront 是不会出来的。
    NSApp.unhide(nil)
    window.makeKeyAndOrderFront(nil)
    // `activate(ignoringOtherApps:)` 从 macOS 14 起只是「将来会废弃」，
    // 在 12/13 上仍是唯一能越过当前前台 App 的写法 —— 所以两条都留着。
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    updateWindowlessActivity()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  // MARK: - 关窗之后的保活

  /// 窗口的可见性变化 → 决定要不要继续顶着 App Nap。
  ///
  /// 盯 `didMiniaturize`/`didDeminiaturize` 是因为**最小化也算「没有窗口在
  /// 眼前」**：此时轮询照样要在跑，但 App Nap 同样会来掐。关窗走 `willClose`
  /// （`isVisible` 要等这一轮结束才变 false，所以回调里让一步，下一轮再读）。
  /// `didBecomeKey` 覆盖「窗口被重新叫回来」。
  ///
  /// 观察者 token。**必须存着**：block 版 `addObserver` 返回的这个对象一旦
  /// 释放，观察就自动注销了 —— 存成局部变量的话，窗口一关这里根本收不到通知，
  /// 而且不报错。
  private var windowObservers: [NSObjectProtocol] = []

  private func setUpWindowObservers() {
    let center = NotificationCenter.default
    for name in [
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
      NSWindow.willCloseNotification,
      NSWindow.didBecomeKeyNotification,
    ] {
      let token = center.addObserver(
        forName: name,
        object: retainedWindow,
        queue: .main
      ) { [weak self] _ in
        // 让一步：`willClose` 触发时窗口还挂着，`isVisible` 这时读出来仍是
        // true。等这一轮事件处理完再读，才是关掉之后的状态。
        DispatchQueue.main.async { self?.updateWindowlessActivity() }
      }
      windowObservers.append(token)
    }
  }

  /// 窗口可见 ⇄ 放开保活。**幂等**，可以随便多调几次。
  ///
  /// 为什么需要它：关掉窗口之后 App 就是一个**没有窗口、没人看着**的常驻
  /// 进程，正是 App Nap 最想掐的那种 —— 它会把定时器和网络活动降到最低，
  /// 表现出来就是「关窗之后收信变成十几分钟才来一次」。这里显式声明一个
  /// userInitiated 级别的活动把 Nap 顶回去，窗口一回来就放开。
  ///
  /// 用 `.userInitiatedAllowingIdleSystemSleep` 而不是 `.userInitiated`：
  /// 后者会连**系统**空闲休眠一起拦住（合盖也不睡），为了收个邮件不值得。
  /// 这个选项的含义是「我很重要，但别拦系统休眠」。
  private func updateWindowlessActivity() {
    let windowVisible = (retainedWindow ?? mainFlutterWindow)?.isVisible ?? false
    if windowVisible {
      if let token = windowlessActivity {
        ProcessInfo.processInfo.endActivity(token)
        windowlessActivity = nil
      }
      return
    }
    guard windowlessActivity == nil else { return }
    windowlessActivity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep],
      reason: "Cirro Mail 在菜单栏后台收信"
    )
  }

  // MARK: - 文案（跟系统语言走，App 只支持中英两种）

  private var prefersChinese: Bool {
    (Locale.preferredLanguages.first ?? "").hasPrefix("zh")
  }

  private var statusItemLabel: String { "Cirro Mail" }

  private var openWindowLabel: String {
    prefersChinese ? "打开主窗口" : "Open Cirro Mail"
  }

  private var quitLabel: String {
    prefersChinese ? "退出 Cirro Mail" : "Quit Cirro Mail"
  }
}
