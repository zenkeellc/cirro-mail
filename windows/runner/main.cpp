#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "single_instance.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 先判「是不是已经有一个在跑」。必须在建窗口、起引擎**之前** ——
  // 关窗之后 App 是「藏在通知区里活着」的，任务栏上看不见它，用户从开始菜单
  // 再点一次完全合理；不拦的话就会开出第二个进程去抢同一个 SQLite 库、
  // 重复登记推送、把同一封信弹两遍。
  //
  // 走到这里的失败分支时，对面那份实例已经被请求过「把窗口摆到前面」了，
  // 我们直接退出就行。
  if (!SingleInstance::Acquire()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Cirro Mail", origin, size)) {
    return EXIT_FAILURE;
  }

  // 关窗**不**退出进程 —— 这是 Windows 和 macOS 两边一致的「关窗之后还留在
  // 通知区里收信」的一半（见 `windows/runner/flutter_window.cpp` 的
  // `WM_CLOSE` 分支）。用户看到的「退出」在托盘菜单里，那条路显式销毁窗口，
  // 窗口一没就 `PostQuitMessage`，也就是这里设的 true。
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
