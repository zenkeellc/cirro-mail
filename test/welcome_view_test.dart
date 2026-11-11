// 零实例（全新安装 / 刚把最后一个实例删掉）时，**主页面**是欢迎 / 引导页。
//
// ## 现场（2026-11-11 iOS 真机）
//
// Pro 全新安装、一个邮件实例都没有：页面停在设置页，底部导航被外壳整条收起，
// 主页面根本到不了 —— 用户的原话是「停在设置页面，无法返回到主页面」。
// 成因两条，缺一条都复现不出来：
//
// 1. `resolveRedirect` 零实例时把 `/home` 也折回 `/settings`；
// 2. `AppShell` 又因为零实例把底部导航收起（上一版为了不摆「点了没反应」
//    的按钮）。
//
// 修法：`/home` 在零实例时也放行，画成一张欢迎 / 引导页（`WelcomeView`）；
// 底部导航保留，两格都通向真页面。这里钉住这张页的骨架：
//
// - 它说清楚「还没有实例」，并只给**一条**一级动作（去设置添加实例）；
// - 功能亮点是**说明**，不是可点的卡（零实例时点进去也没有真数据可看）；
// - 扩展的 `welcomeActions` 铺在主按钮下面（商业版的账号登录就挂在这里）。
//
// 用真 `routerProvider` + 真外壳：缺陷的成因是「重定向 + 外壳收导航」，
// 单看 `WelcomeView` 一个 widget 是看不出来的。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/home/home_menu_screen.dart';
import 'package:mail_app/features/home/welcome_view.dart';
import 'package:mail_app/features/settings/settings_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只在欢迎页挂一颗按钮的扩展 —— 商业版 `welcomeActions` 的最小同形替身。
class _WelcomeActionExt extends AppExtension {
  const _WelcomeActionExt();

  @override
  String get id => 'test.welcome_action';

  @override
  List<Widget> welcomeActions(BuildContext context) => <Widget>[
        TextButton(
          onPressed: () {},
          child: const Text('probe-welcome-action'),
        ),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final zh = lookupAppLocalizations(const Locale('zh'));

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  const loggedIn = Profile(
    id: 'p1',
    baseUrl: 'https://a/api',
    email: 'a@a.com',
    userId: 7,
  );

  Future<dynamic> pump(
    WidgetTester tester, {
    required List<Profile> profiles,
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        prefsStoreProvider.overrideWithValue(prefs),
        profilesProvider.overrideWith((ref) => Stream.value(profiles)),
        syncControllerProvider.overrideWith(_FakeSyncController.new),
      ],
    );
    addTearDown(container.dispose);

    final router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  String uriOf(dynamic router) =>
      router.routeInformationProvider.value.uri.toString();

  Future<void> reset(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  group('零实例的主页面（欢迎 / 引导页）', () {
    testWidgets('冷启动落在主页面，不是设置页；说清现状 + 给一条添加实例的路',
        (tester) async {
      final router = await pump(tester, profiles: const <Profile>[]);

      expect(uriOf(router), Routes.home);
      expect(find.byType(WelcomeView), findsOneWidget);
      expect(find.text(zh.welcomeHeadline), findsOneWidget);
      expect(find.text(zh.welcomeBody), findsOneWidget);
      // 唯一的一级动作：去设置添加第一个实例。
      expect(
        find.widgetWithText(FilledButton, zh.addFirstInstance),
        findsOneWidget,
      );
      // 功能亮点是**说明**（静态卡），不是可点入口。
      expect(find.text(zh.welcomeFeatureInboxTitle), findsOneWidget);
      expect(find.text(zh.welcomeFeatureComposeTitle), findsOneWidget);
      expect(find.text(zh.welcomeFeatureNotifyTitle), findsOneWidget);
      expect(find.text(zh.welcomeFeaturePrivacyTitle), findsOneWidget);

      await reset(tester);
    });

    testWidgets('主按钮去设置页，底部导航「邮件」把用户送回主页面',
        (tester) async {
      final router = await pump(tester, profiles: const <Profile>[]);

      await tester.tap(find.widgetWithText(FilledButton, zh.addFirstInstance));
      await tester.pumpAndSettle();
      expect(uriOf(router), Routes.settings);
      expect(find.byType(SettingsScreen), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(zh.mailTab),
      ));
      await tester.pumpAndSettle();
      expect(uriOf(router), Routes.home);
      expect(find.byType(WelcomeView), findsOneWidget);

      await reset(tester);
    });

    testWidgets('扩展的 welcomeActions 铺在主按钮下面（商业版的账号登录）',
        (tester) async {
      AppExtensionRegistry.instance
          .registerAll(const <AppExtension>[_WelcomeActionExt()]);
      await pump(tester, profiles: const <Profile>[]);

      expect(find.text('probe-welcome-action'), findsOneWidget);
      expect(find.byType(WelcomeView), findsOneWidget);

      await reset(tester);
    });

    testWidgets('有实例时主屏就是原来的菜单网格 —— 欢迎页不出现', (tester) async {
      final router = await pump(
        tester,
        profiles: const <Profile>[loggedIn],
      );

      // 有实例的冷启动落在收件箱（与欢迎页无关的那条老路）。
      expect(uriOf(router), Routes.mailAll);

      router.go(Routes.home);
      await tester.pumpAndSettle();
      expect(find.byType(HomeMenuScreen), findsOneWidget);
      expect(find.byType(WelcomeView), findsNothing);

      await reset(tester);
    });
  });
}

class _FakeSyncController extends SyncController {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  void setActiveProfile(String? profileId) {}
}
