#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <gtk/gtk.h>

#include <functional>

#ifdef CIRRO_HAVE_AYATANA_APPINDICATOR
#include <libayatana-appindicator/app-indicator.h>
#endif

// 顶栏 / 状态栏里的那个图标，以及它弹出来的菜单。
//
// 和 macOS 的 `NSStatusItem`、Windows 的 `windows/runner/tray_icon.{h,cpp}`
// 是同一件事的第三个实现：关掉窗口之后 App 不退，靠它把窗口叫回来、或者显式
// 退出。见 README「Linux：关掉窗口之后 App 还活在顶栏里」。
//
// **两套后端，CMake 里探到哪个用哪个**（见 `linux/runner/CMakeLists.txt` 里
// 那段 `pkg_check_modules(... QUIET)`）：
//
//   * `libayatana-appindicator3`：现代桌面的正路。GNOME 3.26 之后把内置的
//     状态栏图标整个去掉了，只有走 AppIndicator 协议才显示得出来（GNOME 上
//     还要另外装 AppIndicator 扩展）。
//   * `GtkStatusIcon`：GTK 自带、零依赖，但**已废弃**，而且在 GNOME 上根本
//     不显示 —— 这正是 appindicator 存在的理由。作为没装 appindicator 时的
//     兜底：有总比没有强，X11/XFCE/MATE/KDE 上它是能用的。
//
// 两套后端的 API 差别不小（一个自带菜单容器、另一个要自己 `gtk_menu_popup`），
// 所以 `#ifdef` 落在实现里，头文件只暴露「有个图标、有回调、能显示能隐藏」
// 这几件事。
class TrayIcon {
 public:
  TrayIcon();
  ~TrayIcon();

  // 左键点图标 = 打开主窗口（等价于菜单里第一项）。
  void set_on_open(std::function<void()> callback) {
    on_open_ = std::move(callback);
  }

  // 菜单里的「退出 Cirro Mail」。
  void set_on_quit(std::function<void()> callback) {
    on_quit_ = std::move(callback);
  }

  // 把图标放上去（并挂上菜单）。幂等。
  void Show();

  // 从顶栏摘掉。**退出之前必须调**，否则图标要等进程消失、Shell 才发现。
  void Hide();

 private:
  // 菜单只建一次。**必须活得比图标久**：两套后端都只是拿着这个 GtkMenu 的
  // 引用，菜单一析构，点出来的就是空壳。
  void BuildMenu();

  static void OnOpenActivate(GtkMenuItem* item, gpointer user_data);
  static void OnQuitActivate(GtkMenuItem* item, gpointer user_data);
#ifndef CIRRO_HAVE_AYATANA_APPINDICATOR
  static void OnStatusIconActivate(GtkStatusIcon* icon, gpointer user_data);
  static void OnStatusIconPopupMenu(GtkStatusIcon* icon, guint button,
                                    guint activate_time, gpointer user_data);
#endif

  std::function<void()> on_open_;
  std::function<void()> on_quit_;

  // 菜单里的两项。两套后端共用同一份菜单。
  GtkWidget* menu_;

#ifdef CIRRO_HAVE_AYATANA_APPINDICATOR
  AppIndicator* indicator_;
#else
  // 写 `GtkStatusIcon*` 这个**类型**不触发废弃告警，只有调那些函数才触发 ——
  // 所以 `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` 放在 .cc 里，不在这儿。
  GtkStatusIcon* status_icon_;
#endif
};

#endif  // RUNNER_TRAY_ICON_H_
