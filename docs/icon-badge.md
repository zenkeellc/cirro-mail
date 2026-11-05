# 图标未读徽章（任务栏 / 通知区 / Dock / 桌面图标）

给系统图标加一个「还有多少封没读」的数字。需求上只有一句话，实现上散在五个
platform runner 里 —— 这份文档记的是**口径、协议和每个平台落在哪**，具体取舍在
各处代码注释里（本仓库的规矩是「为什么」写在被改的那个文件里）。

## 口径

- 数字 = **全部实例的收件未读总数**，与聚合入口 / 底部导航角标同一个数
  （`totalUnreadProvider`，底层是 `MailDao.watchUnreadByProfile()` 汇总）。
- **只算收件方向、排除已删除**（DAO 里已经这么写了，这里不另算一套）。
- 归零就清除角标；数字**一直显示**，不跟窗口可见性 / in-app 通知开关联动。
  唯一的例外是 iOS 的系统授权（见下面 iOS 一节）：没拿到通知授权时系统不给画，
  代码改不了这件事。
- 显示上限 `99+` 只约束**桌面三端**（Dock 角标 / 菜单栏 / 任务栏 / 托盘）：
  三位数在 Dock 角标和 16px 托盘图标里都放不下，所以 macOS / Windows / Linux
  各自在原生渲染里截成 `99+`。Dart 侧一律传**原始数字**；iOS / Android 也传
  原始数字，显示多少交给系统 / launcher 自己决定（它们有各自的截断规则）。

## 数据从哪来（以及两个「不美好」的地方）

服务端**没有未读计数接口**，数字只能算本地库。由此带来两条已知行为：

1. **冷启动先清一次、再显示真实值**。`IconBadgeHost` 首帧会推一个 0，把上一次
   进程留下的旧角标抹掉（iOS 的 `applicationIconBadgeNumber` 是跨启动持久的）；
   等本地库第一轮 watch 出结果，再推真实数字。桌面端通常看不出中间态，手机上
   可能出现「角标闪一下」。
2. **后台 isolate 不更新徽章**。兜底轮询跑在 workmanager 起的后台引擎里，它没有
   UI 树、`IconBadgeHost` 不在；那段时间新到的邮件要等 App 回到前台、drift watch
   重新出值之后才会反映到角标上。FCM 推送把前台叫醒时同理。

## Dart 侧（两层）

| 文件 | 干什么 |
|---|---|
| `lib/core/notify/icon_badge.dart` | 平台通道的 Dart 封装（`IconBadge.set(count)`），协议的唯一出处 |
| `lib/features/notifications/icon_badge_host.dart` | 挂 `totalUnreadProvider`，变化就推、相同值去重、首帧补推 |
| `lib/app.dart` | 把 host 挂在 `MaterialApp.router` 的 `builder` 链最外层 |

`IconBadgeHost` 是**不画东西**的接线柱：只订阅 provider、只发通道调用，业务状态
全都留在 provider 里。它不判断平台 —— 五个平台都要推，`MissingPluginException`
由 `IconBadge.set` 静默吞掉（旧构建 / 裁剪过的构建不会因此崩）。

## 通道协议

- 通道名：`com.zenkee.cirromail/badge`
- 方法：`setBadge`
- 参数：`{"count": int}`（map；与窗口通道 `setWindowTitle` 的传参风格一致）
- `count <= 0` = **清除**，不是「显示 0」
- 幂等；任何原生侧失败都只能是「不显示数字」，不许抛、不许卡住回调

五个平台注册的通道名/方法名/参数**逐字一致**，Dart 只写一份。下面这张表是
「在哪个文件里接住它」：

| 平台 | 文件 | 落点 |
|---|---|---|
| macOS | `macos/Runner/AppDelegate.swift` | Dock 角标（`NSApp.dockTile.badgeLabel`）+ 菜单栏信封图标右侧的数字 |
| Windows | `windows/runner/flutter_window.cpp`、`windows/runner/tray_icon.cpp` | 任务栏窗口图标（`WM_SETICON`）+ 通知区托盘图标 |
| Linux | `linux/runner/my_application.cc`、`linux/runner/tray_icon.cc` | 顶栏图标（appindicator / GtkStatusIcon 两套后端）+ 启动器角标（Unity LauncherEntry） |
| Android | `android/app/src/main/kotlin/…/MainActivity.kt`、`…/AppIconBadge.kt` | 桌面启动器图标角标 |
| iOS | `ios/Runner/AppDelegate.swift` | 桌面图标角标（`applicationIconBadgeNumber` / `setBadgeCount`） |

## 各平台要点与已知限制

### macOS

- Dock 角标是系统原生能力，数字随 App 运行期的未读数实时变。
- 菜单栏图标是 **template 单色图**，不能在上面画红底白字（会和系统配色打架）；
  所以数字单独作为 `attributedTitle` 放在信封图标右侧，未读归零时清空。
- 菜单栏槽位用 `variableLength`（`squareLength` 会把数字裁掉），没未读时它会
  自己缩到图标宽度。

### Windows

- 任务栏窗口图标用 `WM_SETICON`（`ICON_SMALL` + `ICON_BIG`）换成带角标的版本；
  归零时恢复资源里的原始图标。没有走 `ITaskbarList3::SetOverlayIcon`：那条路要
  初始化 COM 并依赖任务栏对象，收益只是「角标不盖在标题栏图标上」，不值得。
- 通知区托盘图标另画一份（红圆 + 白数字），tooltip 里带「N 封未读」。托盘图标是
  关窗那一刻才建的，所以 badge 数字要先记在 `FlutterWindow` 里，建图标时补画。
- ⚠️ 同本仓库其它 Windows 原生的处境：**本机（macOS）无法真编译/真机验证**，
  只做到 mingw-w64 交叉编译器 `-fsyntax-only`。真机上要看的点见下节。

### Linux

- 顶栏图标两套后端：有 libayatana-appindicator 时它只认**图标名**（不能直接塞
  pixbuf），所以合成图写成 PNG 到 `$XDG_CACHE_HOME/cirro-mail/badge/`、再把
  **PNG 的绝对路径**当 IconName 传过去（GNOME 的 AppIndicator 扩展、KDE 的
  KIconLoader、libayatana 自己的 GtkStatusIcon 兜底都对绝对路径直接读文件；
  走「主题目录 + 主题图标名」反而要摆成 `hicolor/<size>/apps/` 结构，更容易
  静默不显示）。没有 appindicator 时退回 `GtkStatusIcon`（可以直接
  `set_from_pixbuf`）。
- 启动器角标走 Unity LauncherEntry 的 D-Bus 信号（Ubuntu Dock / 部分 KDE 认；
  GNOME 主面板不认，静默跳过 —— 失败不影响任何功能）。`application://
  cirro-mail.desktop` 这个 uri 只有**装成 .deb/.rpm 之后**才存在（`flutter run`
  直接跑 bundle 时启动器里没有对应 .desktop），所以启动器角标只能在安装包上验。
- HiDPI 下合成图固定 24px，2x 面板会把它放大一次（数字略糊）。目前的账算得
  过来：为了托盘图标做多档 PNG 不值，先记在这儿。
- ⚠️ 同 Windows：在 macOS 上写的，只做到 clang `-fsyntax-only`，没在真机验过。

### Android

- 原生 Android **没有公开的数字角标 API**。这里按厂商 launcher 的既有做法做
  best-effort：华为/荣耀（老广播，manifest 里补了 CHANGE_BADGE 权限）、小米
  （provider + 广播）、华硕/LG 等吃通用 `BADGE_COUNT_UPDATE` 广播的机型、索尼
  （新老两套）、vivo。能设就设、设不了静默跳过。
- **三星是个反例**：新 One UI 走 `content://com.sec.badge/apps` 私有 provider
  （要 READ/WRITE 权限），通用广播在它上面大概率无效；本实现两条都没做，所以
  三星新机型上基本别指望数字角标。
- 广播一律走 `queryBroadcastReceivers` → 查到就 `setPackage()` 发**显式**
  广播 → 查不到才退回隐式。原因：Android 8.0 起隐式广播不投递到其它 App 的
  manifest receiver，而厂商角标接收器正是那么注册的。
- Google 系 launcher 只显示「有通知」的点，不显示数字 —— 这是平台限制，不是
  这个实现没做完。**不要**为了角标去 post 一条常驻通知：那会污染通知栏，而
  用户要的只是图标上一个数字。
- 局限写进 `AppIconBadge.kt` 文件头。

### iOS

- `applicationIconBadgeNumber`（iOS 16 以下）/ `UNUserNotificationCenter
  .setBadgeCount`（iOS 16+）。归零清除。
- 角标依赖**通知授权里的 badge 权限**（App 的权限请求里已经带 `badge: true`，
  见 `notification_service.dart`）；用户拒绝时系统静默不显示，不能靠代码绕过。
- 要注意「一直显示」在 iOS 上做不到字面意思：**没授权就没有角标**。而本 App
  现在只在两个时机申请通知权限 —— 用户主动开推送（`push_service.dart`）、
  第一封新信要弹通知时（`notification_service.dart` 的 `ensurePermission`）。
  所以首装、且还没开推送/没收到需要弹通知的新信时，桌面图标上不会有数字。
  这是**刻意不**在启动时弹权限框（邮件客户端一律首启就弹通知授权很讨厌，且
  会拉低用户点「允许」的比例）；如果以后产品上决定「角标必须有」，再在
  `IconBadgeHost` 里补一次 badge-only 的授权请求。

## 怎么验证

```bash
# Dart 侧（必跑）
cd mail-app && flutter analyze && flutter test test/icon_badge_test.dart
# 全量回归
cd mail-app && flutter test

# Windows 原生：只能用 mingw 交叉编译器做语法检查（需要 Flutter Windows 引擎头）
x86_64-w64-mingw32-g++ -std=c++17 -fsyntax-only -Wall -Wextra -DUNICODE -D_UNICODE \
  -isystem <flutter>/bin/cache/artifacts/engine/windows-*/ \
  -isystem <flutter>/bin/cache/artifacts/engine/windows-*/cpp_client_wrapper/include \
  -Iwindows/runner -Iwindows windows/runner/flutter_window.cpp windows/runner/tray_icon.cpp ...

# Linux 原生：GTK3 头 + Flutter Linux 引擎头
clang++ -std=c++17 -fsyntax-only -Wall -Wextra \
  -DAPPLICATION_ID='"com.zenkee.cirromail"' $(pkg-config --cflags gtk+-3.0 gio-2.0) \
  -I<flutter>/bin/cache/artifacts/engine/linux-*/ -Ilinux/runner -Ilinux \
  linux/runner/my_application.cc linux/runner/tray_icon.cc
```

真机上还要点的：

- macOS：Dock 角标数字、菜单栏「信封 + 数字」在浅/深色菜单栏下都看得清；未读
  归零后两处都消失；重新登录后角标不残留。
- Windows：任务栏图标角标、托盘图标数字、tooltip 文案；关窗进托盘后角标仍在；
  未读归零后图标恢复原样；Explorer 重启后图标回来时角标也跟着回来。
- Linux：两种托盘后端各看一次；有 Unity/KDE 的环境看启动器角标。
- Android：在小米/华为/三星各一台机器上看启动器数字角标；Google 系知道只显示点。
- iOS：授权允许/拒绝通知两种情况各看一次；点开邮件读掉后角标数变小。

## 商业版怎么跟

通道名跟着 bundle id 走（与窗口通道同一规矩）：商业版检出改
`lib/core/notify/icon_badge.dart` 里的 `channelName` 前缀，以及五个 runner 里注册
的字符串。核心功能只在公开仓库改一次，商业版从 `main` 合过来 —— 不要两边各写
一份实现。
