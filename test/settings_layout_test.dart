import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/settings/sections/push_section.dart';
import 'package:mail_app/features/settings/settings_screen.dart';
import 'package:mail_app/features/shell/nav_sidebar.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置页的两副形态。三个层面各自都会静默地错，所以要分开钉：
///
/// 1. **分类本身**：九个、顺序、文案。分类栏只有 [Breakpoints.settingsRailWidth]
///    宽，名字长一个字就会被省略号吃掉（推送那个短名字存在的理由）。
/// 2. **窄屏**：一进来是**分类列表**而不是某个分类的正文 —— 漏了这一层，
///    手机上打开设置会直接落在「实例」里，用户找不到其余九个。
/// 3. **宽屏**：分类栏常驻 + 右栏跟着选；切换**不改地址、不压栈**（所以
///    右栏里没敲完的草稿必须还在）。这一条只有把窗口拖宽才看得见。
///
/// 另有一条**路由**的：那三条旧地址（`/settings/ai` / `/settings/push` /
/// `/settings/diagnostics`）曾经是三个整页，现在必须仍然存在且是重定向 ——
/// 它们可能出现在用户的浏览历史 / 通知 / 旧文档里，落到 404 会让人以为坏了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 单例注册表跨用例存活。这一组里有几条会注册假扩展，不清会漏到别的用例里
  // —— 表现是「窄屏分类列表莫名多一行」，跟出错的那条用例毫无关系。
  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  final zh = lookupAppLocalizations(const Locale('zh'));

  group('九个分类', () {
    test('数量与顺序就是分类栏里的顺序', () {
      expect(
        SettingsCategory.values.map((c) => c.label(zh)).toList(),
        const <String>[
          '实例', '邮箱', '轮询', '外观', '写邮件', 'AI', '推送', '诊断', '关于',
        ],
      );
    });

    test('每个分类都有一对图标，选中态与未选态不是同一颗', () {
      for (final category in SettingsCategory.values) {
        expect(category.icon, isNotNull, reason: '$category');
        expect(
          category.selectedIcon,
          isNot(category.icon),
          reason: '$category 的选中态与未选态画的是同一颗图标 —— 分类栏靠'
              '图标变化 + 底色一起说「你在这儿」，两者指同一个字形等于少一半信号',
        );
      }
    });

    test('分类栏里的「推送」用短名字', () {
      // 长名字是 `pushTitle`（「后台推送（FCM）」），塞进 200 宽的分类栏会挤爆。
      // 分类**页内**的标题仍然用长的（`_SettingsScreenState._titleOf`）。
      expect(SettingsCategory.push.label(zh), '推送');
      expect(zh.pushTitle, isNot('推送'));
    });

    test('「邮箱」紧跟「实例」，且与侧栏邮箱行用同一颗字形', () {
      // 位置是用户拍的板（规格 §2.1）：「实例是一台服务器，邮箱是它下面的
      // 一个地址」，两者挨着最顺。而图标与 `SidebarMailboxRow` 的默认 icon
      // 一致，视觉上直接指认「这就是邮箱」。
      expect(SettingsCategory.values[1], SettingsCategory.mailboxes);
      expect(SettingsCategory.mailboxes.icon, Icons.alternate_email_outlined);
      expect(SettingsCategory.mailboxes.selectedIcon, Icons.alternate_email);
      // 分类栏里的短名字复用已有的 `mailbox`（「邮箱」），分类**页内**的标题
      // 用新的长名字 —— 与「推送」那条同一个理由。
      expect(SettingsCategory.mailboxes.label(zh), '邮箱');
      expect(zh.mailboxTitle, isNot('邮箱'));
    });
  });

  /// 旧深链的落点。**不 pump 整棵树**（那要喂上外壳与同步那几条流），
  /// 只把路由表翻出来看这三条自己怎么说 —— 这里要钉的是「它们是重定向」，
  /// 那是路由表的性质，跑一遍跳转只是同一条事实的另一种写法。
  test('三个旧地址都是重定向到 /settings', () {
    final container = ProviderContainer(overrides: [
      profilesProvider.overrideWith(
        (ref) => Stream.value(const <Profile>[]),
      ),
    ]);
    // **不要**自己 `router.dispose()`：`routerProvider` 已经 `ref.onDispose`
    // 它了，再撤一次会撞上 `A GoRouteInformationProvider was used after being
    // disposed` —— 那条断言看起来像「路由坏了」，其实是这里多关了一下。
    addTearDown(container.dispose);
    final router = container.read(routerProvider);

    /// 深度优先找出 `/settings` 那一条 GoRoute。
    GoRoute? find(String path, List<RouteBase> routes) {
      for (final route in routes) {
        if (route is GoRoute) {
          if (route.path == path) return route;
          final hit = find(path, route.routes);
          if (hit != null) return hit;
        } else if (route is ShellRouteBase) {
          final hit = find(path, route.routes);
          if (hit != null) return hit;
        }
      }
      return null;
    }

    final settings = find(Routes.settings, router.configuration.routes);
    expect(settings, isNotNull, reason: '设置这一支本身不见了');

    for (final legacy in <String>['ai', 'push', 'diagnostics']) {
      final route = settings!.routes.whereType<GoRoute>().firstWhere(
            (r) => r.path == legacy,
            orElse: () => throw StateError('/settings/$legacy 这条旧地址没了'),
          );
      expect(
        route.redirect,
        isNotNull,
        reason: '/settings/$legacy 不再是重定向 —— 它现在应该只是一段'
            '「退到 /settings」的兼容路径',
      );
      // 有重定向就不该再有页面：两条同时给的话，go_router 先跑重定向，
      // `builder` 永远不会执行 —— 留着的那个 builder 是一段没人知道
      // 已经死掉的代码。
      expect(
        route.builder,
        isNull,
        reason: '/settings/$legacy 既重定向又挂着 builder',
      );
      final target = route.redirect!(
        _fakeContext,
        GoRouterState(
          router.configuration,
          uri: Uri.parse('/settings/$legacy'),
          matchedLocation: '/settings/$legacy',
          fullPath: '/settings/$legacy',
          pathParameters: const <String, String>{},
          pageKey: const ValueKey<String>('k'),
        ),
      );
      expect(target, Routes.settings, reason: '/settings/$legacy');
    }
  });

  // ── 窄屏（测试环境默认 800×600，< 1024）────────────────────────────

  Future<void> pumpNarrow(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
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

  testWidgets('窄屏：先是一张分类列表，点一个才进那一页', (tester) async {
    await pumpNarrow(tester);

    // 一进来是**分类列表**：标题「设置」+ 九个入口，而不是某个分类的正文。
    expect(find.text('设置'), findsOneWidget);
    for (final label in <String>[
      '实例', '邮箱', '轮询', '外观', '写邮件', 'AI', '推送', '诊断', '关于',
    ]) {
      expect(find.widgetWithText(ListTile, label), findsOneWidget, reason: label);
    }
    // 那九个是**列表**，不是分类栏 —— 分类栏的项是 `NavSidebarItem`。
    expect(find.byType(NavSidebarItem), findsNothing);
    // 也没进任何分类页：没有返回箭头。
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    // 点「外观」→ 进外观那一页。
    await tester.tap(find.widgetWithText(ListTile, '外观'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, '主题'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    // 分类列表已经让位给正文了（标题里那个「外观」是 AppBar，不是列表行）。
    expect(find.widgetWithText(ListTile, '实例'), findsNothing);

    // 返回箭头回分类列表。
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '实例'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '主题'), findsNothing);

    // **系统返回键**是同一个动作（安卓返回键 / iOS 边缘滑动）。
    //
    // 它必须自己接住：设置页是这一支的根，不接的话这一步会把用户整个推出
    // 设置页（在真机上就是「点进外观，按返回，回到了收件箱」）。
    //
    // 写法照抄 `compose_exit_paths_test.dart`：**不能直接 await
    // `handlePopRoute()`** —— 那个 future 要等整套弹出流程跑完，而流程靠帧
    // 推进，直接 await 会把用例钉死在那儿。
    await tester.tap(find.widgetWithText(ListTile, '外观'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '主题'), findsOneWidget);

    final popped = tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(await popped, isTrue, reason: '返回手势应当被设置页接住');
    expect(find.widgetWithText(ListTile, '实例'), findsOneWidget,
        reason: '返回键该退回分类列表，而不是把整个设置页弹掉');
  });

  // ── 宽屏（1400×900，>= 1024）──────────────────────────────────────

  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 钥匙串换成内存 mock：AI 那一块会去读「有没有 Key」。
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[]),
        ),
        aiServiceProvider.overrideWithValue(_FakeAiService()),
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

  testWidgets('宽屏：分类栏常驻，右栏是选中分类的正文（内嵌，不整页推入）',
      (tester) async {
    await pumpWide(tester);

    /// 分类栏里的第 n 项。**必须收窄到 `NavSidebarItem` 里面**：分类名同时
    /// 出现在三处（分类栏那一项、右栏顶部的 `PaneHeader`、有的正文里还会再来
    /// 一次），裸 `find.text('实例')` 会找到两个。
    Finder railItem(String label) => find.descendant(
          of: find.byType(NavSidebarItem),
          matching: find.text(label),
        );

    // 分类栏九个项常驻，且**没有**窄屏那张分类列表。
    for (final label in <String>['实例', '邮箱', '轮询', '外观', '写邮件', 'AI', '推送', '诊断', '关于']) {
      expect(railItem(label), findsOneWidget, reason: '分类栏 $label');
    }
    expect(find.byType(NavSidebarItem), findsNWidgets(9));
    expect(find.widgetWithText(ListTile, '实例'), findsNothing);

    // 默认选中「实例」：右栏是实例正文（空实例时的入口），
    // **不是**一片空白 —— `_built` 若忘了把初值放进去就是那样。
    expect(find.text(zh.addFirstInstance), findsOneWidget);

    // 「推送」此刻**还没被构造**：`PushSection` 一构造就读钥匙串、打中转端
    // 的 `/devices`、还可能自动登记一次设备。只想改个主题的用户不该因此被
    // 发一轮推送请求 —— 这条钉的就是那个「按需构造」的约定。
    expect(find.byType(PushSection), findsNothing);

    // 切到「AI」：右栏换成 AI 正文，同一屏内完成。
    await tester.tap(railItem('AI'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ai-privacy')), findsOneWidget);
    // 没整页推入：分类栏与它的「设置」表头都还在，窄屏那套返回箭头没有。
    expect(find.text('设置'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    // 看过 AI 也不会顺带把推送那一段建出来。
    expect(find.byType(PushSection), findsNothing);

    // 在地址栏里敲一半，别提交。
    await tester.enterText(
      find.byKey(const ValueKey('ai-base-url')),
      'https://half-typed.example',
    );
    await tester.pumpAndSettle();

    // 切走再切回来 —— 草稿必须还在（`IndexedStack` 把构造过的分类留着）。
    await tester.tap(railItem('外观'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '主题'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-base-url')), findsNothing);

    await tester.tap(railItem('AI'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-base-url')))
          .controller!
          .text,
      'https://half-typed.example',
    );
  });

  // ── 扩展分类（`AppExtension.settingsSections`）────────────────────

  /// 一个只往设置页加一栏的假扩展。
  ///
  /// 图标刻意选两颗**不与内置九栏重复**的字形：重复的话「扩展那栏排在第几」
  /// 这条断言会退化成「某个内置图标出现了两次」，而它照样通过。
  group('扩展分类', () {
    testWidgets('登记之后窄屏多一行，且排在「关于」之前', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _SectionExt(),
      ]);
      await pumpNarrow(tester);

      // 内置九栏原样都在 —— 扩展是**追加**，不是替换。
      for (final label in <String>[
        '实例', '邮箱', '轮询', '外观', '写邮件', 'AI', '推送', '诊断', '关于',
      ]) {
        expect(find.widgetWithText(ListTile, label), findsOneWidget, reason: label);
      }
      expect(find.widgetWithText(ListTile, '免打扰'), findsOneWidget);

      // 顺序：「诊断」→ 扩展 → 「关于」。「关于」按惯例永远收尾。
      final labels = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title! as Text).data)
          .toList();
      expect(labels, <String>[
        '实例', '邮箱', '轮询', '外观', '写邮件', 'AI', '推送', '诊断', '免打扰', '关于',
      ]);
    });

    testWidgets('点进去渲染扩展自己的正文（宿主不套 Scaffold 之外的东西）',
        (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _SectionExt(),
      ]);
      await pumpNarrow(tester);

      await tester.tap(find.widgetWithText(ListTile, '免打扰'));
      await tester.pumpAndSettle();

      expect(find.text('扩展正文'), findsOneWidget);
      // 标题是扩展自己给的（核心的 ARB 里没有它的词条）。
      expect(find.text('免打扰'), findsWidgets);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget,
          reason: '扩展分类页与内置的一样有返回箭头');
    });

    testWidgets('宽屏：扩展进分类栏，且与内置一样按需构造', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _SectionExt(),
      ]);
      await pumpWide(tester);

      Finder railItem(String label) => find.descendant(
            of: find.byType(NavSidebarItem),
            matching: find.text(label),
          );
      for (final label in <String>[
        '实例', '邮箱', '轮询', '外观', '写邮件', 'AI', '推送', '诊断', '免打扰', '关于',
      ]) {
        expect(railItem(label), findsOneWidget, reason: '分类栏 $label');
      }
      expect(find.byType(NavSidebarItem), findsNWidgets(10));

      // **没点进去之前不构造它的正文** —— 与 `PushSection` 那条同一条规矩：
      // 扩展正文多半要读盘或者打接口，「打开设置页」不该等于「把每个扩展跑一遍」。
      expect(find.text('扩展正文'), findsNothing);

      await tester.tap(railItem('免打扰'));
      await tester.pumpAndSettle();
      expect(find.text('扩展正文'), findsOneWidget);
      // 内嵌，不整页推入。
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.text('设置'), findsOneWidget);
    });

    /// 空注册表时**一条都不多** —— 公开版（以及没装扩展的商业版）看到的
    /// 设置页与从前逐像素相同。
    testWidgets('没有扩展时不多任何一栏', (tester) async {
      await pumpNarrow(tester);
      expect(find.byType(ListTile), findsNWidgets(9));
    });
  });

  /// 两条**路由出口**各自落在哪一层。
  ///
  /// 这一条与界面无关，但它是「从扩展页面点进核心邮件页会不会红屏」的地基：
  ///
  /// - `AppExtension.routes()` 挂在**根路由表的尾部**（壳之外，与 `/compose`
  ///   同形）。从那种页面上往壳内地址压栈，go_router 会在根 Navigator 上再挂
  ///   一个同 pageKey 的状态壳，Navigator 的重复 pageKey 断言当场把整屏打成
  ///   红框（成因见 `router.dart` 里 `Routes.outbox` 那段注释）；
  /// - `AppExtension.mailBranchRoutes()` 挂在**邮件那一支里**（壳内），
  ///   与 `/mail/<节点>` 共用同一个 Navigator，压栈才是压栈。
  ///
  /// 两条出口各自落在哪一层，就是在界面上完全看不出来的那种事：接错了不会
  /// 报错，只会在用户点开某封信时炸。所以这里把路由表翻出来直接看。
  group('扩展路由挂在哪一层', () {
    ProviderContainer container() {
      final c = ProviderContainer(overrides: [
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[]),
        ),
      ]);
      // **不要**自己 dispose router：`routerProvider` 已经 `ref.onDispose`
      // 它了（见上面「三个旧地址都是重定向」那条的注释）。
      addTearDown(c.dispose);
      return c;
    }

    /// 深度优先找一条 `path` 相同的 `GoRoute`（会钻进子路由与壳）。
    RouteBase? findPath(List<RouteBase> routes, String path) {
      for (final route in routes) {
        if (route is GoRoute) {
          if (route.path == path) return route;
          final hit = findPath(route.routes, path);
          if (hit != null) return hit;
        } else if (route is ShellRouteBase) {
          final hit = findPath(route.routes, path);
          if (hit != null) return hit;
        }
      }
      return null;
    }

    test('壳内那条真的进分支，顶层那条留在壳外', () {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[const _RouteExt()]);
      final router = container().read(routerProvider);
      final roots = router.configuration.routes;

      final shell = roots.whereType<StatefulShellRoute>().single;
      final mailBranch = shell.branches[0].routes;

      expect(
        findPath(mailBranch, _RouteExt.branchPath),
        isNotNull,
        reason: 'mailBranchRoutes() 没接进邮件那一支 —— 壳内的页面与 '
            '/mail/<节点> 共用同一个 Navigator，压栈才成立',
      );
      expect(
        findPath(<RouteBase>[
          for (final r in roots)
            if (r is! StatefulShellRoute) r,
          for (final branch in shell.branches.skip(1)) ...branch.routes,
        ], _RouteExt.branchPath),
        isNull,
        reason: '同一条路由不许在别处再挂一份 —— 根 Navigator 上多一个壳就是'
            '那次红屏的成因',
      );

      expect(
        findPath(roots, _RouteExt.topPath),
        isNotNull,
        reason: 'routes() 那一条要挂在根部（与 /compose 同形）',
      );
      for (final branch in shell.branches) {
        expect(
          findPath(branch.routes, _RouteExt.topPath),
          isNull,
          reason: '顶层那条不该混进分支里 —— 两条出口的形态不同，混了就是接错',
        );
      }

      // 扩展排在核心之后：`/mail/:profileId`（聚合与实例共用这一条）本来就
      // 在邮件那一支里，扩展不能抢在它前面（否则它可以把核心路径吃掉）。
      final mail = mailBranch.indexWhere(
        (r) => r is GoRoute && r.path == '${Routes.mail}/:profileId',
      );
      final ext = mailBranch.indexWhere(
        (r) => r is GoRoute && r.path == _RouteExt.branchPath,
      );
      expect(mail, greaterThanOrEqualTo(0), reason: '核心的列表路由不见了');
      expect(ext, greaterThan(mail), reason: '扩展要排在核心路由之后');
    });
  });
}

/// 两条**路由出口**各自落在哪一层（上面那组用例用它）。
///
/// 它**不返回任何页面**：那两条路由会不会被真的访问，是商业版自己的事；
/// 这里只借用它把两条出口各占一个地址。
class _RouteExt extends AppExtension {
  const _RouteExt();

  static const String topPath = '/test-routes/top';
  static const String branchPath = '/test-routes/branch';

  @override
  String get id => 'test.routes';

  @override
  List<RouteBase> routes() => <RouteBase>[
        GoRoute(
          path: topPath,
          builder: (context, state) => const SizedBox.shrink(),
        ),
      ];

  @override
  List<RouteBase> mailBranchRoutes() => <RouteBase>[
        GoRoute(
          path: branchPath,
          builder: (context, state) => const SizedBox.shrink(),
        ),
      ];
}

/// 一个只往设置页加一栏的假扩展（文案硬编码，与商业版同一条路：扩展自带
/// 文案，核心的 ARB 里不加词条）。
class _SectionExt extends AppExtension {
  const _SectionExt();

  @override
  String get id => 'test.dnd';

  @override
  List<SettingsSection> settingsSections(BuildContext context) =>
      <SettingsSection>[
        SettingsSection(
          id: 'test.dnd.rules',
          icon: Icons.do_not_disturb_on_outlined,
          selectedIcon: Icons.do_not_disturb_on,
          title: '免打扰',
          body: (context) => const _ExtensionBody(),
        ),
      ];
}

class _ExtensionBody extends StatelessWidget {
  const _ExtensionBody();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('扩展正文'));
}

/// 那三条重定向的闭包不看 `context`（返回值是常量），随便给一个即可 ——
/// 这里直接用一个取不到的假 context：它一旦被读就会抛，正好把「你以为
/// 重定向需要 context」这种改法当场打红。
BuildContext get _fakeContext => _NoContext();

class _NoContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('重定向不该碰 context');
}

/// 只回答 `usedToday`，其余一概不实现 —— 这组用例不点「拉取 / 测试连接」。
class _FakeAiService implements AiService {
  @override
  int get usedToday => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('这一组测试不用 ${invocation.memberName}');
}
