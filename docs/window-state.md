# 桌面窗口状态（大小 / 位置 / 最大化）

桌面三端启动时把主窗口摆回**上次退出时**的大小和位置；上次是最大化的，就仍然
最大化启动。手机端没有窗口概念，不涉及。

本文只记**口径、每个平台落在哪、以及各自的限制**。具体为什么这么写，在各平台
runner 的代码注释里（本仓库的规矩是「为什么」写在被改的那个文件旁边）。

## 口径

- 记的是**主窗口**（`mail_app` 进程里那唯一一扇）外框，不是内容区、不是每账号
  一份：窗口是进程级的东西，多实例 / 多账号共用一份位置，与「上次登录的是哪个
  邮箱」无关。
- 「关窗」= 藏进菜单栏 / 通知区 / 顶栏（见 `lib/core/storage/window_channel.dart`），
  **不是退出**。藏窗不会改窗口几何；再叫回来还是原处。
- 恢复发生在**窗口显示之前**（三端都是），所以用户看不到「先弹在默认位置、再跳
  过去」。
- 上次是最大化 → 这次启动也最大化。**全屏**（macOS 绿按钮的全屏空间、Windows
  的 F11 全屏）和**最小化**不恢复：那是窗口管理器的状态，不是外框。
- 存档坏了、读不出来、或与当前显示器对不上，一律**静默退回默认**
  （1280x720、不最大化），不弹窗、不拖慢启动。

## 各平台落在哪

| | macOS | Windows | Linux |
|---|---|---|---|
| 文件 | `macos/Runner/AppDelegate.swift` | `windows/runner/flutter_window.{h,cpp}`、`main.cpp` | `linux/runner/my_application.cc` |
| 存储 | AppKit 的 frame autosave（本 App 的 `UserDefaults`，键 `NSWindow Frame CirroMainWindow`，沙箱容器内） | `HKCU\Software\Zenkee\CirroMail\WindowState`，5 个 `REG_DWORD`：`X`/`Y`/`W`/`H`/`Max` | `$XDG_CONFIG_HOME/<APPLICATION_ID>/window-state.ini`，`GKeyFile` 的 `[window]`：`x`/`y`/`width`/`height`/`maximized` |
| 坐标系 | AppKit 的屏幕坐标（左下原点），AppKit 自己转换 | **物理像素**（`GetWindowPlacement` 那套） | GTK/X11 的逻辑像素（`gtk_window_get_position` 那套） |
| 恢复时机 | `applicationDidFinishLaunching` 里 `setFrameAutosaveName` —— 它设置名字的**同时**立刻套用存档，早于 `showMainWindow()` | `main.cpp` 建完窗口后调 `SetStartupFrame`，`FlutterWindow::OnCreate` 在**建 `FlutterViewController` 之前** `SetWindowPos`（窗口此时还隐藏） | `my_application_activate` 里 realize / 首帧之前 `gtk_window_set_default_size` + `gtk_window_move` |
| 保存时机 | AppKit 自己管：移动、缩放、关窗时写回，不用自己挂观察者 | `WM_SIZE` / `WM_EXITSIZEMOVE` / `WM_CLOSE` / `HideToTray()`（`Cmd+W` 也走它）/ `QuitApplication()` | `configure-event` 500ms 去抖；藏窗（`hide_to_tray` 开头，关闭按钮与 `Cmd+W` 共用）与托盘退出时立即落盘 |
| 最大化 | 不存（macOS 的「缩放」是绿按钮那套窗口管理器状态，见下） | `GetWindowPlacement` 的 `showCmd` / `WPF_RESTORETOMAXIMIZED`，首帧 `ShowWindow(SW_SHOWMAXIMIZED)` | `gtk_window_is_maximized()`，首帧 `gtk_widget_show` 之后 `gtk_window_maximize()` |

### 为什么 macOS 只用一行

`NSWindow.setFrameAutosaveName` 是 AppKit 现成的机制：它把外框写进本 App 的
`UserDefaults`、下次同名窗口建出来时自动套回去，窗口被拖到一块**已经拔掉**的
显示器上时还会在窗口上屏前用 `constrainFrameRect` 挤回可见区域。自己存一份
CGRect 反而要在 macOS 上再实现一遍钳位逻辑 —— Windows / Linux 之所以自己存，
是因为那边没有等价的现成机制。

macOS 因此也不额外记「最大化」：绿按钮在 macOS 上是全屏空间、Option+绿按钮才是
「缩放」，两者都是窗口管理器状态；正常外框已经由 autosave 记住。

### Wayland：只记大小，不记位置

Wayland 合成器不给应用窗口坐标（`gtk_window_get_position` 永远 0,0，
`gtk_window_move` 只是被忽略的 hint）。所以 Linux 实现里用
`GDK_IS_X11_DISPLAY` 分叉：X11 才读写 `x`/`y`，Wayland 只恢复 / 保存宽高与最大化
—— 否则每次启动都会把窗口按 (0,0) 摆到左上角，比不恢复更糟。

## 共同的钳位规则（Windows / Linux）

- **尺寸**：只接受 `[320, 16384] x [240, 16384]`，否则用默认 1280x720。上限挡的是
  损坏数据（十几万像素的窗口在某些平台上直接创建失败），下限挡的是「小到界面
  根本排不开」。
- **位置**：存档矩形必须和**当前某块显示器**（Windows 用 `rcWork` 工作区，Linux
  用 `gdk_monitor_get_geometry()`）至少重叠 **120x80**，否则放弃位置、交给系统 /
  窗口管理器摆。多显示器拔线之后坐标还在、屏幕没了，这条是防止「启动后看不见
  窗口」的唯一防线。
- 两个平台都**先校验、后应用**；应用都发生在窗口显示之前（Windows 是建窗后首帧
  前、窗口隐藏时 `SetWindowPos`）。

## 两个检出（公开版 / 商业版）

- macOS：外框走 AppKit autosave，defaults 域按 bundle id 各自隔离，名字
  `CirroMainWindow` **两个检出逐字相同**，没有品牌差异。
- Windows：注册表键里的 `CirroMail` 是**品牌差异点**，pro 检出为
  `Software\Zenkee\CirroMailPro\WindowState`（与通道名 `com.zenkee.cirromail` →
  `...cirromailpro` 同一条规矩）—— 两个 App 可以同时装，共用键会互相覆盖窗口位置。
- Linux：目录名用 CMake 的 `APPLICATION_ID`，公开版 `com.zenkee.cirromail`、pro 版
  `com.zenkee.cirromailpro`，代码本身没有分支。

## 验证边界

- macOS：已实测（本机）—— 移动 + 缩放窗口 → 退出 → 重启，窗口回到同一位置与
  尺寸；把存档改成屏幕外的坐标 → 重启后 AppKit 把它钳回可见区域。
- Windows / Linux：代码按上述规格实现，**未在真机跑过**（本机是 macOS，无
  Windows / Linux 工具链）。`TODO.md` 里记了一条真机验收：挪窗 → 退出 → 重启；
  最大化退出 → 重启仍最大化；把存档改成屏幕外 → 重启落回可见区域。
- `test/desktop_window_state_test.dart` 是**文本钉子**：`analysis_options.yaml`
  把 `macos/**`、`windows/**`、`linux/**` 排除在分析之外，原生代码进不了
  `flutter test`，只能钉住「关键那几行还在」防止 runner 被模板重新生成时悄悄
  丢掉（本仓库的 `macos_single_instance_test.dart` 用的是同一种办法）。
