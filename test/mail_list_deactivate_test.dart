import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/compose/drafts_screen.dart';
import 'package:mail_app/features/mail_list/mail_list_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「从列表页走进草稿箱」那一跳不许在 build 阶段改 provider。
///
/// 用户报的是真机上的一条报错：
///
/// ```
/// Tried to modify a provider while the widget tree was building.
/// ```
///
/// 成因不在草稿箱那一页（`DraftsScreen` 自己一个 provider 都不在 build 里
/// 改），而在**被它替下去的列表页**：`/drafts` 与 `/mail/<节点>` 是
/// **同一支 Navigator 里的两个根**（`router.dart` 的 `Routes.drafts` 注释
/// 里写了为什么必须是同一支），所以 `go('/drafts')` 换的是这一支的页面栈
/// —— 旧页被摘下来这件事发生在**同一帧的构建过程中**。而列表页原先在
/// `deactivate` 里同步地改了两个 provider：
///
/// - `composePreselectProvider`：收回「写邮件从哪个邮箱发」那份说法；
/// - 已发送那一屏还会把发件方向的轮询关掉。
///
/// 那一刻树根上的 `UncontrolledProviderScope` 正在 build，riverpod 的
/// `debugCanModifyProviders` 钩子（它只做一件 `setState(() {})`）当场抛出
/// 上面那段文字。
///
/// ## 为什么必须用真的 `StatefulShellRoute`
///
/// 换一页**必须是「同一支分支里换根」**这种形状。若把 `/drafts` 挂成另一支
/// 分支，切过去只是 `IndexedStack` 换了个 offstage 标记、元素原地不动，
/// `deactivate` 根本不会跑 —— 那样这条用例会**在没修的时候也是绿的**，
/// 钉不住任何东西。所以下面这一支里挂着两个根路由，与 `router.dart` 里
/// 邮件那一支的形状一致。
///
/// 两个变体覆盖「发布过预选值」的两条来路（只有真的发布过值，收回时才
/// 会真的通知一次 —— 那份通知正是踩到断言的那一下）：
/// - **聚合**（`profileId == null`）：勾选集合里只有一个邮箱时预选它；
/// - **钉住某个邮箱**（左侧菜单下级菜单的落点）：直接预选它。
///
/// 一整条外壳（`AppShell`）不在场：这条路径与侧栏无关，而带上它就得把
/// 未读/草稿/发件箱那几条 drift 流全喂上，用例会变成在测外壳。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profile = Profile(
    id: 'p1',
    baseUrl: 'https://x/api',
    email: 'a@x.com',
    userId: 7,
  );

  Future<void> run(
    WidgetTester tester, {
    required String name,
    required Widget Function() listPage,
  }) async {
    // 内存库：`databaseProvider` 那一链（列表控制器、同步调度器）都要它。
    // **不能省**：换成「一个 provider 都不建」的做法时，`databaseProvider`
    // 会去读没被 override 的 `bootstrapProvider`，整棵树当场落进错误态。
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    final router = GoRouter(
      initialLocation: '/mail/all',
      routes: <RouteBase>[
        StatefulShellRoute.indexedStack(
          // 只验证「换根」这一件事，外壳那层不参与。
          builder: (context, state, shell) => shell,
          branches: <StatefulShellBranch>[
            StatefulShellBranch(
              initialLocation: '/mail/all',
              routes: <RouteBase>[
                GoRoute(
                  // 字面路径而不是 `/mail/:profileId`：分支的
                  // `initialLocation` 不接受带参数的路由（go_router 断言）。
                  path: '/mail/all',
                  builder: (context, state) => listPage(),
                ),
                GoRoute(
                  path: '/drafts',
                  builder: (context, state) => const DraftsScreen(),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(ProviderScope(
      // 不写 `<Override>[]`：`Override` 在 riverpod 3 里是 `sealed` 且没有
      // 对外导出（与 `mailbox_filter_overlay_test.dart` 同一句注释）。
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        // 只有一条实例。列表那几条数据源全部换成固定流：断言的是生命周期，
        // 不是数据。
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[profile]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(const <MailboxAccount>[]),
        ),
        mailListProvider.overrideWith(
          (ref, query) => Stream.value(const <MailRow>[]),
        ),
        unsyncedPlaceholderProvider.overrideWith(
          (ref, query) => Stream<int?>.value(null),
        ),
        draftsProvider.overrideWith(
          (ref, profileId) => Stream.value(const <DbDraft>[]),
        ),
        // 列表头上那颗同步按钮要它（`SyncStatusButton`）。
        syncOverviewProvider.overrideWith(
          (ref) => Stream.value(const <SyncOverview>[]),
        ),
        // `SyncController.build` 会 listen 它，而真身第一件事就是去问
        // `connectivity_plus` 的平台通道 —— 测试里没有那个通道，
        // 于是这条异步调用会**在用例结束之后**才失败（见
        // `desktop_sync_keepalive_test.dart` 里同一句注释）。
        onlineProvider.overrideWith((ref) => Stream.value(true)),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('收件箱'), findsOneWidget, reason: '前提：先在列表页上');

    // 这一跳就是用户点的「草稿箱」。
    router.go('/drafts');
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: '$name：换页那一帧里摘掉列表页，不许在 build 阶段改 provider',
    );
    // 列表页真的被摘下来了 —— 否则上面那条断言是空的（`deactivate` 没跑
    // 就谈不上「在 `deactivate` 里改 provider」）。
    expect(find.text('收件箱'), findsNothing);
    expect(find.text('草稿箱'), findsOneWidget);

    // 把整棵树拆掉并**把时钟往前推一帧**：drift 的流在取消订阅时会排一个
    // 「零延时」定时器去关查询（`StreamQueryStore.markAsClosed`），零延时的
    // 定时器要时钟动了才跑得完（不带时长的 `pump()` 不推时钟），留到用例
    // 结束就会报一句与本题毫无关系的「A Timer is still pending」。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('聚合列表 → 草稿箱：预选收回时不在 build 阶段改 provider',
      (tester) async {
    // 邮箱列表为空 → 勾选集合退化成「这一条实例的全部邮箱」这一项，
    // 于是 `composePreselectOf` 真的会发布一个非 null 的预选值。
    await run(
      tester,
      name: '聚合',
      listPage: () => const MailListScreen(folder: MailFolder.receive),
    );
  });

  testWidgets('钉住某个邮箱的列表 → 草稿箱：同样不许在 build 阶段改 provider',
      (tester) async {
    await run(
      tester,
      name: '钉住',
      listPage: () =>
          const MailListScreen(profileId: 'p1', accountId: 1),
    );
  });
}
