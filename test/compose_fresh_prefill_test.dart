// 新答复页的「预填即落盘」。
//
// 症状：从详情页点「答复」进撰写页，左侧「邮件撰写」里那一项一直显示
// 「（无主题）」，要切到别的页面 / 关掉再回来才刷新。根因是预填（主题 /
// 收件人 / 引用块 / 发件邮箱）只活在 `ComposeController.build()` 的内存
// state 里，库里那条草稿行还是新建时的空行 —— 侧栏读的是库。
//
// 为什么必须是「真 ComposeEntry + 真 GoRouter + 内存库」的 widget 用例：
//   - 纯 factory 单测只能证明「预填算对了」，证明不了「谁在什么时候把
//     它写进库」；
//   - 只装 `SidebarComposeGroup`、把 `openDraftsProvider` 换成常量流的用例
//     又证明不了「新页真的写了库」；
//   - 这里一个字都不输入 —— 只要断言库里有预填、侧栏立刻显示「答复 xxx」，
//     就把「打开页面 → 落盘 → 侧栏刷新」这条链整条钉住了。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_entry.dart';
import 'package:mail_app/features/shell/sidebar_compose.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Profile _profile = Profile(
  id: 'p1',
  baseUrl: 'https://a.example/api',
  email: 'me@a.example',
  userName: '甲',
  userId: 7,
);

/// 给一个真发件邮箱：预填快照里的 `accountEmail` 要能写下来（否则这条
/// 断言就退化成「空串也算通过」）。
const MailboxAccount _box = MailboxAccount(
  accountId: 3,
  email: 'me@a.example',
  name: '甲',
);

/// 被答复的原信：正文是完整 HTML（`replyQuote` 要它拼引用块）。
MailRow originalMail() => MailRow(
      emailId: 7,
      profileId: 'p1',
      accountId: 3,
      subject: '主题',
      sendEmail: 'alice@example.com',
      name: 'Alice',
      mailboxEmail: 'me@a.example',
      content: '<p>第一段</p>',
      createTime: DateTime.utc(2026, 10, 10, 12),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  late AppDatabase db;
  late GoRouter router;

  /// 装一棵「外壳 + 内容区」的最小树：侧栏是真的 `SidebarComposeGroup`
  /// （与正式 App 一样，切页不重建），内容区走真的 `ComposeEntry`。
  ///
  /// 路由挂 `ShellRoute` 而不是把侧栏塞进每个页面：症状 A 的要害就是
  /// 「侧栏一直活着、只跟着库刷新」，每次 `go` 都拆掉侧栏的装置量不出它。
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        // `refreshQuota()` / 发件人候选会顺着 runtime → tokenStore →
        // bootstrap 读一圈，少了它整条链在 pumpAndSettle 里抛。
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        prefsStoreProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        currentProfileIdProvider.overrideWithValue('p1'),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[_profile]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(
            profileId == 'p1' ? const <MailboxAccount>[_box] : const <MailboxAccount>[],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    router = GoRouter(
      initialLocation: '/list',
      routes: <RouteBase>[
        ShellRoute(
          builder: (context, state, child) => Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: 280, child: SidebarComposeGroup(uri: state.uri)),
                const VerticalDivider(width: 1),
                Expanded(child: child),
              ],
            ),
          ),
          routes: <RouteBase>[
            GoRoute(
              path: '/list',
              builder: (context, state) =>
                  const Scaffold(body: Text('list-page')),
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
                  // 正式链路里由 `ComposeEntry._ensureFull` 从库里补正文；
                  // 测试直接给 full 行，省掉一趟网络/库。
                  initial: originalMail(),
                );
              },
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
    // 建草稿行、读库、drift 流派发都是真异步：假时钟下走不完。
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pumpAndSettle();
  }

  /// 从「来的地方」点答复：地址里**没有** `draft`（与 `openMailCompose`
  /// 一致），草稿行是进页之后才建的。
  Future<void> openReply(WidgetTester tester) async {
    // 与 `openMailCompose` 同形：地址里没有 `draft`，只有 profile/mode/from。
    final location = Routes.composeOf(
      profileId: 'p1',
      mode: ComposeMode.reply,
    );
    router.go(
      Uri.parse(location)
          .replace(
            queryParameters: <String, String>{
              ...Uri.parse(location).queryParameters,
              Routes.fromParam: '/list',
            },
          )
          .toString(),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
    // 发件人候选是 drift 流，第一帧才吐值：它到了之后自动保存会补写
    // `account_email`。这里的 1.6s 是把防抖窗口走完（不是等真实网络）。
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
  }

  Finder sidebarText(String text) => find.descendant(
        of: find.byType(SidebarComposeGroup),
        matching: find.text(text),
      );

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  testWidgets('新答复页一个字不输入：预填已经落进草稿行，侧栏立刻显示「答复 主题」',
      (tester) async {
    await pump(tester);
    expect(await db.select(db.drafts).get(), isEmpty, reason: '还没进撰写页');

    await openReply(tester);

    // ① 库里那一行不再只有 id/profile：主题、收件人、引用块、发件邮箱都写下了。
    final drafts = await db.select(db.drafts).get();
    expect(drafts, hasLength(1), reason: '新页只该有一条草稿行');
    final row = drafts.single;
    expect(row.subject, '答复 主题', reason: '预填的主题必须落库，侧栏读的就是它');
    expect(row.recipientsJson, contains('alice@example.com'));
    expect(row.accountEmail, 'me@a.example');
    expect(row.content, isNotEmpty, reason: '引用块是正文初值，同样要落盘');

    // ② 左侧「邮件撰写」：真 provider + 真库，这一项直接显示主题，
    //    而不是等用户切走/关页才刷新。
    expect(sidebarText('答复 主题'), findsOneWidget);
    expect(sidebarText('（无主题）'), findsNothing);

    // ③ 当前页那一项要高亮：地址里没有 draft，靠页面发布的 active id。
    final item = tester.widget<Text>(sidebarText('答复 主题'));
    expect(
      item.style?.fontWeight,
      FontWeight.w600,
      reason: '正在编辑的这一项应当高亮（地址里没有 draft，不能靠地址推）',
    );

    await disposeTree(tester);
  });

  testWidgets('新答复页一个字不输入就关闭：草稿行仍要删掉（预填不算「写过」）',
      (tester) async {
    await pump(tester);
    await openReply(tester);
    expect(await db.select(db.drafts).get(), hasLength(1));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('list-page'), findsOneWidget, reason: '关闭后回到来的地方');
    expect(
      await db.select(db.drafts).get(),
      isEmpty,
      reason: '预填立即落盘不能把「空信不存」这条规矩破掉：'
          '回复页一个字没敲就关掉，草稿箱里不该留下只有引用块的草稿',
    );
    expect(await db.select(db.composePages).get(), isEmpty);

    await disposeTree(tester);
  });
}
