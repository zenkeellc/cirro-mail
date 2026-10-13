#include "tray_icon.h"

#include <shellapi.h>

#include <string>

#include "resource.h"

namespace {

// 菜单命令 ID。只有两项，用不着 `resource.h` 那套 IDR_ 体系。
constexpr UINT kCommandOpen = 1;
constexpr UINT kCommandQuit = 2;

// 当前用户界面语言的**首选**语言 ID（低 10 位是主语言，中文是 0x04）。
// `GetUserDefaultUILanguage` 而不是 `GetSystemDefaultUILanguage`：跟着用户
// 自己选的语言走，和 App 里的中英文切换口径一致。
bool PrefersChinese() {
  return (::GetUserDefaultUILanguage() & 0xFF) == LANG_CHINESE;
}

std::wstring OpenLabel() {
  return PrefersChinese() ? L"打开主窗口" : L"Open Cirro Mail";
}

std::wstring QuitLabel() {
  return PrefersChinese() ? L"退出 Cirro Mail" : L"Quit Cirro Mail";
}

// Explorer 重启（或者用户重登）之后广播的那个消息。名字是固定的 ——
// 这是 Shell 和被通知方之间的约定，不是我们的通道。
//
// 返回 0 表示注册失败；**调用方必须把 0 当成「这条不认」**，因为
// `WM_NULL` 的值就是 0，不挡掉的话一条无害的 `WM_NULL` 会被当成广播。
UINT TaskbarCreatedMessage() {
  static const UINT id = ::RegisterWindowMessageW(L"TaskbarCreated");
  return id;
}

}  // namespace

TrayIcon::TrayIcon(HWND owner, UINT callback_message)
    : owner_(owner), callback_message_(callback_message) {}

TrayIcon::~TrayIcon() {
  Remove();
  if (icon_) {
    ::DestroyIcon(icon_);
    icon_ = nullptr;
  }
}

void TrayIcon::Add() {
  wanted_ = true;
  AddOrModify();
}

void TrayIcon::Remove() {
  wanted_ = false;
  // 摘掉之后 `added_` 这份记录也要跟着作废 —— 否则下一次 `Add()` 会走
  // `NIM_MODIFY`，而图标已经不在通知区里了，那是个静默失败。
  added_ = false;
  if (!owner_) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = owner_;
  data.uID = 1;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
}

bool TrayIcon::AddOrModify() {
  if (!owner_) {
    return false;
  }

  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = owner_;
  data.uID = 1;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = callback_message_;

  if (!icon_) {
    // 用 `LoadImage`（**不带** `LR_SHARED`）而不是 `LoadIcon`：`LoadIcon`
    // 只会给最大的那一档，缩到 16×16 很糊；`LoadImage` 配合 LR_DEFAULTSIZE 时
    // 如果 `.ico` 里没有正好等于目标尺寸的那一档，它会**最近邻缩放**最近的一档。
    // `.ico` 里 16/24/32/48/64/128/256 七档都在（见 `resources/app_icon.ico`），
    // 无论 Shell 要哪一档都能挑到合适的。
    icon_ = static_cast<HICON>(::LoadImageW(GetModuleHandleW(nullptr),
                                            MAKEINTRESOURCEW(IDI_APP_ICON),
                                            IMAGE_ICON, 0, 0,
                                            LR_DEFAULTSIZE));
    if (!icon_) {
      return false;
    }
  }
  data.hIcon = icon_;
  // `lstrcpynW` 而不是 `wcscpy_s`：`szTip` 是定长数组，名字长了要截断而不是
  // 崩（`wcscpy_s` 的「安全」版本会直接触发 invalid parameter handler）。
  ::lstrcpynW(data.szTip, L"Cirro Mail", ARRAYSIZE(data.szTip));

  // 第一次是 `NIM_ADD`，之后再进来就是 `NIM_MODIFY` —— 直接 `NIM_ADD`
  // 一个已经在里面的图标是静默失败（返回值 false），Explorer 重启之后
  // 补图标那一路就会踩到。
  const DWORD op = added_ ? NIM_MODIFY : NIM_ADD;
  if (!::Shell_NotifyIconW(op, &data)) {
    if (op == NIM_MODIFY) {
      return false;
    }
    // Explorer 还没起来（登录早期）时会失败，重试一次没什么损失。
    if (!::Shell_NotifyIconW(NIM_ADD, &data)) {
      return false;
    }
  }
  added_ = true;

  // `NOTIFYICON_VERSION_4` 之后回调的**参数位置变了**（见 [HandleMessage]），
  // 所以记下版本切换到底成没成 —— 成了就按 v4 那一套解，没成就按老的那一套。
  // 不能两边都试：v4 里 `LOWORD(wParam)` 是**屏幕横坐标**，屏幕上 x=514 的
  // 位置恰好等于 `WM_LBUTTONUP` 的数值，混着解会随机误触发。
  data.uVersion = NOTIFYICON_VERSION_4;
  version4_ = ::Shell_NotifyIconW(NIM_SETVERSION, &data) != FALSE;
  return true;
}

void TrayIcon::ReAddIfWanted() {
  if (!wanted_) {
    return;
  }
  // Shell 把图标丢了，`added_` 这份记录也跟着作废。
  added_ = false;
  AddOrModify();
}

bool TrayIcon::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  const UINT taskbar_created = TaskbarCreatedMessage();
  // `!= 0` 是必须的：`RegisterWindowMessageW` 失败时返回 0，而 `WM_NULL`
  // 恰好也是 0 —— 不挡掉的话每一条 `WM_NULL` 都会当成 Explorer 重启。
  if (taskbar_created != 0 && message == taskbar_created) {
    ReAddIfWanted();
    return true;
  }

  if (message != callback_message_) {
    return false;
  }

  // 两套参数布局（MSDN 的 `NOTIFYICONDATA.uVersion` 一节）：
  //
  //   NOTIFYICON_VERSION_4：wParam 低位/高位 = 光标 x/y，lParam 低位 = 事件
  //                         （`NIN_SELECT` / `NIN_KEYSELECT` / `WM_CONTEXTMENU`），
  //                         lParam 高位 = 图标 id。
  //   老版本：              wParam 低位 = 鼠标消息（`WM_LBUTTONUP` …），
  //                         lParam 低位 = 图标 id。
  //
  // 所以「事件码」在哪个字里，取决于版本，二选一。
  const UINT event_code =
      version4_ ? LOWORD(lparam) : LOWORD(wparam);

  switch (event_code) {
    case WM_LBUTTONUP:
    case NIN_SELECT:
    case NIN_KEYSELECT:
      // 左键（或键盘选中）= 打开窗口。桌面上这是个很难猜错的约定，
      // 不用再让用户先点开菜单。
      if (on_open_) {
        on_open_();
      }
      return true;

    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowMenu();
      return true;

    default:
      return true;  // 还是托盘的消息，只是我们不关心（移动、双击之类）。
  }
}

void TrayIcon::ShowMenu() {
  if (!owner_) {
    return;
  }

  HMENU menu = ::CreatePopupMenu();
  if (!menu) {
    return;
  }
  const std::wstring open_label = OpenLabel();
  const std::wstring quit_label = QuitLabel();
  ::AppendMenuW(menu, MF_STRING, kCommandOpen, open_label.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kCommandQuit, quit_label.c_str());

  POINT cursor{};
  ::GetCursorPos(&cursor);

  // `SetForegroundWindow` 这一步是**必需的**，不是礼节：托盘菜单是 Shell
  // 进程弹的，如果 owner 不是前台窗口，菜单会弹出来但**点外面不关**
  // （经典 bug，MSDN 的 `TrackPopupMenu` 文档里专门提了）。
  ::SetForegroundWindow(owner_);

  // 用 `TPM_RETURNCMD` 拿返回值，而不是走 `WM_COMMAND`：我们没有菜单栏、
  // 也没挂 `Menu` 处理，返回值是最省事也最不容易接错的一条路。
  const UINT command = ::TrackPopupMenu(menu, TPM_RETURNCMD, cursor.x, cursor.y,
                                        0, owner_, nullptr);

  ::DestroyMenu(menu);

  // 拾遗：某些 Windows 版本里这条 `PostMessage` 是关掉菜单的可靠收尾
  // （同样出自 MSDN 的那段说明）。
  ::PostMessageW(owner_, WM_NULL, 0, 0);

  if (command == kCommandOpen && on_open_) {
    on_open_();
  } else if (command == kCommandQuit && on_quit_) {
    on_quit_();
  }
}
