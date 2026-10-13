import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/features/shell/sidebar_mailboxes.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/mailbox_totals_probe.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 左侧菜单里那棵「实例 → 邮箱」子树。
///
/// 三件事要一起钉住，它们各自都会**静默地**错：
/// 1. **图标分得开合并项与真实邮箱**：缺 `account:query` 权限的实例在本地
///    没有邮箱列表，这一组会退化成一行「全部邮箱」（`accountId == 0`）。
///    它与它下面那些真实地址必须**一眼**不同 —— 缩进最左那一格正是扫视时
///    先落到的地方。
/// 2. **两种行里的标签起点一致**：实例行与它下面的邮箱行上下相邻，而
///    图标尺寸（16）与间隔（8）是写死在这一行的实现里的 —— 改错一个数就是
///    两套缩进，而「没对齐」这件事在窄侧栏里不容易立刻看出来。
/// 3. **实例行可点、箭头只切展开**：点实例名要落到 `/mail/<实例>`，点右边
///    那颗箭头**不能**顺带导航（`IconButton` 在手势竞技场里赢过外层那个
///    `HitTestBehavior.opaque` 的 `GestureDetector`，但这是「碰巧」还是
///    「设计」得有用例说话）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profile = Profile(
    id: 'p1',
    baseUrl: 'https://x/api',
    email: 'a@x.com',
    userId: 7,
  );
  const other = Profile(
    id: 'p2',
    baseUrl: 'https://y/api',
    email: 'b@y.com',
    userId: 8,
  );

  const box = MailboxAccount(accountId: 1, email: 'box@example.net', name: 'Box');
  const otherBox = MailboxAccount(accountId: 1, email: 'box@y.com', name: 'Y');

  /// 把「点一行之后落在哪儿」变成一个能断言的东西：每个路由都把那一条
  /// 地址画出来。真 `GoRouter`（而不是假的回调）是必须的 —— 这一组要验的
  /// 正是 `go` / `push` / 「什么都不做」这三者的区别，替身把它们抹平了。
  Widget page(GoRouterState state, {required bool push, bool master = true}) =>
      Scaffold(
        body: Row(
          children: <Widget>[
            SizedBox(
              width: 232,
              child: SidebarMailboxTree(
                uri: state.uri,
                push: push,
                masterExpanded: master,
              ),
            ),
            Expanded(child: Text(state.uri.toString(), key: const Key('loc'))),
          ],
        ),
      );

  /// [boxes] 为空 = 这台实例缺 `account:query` 权限，整组退化成一行合并项。
  Future<void> pump(
    WidgetTester tester, {
    required List<MailboxAccount> boxes,
    List<Profile> profiles = const <Profile>[profile],
    Map<String, List<MailboxAccount>>? boxesByProfile,
    String initial = '/mail/p1',
    bool push = false,
    Set<String> collapsed = const <String>{},
    bool masterExpanded = true,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      if (collapsed.isNotEmpty)
        'cm_sidebar_collapsed_instances': collapsed.toList(),
    });
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    final router = GoRouter(
      initialLocation: initial,
      routes: <RouteBase>[
        GoRoute(
          path: '/starred',
          builder: (c, s) => page(s, push: push, master: masterExpanded),
        ),
        GoRoute(
          path: '/mail/:profileId',
          builder: (c, s) => page(s, push: push, master: masterExpanded),
          routes: <RouteBase>[
            GoRoute(
              path: ':emailId',
              builder: (c, s) => page(s, push: push, master: masterExpanded),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(ProviderScope(
      // 不写 `<Override>[]`：`Override` 在 riverpod 3 里没有对外导出
      // （见 `mail_list_deactivate_test.dart` 里同一句注释）。
      overrides: [
        // 展开态住在 prefs 里，所以这一条链必须真的通到 `PrefsStore`。
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        profilesProvider.overrideWith((ref) => Stream.value(profiles)),
        // 直给这一份 Map，绕开「去库里查邮箱表」那一步。
        allMailboxesByProfileProvider.overrideWithValue(
          boxesByProfile ?? <String, List<MailboxAccount>>{'p1': boxes},
        ),
        // 未读数走库查询，这里一律 0（= 那一格不渲染）：断言只关心图标、
        // 几何与落点。
        mailboxUnreadProvider.overrideWith((ref, key) => 0),
        // 实例行的分子（`profileUnreadProvider`）与两处总数同理：它们是
        // **drift 流**，而内存库的 `watch()` 在 widget 树拆掉之后还留着一个
        // drift 自己的定时器，`flutter_test` 会判「树都拆了还有 Timer 没结束」。
        // 「未读 / 总数」的文案另有 `mailbox_counts_test` 逐分支钉，
        // 这一组要验的是行本身。
        unreadByProfileProvider
            .overrideWith((ref) => Stream.value(const <String, int>{})),
        profileMailboxTotalsProvider.overrideWith(
          (ref, profileId) => Stream.value(const <String, MailboxTotal>{}),
        ),
        // 实例行展开时会触发总数探测，而它第一件事就是问联网状态 ——
        // 真身 `onlineProvider` 要过 `connectivity_plus` 的平台通道，测试里
        // 没有那个通道，于是这条异步调用会**在用例结束之后**才失败。
        // 给一个固定的「在线」：探不探得动是 `mailbox_totals_probe_*` 那两个
        // 文件的事，这一组要验的是行本身。
        onlineProvider.overrideWith((ref) => Stream<bool>.value(true)),
        // 这一组里没有真 runtime，真探测会立刻在 `registry.peek` 那一句
        // 返回 null —— 但那条路仍会建一遍 `EmailRepository`（拖进 registry、
        // 能力仓库）。换成空实现，把「展开这一行」与「探测」彻底隔开。
        mailboxTotalsProbeProvider.overrideWithValue(_NoopProbe()),
        // 点一行会 `setActiveProfile` —— 真身要拉起整个调度器（时钟、平台
        // 通道），而这里要验的是**地址**。
        syncControllerProvider.overrideWith(_FakeSyncController.new),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ));
    await tester.pumpAndSettle();
  }

  String location(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('loc'))).data!;

  testWidgets('具体邮箱一行：邮箱图标 + 它的地址', (tester) async {
    await pump(tester, boxes: const <MailboxAccount>[box]);

    expect(find.byIcon(Icons.mail_outline), findsOneWidget);
    expect(find.text('box@example.net'), findsOneWidget);
    expect(find.byIcon(Icons.all_inbox), findsNothing);
    // 那颗色点必须真的没了 —— 否则就是新旧两套一起画。
    expect(
      find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle),
      findsNothing,
    );
  });

  testWidgets('缺 account:query 权限那一行：合并项用另一种图标', (tester) async {
    await pump(tester, boxes: const <MailboxAccount>[]);

    expect(find.byIcon(Icons.all_inbox), findsOneWidget);
    expect(find.byIcon(Icons.mail_outline), findsNothing);
    expect(find.text('全部邮箱'), findsOneWidget);
  });

  testWidgets('实例行用的又是另一种图标', (tester) async {
    await pump(tester, boxes: const <MailboxAccount>[box]);

    // 三级各一个图标：实例 `dns`、邮箱 `mail_outline`、合并项 `all_inbox`。
    expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    expect(find.text('a@x.com'), findsOneWidget);
  });

  /// 三种行在同一组里上下相邻，标签必须从同一个 x 开始。
  testWidgets('实例行 / 合并项 / 具体邮箱的标签左边距相同', (tester) async {
    await pump(tester, boxes: const <MailboxAccount>[box]);
    final mailboxLeft = tester.getTopLeft(find.text('box@example.net')).dx;
    final instanceLeft = tester.getTopLeft(find.text('a@x.com')).dx;

    await pump(tester, boxes: const <MailboxAccount>[]);

    expect(tester.getTopLeft(find.text('全部邮箱')).dx, mailboxLeft);
    expect(instanceLeft, mailboxLeft);
  });

  group('点实例行', () {
    testWidgets('落到 `/mail/<实例>`，不带 account', (tester) async {
      await pump(tester, boxes: const <MailboxAccount>[box], initial: '/starred');

      await tester.tap(find.text('a@x.com'));
      await tester.pumpAndSettle();

      // `account` 一个字节都不许有：写出来就成了「钉在某个邮箱上」，
      // 那是子行那一件事（见 `pinnedMailboxOf`）。
      expect(location(tester), '/mail/p1');
    });

    testWidgets('已经在上面（根）时什么都不做', (tester) async {
      await pump(tester, boxes: const <MailboxAccount>[box]);

      await tester.tap(find.text('a@x.com'));
      await tester.pumpAndSettle();

      expect(location(tester), '/mail/p1');
    });

    /// 窄屏那一形态：`push: true` 时再点一次**不许**叠出第二张列表页
    /// （叠上去的表现是「点了没反应」，返回一次还在原地）。
    testWidgets('窄屏（push）已经在根上时也不叠页', (tester) async {
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        push: true,
      );

      await tester.tap(find.text('a@x.com'));
      await tester.pumpAndSettle();

      expect(location(tester), '/mail/p1');
      // 真的只留了一层：返回箭头不该出现。
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('停在详情页时点实例行 = 退回这一屏的列表', (tester) async {
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        initial: '/mail/p1/7',
        push: true,
      );
      expect(location(tester), '/mail/p1/7');

      await tester.tap(find.text('a@x.com'));
      await tester.pumpAndSettle();

      expect(location(tester), '/mail/p1');
    });
  });

  group('展开箭头', () {
    testWidgets('点箭头只切换展开，不导航', (tester) async {
      await pump(tester, boxes: const <MailboxAccount>[box], initial: '/starred');
      expect(find.text('box@example.net'), findsOneWidget);

      await tester.tap(find.byTooltip('展开或收起这个实例的邮箱'));
      await tester.pumpAndSettle();

      expect(location(tester), '/starred');
      expect(find.text('box@example.net'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
    });

    testWidgets('收起的实例默认不展开子行（从 prefs 读回来）', (tester) async {
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        initial: '/starred',
        collapsed: <String>{'p1'},
      );

      expect(find.text('a@x.com'), findsOneWidget);
      expect(find.text('box@example.net'), findsNothing);
    });

    /// `forced`：地址正落在这台实例上时，那一行本身必须是看得见的 ——
    /// 否则从通知深链回到某个邮箱，侧栏里高亮的那一行根本不存在。
    testWidgets('地址落在这台上时，单独收起也不算数', (tester) async {
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        collapsed: <String>{'p1'},
      );

      expect(find.text('box@example.net'), findsOneWidget);
    });

    /// `forced` 只救**被落中的那一台**。这是与改动前相比一次**可见的行为
    /// 变化**：原来 `master` 是整棵树的开关，`master=false` 且钉住某个邮箱
    /// 时所有实例的子行都会展开。现在只有被落中那一台展开 —— 更贴合那条
    /// 理由的本意（「那一行看不见」说的就是这一台）。
    testWidgets('一括关掉 + 落在这台上：只展开这一台，别的台仍收起', (tester) async {
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        profiles: const <Profile>[profile, other],
        boxesByProfile: <String, List<MailboxAccount>>{
          'p1': const <MailboxAccount>[box],
          'p2': const <MailboxAccount>[otherBox],
        },
        initial: '/mail/p1',
        masterExpanded: false,
      );

      expect(find.text('box@example.net'), findsOneWidget);
      expect(find.text('box@y.com'), findsNothing);
    });

    /// 窄屏那一形态传的是 `masterExpanded: true`（那一屏没有那颗一括箭头）：
    /// 用户上次在宽屏上把整组收起来，切到窄屏不该发现「某个邮箱的收件箱」
    /// 这条路径根本走不通。
    testWidgets('一括关掉时整棵子树收起（宽屏）', (tester) async {
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        initial: '/starred',
        masterExpanded: false,
      );

      expect(find.text('a@x.com'), findsOneWidget);
      expect(find.text('box@example.net'), findsNothing);
    });
  });
}

/// `SyncController` 的真身要拉起整个调度器（时钟、平台通道、钥匙串）。
/// 这一组验的是**地址**，所以只留一个空壳。
class _FakeSyncController extends SyncController {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  void setActiveProfile(String? profileId) {}
}

/// 什么都不做的探测器：这一组用例验的是「行长什么样、点了去哪儿」，
/// 探测另有 `mailbox_totals_probe_test.dart`（请求形状）与
/// `mailbox_totals_probe_strategy_test.dart`（TTL / 在飞 / 并发）两份。
class _NoopProbe implements MailboxTotalsProbe {
  @override
  Ref get ref => throw UnimplementedError('这一组用例不碰探测器的内部');

  @override
  Future<void> ensure({
    required Profile profile,
    required List<MailboxFilter> boxes,
  }) async {}
}
