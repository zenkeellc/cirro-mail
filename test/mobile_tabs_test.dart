// 手机上的底部导航只有**两格**：「邮件」与「设置」（2026-11-10 起）。
//
// 星标**还有自己的分支**（切走再切回来保留滚动位置），但不再占一格 tab ——
// 它从主屏菜单进。这里钉住两件事：
//
// 1. 项数就是 2（不再有「星标」那一格）；
// 2. 地址停在星标那一支时，`NavigationBar.selectedIndex` 必须折回「邮件」
//    那一格 —— 直接传分支下标（1）没问题、但星标的分支下标是 1 而设置是 2，
//    2 在只有两格的导航栏上会当场触发 `NavigationBar` 的断言。这条用例就是
//    那个断言的护栏。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const loggedIn = Profile(
    id: 'p1',
    baseUrl: 'https://a/api',
    email: 'a@a.com',
    userId: 7,
  );

  Future<dynamic> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
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
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[loggedIn]),
        ),
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

  testWidgets('底部导航只有「邮件」「设置」两格', (tester) async {
    await pump(tester);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(2));
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations, hasLength(2));
    // 停在收件箱（邮件那一支）→ 高亮第 0 格。
    expect(bar.selectedIndex, 0);

    await reset(tester);
  });

  testWidgets('「设置」是第 1 格；点它去 /settings，点「邮件」回主屏',
      (tester) async {
    final router = await pump(tester);

    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('设置'),
    ));
    await tester.pumpAndSettle();
    expect(uriOf(router), Routes.settings);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );

    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('邮件'),
    ));
    await tester.pumpAndSettle();
    expect(uriOf(router), Routes.home);

    await reset(tester);
  });

  testWidgets('停在星标那一支时不会断言：没有 tab，高亮折回「邮件」',
      (tester) async {
    final router = await pump(tester);

    router.go(Routes.starred);
    await tester.pumpAndSettle();

    expect(uriOf(router), Routes.starred);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(2));
    // 星标的分支下标是 1，但底部导航只有两格 —— 必须折回第 0 格「邮件」。
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );

    await reset(tester);
  });
}

class _FakeSyncController extends SyncController {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  void setActiveProfile(String? profileId) {}
}
