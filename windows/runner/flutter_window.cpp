#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "single_instance.h"

namespace {

// `Shell_NotifyIcon` 的回调消息。取 `WM_APP` 段里的一个值，只要不和别人撞
// 就行（这个窗口收不到别的 App 的消息）。
constexpr UINT kTrayCallbackMessage = WM_APP + 1;

// Dart 那边用来「把窗口叫回来」的通道。
//
// 和 macOS 的 `com.zenkee.mailapp/window` **同名同方法**，Dart 侧因此只需要
// 一份代码（`lib/core/storage/window_channel.dart` 里那个平台判断）。
// Windows 上需要它的是**点通知**那条路：系统弹的是 toast，点它并不会把
// 「藏在通知区里」的窗口带出来，导航又在 Dart 手里。
constexpr char kWindowChannelName[] = "com.zenkee.mailapp/window";

// 冒烟自检用：设了这个环境变量时，启动就直接跳到「关窗之后」的状态
// （藏起窗口、挂上通知区图标），让没写鼠标、没有 Windows 的自动化也能验一遍
// 「关窗之后窗口不会被销毁、Flutter 引擎继续跑」。生产路径上它不存在，
// 整段只是一个 `GetEnvironmentVariable` 判断。
constexpr const wchar_t kSmokeEnvVar[] = L"CIRRO_SMOKE_MINIMIZE_TO_TRAY";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();

    // 冒烟自检：首帧出来之后立刻进「关窗后」的状态。见上面 kSmokeEnvVar。
    if (::GetEnvironmentVariableW(kSmokeEnvVar, nullptr, 0) != 0) {
      PostMessage(GetHandle(), WM_CLOSE, 0, 0);
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // 「把窗口叫回来」那条通道。绑定的是 Flutter 主线程的 messenger，所以
  // 回调（和 `ShowMainWindow` 里的窗口操作）天然落在建窗口的那个线程上 ——
  // 不像 macOS 那边要自己 `DispatchQueue.main.async` 兜一次。
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        // 两个方法共用这条通道（`Cmd+W` 那条见 Dart 侧 `WindowChannel.hide`）。
        // `hideMainWindow` 走的是**已有的** `HideToTray()` —— 就是 `WM_CLOSE`
        // 那条路调的那个：藏窗口 + 确保通知区图标在。不另写一条「只藏窗口」
        // 的路径，否则会出现「`Cmd+W` 藏了之后托盘里没有图标、再也叫不回来」。
        if (call.method_name() == "hideMainWindow") {
          HideToTray();
          result->Success();
          return;
        }
        if (call.method_name() != "showMainWindow") {
          result->NotImplemented();
          return;
        }
        ShowMainWindow();
        result->Success();
      });

  return true;
}

void FlutterWindow::ShowMainWindow() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  // 最小化过就先还原，否则 `ShowWindow(SW_SHOW)` 对最小化的窗口没有效果。
  ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(hwnd);
}

void FlutterWindow::HideToTray() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  EnsureTrayIcon();

  // 先摘掉任务栏按钮再藏窗口：`SW_HIDE` 之后任务栏按钮本来也会消失，但
  // 显式加 `SWP_HIDEWINDOW` 能顺手压掉「最小化动画之后窗口还闪一下」。
  ::ShowWindow(hwnd, SW_HIDE);
  ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_HIDEWINDOW);
}

void FlutterWindow::EnsureTrayIcon() {
  if (tray_icon_) {
    return;  // 幂等：关一次窗只会建一次图标。
  }
  tray_icon_ = std::make_unique<TrayIcon>(GetHandle(), kTrayCallbackMessage);
  tray_icon_->set_on_open([this]() { ShowMainWindow(); });
  tray_icon_->set_on_quit([this]() { QuitApplication(); });
  tray_icon_->Add();
}

void FlutterWindow::QuitApplication() {
  // 图标要**先**摘：`DestroyWindow` 之后 Shell 才发现那个 owner 窗口没了，
  // 中间这段时间图标还挂在通知区上（要鼠标划过才消失）。主动删掉干净。
  if (tray_icon_) {
    tray_icon_->Remove();
  }
  // `SetQuitOnClose(true)` 是 `main.cpp` 设的，`WM_DESTROY` 会上报退出消息。
  ::DestroyWindow(GetHandle());
}

void FlutterWindow::OnDestroy() {
  // 窗口真的要没了。显式摘掉图标，并把它的析构放回**窗口销毁之前** ——
  // `TrayIcon::~TrayIcon` 还要对着这个 hwnd 发 `NIM_DELETE`。
  if (tray_icon_) {
    tray_icon_->Remove();
    tray_icon_.reset();
  }
  window_channel_.reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 单实例广播：另一个进程（用户又点了一次开始菜单）在请我们把窗口摆前面。
  // 这条消息是在**本进程的 UI 线程**上、由本进程的消息循环派发过来的。
  if (SingleInstance::HandleMessage(message, hwnd)) {
    return 0;
  }

  // 托盘图标的消息（回调 + Explorer 重启后的 `TaskbarCreated`）。
  if (tray_icon_ && tray_icon_->HandleMessage(message, wparam, lparam)) {
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    // 关机 / 注销。这两条本身不用回什么话（`DefWindowProc` 对
    // `WM_QUERYENDSESSION` 的默认答复就是「可以关」），只是要在
    // `WM_CLOSE` 到来**之前**把 [session_ending_] 立起来 —— 系统保证的正是
    // 「先发 `WM_QUERYENDSESSION`，得到许可后才对每个顶层窗口发 `WM_CLOSE`」。
    case WM_QUERYENDSESSION:
      session_ending_ = true;
      break;

    // `WM_ENDSESSION` 在会话**被取消**时也会来，而且带着 `wParam == FALSE`。
    // 不分青红皂白一直置 true 的话，「关窗进通知区」这个行为会在一次被取消
    // 的注销之后就悄悄失效（之后每次关窗都变成退出），而且要重启才恢复。
    case WM_ENDSESSION:
      session_ending_ = wparam != FALSE;
      break;

    // 「关掉窗口」在这里被截住，改成藏进通知区。
    //
    // **为什么这条不能撒手**：`WM_CLOSE` 的默认处理（`DefWindowProc`）就是
    // 直接 `DestroyWindow`。一旦走到那里，`OnDestroy` 会把
    // `flutter_controller_` 一起释放 —— 引擎停摆、轮询和推送登记全没，
    // 而任务栏上什么都不剩。用户以为「关掉窗口而已」，实际是把收信关了。
    // 点了「退出」才会真的销毁窗口，那条路见 [QuitApplication]。
    //
    // 例外是**关机**：那时候不能藏，得让窗口真的走完销毁流程。关机流程最后
    // 会给每个顶层窗口发 `WM_CLOSE`，如果我们照样把窗口藏起来、进程留着，
    // 关机就一直卡着等系统强杀 —— 用户看到的是「点了关机之后半天没反应」。
    case WM_CLOSE:
      if (!session_ending_) {
        HideToTray();
        return 0;
      }
      break;

    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
