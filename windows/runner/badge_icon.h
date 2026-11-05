#ifndef RUNNER_BADGE_ICON_H_
#define RUNNER_BADGE_ICON_H_

#include <windows.h>

// 把「未读数」画成角标叠在 |base| 上，返回一张**新建**的 HICON。
//
// 为什么单独一个文件：任务栏窗口图标（`flutter_window.cpp`）和通知区托盘图标
// （`tray_icon.cpp`）要长同一个样子，画法只能有一份；而 Windows 不会替任何人
// 接管图标句柄的所有权 —— 两边各自持有、各自 `DestroyIcon` 自己拿到的那一份。
//
// |count| <= 0 返回 nullptr：调用方本来就该走「换回原图标」那条路，这里不画
// 一张空角标。数字超过 99 时画成 `99+`（Dart 侧传的是原始数，截断在这里做）。
//
// |size| 期望的边长（像素），调用方按系统度量取（16/32px 那一档）。
// |base| **必须**是按同一个 |size| 载入的那一份图标（见两个调用方里的
// `LoadImage`）：尺寸对不上时会被 GDI+ 缩放，那一道糊是白白丢掉的。
//
// 失败（GDI+ 起不来、画不出来、base 无效）一律返回 nullptr，不抛也不弹框 ——
// 徽章是装饰，画不出来就只是没有数字。
HICON CreateBadgeIcon(HICON base, int count, int size);

#endif  // RUNNER_BADGE_ICON_H_
