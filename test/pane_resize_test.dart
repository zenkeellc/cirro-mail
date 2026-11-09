import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/instance_capabilities.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/mail_detail/mail_detail_screen.dart';
import 'package:mail_app/features/mail_list/mail_panes.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:mail_app/router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// **窗口拖窄时，当前打开的那封邮件不许变回列表**（用户报的 bug）。
///
/// 用户从「未读邮件」入口点开一封信（分栏形态：右栏里那封，地址是
/// `?sel=`），然后把窗口拖窄。以前右栏没了、`?sel=` 没人读，屏幕一下退回
/// 「未读邮件的列表」—— 用户明明选中并正在读的那封不见了，正文下方的 AI
/// 建议面板也跟着消失。
///
/// 这里用**真路由 + 真外壳 + 真列表**钉住整条链路：
///
/// - 分栏（>= 1024）选中态是 `?sel=`；
/// - 拖窄过断点时 `AppShell` 就地 `router.refresh()`，最外层重定向把 `?sel=`
///   展开成一整页详情（`/mail/all/<e>`），于是单栏形态继续显示**这封**；
/// - 拖宽回来再折回 `?sel=`，详情回到右栏。
///
/// 折叠函数本身在 `pane_routes_test.dart` 里逐条钉过；这里钉的是「宽度变化
/// 真的会触发这一次重定向」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profile = Profile(
    id: 'p1',
    baseUrl: 'https://x/api',
    email: 'a@x.com',
    userId: 7,
  );
  const emailId = 7;
  const subject = '一封未读邮件';
  final mailRow = MailRow(
    emailId: emailId,
    profileId: profile.id,
    name: '发件人',
    sendEmail: 'from@x.com',
    subject: subject,
    text: '正文',
    content: '<p>正文</p>',
    hasFullBody: true,
    unread: UnreadState.unread,
    type: MailType.receive,
    createTime: DateTime(2026, 1, 2, 3, 4),
  );

  // `any()` 要兜底值（mocktail 的注册表）：`MailRef` / `Profile` / 枚举都出现在
  // 假仓库的方法签名里。
  setUpAll(() {
    registerFallbackValue(const MailRef(profileId: '', emailId: 0));
    registerFallbackValue(const Profile(
      id: 'fallback',
      baseUrl: 'https://x/api',
      email: 'x@x.com',
      userId: 1,
    ));
    registerFallbackValue(MailType.receive);
    registerFallbackValue(CancelToken());
  });

  Future<GoRouter> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.mailDao.upsertPage(<MailRow>[mailRow]);

    final repo = _FakeRepo();
    when(() => repo.openMail(any())).thenAnswer((_) async {});
    // 详情页第一帧 `mailDetailProvider` 还没吐出那一行时会先走这条「翻页找」
    // 兜底；假仓库说「本地就是没有」，异常与诊断日志都不用出。
    when(() => repo.locateAcrossPages(any())).thenAnswer((_) async => null);
    // 列表首屏会顺手「继续加载」一页（本地窗口已经装满时不会，但兜住）：
    // 假仓库说「没有更旧的了」，别让返回类型走到 mocktail 的默认 null。
    when(() => repo.loadOlder(
          profile: any(named: 'profile'),
          accountId: any(named: 'accountId'),
          type: any(named: 'type'),
          allReceive: any(named: 'allReceive'),
          cancelToken: any(named: 'cancelToken'),
        )).thenAnswer((_) async => false);

    final container = ProviderContainer(overrides: [
      bootstrapProvider.overrideWithValue(
        BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
      ),
      prefsStoreProvider.overrideWithValue(prefs),
      profilesProvider.overrideWith(
        (ref) => Stream.value(const <Profile>[profile]),
      ),
      // 真身会拉起整个调度器（时钟 + 平台通道）。这一组验的是路由折叠。
      syncControllerProvider.overrideWith(_FakeSyncController.new),
      emailRepositoryProvider.overrideWithValue(repo),
      notificationServiceProvider.overrideWithValue(_SilentNotifications()),
      aiSettingsProvider.overrideWith(_UnconfiguredAiSettings.new),
      // 列表 / 详情要的那几条按实例的流：固定值（这一组不验数据同步）。
      capabilitiesProvider.overrideWith(
        (ref, profileId) => Stream.value(const InstanceCapabilities()),
      ),
      mailboxesProvider.overrideWith(
        (ref, profileId) => Stream.value(const <MailboxAccount>[]),
      ),
      inFlightByProfileProvider.overrideWith(
        (ref, profileId) => Stream.value(const <MailRef>{}),
      ),
      onlineProvider.overrideWith((ref) => Stream<bool>.value(true)),
      totalUnreadProvider.overrideWithValue(0),
      outboxPendingCountProvider.overrideWithValue(0),
      draftCountProvider.overrideWithValue(0),
    ]);
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
    // 「未读邮件」入口的地址（`HomeEntries.unread` 用的就是它）。
    router.go(Routes.mailOf(
      Routes.kAggregateNode,
      unreadOnly: true,
    ));
    await tester.pumpAndSettle();
    return router;
  }

  /// 当前地址。用 `routeInformationProvider.value.uri` 而不是再读一次
  /// `GoRouterState`：折叠之后要验的正是「地址真的变了」。
  Uri location(GoRouter router) =>
      router.routeInformationProvider.value.uri;

  testWidgets('点开一封 → 拖窄：还是这封的整页详情，不是未读列表', (tester) async {
    final router = await pump(tester);

    // 前提：宽屏是分栏，点开一行会折成 `?sel=`。
    expect(find.byType(MailPanes), findsOneWidget);
    await tester.tap(find.text(subject).first);
    await tester.pumpAndSettle();
    expect(location(router).path, '/mail/all');
    expect(location(router).queryParameters['sel'], '$emailId');
    expect(find.byType(MailPanes), findsOneWidget);
    expect(find.byType(MailDetailScreen), findsOneWidget);

    // ---- 拖窄到 900（单栏、但不是手机）--------------------------------
    tester.view.physicalSize = const Size(900, 900);
    await tester.pumpAndSettle();

    expect(
      location(router).path,
      '/mail/all/$emailId',
      reason: '`?sel=` 要展开成一整页详情地址 —— 单栏形态没有右栏',
    );
    expect(location(router).queryParameters['profile'], profile.id);
    expect(
      location(router).queryParameters[Routes.unreadParam],
      '1',
      reason: '「未读邮件」这个入口不能丢，否则返回时会落到收件箱',
    );
    expect(find.byType(MailPanes), findsNothing);
    expect(
      find.byType(MailDetailScreen),
      findsOneWidget,
      reason: '用户选中的那封要继续显示，而不是退回列表',
    );
    expect(find.text(subject), findsWidgets);

    // ---- 继续拖窄到手机宽度：还是这封 --------------------------------
    tester.view.physicalSize = const Size(500, 900);
    await tester.pumpAndSettle();
    expect(location(router).path, '/mail/all/$emailId');
    expect(find.byType(MailDetailScreen), findsOneWidget);
    expect(find.byType(MailPanes), findsNothing);

    // ---- 拖宽回去：折回右栏 ------------------------------------------
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(location(router).path, '/mail/all');
    expect(location(router).queryParameters['sel'], '$emailId');
    expect(location(router).queryParameters['profile'], profile.id);
    expect(find.byType(MailPanes), findsOneWidget);
    expect(find.byType(MailDetailScreen), findsOneWidget);

    // 拆树再推一帧：drift 的流关闭排的是零延时定时器。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  });
}

class _FakeRepo extends Mock implements EmailRepository {}

class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #cancelFor) return Future<void>.value();
    return null;
  }
}

class _UnconfiguredAiSettings extends AiSettingsController {
  @override
  Future<AiSettings> build() async => const AiSettings();
}

/// `SyncController` 真身会拉起整个调度器（20s 时钟 + 平台通道）。
class _FakeSyncController extends SyncController {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  void setActiveProfile(String? profileId) {}
}
