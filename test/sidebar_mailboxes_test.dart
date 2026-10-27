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
import 'package:mail_app/features/shell/nav_sidebar.dart';
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
/// 2. **实例行与邮箱行分得开**：层级先靠缩进说 —— 实例行（组头）的标签
///    比它下面的邮箱行靠左 18，而组内各行（邮箱 / 合并项）彼此对齐。
///    以前这两种行从同一个 x 开始，只靠字重区分，扫视时几乎分不出来。
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
    int Function(String profileId, int accountId)? mailboxUnreadOf,
    int? Function(String profileId, int accountId)? mailboxTotalOf,
    int Function(String profileId)? instanceUnreadOf,
    int? Function(String profileId)? instanceTotalOf,
    MailboxTotalsProbe? probe,
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
        // 未读与总数：默认 0 / 未知（= 右侧什么都不画），断言只关心图标、
        // 几何与落点；需要数字的用例用下面那几个回调精确给。
        //
        // 直接覆写这四个 family 而不是它们底下的 drift 流：内存库的
        // `watch()` 在 widget 树拆掉之后还留着一个 drift 自己的定时器，
        // `flutter_test` 会判「树都拆了还有 Timer 没结束」。
        mailboxUnreadProvider.overrideWith(
          (ref, key) => mailboxUnreadOf?.call(key.profileId, key.accountId) ?? 0,
        ),
        mailboxTotalProvider.overrideWith(
          (ref, key) => mailboxTotalOf?.call(key.profileId, key.accountId),
        ),
        profileUnreadProvider.overrideWith(
          (ref, profileId) => instanceUnreadOf?.call(profileId) ?? 0,
        ),
        instanceTotalProvider.overrideWith(
          (ref, profileId) => instanceTotalOf?.call(profileId),
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
        mailboxTotalsProbeProvider.overrideWithValue(probe ?? _NoopProbe()),
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

  /// 邮箱行那一串地址里，**用户名加粗、`@域名` 常规**。
  ///
  /// 这条规则只在样式上可见（截图里 12px 的两档字重差点看不出来），所以
  /// 直接钉 span 的边界：`box` 单独一段挂 w700，`@example.net` 不挂样式、
  /// 继承外层那档 w400。切错位置（比如把 `@` 也切进用户名）时这条立刻红。
  testWidgets('邮箱行的用户名加粗，@域名常规', (tester) async {
    await pump(tester, boxes: const <MailboxAccount>[box]);

    final label = tester.widget<Text>(find.text('box@example.net'));
    expect(label.style?.fontWeight, FontWeight.w400);

    final spans =
        (label.textSpan! as TextSpan).children!.cast<TextSpan>().toList();
    expect(spans.map((s) => s.text), <String>['box', '@example.net']);
    expect(spans.first.style?.fontWeight, FontWeight.w700);
    expect(spans.last.style, isNull);
  });

  testWidgets('实例行用的又是另一种图标', (tester) async {
    await pump(tester, boxes: const <MailboxAccount>[box]);

    // 三级各一个图标：实例 `dns`、邮箱 `mail_outline`、合并项 `all_inbox`。
    expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    expect(find.text('a@x.com'), findsOneWidget);
  });

  /// 层级的主要来源是缩进：实例行（组头）的标签比它下面的邮箱行靠左 18。
  ///
  /// 18 = 行左内边距差 20 减去图标小一号省下的 2。原来这两种行从同一个 x
  /// 开始，只靠字重区分 —— 侧栏里一行行扫下去几乎分不出「这是台实例」还是
  /// 「这是它下面的一口邮箱」。现在钉住这个差值，改行内边距时它会立刻红。
  testWidgets('实例行比邮箱行更靠左；邮箱行内部对齐', (tester) async {
    await pump(tester, boxes: const <MailboxAccount>[box]);
    final mailboxLeft = tester.getTopLeft(find.text('box@example.net')).dx;
    final instanceLeft = tester.getTopLeft(find.text('a@x.com')).dx;

    expect(instanceLeft, lessThan(mailboxLeft));
    expect(mailboxLeft - instanceLeft, 18);

    // 合并项也是「组内的一项」，与具体邮箱同一个 x。
    await pump(tester, boxes: const <MailboxAccount>[]);

    expect(tester.getTopLeft(find.text('全部邮箱')).dx, mailboxLeft);
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

    /// 曾经这里钉的是「地址落在这台上时，单独收起也不算数」——`forced`
    /// 优先于收起记录，用户点实例箭头**看起来无效**。现在收起记录是唯一
    /// 事实：停在这台实例上点收起，子行真的会消失。
    testWidgets('地址落在这台上时，单独收起仍然生效', (tester) async {
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        collapsed: <String>{'p1'},
      );

      expect(find.text('a@x.com'), findsOneWidget);
      expect(find.text('box@example.net'), findsNothing);
    });

    /// 直接在这台实例上点箭头（地址就停在它上面）—— 这次真的收起。
    testWidgets('停在这台实例上时点箭头，子行消失', (tester) async {
      await pump(tester, boxes: const <MailboxAccount>[box]);
      expect(find.text('box@example.net'), findsOneWidget);

      await tester.tap(find.byTooltip('展开或收起这个实例的邮箱'));
      await tester.pumpAndSettle();

      expect(find.text('box@example.net'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
    });

    /// 从「收起」拨到「展开」时要补探一次总数。
    ///
    /// 挂载时这一台是收起的，`_scheduleProbe` 那一帧直接 return；而展开是
    /// provider 状态，不改变任何 widget 入参，`didUpdateWidget` 不会触发。
    /// 不补的话，这一台各邮箱的浅色总数要等下次重启 / 树重建才出现
    /// （旧实现靠 `forced` 翻转「碰巧」能探，那条路随 `forced` 一起删了）。
    testWidgets('从收起拨到展开时补探一次总数', (tester) async {
      final probe = _RecordingProbe();
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        initial: '/starred',
        collapsed: <String>{'p1'},
        probe: probe,
      );

      // 挂载时是收起的：不探。
      expect(probe.ensureCalls, isEmpty);

      await tester.tap(find.byTooltip('展开或收起这个实例的邮箱'));
      await tester.pumpAndSettle();

      expect(probe.ensureCalls, hasLength(1));
      expect(
        probe.ensureCalls.single.boxes,
        const <MailboxFilter>[MailboxFilter(profileId: 'p1', accountId: 1)],
      );
    });

    /// 一括关掉时**所有**实例的子行都收起，包括地址正落着的那一台 ——
    /// 「收件箱」那颗箭头管的是整个目录，不是除当前实例以外的那些。
    testWidgets('一括关掉 + 落在这台上：整组收起（收起优先于地址）', (tester) async {
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

      expect(find.text('a@x.com'), findsOneWidget);
      expect(find.text('b@y.com'), findsOneWidget);
      expect(find.text('box@example.net'), findsNothing);
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

  group('数量与未读徽章', () {
    /// 名字后面紧跟浅色总数，最右边是一颗红色徽章 —— 两样都在，各说一件事。
    testWidgets('总数紧跟邮箱名，未读在最右那颗红色徽章里', (tester) async {
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        initial: '/starred',
        mailboxUnreadOf: (profileId, accountId) => 3,
        mailboxTotalOf: (profileId, accountId) => 12,
      );

      final label = find.text('box@example.net');
      final total = find.text('12');
      final badge = find.byType(SidebarUnreadBadge);
      expect(label, findsOneWidget);
      expect(total, findsOneWidget);
      expect(badge, findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      // 「紧随」：总数紧贴在名字右边（6px 的间距 + 前后文），而不是被
      // 推到行的另一头。
      final gap = tester.getTopLeft(total).dx - tester.getTopRight(label).dx;
      expect(gap, greaterThanOrEqualTo(0));
      expect(gap, lessThan(20));

      // 徽章钉最右：它在总右边，且在行内靠右那一端。
      expect(
        tester.getTopLeft(badge).dx,
        greaterThan(tester.getTopRight(total).dx),
      );

      // 红色来自主题的 error（不是写死的 Colors.red），否则深色主题下对比度
      // 会不对。
      final badgeContainer = tester.widget<Container>(
        find
            .descendant(of: badge, matching: find.byType(Container))
            .first,
      );
      final decoration = badgeContainer.decoration! as BoxDecoration;
      final scheme = Theme.of(tester.element(badge)).colorScheme;
      expect(decoration.color, scheme.error);
    });

    testWidgets('未读 0 时那颗徽章不出现（只留总数）', (tester) async {
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        initial: '/starred',
        mailboxTotalOf: (profileId, accountId) => 7,
      );

      expect(find.text('7'), findsOneWidget);
      expect(find.byType(SidebarUnreadBadge), findsNothing);
    });

    /// 实例行也走同一套：名字后面是这台实例的合计，最右是它的未读徽章。
    testWidgets('实例行：合计紧跟实例名，未站在行最右（箭头让位）', (tester) async {
      await pump(
        tester,
        boxes: const <MailboxAccount>[box],
        initial: '/starred',
        instanceUnreadOf: (profileId) => 5,
        instanceTotalOf: (profileId) => 20,
      );

      final name = find.text('a@x.com');
      final total = find.text('20');
      final badge = find.byType(SidebarUnreadBadge);
      expect(name, findsOneWidget);
      expect(total, findsOneWidget);
      expect(badge, findsOneWidget);
      expect(find.text('5'), findsOneWidget);

      final gap = tester.getTopLeft(total).dx - tester.getTopRight(name).dx;
      expect(gap, greaterThanOrEqualTo(0));
      expect(gap, lessThan(20), reason: '合计应当紧跟在实例名后面，而不是被推到行尾');

      // 实例行最右是展开箭头（箭头必须可点、还承担「这里能展开」的提示），
      // 徽章钉在箭头左边 —— 与邮箱行「贴最右」的差别正是这个箭头让出来的。
      final caret = tester.getTopLeft(find.byType(IconButton));
      expect(caret.dx, greaterThanOrEqualTo(tester.getTopRight(badge).dx));
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

/// 只记下「被 ensure 了几次、带了哪些邮箱」的探测器。
///
/// 用途只有 S1 那条：从收起 → 展开时侧栏要补探一次总数（否则这一台各邮箱
/// 的浅色总数在本次会话里一直是空的）。探测策略本身不在这里验。
class _RecordingProbe implements MailboxTotalsProbe {
  final List<({String profileId, List<MailboxFilter> boxes})> ensureCalls =
      <({String profileId, List<MailboxFilter> boxes})>[];

  @override
  Ref get ref => throw UnimplementedError('这一组用例不碰探测器的内部');

  @override
  Future<void> ensure({
    required Profile profile,
    required List<MailboxFilter> boxes,
  }) async {
    ensureCalls.add((profileId: profile.id, boxes: boxes));
  }
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
