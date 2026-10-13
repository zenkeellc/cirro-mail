#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <cstring>

#include "flutter/generated_plugin_registrant.h"
#include "tray_icon.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;

  // 唯一的主窗口。
  //
  // **关窗之后它仍然存在**（只是被 `gtk_widget_hide` 藏起来），这是「关窗不
  // 退出」的支点：GtkApplication 会替自己的窗口持住主循环，窗口还在，进程就
  // 不会被回收，轮询和推送登记照常跑。
  GtkWindow* window;

  // 顶栏里那个图标。**第一次关窗时才建** —— 一个还开着窗口的 App 不该再占
  // 一格，这条和 Windows 那边一致（macOS 是反过来：启动就挂菜单栏图标）。
  TrayIcon* tray;

  // Dart 用来「把窗口叫回来」的通道。见 `lib/core/storage/window_channel.dart`，
  // macOS / Windows / Linux 三边注册的是同名同方法的通道。
  FlMethodChannel* window_channel;
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
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to window channel: %s", error->message);
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
      messenger, "com.zenkee.mailapp/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->window_channel, window_method_call_cb, self, nullptr);

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
