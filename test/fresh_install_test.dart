// 「全新安装」（一个实例都没有）时，App 该落在**设置页**，而不是一张占满
// 整窗的「添加实例」页。
//
// ## 之前是什么样
//
// `resolveRedirect` 在实例表为空时把**任何**地址都折到 `/setup` —— 那张页是
// 顶层路由（壳之外）：一级导航（宽屏侧栏 / 窄屏底部导航）与设置页的分类菜单
// （宽屏分类栏 / 窄屏分类列表）一个都不在，整窗只有一张填地址的表单。用户
// 点设置，看到的就是这张表单，实际却没有任何「设置」可看。
//
// ## 现在钉住的三件事
//
// 1. **零实例的冷启动落点**：`/settings`，壳在、设置页在；
// 2. **添加实例是设置页里的一栏**：宽屏换右栏（分类栏常驻）、窄屏是分类页
//    （返回到实例列表，再返回到分类列表），**不改地址、不压栈**；
// 3. **旧地址不断**：`/setup` 与 `/settings/add-instance` 都是到 `/settings`
//    的重定向（它们可能出现在旧文档 / 浏览历史里）。
//
// 用真 `routerProvider` + 真外壳：缺陷的成因就是「顶层路由 + redirect」，
// 单页 widget 里看不出来。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/compose/compose_action.dart';
import 'package:mail_app/features/home/welcome_view.dart';
import 'package:mail_app/features/settings/settings_screen.dart';
import 'package:mail_app/features/shell/nav_sidebar.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final zh = lookupAppLocalizations(const Locale('zh'));

  const loggedIn = Profile(
    id: 'p1',
    baseUrl: 'https://a/api',
    email: 'a@a.com',
    userId: 7,
  );

  /// 起一棵真路由 + 真外壳。[seedDb] 为真时把 [profiles] 写进 drift 库并让
  /// `profilesProvider` 走**真**仓库（删/加实例之后列表真的会变，用处是
  /// 确认「零实例」不是写死的快照）。
  Future<GoRouterLike> pump(
    WidgetTester tester, {
    required List<Profile> profiles,
    required Size size,
    bool seedDb = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    if (seedDb) {
      for (final profile in profiles) {
        await db.profileDao.upsertProfile(profile);
      }
    }

    final container = ProviderContainer(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        prefsStoreProvider.overrideWithValue(prefs),
        if (!seedDb)
          profilesProvider.overrideWith((ref) => Stream.value(profiles)),
        // 真身会拉起整个调度器（20s 时钟 + 平台通道）。这一组验的是落点与
        // 版面，调度器不参与，换成空壳。
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
    return GoRouterLike(router);
  }

  /// 拆树再推一帧，放掉零延时的清理定时器（外壳里还挂着一个周期时钟）。
  Future<void> settleAndDispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  /// 分类栏 / 分类列表里的「实例」那一项。
  ///
  /// 分类名在整页里至少出现在两处（宽屏：分类栏 + 右栏 `PaneHeader`；
  /// 窄屏：分类列表 + 分类页 AppBar），所以必须收窄到容器里找。
  Finder railItem(String label) => find.descendant(
        of: find.byType(SettingsScreen),
        matching: find.descendant(
          of: find.byType(NavSidebarItem),
          matching: find.text(label),
        ),
      );

  /// 设置页分类栏里的项。外壳侧栏也有一批 `NavSidebarItem`，必须收窄到
  /// 设置页那一棵子里，否则数出来的是「外壳 8 项 + 分类 10 项」。
  Finder settingsRailItem() => find.descendant(
        of: find.byType(SettingsScreen),
        matching: find.byType(NavSidebarItem),
      );

  /// 窄屏分类列表里的一行。
  ///
  /// 列表行与宽屏分类栏**共用**同一颗 `NavSidebarItem`（见
  /// `SettingsCategoryTile` 的类文档），所以不能按 `ListTile` 找，也不能只按
  /// `NavSidebarItem` 找 —— 必须收窄到 `SettingsCategoryTile`。
  Finder categoryTile(String label) => find.descendant(
        of: find.byType(SettingsCategoryTile),
        matching: find.text(label),
      );

  group('一个实例都没有（全新安装）', () {
    testWidgets('宽屏：落在设置页，一级导航收起 —— 不是那张占满整窗的表单',
        (tester) async {
      final r = await pump(
        tester,
        profiles: const <Profile>[],
        size: const Size(1400, 900),
      );

      // 宽屏没有「主页面」这一页（侧栏自己就是主页面），零实例的落点
      // 是设置页 —— 添加实例就在「实例」那一栏里。
      expect(r.uri, Routes.settings);
      // 零实例时宽屏侧栏收起：侧栏里每一项都会折回设置页，摆着是一排死键。
      expect(find.byType(NavSidebar), findsNothing,
          reason: '零实例时宽屏侧栏收起');
      // 设置页本体在（不是那张表单）。
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text(zh.addAndSignIn), findsNothing,
          reason: '零实例不该一进来就开着表单');
      // 分类栏常驻（二级菜单）。
      expect(railItem(zh.instances), findsOneWidget);
      // 默认选中「实例」：右栏是这一栏的正文（空实例时的入口）。
      expect(find.text(zh.addFirstInstance), findsOneWidget);

      await settleAndDispose(tester);
    });

    testWidgets('窄屏：落在主页面（欢迎页），底部导航两格都在',
        (tester) async {
      final r = await pump(
        tester,
        profiles: const <Profile>[],
        size: const Size(420, 900),
      );

      // 落点：/mail/all → /home（主页面）。零实例时主屏是欢迎 / 引导页，
      // 不是一列点不动的图标，也不是「只剩设置页」的死路 —— 2026-11-11
      // iOS 真机反馈的那条「停在设置页、回不到主页面」就是它。
      expect(r.uri, Routes.home);
      expect(find.byType(WelcomeView), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(WelcomeView),
          matching: find.text(zh.welcomeHeadline),
        ),
        findsOneWidget,
      );
      // 底部导航两格都在：邮件（= 这一页）与设置。
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(2));
      // 零实例时没有发件人，写邮件那颗浮动按钮必须收起来（点了只会被
      // redirect 折回来 —— 又一颗死键）。
      expect(find.byType(ComposeAction), findsNothing);
      // 设置页不在这一屏上（它只是另一格）。
      expect(find.byType(SettingsScreen), findsNothing);

      await settleAndDispose(tester);
    });

    testWidgets('窄屏：欢迎页「添加第一个实例」去设置页，底部导航能回主页面',
        (tester) async {
      final r = await pump(
        tester,
        profiles: const <Profile>[],
        size: const Size(420, 900),
      );

      // 主按钮 → 设置页（另一个分支，走 go）。
      await tester.tap(find.text(zh.addFirstInstance));
      await tester.pumpAndSettle();
      expect(r.uri, Routes.settings);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(categoryTile(zh.instances), findsOneWidget);

      // 底部导航「邮件」那一格 → 回主页面（欢迎页）。
      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(zh.mailTab),
      ));
      await tester.pumpAndSettle();
      expect(r.uri, Routes.home);
      expect(find.byType(WelcomeView), findsOneWidget);

      await settleAndDispose(tester);
    });

    testWidgets('宽屏：添加实例是右栏的一栏正文，分类栏不消失、地址不变',
        (tester) async {
      final r = await pump(
        tester,
        profiles: const <Profile>[],
        size: const Size(1400, 900),
      );

      await tester.tap(find.text(zh.addFirstInstance));
      await tester.pumpAndSettle();

      // 表单在右栏里，而**这条设置页还在**：分类栏十项一个不少。
      expect(find.text(zh.addAndSignIn), findsOneWidget);
      expect(find.text(zh.addFirstInstance), findsNothing);
      expect(settingsRailItem(), findsNWidgets(10),
          reason: '设置分类栏十项必须一个不少');
      // 零实例 → 外壳侧栏收起（见上一条用例的注释）；设置页自己的分类栏
      // 与正文仍然两栏铺开，所以「不压栈、不整页盖住」这件事照样成立。
      expect(find.byType(NavSidebar), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget,
          reason: '不该再压一层「设置页」或整页表单上去');
      // 页内翻页：地址不变（不压栈、不改 URL）。
      expect(r.uri, Routes.settings);

      // 表单自己那颗返回箭头退回实例列表。
      await tester.tap(find.widgetWithText(TextButton, zh.instances));
      await tester.pumpAndSettle();
      expect(find.text(zh.addFirstInstance), findsOneWidget);
      expect(find.text(zh.addAndSignIn), findsNothing);
      await settleAndDispose(tester);
    });

    testWidgets('窄屏：两级返回 —— 表单退实例列表，再退分类列表', (tester) async {
      final r = await pump(
        tester,
        profiles: const <Profile>[],
        size: const Size(420, 900),
      );

      // 零实例的落点是主页面（欢迎页）；设置页从底部导航进。
      expect(r.uri, Routes.home);
      r.go(Routes.settings);
      await tester.pumpAndSettle();

      // 分类列表 → 实例那一页。
      await tester.tap(categoryTile(zh.instances));
      await tester.pumpAndSettle();
      expect(find.text(zh.addFirstInstance), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      // 实例页 → 表单（设置分类页，标题换成「添加实例」）。
      await tester.tap(find.text(zh.addFirstInstance));
      await tester.pumpAndSettle();
      expect(find.text(zh.addAndSignIn), findsOneWidget);
      expect(find.widgetWithText(AppBar, zh.addInstance), findsOneWidget);

      // 第一级：返回回到实例列表。
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.text(zh.addFirstInstance), findsOneWidget);
      expect(find.text(zh.addAndSignIn), findsNothing);
      expect(find.widgetWithText(AppBar, zh.instances), findsOneWidget);

      // 第二级：返回回到分类列表。
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(categoryTile(zh.appearance), findsOneWidget);
      expect(find.text(zh.addFirstInstance), findsNothing);
      await settleAndDispose(tester);
    });
  });

  group('已经有实例时，添加实例同样内嵌在设置页', () {
    testWidgets('宽屏：从实例列表点「添加实例」只换右栏，地址不变', (tester) async {
      final r = await pump(
        tester,
        profiles: const <Profile>[loggedIn],
        size: const Size(1400, 900),
      );

      r.go(Routes.settings);
      await tester.pumpAndSettle();

      await tester.tap(find.text(zh.addInstance));
      await tester.pumpAndSettle();

      expect(find.text(zh.addAndSignIn), findsOneWidget);
      expect(settingsRailItem(), findsNWidgets(10),
          reason: '分类栏必须还在 —— 这正是「不要占据整个页面」那条要求');
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(r.uri, Routes.settings);
      await settleAndDispose(tester);
    });
  });

  group('旧地址不断（都是到 /settings 的重定向）', () {
    testWidgets('/setup 落到设置页', (tester) async {
      final r = await pump(
        tester,
        profiles: const <Profile>[loggedIn],
        size: const Size(1400, 900),
      );

      r.go(Routes.setup);
      await tester.pumpAndSettle();
      expect(r.uri, Routes.settings);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await settleAndDispose(tester);
    });

    testWidgets('/settings/add-instance 落到设置页', (tester) async {
      final r = await pump(
        tester,
        profiles: const <Profile>[loggedIn],
        size: const Size(1400, 900),
      );

      r.go(Routes.addInstance);
      await tester.pumpAndSettle();
      expect(r.uri, Routes.settings);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await settleAndDispose(tester);
    });
  });
}

/// 把 `GoRouter` 收窄成这一组要用的两样（`go` / `push`），外加一个读地址的。
class GoRouterLike {
  GoRouterLike(this.router);

  final dynamic router;

  void go(String location) => router.go(location);

  void push(String location) => router.push(location);

  String get uri => router.routeInformationProvider.value.uri.toString();
}

/// `SyncController` 的真身会拉起整个调度器（时钟、平台通道）。这一组只验
/// 落点与版面，留一个空壳即可 —— 与 `login_screen_back_test.dart` 同一个写法。
class _FakeSyncController extends SyncController {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  void setActiveProfile(String? profileId) {}
}
