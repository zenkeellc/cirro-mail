#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// 「同一份 App 只跑一个进程」这件事的 Windows 实现。
//
// 为什么这里非做不可（macOS 那边不用）：关窗变成了「藏进通知区」，进程仍然
// 活着、仍然在轮询、仍然登记着推送。此时再从开始菜单点一次，任务栏上什么都
// 没有，用户完全有理由认为 App 没开 —— 于是开出**第二个进程**。两个进程抢同
// 一个 SQLite 库、各自登记一份 FCM token、同一封新信弹两份通知，而且关掉一个
// 窗口另一个还活着，用户根本搞不清哪个是哪个。
//
// macOS 上没有这个问题是因为点 Dock 图标本来就只是激活已有的那个 App。
//
// 做法是最小的一对：一个具名互斥体判「我是不是第一个」，一条
// `RegisterWindowMessage` 广播消息（后开的那份在退出前发出去）让先来的那份把
// 窗口摆到前面。两者都不需要任何 IPC 管道或额外的线程。
//
// **没有用 `FindWindow` 找主窗口**：那要靠窗口标题或者窗口类名，而类名
// （`FLUTTER_RUNNER_WIN32_WINDOW`）是所有 Flutter 桌面 App 共用的，两个不同
// 的 Flutter App 之间会串。广播消息则只在用同一个字符串注册过的窗口之间有效。
class SingleInstance {
 public:
  // 抢「第一个实例」的名分。
  //
  // 返回 true：本进程就是第一个，正常启动，并且**之后要**在收到
  // [show_message] 广播时调 [HandleMessage]。
  //
  // 返回 false：已经有一个在跑了，**它已经被请求把窗口摆到前面**（见
  // [NotifyExistingInstance]），调用方应当立刻退出，别再建窗口。
  //
  // 幂等：重复调用只会重复判一次，第一次的结果就是结果。
  static bool Acquire();

  // 后开的那份在退出前调用：请已经跑着的那份把窗口弄到前面来。
  //
  // 先 `AllowSetForegroundWindow(ASFW_ANY)` 再广播是**必需的**：Windows 的
  // 前台锁定规则默认不允许一个后台进程抢焦点，只有刚被用户点过（比如刚从
  // 开始菜单启动）的进程才有资格授权。不授权的话那份实例的 `SetForegroundWindow`
  // 会被系统忽略 —— 窗口是出来了，但还压在别的窗口后面，用户看到的依旧是
  // 「点了没反应」，跟不处理没区别。
  //
  // 无返回值：发不到也没什么可做的，调用方反正要退出了。
  static void NotifyExistingInstance();

  // 广播消息的编号。自己窗口的 `WndProc` 收到它就交给 [HandleMessage]。
  static UINT show_message();

  // 处理一条消息。|message| 是本进程要认的广播（返回 true 表示已处理），
  // 这时把 |hwnd| 摆到前面。与单实例无关的消息返回 false。
  static bool HandleMessage(UINT message, HWND hwnd);

 private:
  static void BringToFront(HWND hwnd);
};

#endif  // RUNNER_SINGLE_INSTANCE_H_
