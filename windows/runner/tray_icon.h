#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>

// 任务栏通知区（下称「托盘」）里的那个图标，以及它弹出来的菜单。
//
// 它和 macOS 的 `NSStatusItem` 是同一件事的两个平台实现：关掉窗口之后 App
// 不退，靠这个小图标让用户还能把窗口叫回来、或者显式退出。见 README
// 「Windows：关掉窗口之后 App 还活在通知区里」。
//
// **消息路由是调用方的责任**：`Shell_NotifyIcon` 的回调消息发给 owner 窗口，
// 这个类自己没有窗口，收不到任何东西。owner 必须把它收到的**每一条**消息都
// 转给 [HandleMessage]，返回 true 的那些要吞掉（`return 0`）。
class TrayIcon {
 public:
  // |owner| 是接收回调消息的窗口 —— 关窗之后它依然存在（我们只是把它藏起来，
  // 不销毁），所以它一直收得到消息。|callback_message| 是回调消息的编号，
  // 取 `WM_APP` 段里的一个值。见 [FlutterWindow] 里的常量。
  TrayIcon(HWND owner, UINT callback_message);
  ~TrayIcon();

  // 把图标放进通知区。幂等（已经在里面时走 `NIM_MODIFY`）。析构时会自动摘掉。
  void Add();

  // 从通知区摘掉。**退出之前必须调**，否则图标会一直挂在那儿，要等鼠标划过
  // 才消失 —— 那是 Shell 发现「这个窗口没了」之后才回收的。
  void Remove();

  // 返回 true 表示这条消息是托盘的（`Shell_NotifyIcon` 的回调，或者 Explorer
  // 重启后那条 `TaskbarCreated` 广播），已经处理掉了，调用方应当 `return 0`。
  // 与托盘无关的消息返回 false。
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

  // 左键点图标（等价于菜单里的「打开主窗口」）。
  void set_on_open(std::function<void()> callback) {
    on_open_ = std::move(callback);
  }

  // 菜单里的「退出 Cirro Mail」。
  void set_on_quit(std::function<void()> callback) {
    on_quit_ = std::move(callback);
  }

 private:
  void ShowMenu();
  bool AddOrModify();
  void ReAddIfWanted();

  HWND owner_;
  UINT callback_message_;

  // 「我们希望图标在通知区里」。第一次关窗时才置上 —— Explorer 重启（它会
  // 广播 `TaskbarCreated`）之后要靠它决定要不要补一个回去，因为那时候 Shell
  // 已经把图标全丢了，而且**不会**通知你。没关过窗的 App 不该突然冒出图标。
  bool wanted_ = false;

  // 「图标此刻确实在通知区里」。和 [wanted_] 是两件事：`NIM_ADD` 一个已经在
  // 的图标是静默失败，所以补图标时必须知道该用 `NIM_ADD` 还是 `NIM_MODIFY`。
  bool added_ = false;

  // `NIM_SETVERSION` 到底成功了没有。回调消息里「事件码」放哪个字取决于它，
  // 见 [HandleMessage]。
  bool version4_ = false;

  // 图标句柄。用 `LoadImage`（**不带** `LR_SHARED`）而不是 `LoadIcon`：
  // `LoadIcon` 只会给最大的那一档，缩到 16×16 很糊。代价是拿到的是自己的一份，
  // 所以析构里要 `DestroyIcon`（带 `LR_SHARED` 的句柄则**绝不能**销毁）。
  HICON icon_ = nullptr;

  std::function<void()> on_open_;
  std::function<void()> on_quit_;
};

#endif  // RUNNER_TRAY_ICON_H_
