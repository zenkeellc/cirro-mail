import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/mailbox_totals_probe.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 外壳里「收件箱」下面那组邮箱的**展开接线**（不是树本身里的那层）。
///
/// `sidebar_mailboxes_test.dart` 直接给 `SidebarMailboxTree` 传
/// `masterExpanded:`，验的是「传进去之后树怎么画」；但需求 2 真正的发生地
/// 在这两处：
///
/// 1. `app_shell.dart` 里那颗「收件箱」箭头的 `onPressed`（`set(false)` /
///    `set(true)` + `expandAll()`）；
/// 2. `app_shell.dart` 里 `if (expanded)` 决定整棵树**渲不渲染**。
///
/// 把 `|| pinned != null` 加回去、或者箭头漏掉 `expandAll()`，只测树的那个
/// 文件一个用例都不会红 —— 所以这里起**真外壳 + 真路由**，从界面点那颗箭头。
///
/// 窗口取 1400 宽（宽屏侧栏）；地址停在 `/mail/p1`：这正是旧代码里被
/// `forced` / `pinned` 撑开、让箭头看起来无效的位置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profile = Profile(
    id: 'p1',
    baseUrl: 'https://x/api',
    email: 'a@x.com',
    userId: 7,
  );
  const box = MailboxAccount(accountId: 1, email: 'box@example.net', name: 'Box');

  Future<void> pump(WidgetTester tester, {String initial = '/mail/p1'}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        prefsStoreProvider.overrideWithValue(prefs),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[profile]),
        ),
        allMailboxesByProfileProvider.overrideWithValue(
          <String, List<MailboxAccount>>{
            'p1': const <MailboxAccount>[box],
          },
        ),
        // 展开这一组会触发总数探测；探测第一件事是问联网状态，真身走
        // `connectivity_plus` 的平台通道（测试里没有）。探不探得动是
        // `mailbox_totals_probe_*` 那两个文件的事，这里只验展开接线。
        onlineProvider.overrideWith((ref) => Stream<bool>.value(true)),
        mailboxTotalsProbeProvider.overrideWithValue(_NoopProbe()),
        // 数字全部钉死，避免几个 drift 流在树拆掉后还挂着定时器
        // （`sidebar_mailboxes_test.dart` 里那段注释讲的是同一件事）。
        mailboxUnreadProvider.overrideWith((ref, key) => 0),
        mailboxTotalProvider.overrideWith((ref, key) => null),
        profileUnreadProvider.overrideWith((ref, profileId) => 0),
        instanceTotalProvider.overrideWith((ref, profileId) => null),
        totalUnreadProvider.overrideWithValue(0),
        outboxPendingCountProvider.overrideWithValue(0),
        draftCountProvider.overrideWithValue(0),
        // 真身会拉起整个调度器（时钟、平台通道），树拆掉后时钟还在 ——
        // `flutter_test` 会判「还有 Timer 没结束」。
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

    router.go(initial);
    await tester.pumpAndSettle();
  }

  /// 拆树再推一帧：外壳里零延时的清理定时器不能在用例结束时还挂着。
  Future<void> settleAndDispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  /// 这一组只认两样东西：邮箱行在不在、实例行在不在。
  ///
  /// 不用 `find.text('a@x.com')` 判实例行：内容区那半也可能显示实例名
  /// （邮箱筛选按钮），两边一起断会分不清是哪边。
  Finder instanceRows() => find.byIcon(Icons.dns_outlined);

  testWidgets('停在这台实例上时，「收件箱」箭头收起整棵目录', (tester) async {
    await pump(tester);

    expect(instanceRows(), findsOneWidget);
    expect(find.text('box@example.net'), findsOneWidget);

    await tester.tap(find.byTooltip('展开或收起邮箱列表'));
    await tester.pumpAndSettle();

    // 整棵目录都没了（含实例行）—— 不是「只收起当前实例」。
    expect(
      instanceRows(),
      findsNothing,
      reason: '收起「收件箱」目录 = 连实例行一起收起；只有子行消失说明'
          '箭头只拨到了某一台实例',
    );
    expect(find.text('box@example.net'), findsNothing);

    // 再拨开：整棵回来。
    await tester.tap(find.byTooltip('展开或收起邮箱列表'));
    await tester.pumpAndSettle();
    expect(instanceRows(), findsOneWidget);
    expect(find.text('box@example.net'), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets('「收件箱」展开时，单个实例的箭头只收那一台', (tester) async {
    await pump(tester);

    await tester.tap(find.byTooltip('展开或收起这个实例的邮箱'));
    await tester.pumpAndSettle();

    expect(
      instanceRows(),
      findsOneWidget,
      reason: '实例箭头只收起这一台的子行，实例行本身必须留着（不然没法再展开）',
    );
    expect(find.text('box@example.net'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    await tester.tap(find.byTooltip('展开或收起这个实例的邮箱'));
    await tester.pumpAndSettle();
    expect(find.text('box@example.net'), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets('「全部展开」会清掉之前单独收起的记录', (tester) async {
    await pump(tester);

    // 先单独收起这一台，再把整组收掉、重新展开。
    await tester.tap(find.byTooltip('展开或收起这个实例的邮箱'));
    await tester.pumpAndSettle();
    expect(find.text('box@example.net'), findsNothing);

    await tester.tap(find.byTooltip('展开或收起邮箱列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('展开或收起邮箱列表'));
    await tester.pumpAndSettle();

    // `expandAll()` 清空「单独收起」的集合 —— 上一次手动收起的那台
    // 不该在新的「全部展开」之后还躲着。
    expect(find.text('box@example.net'), findsOneWidget);

    await settleAndDispose(tester);
  });
}

/// 什么都不做的探测器（真正的策略在 `mailbox_totals_probe_*` 里钉）。
class _NoopProbe implements MailboxTotalsProbe {
  @override
  Ref get ref => throw UnimplementedError('这一组用例不碰探测器的内部');

  @override
  Future<void> ensure({
    required Profile profile,
    required List<MailboxFilter> boxes,
  }) async {}
}

/// `SyncController` 真身会拉起整个调度器；这一组验的是展开接线。
class _FakeSyncController extends SyncController {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  void setActiveProfile(String? profileId) {}
}
