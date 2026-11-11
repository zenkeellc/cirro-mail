#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "tray_icon.h"
#include "win32_window.h"

// 上次退出时窗口的外框（**物理像素**，left/top 可以是负数 —— 显示器摆在主屏
// 左边/上边时就是负坐标）与最大化状态。
//
// 为什么是物理像素、而不是像 `Win32Window::Create` 那样收逻辑像素：
//
// 1. 注册表里存的就是物理像素（`GetWindowPlacement` 的 `rcNormalPosition`）。
//    换成逻辑像素要先除一次 DPI 缩放比，启动后 `Create` 内部再乘一次 —— 一条
//    没有必要的往返，每次启动都多一次舍入（±1px）；负坐标还被
//    `Win32Window::Point` 的无符号字段直接表达不了（副屏在主屏左边就丢位置）。
// 2. 更要命的是 `Create` 拿**逻辑** origin 去 `MonitorFromPoint` 挑一块显示器
//    算 DPI，跟我们自己按物理坐标挑的那块不一定是同一块。混合 DPI 多屏上，
//    窗口会按错的缩放比摆，位置/大小都偏。
//
// 所以恢复到「窗口建好之后、首帧之前」用 `SetWindowPos` 按物理像素摆一次：
// 那时窗口还隐藏着，用户看不到任何跳动；而 `GetClientArea()` 已经是最终尺寸，
// Flutter 控制器一次就按正确大小建出来。
struct StartupFrame {
  // 外框（物理像素）。left/top 允许为负。
  RECT bounds;
  // 上次退出时是不是最大化。与 [bounds] 是否可信无关：位置丢了、窗口也还是
  // 可以按最大化开（回到默认位置所在那块屏的最大化）。
  bool maximized;
  // false = 没有可信的保存值（没存过 / 尺寸越界 / 那块屏已经不在了）：保持
  // `Create` 给的默认几何，别拿一个不可信的矩形去摆窗口。
  bool valid;
};

// 读回上次保存的窗口几何并校验（尺寸区间、与某块显示器的可用工作区至少有
// 120x80 的重叠，全部用物理坐标，不做任何 DPI 换算）；读不到、或被判定不可信
// 时返回 `valid == false` 的结构。任何注册表错误都静默：记不住窗口位置不值得
// 打扰用户，更不该影响启动。
StartupFrame LoadStartupFrame();

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // 把主窗口显示出来并抢到前台。窗口本来就开着时是幂等的。
  //
  // 三条路都走这里：托盘菜单的「打开主窗口」、左键点托盘图标、以及「用户又
  // 点了一次开始菜单」时另一个进程广播过来的那条消息。
  //
  // `SetForegroundWindow` 能不能真的抢到前台，取决于**调用方那一刻有没有
  // 资格**：广播那条路上是对方先 `AllowSetForegroundWindow(ASFW_ANY)` 授的权
  // （见 `single_instance.cpp`）；托盘那条路上，点托盘图标本身就让本进程
  // 拿到了前台资格。这是 Windows 的前台锁规则，跟 App 的代码没关系。
  void ShowMainWindow();

  // 启动时第一次显示要不要直接最大化。`main.cpp` 在 `Create` 之后、进消息循环
  // 之前调一次；真正那一下 `ShowWindow(SW_SHOWMAXIMIZED)` 发生在首帧回调里
  // （见 `flutter_window.cpp` 的 `SetNextFrameCallback`）—— 窗口在首帧之前一直
  // 是隐藏的，那之前调 `ShowWindow` 等于没调。
  void SetStartMaximized(bool maximized);

  // 交进启动几何。**必须在 `Create` 之前调**：`Create` 内部就会跑 `OnCreate`，
  // 而 [OnCreate] 要把窗口先摆到最终位置、再按摆好之后的客户区尺寸建 Flutter
  // 控制器。（晚一步就等于让引擎先按默认尺寸建一次 surface、再因为 `WM_SIZE`
  // 重来一次，启动时白费一帧的渲染资源。）
  void SetStartupFrame(const StartupFrame& startup_frame);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 改原生标题栏的文字（Dart 侧 `WindowTitleHost` 在版本解析出来后调一次）。
  // UTF-8 → UTF-16 的转换在 `utils.cpp` 的 `Utf16FromUtf8`。
  void SetWindowTitle(const std::string& title);

  // 「关窗」的真正动作：藏起窗口、确保通知区里有图标。见 [MessageHandler]
  // 里那段关于为什么必须拦 `WM_CLOSE` 的注释。
  void HideToTray();

  // 第一次关窗时才建通知区图标。关窗之前**没有**这个图标 —— 一个还开着窗口
  // 的 App 不需要再在通知区里占一格。幂等。
  void EnsureTrayIcon();

  // 托盘菜单里的「退出」：摘掉图标、销毁窗口，走上 `main.cpp` 那条
  // `SetQuitOnClose(true)` → `PostQuitMessage` 的路径。
  void QuitApplication();

  // 把当前外框和最大化状态写进注册表。调用点见 [MessageHandler] 里的
  // `WM_EXITSIZEMOVE` / `WM_SIZE` / `WM_CLOSE`、[HideToTray]、[QuitApplication]。
  // 幂等（和上一次写进去的一样就什么都不做）、便宜、任何失败静默、不抛异常。
  void SaveWindowState();

  // 图标徽章的统一入口：Dart 侧 `lib/core/notify/icon_badge.dart` 每次未读数
  // 变化推一条 `{"count": int}`，`count <= 0` 表示清除。两个落点（任务栏窗口
  // 图标、通知区托盘图标）都从这里更新，保证它们永远同一个数。
  void ApplyBadgeCount(int count);

  // 按 [badge_count_] 重画窗口图标。`WM_SETICON` 只认 HICON，所以要自己
  // `LoadImage` 原图、自己 `CreateBadgeIcon`、自己销毁换下来的句柄 ——
  // Windows 不接管图标所有权。任何一档画不出来都退回原图，绝不设成空。
  void ApplyWindowIconBadge();

  // 换上这对窗口图标并回收上一对（nullptr 表示那一档不动）。见
  // [window_icon_small_] 那两个成员上的注释。
  // 参数不能叫 `small` / `big`：`rpcndr.h` 里有 `#define small char` 与
  // `#define big char`，在 Windows 上会把这行展开成 `HICON char`，MSVC 直接
  // 报 C2628。之前只在 macOS 上做过语法检查，所以一直没暴露。
  void SetWindowIcons(HICON small_icon, HICON big_icon);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 系统正在关机 / 注销。
  //
  // 有它才能让「关窗 = 藏进通知区」在关机时**不生效**：关机流程最后会走到
  // 每个窗口的 `WM_CLOSE` 上，如果那儿照样把窗口藏起来、进程留着不走，
  // 用户看到的就是「点了关机之后卡很久」—— 直到系统强杀。见 [MessageHandler]。
  bool session_ending_ = false;

  // 任务栏通知区里的那个图标。关窗之前一直是 nullptr。
  std::unique_ptr<TrayIcon> tray_icon_;

  // 未读总数（0 = 不显示角标）。放在窗口这一层而不是 [TrayIcon] 里：托盘
  // 图标要等第一次关窗才建（[EnsureTrayIcon]），而徽章可能在窗口还开着时
  // 就到了；这个数在两个落点之间共用，「补建托盘」时拿它补画。
  int badge_count_ = 0;

  // 启动时第一次显示要不要最大化。见 [SetStartMaximized]。
  bool start_maximized_ = false;

  // [SetStartupFrame] 交进来的几何，`OnCreate` 里用一次。
  StartupFrame startup_frame_{};

  // 窗口已经显示过至少一次。
  //
  // [SaveWindowState] 拿它当闸门：`Create` 内部那几条 `WM_SIZE` 和首帧之前的
  // 几何都是构造期间的中间值（那一刻启动意图甚至还没从 `main.cpp` 传进来），
  // 存它只会把刚读出来的正确值覆盖掉。
  bool window_shown_ = false;

  // [SaveWindowState] 上一次**真的写进注册表**的值，用来做幂等判断：拖动/贴边
  // 时 `WM_SIZE` 会连着来几十上百条，值没变就不必每条都去开一次注册表键。
  RECT saved_rect_{};
  bool saved_maximized_ = false;
  bool has_saved_state_ = false;

  // 窗口图标的句柄。两份都是本类 `LoadImage` / `CreateBadgeIcon` 出来的
  // **自己的一份**（不是窗口类里那个 `LoadIcon` 的共享图标），换下来当场
  // `DestroyIcon`，析构时也要销毁。`WM_SETICON` 的返回值是**先前那个**句柄，
  // 它可能指向共享图标、不能拿去销毁，所以「当前装的是谁」得另外记在这里。
  HICON window_icon_small_ = nullptr;
  HICON window_icon_big_ = nullptr;

  // 「把窗口叫回来」的通道。持有它才有 handler —— 见
  // `lib/core/storage/window_channel.dart`，两个平台共用那一个 Dart 类。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // 图标徽章那条通道。和 [window_channel_] 一样必须强持有：通道对象一释放，
  // handler 就跟着没了，表现是「未读数变了但角标永远不动」。
  //
  // 单独一条通道而不是塞进 window 通道，理由与 macOS 那边 `setUpBadgeChannel`
  // 相同：`window` 的语义是「桌面外壳的窗口能力」，而徽章在手机上（iOS）也
  // 走同一个 Dart 类，塞进去等于让 iOS 继承一个名不副实的通道名。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      badge_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
