#include "single_instance.h"

namespace {

// 互斥体名字。`Local\` 前缀 = 只在**当前登录会话**里唯一。
//
// 不用 `Global\`：那会让同一台机器上另一个用户的会话也被挡在外面（他该跑
// 自己的一份），而且 `Global\` 需要额外的权限，普通用户可能根本建不出来。
//
// 字符串里带上 App 标识，免得和别的程序撞 —— 同时也是个提醒：换包名的时候
// 这里要跟着改。
constexpr const wchar_t kMutexName[] =
    L"Local\\com.zenkee.mailapp.single-instance";

// 广播消息的名字。`RegisterWindowMessage` 保证同一个字符串在任何进程里都
// 拿到同一个编号，这就是「进程之间对暗号」的全部机制。
constexpr const wchar_t kShowMessageName[] = L"com.zenkee.mailapp.show-window";

// 互斥体句柄。**故意不关**：句柄一旦关掉、又没有别人持有，这个具名对象就
// 被销毁了，紧接着启动的下一份会顺理成章地把自己当成第一个实例。进程退出
// 时系统会替我们关，那正是我们想要的时机。
HANDLE g_mutex = nullptr;
bool g_is_first_instance = false;
bool g_checked = false;

}  // namespace

UINT SingleInstance::show_message() {
  // 缓存住：`RegisterWindowMessage` 每次调用都问一遍系统，而窗口过程每收到
  // 一条消息就要比一次。
  static const UINT id = ::RegisterWindowMessageW(kShowMessageName);
  return id;
}

bool SingleInstance::Acquire() {
  if (g_checked) {
    return g_is_first_instance;
  }
  g_checked = true;

  g_mutex = ::CreateMutexW(nullptr, FALSE, kMutexName);
  if (g_mutex == nullptr) {
    // 极端情况（安全策略不允许建内核对象）。**当作第一个实例放行**：
    // 让 App 因为这件事完全打不开，比偶尔多开一个进程糟糕得多。
    g_is_first_instance = true;
    return true;
  }

  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    g_is_first_instance = false;
    NotifyExistingInstance();
    return false;
  }

  g_is_first_instance = true;
  return true;
}

void SingleInstance::NotifyExistingInstance() {
  // 必须在广播**之前**授权。Windows 的前台锁定规则默认不允许后台进程抢焦点，
  // 而「刚被用户点过」的进程有这个资格 —— 我们正是刚从开始菜单启动的那个。
  // 不授权的话对面那份实例的 `SetForegroundWindow` 会被系统静默忽略，窗口
  // 出来了却还压在别人后面，用户看到的仍然是「点了没反应」。
  ::AllowSetForegroundWindow(ASFW_ANY);
  ::PostMessageW(HWND_BROADCAST, show_message(), 0, 0);
}

bool SingleInstance::HandleMessage(UINT message, HWND hwnd) {
  const UINT show = show_message();
  // `show != 0` 是必须的：注册失败时 `RegisterWindowMessageW` 返回 0，而
  // `WM_NULL` 也正好是 0。托盘菜单收尾会 PostMessage 一条 `WM_NULL`，
  // 不挡掉的话每次都白抢一次前台。
  if (show == 0 || message != show) {
    return false;
  }
  BringToFront(hwnd);
  return true;
}

void SingleInstance::BringToFront(HWND hwnd) {
  if (hwnd == nullptr) {
    return;
  }
  // 最小化过就先还原，否则 `SW_SHOW` 对最小化的窗口没有效果。
  // 这条也在对方实例的 UI 线程上跑（广播消息由它的消息循环派发），
  // 所以这里调窗口 API 是安全的。
  ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(hwnd);
}
