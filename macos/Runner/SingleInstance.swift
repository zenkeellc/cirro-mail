import Cocoa

/// 「同一份 App 只跑一个进程」的 **macOS 实现**，对应 Windows 的
/// `windows/runner/single_instance.{h,cpp}` 与 Linux 的
/// 「别带 `G_APPLICATION_NON_UNIQUE`」（`linux/runner/my_application.cc`）。
///
/// ## 为什么 macOS 也要做（它以前确实不用）
///
/// 三个平台的桌面壳都是「关窗不退出」：窗口关上只是藏起来，进程继续轮询收信、
/// 继续登记着推送。Windows 那边关窗后任务栏上看不见 App，Linux 那边桌面壳里也
/// 看不见，用户再从开始菜单点一次完全合理 —— 于是会开出第二个进程。macOS 以前
/// 靠 Dock 兜着（点 Dock 图标本来就只是激活已有的那一个），所以一直没做。
///
/// 但这条兜底**漏了两个入口**：
///
/// 1. **终端里直接跑可执行文件**（`flutter run` 就是这么启动的，开发时天天用）
///    —— 不经过 LaunchServices，Dock 那条路一步都走不到；
/// 2. `open -n`（强行新开一份）与任何绕过 LaunchServices 复用的启动方式。
///
/// 实测代价：真 App 已经在跑（关窗状态）时直接跑两次二进制，本机一次拿到
/// **3 个进程**，各自打开同一份 drift SQLite（库名是固定的，见
/// `lib/core/db/database.dart`）、各登记一份 FCM device
/// （`lib/core/storage/prefs_store.dart` 的 `cm_push_device_id`）、同一封信
/// 弹两遍通知 —— 症状与 `single_instance.h` 顶上描述的一字不差。
///
/// ## 两半分工，缺一不可（本机逐场景实测过）
///
/// | 入口 | 归谁管 |
/// |---|---|
/// | 点 Dock / Finder 双击 / `open` / `open -n` | `Info.plist` 的 `LSMultipleInstancesProhibited`（LaunchServices 自己复用已有实例，并触发 `applicationShouldHandleReopen`） |
/// | 终端直接 exec 二进制（含 `flutter run`） | **本文件**：抢 flock，抢不到就唤醒对面然后退出 |
///
/// 只做 plist 那一半，`flutter run` 之外的所有入口都堵住了；只做本文件这一半，
/// 点 Dock 那条路会绕过它（那个进程压根不会走到 `applicationDidFinishLaunching`）。
///
/// ## 为什么用 `flock` 而不是别的
///
/// - **不用 `NSDistributedLock`**：API 语义上已经过时（Apple 文档原话是
///   "typically for a short-lived lock"，还专门劝人别拿它当 App 的单例锁），
///   而且它要显式 `unlock()`，崩溃时留下的是陈旧锁文件。
/// - **不用 `CreateMutexW` 那种「具名内核对象」**：macOS 没有对等物。
/// - `flock(2)` 的锁**跟着文件描述符走、进程一死内核就释放**，不需要清理，
///   也没有陈旧状态。实测在沙箱容器里可用（锁文件落在容器内，天然按用户隔离）。
///
/// ## 唤醒对面为什么要两条路
///
/// 本机探针实测（`/tmp/cirro-sbx/`，见 README 那一段）：
///
/// - `NSRunningApplication.activate(options: [.activateAllWindows])` 是**主路**：
///   它走 LaunchServices 的激活，对面会收到 `applicationDidBecomeActive`。
/// - 但**关掉窗口之后 App 仍然是「前台那个」**，此时 `activate` 明明返回 true，
///   对面却**一个回调都不来**（实测：窗口 orderOut 之后 App 仍 active，
///   `activate` 之后第一条实例零日志）。这一路要用分布式通知补：
///   观察者装在 `AppDelegate` 上（见 `showWindowNotification`），投递不需要任何
///   entitlement，沙箱下照常工作。
/// - **投递必须用 `CFNotificationCenterPostNotification(GetDistributedCenter(), …)`**，
///   不能图省事用 `NSDistributedNotificationCenter.postNotificationName` ——
///   同一个中心，后者会被沙箱拦掉，表现是 stderr 一行 `thwarted by sandboxing`
///   而**不抛任何错**（`try?` 什么都看不出来），等于静默失效。
///
/// 发送与退出不必等对面回话：实测「投完立刻 `exit(0)`」对面照样收得到。
enum SingleInstance {
  /// 跨进程对暗号用的名字。与 Windows 的 `kShowMessageName`
  /// （`windows/runner/single_instance.cpp`）取同一个字符串 —— 两边指的是
  /// 同一件事，名字一致方便对读。
  static let showWindowNotification = NSNotification.Name(
    "com.zenkee.mailapp.show-window")

  /// 抢「第一个实例」的名分，顺手把「该唤醒谁」办掉。
  ///
  /// - 返回 `true`：本进程就是第一个，正常启动。
  /// - 返回 `false`：已经有一份在跑，**并且已经请求它把窗口摆到前面了**。
  ///   调用方应当立刻退出，别再建引擎 —— 见 `AppDelegate.applicationDidFinishLaunching`
  ///   开头那个 `guard`。
  ///
  /// 幂等：重复调用只判一次，第一次的结果就是结果。
  static func acquireAndWakeIfSecond() -> Bool {
    if state.checked {
      return state.isFirst
    }
    state.checked = true

    guard let fd = openLockFile() else {
      // 极端情况（容器目录建不出来、安全策略不让开文件）。**当作第一个放行**：
      // 让 App 因为这件事完全打不开，比偶尔多开一个进程糟糕得多。Windows
      // 那边 `CreateMutexW` 失败时是同一个取舍。
      state.isFirst = true
      return true
    }

    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
      // 抢到了。**故意不关这个 fd、也不解锁**：锁跟着 fd 走，关了锁就没了，
      // 紧接着启动的下一份会顺理成章地把自己当成第一个。进程退出时内核会
      // 替我们收拾 —— 那正是我们想要的时机（和 Windows 那边「故意不关
      // 互斥体句柄」是同一个道理）。
      state.isFirst = true
      return true
    }

    // 没抢到：`errno == EWOULDBLOCK` 是预期值（.app 内部 open 一次要数十毫秒，
    // 被两个进程**同时**抢到的窗口极窄）。别的 errno 也一并按「已经有一份」处理
    // —— 那时多开一个反而更糟，而唤醒是本文件唯一的补救手段。
    state.isFirst = false
    wakeRunningInstance()
    return false
  }

  /// 打开（必要时创建）锁文件，返回 fd。
  ///
  /// 路径取 `~/Library/Application Support/`：在沙箱里它落在
  /// `~/Library/Containers/com.zenkee.mailapp/Data/...`，天然按用户隔离，
  /// 也不需要任何 entitlement。**刻意不用 `/tmp`** —— 那会变成「全机器共用」，
  /// 同一台机器上另一个用户会话会被挡在外面（和 Windows 那条用 `Local\`
  /// 而不是 `Global\` 的理由一样）。
  private static func openLockFile() -> Int32? {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/cirro-mail", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("single-instance.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    return fd >= 0 ? fd : nil
  }

  /// 请已经跑着的那一份把窗口弄到前面来。**没有返回值**：发不到也没什么可做的，
  /// 调用方反正要退出了。
  private static func wakeRunningInstance() {
    // 主路：LaunchServices 激活。对面会收到 `applicationDidBecomeActive`。
    let running = NSRunningApplication.runningApplications(
      withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    for app in running where app.processIdentifier != getpid() {
      app.activate(options: [.activateAllWindows])
    }

    // 补路：对面本来就前台时 `activate` 不产生任何回调（见文件头的实测记录），
    // 而关窗状态的 App 恰好就是这种情况 —— 这时唯一的信号就是这条通知。
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDistributedCenter(),
      CFNotificationName(showWindowNotification.rawValue as CFString),
      nil, nil, true)
  }

  /// 进程级状态。
  ///
  /// **不能**写成 `private static var isFirst = false` 这种类型上的存储属性：
  /// Swift 的静态存储属性要初始化，而「初始化」这件事对 `@main` 类
  /// （`AppDelegate`）连带的一批存储属性是禁的。放进 `enum` 命名空间下的一个
  /// 全局变量就没有这个限制。
  private enum state {
    static var checked = false
    static var isFirst = false
  }
}
