import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/branding/app_brand.dart';
import 'core/version/window_title.dart';
import 'features/deeplink/external_link_host.dart';
import 'features/notifications/icon_badge_host.dart';
import 'features/notifications/notification_host.dart';
import 'features/shortcuts/shortcut_host.dart';
import 'features/update/update_host.dart';
import 'l10n/app_localizations.dart';
import 'providers/settings_providers.dart';
import 'router.dart';

/// App 根。
///
/// 只做四件事：主题、语言、路由、标题。**不持有任何业务状态** ——
/// 单实例/多实例、登录与否都折算在 `redirect` 里（见 `router.dart`），
/// 所以这里不需要判断「该显示登录页还是收件箱」。
///
/// `ProviderScope` 在 `main.dart` 里，因为 `bootstrapProvider` 必须被
/// override 成启动时建好的那几样东西（库、密钥库、prefs）。
class MailApp extends ConsumerWidget {
  const MailApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    // 主题包（扩展接缝 `AppExtension.themes`）。公开版注册表为空 → 下面两个
    // provider 直接回退到内置那套蓝，行为与接缝出现之前逐字一致。
    final themeData = ref.watch(activeThemeDataProvider);
    final themePack = ref.watch(activeThemePackProvider);

    return MaterialApp.router(
      // 任务切换器 / 任务栏那一行名字。与侧栏左上角同源（见 `AppBrand`）。
      onGenerateTitle: (context) => AppBrand.displayName(context),
      routerConfig: router,
      // 中英双语：`supportedLocales` 由 ARB 生成，加语言时不用改这里。
      // `AppLocalizations.localizationsDelegates` 里已经含
      // GlobalMaterial/Widgets/Cupertino 三个 delegate，不必再补。
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      themeMode: themeMode,
      theme: themeData.light,
      darkTheme: themeData.dark,
      // 通知的接线柱。**必须在 `MaterialApp.router` 里面**：它要用
      // `AppLocalizations`（文案）和 router（点通知后导航），两者都只有
      // 在 MaterialApp 之下才拿得到。它自己是个不画东西的 widget
      // （`builder` 的 child 原样返回），所以放进 builder 不影响布局。
      //
      // 外面再罩一层 `MailShortcutHost`（快捷键）。**顺序有讲究**：
      // - 它在 `builder` 的**输出外面**，于是整棵树里只有这一层 ——
      //   各页面自己的 `Shortcuts`（写邮件页那个）比它近，能盖住它；
      // - 它比框架的 `DefaultTextEditingShortcuts` **近**（探针实测的焦点链：
      //   我们的 `Shortcuts` 在 `Default Text Editing Shortcuts` 之前被走到），
      //   所以它是**全权**的 —— 我们占了哪个键，框架就再也收不到。
      //   代价是 `mailShortcutsFor` 那张表一个编辑键都不能有（剪贴板 / 撤销
      //   归框架，靠的是「表里没有它 + 没命中时返回 ignored」）；
      //   `test/mail_shortcuts_keymap_test.dart` 钉住了这一点，
      //   `test/mail_shortcuts_clipboard_test.dart` 是端到端的验证。
      // - 它在 `NotificationHost` **外面**：通知点开会 push 路由，快捷键
      //   要罩住推上来的那一页。
      //
      // `ExternalLinkHost`（外部链接 / 自定义 scheme 深链）夹在两者之间：
      // 它只要 `ref`（`routerProvider`）与一张常驻的订阅表，既不需要
      // `ScaffoldMessenger`，也不参与快捷键的焦点链 —— 放在这层的理由与
      // 「顺序」无关，是「它必须在 `ProviderScope` 里、且活得和 App 一样久」，
      // 而这段 `builder` 是第一个同时满足这两点的地方（扩展在 `runApp` 之前
      // 注册，`main.dart` 那时还没有 `ref`，也不该动 `main.dart` —— 两个检出
      // 必须逐字节相同）。空注册表（公开版）时它一个流都不订阅、一个像素都
      // 不画，挂在链上的位置因此在视觉与行为上都不可观测。
      //
      // 最外面两层是「版本」的两个出口，再外面是图标徽章，都是**不改布局**的
      // 接线柱：
      // - `UpdateHost`：启动后每天最多一次查官网版本清单，发现新版本弹一条
      //   SnackBar（下载 / 查看）。它要 `ScaffoldMessenger`，所以必须在这
      //   里面（`MaterialApp` 提供），放外面不会崩、但 SnackBar 静默不弹。
      // - `WindowTitleHost`：把版本写进**原生**窗口标题栏。它不碰
      //   `MaterialApp.title` —— 那只影响任务切换器显示的名字（见
      //   `core/version/window_title.dart` 与三个 runner 的 `setWindowTitle`）。
      // - `IconBadgeHost`：把全部实例的未读总数写进系统图标角标（Dock / 菜单栏 /
      //   任务栏 / 托盘 / 手机桌面图标）。它只要 `ref`，放在最外面 —— 越靠外
      //   越早挂上，冷启动时的首推才不会漏掉（见
      //   `features/notifications/icon_badge_host.dart`）。
      builder: (context, child) {
        // 主题背板：铺在**整棵 UI 下面**（路由内容之上没有、之下有一层）。
        // 主题包把 `scaffoldBackgroundColor` 留了透明度，所以它透得出来。
        // 没有背板（公开版、或纯配色主题）时这里原样返回 content —— 多一层
        // IgnorePointer 也不该出现，否则空注册表的构建与接缝之前不是逐字相同。
        final backdrop = themePack?.buildBackdrop(context);
        final Widget content = IconBadgeHost(
          child: WindowTitleHost(
            child: UpdateHost(
              child: MailShortcutHost(
                child: ExternalLinkHost(
                  child: NotificationHost(
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        );
        if (backdrop == null) return content;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned.fill(
              child: IgnorePointer(
                // 背板是静态的：一层 RepaintBoundary 把它的绘制与上方列表/滚动的
                // 重绘隔开，滚动邮件列表时它不会被带着重画。
                child: RepaintBoundary(child: backdrop),
              ),
            ),
            content,
          ],
        );
      },
      debugShowCheckedModeBanner: false,
    );
  }
}
