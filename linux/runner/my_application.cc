#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <cstring>

#include <gio/gio.h>

#include "flutter/generated_plugin_registrant.h"
#include "tray_icon.h"

namespace {

// 启动器角标（Unity LauncherEntry）用到的坐标。这条协议是 Unity 定的、
// KDE 等启动器也认：应用在 session bus 上**广播** `Update` 信号，启动器按
// `.desktop` 的 uri 找到对应图标、把数字挂上去。
//
// 为什么不用 libunity：那是额外的链接依赖，而且很多发行版根本不装。协议本身
// 只有一次 GDBus 调用。桌面不认（GNOME 默认就没有）时没人收这条信号，
// 没有任何副作用。
constexpr const char kLauncherEntryInterface[] =
    "com.canonical.Unity.LauncherEntry";
constexpr const char kLauncherEntryObjectPath[] =
    "/com/canonical/Unity/LauncherEntry";

// 与 `linux/cirro-mail.desktop` 的文件名逐字一致 —— 对不上启动器就找不到图标。
constexpr const char kLauncherAppUri[] = "application://cirro-mail.desktop";

// ── 主窗口几何的持久化 ──
//
// 文件名 / group / 键名集中放在这里：读、写、校验三处必须用同一份字面量，
// 散开写的话改一处漏一处就是「能存不能读」，而症状只是「启动时位置没记住」，
// 很难被当成 bug 报上来。
constexpr const char kWindowStateFileName[] = "window-state.ini";
constexpr const char kWindowStateGroup[] = "window";
constexpr const char kWindowStateKeyX[] = "x";
constexpr const char kWindowStateKeyY[] = "y";
constexpr const char kWindowStateKeyWidth[] = "width";
constexpr const char kWindowStateKeyHeight[] = "height";
constexpr const char kWindowStateKeyMaximized[] = "maximized";

// 没有（或读不出）存档时的窗口大小，与改造前硬编码的那个值一致。
constexpr gint kDefaultWindowWidth = 1280;
constexpr gint kDefaultWindowHeight = 720;

// 尺寸的合法区间。下限挡的是「小到 Flutter 界面根本排不开」的窗口（这类值
// 通常来自手改配置）；上限挡的是离谱值 —— 十几万像素的窗口在 X11 上会直接
// 创建失败，窗口就再也不出现了。
constexpr gint kMinWindowWidth = 320;
constexpr gint kMaxWindowWidth = 16384;
constexpr gint kMinWindowHeight = 240;
constexpr gint kMaxWindowHeight = 16384;

// 恢复位置时要求「至少露出这么多」，见 [my_application_rect_visible]。
// 不取 1x1：只剩一条边挂在屏幕上时，标题栏已经抓不住了。
constexpr gint kMinVisibleWidth = 120;
constexpr gint kMinVisibleHeight = 80;

// 去抖窗口（毫秒），见 [my_application_schedule_window_state_save]。
constexpr guint kWindowStateSaveDelayMs = 500;

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;

  // 唯一的主窗口。
  //
  // **关窗之后它仍然存在**（只是被 `gtk_widget_hide` 藏起来），这是「关窗不
  // 退出」的支点：GtkApplication 会替自己的窗口持住主循环，窗口还在，进程就
  // 不会被回收，轮询和推送登记照常跑。
  GtkWindow* window;

  // GNOME 下用的是带 `GtkHeaderBar` 的自绘标题栏（`my_application_activate`
  // 里 `use_header_bar` 那一支）。这种窗口的标题**不在** `GtkWindow` 上 ——
  // 只调 `gtk_window_set_title` 的话，用户在标题栏里什么都看不到。所以留一份
  // 指针，Dart 改标题时两处一起改（见 [window_method_call_cb]）。
  // 走传统标题栏的分支里它是 nullptr。
  GtkHeaderBar* header_bar;

  // 顶栏里那个图标。**第一次关窗时才建** —— 一个还开着窗口的 App 不该再占
  // 一格，这条和 Windows 那边一致（macOS 是反过来：启动就挂菜单栏图标）。
  TrayIcon* tray;

  // Dart 用来「把窗口叫回来」的通道。见 `lib/core/storage/window_channel.dart`，
  // macOS / Windows / Linux 三边注册的是同名同方法的通道。
  FlMethodChannel* window_channel;

  // 图标徽章那条通道（Dart 侧 `lib/core/notify/icon_badge.dart`）。与
  // `window_channel` 一样必须强持有 —— 通道对象一释放，挂在上面的 handler
  // 就跟着没了，表现是「未读数变了但图标不动」。
  FlMethodChannel* badge_channel;

  // Dart 推来的未读数。**托盘图标可能还没建**（Linux 是第一次藏窗才建），
  // 所以这里先存着；`my_application_hide_to_tray` 建好图标之后靠它补画。
  gint badge_count;

  // 启动器角标要往 session bus 发信号。第一次真正用到时才取；取不到就记下
  // 「这台机器没有会话总线」，不再反复重试。
  GDBusConnection* session_bus;
  gboolean session_bus_unavailable;

  // ── 主窗口几何的持久化（实现见下面的 [my_application_restore_window_state]
  //    与 [my_application_save_window_state]）──
  //
  // 待写盘的几何。`configure-event` 只更新这几个字段，真正落盘由 500ms 的
  // 去抖 timeout、或者「藏窗 / 退出」触发。宽度 <= 0 表示「还没有见过一次
  // 有效几何」，这时不写盘 —— 免得把上次的存档盖成一份空状态。
  gint pending_x;
  gint pending_y;
  gint pending_width;
  gint pending_height;

  // `pending_x/pending_y` 是否可信。Wayland 下没有位置（见
  // [my_application_can_place_window]），从没 `gtk_window_move` 过也没读到
  // 过坐标时它为 FALSE，写盘时就不写 x/y，免得把 0,0 这种假坐标存下去。
  gboolean pending_position_valid;

  // 待定的去抖 timeout（`g_timeout_add` 的 id；0 = 没有排队中的写入）。
  guint window_state_timeout;

  // 上次退出时窗口是最大化的。`activate` 里只把它记下来，真正的
  // `gtk_window_maximize` 留给 [first_frame_cb] —— 窗口还没 map 就请求最大化
  // 时，各 WM 的处理并不一致（有的忽略、有的连默认大小一起丢掉），映射之后
  // 再请求是都认的时序。
  gboolean restore_maximized;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// 主窗口几何存档的路径：`$XDG_CONFIG_HOME/<APPLICATION_ID>/window-state.ini`
// （`g_get_user_config_dir()` 已经替我们处理好 XDG 与兜底的 `~/.config`）。
//
// 目录名用编译期传进来的 `APPLICATION_ID` 而不是写死一个品牌串：公开版与
// pro 版是两个各自独立的安装包（`com.zenkee.cirromail` /
// `com.zenkee.cirromailpro`），共用同一个配置目录会让两个 App 互相覆盖窗口
// 位置；而这个名字本来就由 CMake 的 `APPLICATION_ID` 单点决定，改名不用
// 回来改这里。
static gchar* my_application_window_state_path() {
  return g_build_filename(g_get_user_config_dir(), APPLICATION_ID,
                          kWindowStateFileName, nullptr);
}

// 这个显示后端下，应用能不能自己决定窗口摆在哪。
//
// Wayland 下**不能**：合成器不给应用坐标，`gtk_window_get_position` 永远
// 返回 0,0，`gtk_window_move` 也只是个被忽略的 hint。真在那儿读写 x/y，下次
// 启动就会把窗口按 (0,0) 摆到左上角 —— 比不恢复更糟。所以 Wayland 下只恢复
// / 保存宽高与最大化状态。
static gboolean my_application_can_place_window(GtkWidget* widget) {
#ifdef GDK_WINDOWING_X11
  return GDK_IS_X11_DISPLAY(gtk_widget_get_display(widget));
#else
  // 没编进 X11 后端（只可能是 Wayland），也就没有位置可言。
  static_cast<void>(widget);
  return FALSE;
#endif
}

// 「这块矩形与某台显示器至少重叠了 120x80 像素」。
//
// 为什么需要这层校验：多显示器是笔记本的常态。用户在公司把窗口拖到外接屏，
// 回家拔了线再启动 —— 坐标的绝对值还在，但那块屏幕没了，窗口会被摆到虚拟
// 桌面之外，表现为「启动之后看不见窗口，只能从任务栏叫回来」。校验不过就
// 不要把窗口移到任何地方，让窗口管理器用它自己的规则摆（它知道现在有哪几
// 台显示器）。
static gboolean my_application_rect_visible(GtkWidget* widget, gint x, gint y,
                                            gint width, gint height) {
  GdkDisplay* display = gtk_widget_get_display(widget);
  if (display == nullptr) {
    return FALSE;
  }
  // 存档里的坐标来自**上一次**的显示器布局（可能换过屏、改过缩放），这里
  // 只按原样求交、不做换算：算不出来时宁可让 WM 决定，也不要猜。
  for (gint i = 0; i < gdk_display_get_n_monitors(display); i++) {
    GdkMonitor* monitor = gdk_display_get_monitor(display, i);
    if (monitor == nullptr) {
      continue;
    }
    GdkRectangle geometry = {0, 0, 0, 0};
    gdk_monitor_get_geometry(monitor, &geometry);
    const gint overlap_width = MIN(x + width, geometry.x + geometry.width) -
                               MAX(x, geometry.x);
    const gint overlap_height = MIN(y + height, geometry.y + geometry.height) -
                                MAX(y, geometry.y);
    if (overlap_width >= kMinVisibleWidth &&
        overlap_height >= kMinVisibleHeight) {
      return TRUE;
    }
  }
  return FALSE;
}

// 把待写的几何立刻落盘，并取消排队中的去抖 timeout。
//
// 调用点有三个：去抖 timeout 到点、藏窗（[my_application_hide_to_tray]）、
// 托盘退出（[on_tray_quit]）。后两个是「用户可能不再给我们下一次机会」的
// 时刻 —— 藏进托盘之后窗口可能很久不动，托盘退出之后进程就没了，等那 500ms
// 就等丢了。
//
// **所有 I/O 失败一律静默**：配置文件写不进去（只读家目录、磁盘满、沙箱、
// 权限不对）时，用户该看到的仍然是一个正常启动、正常藏起来的窗口；为此弹
// 错或者卡一下都不值得，丢的只是「下次记住位置」这一条便利。
static void my_application_save_window_state(MyApplication* self) {
  if (self->window_state_timeout != 0) {
    g_source_remove(self->window_state_timeout);
    self->window_state_timeout = 0;
  }
  if (self->window == nullptr || self->pending_width <= 0 ||
      self->pending_height <= 0) {
    // 还没见过一次有效几何：别写一份只有半截的存档把上次的盖掉。
    return;
  }

  g_autofree gchar* path = my_application_window_state_path();
  g_autofree gchar* directory = g_path_get_dirname(path);
  // 0700：里面只有「用户上次把窗口摆在哪」，别人没必要读；顺带避免共享家
  // 目录的机器上出现权限告警。目录已存在时 `g_mkdir_with_parents` 什么都不做。
  if (g_mkdir_with_parents(directory, 0700) != 0) {
    return;
  }

  // 每次从头建一个 `GKeyFile`，而不是复用上次读进来的那份：Wayland 下不该
  // 回写 x/y（见 [my_application_can_place_window]），复用会把上一个 X11
  // 会话留下的坐标又带出去。
  g_autoptr(GKeyFile) key_file = g_key_file_new();
  g_key_file_set_integer(key_file, kWindowStateGroup, kWindowStateKeyWidth,
                         self->pending_width);
  g_key_file_set_integer(key_file, kWindowStateGroup, kWindowStateKeyHeight,
                         self->pending_height);
  if (self->pending_position_valid) {
    g_key_file_set_integer(key_file, kWindowStateGroup, kWindowStateKeyX,
                           self->pending_x);
    g_key_file_set_integer(key_file, kWindowStateGroup, kWindowStateKeyY,
                           self->pending_y);
  }
  // 最大化状态**现读**、不用 pending：它在两次 configure-event 之间就可能
  // 被用户按掉（按最大化按钮本身不一定改变几何），而 pending 里存的是
  // 「普通状态下用户摆的尺寸」，两者是两个维度。
  g_key_file_set_boolean(key_file, kWindowStateGroup, kWindowStateKeyMaximized,
                         gtk_window_is_maximized(self->window));

  // 返回值故意不查：失败就是「下次记不住」，见函数开头那段。
  static_cast<void>(g_key_file_save_to_file(key_file, path, nullptr));
}

// 去抖到点：写盘。`G_SOURCE_REMOVE` 让 GLib 把这个 source 摘掉。
static gboolean on_window_state_timeout(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  // 先把 id 清零再写：保持「id 非 0 ⟺ source 还挂着」这条不变量，
  // [my_application_dispose] 才不会去 remove 一个已经没了的 id。
  self->window_state_timeout = 0;
  my_application_save_window_state(self);
  return G_SOURCE_REMOVE;
}

// 排一次「500ms 后写盘」；连续调用会重新计时（尾部去抖）。
//
// 为什么需要去抖：拖动 / 缩放窗口时 configure-event 是按帧发的，一次拖动
// 就是几十上百个事件，每个都写一次文件等于拿磁盘当缓冲；而且用户还在拖，
// 中途那些几何本来就没有意义 —— 只有松手停下来的那个值才是他想要的。
static void my_application_schedule_window_state_save(MyApplication* self) {
  if (self->window_state_timeout != 0) {
    g_source_remove(self->window_state_timeout);
  }
  self->window_state_timeout = g_timeout_add(kWindowStateSaveDelayMs,
                                             on_window_state_timeout, self);
}

// 把上次的几何套到新窗口上。**必须在窗口 realize / 首帧之前调用**：
// `gtk_window_set_default_size` 只影响「第一次映射时的尺寸」，窗口显示出来
// 之后再调它什么都不会发生。
//
// 读盘失败一律静默退回默认值：配置文件是锦上添花，它可能被手改坏、可能
// 权限不对、也可能因为断电只写了半截 —— 这些都不该变成启动失败或一个弹窗。
static void my_application_restore_window_state(MyApplication* self,
                                                GtkWindow* window) {
  gint width = kDefaultWindowWidth;
  gint height = kDefaultWindowHeight;

  g_autofree gchar* path = my_application_window_state_path();
  g_autoptr(GKeyFile) key_file = g_key_file_new();
  if (g_key_file_load_from_file(key_file, path, G_KEY_FILE_NONE, nullptr)) {
    const gint saved_width = g_key_file_get_integer(
        key_file, kWindowStateGroup, kWindowStateKeyWidth, nullptr);
    const gint saved_height = g_key_file_get_integer(
        key_file, kWindowStateGroup, kWindowStateKeyHeight, nullptr);
    if (saved_width >= kMinWindowWidth && saved_width <= kMaxWindowWidth &&
        saved_height >= kMinWindowHeight && saved_height <= kMaxWindowHeight) {
      width = saved_width;
      height = saved_height;
    }

    // 位置只有 X11 下有意义（原因见 [my_application_can_place_window]）。
    // 两个键都用 `has_key` 判断：合法坐标可以是 0，不能拿「读到 0」当缺失。
    if (my_application_can_place_window(GTK_WIDGET(window)) &&
        g_key_file_has_key(key_file, kWindowStateGroup, kWindowStateKeyX,
                           nullptr) &&
        g_key_file_has_key(key_file, kWindowStateGroup, kWindowStateKeyY,
                           nullptr)) {
      const gint saved_x = g_key_file_get_integer(
          key_file, kWindowStateGroup, kWindowStateKeyX, nullptr);
      const gint saved_y = g_key_file_get_integer(
          key_file, kWindowStateGroup, kWindowStateKeyY, nullptr);
      if (my_application_rect_visible(GTK_WIDGET(window), saved_x, saved_y,
                                      width, height)) {
        gtk_window_move(window, saved_x, saved_y);
        // 用户万一在第一次 configure-event 之前就退出（窗口还没 map 完），
        // 至少把刚恢复的坐标原样写回去，而不是写 0,0。
        self->pending_x = saved_x;
        self->pending_y = saved_y;
        self->pending_position_valid = TRUE;
      }
      // 不可见就什么都不做：让 WM 摆。它知道现在有哪些显示器。
    }

    self->restore_maximized = g_key_file_get_boolean(
        key_file, kWindowStateGroup, kWindowStateKeyMaximized, nullptr);
  }

  gtk_window_set_default_size(window, width, height);

  // 把这份尺寸先记成「已知的有效几何」：万一窗口还没 map 完用户就退出
  // （或者重启到最大化、期间一次普通状态的 configure-event 都没来），
  // [my_application_save_window_state] 也有东西可写，不会整份跳过 ——
  // 跳过会把「这次是不是最大化」一起丢掉。
  self->pending_width = width;
  self->pending_height = height;
}

// 窗口每被移动 / 缩放一次就更新一遍 pending，真正的写盘交给去抖
// （见 [my_application_schedule_window_state_save]）。
static gboolean on_configure_event(GtkWidget* widget, GdkEventConfigure* event,
                                   gpointer user_data) {
  static_cast<void>(event);
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->window == nullptr) {
    return FALSE;
  }

  // 最大化 / 全屏时的几何是「容器给的」，不是用户摆的：拿它覆盖 pending 会
  // 把用户上次调好的普通尺寸冲掉（下次取消最大化，窗口就变成整屏那么大）。
  // 最大化状态本身在写盘时现读，见 [my_application_save_window_state]。
  if (!gtk_window_is_maximized(self->window)) {
    gint width = 0;
    gint height = 0;
    gtk_window_get_size(self->window, &width, &height);
    if (width > 0 && height > 0) {
      self->pending_width = width;
      self->pending_height = height;
    }
    if (my_application_can_place_window(widget)) {
      gint x = 0;
      gint y = 0;
      gtk_window_get_position(self->window, &x, &y);
      self->pending_x = x;
      self->pending_y = y;
      self->pending_position_valid = TRUE;
    }
  }

  my_application_schedule_window_state_save(self);
  // 不消费这个事件：GTK 内部和别的 handler 还要用它。
  return FALSE;
}

// 把主窗口显示出来并抬到前面。窗口本来就开着时是幂等的。
static void my_application_present_window(MyApplication* self) {
  if (self->window == nullptr) {
    return;
  }
  // 最小化过要先撤销：`gtk_window_present` 对已最小化的窗口只会让它闪一下
  // 任务栏，不会真的抬起来。
  gtk_window_deiconify(self->window);
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_present(self->window);
}

// 托盘菜单 / 左键点图标 → 打开主窗口。
static void on_tray_open(gpointer user_data) {
  my_application_present_window(MY_APPLICATION(user_data));
}

// 托盘菜单里的「退出」：摘掉图标、销毁窗口，然后显式退出。
//
// 和点窗口的关闭按钮是**两件事**：那条路只藏窗口（见 [on_delete_event]）。
static void on_tray_quit(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);

  // 销毁窗口之前把几何落盘：进程马上就没了，等不到那 500ms 的去抖 timeout。
  // 必须放在 `gtk_widget_destroy` 之前 —— 窗口没了就读不出 size / 最大化状态。
  my_application_save_window_state(self);

  if (self->tray != nullptr) {
    self->tray->Hide();
  }
  if (self->window != nullptr) {
    gtk_widget_destroy(GTK_WIDGET(self->window));
    self->window = nullptr;
  }
  g_application_quit(G_APPLICATION(self));
}

// 藏起主窗口、并确保顶栏图标在（`Cmd+W` 与点关闭按钮都走这里）。
//
// **不销毁窗口**：GtkApplication 替自己的窗口持着主循环，窗口一没进程就
// 可能被回收，收信、推送登记一起断 —— 而用户以为自己只是关了个窗口。
// 要真退是托盘菜单里的「退出」（[on_tray_quit]）。
static void my_application_hide_to_tray(MyApplication* self) {
  // 藏窗之前先把几何落盘。放在这里而不是 `on_delete_event` 里：另一条入口
  // `Cmd+W`（`window_method_call_cb` 的 `hideMainWindow`）是直接调本函数的，
  // 只在关闭按钮那条路上写盘的话，键盘关窗就不会记住位置 —— 两处各写一遍
  // 迟早只有一处生效（这个文件里别的地方也是同一个教训）。
  //
  // 藏进托盘之后窗口可能很久都不再动，排着的 500ms 去抖就等不到了。
  my_application_save_window_state(self);

  // 托盘图标第一次藏窗时才建：一个还开着窗口的 App 不该再占顶栏一格
  // （与 Windows 那边的 `EnsureTrayIcon` 同一条规矩）。
  if (self->tray == nullptr) {
    self->tray = new TrayIcon();
    self->tray->set_on_open([self]() { on_tray_open(self); });
    self->tray->set_on_quit([self]() { on_tray_quit(self); });
  }
  self->tray->Show();

  // 托盘可能是**这次才建**的：Dart 侧首帧就把未读数推过来了（那时图标还
  // 不存在，只存进了 `badge_count`），这里补画一次，不然用户看到的是
  // 「藏进托盘之后图标上没有数字」。
  self->tray->SetBadgeCount(self->badge_count);

  if (self->window != nullptr) {
    gtk_widget_hide(GTK_WIDGET(self->window));
  }
}

// 「关掉窗口」= 藏进顶栏。
//
// 返回 `TRUE` 是把默认处理（销毁窗口）**按住**。一旦窗口真被销毁，GtkApplication
// 替它持的那份主循环也跟着松掉，进程退出、收信就断了 —— 而用户以为自己只是
// 关了个窗口。要真退就点托盘菜单里的「退出」，那条路见 [on_tray_quit]。
static gboolean on_delete_event(GtkWidget* widget, GdkEvent* event,
                                gpointer user_data) {
  static_cast<void>(event);
  static_cast<void>(widget);
  MyApplication* self = MY_APPLICATION(user_data);

  // 走 [my_application_hide_to_tray] 而不是在这儿就地写一遍：`Cmd+W`
  // （`window_method_call_cb` 那条）要的是**同一件事**，两处各写一遍迟早
  // 只在其中一处生效 —— 而缺的那一半是「藏了之后托盘里没有图标」，
  // 症状是窗口再也叫不回来。
  //
  // 窗口几何的写盘也在那条路径里（`hide_to_tray` 开头），所以关闭按钮和
  // `Cmd+W` 两条入口都能立刻落盘，不会只覆盖其中一条。
  my_application_hide_to_tray(self);
  return TRUE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));

  // 上次退出时是最大化：**映射之后**再请求。窗口还没 map 就
  // `gtk_window_maximize` 时，各窗口管理器的处理并不一致（有的直接忽略，
  // 有的顺手把默认大小也丢掉），先 show 再要最大化是都认的时序。
  //
  // 无论请求成不成功都清掉标志：它只服务于「本次启动」这一次请求，留着会让
  // 以后每次首帧都试图最大化一遍。
  if (self->restore_maximized) {
    self->restore_maximized = FALSE;
    if (self->window != nullptr) {
      gtk_window_maximize(self->window);
    }
  }
}

// Dart 侧那条「把窗口叫回来」的通道。点系统通知时要靠它 —— 桌面版的推送
// 不像手机上那样自带「打开某个界面」的语义，导航又在 Dart 手里。
static void window_method_call_cb(FlMethodChannel* channel,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  static_cast<void>(channel);
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(fl_method_call_get_name(method_call), "showMainWindow") == 0) {
    my_application_present_window(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(fl_method_call_get_name(method_call), "hideMainWindow") ==
             0) {
    // `Cmd+W`：与点窗口关闭按钮同一件事（`on_delete_event`），共用
    // [my_application_hide_to_tray]。
    my_application_hide_to_tray(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(fl_method_call_get_name(method_call), "setWindowTitle") == 0) {
    // 与另外两个无参方法不同，这条的参数是 map（`{"title": ...}`）。
    FlValue* args = fl_method_call_get_args(method_call);
    const gchar* title = nullptr;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* value = fl_value_lookup_string(args, "title");
      if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
        title = fl_value_get_string(value);
      }
    }
    if (title != nullptr && title[0] != '\0' && self->window != nullptr) {
      // 两处都设：GNOME 下用户看到的是 header bar 的标题，但传统标题栏、以及
      // 任务栏 / 窗口列表读的是 `GtkWindow` 的 title —— 只改一处会在另一半
      // 场景里悄悄失效。`header_bar` 为 nullptr 时那条分支不会执行。
      gtk_window_set_title(self->window, title);
      if (self->header_bar != nullptr) {
        gtk_header_bar_set_title(self->header_bar, title);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to window channel: %s", error->message);
  }
}

// 把未读数推给启动器（Unity LauncherEntry 协议，常量见文件顶部）。
//
// 好消息是「发出去就算」：这条信号本来就是广播，没有接收方也不算错，所以
// 唯一的失败点是拿不到 session bus。那种机器（裸 WM、无 D-Bus 会话）上托盘
// 数字照样工作，这里静默跳过即可 —— 徽章是装饰，不能因为启动器不支持就
// 把通道回调卡住。
static void my_application_update_launcher_badge(MyApplication* self,
                                                 gint count) {
  if (self->session_bus == nullptr) {
    if (self->session_bus_unavailable) {
      return;
    }
    g_autoptr(GError) error = nullptr;
    self->session_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (self->session_bus == nullptr) {
      // 记住失败：别每来一封新信就再试一次、刷一屏 warning。
      self->session_bus_unavailable = TRUE;
      return;
    }
  }

  // body 是 `(sa{sv})`：desktop uri + 一个属性字典。`count-visible` 是独立
  // 开关 —— 归零时保留数字、只把它关掉也行，但这里直接传 0 更直白。
  GVariantBuilder properties;
  g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&properties, "{sv}", "count",
                        g_variant_new_int64(count));
  g_variant_builder_add(&properties, "{sv}", "count-visible",
                        g_variant_new_boolean(count > 0));

  g_dbus_connection_emit_signal(
      self->session_bus, nullptr, kLauncherEntryObjectPath,
      kLauncherEntryInterface, "Update",
      g_variant_new("(sa{sv})", kLauncherAppUri, &properties), nullptr);
}

// Dart 侧那条「图标角标」通道。方法名与参数格式（map `{"count": int}`）五个
// 平台逐字一致，见 `lib/core/notify/icon_badge.dart`。
//
// 失败一律静默：图标没建好、桌面没有启动器角标，都只表现为「不显示数字」，
// 不许把通道回调卡住 —— Dart 侧本来也吞掉所有异常。
static void badge_method_call_cb(FlMethodChannel* channel,
                                 FlMethodCall* method_call,
                                 gpointer user_data) {
  static_cast<void>(channel);
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(fl_method_call_get_name(method_call), "setBadge") == 0) {
    gint count = 0;
    FlValue* args = fl_method_call_get_args(method_call);
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* value = fl_value_lookup_string(args, "count");
      if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
        // 负数按 0（清除）处理：Dart 侧不会传，但把负数画上图标更糟；
        // `99+` 那条上限在 TrayIcon 里统一收，这里只防 int64 溢出 gint。
        const int64_t raw = fl_value_get_int(value);
        if (raw > 0) {
          count = raw > G_MAXINT ? G_MAXINT : static_cast<gint>(raw);
        }
      }
    }
    self->badge_count = count;
    // 托盘可能还没建（用户还没藏过窗）：里面会先记下数字，等图标建好再补画。
    if (self->tray != nullptr) {
      self->tray->SetBadgeCount(count);
    }
    my_application_update_launcher_badge(self, count);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to badge channel: %s", error->message);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // 已经有窗口了 —— 这次 `activate` 是**别处转过来的**（用户又点了一次桌面
  // 图标 / 菜单项）。`g_application_activate` 的语义是「让**主实例**收到
  // ::activate」，所以在第二个进程里调它，信号也会落回这里。
  //
  // 这时候必须把已有窗口抬起来就返回，**绝不能再建一个**：不然每次点图标
  // 都会多出一扇窗，而关掉的那些还各自占着一份引擎。
  if (self->window != nullptr) {
    my_application_present_window(self);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Cirro Mail");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
    // 记下来给 `setWindowTitle` 用（见 [window_method_call_cb]）。
    self->header_bar = header_bar;
  } else {
    gtk_window_set_title(window, "Cirro Mail");
  }

  // The bundle keeps its icon alongside the Flutter data, so it also works
  // when launched directly without a system-wide icon theme installation.
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable != nullptr) {
    g_autofree gchar* directory = g_path_get_dirname(executable);
    g_autofree gchar* icon_path =
        g_build_filename(directory, "data", "cirro-mail.png", nullptr);
    gtk_window_set_icon_from_file(window, icon_path, nullptr);
  }

  // 恢复上次的窗口几何（默认 1280x720 在 [my_application_restore_window_state]
  // 里兜底）。**必须放在窗口 realize / 首帧之前**：`gtk_window_set_default_size`
  // 只在第一次映射时生效，映射之后再调就没人看了。
  //
  // 最大化不在这里请求，只记一个标志，留给 [first_frame_cb]。
  my_application_restore_window_state(self, window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // 「关窗 = 藏进顶栏」那条路。见 [on_delete_event]。
  g_signal_connect(window, "delete-event", G_CALLBACK(on_delete_event), self);

  // 移动 / 缩放窗口 → 更新待写状态，500ms 去抖后落盘。见 [on_configure_event]。
  g_signal_connect(window, "configure-event", G_CALLBACK(on_configure_event),
                   self);

  // 通道要等插件注册完再建：引擎这时才真正起来。
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(
      messenger, "com.zenkee.cirromail/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->window_channel, window_method_call_cb, self, nullptr);

  // 图标徽章通道：与窗口通道同一个 messenger、同一份 codec。见
  // [badge_method_call_cb]。
  self->badge_channel = fl_method_channel_new(
      messenger, "com.zenkee.cirromail/badge", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->badge_channel, badge_method_call_cb, self, nullptr);

  self->window = window;

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // 「已经有实例在跑了」这一支不用在这里分叉：`g_application_activate` 的
  // 语义就是「让**主实例**收到 ::activate」，注册成远程实例之后再调它，
  // 信号会转发到那个已经在跑的进程里（见 [my_application_activate] 开头那段）。
  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);

  // 待定的写盘 timeout 必须在这里摘掉：`self` 马上要释放，让一个还挂在主
  // 循环上的 source 拿着它的指针回调就是 use-after-free。待写的几何不再
  // 补写 —— 走到 dispose 时窗口要么已经由 [on_tray_quit] 落过盘，要么这次
  // 进程退出本来就不该再碰磁盘。
  if (self->window_state_timeout != 0) {
    g_source_remove(self->window_state_timeout);
    self->window_state_timeout = 0;
  }

  // 托盘图标要**先**摘掉：进程一没，Shell 才发现那个图标没了，中间这段时间
  // 它还挂在顶栏上（要点一下才知道是死的）。摘的动作在 `~TrayIcon` 里，这里
  // 只负责在窗口和引擎之前把它销毁掉。
  delete self->tray;
  self->tray = nullptr;

  g_clear_object(&self->window_channel);
  g_clear_object(&self->badge_channel);
  g_clear_object(&self->session_bus);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);

  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->window = nullptr;
  self->tray = nullptr;
  self->window_channel = nullptr;
  self->badge_channel = nullptr;
  self->badge_count = 0;
  self->session_bus = nullptr;
  self->session_bus_unavailable = FALSE;
  // 宽度 / 高度留 0 = 「还没有有效几何」。`activate` 里的
  // [my_application_restore_window_state] 会立刻把它填成存档值或默认值，
  // [my_application_save_window_state] 再拿它当「这次有没有东西可写」的闸门。
  self->pending_x = 0;
  self->pending_y = 0;
  self->pending_width = 0;
  self->pending_height = 0;
  self->pending_position_valid = FALSE;
  self->window_state_timeout = 0;
  self->restore_maximized = FALSE;
}

MyApplication* my_application_new() {
  g_set_application_name("Cirro Mail");
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // **不再是 `G_APPLICATION_NON_UNIQUE`。**
  //
  // 关窗之后 App 是「藏在顶栏里活着」的，桌面上看不见它，用户再从菜单点
  // 一次完全合理 —— 而 `NON_UNIQUE` 会让那次点击开出**第二个进程**：两个进程
  // 抢同一个 SQLite 库、各登记一份推送、同一封信弹两遍。这和 Windows 那边
  // 用互斥体挡掉的是同一件事，只是 GLib 自带这套机制 —— 带上唯一 app id 之后，
  // 第二次启动会被 GApplication 通过会话 D-Bus 转到已经在跑的那个进程上，
  // 落进 `activate`（见 [my_application_activate] 里那个「已经有窗口」的分支）。
  // 第三个参数是 flags，这里要的是「不要任何特殊行为」。
  //
  // 写 `0` 而不是 `G_APPLICATION_FLAGS_NONE`：后者从 GLib 2.74 起废弃（改叫
  // `G_APPLICATION_DEFAULT_FLAGS`），而那个新名字在更老的发行版（Ubuntu 22.04
  // 是 GLib 2.72）上根本不存在 —— 两个名字横竖要挑一个版本踩，`0` 两边都能编。
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     static_cast<GApplicationFlags>(0),
                                     nullptr));
}
