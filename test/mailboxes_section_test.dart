// 这一组钉的是**三条闸门各自的措辞与可见性**（规格 §3）—— 本轮最容易做错的
// 地方。三条闸不能合成一句「你没有权限」：
//
//   实例关掉了添加   → 说「这台实例关闭了添加邮箱」（用户改不了，只能认）
//   账号没权限       → 说「请联系管理员」（能让管理员改）
//   实例没登录       → 说「需要先登录」（用户自己就能解决）
//
// 还有两条「不给按钮」的沉默失败：主邮箱那行**不该**有删除与置顶（服务端会回
// `delMyAccount`），而 `email:send` 为 denied 时**不该**有改名。
//
// **这一组只钉「按钮在不在、点下去打不打出去」，不钉「打开浏览器」那一步。**
//
// 「在网页端添加」走 `launchUrl`，而 `flutter_tester` 里没有平台实现
// （`url_launcher` 每个平台一个包，测试环境一个都没注册），调用它会抛。
// 与其在测试里造一个假的 `UrlLauncherPlatform`，不如把那一步留在真机上验
// —— 本组把断言停在「界面已经切到网页端那条降级路径、且**没有**调
// `/account/add`」，那才是这轮新写的逻辑；`launchUrl` 本身是既有依赖。
//
// 后半段（10 条）补的是**除「添加」以外的四条路**：删除（确认框带地址 /
// 取消不动 / 确认后 remove+refresh+SnackBar）、改名（空串与超长在本地拦下、
// 与旧名相同直接关、正常改名打 `setName` 再 refresh）、profiles 为空时的空态、
// 以及「被删的邮箱正被钉着 → 退回实例级」。这些分支此前 16 条一条都没走到。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/error/app_exception.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/instance_capabilities.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/models/user_info.dart';
import 'package:mail_app/data/models/website_config.dart';
import 'package:mail_app/data/repositories/account_repository.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/config_repository.dart';
import 'package:mail_app/features/mail_list/mailbox_scope.dart';
import 'package:mail_app/features/settings/sections/mailboxes_section.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final zh = lookupAppLocalizations(const Locale('zh'));

  late _Harness h;

  setUp(() async => h = await _Harness.create());
  tearDown(() async => h.dispose());

  /// 一个最小的 `GoRouter`：只挂在 `/mail/:profileId` 一条路由上，页面就是
  /// `MailboxesSection`。
  ///
  /// `_onAction` 的 delete 分支末尾会 `GoRouterState.of(context)` —— 它要求
  /// 上下文里有 `GoRouter`（只有 `MaterialApp(home:)` 时会抛 `GoError`）。
  /// 这个 helper 给那几条用例一个真路由，顺便让 `router.state.uri` 成为
  /// 「当前钉在哪个邮箱上」的可观察量。
  GoRouter mailRouter(String profileId, {int? pinnedAccountId}) => GoRouter(
        initialLocation: Routes.mailOf(profileId, accountId: pinnedAccountId),
        routes: <RouteBase>[
          GoRoute(
            path: '${Routes.mail}/:profileId',
            builder: (context, state) =>
                const Scaffold(body: MailboxesSection()),
          ),
        ],
      );

  // 两个邮箱：主邮箱（sort 3，排第一行）在前，另一个在后。
  const twoMailboxes = <MailboxAccount>[
    MailboxAccount(
      accountId: 3,
      email: 'admin@example.net',
      name: 'admin',
      sort: 3,
    ),
    MailboxAccount(accountId: 8, email: 'kedong@example.net'),
  ];

  group('添加按钮的三条闸门', () {
    testWidgets('perm 齐全 + 站点开着 → 有「添加邮箱」按钮', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );
      expect(find.widgetWithText(TextButton, zh.mailboxAdd), findsOneWidget);
      expect(find.text(zh.mailboxAddDenied), findsNothing);
      expect(find.text(zh.mailboxAddDisabledByServer), findsNothing);
      expect(find.text(zh.mailboxNeedLogin), findsNothing);
    });

    testWidgets('account:add 为 denied → 没有按钮，说明是「没权限，找管理员」',
        (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: const InstanceCapabilities(hasAccountAdd: ProbeState.denied),
        mailboxes: twoMailboxes,
      );
      expect(find.widgetWithText(TextButton, zh.mailboxAdd), findsNothing);
      expect(find.text(zh.mailboxAddDenied), findsOneWidget);
      // 措辞必须是**三句不同的话**，这一条钉的是「没有串味」。
      expect(find.text(zh.mailboxAddDisabledByServer), findsNothing);
      expect(find.text(zh.mailboxNeedLogin), findsNothing);
    });

    testWidgets('站点关掉（addMailboxDisabledByConfig）→ 没有按钮，说明是「实例关掉了」',
        (tester) async {
      // 这两句措辞**必须不同**：一个用户能找管理员解决，另一个找谁都没用。
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: const InstanceCapabilities(
          hasAccountAdd: ProbeState.available,
          addMailboxDisabledByConfig: true,
        ),
        mailboxes: twoMailboxes,
      );
      expect(find.widgetWithText(TextButton, zh.mailboxAdd), findsNothing);
      expect(find.text(zh.mailboxAddDisabledByServer), findsOneWidget);
      expect(find.text(zh.mailboxAddDenied), findsNothing,
          reason: '有权限但实例关掉了，不该说人家没权限');
    });

    testWidgets('实例没登录 → 没有按钮，说明是「先登录」', (tester) async {
      await h.pump(
        tester,
        // 这个实例 `userId == 0`、`email` 为空 → `Profile.isLoggedIn` 为假。
        profile: _Harness.offline,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );
      expect(find.widgetWithText(TextButton, zh.mailboxAdd), findsNothing);
      expect(find.text(zh.mailboxNeedLogin), findsOneWidget);
      expect(find.text(zh.mailboxAddDenied), findsNothing,
          reason: '没登录时不该说「你没权限」—— 用户自己就能解决，而且更可能');
    });
  });

  group('行菜单', () {
    testWidgets('主邮箱那一行：有改名，没有删除与置顶', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );

      await h.openMenu(tester, 3);
      expect(find.text(zh.mailboxRename), findsOneWidget);
      expect(find.text(zh.mailboxPin), findsNothing,
          reason: '服务端 setAsTop 对主邮箱没有意义（它就是排序基准）');
      expect(find.text(zh.delete), findsNothing,
          reason: '服务端会回 delMyAccount —— 我方不该把这个判断全推给服务端');
      // 主邮箱有徽标。
      expect(find.text(zh.mailboxPrimaryBadge), findsOneWidget);
    });

    testWidgets('非主邮箱那一行：改名 + 置顶 + 删除', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );

      await h.openMenu(tester, 8);
      expect(find.text(zh.mailboxRename), findsOneWidget);
      expect(find.text(zh.mailboxPin), findsOneWidget);
      expect(find.text(zh.delete), findsOneWidget);
    });

    testWidgets('email:send 为 denied → 菜单里没有改名', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: const InstanceCapabilities(
          hasAccountRename: ProbeState.denied,
          hasAccountDelete: ProbeState.available,
        ),
        mailboxes: twoMailboxes,
      );

      await h.openMenu(tester, 8);
      expect(find.text(zh.mailboxRename), findsNothing);
      expect(find.text(zh.mailboxPin), findsOneWidget,
          reason: '置顶无权限要求 —— 少了改名的权限不等于少了一切');
    });

    testWidgets('account:delete 为 denied → 没有删除，但置顶还在', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: const InstanceCapabilities(
          hasAccountRename: ProbeState.available,
          hasAccountDelete: ProbeState.denied,
        ),
        mailboxes: twoMailboxes,
      );

      await h.openMenu(tester, 8);
      expect(find.text(zh.delete), findsNothing);
      expect(find.text(zh.mailboxPin), findsOneWidget);
    });
  });

  group('添加表单的本地预校验（对齐服务端顺序）', () {
    testWidgets('空 → 报「格式不正确」，不打接口', (tester) async {
      await h.pump(tester, profile: _Harness.loggedIn, caps: h.addableCaps);
      await h.openAddDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, zh.mailboxAdd));
      await tester.pumpAndSettle();

      expect(find.text(zh.mailboxInvalidAddress), findsOneWidget);
      expect(h.accounts.added, isEmpty, reason: '空串注定被服务端挡，不该走一趟网络');
      expect(find.byType(AlertDialog), findsOneWidget, reason: '对话框不关');
    });

    testWidgets('前缀过短 → 报 `mailboxPrefixTooShort(3)`，不打接口', (tester) async {
      // 夹具把 `minEmailPrefix` 种成 3（线上是 1）。
      await h.pump(tester, profile: _Harness.loggedIn, caps: h.addableCaps);
      await h.openAddDialog(tester);
      await tester.enterText(find.byKey(const ValueKey('mailbox-prefix')), 'ab');
      await tester.tap(find.widgetWithText(FilledButton, zh.mailboxAdd));
      await tester.pumpAndSettle();

      expect(find.text(zh.mailboxPrefixTooShort(3)), findsOneWidget);
      expect(h.accounts.added, isEmpty);
    });

    testWidgets('格式不合法（带空格）→ 报「格式不正确」，不打接口', (tester) async {
      await h.pump(tester, profile: _Harness.loggedIn, caps: h.addableCaps);
      await h.openAddDialog(tester);
      await tester.enterText(
        find.byKey(const ValueKey('mailbox-prefix')),
        'bad prefix',
      );
      await tester.tap(find.widgetWithText(FilledButton, zh.mailboxAdd));
      await tester.pumpAndSettle();

      expect(find.text(zh.mailboxInvalidAddress), findsOneWidget);
      expect(h.accounts.added, isEmpty);
    });

    testWidgets('合法 → 拼成完整地址打出去', (tester) async {
      await h.pump(tester, profile: _Harness.loggedIn, caps: h.addableCaps);
      await h.openAddDialog(tester);
      await tester.enterText(
        find.byKey(const ValueKey('mailbox-prefix')),
        'kedong',
      );
      await tester.tap(find.widgetWithText(FilledButton, zh.mailboxAdd));
      await tester.pumpAndSettle();

      expect(h.accounts.added, <String>['kedong@example.com']);
    });

    testWidgets('domainList 为空 → 换成「完整地址」单框', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        config: const WebsiteConfig(minEmailPrefix: 1),
      );
      await h.openAddDialog(tester);

      expect(find.text(zh.mailboxAddFullAddress), findsOneWidget);
      expect(find.text(zh.mailboxDomainUnavailable), findsOneWidget);
      // **不做「自由后缀输入」**：服务端 `c.env.domain.includes(...)` 会挡，
      // 让用户自己拼一个不在列表里的域名只是把失败往后推一步。
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('mailbox-prefix')),
        'someone@elsewhere.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, zh.mailboxAdd));
      await tester.pumpAndSettle();
      expect(h.accounts.added, <String>['someone@elsewhere.com']);
    });
  });

  group('Turnstile 降级', () {
    testWidgets('needsTurnstile → 主按钮变「在网页端添加」，且不打 /account/add',
        (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        // `addEmailVerify == 0`（OPEN）→ 恒要。
        config: const WebsiteConfig(
          domainList: <String>['@example.com'],
          addEmailVerify: 0,
        ),
      );
      await h.openAddDialog(tester);

      expect(find.text(zh.mailboxAddVerifyRequired), findsOneWidget);
      expect(find.widgetWithText(FilledButton, zh.mailboxOpenWeb), findsOneWidget);
      expect(find.widgetWithText(FilledButton, zh.mailboxAdd), findsNothing);
      // 这里**不点**那个按钮：它会走 `launchUrl`，而 `flutter_tester` 里
      // 没有平台实现（会在 `UrlLauncherPlatform.instance` 上抛）。本组能钉的
      // 是「界面已经切到了降级路径，而那条路径上根本没有 add 这个调用」——
      // 也就是下面这一句，它比「点一下发现没打出去」更强。
      expect(h.accounts.calls, isEmpty);
    });

    testWidgets('服务端回 400 emptyBotToken → 也走同一条降级告示', (tester) async {
      // `addVerifyOpen` 是 per-IP 计数的**快照**，可能已经过期（用户在别的
      // 设备上又加了一个），所以 400 这两条也要兜住，而不是弹一句服务端
      // 的中文原文。
      // 线上向客户端发的是**本地化后**的文案（`turnstile-service.js` →
      // `t('emptyBotToken')`）。判定不看文案、只看 `code == 400`，所以这里
      // 写哪一句都行 —— 写真实的那句是为了让夹具跟线上一致。
      h.accounts.failWith('需要进行人机验证');
      await h.pump(tester, profile: _Harness.loggedIn, caps: h.addableCaps);
      await h.openAddDialog(tester);
      await tester.enterText(
        find.byKey(const ValueKey('mailbox-prefix')),
        'kedong',
      );
      await tester.tap(find.widgetWithText(FilledButton, zh.mailboxAdd));
      await tester.pumpAndSettle();

      expect(find.text(zh.mailboxAddVerifyRequired), findsOneWidget);
      expect(find.widgetWithText(FilledButton, zh.mailboxOpenWeb), findsOneWidget);
      expect(h.accounts.calls, hasLength(1),
          reason: '这一次是服务端说需要验证，我方打了一次就被拦下了');
    });

    testWidgets('服务端回 403 → 按钮降级掉，且能力表被标成 denied', (tester) async {
      h.accounts.failWith('没有权限', code: 403);
      await h.pump(tester, profile: _Harness.loggedIn, caps: h.addableCaps);
      await h.openAddDialog(tester);
      await tester.enterText(
        find.byKey(const ValueKey('mailbox-prefix')),
        'kedong',
      );
      await tester.tap(find.widgetWithText(FilledButton, zh.mailboxAdd));
      await tester.pumpAndSettle();

      // 对话框**不关**：那句「为什么不行」就写在里面（关掉的话用户只看到
      // 一个 SnackBar 一闪而过）。
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(zh.mailboxAddDenied), findsOneWidget);
      expect(
        (await h.capabilities.of(_Harness.loggedIn.id)).hasAccountAdd,
        ProbeState.denied,
      );
    });
  });

  group('删除', () {
    // 删除是**不可逆**的一步，所以这一组钉的是「用户看到的字对不对」与
    // 「取消时到底动没动」。确认框里那句把邮箱地址拼出来 —— 少拼了它，用户
    // 面对的是一个「删除这个邮箱？」而不知道删的是哪一个的框。
    testWidgets('确认框里带邮箱地址（对话框还开着）', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );

      await h.openMenu(tester, 8);
      await tester.tap(find.text(zh.delete));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget,
          reason: '确认框就该停在那儿等一个答复，点了删除不该直接打接口');
      expect(find.text(zh.mailboxRemoveConfirm('kedong@example.net')), findsOneWidget,
          reason: '删错邮箱的代价是那里面全部邮件一起没了，确认框必须指名道姓');
      expect(h.accounts.calls, isEmpty,
          reason: '框还没答，一行都不该动 —— 取消了就什么都不发生');
    });

    testWidgets('取消 → 一行都不动（不打接口、列表那行还在）', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );

      await h.openMenu(tester, 8);
      await tester.tap(find.text(zh.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, zh.cancel));
      await tester.pumpAndSettle();

      // `_confirm` 的 `result ?? false` 一旦写成 `?? true`，点「取消」会
      // 被当成确认 —— 下面两句就会红。这是这一条钉的坏法。
      expect(h.accounts.calls, isEmpty,
          reason: '取消按钮的语义就是「什么都没发生」');
      expect(find.byKey(const ValueKey<int>(8)), findsOneWidget,
          reason: '那一行不该因为点过删除、又取消了就消失');
    });

    testWidgets('确认 → remove + refresh + SnackBar', (tester) async {
      // 这条同时钉着 delete 分支**真的走到底**：它末尾会
      // `GoRouterState.of(context)`，只有真 `GoRouter` 在场时才不抛 ——
      // 库里 `mailboxes_section.dart:363` 那次调用在 `MaterialApp(home:)` 下会
      // 直接抛 `GoError`。所以这里也给一个最小 router。
      final router = mailRouter(_Harness.loggedIn.id);
      addTearDown(router.dispose);

      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
        router: router,
      );

      await h.openMenu(tester, 8);
      await tester.tap(find.text(zh.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, zh.confirm));
      await tester.pumpAndSettle();

      expect(h.accounts.calls, contains('remove:8'));
      // 删完必须重拉：本地那行要等下一轮 `/account/list` 才消失，顺序也以
      // 服务端为准 —— 少了这一步，用户删掉的邮箱会一直留在屏幕上。
      expect(h.accounts.calls, contains('refresh:${_Harness.loggedIn.id}'));
      expect(find.text(zh.mailboxRemoved('kedong@example.net')), findsOneWidget,
          reason: '删成功要给一句回执，不然用户不知道刚才那下生效了没');
    });
  });

  group('改名', () {
    // `_promptName` 的两条本地拦截 + 一条「与旧名相同直接关」。三条都在
    // **打接口之前**拦下 —— 服务端 `setName` 只拦 `length > 30`，空串会真的
    // 写进去，于是 `MailboxAccount.displayName` 退化成邮箱地址，看起来像改坏了。
    testWidgets('空串 → 本地弹 SnackBar，不打接口', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );

      await h.saveRename(tester, 3, text: '');

      expect(find.text(zh.mailboxEmptyName), findsOneWidget);
      expect(h.accounts.calls, isEmpty,
          reason: '空串注定被服务端写坏，不该走一趟网络');
    });

    testWidgets('超 30 字 → 本地弹 SnackBar，不打接口', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );

      await h.saveRename(tester, 3, text: 'x' * 31);

      expect(find.text(zh.mailboxNameTooLong), findsOneWidget);
      expect(h.accounts.calls, isEmpty);
    });

    testWidgets('与旧名相同 → 直接关掉，不打接口', (tester) async {
      // 主邮箱那行 `name` 是 `'admin'`，输入框预填就是它 —— 原样保存等于没改。
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );

      // 不 enterText：输入框预填的就是 `'admin'`。
      await h.saveRename(tester, 3);

      // `if (name == account.name) return;` 一旦被删掉，这里就会多一次
      // `setName:3` + `refresh` —— 一次纯属浪费的往返。
      expect(h.accounts.calls, isEmpty,
          reason: '没改就没改，不必打扰服务端');
      expect(find.byType(AlertDialog), findsNothing,
          reason: '相同也照样把框关掉');
    });

    testWidgets('正常改名 → setName + refresh', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );

      await h.saveRename(tester, 3, text: '新的备注名');

      // 主邮箱的 accountId 是 3。
      expect(h.accounts.calls, contains('setName:3'));
      expect(h.accounts.calls, contains('refresh:${_Harness.loggedIn.id}'),
          reason: '改完要重拉 —— 本地那行 name 只在 refresh 里被整行覆盖');
    });
  });

  group('网络类异常（非 ApiException）不逃逸', () {
    // 这一组钉的是审查者实测出来的两条逃逸面：`AccountRepository` 底层
    // 走 `mapDioException`，离线 / DNS / TLS 抛的是 `NetworkException`、
    // 超时抛 `TimeoutException` —— 它们**都是 `AppException`，却都不是
    // `ApiException`**。只 catch 子类的话：
    //
    //   添加 → `_busy` 永远停在 `true`（转圈不停、取消与确认都点不动）
    //   删除/改名 → 异常直接逃逸，用户点了什么都不发生、也没有一句回执
    //
    // 这两条以前一条测试都没有（`failWith` 造的全是 `ApiException`）。
    testWidgets('添加时抛 NetworkException → 对话框还在、_busy 复位、有错误文案',
        (tester) async {
      h.accounts.failNext(const NetworkException());
      await h.pump(tester, profile: _Harness.loggedIn, caps: h.addableCaps);
      await h.openAddDialog(tester);
      await tester.enterText(
        find.byKey(const ValueKey('mailbox-prefix')),
        'kedong',
      );
      await tester.tap(find.widgetWithText(FilledButton, zh.mailboxAdd));
      await tester.pumpAndSettle();

      // 对话框**不关**：那句「为什么不行」就写在里面。
      expect(find.byType(AlertDialog), findsOneWidget);
      // `NetworkException.userMessage` 是「网络不可用」。
      expect(find.text('网络不可用'), findsOneWidget,
          reason: '失败要给一句人话，不能只有转圈');
      // `_busy` 必须复位：转圈没了，按钮回到可点。
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '只 catch ApiException 时这里会一直转 —— 取消和确认都点不动');
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, zh.mailboxAdd),
      );
      expect(button.onPressed, isNotNull, reason: '复位了才点得动');
      expect(h.accounts.calls, hasLength(1));

      // 「可再点」不是只看 `onPressed` 非空 —— 真的再点一次，这次成功、框关掉。
      await tester.tap(find.widgetWithText(FilledButton, zh.mailboxAdd));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.accounts.added, <String>['kedong@example.com']);
    });

    testWidgets('删除时抛 NetworkException → 有 SnackBar，不是静默', (tester) async {
      h.accounts.failNext(const NetworkException());
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );

      await h.openMenu(tester, 8);
      await tester.tap(find.text(zh.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, zh.confirm));
      await tester.pumpAndSettle();

      expect(h.accounts.calls, contains('remove:8'));
      expect(find.text('网络不可用'), findsOneWidget,
          reason: '删失败必须给回执 —— 只 catch ApiException 时这里一条 SnackBar 都没有，'
              '用户点了删除什么都不发生');
    });

    testWidgets('改名时抛 NetworkException → 有 SnackBar，不是静默', (tester) async {
      h.accounts.failNext(const NetworkException());
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
      );

      await h.saveRename(tester, 3, text: '新的备注名');

      expect(h.accounts.calls, contains('setName:3'));
      expect(find.text('网络不可用'), findsOneWidget,
          reason: '改名失败同样要给回执');
    });
  });

  group('空实例列表', () {
    testWidgets('一个实例都没有 → 显示「添加第一个实例」', (tester) async {
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        profiles: const <Profile>[],
      );

      // 少了这条早退，下面那圈「按实例分组」会渲染成一片空白，用户以为
      // 这一页坏了 —— 而他其实需要的是「去加一个实例」。
      expect(find.text(zh.addFirstInstance), findsOneWidget);
      expect(find.byType(ListTile), findsOneWidget);
    });
  });

  group('被删的邮箱正被钉着', () {
    // 地址里的 `?account=<id>` 是「这一屏钉在哪个邮箱上」的唯一标志。删掉那个
    // 邮箱之后这个 id 不再存在，而列表里**永远**不会再有那一行 —— 不退回
    // 实例级的话，用户看到的是「点了删除，这一屏一直转不出来」。
    //
    // 这一组的 `pump` 用真的 `GoRouter` 当 `home`：`_onAction` 的 delete
    // 分支末尾会 `GoRouterState.of(context)`，在只有 `MaterialApp(home:)` 的
    // 旧夹具下会抛 `GoError`（没有 `GoRouterStateRegistryScope`）。真路由
    // 在场，那条分支才真的走得到。
    testWidgets('删掉钉着的那个 → 退回实例级（地址去掉 account=）', (tester) async {
      final router = mailRouter(_Harness.loggedIn.id, pinnedAccountId: 8);
      addTearDown(router.dispose);
      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
        router: router,
      );
      // 起始地址确实是「钉在 8 上」那条 —— 否则下面断言的就是个空条件。
      expect(pinnedMailboxOf(router.state.uri)?.accountId, 8);

      await h.openMenu(tester, 8);
      await tester.tap(find.text(zh.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, zh.confirm));
      await tester.pumpAndSettle();

      final after = router.state.uri;
      expect(after.path, '/mail/${_Harness.loggedIn.id}');
      expect(after.queryParameters.containsKey(Routes.accountParam), isFalse,
          reason: '不退回去的话这一屏会永远停在一条加载不出来的列表上');
    });

    testWidgets('删掉的是别的邮箱 → 地址不动（不该顺手把钉住的那屏拆掉）',
        (tester) async {
      // accountId 8 的邮箱没被钉住（钉的是 999）—— 删它不该改变 `?account=`。
      final router = mailRouter(_Harness.loggedIn.id, pinnedAccountId: 999);
      addTearDown(router.dispose);

      await h.pump(
        tester,
        profile: _Harness.loggedIn,
        caps: h.addableCaps,
        mailboxes: twoMailboxes,
        router: router,
      );

      await h.openMenu(tester, 8);
      await tester.tap(find.text(zh.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, zh.confirm));
      await tester.pumpAndSettle();

      expect(
        router.state.uri.queryParameters[Routes.accountParam],
        '999',
        reason: '现解析的判据要真对上 id 才退，不能一删就无条件退',
      );
    });
  });
}

class _Harness {
  _Harness._({
    required this.db,
    required this.prefs,
    required this.capabilities,
    required this.configs,
    required this.accounts,
    required this.authEvents,
  });

  static Future<_Harness> create() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final authEvents = AuthEvents();
    final capabilities = CapabilityRepository(db);

    // 两个实例行**直接写库**（不用 `ProfileRepository.create` —— 它要求
    // 一个 baseUrl，而这里要的正是一个「还没配好」的离线 profile）。
    // `profilesProvider` 下面是被 override 成固定值的假流，界面读的一直是
    // 注入进去的那个 `Profile` 对象；写库只是让夹具与真实形态一致。
    await db.profileDao.upsertProfile(offline);
    await db.profileDao.upsertProfile(loggedIn);

    final registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: TokenStore(),
      prefs: prefs,
      // 这一组**永远不该建 runtime**（不该有任何真请求）；真被调到了，
      // 直接在那一行抛，比一个假的 200 更容易定位。
      buildApiDio: (_) => throw UnsupportedError('这一组用例不打网络'),
    );

    return _Harness._(
      db: db,
      prefs: prefs,
      capabilities: capabilities,
      configs: ConfigRepository(
        registry: registry,
        capabilities: capabilities,
      ),
      accounts: _RecordingAccounts(
        db: db,
        registry: registry,
        capabilities: capabilities,
      ),
      authEvents: authEvents,
    );
  }

  final AppDatabase db;
  final PrefsStore prefs;
  final CapabilityRepository capabilities;
  final ConfigRepository configs;
  final _RecordingAccounts accounts;
  final AuthEvents authEvents;

  /// 已登录的实例：perm 三项齐全、站点开着。
  ///
  /// **`hasAccountAdd` 必须是 `available`** —— `accountAddEnabled` 用的是
  /// `== ProbeState.available`（`unknown` 时不给按钮），光「站点开着」是不够的。
  static const Profile loggedIn = Profile(
    id: 'pnb:inst',
    baseUrl: 'https://mail.example.net',
    userId: 42,
    email: 'admin@example.net',
    userName: 'admin',
  );

  /// 没登录过的实例（`userId == 0`、`email` 为空 → `isLoggedIn == false`）。
  static const Profile offline = Profile(
    id: 'pnb:offline',
    baseUrl: 'https://mail.example.net',
  );

  InstanceCapabilities get addableCaps => const InstanceCapabilities(
        hasAccountAdd: ProbeState.available,
        hasAccountDelete: ProbeState.available,
        hasAccountRename: ProbeState.available,
      );

  static const List<MailboxAccount> defaultMailboxes = <MailboxAccount>[
    // 本地的 `sort DESC, accountId ASC` 把主邮箱排在**第一行**。
    MailboxAccount(
      accountId: 3,
      email: 'admin@example.net',
      name: 'admin',
      sort: 3,
    ),
  ];

  Future<void> pump(
    WidgetTester tester, {
    required Profile profile,
    required InstanceCapabilities caps,
    List<MailboxAccount> mailboxes = defaultMailboxes,
    WebsiteConfig? config,
    // 空实例列表那条早退（`profiles.isEmpty`）得能真的走到 —— 所以让整张
    // 列表可换，默认仍是「就这一个实例」。
    List<Profile>? profiles,
    // 钉住的那个邮箱被删时要 `GoRouterState.of(context)`（它要求上下文里有
    // `GoRouter`）。只有那几条用例需要真路由，其余维持最薄的 `home:`。
    GoRouter? router,
  }) async {
    // 表单的域名单/阈值走 `ConfigRepository.peek`（**同步**读内存缓存）——
    // `seed` 是它的公开入口，正好让这一组用例不必打网络。
    configs.seed(
      profile.id,
      config ??
          const WebsiteConfig(
            domainList: <String>['@example.com'],
            minEmailPrefix: 3,
          ),
    );

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        databaseProvider.overrideWithValue(db),
        prefsStoreProvider.overrideWithValue(prefs),
        capabilityRepositoryProvider.overrideWithValue(capabilities),
        configRepositoryProvider.overrideWithValue(configs),
        accountRepositoryProvider.overrideWithValue(accounts),
        profilesProvider.overrideWith(
          (ref) => Stream<List<Profile>>.value(
            profiles ?? <Profile>[profile],
          ),
        ),
        mailboxesProvider.overrideWith(
          (ref, String id) => Stream<List<MailboxAccount>>.value(mailboxes),
        ),
        capabilitiesProvider.overrideWith(
          (ref, String id) => Stream<InstanceCapabilities>.value(caps),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        // 有 router 时把它当作 `home`（`MaterialApp.router` 每个用例要搭一整套
        // `RouterDelegate`，这里只需要 `GoRouter` 在场）。
        home: router == null
            ? const Scaffold(body: MailboxesSection())
            : Router.withConfig(config: router),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 点开某个邮箱那一行的弹出菜单。
  ///
  /// **按 `accountId` 定位**（`_MailboxTile` 上的 `ValueKey<int>`），不按邮箱
  /// 文字找 —— 组头里的实例名与副标题用的也是同一个地址串（`Profile.displayName`
  /// 与 `Profile.subtitle` 在没有备注名时都会退回 email），按文字找会撞上多个。
  Future<void> openMenu(WidgetTester tester, int accountId) async {
    final row = find.byKey(ValueKey<int>(accountId));
    await tester.tap(
      find.descendant(of: row, matching: find.byType(PopupMenuButton<String>)),
    );
    await tester.pumpAndSettle();
  }

  /// 点组头那个「添加邮箱」。
  Future<void> openAddDialog(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(
      TextButton,
      lookupAppLocalizations(const Locale('zh')).mailboxAdd,
    ));
    await tester.pumpAndSettle();
  }

  /// 打开某个邮箱的改名框，可选地改文本，然后点「保存」。
  Future<void> saveRename(
    WidgetTester tester,
    int accountId, {
    String? text,
  }) async {
    final zh = lookupAppLocalizations(const Locale('zh'));
    await openMenu(tester, accountId);
    await tester.tap(find.text(zh.mailboxRename));
    await tester.pumpAndSettle();
    if (text != null) {
      await tester.enterText(find.byType(TextField), text);
    }
    await tester.tap(find.widgetWithText(FilledButton, zh.save));
    await tester.pumpAndSettle();
  }

  Future<void> dispose() async {
    await authEvents.dispose();
    await db.close();
  }
}

class _RecordingAccounts extends AccountRepository {
  _RecordingAccounts({
    required super.db,
    required super.registry,
    required super.capabilities,
  });

  /// **每一次**调用都记一笔（不管成功还是被 `failWith` 拦下）——
  /// 「该不打的时候一次都没打」正是这一组最要紧的几条断言。
  final List<String> calls = <String>[];

  /// 真的走完了的添加（用来钉「拼出来的完整地址对不对」）。
  final List<String> added = <String>[];
  String? _failure;
  int _failureCode = 400;

  /// 让下一次写操作抛一个**非 `ApiException`** 的 `AppException`
  /// （`NetworkException` / `TimeoutException` / `ServerException` …）。
  ///
  /// `failWith` 只会造 `ApiException`，而「只 catch 到 `ApiException`」这个
  /// 逃逸面的要害正在于**不是** `ApiException` 的那些子类 —— 夹具得能造它们，
  /// 那两条例外路径才测得到（见文件末尾「网络类异常」那一组）。
  AppException? _failureException;

  /// 让下一次 add / remove / setName / setAsTop 抛这个异常（一次性）。
  void failNext(AppException e) => _failureException = e;

  /// 记录调用之后、真正干活之前：该抛就抛。
  void _maybeThrow() {
    final e = _failureException;
    if (e != null) {
      _failureException = null;
      throw e;
    }
  }

  /// 让下一次 `add` 抛一个 `ApiException`。[message] 就是服务端那一句 ——
  /// 线上向客户端发的是 i18n **后的文案**（「需要进行人机验证」），
  /// 不是 `emptyBotToken` 这个 key；所以实现里判定的是 `code == 400`。
  void failWith(String message, {int code = 400}) {
    _failure = message;
    _failureCode = code;
  }

  @override
  Future<MailboxAccount?> add(
    Profile profile,
    String email, {
    String? turnstileToken,
  }) async {
    calls.add('add:$email');
    _maybeThrow();
    final failure = _failure;
    if (failure != null) {
      _failure = null;
      throw ApiException(code: _failureCode, message: failure);
    }
    added.add(email);
    return MailboxAccount(accountId: 999, email: email);
  }

  @override
  Future<void> remove(Profile profile, int accountId) async {
    calls.add('remove:$accountId');
    _maybeThrow();
  }

  @override
  Future<void> setName(Profile profile, int accountId, String name) async {
    calls.add('setName:$accountId');
    _maybeThrow();
  }

  @override
  Future<void> setAsTop(Profile profile, int accountId) async {
    calls.add('setAsTop:$accountId');
    _maybeThrow();
  }

  /// 删除 / 改名之后必须重拉一次。**父类那一版会走 `registry.peek` 拿 runtime，
  /// 而本夹具的 registry 一被问到就 `throw`** —— 所以这里必须覆盖成只记一笔的
  /// 空实现，否则那条「删完要 refresh」的路径会以「不打网络」的假象炸掉。
  ///
  /// 返回值给**空列表**：本组的 `mailboxesProvider` 是固定的假流，界面读的
  /// 一直是注入进去的那个列表，不看这个返回值。
  @override
  Future<List<MailboxAccount>> refresh(
    Profile profile, {
    UserInfo? fallback,
    bool wipeMissing = true,
  }) async {
    calls.add('refresh:${profile.id}');
    return const <MailboxAccount>[];
  }
}
