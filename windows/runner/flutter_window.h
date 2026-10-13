#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "tray_icon.h"
#include "win32_window.h"

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

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 「关窗」的真正动作：藏起窗口、确保通知区里有图标。见 [MessageHandler]
  // 里那段关于为什么必须拦 `WM_CLOSE` 的注释。
  void HideToTray();

  // 第一次关窗时才建通知区图标。关窗之前**没有**这个图标 —— 一个还开着窗口
  // 的 App 不需要再在通知区里占一格。幂等。
  void EnsureTrayIcon();

  // 托盘菜单里的「退出」：摘掉图标、销毁窗口，走上 `main.cpp` 那条
  // `SetQuitOnClose(true)` → `PostQuitMessage` 的路径。
  void QuitApplication();

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

  // 「把窗口叫回来」的通道。持有它才有 handler —— 见
  // `lib/core/storage/window_channel.dart`，两个平台共用那一个 Dart 类。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
