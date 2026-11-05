#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <limits>
#include <optional>
#include <string>
#include <variant>

#include "badge_icon.h"
#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "single_instance.h"
#include "utils.h"

namespace {

// `Shell_NotifyIcon` 的回调消息。取 `WM_APP` 段里的一个值，只要不和别人撞
// 就行（这个窗口收不到别的 App 的消息）。
constexpr UINT kTrayCallbackMessage = WM_APP + 1;

// Dart 那边用来「把窗口叫回来」的通道。
//
// 和 macOS 的 `com.zenkee.cirromail/window` **同名同方法**，Dart 侧因此只需要
// 一份代码（`lib/core/storage/window_channel.dart` 里那个平台判断）。
// Windows 上需要它的是**点通知**那条路：系统弹的是 toast，点它并不会把
// 「藏在通知区里」的窗口带出来，导航又在 Dart 手里。
constexpr char kWindowChannelName[] = "com.zenkee.cirromail/window";

// 图标徽章那条通道（Dart 侧 `lib/core/notify/icon_badge.dart`）。
//
// 与 macOS 的 `setUpBadgeChannel` **同名同方法同参数**：方法名 `setBadge`，
// 参数 map `{"count": int}`，`count <= 0` 表示清除。五个平台的 runner 注册的
// 字符串逐字一致，Dart 侧只写一份。
constexpr char kBadgeChannelName[] = "com.zenkee.cirromail/badge";

// 窗口图标要的像素边长。用 `GetSystemMetricsForDpi` 而不是直接
// `GetSystemMetrics`：清单里声明了 PerMonitorV2（见 `runner.exe.manifest`），
// 窗口被拖到另一块缩放比不同的显示器上时，任务栏要的是**那块屏幕**的像素数；
// 用系统 DPI 那一档会被 Shell 再缩一次，数字就糊了。
//
// 这两个 API 是 Windows 10 1607 引入的。早于它的 Windows 10 已经不在支持
// 范围内，所以直接调用，不学 `win32_window.cpp` 里 `EnableNonClientDpiScaling`
// 那套 `GetProcAddress` 动态加载。
int IconMetricForWindow(HWND hwnd, int metric) {
  const UINT dpi = hwnd != nullptr ? ::GetDpiForWindow(hwnd) : 0;
  return ::GetSystemMetricsForDpi(metric,
                                  dpi != 0 ? dpi : USER_DEFAULT_SCREEN_DPI);
}

// 载入 App 自己的资源图标。**不带** `LR_SHARED`：拿到的是我们自己的一份，
// 什么时候销毁由我们说了算（带 `LR_SHARED` 的共享句柄绝不能 `DestroyIcon`）；
// 也**不用** `LoadIcon` —— 那个只会给最大的那一档，任务栏 16px 上会糊。
HICON LoadAppIcon(int size) {
  if (size <= 0) {
    return nullptr;
  }
  return static_cast<HICON>(
      ::LoadImageW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON),
                   IMAGE_ICON, size, size, 0));
}

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
        // 三个方法共用这条通道（`Cmd+W` 那条见 Dart 侧 `WindowChannel.hide`）。
        // `hideMainWindow` 走的是**已有的** `HideToTray()` —— 就是 `WM_CLOSE`
        // 那条路调的那个：藏窗口 + 确保通知区图标在。不另写一条「只藏窗口」
        // 的路径，否则会出现「`Cmd+W` 藏了之后托盘里没有图标、再也叫不回来」。
        if (call.method_name() == "hideMainWindow") {
          HideToTray();
          result->Success();
          return;
        }
        if (call.method_name() == "setWindowTitle") {
          // 与另外两个无参方法不同，这条的参数是 map（`{"title": ...}`）。
          std::string title;
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments != nullptr) {
            const auto it = arguments->find(flutter::EncodableValue("title"));
            if (it != arguments->end()) {
              if (const auto* value = std::get_if<std::string>(&it->second)) {
                title = *value;
              }
            }
          }
          SetWindowTitle(title);
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

  // 图标徽章那条通道（Dart 侧 `lib/core/notify/icon_badge.dart`）。
  //
  // 和上面那条 window 通道一样绑定 Flutter 主线程的 messenger：`WM_SETICON`
  // 只能在这个（建窗口的）线程上发；`Shell_NotifyIcon` 虽然不挑线程，但让
  // 两个落点、连同托盘回调都落在同一个线程上，顺序才不会乱。
  //
  // 回调**绝不阻塞、绝不抛**：参数认不出来就按 0（清角标）处理，画不出来
  // 也只是没有数字。这边若把回调挂住，Dart 那边 `await` 的 future 会一直悬着，
  // 徽章这条链就断了 —— 而这个通道的全部价值就是「有变化就同步一次」。
  badge_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kBadgeChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  badge_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setBadge") {
          result->NotImplemented();
          return;
        }
        // 参数是 map `{"count": int}`，与 `setWindowTitle` 的传参风格一致。
        int count = 0;
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments != nullptr) {
          const auto it = arguments->find(flutter::EncodableValue("count"));
          if (it != arguments->end()) {
            if (const auto* value = std::get_if<int32_t>(&it->second)) {
              count = *value;
            } else if (const auto* wide = std::get_if<int64_t>(&it->second)) {
              // Dart 的 int 是 64 位，StandardMethodCodec 装不下 32 位时才发
              // LongLong。未读总数到不了这个量级，真到了也只影响「显示几位
              // 数字」，截一下别让窄化转换溢出。
              count = *wide > std::numeric_limits<int>::max()
                          ? std::numeric_limits<int>::max()
                          : static_cast<int>(*wide);
            }
          }
        }
        ApplyBadgeCount(count);
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

void FlutterWindow::SetWindowTitle(const std::string& title) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || title.empty()) {
    return;
  }
  // 标题从 Dart 过来是 UTF-8，`SetWindowTextW` 只认 UTF-16，所以先转一道。
  // 转换失败时 `Utf16FromUtf8` 返回空串，`SetWindowTextW` 什么都不做 ——
  // 标题没改掉是小事，不值得让通道回调失败。
  ::SetWindowTextW(hwnd, Utf16FromUtf8(title).c_str());
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
  // 先把此刻的未读数交给它、再 `Add()`：徽章可能在窗口还开着时就到了
  // （那时没有托盘图标，数字只存在 [badge_count_] 里），先设后加就是一次
  // `NIM_ADD` 直接带上角标，不会出现「先无角标、再闪一下变有」。
  tray_icon_->SetBadgeCount(badge_count_);
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

void FlutterWindow::ApplyBadgeCount(int count) {
  // 负数按 0 处理：调用方不该传负数，但「清空」永远比「显示 -1」安全。
  badge_count_ = count > 0 ? count : 0;
  ApplyWindowIconBadge();

  // 通知区图标可能还不存在（窗口没关过就没有托盘图标）：数字存在
  // [badge_count_] 里，`EnsureTrayIcon` 建图标时会补画上去。
  if (tray_icon_) {
    tray_icon_->SetBadgeCount(badge_count_);
  }
}

void FlutterWindow::ApplyWindowIconBadge() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  const int small_size = IconMetricForWindow(hwnd, SM_CXSMICON);
  const int big_size = IconMetricForWindow(hwnd, SM_CXICON);

  // 底图每次都按**当前** DPI 重新载入：窗口被拖到另一块显示器
  // （`WM_DPICHANGED`）之后要画的是另一个像素尺寸，留着旧尺寸的底图只会被
  // Shell 再拉伸一次，数字就糊了。
  HICON small = LoadAppIcon(small_size);
  HICON big = LoadAppIcon(big_size);

  if (badge_count_ > 0) {
    // 把数字叠上去。任何一档画不出来就退回那一档的原图 —— 宁可没有数字，
    // 也不能让任务栏图标变成一个透明块（`CreateBadgeIcon` 失败返回 nullptr）。
    if (small != nullptr) {
      HICON badged = CreateBadgeIcon(small, badge_count_, small_size);
      if (badged != nullptr) {
        ::DestroyIcon(small);
        small = badged;
      }
    }
    if (big != nullptr) {
      HICON badged = CreateBadgeIcon(big, badge_count_, big_size);
      if (badged != nullptr) {
        ::DestroyIcon(big);
        big = badged;
      }
    }
  }

  // 这一行之后两个句柄的所有权归窗口：由 [SetWindowIcons] 换上并负责销毁
  // 上一对。`badge_count_ == 0` 时传进去的就是刚载入的原图，等于「恢复原图标」。
  SetWindowIcons(small, big);
}

void FlutterWindow::SetWindowIcons(HICON small, HICON big) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    // 窗口已经没了（正常退出流程里不该走到这里）：句柄没人接手，就地销毁，
    // 不留悬空的所有权。
    if (small != nullptr) {
      ::DestroyIcon(small);
    }
    if (big != nullptr) {
      ::DestroyIcon(big);
    }
    return;
  }

  // 先换、后销毁旧的：`WM_SETICON` 之后 Shell 才不再引用旧的那一份。
  // 不用 `WM_SETICON` 的返回值回收：它返回的是**先前那个**句柄，可能是窗口类
  // 里 `LoadIcon` 的共享图标（`WM_SETICON` 之前的状态），那种句柄销毁了会
  // 波及所有用同一个图标的窗口。只销毁我们自己记录、自己创建的那一对。
  if (small != nullptr) {
    HICON previous = window_icon_small_;
    window_icon_small_ = small;
    ::SendMessageW(hwnd, WM_SETICON, ICON_SMALL,
                   reinterpret_cast<LPARAM>(small));
    if (previous != nullptr) {
      ::DestroyIcon(previous);
    }
  }
  if (big != nullptr) {
    HICON previous = window_icon_big_;
    window_icon_big_ = big;
    ::SendMessageW(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(big));
    if (previous != nullptr) {
      ::DestroyIcon(previous);
    }
  }
}

void FlutterWindow::OnDestroy() {
  // 窗口真的要没了。显式摘掉图标，并把它的析构放回**窗口销毁之前** ——
  // `TrayIcon::~TrayIcon` 还要对着这个 hwnd 发 `NIM_DELETE`。
  if (tray_icon_) {
    tray_icon_->Remove();
    tray_icon_.reset();
  }
  window_channel_.reset();
  badge_channel_.reset();

  // 窗口图标的两份句柄是本类自己 `LoadImage` / `CreateBadgeIcon` 出来的
  // （`WM_SETICON` 不接管所有权），窗口都没了、Shell 也不会再引用它们，直接
  // 销毁。注意不能照着窗口类里那个 `LoadIcon` 的共享句柄销毁 —— 那不是我们的。
  if (window_icon_small_ != nullptr) {
    ::DestroyIcon(window_icon_small_);
    window_icon_small_ = nullptr;
  }
  if (window_icon_big_ != nullptr) {
    ::DestroyIcon(window_icon_big_);
    window_icon_big_ = nullptr;
  }

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

    // 窗口被拖到另一块缩放比不同的显示器上。任务栏图标是按像素画出来的，
    // 得按新 DPI 重载底图、重画角标，否则 Shell 会把旧尺寸的图拉伸一遍，
    // 数字就糊了。这条消息本体（把窗口 `SetWindowPos` 到新矩形）不在这里
    // 处理，`break` 下去交给 `Win32Window`，别抢它的活。
    case WM_DPICHANGED:
      ApplyWindowIconBadge();
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
