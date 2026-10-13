# Cirro Mail —— cloud-mail 多实例客户端

[cloud-mail](https://github.com/maillab/cloud-mail) 的 Flutter 客户端，Android / iOS / macOS / Windows / Linux 五平台共一份代码。

**简体中文** · [English](README.md)

应用显示名在所有语言和平台统一为 **Cirro Mail**。透明图标母版位于 `assets/branding/cirro-mail-master.png`；iOS 图标因平台要求导出为白底不透明 PNG，Android、macOS、Windows 和 Linux 使用透明图标或透明前景层。Android 包含五档普通、圆形和自适应图标；Linux 提供 16–512 像素的九档桌面主题图标。`mail_app` 仍是 Dart 包名和桌面可执行文件名。

它**不改动 `mail-worker`**，只用现有的 HTTP API 说话。配套的推送中转 Worker（`mail-push`）与 cloud-mail 服务端同属上游仓库，本项目只与它的 HTTP 接口对话。

## 它比网页端多什么

- **多实例**：可以同时存着自建实例和朋友给的实例，各自独立登录（各自一份 token），**所有实例同时收信**，合并成一条聚合时间线；也可以只筛某一个实例看。
- **原生推送**：外部来信可以推到手机通知栏，点通知直达那封信。走自建中转 Worker → FCM → Android / iOS(APNs)。**不需要**在实例上暴露任何端口。
- **附件**：下载、系统应用打开、分享、**应用内预览**（图片 / PDF / 文本 / Markdown / CSV / docx / xlsx / pptx / 音频 / 视频）、另存为、缓存占用查看与清理。Office 三种是**纯 Dart 本地解析**，文件不出机器（见下）。
- **大附件发送**：请求体是流式组装的，附件从磁盘分块编码，进程内存不会被 base64 撑爆（见下）。
- **按能力降级**：对着一个缺功能的旧版实例，缺的那块会隐藏或退化，而不是报错。
- **本地缓存**：邮件列表与正文落在本地 SQLite（drift），断网也能翻已经看过的信。

## 快速开始

需要 Flutter **3.47.7**（Dart 3.13.5；`pubspec.yaml` 里的依赖版本就是按这一版逐条核对的，见下方「依赖版本为什么是这几个数」）。

```bash
flutter pub get
flutter run -d <device>
```

第一次启动会让你填**实例地址**（自建就填自己的 `https://<你的域名>/api`；输入框默认留空，只给一条 `https://example.com/api` 的占位提示）→ 测连通性 → 登录。登录之后才能加第二个实例。

## 构建

```bash
flutter build apk --debug        # Android
flutter build ios --no-codesign  # iOS（签名要自己的账号）
flutter build macos --debug
flutter build windows            # 需在 Windows 上
flutter build linux              # 需在 Linux 上
```

`android/app/google-services.json` **不在仓库里**，也不影响构建 —— `android/app/build.gradle.kts` 会检测它是否存在，不存在就跳过 Google 服务插件并打一行提示。没有推送，其他功能都正常。

## 包名 / Bundle ID

包名是 `com.zenkee.mailapp`。**Firebase 控制台里填的包名必须与之逐字一致**，否则 `google-services.json` 放进去也不生效（Android 会**直接构建失败**并报 `No matching client found for package name`；Apple 侧则是运行时找不到默认 app）：

| 平台 | 标识符 | 改在哪 |
|---|---|---|
| Android | `com.zenkee.mailapp` | `android/app/build.gradle.kts` 的 `applicationId` / `namespace`；源码在 `android/app/src/main/kotlin/com/zenkee/mailapp/` |
| iOS | `com.zenkee.mailapp` | `ios/Runner.xcodeproj/project.pbxproj` |
| macOS | `com.zenkee.mailapp` | `macos/Runner/Configs/AppInfo.xcconfig` |
| Linux | `com.zenkee.mailapp` | `linux/CMakeLists.txt` 的 `APPLICATION_ID` |
| Windows | `com.zenkee.mailapp` | `windows/runner/Runner.rc` 的 `CompanyName`（版权行的持有人是公司名 ZENKEE LLC） |

五个平台一律 `com.zenkee.mailapp`。**Apple 不允许 bundle ID 带下划线** —— 注册 App ID / App Store Connect 只接受字母、数字、连字符和点，写 `ke.dong.mail_app` 会被直接拒（Xcode 本地构建也会打 `invalid character in Bundle Identifier`），所以是连写而不是 `mail_app`。

`-RunnerTests` 那几处（`com.zenkee.mailapp.RunnerTests`）是测试 target 的 bundle id，跟着一起改了。

⚠️ **`pubspec.yaml` 顶上的 `name: mail_app` 不是包名，别动它。** 那是 Dart package 名，所有 `import 'package:mail_app/...'` 都靠它，与应用标识符完全无关。

另外 `cloudmail.periodicSync` / `cloudmail.sync` 是 **workmanager 的任务标识符**，与包名无关。改它要四处同步（`background_sync_task.dart` 的两个常量、`AppDelegate.swift`、`Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers`），漏一处后台任务就静默不跑，所以**故意留着没动** —— 它只是个标识符，不对外暴露。

## Firebase 配置文件（已就位）

| 平台 | 文件 | 位置 | 读它的人 |
|---|---|---|---|
| Android | `google-services.json` | `android/app/` | Google 服务 Gradle 插件（把它编译成 `google_app_id` 等资源常量） |
| iOS | `GoogleService-Info.plist` | `ios/Runner/`，**已登记进 Xcode 工程** | `firebase_core` 在启动时从 bundle 里找 |
| macOS | `GoogleService-Info.plist` | `macos/Runner/`，**已登记进 Xcode 工程** | 同上 —— macOS 用的**就是** iOS 的那份 plist（`BUNDLE_ID` 与 macOS bundle id 相同，所以不需要单独的 macOS 应用） |

三份文件里的 `BUNDLE_ID` / `package_name` 都必须是 `com.zenkee.mailapp`，Firebase 控制台里建应用时填的也必须是这个。三份都提交进了仓库 —— 它们是可公开的客户端标识（FCM 就是这么设计的，密级与 `google_app_id` 相同），但换 Firebase 项目时要三个平台一起换。

⚠️ **从 Firebase 控制台下载 iOS 的 plist 后要检查 `BUNDLE_ID`。** 本项目的这份下载下来是 `con.zenkee.mailapp`（少了 m），已手工改正。

**光把 plist 放进目录是不够的** —— 它必须出现在 target 的 **Copy Bundle Resources** 构建阶段里才会被打进 `.app`，否则 `Firebase.initializeApp()` 在运行时报 `could not find default app`。这一步目前是靠手改 `project.pbxproj`（登记 4 处：`PBXBuildFile`、`PBXFileReference`、所在 group、Resources 阶段）完成的，不是 Xcode 点的。

## 推送需要你自己配的东西

**逐步的操作手册见 [`docs/push-setup.md`](docs/push-setup.md)**（App 的「设置 → 后台推送」是它的 App 内版 —— 那是一份**七页的分步向导**：① 状态 / ② 三条值 / ③ 开关 / ④ 登记 / ⑤ 实例后台 / ⑥ 检查 / ⑦ 说明与限制）。下面是这一节的三行摘要。

这部分代码里写不了，各是一处外部配置：

1. ~~建 Firebase 项目、放配置文件~~ —— **已完成**（见上一节；三份都在仓库里）。
2. **部署 `mail-push` + 配 FCM 服务账号** —— 见 [`docs/push-setup.md`](docs/push-setup.md) 第四节。App 里默认填的中转地址是 <https://push.zenkee.com>（自建部署可换成你自己的）；服务账号私钥由部署者自己走 `npx wrangler secret put FCM_SERVICE_ACCOUNT` 上传（整串 JSON，别往 `wrangler.toml` 的 `[vars]` 里加同名变量 —— 同名会让 `secret put` 直接失败）。
3. **在 App 里**填中转地址 `https://push.zenkee.com` + 实例位 + 配对码（向导第 ② 页）。配对码**同时就是**实例后台要填的 webhook secret，第 ⑤ 页会把它显示出来供复制。
4. **在实例后台**（「Webhook 推送」那一栏）填上第 ⑤ 页给出的 webhook 地址（带 `/<实例位>/webhook` 尾巴）与 secret，并把那一栏的开关拨开。这是整个链路里唯一必须在实例侧做的事 —— **注意那个开关在库里是 `webhookStatus`，`0` 才是「启用」**，字段名与直觉相反，所以「地址 secret 都填对了却收不到」的第一嫌疑永远是它。

### 仍然只能在 Xcode / Apple 开发者后台里做的

- **iOS 的 Push Notifications capability**：`aps-environment` entitlement 已经写进 `ios/Runner/Runner.entitlements` 并接到三个构建配置上了，但这条权利要生效得有匹配的 provisioning profile（**来自你自己的 Apple 开发者账号 —— 换成你的 Team ID**）。第一次真机跑时 Xcode 会去申请一份带 APS 的 —— 需要账号已登录、且 App ID 上开过推送。
- **macOS 的 Push Notifications capability**：和 iOS **不是同一套键名**。macOS 要 `com.apple.developer.aps-environment`（带 `com.apple.developer.` 前缀，写在 `macos/Runner/DebugProfile.entitlements` 与 `Release.entitlements` 里，Debug 用 `development`、Release 用 `production`）；iOS 那份写的裸 `aps-environment` 在原生 mac App 上会被 codesign 忽略。同样需要带推送的 **Mac** 描述文件 —— App ID 勾上开关后，Xcode 自动签名会自己申请一份 `Mac Team Provisioning Profile: com.zenkee.mailapp`（落在 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`）。缺描述文件时构建直接失败：`Provisioning profile ... doesn't include the Push Notifications capability`；缺 entitlement 时构建能过，但 `getToken()` 抛 `apns-token-not-set` —— **与通知权限无关**，别去系统设置里找。
- **Firebase 控制台里 iOS 应用要上传 APNs 密钥/证书**（项目设置 → 云消息 → APNs 身份验证密钥）。上传 Firebase 服务账号解决的是「中转端能否调 FCM」，这一条解决的是「FCM 能否把消息投给 APNs」，是两件事。
- **Apple 开发者后台打开 App ID 的 Push Notifications 开关**（`com.zenkee.mailapp` 这个 App ID —— iOS 与 macOS 共用同一个）。
- **分发的 macOS 构建还需要一份 Developer ID 描述文件**。现在 `Release.entitlements` 写的是 `production`，而**本机只有那一份 development 的 Mac 描述文件，所以实测产物里嵌的仍是 `development`**（`codesign -d --entitlements -` 看得到）—— 能构建、能注册，但那是开发环境的 APNs，本机跑 Release 没问题、发给别人用就投不到。外发/上架之前去后台建一份 Developer ID provisioning profile，那时产物才会真的变成 `production`。

### macOS 签名：`CODE_SIGN_IDENTITY` 得跟着 team 一起改

`macos/Runner.xcodeproj` 的 **project 级**配置里有一条 `CODE_SIGN_IDENTITY = "-"`（adhoc 签名）。
只在 target 上写 `DEVELOPMENT_TEAM = <你的 Team ID>` 是**没用的** —— 产物依旧是 `Signature=adhoc`、
`TeamIdentifier=not set`。三个 target 配置（Debug / Release / Profile）里都要再覆盖一句
`CODE_SIGN_IDENTITY = "Apple Development"`，产物才会带上 team（仓库里这三处的
`DEVELOPMENT_TEAM` 现为 `""`，等你在 Xcode 里选中自己的 Team 会自动填上）：

```
$ codesign -dv build/macos/Build/Products/Debug/mail_app.app | grep Team
TeamIdentifier=<你的 Team ID>      # 改之前是 not set
```

这一步不改也能本地跑（adhoc 签名本机可以用），只有分发 / 用带 APS 权利的 profile 时才看得出区别。

### macOS 沙箱：`com.apple.security.network.client` 是必需的

`flutter create` 生成的 macOS entitlements **只有 `network.server`**（那是给 Dart VM 调试服务用的），出站的 `network.client` 要自己加。少了它，沙箱下所有 HTTP 都会以 `errno 1 (Operation not permitted)` 失败 —— 而这个客户端全靠联网。

这不是「保险起见」：本机用一个最小 App 只做一次 `connect()` 实测过，沙箱 + 无 `network.client` → `CONNECT FAIL errno=1`，加上 → `CONNECT OK`，不加沙箱 → `CONNECT OK`。Debug 和 Release 两个 entitlements 文件里都已经补上了。

设置页里有一个**自检**按钮：它拿配对码去问中转端「实例后台该怎么填」，并对比你已经填进去的地址 —— 地址填错是**静默失败**（实例那边只有真收到外部来信时才会去打 webhook，打不通也只在自己日志里留一行），所以这一步值得点一下。向导里它是第 ⑥ 页那个「检查这条链路」（原来的「测试连接」与「自检」已合成这一个）。

⚠️ webhook 只覆盖**外部来信**。站内互发、别的客户端发的信都不触发它，只能靠轮询。实例若开了 `ruleType=RULE`，webhook 完全不触发。

### macOS：关掉窗口之后 App 还活在菜单栏里

macOS 上点红叉**不是退出**。`applicationShouldTerminateAfterLastWindowClosed` 返回 `false`，窗口关掉之后进程继续跑：菜单栏上留一个信封图标，点它弹出的菜单里有「打开主窗口 / 退出 Cirro Mail」两项，点 Dock 图标或 Cmd-Tab 切回来也会把窗口带回来。要退就显式退出（菜单栏菜单、`Cmd+Q`、Dock 右键）。

这条是**收信能不能持续**的前提，不是顺手加的装饰。桌面端进程原本一直活着，但「关窗即退」意味着关掉窗口那一刻轮询就断了，那段空窗期只有 FCM 推得到 —— 而 FCM 只覆盖**外部来信**（站内互发、别的客户端发的信都不触发 webhook），所以「关上窗口、等同事用另一个客户端发一封信」这种最普通的用法，音信全无。修好的效果是：关窗之后按设置里那个间隔照常收信、照常弹通知。

三处实现上的坑，都在 `macos/Runner/AppDelegate.swift` 里写着：

- **`applicationDidFinishLaunching` 里不能调 `super`**。本工程这一版的 `FlutterAppDelegate` 那个方法不返回（实测：先调它，后面建立菜单栏图标的代码一行都跑不到，界面表现是「卡在启动」）。引擎自己要做的启动工作在 `applicationWillFinishLaunching` 里已经做完了。
- **窗口要自己强引用一份**。`FlutterAppDelegate.mainFlutterWindow` 是 **weak** 的 IBOutlet，窗口一关就可能变 nil。nib 里的窗口是 `releasedWhenClosed="NO"`，所以自己持一份就够。
- **关窗之后要显式顶住 App Nap**。没有窗口、没人看着的进程正是 App Nap 最想掐的，表现是「关窗之后收信变成十几分钟才来一次」。窗口不可见时 `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep)`，窗口一回来就 `endActivity`。用这个选项而不是 `.userInitiated` 是因为后者连**系统**空闲休眠一起拦（合盖也不睡），为了收个邮件不值得。

Dart 这一侧对应的一条：`SyncController` 的 `_onPause` 在桌面端**直接返回**，什么都不做。不这样做的话，关窗会产生 `AppLifecycleState.hidden`，而下一轮同步成功又一定会写 `profiles` 表的 `lastSyncAt` → 触发 `build()` 重算 → 走到停调度器那一支。**窗口一关，收信就静默地死了**，菜单栏图标还亮着，用户只会以为它在后台跑。这条回归钉在 `test/desktop_sync_keepalive_test.dart`（同时钉住 Android 那条不被顺手改坏）。

还有一条只能手动验的路：点系统通知时，系统会激活 App 但**不像 iOS 那样自带「打开哪封信」的语义**，屏幕上什么都没发生。原生的 `applicationShouldHandleReopen`（点 Dock）与 `applicationDidBecomeActive`（App 被激活）都覆盖不到这条，因为导航在 Dart 手里。所以加了一条 `com.zenkee.mailapp/window` 通道（`lib/core/storage/window_channel.dart` ↔ `AppDelegate.setUpWindowChannel`），Dart 在跳转前先把窗口叫起来。

**只跑一个进程**。理由和上面 Windows 那条一模一样（关窗之后屏幕上找不到 App，用户再启动一次完全合理），但 macOS 这边的入口比 Windows 多、也比它藏得住 —— 这里要**两件套**，缺一个就从某个入口漏出第二个进程（`macos/Runner/SingleInstance.swift` 的文件头把取舍写全了）：

- **LaunchServices 那一半靠 `Info.plist` 的 `LSMultipleInstancesProhibited`**。点 Dock 图标、资源库 / Finder 里双击、`open`、`open -n` 全归它管：第二次启动不再起进程，而是把「再次打开」转给已经在跑的那一份（落进 `applicationShouldHandleReopen`）。刻意**不加** `LSUIElement` —— 那会把 Dock 图标一起收走，而点 Dock 正是把窗口叫回来的既有路径。
- **终端直接跑可执行文件那一半自己写**。`flutter run` 就是这么启动的（flutter_tools 走 `open`，但调试时人肉跑二进制、以及 `open -n` 都能绕开 LaunchServices），这部分 plist 管不着，靠 `flock(2)`：锁文件在 `~/Library/Application Support/cirro-mail/` 下（沙箱里落在容器内，天然按用户隔离），抢不到就请对面把窗口抬起来再自己退出。锁跟着文件描述符走、进程一死内核就释放，没有陈旧锁要清理 —— 也不用 `NSDistributedLock`（Apple 自己劝人别拿它当单例锁，崩了还会留脏文件）。
- **唤醒对面要两条路**。主路是 `NSRunningApplication.activate(options: [.activateAllWindows])`；但**关掉窗口之后 App 仍然是「前台那个」**，此时 `activate` 明明返回 true、对面却一个回调都不来，所以补一条分布式通知。投递必须用 `CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), …)` —— 同一个中心走 `NSDistributedNotificationCenter.postNotificationName` 会被沙箱**静默**拦掉（stderr 一行 `thwarted by sandboxing`，`try?` 什么都看不出来）；只**观察**这条通知不需要任何 entitlement。
- **窗口改成 `visibleAtLaunch="NO"`，首屏由守卫通过之后显式放**。因为 `MainMenu.xib` 是在 `NSApplicationMain` 的顶层代码阶段 load 的，比 `applicationDidFinishLaunching` 里的守卫早约 100ms；不关掉的话第二份进程会先闪一下窗口再消失。守卫也只能待在这里：往上挪不动（nib 与引擎都已建好），往下挪就是「先弹窗口再退出」。

几个跟 Windows 不一样的取舍：`Local\` ↔ 容器内路径（都是按用户隔离，不用 `/tmp` / `Global\` 那种全机器共用）；「抢锁失败时当作第一个放行」两边一致 —— 让 App 因为这件事完全打不开，比偶尔多开一个进程糟糕得多。

### Windows：关掉窗口之后 App 还活在通知区里

和 macOS 那条是同一件事的两个平台实现（Linux 是第三个，见下一节），只是 Windows 这边没有「Dock 图标」这种兜底 —— 从开始菜单再点一次会**开出一个新进程**，所以这里多做了一步单实例。

- **关窗不是退出**。点窗口的关闭按钮走的是 `WM_CLOSE`，在 `windows/runner/flutter_window.cpp` 里被截住，改成 `ShowWindow(SW_HIDE)`：窗口藏起来但**不销毁**，`FlutterViewController`（也就是引擎）继续活着，轮询和推送登记都照常。
- **图标是关窗那一刻才建的**。窗口还开着的时候通知区里没有它 —— 一个看得见的 App 不需要再占一格。图标旁边是右键菜单：「打开主窗口 / 退出 Cirro Mail」；左键直接打开窗口（桌面上这是个很难猜错的约定）。
- **「退出」走的是另一条路**：托盘菜单那一条会摘掉图标并 `DestroyWindow`，窗口真没了才触发 `PostQuitMessage` 退出进程。这是用户唯一的退出方式（任务栏上已经没有窗口可以右键了）。
- **只跑一个进程**。关窗之后任务栏上看不见 App，用户从开始菜单再点一次完全合理 —— 所以启动时先抢一个具名互斥体（`Local\com.zenkee.mailapp.single-instance`），没抢到就广播一条 `RegisterWindowMessage` 消息请那个已经在跑的实例把窗口摆到前面，然后自己退出。没有这一步的话两个进程会抢同一个 SQLite 库、各自登记一份 FCM token、同一封信弹两遍。

实现上几个不那么显然的地方（都在代码注释里）：

- **`WM_CLOSE` 的默认处理就是 `DestroyWindow`**，不拦的话窗口是真的被销毁了 —— `OnDestroy` 会把 `flutter_controller_` 一起释放，引擎停摆，用户以为「只是关了个窗口」，实际把收信关了。
- **关机时要放行**。关机流程最后会给每个顶层窗口发 `WM_CLOSE`，照样藏起来的话进度条会一直卡着等系统强杀（用户看到的是「点了关机之后半天没反应」）。所以 `WM_QUERYENDSESSION` 之后就走正常销毁，`WM_ENDSESSION` 带 `wParam == FALSE`（注销被取消）时要退回去 —— 不然「关窗进通知区」会在一次被取消的注销之后就悄悄失效，要重启才恢复。
- **托盘回调消息的参数布局有两套**。设了 `NOTIFYICON_VERSION_4` 时事件码在 `lParam` 低位，没设就在 `wParam` 低位。`NIM_SETVERSION` 的返回值要记下来、二选一，**不能两边都试**：v4 下 `LOWORD(wParam)` 是屏幕横坐标，x=514 的位置恰好等于 `WM_LBUTTONUP` 的数值，混着解会随机误触发。
- **`TrackPopupMenu` 之前必须 `SetForegroundWindow`**，否则菜单弹出来但点外面不关（MSDN 里专门提过这个经典 bug）。
- **Explorer 重启会静默清空通知区图标**，且不通知任何人。它只是广播一条 `TaskbarCreated`，所以那个消息要接住并把图标补回去 —— 用 `NIM_ADD` 而不是 `NIM_MODIFY`，因为已经在的图标补 `NIM_ADD` 是静默失败。
- **广播那一路要 `AllowSetForegroundWindow(ASFW_ANY)`**。Windows 的前台锁规则默认不允许后台进程抢焦点；不授权的话对面实例的 `SetForegroundWindow` 会被系统忽略，窗口出来了却还压在别人后面，用户看到的依旧是「点了没反应」。
- **`LoadImage` 而不是 `LoadIcon`**：`LoadIcon` 只会给最大的那一档，缩到 16×16 很糊。代价是拿到的句柄要自己 `DestroyIcon`。

冒烟自检：设环境变量 `CIRRO_SMOKE_MINIMIZE_TO_TRAY=1` 启动，首帧之后会自己走一次「关窗」路径（藏窗口 + 建托盘图标），用来在没法点鼠标的环境里确认引擎没被销毁。

⚠️ **这一段没有在本机验证过** —— 这台是 macOS，`flutter build windows` 跑不了（CI 也没验）。目前只做到：用 mingw-w64 交叉编译器把四个源文件 `-fsyntax-only -Wall -Wextra` 过了一遍（零错误零告警），以及 Dart 侧 `flutter analyze` 干净。「关窗进托盘 / 菜单两项 / 再次启动只开一个」这三条得在 Windows 上实际点一遍。

### Linux：关掉窗口之后 App 还活在顶栏里

第三个平台实现，行为和 Windows 那条对齐（macOS 是启动就挂图标，Linux/Windows 都是**第一次关窗时才出现**）：点窗口的关闭按钮只把窗口藏起来，顶栏上留一个图标，菜单里「打开主窗口 / 退出 Cirro Mail」，左键点图标直接开窗。

和 Windows 相比有两处是 Linux 自己的味道：

- **单实例不用自己写**。Windows 那边是抢具名互斥体，Linux 这边只要**别带 `G_APPLICATION_NON_UNIQUE`** —— 带上唯一 app id 之后，第二次启动会被 `GApplication` 通过会话 D-Bus 转到已经在跑的那个进程上，落进它的 `::activate`。`linux/runner/my_application.cc` 里 `activate` 开头那个「已经有窗口了就把窗口抬起来、直接返回」的分支就是接这件事的，**不能省**：少了它每次点桌面图标都会多开一扇窗。（flags 写字面量 `0` 而不是 `G_APPLICATION_FLAGS_NONE`：后者从 GLib 2.74 起废弃改名 `G_APPLICATION_DEFAULT_FLAGS`，而新名字在 Ubuntu 22.04 那种 GLib 2.72 上不存在，两个名字横竖要踩一个版本。）
- **「藏起来」是 `delete-event` 返回 `TRUE`**，对应 Windows 那边截 `WM_CLOSE`。返回 `TRUE` 把默认处理（销毁窗口）按住 —— `GtkApplication` 替自己的窗口持着主循环，窗口一被销毁进程就跟着走了，收信随之断掉。

顶栏图标有**两套后端，CMake 探到哪个用哪个**（`linux/runner/CMakeLists.txt` 里 `pkg_check_modules(APPINDICATOR QUIET IMPORTED_TARGET ...)`，探到就定义 `CIRRO_HAVE_AYATANA_APPINDICATOR`）。configure 时会打一行 `Tray icon: ...` 说明选中的是哪套：

| 后端 | 什么时候用 | 代价 |
|---|---|---|
| `libayatana-appindicator3` | 机器上有这个包（现代桌面的正路） | 多一个**可选**系统依赖 |
| `GtkStatusIcon` | 没探到时的兜底 | 已废弃；且 **GNOME 上根本不显示** |

GNOME 3.26 起把内置的状态栏图标整个去掉了，只有走 AppIndicator 协议才显示得出来（GNOME 上还要另外装 AppIndicator 扩展）。所以兜底那一支在 GNOME 上是**看不见图标**的 —— 有 X11/XFCE/MATE 这些桌面兜着，但这也是为什么 appindicator 那支优先。**`QUIET` 不能改成 `REQUIRED`**：那会让没装 `-dev` 包的机器连 `flutter build linux` 都过不去。

其余几个实现上的点：

- **菜单必须显式 `gtk_widget_show_all`**。appindicator 那一支**不走** `gtk_menu_popup`，它把菜单结构导出给 Shell 去渲染，那条路上没有谁替你 `show_all` —— 漏了这一步表现就是「菜单弹出来是空白」。
- **`Hide()` 和析构是两件事**。`Hide` 只是让 Shell 别显示（`APP_INDICATOR_STATUS_PASSIVE` / `set_visible(FALSE)`），对象还在，窗口再打开时图标能挂回去；析构才 `g_clear_object` 放掉它、并销毁菜单。退出时那个 `Hide` 是必须的 —— 光靠进程消失，Shell 要过一会儿才发现图标没了，那段时间它挂在顶栏上、点一下才知道是死的。
- **图标名先查主题再兜底**。`cirro-mail` 这个名字只有装到系统里才进主题（`linux/CMakeLists.txt` 装了 16–512 九档），`flutter run` 直接跑 bundle 时不走 install。所以 `ResolveIconName()` 用 `gtk_icon_theme_has_icon` 探一下，没有就退回 GTK 自带的 `mail-unread`。
- **本工程 Linux 侧是 `-Wall -Werror`**，而 `GtkStatusIcon` 整族从 GTK 3.14 起废弃、`libayatana-appindicator` 的**整个** C API 也是 deprecated 的（`app_indicator_new_with_path` 同样，不是换个构造函数就好）—— 每一处调用点都得用 `G_GNUC_BEGIN/END_IGNORE_DEPRECATIONS` 按住（这个宏**必须包住调用点**，包在头文件里没用，告警是在那一行报的；也不能出现在 class body 里）。

⚠️ **这一段同样没有在本机验证过** —— 这台是 macOS，`flutter build linux` 跑不了。做到的只有：用 `clang++ -fsyntax-only -Wall -Werror`（跟工程里 `apply_standard_settings` 同一套开关）把三个源文件在**两个后端各过了一遍**（全绿），Dart 侧 `flutter analyze` 干净。要在真机上确认的是：「关窗进顶栏 / 菜单两项 / 再次启动只开一个」，外加 configure 那行提示说的是哪套后端。

## 附件预览

预览的**唯一**入口是 `features/attachment/attachment_preview.dart`：一个判据
（`canPreview`）+ 一个 `switch`。判据 = 类型/体积 × 平台能力 × viewer 实现了没有；
`switch` **没有兜底分支**，所以将来加类型时忘了改这里是**编译错误**，而不是推一个
空页面出去。（在这之前这件事是 `attachment_sheet.dart` 里的一对私有成员，兜底
分支是「不是 PDF 就当图片」—— 任何漏判的新类型都会报「图片打不开」。）

| 类型 | 怎么预览 | 降级 |
|---|---|---|
| 图片 / PDF | 既有实现 | Linux 没有 `pdfx` 后端 → 不给「预览」 |
| 文本 / 日志 / 代码 | 等宽 + 按行懒建 + 可选中；BOM → 严格 UTF-8 → **GBK/GB18030** → 宽容 UTF-8（并提示） | — |
| Markdown | 解析成 HTML 后**复用正文那套 `HtmlBodyView`**，另给一个「看源码」开关 | — |
| CSV / TSV | 自写 RFC4180 解析（引号转义、字段内换行、CRLF），表头固定、双向滚动 | 5000 行 × 100 列 |
| docx | `archive` + `xml` 取 `w:body`：标题级别、粗斜下划线删除线、列表项、表格跨列 | 图片/版式/脚注/文本框/公式一律不显示，图上插 `[图片]` 占位并在底部说明 |
| xlsx | 共享字符串 / inlineStr / 布尔 / 错误 / 公式结果，**日期序列号会转换成日期**（靠 `cellXfs → numFmtId`，内建 14–22/27–36/45–47/50–58 + 自定义格式码扫描） | 5000 行 / 100 列 / 20 张表 |
| pptx | 逐页纯文本卡片，页序按 `p:sldIdLst`，页头「第 N 页 / 共 M 页」 | 只抽文本，没有版式/图片/动画；100 页 |
| 音频 | `audioplayers`：播放/暂停、拖动定位、倍速；播放器藏在 `AudioPlayback` 接口后面（插件在 `flutter_tester` 里只有 `MissingPluginException`，不隔一层控件层写不了测试） | Linux 缺 gstreamer 时页内提示并给「用其他应用打开」 |
| 视频 | `video_player`，控件自己画（点一下收放） | **Windows / Linux 没有实现**，那两个平台不出现「预览」这一行 |

四条硬规矩：

1. **Office 文件不出机器。** 纯 Dart 本地解析，不交给 Google Docs Viewer /
   Office Online。走第三方等于把用户的合同发出去。
2. **附件是不可信输入**，与邮件正文 HTML 同级。`archive` 4.5 的解压炸弹防护
   （`maxSize` / `maxOutputSize`）是必需项；`xml` 7.x 不展开内部实体（没有
   billion-laughs）、不取外部实体（没有 XXE）、解析器是迭代的（不会爆栈）。
3. **统一体积上限 20 MiB**（与发信那边的 `attachmentTotalSoftLimit` 同一个数）。
   超限的不给「预览」，只留打开/另存为，复用 `previewUnsupported` 那句话。
4. **类型判定只有一处**：`core/util/attachment_mime.dart`（纯 Dart，不 import
   flutter）。服务端在 S3/KV 后端上永远返回 `application/octet-stream`，所以
   **扩展名兜底是必需项**：声明的 mime（非 octet-stream）→ `mime` 包查表 →
   一张补丁表（`mime` 包里没有 `docx` / `pptx` / `yaml`）→ 前 8 KB 嗅探 magic。

解析器一律是**纯函数**：吃 `List<int>`，吐中性模型，不 import `dart:io`、不 import
widget，坏 zip / 缺文件 / 超限都返回一个可展示的错误而不是抛穿。

## 大附件为什么这么做

`/email/send` 只收 JSON + base64，服务端没有通用上传端点，且**不改后端**的前提下绕不开。所以客户端能做的只有「不让它在内存里爆开」：

- 请求体用 `Stream<List<int>>` 逐块组装（`features/compose/stream_body_builder.dart`），附件从磁盘 `openRead()` 经 base64 编码器流出，**不整体展开成 String**。峰值内存从「文件 + 1.33×base64（Dart 的 String 是 UTF-16，实际更差）+ 序列化缓冲」降到大约一个分块。
- base64 长度可以精确预算，所以 `Content-Length` 是显式带上的。
- 附件挑选时只留路径（`file_picker` 的 `withData: false`），不读进内存。
- 发送前在**本地**先校验：附件数 ≤ 10、内嵌图 ≤ 10、收件人非空、正文非空、总量软上限。这不是优化 —— 服务端的超限检查发生在**插库之后**，超了会留一条脏的 `SAVING` 行。

真正的天花板在服务端：Worker 128MB 内存要 base64 解码全部附件并算两次 SHA-256，发信服务商单封通常还有个 25MB 左右的上限。默认软上限设成 20MB。要真突破必须改后端（加 multipart 的 `sendStream` + 通用 `POST /upload`），那是另一件事。

## 目录结构

```
lib/
├── core/          网络（dio + 拦截器 + 信封拆包）、存储、drift 库、主题、工具
├── data/          models（手写 fromJson，全字段容错）、api、repositories
├── instance/      一个实例的运行时（dio + token + 能力 + 同步），以及多实例的串行调度器
├── features/      按页面分：onboarding / timeline / mail_list / mail_detail / attachment / compose / …
├── providers/     Riverpod
└── l10n/          中英 ARB
test/             单测：信封拆包、游标、URL 解析、时间解析、流式 body、通知闸门、路由重算
```

`dart:io` 只允许出现在 `core/storage/`、`data/repositories/attachment_repository.dart`、`features/notifications/background_sync_task.dart`。其余层保持平台无关 —— 现在不做 Web，但这条线能让日后想加 PWA 时不至于全盘返工。

## 一些不那么显然的坑（都在代码注释里，这里列提纲）

- **HTTP 状态码恒为 200**。`401/403/501/502` 全在 body 的 `{code}` 里，所以 dio 必须 `validateStatus: (_) => true`，否则鉴权与错误处理全部失效。
- `unread` 是 **0 未读 / 1 已读**，与字段名直觉相反。
- 正文里的内嵌图是字面量 `{{domain}}`，必须在**渲染时**替换，不能把替换结果写回缓存的 `content`（实例日后配了 `r2Domain` 要能自动切 CDN）。
- 附件下载统一走 `/api/oss/<key>`，**不要**用 `/attachments/*`（它只读 KV，存储是 R2/S3 时会挂）。且 `/api/oss/*` 找不到对象时返回的是 **200 + 一段 JSON** —— 下载器要嗅探，否则会把 72 字节的 JSON 当文件写盘。
- `createTime` 是无时区标识的 UTC，`DateTime.parse` 会当本地时间，必须显式按 UTC 解析。
- 登录 JWT **没有 `exp`**，服务端靠 KV 里一份最多 10 条的 token 列表校验 —— **第 11 次登录会把最老的会话挤掉**。所以 401 时不要静默重登，那会继续挤。App 在设置里有说明。
- 服务端**没有未读计数接口**，也没有单封详情接口。未读角标是本地库算的（首次同步完成前显示「同步中」而不是一个错误的 0）；通知深链要往回翻页找那封信（上限 5 页）。
- 发信接口**不支持 cc/bcc**（服务端只用 `receiveEmail` 拼 `recipient`），UI 如实说明了这一点。

## 依赖版本为什么是这几个数

本机 / CI 用 Flutter 3.47.7 + Dart 3.13.5。升 Flutter 时下面这几条要重新核一遍
（CI `.github/workflows/ci.yml` 也钉了同一个版本，就是为了不出现「本地过、CI 挂」）：

| 包 | 约束 | 为什么是这一版 |
|---|---|---|
| `flutter_riverpod` `^3.4.3` | 3.4.x 起要 Dart ≥3.12、Flutter ≥3.44；18.x 之前的 `go_router` 也要 Flutter ≥3.38 | 已是最新，见下面「riverpod 的那个补丁」 |
| `go_router` `^18.0.2` | 18.x 要 Flutter ≥3.44 | 18.0.2 是最新 |
| `drift` / `drift_dev` `^2.35.1` | 2.34.x 起 `drift_dev` 的 analyzer 要 meta ^1.18，旧 `flutter_test` 把 meta 钉死在 1.17 | 3.47 的 `flutter_test` 已放开 meta |
| `connectivity_plus` `>=7.3.1 <7.3.2` | **与 Flutter 无关的冲突**：7.3.2 起经 nm ^0.6.0 要 dbus ^0.8.0，而 `flutter_local_notifications_linux` 8.0.1 要 dbus ^0.7.8 | 等 `flutter_local_notifications` 换到 dbus ^0.8 才能放开 |
| `cached_network_image` `^4.0.4` | 4.x 要 Flutter ≥3.44 | — |
| `pdfx` 而非 `pdfrx` | `pdfrx` 要 Flutter ≥3.47（现在够了，见下） | 暂未迁移 |
| `archive` `^4.5.1` | 纯 Dart，五平台一致 | **4.5 起才有解压炸弹防护**（`maxSize` / `maxOutputSize`）。API 也与网上常见的 3.x 写法不同（`ZipDecoder().decodeBytes()`，没有 `decodeBuffer`） |
| `xml` `^7.0.1` | lock 里本来就是 7.0.1（`flutter_local_notifications_windows` 传递依赖），显式声明只是摆上台面 | **别引 `excel` 包** —— 它钉 `xml >=5.0.0 <7.0.0`，会把 xml 降级 |
| `charset` `^2.0.1` | 纯 Dart，GBK / GB18030 / BIG5 | 冷门包（27 likes），但纯函数、可单测 |
| `audioplayers` `^6.7.1` | **五平台都有实现**（`just_audio` 缺 windows/linux） | Linux 转发给系统 gstreamer，缺库时构造播放器会抛 → 播放页捕获后降级 |
| `video_player` `^2.14.1` | 本来就在 lock 里（`flutter_quill_extensions` → `video_player`），提成直接依赖**不改变任何插件注册** | **没有 Windows / Linux 实现** → 那两平台不提供视频预览（补齐要换 `fvp`，本轮不做） |

`build_runner` 上到 `^2.16.2` 之后，`--delete-conflicting-outputs` 这个参数被移除
了（写了只会打一行警告），CI 与本地命令都去掉了它。

### riverpod 的那个补丁

`flutter_riverpod` 3.4.3 仍有一处应用会稳定踩到的 bug：**被 `TickerMode` 暂停的
消费者恢复可见时，会抛 `setState() or markNeedsBuild() called during build`**
（切宽屏侧栏 / 窄屏底部导航的分支时触发，菱形依赖图下必现，见
`test/ticker_resume_build_test.dart`）。上游在 `main` 分支上修了（PR #4884），
但**还没进任何发行版**。

所以 `pubspec.yaml` 里有这一段 `dependency_overrides`，指向 `third_party/` 下
**上游 3.4.3 的源码副本 + 一处回移的修复**：

```yaml
dependency_overrides:
  riverpod:
    path: third_party/riverpod
```

补丁是什么、为什么需要、什么时候能删，都在 `third_party/PATCHES.md`。

## 测试

```bash
flutter analyze
flutter test
```

`test/` 里有 166 个用例文件、2228 个用例。覆盖的是那些「在真机上极难复现、但错了后果很重」的地方：信封拆包、双向游标、`{{domain}}` 在 `r2Domain` 有无两态下的替换、畸形 `recipient` 的容错、UTC 时间解析、`resolveKey` 的四种 key 形态、**流式 body 的字节流与 `jsonEncode` 结果逐字节相等**、多实例空洞检测、通知的基线闸门、路由重算，以及分栏形态的几何（`clampListWidth` 的边界）、选中态地址的拼解、外壳那颗写邮件浮动按钮的显隐判据（详情页与宽屏设置页收起，`compose_fab_routes_test.dart`），还有那条「TickerMode 恢复可见时不许在 build 阶段标脏」的回归（四种依赖图形状，见上面 `third_party/` 那段）。收件箱那一轮加了两条**守卫**：`mailbox_scope_test.dart` 钉住「这一屏是不是钉在某个邮箱上」的判据（`account` 参数在不在，`0` 也算），`home_entries_test.dart` 里那条钉住「一级入口的地址里永远不许出现 `account`」—— 它一破，收件箱自己就会被判成下级菜单，把筛选按钮藏掉（见 `pinnedMailboxOf`）。推送那部分单钉了一条回归：**出站请求里的设备号必须带 `<实例位>-` 前缀** —— 这条曾经在真实链路上全数 401（见 `docs/push-setup.md`）；另外 `push_pages_test.dart` 钉住了七页向导里唯一有分支的那处「这一页算不算做完了」，`poll_interval_prefs_test.dart` 钉住了「检查邮件间隔」的默认 5 分钟 / 1 分钟 – 1 小时区间与旧版本那两档 key 不再作数。全库唯一一条「pump 一整块挂 `ProviderScope` 的界面」的用例是 `mailbox_filter_overlay_test.dart`：它钉的是收件箱那颗按钮的浮层**跟着路由收起**（压一页详情上去要收、退回来不许复活）—— 这条只有把界面整个跑起来才看得见，纯函数测不到。

附件预览那一轮把 OOXML / CSV 的解析器做成了**纯函数**，所以能整块单测（`docx_codec_test.dart` / `xlsx_codec_test.dart` / `pptx_codec_test.dart` / `csv_codec_test.dart` / `text_decode_test.dart`，含各自的「坏 zip / 缺文件 / 超限」容错用例）。文件夹样本**不往仓库里提交二进制**：`test/support/ooxml_fixture.dart` 在测试里用 `archive` 的 `ZipEncoder` 现搭最小包，顺带也验了「自己写的 zip 能被自己读回来」。`xlsx_codec_test.dart` 里单钉了一条日期序列号：epoch 是 1899-12-30（Lotus 1-2-3 兼容），序列号 60 那个历史上的一天偏差也钉住了。音频那侧靠注入假 `AudioPlayback` 测控件层（拖动时位置回调不许把滑块拽走、放完再点要先 seek 回 0），视频那侧只测「文件不在了 / 超限」这两条**跑在插件之前**的路径 —— 播放本身在 `flutter_tester` 里没有实现，测不了，如实写在文件头。

详情页那一轮（正文可选 + 右键菜单）三条：`mail_detail_selection_test.dart` 里，正文拖选之后 `RenderParagraph.selections` 非空（**必须给 `PointerDeviceKind.mouse`**，触屏走的是另一套识别器）、`Ctrl+A` + `Ctrl+C` 发出去的文本里**同时**有正文与主题（钉住 `SelectionArea` 包的是 `ListView` 而不是只包正文）、右键菜单里「删除」点完库里那一行真没了且内嵌形态的 `onClose` 被调用。`mail_shortcuts_system_test.dart` 挂 `com.zenkee.mailapp/window` 那条原生通道，验 `Cmd+W` 真的打到 `hideMainWindow` 上、`Cmd+,` 真的落到 `/settings`。

## 已知未完成

- **选中行不会自动滚入视野**。`?sel=` 指向的邮件若不在列表已加载的那一屏里，右栏有内容但左栏看不到高亮行（需要 `Scrollable.ensureVisible`）。另外选中是「替换 URL」而不是压栈，所以**系统返回手势关不掉右侧预览**，靠右栏自己的关闭按钮。
- **界面文案只翻了主体**。中英 ARB 已有 567 条 key（侧完全对齐），但仍有约 540 处界面字符串是硬编码中文（散在 80 个文件里；口径是「去注释后、字符串字面量里出现汉字」，含 Office 解析器里那些 `[图片]` 占位）。中文用户看到的是完整的，只有**英文界面**上会露出这些没翻的片段。列最全的是错误消息与诊断页（那里甚至有意保留服务端的原始中文）。
- **快捷键只有一小组**：`Cmd/Ctrl+N` 新建、`Cmd/Ctrl+R` 答复、`Cmd/Ctrl+Shift+F` 转发、`Cmd/Ctrl+D` 删除、`Cmd/Ctrl+Enter` 发送、`Cmd/Ctrl+,` 打开设置、`Cmd/Ctrl+W` 藏窗口；写邮件页 `Esc` 退出并自动存草稿。详情页正文可选可复制，右键有「复制 / 全选 + 答复 / 转发 / 删除」。计划里的 `j`/`k` 上下移动与快捷键帮助面板仍然没做。
- Windows / Linux 的构建没有在 CI 上验证（原生依赖差异大，需要各自的机器）。Android（`flutter build apk --debug`）、macOS（`flutter build macos --debug`）、iOS（`flutter build ios --no-codesign`）三个都在本机跑通过。**Windows 和 Linux 没有 FCM 推送**（`firebase_messaging` 只声明了 android/ios/macos/web），那两个平台只能靠轮询。
- **Windows / Linux 的托盘都没在真机上验过**。macOS（菜单栏 `NSStatusItem`）、Windows（任务栏通知区 `Shell_NotifyIcon`）、Linux（顶栏图标，appindicator 或 `GtkStatusIcon` 兜底）三边都已经「关窗不退出 + 常驻小图标」，但后两个平台是在 macOS 上写的，只做到交叉编译 / 语法检查，见上面各自那一段末尾的 ⚠️。
- **macOS 的 Release 构建拿到的是 development 环境**（本机只有开发描述文件，见上面「仍然只能在 Xcode / Apple 开发者后台里做的」）。要外发还得补 Developer ID 描述文件。
- iOS 后台拉取是机会式调度，用户强杀 App 后不跑。
- 网页端的草稿在浏览器 IndexedDB 里，App 读不到 —— 两边的草稿不互通。
- 正文渲染用纯 Dart 的 `flutter_widget_from_html_core`，复杂营销邮件（媒体查询 / flex / grid / `@font-face`）会比网页端差一些。
- **附件预览这一轮没有在真机上逐项走过。** 纯函数（三个 OOXML 解析器、CSV、编码嗅探）与控件层（音频假播放器、分发器落到哪一页）都有用例，但 §8 那份端到端清单 —— 真的拿一封带 `report.docx` / `sheet.xlsx` / `deck.pptx` / GBK 的 CSV / `voice.m4a` 的邮件逐个点开 —— 只在 macOS 上跑过 `flutter build macos --debug`，没有逐项点。**最该先验的是 xlsx 的日期列**（编译过不等于 `cellXfs` 那条链路在真实文件上对）与音频的拖动。
- **Office 三种是「能看内容」不是「能看排版」**：docx 的图片是 `[图片]` 占位、版式/分页/脚注/文本框/公式全不显示，pptx 只抽文本（没有图片、图表、动画、备注），xlsx 不做公式求值也不认条件格式与图表。三边都在页面底部写明了一句，免得用户以为文件坏了。
- **视频在 Windows / Linux 上没有预览**，退回「用其他应用打开」（`video_player` 无那两个平台的实现，见上面的依赖表）。Linux 的音频另外依赖系统 gstreamer，缺库时是页内提示而不是静默失败。
