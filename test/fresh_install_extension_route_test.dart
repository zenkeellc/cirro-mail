// 零实例时，**扩展的顶层页面**必须还能进。
//
// ## 现场（2026-11-10 安卓真机）
//
// 全新安装的商业版（零实例）里，设置 → 账号 → 登录，点下去**没有任何反应**：
// 一个实例都没有时 `resolveRedirect` 把**任何**地址都折回 `/settings`，于是
// `AppExtension.routes()` 挂在根上的 `/account/login`（壳之外的整屏页）刚被
// `go` 上去就被原样折回来 —— 用户看到的是「按钮失灵」。
//
// 同一条重定向也是底部导航那两个死键的成因（`/mail/...`、`/starred` 折回
// 设置页）；那两条由外壳**把导航收起**来兜（见 `AppShell` 的 `noInstances`）。
// 这里只钉第三件事：**扩展顶层页的放行**。
//
// 用真 `routerProvider` + 一个假扩展（与商业版同形的 `/account/login`）：
// 缺陷的成因就是「顶层路由 + redirect」，单看 `resolveRedirect` 的返回值不足以
// 证明用户真的能到那一页。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/settings/settings_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 与商业版的 `/account/login` 同形：顶层路由（壳之外）、不依赖邮件实例。
class _AccountLoginExt extends AppExtension {
  const _AccountLoginExt();

  @override
  String get id => 'test.account';

  @override
  List<RouteBase> routes() => <RouteBase>[
        GoRoute(
          path: '/account/login',
          builder: (context, state) => const Scaffold(
            body: Center(child: Text('probe-account-login')),
          ),
        ),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('一个实例都没有（全新安装）', () {
    testWidgets('扩展的顶层页照常打开（Pro 的账号登录就挂在这里）', (tester) async {
      AppExtensionRegistry.instance
          .registerAll(const <AppExtension>[_AccountLoginExt()]);
      final router = await pump(tester, profiles: const <Profile>[]);

      // 冷启动仍然落在设置页（零实例时的唯一可用页）。
      expect(uriOf(router), Routes.settings);

      router.go('/account/login');
      await tester.pumpAndSettle();
      expect(uriOf(router), '/account/login',
          reason: '扩展顶层页不该被「零实例 → 设置页」那条重定向吞掉');
      expect(find.text('probe-account-login'), findsOneWidget);

      await reset(tester);
    });

    testWidgets('扩展顶层页的子路径同样放行', (tester) async {
      AppExtensionRegistry.instance
          .registerAll(const <AppExtension>[_AccountLoginExt()]);
      final router = await pump(tester, profiles: const <Profile>[]);

      router.go('/account/login?expired=1');
      await tester.pumpAndSettle();
      expect(uriOf(router), '/account/login?expired=1');
      expect(find.text('probe-account-login'), findsOneWidget);

      await reset(tester);
    });

    testWidgets('外壳里的页面（邮件 / 星标）仍然折回设置页', (tester) async {
      final router = await pump(tester, profiles: const <Profile>[]);

      expect(uriOf(router), Routes.settings);
      router.go(Routes.starred);
      await tester.pumpAndSettle();
      expect(uriOf(router), Routes.settings);
      router.go(Routes.home);
      await tester.pumpAndSettle();
      expect(uriOf(router), Routes.settings);

      await reset(tester);
    });

    testWidgets('零实例时底部导航收起 —— 不摆两条点了没反应的按钮',
        (tester) async {
      final router = await pump(tester, profiles: const <Profile>[]);

      expect(uriOf(router), Routes.settings);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);

      await reset(tester);
    });

    testWidgets('添加实例、登录之后导航自己回来', (tester) async {
      final router = await pump(tester, profiles: const <Profile>[loggedIn]);

      // 有实例 → 冷启动落在收件箱，底部导航在。
      expect(uriOf(router), Routes.mailAll);
      expect(find.byType(NavigationBar), findsOneWidget);

      await reset(tester);
    });
  });

  group('公开版（空注册表）行为不变', () {
    test('零实例 + 未注册扩展 → 任何地址都折回设置页', () {
      expect(
        resolveRedirect(
          healthy: true,
          async: const AsyncData<List<Profile>>(<Profile>[]),
          location: '/account/login',
          profileIdParam: null,
        ),
        Routes.settings,
      );
    });
  });
}

class _FakeSyncController extends SyncController {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  void setActiveProfile(String? profileId) {}
}
