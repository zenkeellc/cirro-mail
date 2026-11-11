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

  /// 图标徽章那条通道（Dart 侧 `lib/core/notify/icon_badge.dart`）。
  ///
  /// 与 `windowChannel` 一样必须强持有 —— 通道对象一释放，挂在上面的 handler
  /// 就跟着没了，表现是「未读数变了但角标永远不动」。
  ///
  /// **单独一条通道**而不是塞进 `windowChannel`：那条的名字叫 window，语义是
  /// 「桌面外壳的窗口能力」；徽章在手机上（iOS）也走同一个 Dart 类，塞进
  /// window 通道会让 iOS 那边继承一个名不副实的名字。见 [setUpBadgeChannel]。
  private var badgeChannel: FlutterMethodChannel?

  /// 给 Dart 侧的桌面外壳能力（目前只有「在 Finder 里显示附件」）。
  ///
  /// 与 `windowChannel` 一样必须强持有：通道一释放，handler 就没了。
  /// 见 `lib/core/storage/attachment_launcher.dart` 的 `revealInFileManager`
  /// —— Windows / Linux 在 Dart 侧拉系统命令，macOS 走这条原生通道
  /// （App 是沙盒的，`NSWorkspace.activateFileViewerSelecting` 才是正路）。
  ///
  /// 是**数组**：这条通道按「公开版前缀 + 当前 bundle id 前缀」各挂一条
  /// （见 [setUpDesktopChannel]），两条都得活着。
  private var desktopChannels: [FlutterMethodChannel] = []

  /// 关掉窗口之后用来顶着 App Nap 的那个「活动」。见 [updateWindowlessActivity]。
  private var windowlessActivity: NSObjectProtocol?

  /// 窗口外框（大小与位置）的 autosave 名字。
  ///
  /// `UserDefaults` 里的键是 `NSWindow Frame <这个名字>`。名字**两个检出逐字
  /// 相同**：公开版与商业版的 defaults 域本来就是各自的 bundle id（沙箱容器
  /// 也各自一份），同名不会互相踩，反而少一处品牌差异。见 [applicationDidFinishLaunching]
  /// 里设置它的那段注释。
  private static let mainWindowFrameAutosaveName = "CirroMainWindow"
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

    // **记住窗口的大小与位置。** 这件事交给 AppKit 的 frame autosave，而不是
    // 自己存一份 CGRect：
    //
    // - 它把外框写进本 App 的 `UserDefaults`（键 `NSWindow Frame CirroMainWindow`），
    //   并且**在设置名字的这一刻就把存下来的 frame 套上去** —— 所以这行必须在
    //   下面 `showMainWindow()` 之前。放到显示之后，用户会先看见窗口弹在 nib
    //   里那个默认位置、再跳一下。
    // - 保存也是 AppKit 自己管的：窗口被拖/被缩放、以及关窗时它都会写回，
    //   不用另挂 `windowDidMove` / `windowDidResize` 观察者。
    // - 窗口被拖到一块**已经拔掉**的显示器上时，AppKit 会在窗口上屏前用
    //   `constrainFrameRect` 把它挤回可见区域。自己存就得在三个平台各写一遍
    //   钳位逻辑（Windows / Linux 的 runner 就是这么做的，因为那边没有等价的
    //   现成机制）。
    //
    // 不恢复的是**全屏 / 缩放（绿按钮那两种）**：那是窗口管理器的状态，不在
    // frame 这条路上。见 `docs/window-state.md`。
    (retainedWindow ?? mainFlutterWindow)?
      .setFrameAutosaveName(Self.mainWindowFrameAutosaveName)

    setUpStatusItem()
    setUpWindowChannel()
    setUpBadgeChannel()
    setUpDesktopChannel()
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
    // `variableLength` 而不是 `squareLength`：有未读时要在信封旁边显示数字，
    // 方形槽位会把数字裁掉。没有未读时它照样缩到图标本身的宽度，外观不变
    // （见 [applyBadge]）。
    let item = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.variableLength)
    if let button = item.button {
      // 用 SF Symbol 而不是 App 图标：App 图标是彩色的、且不是 template，
      // 塞进菜单栏会又大又花；SF Symbol 会跟着浅/深色和菜单栏高亮自动反色。
      let image = NSImage(
        systemSymbolName: "envelope.fill",
        accessibilityDescription: statusItemLabel
      )
      image?.isTemplate = true
      button.image = image
      // 数字（如果此刻有未读）画在信封右侧，而不是盖在图标上：菜单栏图标是
      // template 单色图，覆盖一层红底白字会和系统配色打架。见 [applyBadge]。
      button.imagePosition = .imageLeading
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
    // 幂等：此刻 badgeCount 通常还是 0（Dart 侧还没推首帧的值），这一句是给
    // 「图标晚于通道被重建」这种理论情形兜底的。
    applyBadge(badgeCount)
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
      name: "com.zenkee.cirromail/window",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      // 三个方法共用一条通道：`showMainWindow`（点通知时把窗口叫起来）、
      // `hideMainWindow`（`Cmd+W` 藏窗）与 `setWindowTitle`（标题栏显示版本）。
      // **不是**三条通道 —— 通道名是 Dart 侧 [WindowChannel] 的一个常量，
      // 多开一条就要多维护一处字符串。
      guard call.method == "showMainWindow" || call.method == "hideMainWindow"
        || call.method == "setWindowTitle" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // 通道回调不保证落在主线程上，而 AppKit 只认主线程。
      DispatchQueue.main.async {
        switch call.method {
        case "showMainWindow":
          self?.showMainWindow()
        case "hideMainWindow":
          self?.hideMainWindow()
        default:
          // 与上面两个无参方法不同，这条的参数是 map（`{"title": ...}`）。
          let arguments = call.arguments as? [String: Any]
          if let title = arguments?["title"] as? String, !title.isEmpty {
            self?.setWindowTitle(title)
          }
        }
        result(nil)
      }
    }
    windowChannel = channel
  }

  // MARK: - 图标徽章

  /// 图标徽章（Dock 角标 + 菜单栏数字）当前的未读数。
  ///
  /// 单独记一份而不是每次从 `badgeLabel` 里读回来：菜单栏与 Dock 是两个落点，
  /// 统一从这一个值画出去；而且图标被重建（理论上不会）时要能补画。
  private var badgeCount = 0

  /// 把「未读数」推到两个系统落点：
  /// - **Dock 图标角标**：`NSApp.dockTile.badgeLabel`，就是用户说的「数字徽章」；
  /// - **菜单栏信封图标右侧的数字**：`NSStatusItem.button.attributedTitle`。
  ///
  /// 0 表示**清除**（`badgeLabel = nil` + 空标题）。超过 99 显示 `99+`：
  /// Dock 角标与菜单栏都放不下三位数。
  private func applyBadge(_ count: Int) {
    let value = max(0, count)
    badgeCount = value

    // `nil` 才是「没有角标」；空串在部分 macOS 版本上会画一个空胶囊。
    NSApp.dockTile.badgeLabel = value > 0 ? badgeText(value) : nil

    guard let button = statusItem?.button else { return }
    button.attributedTitle =
      value > 0
      ? NSAttributedString(
        string: " " + badgeText(value),
        attributes: [
          // 11pt：菜单栏高度 22pt，这是带数字的菜单栏应用通行的字号。
          .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
          // 动态系统色：菜单栏浅/深色下各自解析成黑/白。菜单栏按钮的
          // `effectiveAppearance` 带 vibrant 语义，颜色是画的时候才解析的。
          .foregroundColor: NSColor.labelColor,
        ])
      : NSAttributedString(string: "")
    button.toolTip = unreadTooltip(value)
  }

  /// 角标/菜单栏上的文字。上限 99：三位数在 Dock 角标里会被裁成「…」。
  private func badgeText(_ count: Int) -> String {
    count > 99 ? "99+" : "\(count)"
  }

  /// 图标悬停提示。没有未读时保持原来的产品名。
  private func unreadTooltip(_ count: Int) -> String {
    guard count > 0 else { return statusItemLabel }
    return prefersChinese
      ? "\(statusItemLabel) — \(count) 封未读"
      : "\(statusItemLabel) — \(count) unread"
  }

  /// 图标徽章那条通道的 macOS 实现（Dart 侧 `lib/core/notify/icon_badge.dart`）。
  ///
  /// 为什么单独一条通道、而不是并进 `windowChannel`：那条的语义是「桌面外壳
  /// 的窗口能力」，而徽章在 iOS 上也存在（同一个 Dart 类），塞进去等于让 iOS
  /// 继承一个名不副实的通道名。方法名与参数格式（`{"count": int}`）五个平台
  /// 完全一致，Dart 侧只写一份。
  ///
  /// 失败一律静默：Dart 侧本来就吞 `MissingPluginException`，这边也不许因为
  /// 图标没建好、系统不认某个 API 就把通道回调挂住 —— 徽章是装饰。
  private func setUpBadgeChannel() {
    guard let window = retainedWindow ?? mainFlutterWindow,
      let controller = window.contentViewController as? FlutterViewController
    else { return }
    let channel = FlutterMethodChannel(
      name: "com.zenkee.cirromail/badge",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setBadge" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // 参数是 map `{"count": int}`（Dart 的 int 到这边是 NSNumber）。
      let arguments = call.arguments as? [String: Any]
      let count = (arguments?["count"] as? NSNumber)?.intValue ?? 0
      // AppKit 只认主线程；Dart 侧未读数一变就推一条，这里不能阻塞。
      DispatchQueue.main.async {
        self?.applyBadge(count)
        result(nil)
      }
    }
    badgeChannel = channel
  }

  /// 「在 Finder 里显示附件」这条通道的 macOS 实现。
  ///
  /// 为什么非原生不可：本 App 开了 **App Sandbox**（见 `Release.entitlements`），
  /// 而 Dart 侧能想到的两条野路子在这个沙盒里都不可靠 ——
  /// `Process.run('open', ['-R', …])` 要自己 fork 一个子进程，
  /// `url_launcher` 的 `file://` 只能打开目录、选不中文件。
  /// `NSWorkspace.activateFileViewerSelecting` 是唯一既能选中文件、
  /// 又完全不需要额外 entitlement 的做法。
  ///
  /// 参数是 `{"path": String}`（Dart 侧 `AttachmentLauncher` 传的是**另存为**
  /// 之后的目标路径，位于用户自己选的目录里 —— 沙盒对它有临时授权）。
  private func setUpDesktopChannel() {
    guard let window = retainedWindow ?? mainFlutterWindow,
      let controller = window.contentViewController as? FlutterViewController
    else { return }

    // **这个工程有两个检出，共用同一份 Dart 核心，bundle id 却不一样**
    // （公开版是 `com.zenkee.cirromail`，另一个检出在它后面带后缀）。
    // 核心代码里不该出现那一个的标识符（公开仓库有 `no-commercial-refs` 在扫），
    // 所以 Dart 侧固定用公开版前缀，原生这侧按**当前** bundle id 再挂一条：
    // 两个名字共用同一个 handler，谁在用都能对上。
    let bundleId = Bundle.main.bundleIdentifier
    let names: [String] = [
      "com.zenkee.cirromail/desktop",
      bundleId.map { "\($0)/desktop" } ?? "com.zenkee.cirromail/desktop",
    ]

    let handler: FlutterMethodCallHandler = { call, result in
      guard call.method == "revealInFileManager" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let arguments = call.arguments as? [String: Any]
      guard let path = arguments?["path"] as? String, !path.isEmpty else {
        result(false)
        return
      }
      // AppKit 只认主线程。
      DispatchQueue.main.async {
        let url = URL(fileURLWithPath: path)
        // 文件已经不在了（用户自己删了/目录被清）就别把 Finder 叫起来了。
        guard FileManager.default.fileExists(atPath: url.path) else {
          result(false)
          return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        result(true)
      }
    }

    for name in Set(names) {
      let channel = FlutterMethodChannel(
        name: name,
        binaryMessenger: controller.engine.binaryMessenger
      )
      channel.setMethodCallHandler(handler)
      desktopChannels.append(channel)
    }
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

  /// 改原生标题栏的文字（Dart 侧 `WindowTitleHost` 在版本解析出来后调一次）。
  ///
  /// 取窗口的口径与 [showMainWindow] / [hideMainWindow] 一致
  /// （`retainedWindow ?? mainFlutterWindow`）：`mainFlutterWindow` 是 weak 的
  /// IBOutlet，窗口藏起来之后它可能已经变 nil，而标题要一直对到退出为止。
  private func setWindowTitle(_ title: String) {
    guard let window = retainedWindow ?? mainFlutterWindow else { return }
    retainedWindow = window
    window.title = title
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
