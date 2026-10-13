#include "tray_icon.h"

#include <gtk/gtk.h>

#ifdef CIRRO_HAVE_AYATANA_APPINDICATOR
#include <libayatana-appindicator/app-indicator.h>
#endif

namespace {

// 图标名。appindicator 那一支按**主题名**查图标，取的就是 `.desktop` 里写的
// 那个 `Icon=cirro-mail` —— 九档 hicolor 图标随包装到
// `share/icons/hicolor/*/apps/`，见顶层 `linux/CMakeLists.txt` 里那段
// `foreach(icon_size ...)`。
//
// ⚠️ 这两套后端查的是**同一个图标主题**，但时机不同：除了做成 .deb/.rpm 装到
// 系统里，`flutter run` 那种直接跑 bundle 的情形下主题里并没有 `cirro-mail`。
// 所以真正拿去查主题的是 [ResolveIconName]，它在主题里查不到就换兜底那个。
constexpr const char kIconName[] = "cirro-mail";

// 找不到上面那个图标时的退路：GTK 自带的通用信封图标。总比顶栏里什么都不
// 出现强 —— 用户看不到图标，就再也叫不回窗口了。
constexpr const char kFallbackIconName[] = "mail-unread";

// 主题里有 `cirro-mail` 就用它，没有就用兜底那个。
//
// 这一层不是多余的：图标是**装到系统里**才进主题的（见上面 `kIconName` 那段），
// 而 `flutter run` 那种直接跑 bundle 的开发流程根本不走 install。这时候拿去查
// 主题会落空，顶栏上会出现一个「缺图标」的占位方块。
const char* ResolveIconName() {
  GtkIconTheme* theme = gtk_icon_theme_get_default();
  if (theme != nullptr && gtk_icon_theme_has_icon(theme, kIconName)) {
    return kIconName;
  }
  return kFallbackIconName;
}

bool PrefersChinese() {
  const gchar* const* languages = g_get_language_names();
  return languages != nullptr && languages[0] != nullptr &&
         g_str_has_prefix(languages[0], "zh");
}

const char* OpenLabel() {
  return PrefersChinese() ? "打开主窗口" : "Open Cirro Mail";
}

const char* QuitLabel() {
  return PrefersChinese() ? "退出 Cirro Mail" : "Quit Cirro Mail";
}

#ifdef CIRRO_HAVE_AYATANA_APPINDICATOR
// 整个 `libayatana-appindicator` 的 C API 都挂着 `G_GNUC_DEPRECATED`（包括
// `app_indicator_new_with_path`，不是「换一个构造函数就好」），上游想让调用方
// 直接说 StatusNotifierItem 那套 D-Bus 协议。但那个量大得多、还得自己往
// `/usr/share/dbus-1/services` 装一份 service 文件，为了一个托盘图标不值得 ——
// 何况现在整个 Linux 桌面生态的标准做法仍然是这个库。
//
// 单包一层函数是因为 `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` 是按**语句**生效的，
// 包在别处没用 —— 告警是在下面这行调用上报出来的。
G_GNUC_BEGIN_IGNORE_DEPRECATIONS
AppIndicator* NewCirroIndicator(const char* icon_name) {
  return app_indicator_new("cirro-mail", icon_name,
                           APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
}
G_GNUC_END_IGNORE_DEPRECATIONS
#endif

}  // namespace

TrayIcon::TrayIcon()
    : menu_(nullptr),
#ifdef CIRRO_HAVE_AYATANA_APPINDICATOR
      indicator_(nullptr)
#else
      status_icon_(nullptr)
#endif
{
}

TrayIcon::~TrayIcon() {
  Hide();

  // 图标自身那份引用也要放掉，和 `Hide()` 是两件事：`Hide` 只是让 Shell 别
  // 显示，对象还在（比如窗口后来又打开、图标要能再挂回去，见 [Show]）。
#ifdef CIRRO_HAVE_AYATANA_APPINDICATOR
  g_clear_object(&indicator_);
#else
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  g_clear_object(&status_icon_);
  G_GNUC_END_IGNORE_DEPRECATIONS
#endif

  // 菜单最后销毁 —— 上面那个对象还拿着它的引用。
  if (menu_ != nullptr) {
    gtk_widget_destroy(menu_);
    menu_ = nullptr;
  }
}

void TrayIcon::BuildMenu() {
  if (menu_ != nullptr) {
    return;  // 幂等。
  }

  menu_ = gtk_menu_new();

  GtkWidget* open_item = gtk_menu_item_new_with_label(OpenLabel());
  g_signal_connect(open_item, "activate", G_CALLBACK(OnOpenActivate), this);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu_), open_item);

  gtk_menu_shell_append(GTK_MENU_SHELL(menu_), gtk_separator_menu_item_new());

  GtkWidget* quit_item = gtk_menu_item_new_with_label(QuitLabel());
  g_signal_connect(quit_item, "activate", G_CALLBACK(OnQuitActivate), this);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu_), quit_item);

  // 菜单项要显式 show。appindicator 那一支**不走** `gtk_menu_popup`，它把菜单
  // 结构导出给 Shell 去渲染，那条路上没有谁替你 `show_all` —— 漏了这一步，
  // 表现就是「菜单弹出来是空白的」。
  gtk_widget_show_all(menu_);
}

void TrayIcon::Show() {
  BuildMenu();

#ifdef CIRRO_HAVE_AYATANA_APPINDICATOR
  if (indicator_ == nullptr) {
    indicator_ = NewCirroIndicator(ResolveIconName());
    if (indicator_ == nullptr) {
      return;
    }
    app_indicator_set_menu(indicator_, GTK_MENU(menu_));
  }
  app_indicator_set_status(indicator_, APP_INDICATOR_STATUS_ACTIVE);
#else
  if (status_icon_ == nullptr) {
    // 本工程 Linux 侧是 `-Wall -Werror`，而 `GtkStatusIcon` 整族从 GTK 3.14
    // 起就废弃了 —— 不按住告警，兜底这一支直接**编译不过**（而那会让没装
    // appindicator 的机器连 build 都过不去，正是这一支要救的场景）。
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    status_icon_ = gtk_status_icon_new_from_icon_name(ResolveIconName());

    if (status_icon_ != nullptr) {
      // 左键 = 开窗（桌面的既有约定），右键 / 菜单键 = 弹菜单。
      g_signal_connect(status_icon_, "activate",
                       G_CALLBACK(OnStatusIconActivate), this);
      g_signal_connect(status_icon_, "popup-menu",
                       G_CALLBACK(OnStatusIconPopupMenu), this);
      gtk_status_icon_set_tooltip_text(status_icon_, "Cirro Mail");
      gtk_status_icon_set_visible(status_icon_, TRUE);
    }
    G_GNUC_END_IGNORE_DEPRECATIONS
  }
#endif
}

void TrayIcon::Hide() {
#ifdef CIRRO_HAVE_AYATANA_APPINDICATOR
  if (indicator_ != nullptr) {
    // PASSIVE 就是「藏起来」：Shell 立刻把图标撤掉，不需要等进程消失。
    app_indicator_set_status(indicator_, APP_INDICATOR_STATUS_PASSIVE);
  }
#else
  if (status_icon_ != nullptr) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gtk_status_icon_set_visible(status_icon_, FALSE);
    G_GNUC_END_IGNORE_DEPRECATIONS
  }
#endif
}

// 下面这些静态回调的签名要跟 `GCallback` 对得上，用不上的参数也不能省名字，
// 所以拿 `static_cast<void>(x)` 吃掉「参数没用上」那类告警（本工程是 `-Werror`，
// 一旦谁把 `-Wextra` 打开就会变成硬错误）。
void TrayIcon::OnOpenActivate(GtkMenuItem* item, gpointer user_data) {
  static_cast<void>(item);
  auto* self = static_cast<TrayIcon*>(user_data);
  if (self->on_open_) {
    self->on_open_();
  }
}

void TrayIcon::OnQuitActivate(GtkMenuItem* item, gpointer user_data) {
  static_cast<void>(item);
  auto* self = static_cast<TrayIcon*>(user_data);
  if (self->on_quit_) {
    self->on_quit_();
  }
}

#ifndef CIRRO_HAVE_AYATANA_APPINDICATOR
void TrayIcon::OnStatusIconActivate(GtkStatusIcon* icon, gpointer user_data) {
  static_cast<void>(icon);
  auto* self = static_cast<TrayIcon*>(user_data);
  if (self->on_open_) {
    self->on_open_();
  }
}

void TrayIcon::OnStatusIconPopupMenu(GtkStatusIcon* icon, guint button,
                                     guint activate_time, gpointer user_data) {
  auto* self = static_cast<TrayIcon*>(user_data);
  if (self->menu_ == nullptr) {
    return;
  }
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  gtk_menu_popup(GTK_MENU(self->menu_), nullptr, nullptr,
                 gtk_status_icon_position_menu, icon, button, activate_time);
  G_GNUC_END_IGNORE_DEPRECATIONS
}
#endif
