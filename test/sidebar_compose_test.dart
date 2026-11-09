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
  Future<GoRouter> pump(
    WidgetTester tester,
    List<DbDraft> drafts,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    final router = GoRouter(
      initialLocation: '/mail/p1',
      routes: <RouteBase>[
        GoRoute(
          path: '/mail/:profileId',
          builder: (context, state) =>
              Scaffold(body: SidebarComposeGroup(uri: state.uri)),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) =>
              Scaffold(body: Text('compose:${state.uri}')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
          openDraftsProvider.overrideWith(
            (ref) => Stream<List<DbDraft>>.value(drafts),
          ),
        ],
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
}
