cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "tray_icon.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# === 顶栏图标的两个后端 ===
#
# `libayatana-appindicator3` 是现代桌面（GNOME 3.26+ / KDE / 各大 DE）唯一还
# 显示得出来的那套；GNOME 早把内置的状态栏图标整个去掉了。但它是个**额外
# 依赖**，很多机器上没有 `-dev` 包，所以这里是 `QUIET` + 可选：探到就用它
# （并定义 CIRRO_HAVE_AYATANA_APPINDICATOR，见 `tray_icon.cc` 里的 #ifdef），
# 探不到就退回 GTK 自带的 GtkStatusIcon。
#
# **不能写成 REQUIRED** —— 那会让没装这个包的机器 `flutter build linux` 直接
# 失败，而它的用户本来跑得好好的。这条也是 `linux/runner/CMakeLists.txt` 里
# 唯一一处新增的系统依赖。
pkg_check_modules(APPINDICATOR QUIET IMPORTED_TARGET ayatana-appindicator3-0.1)
if(APPINDICATOR_FOUND)
  target_compile_definitions(${BINARY_NAME} PRIVATE "CIRRO_HAVE_AYATANA_APPINDICATOR")
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::APPINDICATOR)
  message(STATUS "Tray icon: libayatana-appindicator3 已找到，使用 AppIndicator 后端")
else()
  message(STATUS "Tray icon: 没找到 libayatana-appindicator3，退回 GtkStatusIcon（GNOME 上不会显示）")
endif()

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
