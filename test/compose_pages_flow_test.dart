// 撰写页的「打开 / 切走 / 关闭」生命周期，走**真 ComposeEntry + 真 GoRouter**。
//
// 这三件事只测 widget 都不够：
// - 打开时有没有草稿行（没有行就不进「邮件撰写」、重启也恢复不了）；
// - 切走（`go` 到别处，不经过 X）时打开标记要**留着** —— 页面还在列表里；
// - 关闭（X）时：什么都没写删行、写过只去标记（内容回草稿箱）。
//
// 纯 DAO 用例只能验「方法是对的」，验不了「谁在什么时候调它」。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/compose/compose_entry.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  late AppDatabase db;
  late GoRouter router;

  /// 装一棵最小树：`/list` 是「来的地方」，`/compose` 走真的 `ComposeEntry`。
  ///
  /// [initial] 默认直接停在撰写页（验「打开即建行」）；需要先造数据的用例
  /// 从 `/list` 起步。
  Future<void> pump(
    WidgetTester tester, {
    String initial = '/compose?profile=p1&from=%2Flist',
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        currentProfileIdProvider.overrideWithValue('p1'),
      ],
    );
    addTearDown(container.dispose);

    router = GoRouter(
      initialLocation: initial,
      routes: <RouteBase>[
        GoRoute(
          path: '/list',
          builder: (context, state) => const Scaffold(body: Text('list-page')),
        ),
        GoRoute(
          path: Routes.compose,
          builder: (context, state) {
            final query = state.uri.queryParameters;
            return ComposeEntry(
              profileId: query['profile'] ?? '',
              draftId: int.tryParse(query['draft'] ?? '') ?? 0,
              mode: composeModeOf(query['mode']),
              from: query[Routes.fromParam],
            );
          },
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
    // **不要在这里 `pumpAndSettle`**：草稿行还在异步建，那一帧是
    // `CircularProgressIndicator`（无限动画），settle 永远等不到。
    // 用 runAsync 放真异步（drift 建行）跑完，再推一帧。
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pumpAndSettle();
  }

  /// **用 `select().get()` 而不是 `watchOpenDrafts().first`**：drift 的
  /// `watch` 流在 `testWidgets` 的假时钟下不会自己推完，`first` 会一直挂着
  /// （`compose_exit_paths_test.dart` 里那段注释讲的是同一件事）。
  Future<List<DbDraft>> storedDrafts() => db.select(db.drafts).get();
  Future<List<DbComposePage>> openPages() => db.select(db.composePages).get();

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  testWidgets('打开新撰写页：先建草稿行 + 打开标记，侧栏才有东西可列', (tester) async {
    await pump(tester);

    expect(await openPages(), hasLength(1), reason: '新页面必须在打开这一刻就有行');
    expect(await storedDrafts(), hasLength(1));

    await disposeTree(tester);
  });

  testWidgets('什么都没写就点关闭：草稿行删除，草稿箱不留空记录', (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('list-page'), findsOneWidget, reason: '关闭后回到 from');
    expect(await storedDrafts(), isEmpty,
        reason: '「空信不存」这条规矩不能因为自动保存就破');
    expect(await openPages(), isEmpty);

    await disposeTree(tester);
  });

  testWidgets('写了主题再关闭：草稿留着、打开标记去掉（内容回草稿箱）', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('compose-subject')),
      '写了一半',
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(await openPages(), isEmpty, reason: '关掉就不再是「正在编辑」');
    final drafts = await storedDrafts();
    expect(drafts, hasLength(1));
    expect(drafts.single.subject, '写了一半');

    await disposeTree(tester);
  });

  testWidgets('切走（不是关闭）：打开标记留着，重启后还能恢复这一页', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('compose-subject')),
      '切走前写的',
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 侧栏点别的页面 = 直接 `go`，不经过 X / 返回键。
    router.go('/list');
    await tester.pumpAndSettle();

    expect(await openPages(), hasLength(1),
        reason: '切走不等于关页 —— 它还在「邮件撰写」里');
    final drafts = await storedDrafts();
    expect(drafts, hasLength(1));
    expect(drafts.single.subject, '切走前写的');

    await disposeTree(tester);
  });

  testWidgets('从列表打开已有草稿：标记补上，关掉后草稿仍留着', (tester) async {
    await pump(tester, initial: '/list');
    final id = await db.localDao.saveDraft(
      profileId: 'p1',
      accountEmail: '',
      recipientsJson: '[]',
      subject: '老草稿',
      content: '[{"insert":"正文\\n"}]',
    );
    router.go(Routes.composeOf(profileId: 'p1', draftId: id));
    await tester.pumpAndSettle();

    expect((await openPages()).single.draftId, id);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(await openPages(), isEmpty);
    final draft = await db.localDao.findDraft(id);
    expect(draft, isNotNull);
    expect(draft!.subject, '老草稿');

    await disposeTree(tester);
  });
}
