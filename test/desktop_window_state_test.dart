import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **为什么读文本**：`analysis_options.yaml` 把 `macos/**`、`windows/**`、
/// `linux/**` 排除在外，这些原生 runner 文件既不进 `flutter analyze`、也不在
/// widget 树里，跑不了任何行为测试。而「记住窗口大小与位置」这个功能漏掉一半
/// 是**静默**的 —— 窗口照样能开，只是下次启动回到右上角；没人会把它当崩溃报
/// 上来。所以这里钉住三端各自的关键几行，尤其是**每个保存/恢复点**：这些点
/// 分布在好几个函数里，删掉任何一个都只表现为某个入口下「位置没记住」。
///
/// 真实行为验证在 macOS 上是实测过的（见 `docs/window-state.md`「验证边界」），
/// Windows / Linux 只有代码与这份钉子。本文件只是防退化。
///
/// 和 `macos_single_instance_test.dart` 一样，先在**去注释**的副本上找：
/// 这些文件的注释里专门写着「不要用 xxx、所以用了 yyy」，不剥注释的话钉子会
/// 咬到自己的说明文字。
void main() {
  late String appDelegate;
  late String windowsWindow;
  late String windowsMain;
  late String linuxApp;

  /// 剥掉 `//` 行注释与 `/* … */` 块注释，只留代码。
  String withoutLineComments(String source) => source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  /// 取 `startMarker` 之后、下一个 `nextMarker`（或文件尾）之间的那段——
  /// 用来断言「某个函数体里确实调用了某个东西」。按**第一次出现**切，各文件
  /// 里这几个函数都只有一处定义。
  String bodyAfter(String source, String startMarker, String nextMarker) {
    final start = source.indexOf(startMarker);
    expect(start, isNot(-1), reason: '找不到 `$startMarker` —— 函数/分支被改名或删掉了');
    final rest = source.substring(start + startMarker.length);
    final end = nextMarker.isEmpty ? -1 : rest.indexOf(nextMarker);
    return end == -1 ? rest : rest.substring(0, end);
  }

  setUpAll(() {
    appDelegate = withoutLineComments(
      File('macos/Runner/AppDelegate.swift').readAsStringSync(),
    );
    windowsWindow = withoutLineComments(
      File('windows/runner/flutter_window.cpp').readAsStringSync(),
    );
    windowsMain = withoutLineComments(
      File('windows/runner/main.cpp').readAsStringSync(),
    );
    linuxApp = withoutLineComments(
      File('linux/runner/my_application.cc').readAsStringSync(),
    );
  });

  group('macOS：AppKit 的 frame autosave', () {
    test('用 setFrameAutosaveName 记住外框，名字是一个公开常量', () {
      expect(
        appDelegate,
        matches(RegExp(r'setFrameAutosaveName\(\s*Self\.mainWindowFrameAutosaveName\s*\)')),
      );
      expect(
        appDelegate,
        contains('mainWindowFrameAutosaveName = "CirroMainWindow"'),
      );
    });

    test('autosave 在 showMainWindow() **之前**设置（放到显示之后窗口会先跳一下）', () {
      final autosaveAt = appDelegate.indexOf('setFrameAutosaveName');
      final showAt = appDelegate.indexOf('showMainWindow()', autosaveAt);
      expect(autosaveAt, isNot(-1));
      expect(showAt, isNot(-1), reason: 'didFinishLaunching 末尾那句 showMainWindow() 不见了？');
      expect(autosaveAt, lessThan(showAt));
    });

    test('没有自己另存一份 CGRect / 没有多余的 windowDidMove 观察者', () {
      // AppKit 自己在移动/缩放/关窗时写回；自己再写一遍是两套真相。
      expect(appDelegate, isNot(contains('windowDidMoveNotification')));
      expect(appDelegate, isNot(contains('windowDidResizeNotification')));
    });
  });

  group('Windows：HKCU 注册表 + 首帧前 SetWindowPos', () {
    test('5 个 REG_DWORD 的键名与值名（品牌后缀两个检出不同，见文件注释）', () {
      // 键名里的 `CirroMail`/`CirroMailPro` 是品牌差异点（pro 检出带后缀），
      // 这份测试两个检出共用，所以只钉「前缀 + 结尾 + 值名」的形状。
      expect(
        windowsWindow,
        matches(RegExp(r'L"Software\\\\Zenkee\\\\CirroMail[^\\\\]*\\\\WindowState"')),
      );
      for (final value in ['X', 'Y', 'W', 'H', 'Max']) {
        expect(windowsWindow, contains('L"$value"'));
      }
      expect(windowsWindow, contains('RegOpenKeyExW'));
      expect(windowsWindow, contains('RegCreateKeyExW'));
      expect(windowsWindow, contains('RegSetValueExW'));
    });

    test('保存取 rcNormalPosition（最大化时 GetWindowRect 会存成满屏，还原后无法缩小）', () {
      expect(windowsWindow, contains('GetWindowPlacement'));
      expect(windowsWindow, contains('rcNormalPosition'));
      expect(windowsWindow, contains('WPF_RESTORETOMAXIMIZED'));
    });

    test('五个保存点一个都不能少（少一个 = 某一类退出方式不记位置）', () {
      // 拖动/缩放结束、最大化/还原、关窗、藏进托盘（Cmd+W 也走它）、托盘退出。
      for (final anchor in [
        'case WM_EXITSIZEMOVE:',
        'case WM_SIZE:',
        'case WM_CLOSE:',
      ]) {
        final body = bodyAfter(windowsWindow, anchor, 'case WM_');
        expect(body, contains('SaveWindowState();'), reason: '$anchor 丢了保存调用');
      }
      final hideToTray = bodyAfter(
        windowsWindow,
        'void FlutterWindow::HideToTray()',
        'void FlutterWindow::EnsureTrayIcon()',
      );
      expect(hideToTray, contains('SaveWindowState();'));
      final quit = bodyAfter(
        windowsWindow,
        'void FlutterWindow::QuitApplication()',
        'void FlutterWindow::ApplyBadgeCount',
      );
      expect(quit, contains('SaveWindowState();'));
    });

    test('恢复在 Flutter 控制器创建之前（否则先按默认尺寸建一次 surface）', () {
      final onCreate = bodyAfter(
        windowsWindow,
        'bool FlutterWindow::OnCreate()',
        'void FlutterWindow::ShowMainWindow()',
      );
      final setWindowPosAt = onCreate.indexOf('SetWindowPos');
      final controllerAt = onCreate.indexOf('flutter_controller_ =');
      expect(setWindowPosAt, isNot(-1));
      expect(controllerAt, isNot(-1));
      expect(setWindowPosAt, lessThan(controllerAt));
    });

    test('main.cpp 在 Create 之前交进启动帧，最大化留给首帧', () {
      final setStartupAt = windowsMain.indexOf('SetStartupFrame(');
      final createAt = windowsMain.indexOf('window.Create(');
      expect(setStartupAt, isNot(-1));
      expect(createAt, isNot(-1));
      expect(setStartupAt, lessThan(createAt));
      expect(
        bodyAfter(
          windowsWindow,
          'engine()->SetNextFrameCallback(',
          'ForceRedraw()',
        ),
        contains('SW_SHOWMAXIMIZED'),
      );
    });

    test('位置校验用当前显示器的可用工作区（拔掉副屏后窗口不能跑到屏幕外）', () {
      expect(windowsWindow, contains('EnumDisplayMonitors'));
      expect(windowsWindow, contains('GetMonitorInfoW'));
      expect(windowsWindow, contains('rcWork'));
    });
  });

  group('Linux：GKeyFile + configure-event 去抖', () {
    test('存档路径用 APPLICATION_ID（公开版/pro 版各一份，代码里没有品牌分支）', () {
      expect(linuxApp, contains('g_get_user_config_dir()'));
      expect(linuxApp, contains('APPLICATION_ID'));
      expect(linuxApp, contains('window-state.ini'));
      expect(linuxApp, contains('g_key_file_load_from_file'));
      expect(linuxApp, contains('g_key_file_save_to_file'));
    });

    test('恢复在窗口 realize 之前（映射之后再调 set_default_size 什么都不发生）', () {
      final restoreAt = linuxApp.indexOf('my_application_restore_window_state(self, window)');
      final realizeAt = linuxApp.indexOf('gtk_widget_realize(');
      expect(restoreAt, isNot(-1));
      expect(realizeAt, isNot(-1));
      expect(restoreAt, lessThan(realizeAt));
    });

    test('configure-event 是保存触发点，且去了抖', () {
      expect(linuxApp, contains('g_signal_connect(window, "configure-event"'));
      expect(linuxApp, contains('g_timeout_add('));
    });

    test('藏窗与托盘退出都立即落盘（藏窗是关闭按钮与 Cmd+W 共用的咽喉点）', () {
      final hide = bodyAfter(
        linuxApp,
        'static void my_application_hide_to_tray(MyApplication* self)',
        '// 「关掉窗口」= 藏进顶栏。',
      );
      expect(hide, contains('my_application_save_window_state(self);'));
      final quit = bodyAfter(
        linuxApp,
        'static void on_tray_quit(gpointer user_data)',
        'static void my_application_hide_to_tray(',
      );
      expect(quit, contains('my_application_save_window_state(self);'));
    });

    test('最大化在 show 之后请求；Wayland 下不读写 x/y', () {
      final firstFrame = bodyAfter(
        linuxApp,
        'static void first_frame_cb(MyApplication* self, FlView* view)',
        '// Dart 侧那条「把窗口叫回来」的通道。',
      );
      final showAt = firstFrame.indexOf('gtk_widget_show');
      final maximizeAt = firstFrame.indexOf('gtk_window_maximize');
      expect(showAt, isNot(-1));
      expect(maximizeAt, isNot(-1));
      expect(showAt, lessThan(maximizeAt));
      expect(linuxApp, contains('GDK_IS_X11_DISPLAY'));
    });

    test('位置恢复要过「当前显示器可见性」校验', () {
      expect(linuxApp, contains('gdk_display_get_monitor('));
      expect(linuxApp, contains('gdk_monitor_get_geometry('));
      expect(linuxApp, contains('gtk_window_move('));
    });
  });
}
