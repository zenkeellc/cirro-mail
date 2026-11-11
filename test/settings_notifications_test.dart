import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/features/notifications/push_service.dart';
import 'package:mail_app/features/settings/sections/push_section.dart';
import 'package:mail_app/features/settings/settings_screen.dart';
import 'package:mail_app/features/shell/nav_sidebar.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「设置 → 通知」这一页，以及它里面那个「后台推送」**子页**。
///
/// 这次重排把三处讲同一件事的东西合成了一页（收信页的两张提醒开关、独占
/// 一栏的「推送」、商业版独占一栏的「免打扰」）。最容易写坏的是两处：
///
/// 1. **子页的进/退层级**。窄屏的返回箭头有三级：子页 → 分类页 → 分类
///    列表。写成两级的话点一下返回会直接跳回列表，用户刚看的「通知」页没了；
///    写成四级的话点一下没反应 —— 两种都不报错，只是「返回坏了」。
/// 2. **提醒开关真的搬过来了**。「收信」页少了两张开关的同时，「通知」页
///    必须有它们；只删不加 = 用户再也关不掉提醒。
///
/// 「发送延迟」搬到「写邮件」页是另一条独立的搬迁，见
/// `settings_send_delay_test.dart`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  final zh = lookupAppLocalizations(const Locale('zh'));

  /// 挂起设置页。[wide] 决定 1400（宽屏两栏）还是 800（窄屏分类列表）。
  Future<void> pumpSettings(
    WidgetTester tester, {
    required bool wide,
  }) async {
    tester.view.physicalSize = wide
        ? const Size(1400, 1200)
        : const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final tokens = TokenStore();
    // 推送向导一建出来就会读钥匙串、问 `PushService` 要状态；给它一个什么都不
    // 连的实例，别让这条用例去碰网络。
    final push = PushService(
      prefs: prefs,
      tokens: tokens,
      readProfiles: () async => const [],
      readMailboxes: (_) async => const [],
      forceAvailable: true,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        tokenStoreProvider.overrideWithValue(tokens),
        pushServiceProvider.overrideWithValue(push),
        notificationServiceProvider.overrideWithValue(_SilentNotifications()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 窄屏分类列表里的一行。
  Finder categoryRow(String label) => find.descendant(
        of: find.byType(SettingsCategoryTile),
        matching: find.text(label),
      );

  /// 宽屏分类栏里的一项。
  Finder railItem(String label) => find.descendant(
        of: find.byType(NavSidebarItem),
        matching: find.text(label),
      );

  /// 窄屏：分类列表 → 「通知」页。
  Future<void> openNarrow(WidgetTester tester, String label) async {
    await tester.tap(categoryRow(label));
    await tester.pumpAndSettle();
  }

  /// 宽屏：分类栏 → 某一栏。
  Future<void> openWide(WidgetTester tester, String label) async {
    await tester.tap(railItem(label));
    await tester.pumpAndSettle();
  }

  /// 点「通知」页第二组里那一行（标题是长名字「系统推送」），进子页。
  Future<void> openPush(WidgetTester tester) async {
    await tester.tap(find.text(zh.pushTitle));
    await tester.pumpAndSettle();
  }

  group('「通知」页的内容', () {
    testWidgets('窄屏：应用内提醒 + 后台推送两组，顺序即「从近到远」',
        (tester) async {
      await pumpSettings(tester, wide: false);
      await openNarrow(tester, '通知');

      // 标题是分类名（页内标题没有分类栏的宽度压力）。
      expect(find.text(zh.notifications), findsWidgets);

      // 第一组：应用内提醒 —— 两张开关都是从这里搬过来的。
      expect(find.text(zh.notificationsInApp), findsOneWidget);
      expect(
        find.text(zh.notifyEnabledHint),
        findsOneWidget,
        reason: '「收信 / 提醒」总开关搬进「通知」页后，它的说明文字也必须在',
      );
      // notifyEnabled 默认开、平台（假服务）支持 → 横幅开关同组出现。
      expect(find.text(zh.notifyBanner), findsOneWidget);

      // 第二组：后台推送 —— 只有一行入口，向导在子页里。
      expect(find.text(zh.notificationsPush), findsOneWidget);
      expect(find.text(zh.pushTitle), findsOneWidget);
      expect(find.text(zh.pushHint), findsOneWidget);

      // 「从近到远」：应用内提醒在后台推送**之上**。
      expect(
        tester.getTopLeft(find.text(zh.notificationsInApp)).dy,
        lessThan(tester.getTopLeft(find.text(zh.notificationsPush)).dy),
      );

      // 只是入口，Point 2 那条「按需构造」同理：没点子页就不建向导。
      expect(find.byType(PushSection), findsNothing);
    });

    testWidgets('窄屏：「收信」页不再有那两张提醒开关', (tester) async {
      await pumpSettings(tester, wide: false);
      await openNarrow(tester, '收信');

      // 收信页只剩「检查间隔 / 预取正文」。
      expect(find.text(zh.pollInterval), findsOneWidget);
      expect(find.text(zh.prefetchTitle), findsOneWidget);
      expect(
        find.text(zh.notifyEnabledHint),
        findsNothing,
        reason: '提醒总开关已经搬进「通知」页，收信页里不该再有第二份',
      );
      expect(find.text(zh.notifyBanner), findsNothing);
    });

    testWidgets('宽屏：右栏是「通知」页，点那一行进子页', (tester) async {
      await pumpSettings(tester, wide: true);
      await openWide(tester, '通知');

      expect(find.text(zh.notificationsInApp), findsOneWidget);
      expect(find.text(zh.notificationsPush), findsOneWidget);
      // 宽屏下子页还没开：右栏页头没有返回箭头（分类栏就是出口）。
      expect(find.byIcon(Icons.arrow_back), findsNothing);

      await openPush(tester);

      // 子页顶上来：向导出现，右栏页头多一颗返回箭头，分类栏仍在。
      expect(find.byType(PushSection), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.byType(NavSidebarItem), findsNWidgets(10),
          reason: '宽屏子页不压栈 —— 分类栏不会消失');
      // 页头标题换成子页的标题。
      expect(find.text(zh.notificationsInApp), findsNothing);
      expect(find.text(zh.notificationsPush), findsWidgets);

      // 页头那颗返回箭头把分类正文换回来（不是离开设置页）。
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.byType(PushSection), findsNothing);
      expect(find.text(zh.notificationsInApp), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.byType(NavSidebarItem), findsNWidgets(10));
    });
  });

  group('「后台推送」子页的进与退', () {
    testWidgets('窄屏：返回箭头先退子页、回到「通知」页，再退分类列表',
        (tester) async {
      await pumpSettings(tester, wide: false);
      await openNarrow(tester, '通知');
      await openPush(tester);

      // 进到子页：AppBar 标题是「后台推送」，向导出现。
      expect(find.byType(PushSection), findsOneWidget);
      expect(find.text(zh.notificationsPush), findsOneWidget);
      expect(find.text(zh.notificationsInApp), findsNothing);

      // 第一下：退子页 → 「通知」页（**不是**分类列表）。
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.byType(PushSection), findsNothing);
      expect(
        find.text(zh.notificationsInApp),
        findsOneWidget,
        reason: '返回箭头该先退回「通知」页；直接回分类列表会让用户刚看的页消失',
      );
      expect(
        categoryRow('实例'),
        findsNothing,
        reason: '只退一级 —— 这时还该在「通知」页里',
      );

      // 第二下：退分类页 → 分类列表。
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(categoryRow('实例'), findsOneWidget);
      expect(categoryRow('通知'), findsOneWidget);
      expect(find.text(zh.notificationsInApp), findsNothing);
    });

    testWidgets('窄屏：系统返回键在第一页也是「退子页」，不退分类页',
        (tester) async {
      await pumpSettings(tester, wide: false);
      await openNarrow(tester, '通知');
      await openPush(tester);

      // 向导停在第 ① 页，`PushSection` 的 PopScope 允许 pop，交给设置页的
      // `_back` 处理 —— 它知道现在该退的是子页。
      //
      // 不能直接 await `handlePopRoute()`：那个 future 要等整套弹出流程跑完，
      // 而流程靠帧推进（照抄 `settings_layout_test.dart` 的写法）。
      final popped = tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(await popped, isTrue, reason: '返回手势应当被设置页接住');
      expect(find.byType(PushSection), findsNothing);
      expect(
        find.text(zh.notificationsInApp),
        findsOneWidget,
        reason: '系统返回键该退回「通知」页，而不是把整个设置页弹掉',
      );
    });

    testWidgets('窄屏：退出「通知」再进来是分类正文，不残留子页', (tester) async {
      await pumpSettings(tester, wide: false);
      await openNarrow(tester, '通知');
      await openPush(tester);
      expect(find.byType(PushSection), findsOneWidget);

      // 宿主在 `_select` / `_back` 里把 `_subPage` 清掉：用户已经走开了，
      // 下次进「通知」该看到分类正文，而不是半路留着一个推送向导。子页
      // **不缓存**（见 `_subPage` 的注释）—— 留一份旧向导状态比多建一次
      // 更容易骗人（它一建出来就要读钥匙串、打 `/devices`）。
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await openNarrow(tester, '通知');
      expect(
        find.byType(PushSection),
        findsNothing,
        reason: '重新进「通知」页应当是分类正文 —— 子页状态归宿主，不该留着',
      );
      expect(find.text(zh.notificationsInApp), findsOneWidget);
    });
  });
}

/// 「通知」页只读 `NotificationService.isSupported` 与几个开关的读写；这里
/// 测的是导航，不是通知，所以换成空实现 —— 别去构造真的平台插件。
///
/// `isSupported` 必须给 `true`：`noSuchMethod` 默认的 `null` 落到 `bool`
/// 位置会当场抛；而默认 `notifyEnabled=true`，这一步决定横幅开关画不画。
class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #isSupported) return true;
    return null;
  }
}
