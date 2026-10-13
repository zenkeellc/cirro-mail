// 宿主层（`MailShortcutHost`）的三条动作：新建 / 答复转发 / 删除。
//
// 这一组**必须开真的路由树**（真 `GoRouter` + `MaterialApp.router`），因为要
// 验的正是「从地址解出当前那一封」这件事本身：动作的输入不是参数，是**地址**。
// 拿一个假的 `Actions` 去 invoke，验的就只剩「我传了什么进去」，而本轮改动的
// 全部风险在「地址读得对不对、Action 挂的位置对不对」。
//
// `routerProvider` 换成一个**小路由表**（只留 `/mail/...`、`/settings` 与
// `/compose`）：真那棵树要喂未读/草稿/发件箱好几条 drift 流，用例会变成在测
// 外壳。地址的形状与真表一致（`/mail/<p>?sel=<e>`、`/mail/<p>/<e>`），键位表
// 与 Action 都是真的。
//
// 平台用默认值（flutter_tester 下是 android → `Control`）：mac 那一支（`Command`）
// 是同一张表的另一个分支，`test/mail_shortcuts_keymap_test.dart` 已经逐个字段
// 钉过它，这里再跑一遍只是把同一件事写两遍。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/compose/compose_preselect.dart';
import 'package:mail_app/features/shortcuts/shortcut_host.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profileId = 'p1';
  const emailId = 7;

  MailRow mail() => MailRow(
        emailId: emailId,
        profileId: profileId,
        name: '发件人',
        sendEmail: 'from@x.com',
        subject: '一封广告',
        text: '正文',
        content: '<p>正文</p>',
        hasFullBody: true,
        type: MailType.receive,
        createTime: DateTime(2026, 1, 2, 3, 4),
      );

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// 装一棵「真路由 + 宿主层」的树，返回本地库与 provider 容器。
  ///
  /// [location] 就是起始地址 —— 本组所有断言都由它推出来。
  /// [row] 给出时先写进本地库（删除那一条要从库里查行）。
  ///
  /// 容器是**显式建的**（不是 `ProviderScope` 自己建的）只为了一件事：测试里
  /// 要能先往 `composePreselectProvider` 里发布一份预选值再按快捷键。
  Future<({AppDatabase db, ProviderContainer container})> pump(
    WidgetTester tester, {
    required String location,
    MailRow? row,
    ComposePreselect? preselect,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final router = GoRouter(
      initialLocation: location,
      routes: <RouteBase>[
        GoRoute(
          path: Routes.settings,
          builder: (context, state) => const Scaffold(body: Text('设置页')),
        ),
        // 列表（宽屏分栏的右栏靠 `?sel=`）+ 详情（窄屏那一页）。
        GoRoute(
          path: '${Routes.mail}/:profileId',
          builder: (context, state) => const Scaffold(
            body: Center(child: Text('列表页')),
          ),
          routes: <RouteBase>[
            GoRoute(
              path: ':emailId',
              builder: (context, state) =>
                  Scaffold(body: Text('detail:${state.uri}')),
            ),
          ],
        ),
        // 写邮件页的**代替品**：这一组只验「推到哪儿去了」，页面本身有它
        // 自己的一整套用例（与 `compose_launcher_test.dart` 同一个理由）。
        GoRoute(
          path: Routes.compose,
          builder: (context, state) =>
              Scaffold(body: Text('compose:${state.uri}')),
        ),
      ],
    );
    addTearDown(router.dispose);

    final container = ProviderContainer(overrides: [
      // 宿主层读的就是它（`_currentUri`）—— 换掉它就等于换掉「当前那一封」。
      routerProvider.overrideWithValue(router),
      bootstrapProvider.overrideWithValue(BootstrapData(
        db: db,
        tokens: TokenStore(),
        prefs: PrefsStore(await SharedPreferences.getInstance()),
      )),
    ]);
    addTearDown(container.dispose);
    if (preselect != null) {
      container
          .read(composePreselectProvider.notifier)
          .publish(Object(), preselect);
    }

    // 行要**在装树之前**写进库：删除那一路是「按快捷键 → 宿主层现查库 →
    // MailActionRunner」，查的时候树已经在跑了。
    if (row != null) await db.mailDao.upsertPage(<MailRow>[row]);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        // 宿主层挂在 **builder** 里（不是外面）：它要 `Theme.of(context).platform`，
        // 而 Theme 是 MaterialApp 自己给的。这也正是 `lib/app.dart` 里的位置。
        builder: (context, child) =>
            MailShortcutHost(child: child ?? const SizedBox.shrink()),
      ),
    ));
    await tester.pumpAndSettle();
    return (db: db, container: container);
  }

  /// 按一次 `Control + <key>`（[shift] 时再加上 Shift）。
  ///
  /// `sendKeyEvent` 只发「按下 + 抬起」，修饰键要自己按着 —— `SingleActivator`
  /// 判的是 `HardwareKeyboard` 当下按住的那些键，不是事件里带的。
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// 拆树并把时钟推一帧（drift 给流关闭排的是零延时定时器，见
  /// `mail_detail_suggest_test.dart` 里同一句注释）。**断言必须在它之前**。
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  testWidgets('答复：宽屏右栏选中时按 Ctrl+R，开出的地址与详情页那颗回形箭头一样',
      (tester) async {
    await pump(tester, location: '/mail/p1?sel=$emailId', row: mail());

    await press(tester, LogicalKeyboardKey.keyR);

    expect(
      find.text('compose:/compose?profile=p1&email=7&mode=reply'),
      findsOneWidget,
    );
    await disposeTree(tester);
  });

  testWidgets('转发：Ctrl+Shift+F → mode=forward', (tester) async {
    await pump(tester, location: '/mail/p1?sel=$emailId', row: mail());

    await press(tester, LogicalKeyboardKey.keyF, shift: true);

    expect(
      find.text('compose:/compose?profile=p1&email=7&mode=forward'),
      findsOneWidget,
    );
    await disposeTree(tester);
  });

  testWidgets('窄屏详情页（当前那一封在路径段里）同样认得出', (tester) async {
    await pump(tester, location: '/mail/p1/$emailId', row: mail());

    await press(tester, LogicalKeyboardKey.keyR);

    expect(
      find.text('compose:/compose?profile=p1&email=7&mode=reply'),
      findsOneWidget,
    );
    await disposeTree(tester);
  });

  testWidgets('删除：Ctrl+D 先问「删哪一封」，确认之后真的没了', (tester) async {
    final tree =
        await pump(tester, location: '/mail/p1?sel=$emailId', row: mail());
    final db = tree.db;
    expect(await db.mailDao.find(profileId, emailId), isNotNull,
        reason: '前提：这一封在库里');

    await press(tester, LogicalKeyboardKey.keyD);

    // 确认框要**说清是哪一封**（`aiSuggestDeleteConfirm(subject)` 那个参数的
    // 用途）—— 这一层要是自己写一个「删除这封邮件？」就丢了这条信息。
    expect(find.text('删除「一封广告」？'), findsOneWidget);
    expect(find.textContaining('compose:'), findsNothing,
        reason: '删除不是「去写邮件」—— 两条动作别串了');

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(await db.mailDao.find(profileId, emailId), isNull,
        reason: '确认之后要真的删掉（走的是 MailActionRunner 那一处执行）');
    await disposeTree(tester);
  });

  testWidgets('删除：在确认框里按取消，什么都不发生', (tester) async {
    final tree =
        await pump(tester, location: '/mail/p1?sel=$emailId', row: mail());
    final db = tree.db;

    await press(tester, LogicalKeyboardKey.keyD);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(await db.mailDao.find(profileId, emailId), isNotNull);
    await disposeTree(tester);
  });

  testWidgets('列表页没选中任何一封：答复/转发/删除都**静默不做**', (tester) async {
    final tree = await pump(tester, location: '/mail/p1', row: mail());
    final db = tree.db;

    await press(tester, LogicalKeyboardKey.keyR);
    await press(tester, LogicalKeyboardKey.keyF, shift: true);
    await press(tester, LogicalKeyboardKey.keyD);

    expect(find.textContaining('compose:'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing,
        reason: '没选中时说一句「请先选一封」比没反应更吵 —— 静默是常态');
    expect(find.text('列表页'), findsOneWidget, reason: '前提：我们还停在列表页');
    expect(await db.mailDao.find(profileId, emailId), isNotNull);
    await disposeTree(tester);
  });

  testWidgets('新建是全局的：停在设置页按 Ctrl+N 也开写邮件页', (tester) async {
    // 另外三条要有「当前那一封」才成立，新建不需要 —— 它与外壳那颗 FAB
    // 是同一件事，在任何一屏都该能按。这一条把这条边界钉住。
    await pump(tester, location: Routes.settings);
    expect(find.text('设置页'), findsOneWidget, reason: '前提：在设置页上');

    await press(tester, LogicalKeyboardKey.keyN);

    expect(find.text('compose:/compose'), findsOneWidget,
        reason: '没有预选发件箱时地址里什么参数都没有（与 FAB 同一条口径）');
    await disposeTree(tester);
  });

  testWidgets('新建读的是 composePreselectProvider 里那一份预选', (tester) async {
    // 与 `Ctrl+R` 不同，新建**不看地址**，看的是「外壳那一颗 FAB 会从哪个
    // 邮箱发」。两条各拼一遍的话，「预选发件箱」迟早只在其中一处生效 ——
    // 症状是「点 FAB 从对的邮箱发，按 Ctrl+N 从默认邮箱发」。
    await pump(
      tester,
      location: '/mail/p1',
      preselect: const ComposePreselect(profileId: 'p9', accountId: 3),
    );

    await press(tester, LogicalKeyboardKey.keyN);

    expect(
      find.text('compose:/compose?profile=p9&account=3'),
      findsOneWidget,
      reason: '读的必须是 provider 里那一份，不是「当前地址那个实例」',
    );
    await disposeTree(tester);
  });
}
