import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/features/settings/settings_screen.dart';
import 'package:mail_app/features/shell/nav_sidebar.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// **页面级**接缝护栏：`AppExtension.notificationExtras` / `composeExtras`
/// 的块真的被「通知」「写邮件」两页画出来了。
///
/// 为什么非要页面级：包里的注册表单测只能证明「注册表把各扩展的块按序拼成
/// 了一个列表」，证明不了核心页面**用了**那个列表。`notifications_section.dart`
/// / `compose_section.dart` 里漏写一行 `...registry.xxxExtras(context)`，
/// 注册表单测照样全绿，而商业版的两块（免打扰 / 云草稿同步）永远不显示 ——
/// 这正是「接缝加了但没接上」的典型症状，只有把真实的 `SettingsScreen` 挂
/// 起来才看得见。
///
/// 「写邮件」页还有一条更隐蔽的路：`compose_section.dart` 在**没有邮箱**时
/// 走 early return 分支，两个分支各写一次 spread。只测有邮箱的那一支时，
/// 空态那条分支漏了 spread 也不会红 —— 所以这里两种输入都测。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  final zh = lookupAppLocalizations(const Locale('zh'));

  /// 挂真实的设置页。[wide] 决定 1400（宽屏两栏）还是 800（窄屏分类列表）。
  ///
  /// 两个 override 都从外面喂：`profiles` / `mailboxes` 决定「写邮件」页走
  /// 非空分支还是空态分支；`extensions` 决定有没有那两个接缝块。
  Future<void> pumpSettings(
    WidgetTester tester, {
    required bool wide,
    List<AppExtension> extensions = const <AppExtension>[],
    List<Profile> profiles = const <Profile>[_profile],
    List<MailboxAccount>? mailboxes = const <MailboxAccount>[_box],
  }) async {
    AppExtensionRegistry.instance.registerAll(extensions);

    tester.view.physicalSize =
        wide ? const Size(1400, 1200) : const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        profilesProvider.overrideWith((ref) => Stream.value(profiles)),
        if (mailboxes != null)
          mailboxesProvider.overrideWith(
            (ref, profileId) => Stream.value(mailboxes),
          ),
        // 「通知」页读 `notificationService.isSupported` —— 换成空实现，免得
        // 为一条「块铺没铺出来」的断言去构造真的平台插件。
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

  Finder categoryRow(String label) => find.descendant(
        of: find.byType(SettingsCategoryTile),
        matching: find.text(label),
      );

  Finder railItem(String label) => find.descendant(
        of: find.byType(NavSidebarItem),
        matching: find.text(label),
      );

  /// 进某一栏。窄屏点分类列表、宽屏点分类栏。
  Future<void> open(WidgetTester tester, String label, {required bool wide}) async {
    await tester.tap(wide ? railItem(label) : categoryRow(label));
    await tester.pumpAndSettle();
  }

  /// 窄屏分类页返回分类列表（宽屏不需要：分类栏一直在）。
  Future<void> back(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
  }

  group('有扩展时：两页真的把它画出来', () {
    testWidgets('窄屏：「通知」页把 notificationExtras 铺在内置两组之后',
        (tester) async {
      await pumpSettings(
        tester,
        wide: false,
        extensions: const <AppExtension>[_ExtrasExt()],
      );
      await open(tester, zh.notifications, wide: false);

      expect(find.text('通知扩展块'), findsOneWidget,
          reason: 'notifications_section.dart 漏了 '
              '`...registry.notificationExtras(context)`');

      // 顺序：内置的应用内提醒 → 后台推送 → 扩展块（末尾）。
      final yInApp = tester.getTopLeft(find.text(zh.notificationsInApp)).dy;
      final yPush = tester.getTopLeft(find.text(zh.notificationsPush)).dy;
      final yExtras = tester.getTopLeft(find.text('通知扩展块')).dy;
      expect(yInApp, lessThan(yPush));
      expect(yPush, lessThan(yExtras),
          reason: '扩展块要铺在这一页正文末尾 —— 不能抢在内置两组之前');

      // 另一页的块不该串进来。
      expect(find.text('写邮件扩展块'), findsNothing);
    });

    testWidgets('窄屏：「写邮件」页（有邮箱）把 composeExtras 铺在末尾',
        (tester) async {
      await pumpSettings(
        tester,
        wide: false,
        extensions: const <AppExtension>[_ExtrasExt()],
      );
      await open(tester, zh.compose, wide: false);

      expect(find.text('写邮件扩展块'), findsOneWidget,
          reason: 'compose_section.dart 的非空分支漏了 '
              '`...registry.composeExtras(context)`');

      // 内置的「发送 / 签名 / 常用语」之后才是扩展块。
      final yPhrases = tester.getTopLeft(find.text(zh.composePhrases)).dy;
      final yExtras = tester.getTopLeft(find.text('写邮件扩展块')).dy;
      expect(yPhrases, lessThan(yExtras));

      expect(find.text('通知扩展块'), findsNothing);
    });

    testWidgets('窄屏：「写邮件」页空态（一台实例都没登）也铺 composeExtras',
        (tester) async {
      // **最关键的一条**：没有邮箱时 `compose_section.dart` 在 early return
      // 分支里再 spread 一次 extras。只测有邮箱那支时，空态漏写不会红。
      await pumpSettings(
        tester,
        wide: false,
        extensions: const <AppExtension>[_ExtrasExt()],
        profiles: const <Profile>[],
        mailboxes: null,
      );
      await open(tester, zh.compose, wide: false);

      // 先确认真的走在空态分支上：空态提示在，签名 / 常用语两行不在。
      expect(find.text(zh.composeSignatureEmpty), findsOneWidget);
      expect(find.text(zh.composeSectionSignatures), findsNothing);
      expect(find.text(zh.composePhrases), findsNothing);

      expect(find.text('写邮件扩展块'), findsOneWidget,
          reason: '空态分支漏了 spread —— 新装用户在「写邮件」页看不到商业版的块');
      expect(
        tester.getTopLeft(find.text(zh.composeSignatureEmpty)).dy,
        lessThan(tester.getTopLeft(find.text('写邮件扩展块')).dy),
        reason: '空态块与扩展块都在，且扩展块在末尾',
      );
    });

    testWidgets('宽屏：「通知」与「写邮件」两栏都铺出各自的扩展块',
        (tester) async {
      await pumpSettings(
        tester,
        wide: true,
        extensions: const <AppExtension>[_ExtrasExt()],
      );

      await open(tester, zh.notifications, wide: true);
      expect(find.text('通知扩展块'), findsOneWidget,
          reason: '宽屏右栏与窄屏分类页是两条渲染路径，要各钉一次');
      expect(find.text('写邮件扩展块'), findsNothing);

      await open(tester, zh.compose, wide: true);
      expect(find.text('写邮件扩展块'), findsOneWidget);
      expect(find.text('通知扩展块'), findsNothing);
    });
  });

  group('空注册表（公开版）', () {
    testWidgets('两页都看不到任何扩展块，而内置内容照常',
        (tester) async {
      await pumpSettings(tester, wide: false);

      await open(tester, zh.notifications, wide: false);
      // 内置两组在 —— 否则下面两条「找不到」可能只是整页没建出来。
      expect(find.text(zh.notificationsInApp), findsOneWidget);
      expect(find.text(zh.notificationsPush), findsOneWidget);
      expect(find.text('通知扩展块'), findsNothing);

      await back(tester);
      await open(tester, zh.compose, wide: false);
      expect(find.text(zh.send), findsOneWidget);
      expect(find.text(zh.composeSectionSignatures), findsOneWidget);
      expect(find.text('写邮件扩展块'), findsNothing);
    });
  });
}

const String _email = 'me@example.com';

const Profile _profile = Profile(
  id: 'p1',
  baseUrl: 'https://x/api',
  email: _email,
  userName: '王五',
  userId: 7,
);

const MailboxAccount _box = MailboxAccount(
  accountId: 1,
  email: _email,
  name: 'Me',
);

/// 两条接缝各返回一块，块内文案把「来自哪条接缝」写明 —— 断言找的就是它。
class _ExtrasExt extends AppExtension {
  const _ExtrasExt();

  @override
  String get id => 'test.extras';

  @override
  List<Widget> notificationExtras(BuildContext context) => <Widget>[
        const ListTile(title: Text('通知扩展块')),
      ];

  @override
  List<Widget> composeExtras(BuildContext context) => <Widget>[
        const ListTile(title: Text('写邮件扩展块')),
      ];
}

/// 「通知」页只读 `NotificationService.isSupported`；这组用例测的是接缝有没有
/// 接线，与平台通知无关 —— 空实现，别去构造真的插件。
///
/// `isSupported` 必须回 `true`：默认的 `null` 落到 `bool` 位置会当场抛。
class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #isSupported) return true;
    return null;
  }
}
