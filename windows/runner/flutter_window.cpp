#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
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

// 窗口几何（位置/大小/最大化）存这个 HKCU 键下，5 个 REG_DWORD：
// X / Y / W / H（外框，**物理像素**，`GetWindowPlacement` 那套坐标）与
// Max（1 = 最大化）。
//
// 键名里的品牌是**差异点**：pro 检出把中间的 `CirroMail` 换成 `CirroMailPro`
// （即 `Software\Zenkee\CirroMailPro\WindowState`）—— 和上面的通道名
// （`com.zenkee.cirromail/window` → pro 的 `...cirromailpro/window`）是同一条
// 规矩。两个 App 可以同时装在一台机器上，共用同一个 HKCU 键会让「一个窗口
// 拖大、另一个跟着变大」。
//
// 为什么用注册表而不是自己的文件：Windows 上 HKCU 就是「每个用户的界面设置」
// 的默认去处，不归 App 管的重置/漫游/清理都跟其它 Win32 App 一致，也不需要
// 我们自己操心路径、权限、编码（UTF-16 键名）和卸载残留。
constexpr wchar_t kWindowStateKey[] =
    L"Software\\Zenkee\\CirroMail\\WindowState";

// 值名单独列出来而不是就地写 L"X"：保存和读取两边各用一次，拼错一个字母的
// 结果就是「存了但永远读不回来」，编译器又不会管。
constexpr wchar_t kStateValueX[] = L"X";
constexpr wchar_t kStateValueY[] = L"Y";
constexpr wchar_t kStateValueW[] = L"W";
constexpr wchar_t kStateValueH[] = L"H";
constexpr wchar_t kStateValueMax[] = L"Max";

// 启动几何的可信区间（物理像素）。
//
// 上界 16384：比任何单块显示器的边长都宽裕，再大的值只可能来自损坏/伪造的
// 数据；真按它建窗会得到一个用户根本没法操作的巨型窗口（再叠上 DPI 缩放更
// 吓人）。
// 下界 320x240：再小就已经不是「用户把它缩到这么小」，而是记录了坏值 ——
// 那个尺寸下窗口连标题栏都放不下。
constexpr DWORD kMinWindowWidth = 320;
constexpr DWORD kMinWindowHeight = 240;
constexpr DWORD kMaxWindowSide = 16384;

// 恢复位置时，外框必须和某块显示器的**可用工作区**有这么多的重叠
// （物理像素），否则放弃保存的位置、退回默认的 10,10。
//
// 为什么不是「有 1 像素重叠就算数」：只压到屏幕边缘一条缝的窗口，用户既看不
// 见内容也抓不住标题栏拖回来 —— 效果跟窗口飞到屏幕外完全一样，还得自己去
// 显示设置里找。120x80 比一个标题栏加关闭按钮大，保证恢复出来的窗口至少能
// 被拖、被点。
constexpr LONG kMinVisibleWidth = 120;
constexpr LONG kMinVisibleHeight = 80;

// 读一个 REG_DWORD。读不到、类型不对、长度不对都返回「没有」，由调用方决定
// 退回哪个默认值 —— 五个值各有各的默认，不该让一个坏值把其它四个一起带走。
std::optional<DWORD> ReadStateDword(HKEY key, const wchar_t* name) {
  DWORD type = 0;
  DWORD value = 0;
  DWORD size = static_cast<DWORD>(sizeof(value));
  if (::RegQueryValueExW(key, name, nullptr, &type,
                         reinterpret_cast<LPBYTE>(&value),
                         &size) != ERROR_SUCCESS) {
    return std::nullopt;
  }
  // 类型和长度都要核对：这个键用户拿 regedit 就能改，不能假设它还是自己写的
  // 那个形状。长度按字节算，DWORD 是 4。
  if (type != REG_DWORD || size != static_cast<DWORD>(sizeof(value))) {
    return std::nullopt;
  }
  return value;
}

// 写一个 REG_DWORD。失败静默：下一个保存点还会再试一次，位置记忆不需要让
// 用户知道某一次写失败了（也不值得为它弹窗）。
void WriteStateDword(HKEY key, const wchar_t* name, DWORD value) {
  static_cast<void>(::RegSetValueExW(
      key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value),
      static_cast<DWORD>(sizeof(value))));
}

// [EnumDisplayMonitors] 回调要的上下文。
struct WorkAreaSearch {
  RECT candidate;
  bool overlaps;
};

// 候选矩形和某块显示器的可用工作区重叠得够不够多。
//
// 用 `rcWork` 而不是 `rcMonitor`：任务栏/桌面停靠栏压着的那一条虽然算在「屏幕
// 上」，但窗口放那儿是看不全也点不到的；按整屏判定等于「把窗口藏在任务栏后面」
// 也算恢复成功。
BOOL CALLBACK FindUsableWorkArea(HMONITOR monitor, HDC, LPRECT,
                                 LPARAM context) {
  auto* search = reinterpret_cast<WorkAreaSearch*>(context);
  MONITORINFO info{};
  info.cbSize = static_cast<DWORD>(sizeof(info));
  if (::GetMonitorInfoW(monitor, &info)) {
    const RECT& work = info.rcWork;
    // 用 64 位算差值：两块显示器的坐标都可能贴近 LONG 的两端（rcWork.left 在
    // 主屏左边的显示器上是负的），先减再判会溢出成「看起来重叠了」。
    const int64_t overlap_width =
        static_cast<int64_t>(std::min(search->candidate.right, work.right)) -
        static_cast<int64_t>(std::max(search->candidate.left, work.left));
    const int64_t overlap_height =
        static_cast<int64_t>(std::min(search->candidate.bottom, work.bottom)) -
        static_cast<int64_t>(std::max(search->candidate.top, work.top));
    if (overlap_width >= kMinVisibleWidth &&
        overlap_height >= kMinVisibleHeight) {
      search->overlaps = true;
      return FALSE;  // 找到一块就够了，别接着枚举。
    }
  }
  return TRUE;
}

// 候选矩形（物理像素）在**任何**一块当前接着的显示器上是否够可见。
bool OverlapsUsableWorkArea(const RECT& candidate) {
  WorkAreaSearch search{candidate, false};
  ::EnumDisplayMonitors(nullptr, nullptr, FindUsableWorkArea,
                        reinterpret_cast<LPARAM>(&search));
  return search.overlaps;
}

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

StartupFrame LoadStartupFrame() {
  // 无效 = 保持 `Create` 给的默认几何（10,10 + 1280x720，逻辑像素）。
  StartupFrame startup_frame{};
  startup_frame.maximized = false;
  startup_frame.valid = false;

  HKEY key = nullptr;
  // 只读打开（`KEY_QUERY_VALUE`，不要写权限：光是读位置不该有任何机会改坏
  // 别的值）。键不存在是最常见的情况 —— 第一次启动 —— 直接静默返回无效值。
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kWindowStateKey, 0, KEY_QUERY_VALUE,
                      &key) == ERROR_SUCCESS) {
    const std::optional<DWORD> saved_x = ReadStateDword(key, kStateValueX);
    const std::optional<DWORD> saved_y = ReadStateDword(key, kStateValueY);
    const std::optional<DWORD> saved_w = ReadStateDword(key, kStateValueW);
    const std::optional<DWORD> saved_h = ReadStateDword(key, kStateValueH);
    const std::optional<DWORD> saved_max = ReadStateDword(key, kStateValueMax);
    ::RegCloseKey(key);

    // 最大化是独立的开关：值不在/坏了就当「不最大化」，比「莫名满屏」温和。
    startup_frame.maximized = saved_max.has_value() && *saved_max != 0;

    // 尺寸：两个都得在区间里才采用。只信一半没有意义（宽可信、高是坏值时
    // 拼出来的形状照样是错的）。
    if (!saved_w.has_value() || !saved_h.has_value() ||
        *saved_w < kMinWindowWidth || *saved_w > kMaxWindowSide ||
        *saved_h < kMinWindowHeight || *saved_h > kMaxWindowSide) {
      // 尺寸不可信：整帧不可信。位置单独拿出来用也不行 —— 没有可信的宽高就
      // 拼不出矩形，而「默认 1280x720 物理像素」在缩放的屏幕上也不是用户在
      // 那个位置看到的大小。
      return startup_frame;
    }
    const DWORD width = *saved_w;
    const DWORD height = *saved_h;

    // 位置。X/Y 是按位存进 DWORD 的 LONG（见 [SaveWindowState]），这里还原成
    // 有符号数：主屏左边/上边的显示器上坐标就是负的。`DWORD → LONG` 的转换在
    // 高位被置位时依赖补码，Windows 上 LONG 和 DWORD 都是 32 位、内存里同一串
    // 比特，MSVC/GCC 都按补码解释（C++20 起也已经是定义良好的行为）。
    bool have_position = false;
    RECT bounds{};
    if (saved_x.has_value() && saved_y.has_value()) {
      const int64_t left = static_cast<LONG>(*saved_x);
      const int64_t top = static_cast<LONG>(*saved_y);
      const int64_t right = left + static_cast<int64_t>(width);
      const int64_t bottom = top + static_cast<int64_t>(height);
      if (right <= std::numeric_limits<LONG>::max() &&
          bottom <= std::numeric_limits<LONG>::max()) {
        const RECT candidate{static_cast<LONG>(left), static_cast<LONG>(top),
                             static_cast<LONG>(right),
                             static_cast<LONG>(bottom)};
        // 校验放在物理坐标上：显示器的 rcWork 就是物理像素，两边同一个坐标系，
        // 不需要中间换算 —— 换算过的位置校验是「拿错坐标系去问对不对」。
        if (OverlapsUsableWorkArea(candidate)) {
          bounds = candidate;
          have_position = true;
        }
      }
    }

    if (!have_position) {
      // 位置不可信（没存过、或者那块显示器已经不在/只剩一条缝）：退回默认的
      // 10,10，尺寸照样用 —— 这是加这个功能之前的行为，但至少把大小记住了。
      // 这里 10,10 是物理像素，就在主屏左上角；`Create` 的默认位置是逻辑像素
      // 10,10，缩放的屏幕上会落在 (15,15) 之类，两者视觉上都是左上角。
      bounds = RECT{10, 10, static_cast<LONG>(10 + width),
                    static_cast<LONG>(10 + height)};
    }

    startup_frame.bounds = bounds;
    startup_frame.valid = true;
  }

  return startup_frame;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // 先把外框摆到上次的位置/大小，再量客户区。
  //
  // 为什么放在建 `flutter_controller_` **之前**：控制器是按 `GetClientArea()`
  // 的尺寸建的。先摆好就一次到位；反过来会先按默认尺寸建一次 surface、再因为
  // 随后的 `WM_SIZE` 重来一次 —— 启动时白丢一帧的渲染资源，还可能闪一下。
  //
  // 为什么用 `SetWindowPos` 而不是让 `Create` 直接建在这个矩形上：`Create` 只
  // 收逻辑像素，物理 → 逻辑再在它内部乘回去，负坐标（副屏在主屏左边/上边）在
  // `Win32Window::Point` 的无符号字段里表达不了，混合 DPI 下它挑显示器的口径也
  // 和我们按物理坐标挑的不是同一块（见 [StartupFrame] 的注释）。
  //
  // 这件事是安全的：此刻窗口还隐藏着（要等首帧回调才 `Show`），用户看不到任何
  // 跳动；`child_content_` 也还没挂上，`SetWindowPos` 带来的那条 `WM_SIZE` 在
  // `Win32Window::MessageHandler` 里只会被 `child_content_` 的空判断放过，而
  // [SaveWindowState] 那头还有 `window_shown_` 闸门挡着，不会把默认几何存回去。
  if (startup_frame_.valid) {
    const RECT& bounds = startup_frame_.bounds;
    ::SetWindowPos(GetHandle(), nullptr, bounds.left, bounds.top,
                   bounds.right - bounds.left, bounds.bottom - bounds.top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
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
    // 记下「已经显示过」：在这之前几条 `WM_SIZE` 是建窗构造出来的中间值，
    // [SaveWindowState] 靠这个闸门跳过它们。
    window_shown_ = true;

    // 上次退出时是最大化：一步到位 `ShowWindow(SW_SHOWMAXIMIZED)`，别先
    // `Show()`（那是 `SW_SHOWNORMAL`，只会按还原尺寸显示）再补一次最大化 ——
    // 中间会先画出一个小窗口再铺满，启动时闪一下。
    if (start_maximized_) {
      ::ShowWindow(GetHandle(), SW_SHOWMAXIMIZED);
    } else {
      this->Show();
    }

    // 冒烟自检：首帧出来之后立刻进「关窗后」的状态。见上面 kSmokeEnvVar。
    // 放在显示/最大化之后，和以前一样 —— 它要验的是「已经显示过的窗口被关掉」
    // 这条路，顺序反了就没意义了。
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

void FlutterWindow::SetStartupFrame(const StartupFrame& startup_frame) {
  // 只是记下来 —— 真正摆窗口的是 `OnCreate`（它跟着 `Create` 一起跑，见头文件
  // 里 [SetStartupFrame] 的注释）。
  startup_frame_ = startup_frame;
}

void FlutterWindow::SetStartMaximized(bool maximized) {
  start_maximized_ = maximized;
  // 第一次保存时若窗口还没显示过（`showCmd == SW_HIDE`），[SaveWindowState]
  // 对「最大化」的判断是「沿用上一次」；把启动时的意图先记进去，免得
  // 「启动就该最大化、但首帧之前先存了一次」把 Max 记成 0。
  if (!has_saved_state_) {
    saved_maximized_ = maximized;
  }
}

void FlutterWindow::SaveWindowState() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  // 窗口还没显示过：`Create` 内部和首帧之前的几何都是构造期间的中间值，
  // 那时 `main.cpp` 甚至还没把「上次是不是最大化」传进来。存它只会把刚读出
  // 来的正确值覆盖掉。
  if (!window_shown_) {
    return;
  }

  // 位置/大小取 `rcNormalPosition`，不是 `GetWindowRect`：最大化时
  // `GetWindowRect` 给的是铺满屏幕的矩形，存下来下次启动拿它当「还原尺寸」，
  // 一还原就已经是满屏了，用户再也没法把窗口缩小；`rcNormalPosition` 始终是
  // **还原之后**那个外框，正是下次建窗要用的尺寸。
  WINDOWPLACEMENT placement{};
  placement.length = static_cast<UINT>(sizeof(placement));
  if (!::GetWindowPlacement(hwnd, &placement)) {
    return;
  }
  const RECT& frame = placement.rcNormalPosition;

  // 最大化状态：`showCmd == SW_SHOWMAXIMIZED` 是明确的。
  //
  // 最小化时它只说「最小化」，看不出还原之后会不会最大化 —— 那时**不能**当成
  // 「没最大化」记下来，否则「最大化着、直接最小化、然后退出」会把满屏状态
  // 丢掉；系统在 `WPF_RESTORETOMAXIMIZED` 里记着这个信息，照它来。
  //
  // 其余状态（最典型的是藏在通知区里的 `SW_HIDE`）根本没带这个信息，沿用
  // 上一次的判断 —— 藏窗之前那一次保存（[HideToTray]）已经把真实状态写进去
  // 了，这里只是别把它擦掉。
  bool maximized = saved_maximized_;
  if (placement.showCmd == SW_SHOWMAXIMIZED) {
    maximized = true;
  } else if (placement.showCmd == SW_SHOWMINIMIZED) {
    maximized = (placement.flags & WPF_RESTORETOMAXIMIZED) != 0;
  }

  // 幂等：拖动/贴边时 `WM_SIZE` 会连着来几十上百条，和上一次写进去的一样就
  // 直接走人，不开键、不写盘。这条 `return` 也是「WM_SIZE 里不会有写操作
  // 反过来触发消息」的兜底 —— 本来 `GetWindowPlacement` / `RegSetValueExW`
  // 都不发窗口消息，不存在递归，但少一次无谓的注册表往返总是好的。
  if (has_saved_state_ && ::EqualRect(&saved_rect_, &frame) &&
      maximized == saved_maximized_) {
    return;
  }

  // 键不存在就建（第一次保存）。`KEY_SET_VALUE` 只要写权限；不要
  // `KEY_ALL_ACCESS` —— 用不到读和删除。失败静默返回，下次保存点会再来。
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kWindowStateKey, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }
  // X/Y 有可能是负的（显示器在主屏左边/上边），按位原样存进 DWORD；读回来时
  // 再还原成有符号数（见 [LoadStartupFrame]）。恢复走 `SetWindowPos` 按物理
  // 像素摆，负坐标照样摆得回去。
  WriteStateDword(key, kStateValueX, static_cast<DWORD>(frame.left));
  WriteStateDword(key, kStateValueY, static_cast<DWORD>(frame.top));
  WriteStateDword(key, kStateValueW,
                  static_cast<DWORD>(frame.right - frame.left));
  WriteStateDword(key, kStateValueH,
                  static_cast<DWORD>(frame.bottom - frame.top));
  WriteStateDword(key, kStateValueMax, maximized ? 1u : 0u);
  ::RegCloseKey(key);

  // 记下「刚才写进去的是什么」。某个值单独写失败也照记：五个值是一套，
  // 下次用户再动窗口时整组重写一遍，比为了一个坏值反复重试更简单。
  saved_rect_ = frame;
  saved_maximized_ = maximized;
  has_saved_state_ = true;
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
  // 藏之前存。`SW_HIDE` 之后 `GetWindowPlacement` 的 `showCmd` 变成 `SW_HIDE`，
  // 位置还在、但「现在是不是最大化」这半条信息就只剩上一次的记录了；趁窗口
  // 还醒着存一遍最准。
  //
  // 这是「藏窗」的唯一保存点，两条路都经过它：`WM_CLOSE`（[MessageHandler]）
  // 和 `Cmd+W`（Dart 的 `hideMainWindow`）。只挂在 `WM_CLOSE` 上会漏掉后者 ——
  // 那正是最容易发生的一种：用户按 `Cmd+W` 藏窗，然后从托盘退出。
  SaveWindowState();
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
  // 销毁窗口之前再存一次。这是唯一真正结束进程的路，也是最后一个还能拿到
  // `GetWindowPlacement` 的时刻；窗口这会儿多半藏在通知区里（这里会走
  // 上面那条「showCmd 是 SW_HIDE 就沿用上一次判断」的分支），存出来的值跟
  // 藏窗那次一致，幂等判断会直接放过 —— 留着它是为了「以后退出路径变了」
  // 也不会丢状态。
  SaveWindowState();
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
  // 局部变量不能叫 `small` / `big`：`rpcndr.h` 把它们 `#define` 成 `char`
  // （见头文件里的注释），这里用 `_icon` 后缀避开。
  HICON small_icon = LoadAppIcon(small_size);
  HICON big_icon = LoadAppIcon(big_size);

  if (badge_count_ > 0) {
    // 把数字叠上去。任何一档画不出来就退回那一档的原图 —— 宁可没有数字，
    // 也不能让任务栏图标变成一个透明块（`CreateBadgeIcon` 失败返回 nullptr）。
    if (small_icon != nullptr) {
      HICON badged = CreateBadgeIcon(small_icon, badge_count_, small_size);
      if (badged != nullptr) {
        ::DestroyIcon(small_icon);
        small_icon = badged;
      }
    }
    if (big_icon != nullptr) {
      HICON badged = CreateBadgeIcon(big_icon, badge_count_, big_size);
      if (badged != nullptr) {
        ::DestroyIcon(big_icon);
        big_icon = badged;
      }
    }
  }

  // 这一行之后两个句柄的所有权归窗口：由 [SetWindowIcons] 换上并负责销毁
  // 上一对。`badge_count_ == 0` 时传进去的就是刚载入的原图，等于「恢复原图标」。
  SetWindowIcons(small_icon, big_icon);
}

void FlutterWindow::SetWindowIcons(HICON small_icon, HICON big_icon) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    // 窗口已经没了（正常退出流程里不该走到这里）：句柄没人接手，就地销毁，
    // 不留悬空的所有权。
    if (small_icon != nullptr) {
      ::DestroyIcon(small_icon);
    }
    if (big_icon != nullptr) {
      ::DestroyIcon(big_icon);
    }
    return;
  }

  // 先换、后销毁旧的：`WM_SETICON` 之后 Shell 才不再引用旧的那一份。
  // 不用 `WM_SETICON` 的返回值回收：它返回的是**先前那个**句柄，可能是窗口类
  // 里 `LoadIcon` 的共享图标（`WM_SETICON` 之前的状态），那种句柄销毁了会
  // 波及所有用同一个图标的窗口。只销毁我们自己记录、自己创建的那一对。
  if (small_icon != nullptr) {
    HICON previous = window_icon_small_;
    window_icon_small_ = small_icon;
    ::SendMessageW(hwnd, WM_SETICON, ICON_SMALL,
                   reinterpret_cast<LPARAM>(small_icon));
    if (previous != nullptr) {
      ::DestroyIcon(previous);
    }
  }
  if (big_icon != nullptr) {
    HICON previous = window_icon_big_;
    window_icon_big_ = big_icon;
    ::SendMessageW(hwnd, WM_SETICON, ICON_BIG,
                   reinterpret_cast<LPARAM>(big_icon));
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

    // 拖动/缩放结束：这是「用户把窗口摆成这样了」最干净的落点。拖动途中
    // 每一条 `WM_SIZE` 也已经存过（下面那条），这里再存一次是为了拿到松手后
    // 的最终矩形 —— 拖动中的最后一条 `WM_SIZE` 和松手位置之间可能还差几像素。
    case WM_EXITSIZEMOVE:
      SaveWindowState();
      break;

    // 最大化/还原/贴边、以及程序自己 `SetWindowPos` 造成的变化都不经过
    // `WM_EXITSIZEMOVE`，只能靠这条。`SIZE_MAXSHOW`/`SIZE_MAXHIDE` 是「别的
    // 窗口最大化/还原了，通知你一下」，自己的尺寸没变，不用存。
    case WM_SIZE:
      if (wparam == SIZE_RESTORED || wparam == SIZE_MINIMIZED ||
          wparam == SIZE_MAXIMIZED) {
        SaveWindowState();
      }
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
      // 先存再分叉：无论是「藏进通知区」还是关机真的退出，这条都是**两条路
      // 共用**的最后一个确定经过的点。分成两个分支各写一遍，早晚会漏掉一边
      // （比如以后再加第三条分支）。
      SaveWindowState();
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
