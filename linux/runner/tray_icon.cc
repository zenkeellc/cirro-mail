#include "tray_icon.h"

#include <gtk/gtk.h>

#include <cairo.h>

#include <string>

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

// 角标图标的边长。托盘图标的惯例尺寸是 22~24px（顶栏本身一般 24~32 高），
// 这里取 24：数字比 22 更容易看清，顶栏要更小的会自己缩。
constexpr int kBadgeIconSize = 24;

// 角标上显示的数字上限。24px 的圆里塞三位数怎么画都会糊，所以和 macOS /
// Windows 那边一样收在 `99+`。
constexpr int kBadgeMaxCount = 99;

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

// 未读数规范化：`0` 就是「没有角标」，超过 [kBadgeMaxCount] 的一律折到
// `kBadgeMaxCount + 1`。折这一下还顺带管住了 appindicator 那支的缓存文件名
// —— 按真实未读数命名的话，缓存目录会随未读数无限长下去。
int NormalizeBadgeCount(int count) {
  if (count <= 0) {
    return 0;
  }
  return count > kBadgeMaxCount ? kBadgeMaxCount + 1 : count;
}

// 画在图标上的文字。输入是 [NormalizeBadgeCount] 的结果。
std::string BadgeText(int count) {
  if (count > kBadgeMaxCount) {
    return "99+";
  }
  return std::to_string(count);
}

// 在 [cr] 上画「红色圆底 + 白色数字」。
//
// 用 cairo 的 toy 字体 API（`cairo_select_font_face` / `cairo_show_text`）：
// 为了几个数字引 pango 那套布局不值得，字体回退交给 fontconfig 就行。圆的
// 大小跟着文字长度走（一位数小一点、`99+` 接近整图），并且钉在右下角 ——
// 顶栏图标那一角通常最空，也不至于把底图整个盖住。
void PaintBadge(cairo_t* cr, int size, const char* text) {
  cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL,
                         CAIRO_FONT_WEIGHT_BOLD);
  double font_size = size * 0.46;
  cairo_set_font_size(cr, font_size);
  cairo_text_extents_t extents;
  cairo_text_extents(cr, text, &extents);

  // 圆的直径：字宽 + 一点内边距，夹在「图标的一半」和「几乎整个图标」之间。
  double diameter = extents.width + size * 0.28;
  const double min_diameter = size * 0.56;
  const double max_diameter = size * 0.96;
  if (diameter < min_diameter) {
    diameter = min_diameter;
  } else if (diameter > max_diameter) {
    diameter = max_diameter;
  }

  // 文字比圆还宽（`99+` 落在小图标上）就缩字号，保证数字始终留在圆里。
  const double max_text_width = diameter - size * 0.16;
  if (extents.width > max_text_width && extents.width > 0.0) {
    font_size *= max_text_width / extents.width;
    cairo_set_font_size(cr, font_size);
    cairo_text_extents(cr, text, &extents);
  }

  const double radius = diameter / 2.0;
  const double center_x = size - radius;
  const double center_y = size - radius;
  // 偏暗的红（#D92B26 一档）：顶栏底色深浅都有，太亮会糊在浅色面板上。
  cairo_set_source_rgb(cr, 0.851, 0.169, 0.149);
  cairo_arc(cr, center_x, center_y, radius, 0.0, 2.0 * G_PI);
  cairo_fill(cr);

  // `cairo_text_extents` 给的是相对基线的包围盒，用 bearing 把字挪到圆心。
  cairo_move_to(cr, center_x - (extents.x_bearing + extents.width / 2.0),
                center_y - (extents.y_bearing + extents.height / 2.0));
  cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
  cairo_show_text(cr, text);
}

// 「主题图标 + 角标」合成到一张 cairo surface。调用方负责
// `cairo_surface_destroy`；`count` 必须是 [NormalizeBadgeCount] 的结果且 > 0。
//
// 底图查不到时只用红圆 —— `flutter run` 直接跑 bundle 时主题里并没有
// `cirro-mail`（[ResolveIconName] 会先退到 `mail-unread`，通常还是查得到的）。
// 任何一步失败都只表现为「图标上少点东西」，不抛、不崩。
cairo_surface_t* CreateBadgeSurface(int count) {
  const int size = kBadgeIconSize;
  cairo_surface_t* surface =
      cairo_image_surface_create(CAIRO_FORMAT_ARGB32, size, size);
  cairo_t* cr = cairo_create(surface);

  g_autoptr(GError) error = nullptr;
  GdkPixbuf* base = gtk_icon_theme_load_icon(
      gtk_icon_theme_get_default(), ResolveIconName(), size,
      GTK_ICON_LOOKUP_FORCE_SIZE, &error);
  if (base != nullptr) {
    gdk_cairo_set_source_pixbuf(cr, base, 0, 0);
    cairo_paint(cr);
    g_object_unref(base);
  }

  const std::string text = BadgeText(count);
  PaintBadge(cr, size, text.c_str());

  cairo_destroy(cr);
  return surface;
}

#ifndef CIRRO_HAVE_AYATANA_APPINDICATOR
// GtkStatusIcon 只能塞 GdkPixbuf：把合成图从 surface 转过去。
GdkPixbuf* CreateBadgePixbuf(int count) {
  cairo_surface_t* surface = CreateBadgeSurface(count);
  GdkPixbuf* pixbuf = gdk_pixbuf_get_from_surface(surface, 0, 0,
                                                  kBadgeIconSize, kBadgeIconSize);
  cairo_surface_destroy(surface);
  return pixbuf;
}

// 「换图标」这一族全挂在 `GtkStatusIcon` 的废弃名单上。单独包两个小函数是为了
// 让 `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` 的 push / pop **成对且不被 return
// 绕过** —— 它本质是 pragma，包在带提前返回的业务代码外面时，某条路径上的
// pop 会被跳过，clang 报 `pragma diagnostic pop could not pop`，`-Werror`
// 下就是硬错误。
G_GNUC_BEGIN_IGNORE_DEPRECATIONS
void SetStatusIconFromName(GtkStatusIcon* icon, const char* icon_name) {
  gtk_status_icon_set_from_icon_name(icon, icon_name);
}

void SetStatusIconFromPixbuf(GtkStatusIcon* icon, GdkPixbuf* pixbuf) {
  gtk_status_icon_set_from_pixbuf(icon, pixbuf);
}
G_GNUC_END_IGNORE_DEPRECATIONS
#endif

#ifdef CIRRO_HAVE_AYATANA_APPINDICATOR
// appindicator 的缓存目录：`$XDG_CACHE_HOME/cirro-mail/badge/`。
//
// 为什么非得落盘：appindicator 的 C API 只能按「图标名」换图标，塞不进
// pixbuf（Windows 那边换 HICON 的办法在这儿用不了），所以合成图只能写成
// PNG，再让面板按名字去取。放 cache 而不是 data：这些 PNG 是派生品，丢了
// 下次未读数一变就会重画。
std::string BadgeCacheDirectory() {
  g_autofree gchar* directory =
      g_build_filename(g_get_user_cache_dir(), "cirro-mail", "badge", nullptr);
  // 0700：未读数也算用户隐私，别的用户不必看见。
  g_mkdir_with_parents(directory, 0700);
  return directory;
}

// 把合成图写成 PNG，返回**绝对路径**；失败返回空串。
//
// 每个 count 一个文件名而不是覆盖同一个：面板对 IconName 是按字符串记的，
// 同名重写它不会重新读盘。反正最多 100 个文件、每个几百字节。
std::string WriteBadgePng(int count) {
  const std::string file_name =
      "cirro-mail-badge-" + std::to_string(count) + ".png";
  const std::string directory = BadgeCacheDirectory();
  g_autofree gchar* path =
      g_build_filename(directory.c_str(), file_name.c_str(), nullptr);

  cairo_surface_t* surface = CreateBadgeSurface(count);
  const cairo_status_t status = cairo_surface_write_to_png(surface, path);
  cairo_surface_destroy(surface);
  if (status != CAIRO_STATUS_SUCCESS) {
    return std::string();
  }
  return path;
}

// appindicator 换图标。这里传给 `app_indicator_set_icon_full` 的是 PNG 的
// **绝对路径**，不是主题图标名 —— 这是三套主流宿主都认的那种形式：
//
//   * GNOME 的 AppIndicator 扩展：`IconName` 以 `/` 开头时直接当文件读
//     （appIndicator.js 里 `name[0] === '/'` 那一支）；
//   * KDE Plasma：`IconName` 交给 KIconLoader，它对绝对路径直接取文件
//     （kiconloader.cpp 里 `QDir::isAbsolutePath` 那条捷径）；
//   * libayatana-appindicator 自己的 GtkStatusIcon 兜底：`g_file_test()` 成立
//     就走 `gtk_status_icon_set_from_file`（本仓库的 example/simple-client.c
//     也是这么用绝对路径的）。
//
// 另一条路是「`set_icon_theme_path` + 主题图标名」，但那条要求把 PNG 摆成
// `hicolor/<size>/apps/…` 的主题结构、还得补 `index.theme`，任何一环没对齐
// 就静默不显示；绝对路径把「文件在哪」说死，反而最稳。归零时传回主题图标名
// （`cirro-mail` / `mail-unread`），走的就是普通主题查询。
G_GNUC_BEGIN_IGNORE_DEPRECATIONS
void SetIndicatorIcon(AppIndicator* indicator, const char* icon_name) {
  app_indicator_set_icon_full(indicator, icon_name, "Cirro Mail");
}
G_GNUC_END_IGNORE_DEPRECATIONS
#endif

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
      badge_count_(0),
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
    // 不在这里补画未读数：`Show()` 只在第一次藏窗时走到这个分支，而
    // `my_application_hide_to_tray` 紧接着就会把 `badge_count` 交给
    // [SetBadgeCount] —— 补画放在那一条路径上，语义只有一处。
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
    // 同 appindicator 那支：补画由 `my_application_hide_to_tray` 里的
    // [SetBadgeCount] 统一负责，见上面的注释。
  }
#endif
}

void TrayIcon::SetBadgeCount(int count) {
  const int value = count > 0 ? count : 0;
  // 幂等：Dart 侧已经去过重，这里再挡一层 —— 重画要走合成 + 落盘 + 通知
  // 面板，不值得为一个没变的数字做一遍。
  if (value == badge_count_) {
    return;
  }
  badge_count_ = value;
  ApplyBadge();
}

// 按当前 [badge_count_] 重画图标。图标对象还没建时什么都不做 —— 建好之后
// `my_application_hide_to_tray` 会立刻把当前数字交进来（见那处注释）。
void TrayIcon::ApplyBadge() {
  const int value = NormalizeBadgeCount(badge_count_);
#ifdef CIRRO_HAVE_AYATANA_APPINDICATOR
  if (indicator_ == nullptr) {
    return;
  }
  if (value <= 0) {
    // 归零：图标名切回主题图标。**不删缓存里那些 PNG** —— 未读再涨起来还是
    // 同一批文件，删了反而要多写盘。
    SetIndicatorIcon(indicator_, ResolveIconName());
    return;
  }
  const std::string icon_path = WriteBadgePng(value);
  if (icon_path.empty()) {
    // 落盘失败：顶栏继续用原图标，不抛、不崩。
    return;
  }
  SetIndicatorIcon(indicator_, icon_path.c_str());
#else
  if (status_icon_ == nullptr) {
    return;
  }
  if (value <= 0) {
    SetStatusIconFromName(status_icon_, ResolveIconName());
    return;
  }
  GdkPixbuf* badge = CreateBadgePixbuf(value);
  if (badge == nullptr) {
    // 合成失败（主题里连兜底图标都没有）：保持原样。
    return;
  }
  SetStatusIconFromPixbuf(status_icon_, badge);
  g_object_unref(badge);
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
