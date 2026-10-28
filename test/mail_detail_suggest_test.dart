import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/attachment_cache.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/mail_detail/mail_detail_screen.dart';
import 'package:mail_app/features/mail_list/mail_panes.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 清附件目录那一步的空实现：本组用例只关心「删完之后的收尾」，不碰盘。
class _NoopAttachmentCache extends AttachmentCache {
  @override
  Future<void> deleteMail(String profileId, int emailId) async {}
}

/// 打开详情时会顺手撤掉这条通知（见 `mail_detail_screen.dart` 的 `_openOnce`）。
/// 测试里那会真的去建平台插件、失败一次、在日志里留一行与本题无关的话。
/// 换成空实现。形状照 `test/mail_detail_header_test.dart` 的 `_SilentNotifications`。
class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #cancelFor) return Future<void>.value();
    return null;
  }
}

/// 一份「配得上 AI」的设置（形状照 `test/ai_reply_test.dart`）。
class _UsableAiSettings extends AiSettingsController {
  _UsableAiSettings({this.suggestEnabled = true});

  final bool suggestEnabled;

  @override
  Future<AiSettings> build() async => AiSettings(
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
        hasApiKey: true,
        mailSuggestEnabled: suggestEnabled,
      );
}

/// 还没配 AI。
class _UnconfiguredAiSettings extends AiSettingsController {
  @override
  Future<AiSettings> build() async => const AiSettings();
}

/// `AiService` 不是接口，但 mocktail 能按接口实现它 —— 面板与 `SuggestFlow`
/// 只碰 `suggest` 这一个方法，别的一律不碰（碰了就会得到 `MissingStubError`，
/// 那正是我们要的信号）。形状照 `test/suggest_flow_test.dart` 的 `_FakeAi`。
class _FakeAi extends Mock implements AiService {}

/// **还没读到**那一个态（异步 provider 的 `value == null`）。
///
/// 用一个永不完成的 future 造出来，而不是「不覆盖、跑真身」—— 真身的
/// `build` 会去读钥匙串（平台通道），那个调用即使在测试里不报错，也会在
/// 用例结束之后才失败，留一句与本题无关的话。
class _PendingAiSettings extends AiSettingsController {
  @override
  Future<AiSettings> build() => Completer<AiSettings>().future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profileId = 'p1';
  const emailId = 12;
  final icon = find.byKey(const ValueKey<String>('ai-suggest-detail'));

  MailRow mail({bool send = false}) => MailRow(
        emailId: emailId,
        profileId: profileId,
        name: '发件人',
        sendEmail: 'from@x.com',
        subject: '一封邮件',
        text: '正文',
        content: '<p>正文</p>',
        hasFullBody: true,
        type: send ? MailType.send : MailType.receive,
        createTime: DateTime(2026, 1, 2, 3, 4),
      );

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// 删邮件会顺手清磁盘上的附件目录（`EmailRepository.onDiskPurge`）。
  /// 这一组是 widget 测试，跑在 fake async 里 —— 真文件 I/O 的 future 在这里
  /// **永远等不到**（`path_provider` 那条平台通道同理会一直挂着），删除就停在
  /// 「清磁盘」那一步，`onDeleted` 不调，表现正是「点了确定、删不掉」。
  /// 磁盘清理由 `email_delete_disk_test.dart` 用真临时目录覆盖（普通
  /// `test()`，没有 fake async）。
  AttachmentCache noopAttachmentCache() => _NoopAttachmentCache();

  Future<void> pumpDetail(
    WidgetTester tester,
    MailRow row, {
    AiSettingsController Function()? settings,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.mailDao.upsertPage(<MailRow>[row]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        bootstrapProvider.overrideWithValue(BootstrapData(
          db: db,
          tokens: TokenStore(),
          prefs: PrefsStore(await SharedPreferences.getInstance()),
        )),
        notificationServiceProvider.overrideWithValue(_SilentNotifications()),
        attachmentCacheProvider.overrideWithValue(noopAttachmentCache()),
        if (settings != null) aiSettingsProvider.overrideWith(settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const MailDetailScreen(profileId: profileId, emailId: emailId),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 拆树并把时钟推一帧（drift 的流关闭排的是零延时定时器）。
  /// **断言要在它之前** —— 空树上什么都找不到。
  Future<void> disposeDetail(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  testWidgets('三个条件都满足：那颗图标在顶栏，且在**转发之后、星标之前**',
      (tester) async {
    await pumpDetail(tester, mail(), settings: _UsableAiSettings.new);

    expect(icon, findsOneWidget);
    // 位置：转发那颗在它左边，星标那颗在它右边。用 `AppBar.actions` 里的
    // 次序断，而不是断像素坐标 —— 坐标会随图标尺寸与内边距漂。
    final bar = find.byType(AppBar);
    expect(bar, findsOneWidget);
    final buttons = tester
        .widgetList<IconButton>(find.descendant(of: bar, matching: find.byType(IconButton)))
        .toList();
    final suggestAt =
        buttons.indexWhere((b) => b.key == const ValueKey('ai-suggest-detail'));
    expect(suggestAt, greaterThan(0), reason: '回复 / 转发在它前面');
    expect(
      suggestAt,
      lessThan(buttons.length - 1),
      reason: '星标那一颗在它后面（位置的理由见 spec §8.2）',
    );
    // 它**不在**那个 ⋯ 菜单里（那里是无条件的两项固定项）
    expect(
      find.descendant(
        of: find.byType(PopupMenuButton<String>),
        matching: icon,
      ),
      findsNothing,
    );

    await disposeDetail(tester);
  });

  testWidgets('① 已发送方向：不画', (tester) async {
    await pumpDetail(tester, mail(send: true), settings: _UsableAiSettings.new);
    expect(icon, findsNothing);
    await disposeDetail(tester);
  });

  testWidgets('② 没配 AI（还没读到 / 缺 Key / 缺模型）：不画', (tester) async {
    await pumpDetail(tester, mail(), settings: _UnconfiguredAiSettings.new);
    expect(icon, findsNothing, reason: '点了只会弹一句「去设置里填」');
    await disposeDetail(tester);
  });

  testWidgets('②「还没读到」也不画（异步 provider 的 null 态）', (tester) async {
    await pumpDetail(tester, mail(), settings: _PendingAiSettings.new);
    expect(
      icon,
      findsNothing,
      reason: '还没读到就说「能用」，会在冷启动那几帧里闪一颗点了没反应的图标',
    );
    await disposeDetail(tester);
  });

  testWidgets('③ 设置里关掉了：不画', (tester) async {
    await pumpDetail(
      tester,
      mail(),
      settings: () => _UsableAiSettings(suggestEnabled: false),
    );
    expect(icon, findsNothing);
    await disposeDetail(tester);
  });

  testWidgets('对照组：有那三个条件之外的东西挡着也不影响 —— 转发那颗照旧在',
      (tester) async {
    await pumpDetail(tester, mail(), settings: _UsableAiSettings.new);
    expect(find.byTooltip('转发'), findsOneWidget,
        reason: '前提：动作区确实画出来了（证明上面那些 findsNothing 是真的没有，'
            '而不是整个动作区塌了）');
    await disposeDetail(tester);
  });

  // ------------------------------------------------- 「AI 建议删除」之后的收尾
  //
  // 这一组守的是一个**只在两个入口之间才看得出来**的差别：
  // `MailActionRunner._delete` 执行完只调 `onDeleted`（它不 pop，因为它不知道
  // 自己在哪种宿主里）。详情页那颗 AI 图标从前**没传**这个回调，于是删掉之后
  // `mailDetailProvider` 推出 `null`，本页落进 `row == null` 那一支 ——
  // 屏幕上是一个**永远转下去**的圈。同一个删除从 ⋯ 菜单点是好使的，所以这
  // 属于「同一个动作两个入口行为不一样」，不写用例根本发现不了（它不报错）。

  /// 面板要的那些回调都在 `SuggestFlow.open` 里就地接的
  /// （生产路径**不注入** opener），所以这一组要真的把面板开起来、点那一项。
  const deleteJson =
      '{"summary":"广告","actions":[{"action":"delete","reason":"广告"}]}';

  AiStart deleteStart() => AiStarted(AiStream(
        text: Stream<String>.value(deleteJson),
        done: Future<String>.value(deleteJson),
        cancel: () {},
      ));

  /// **绝不 `pumpAndSettle` 面板那几帧**：面板里跑着
  /// `CircularProgressIndicator`（永不结束的动画），`pumpAndSettle` 会一直等到
  /// `timed out` 而不是让某条断言失败 —— 与 `test/suggest_panel_test.dart`
  /// 的第一段注释逐字同一个理由。两下 400ms 覆盖了底部弹窗那 250ms 的动画。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 点开 AI 图标 → 等面板出结果 → 点「删除」→ 确认。
  Future<void> suggestDelete(WidgetTester tester) async {
    await tester.tap(icon);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-suggest-choice-delete')));
    await settle(tester);
    // `_confirm` 那个对话框：确认键是 `FilledButton`，文案 l10n.confirm = 确定。
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await settle(tester);
  }

  testWidgets('整页形态：从 AI 面板删掉之后**回到列表**，不是停在一个转圈上',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.mailDao.upsertPage(<MailRow>[mail()]);
    final ai = _FakeAi();
    when(() => ai.suggest(
          input: any(named: 'input'),
          actionIds: any(named: 'actionIds'),
        )).thenAnswer((_) async => deleteStart());

    final router = GoRouter(
      initialLocation: '/list',
      routes: <RouteBase>[
        GoRoute(
          path: '/list',
          builder: (context, state) => Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => ElevatedButton(
                  key: const ValueKey('open-detail'),
                  onPressed: () => context.push('/detail'),
                  child: const Text('列表页'),
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/detail',
          builder: (context, state) =>
              const MailDetailScreen(profileId: profileId, emailId: emailId),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        bootstrapProvider.overrideWithValue(BootstrapData(
          db: db,
          tokens: TokenStore(),
          prefs: PrefsStore(await SharedPreferences.getInstance()),
        )),
        notificationServiceProvider.overrideWithValue(_SilentNotifications()),
        attachmentCacheProvider.overrideWithValue(noopAttachmentCache()),
        aiServiceProvider.overrideWithValue(ai),
        aiSettingsProvider.overrideWith(_UsableAiSettings.new),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        routerConfig: router,
      ),
    ));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('open-detail')));
    await settle(tester);
    expect(icon, findsOneWidget, reason: '前提：详情页开了、AI 那颗在');

    await suggestDelete(tester);

    // 关键：**detail 那一页没了**，回到列表。
    expect(find.text('列表页'), findsOneWidget);
    expect(find.byType(MailDetailScreen), findsNothing,
        reason: '删完还停在那一页上就是那个「永远转下去」的圈');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 前提自查：信真的被删了（不是「什么都没发生所以也没 pop」）。
    expect(await db.mailDao.find(profileId, emailId), isNull);

    // **收树必须在这里做，不能留给自动 teardown**：`ProviderScope` 被拆时
    // `ProviderContainer.dispose` 会挨个 dispose 流 provider，drift 那边给
    // 「流关闭」排的是**零延时定时器**。自动 teardown 拆树的那一刻正是
    // `testWidgets` 查「还有没有活着的定时器」的那一刻 —— 于是报一句
    // 「A Timer is still pending」，而这句与本用例要验的东西毫无关系。
    // （同一文件里另外六条都靠这一句收尾，所以它们是绿的。）
    await disposeDetail(tester);
  });

  testWidgets('内嵌形态（宽屏右栏）：从 AI 面板删掉之后**把选中清掉**',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.mailDao.upsertPage(<MailRow>[mail()]);
    final ai = _FakeAi();
    when(() => ai.suggest(
          input: any(named: 'input'),
          actionIds: any(named: 'actionIds'),
        )).thenAnswer((_) async => deleteStart());

    var closed = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bootstrapProvider.overrideWithValue(BootstrapData(
          db: db,
          tokens: TokenStore(),
          prefs: PrefsStore(await SharedPreferences.getInstance()),
        )),
        notificationServiceProvider.overrideWithValue(_SilentNotifications()),
        attachmentCacheProvider.overrideWithValue(noopAttachmentCache()),
        aiServiceProvider.overrideWithValue(ai),
        aiSettingsProvider.overrideWith(_UsableAiSettings.new),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: MailPanes(
            selected: const MailRef(profileId: profileId, emailId: emailId),
            onClosed: () => closed++,
            list: const SizedBox.shrink(),
          ),
        ),
      ),
    ));
    await settle(tester);
    expect(icon, findsOneWidget, reason: '前提：右栏开着、AI 那颗在');

    await suggestDelete(tester);

    expect(closed, 1,
        reason: '内嵌时右栏没有可 pop 的东西 —— 不收尾就停在那个圈上');
    await disposeDetail(tester);
  });
}
