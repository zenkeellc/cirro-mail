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
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

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
  my_application_hide_to_tray(self);
  return TRUE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  static_cast<void>(self);
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
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

  gtk_window_set_default_size(window, 1280, 720);

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
