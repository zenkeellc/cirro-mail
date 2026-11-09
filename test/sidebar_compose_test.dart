// 左侧「邮件撰写」分类：默认展开、按数据源顺序渲染（数据源已按最后编辑时间
// 倒序）、空态提示、展开/收起、点子项进对应撰写页。
//
// 为什么单独一个文件：这一组的行为一半在数据源（`watchOpenDrafts` 的排序，
// 另见 `compose_pages_dao_test.dart`）、一半在这个 widget 的渲染与跳转上。
// 只测一边的话，「排序正确但渲染反了」或「渲染正确但点开的是别的草稿」
// 都能全绿。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/shell/sidebar_compose.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DbDraft draft({
    required int id,
    required String subject,
    String updatedAt = '2026-11-09T00:00',
  }) =>
      DbDraft(
        id: id,
        profileId: 'p1',
        accountEmail: 'me@x.com',
        recipientsJson: '["you@x.com"]',
        subject: subject,
        content: '',
        attachmentPathsJson: '[]',
        updatedAt: DateTime.parse(updatedAt),
        // v6 的跨设备身份：这一组用例只看渲染，uid/rev 给固定值即可。
        uid: 'uid-$id',
        rev: 1,
      );

  /// `openDraftsProvider` 的替身：数据源已按「最后编辑时间倒序」排好
  /// （`watchOpenDrafts` 的 `ORDER BY` 由 DAO 用例钉住）。
  Future<(GoRouter, ProviderContainer)> pump(
    WidgetTester tester,
    List<DbDraft> drafts,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    final container = ProviderContainer.test(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        openDraftsProvider.overrideWith(
          (ref) => Stream<List<DbDraft>>.value(drafts),
        ),
      ],
    );
    addTearDown(container.dispose);

    // 侧栏挂在外壳（`ShellRoute`）里、而不是每个页面自己装一份：正式 App
    // 里它**跨页常驻**，高亮/计数才是「切页面时不变」的。顺带让「切到撰写页
    // 之后侧栏还在」这件事在用例里成立。
    final router = GoRouter(
      initialLocation: '/mail/p1',
      routes: <RouteBase>[
        ShellRoute(
          builder: (context, state, child) => Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: 240,
                  child: SidebarComposeGroup(uri: state.uri),
                ),
                Expanded(child: child),
              ],
            ),
          ),
          routes: <RouteBase>[
            GoRoute(
              path: '/mail/:profileId',
              builder: (context, state) =>
                  const Scaffold(body: Text('mail-page')),
            ),
            GoRoute(
              path: '/compose',
              builder: (context, state) =>
                  Scaffold(body: Text('compose:${state.uri}')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

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
    return (router, container);
  }

  /// 子项的「高亮」= 字重 `w600`（见 `_ComposePageRow` 的 `selected`）。
  FontWeight? itemWeight(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style?.fontWeight;

  testWidgets('默认展开：父项 + 全部打开中的页面，顺序与数据源一致', (tester) async {
    await pump(tester, <DbDraft>[
      draft(id: 3, subject: '最新的一封'),
      draft(id: 2, subject: '中间那封'),
      draft(id: 1, subject: '最早那封'),
    ]);

    expect(find.text('邮件撰写'), findsOneWidget);
    expect(find.text('最新的一封'), findsOneWidget);
    expect(find.text('中间那封'), findsOneWidget);
    expect(find.text('最早那封'), findsOneWidget);

    // 渲染顺序 = 数据源顺序（最后编辑的在上）。
    final newestY = tester.getTopLeft(find.text('最新的一封')).dy;
    final middleY = tester.getTopLeft(find.text('中间那封')).dy;
    final oldestY = tester.getTopLeft(find.text('最早那封')).dy;
    expect(newestY, lessThan(middleY));
    expect(middleY, lessThan(oldestY));
  });

  testWidgets('没有打开中的页面：给一句空态提示', (tester) async {
    await pump(tester, const <DbDraft>[]);

    expect(find.text('邮件撰写'), findsOneWidget);
    expect(find.text('没有正在编辑的邮件'), findsOneWidget);
  });

  testWidgets('收起 → 子项消失；再展开 → 回来', (tester) async {
    await pump(tester, <DbDraft>[draft(id: 1, subject: '一封信')]);
    expect(find.text('一封信'), findsOneWidget);

    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    expect(find.text('一封信'), findsNothing);

    await tester.tap(find.byTooltip('展开'));
    await tester.pumpAndSettle();
    expect(find.text('一封信'), findsOneWidget);
  });

  testWidgets('点子项：去那一封的撰写页，并带上回来的地址', (tester) async {
    await pump(tester, <DbDraft>[
      draft(id: 7, subject: '点我'),
      draft(id: 9, subject: '别点我'),
    ]);

    await tester.tap(find.text('点我'));
    await tester.pumpAndSettle();

    final url = find.textContaining('compose:/compose');
    expect(url, findsOneWidget);
    final text = (tester.widget<Text>(url)).data ?? '';
    expect(text, contains('draft=7'), reason: '点开的是被点的那一封');
    expect(text, isNot(contains('draft=9')));
    expect(text, contains('from=%2Fmail%2Fp1'),
        reason: '关页时要知道回到哪里');
  });

  testWidgets('主题为空的页面显示「（无主题）」', (tester) async {
    await pump(tester, <DbDraft>[draft(id: 1, subject: '  ')]);
    expect(find.text('（无主题）'), findsOneWidget);
  });

  group('高亮跟随当前编辑页', () {
    testWidgets('地址里没有 draft（回复/转发/新邮件）：用页面发布的活动 id', (tester) async {
      final (router, container) = await pump(tester, <DbDraft>[
        draft(id: 7, subject: '答复 主题'),
        draft(id: 9, subject: '另一封'),
      ]);

      // 页面在「建好草稿行」之后发布（见 `ComposeEntry._ensureDraft`）；
      // 这里直接模拟那一刻。地址里没有 `draft`，侧栏从地址上推不出来。
      container.read(activeComposeDraftIdProvider.notifier).publish(7);
      router.go('/compose?profile=p1&mode=reply');
      await tester.pumpAndSettle();

      expect(itemWeight(tester, '答复 主题'), FontWeight.w600,
          reason: '正在编辑的这一项要高亮');
      expect(itemWeight(tester, '另一封'), FontWeight.w400);
    });

    testWidgets('地址里带了 draft：以地址为准，活动 id 不抢', (tester) async {
      final (router, container) = await pump(tester, <DbDraft>[
        draft(id: 7, subject: '答复 主题'),
        draft(id: 9, subject: '另一封'),
      ]);

      container.read(activeComposeDraftIdProvider.notifier).publish(9);
      router.go('/compose?draft=7');
      await tester.pumpAndSettle();

      expect(itemWeight(tester, '答复 主题'), FontWeight.w600);
      expect(itemWeight(tester, '另一封'), FontWeight.w400,
          reason: '地址里有 draft 时只有那一项高亮');
    });

    test('clear 只清自己那一条：切页时旧页面不能灭掉新页面', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final active = container.read(activeComposeDraftIdProvider.notifier);

      active.publish(7);
      expect(container.read(activeComposeDraftIdProvider), 7);

      // 旧页面（7）先销毁、新页面（9）已经发布 —— 旧页面必须假装没看见。
      active.publish(9);
      active.clear(7);
      expect(container.read(activeComposeDraftIdProvider), 9);

      active.clear(9);
      expect(container.read(activeComposeDraftIdProvider), 0);
      // 0 / 负数不是合法行 id，忽略（建行失败时页面可能拿到 0）。
      active.publish(0);
      expect(container.read(activeComposeDraftIdProvider), 0);
    });
  });
}
