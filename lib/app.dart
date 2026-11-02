import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'core/version/window_title.dart';
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

    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      routerConfig: router,
      // 中英双语：`supportedLocales` 由 ARB 生成，加语言时不用改这里。
      // `AppLocalizations.localizationsDelegates` 里已经含
      // GlobalMaterial/Widgets/Cupertino 三个 delegate，不必再补。
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      themeMode: themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
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
      // 最外面两层是「版本」的两个出口，都是**不改布局**的接线柱：
      // - `UpdateHost`：启动后每天最多一次查官网版本清单，发现新版本弹一条
      //   SnackBar（下载 / 查看）。它要 `ScaffoldMessenger`，所以必须在这
      //   里面（`MaterialApp` 提供），放外面不会崩、但 SnackBar 静默不弹。
      // - `WindowTitleHost`：把版本写进**原生**窗口标题栏。它不碰
      //   `MaterialApp.title` —— 那只影响任务切换器显示的名字（见
      //   `core/version/window_title.dart` 与三个 runner 的 `setWindowTitle`）。
      builder: (context, child) => WindowTitleHost(
        child: UpdateHost(
          child: MailShortcutHost(
            child: NotificationHost(child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}
