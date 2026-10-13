// 写邮件页那一层的两个键：`Esc` 与 `Cmd/Ctrl+Enter`。
//
// 三件事在这里被钉住：
//
// 1. **Esc = 退出 + 自动存草稿**（需求原文：「esc 推出并自动保存」）。它走的必须
//    就是 `X` 按钮那条出口（`_leave()`：`_flushBody()` → `saveDraftOnExit()` →
//    `pop()`）—— 少任何一步，用户最后那几个字（250 ms 防抖还没烧完的）
//    就既进不了草稿也去不了别处。E1 正是拿「防抖窗口里按 Esc」来验的。
// 2. **`state.busy` 时 Esc 什么都不做**（E3）：发送是一条已经发出的请求，
//    从它底下把页面抽走只会让用户既看不到结果、也不知道信去哪了。
// 3. **焦点在正文（quill）里时 Esc 同样要能退出**（E2）—— 这一条**不是**
//    页面那层 `Shortcuts` 能办到的：quill 自己无条件绑了
//    `escape → HideSelectionToolbarIntent`（`default_single_activator_intents.dart:14`），
//    而它在焦点树上比页面那层近，Esc 在正文里被它吃掉。所以 E2 要等
//    `MailQuillEditor.onKeyPressed`（Task 6）—— 在本任务里它是**红的**。
//
// 这里**不读系统剪贴板**（`Clipboard.getData` 在 flutter_tester 里永不完成，
// 见 Task 8 的注释）；也不碰 `handlePopRoute`（那是 `compose_exit_paths_test`
// 的地盘，那一组验的是系统返回手势，与键盘是两条不同的路）。
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/instance_capabilities.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/models/send_payload.dart';
import 'package:mail_app/data/repositories/send_repository.dart';
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/features/shortcuts/shortcut_host.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Profile _profileA = Profile(
  id: 'p1',
  baseUrl: 'https://a.example/api',
  email: 'me@a.example',
  userName: '甲',
  userId: 7,
);

const MailboxAccount _boxA3 = MailboxAccount(
  accountId: 3,
  email: 'me@a.example',
  name: '甲',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // `any()` 碰上自定义类型要先登记一个占位值，mocktail 的老规矩
    // （与 `suggest_flow_test.dart` 同一句）。E3 那份假仓储的签名里有
    // `SendPayload`。
    registerFallbackValue(
      SendPayload(accountId: 0, sendEmail: '', recipients: const <String>[]),
    );
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    // 「发送前检查」默认**开着**，而它会为任何非空正文弹一个底部面板
    // （`_maybePreflight`）—— 键盘用例不该被它拦住。这一条把本地那份设置写成
    // `preflight: false`，比覆盖 `aiSettingsProvider` 少一层间接
    // （`AiSettingsCodec.decode` 只认 `preflight` 这个键，其余走默认）。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cm_ai_settings': jsonEncode(<String, Object>{'preflight': false}),
    });
  });

  /// 把写邮件页**推**进导航栈（而不是当 `home:`）：Esc 那条路最后要 `pop`，
  /// 它必须是能被弹掉的那一层。
  ///
  /// [send] 给出时用它替换发信仓储（E3 要一个「永远发不完」的发送）。
  /// [sendDelaySeconds] 写进 prefs —— 0 = 直发，省略 = 默认的 60 秒（入队）。
  Future<ProviderContainer> pumpCompose(
    WidgetTester tester,
    AppDatabase db, {
    ComposeArgs args = const ComposeArgs(),
    SendRepository Function(AppDatabase db, PrefsStore prefs)? send,
    int? sendDelaySeconds,
  }) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    if (sendDelaySeconds != null) {
      await prefs.setSendDelay(Duration(seconds: sendDelaySeconds));
    }
    final container = ProviderContainer.test(
      overrides: [
        // `bootstrapProvider` 也要给：控制器的 `refreshQuota()` 会读
        // `runtimeProvider` → `runtimeRegistryProvider` → `tokenStoreProvider`
        // → `bootstrapProvider`。只 override `databaseProvider` / `prefsStoreProvider`
        // 的话那条链会在半路上撞见「必须被 override」那个 StateError。
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        prefsStoreProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        currentProfileIdProvider.overrideWithValue('p1'),
        // 有了实例 + 邮箱才有发件人；有了发件人 `canSendNow` 才可能为真
        // （`sendDisabledReason`/`sendMailActivator` 那条线上的前提）。
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[_profileA]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) =>
              Stream.value(const <MailboxAccount>[_boxA3]),
        ),
        capabilitiesProvider.overrideWith(
          (ref, profileId) => Stream.value(const InstanceCapabilities()),
        ),
        if (send != null)
          sendRepositoryProvider.overrideWithValue(send(db, prefs)),
      ],
    );
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          // 宿主层要挂上：`Cmd/Ctrl+Enter` 的**激活器**在它那张表里
          // （`mailShortcutsFor`），写邮件页只挂 `SendMailIntent` 的 Action。
          // 少了这一层，`Ctrl+Enter` 在用例里按下去什么都不会发生 ——
          // 与真机上表现不同，而这种「测试里缺一层」最容易把活的功能测成死的。
          builder: (context, child) =>
              MailShortcutHost(child: child ?? const SizedBox.shrink()),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => ComposeScreen(args: args)),
    );
    await tester.pumpAndSettle();
    // 发件人是从 drift 流里递进来的（第一帧还没有），等它到位再断言 ——
    // E4 那条要 `canSendNow` 为真才发得出去。
    await tester.pump();
    return container;
  }

  /// 按一次 Esc。
  Future<void> pressEsc(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  /// 按一次 `Ctrl + Enter`（mac 上那一支是 `Command`，同一张表的另一个分支）。
  Future<void> pressSend(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// 读出库里所有草稿（整行 —— 主题与正文在两列里，只取 `content` 会让
  /// 「主题存下来了没有」这条断言看起来在验正文）。
  ///
  /// **用 `select().get()` 而不是 `watchDrafts(...).first`** —— 后者是流查询，
  /// drift 在订阅结束时留一个保活计时器，假时钟不推它，`db.close()` 再也回不来
  /// （见 `compose_exit_paths_test.dart` 里同一句注释）。
  Future<List<DbDraft>> storedDrafts(AppDatabase db) => db.select(db.drafts).get();

  /// 主题栏那个 `TextField`。**按位置取**：`Column` 的顺序是收件人、主题，
  /// 而发件人那一行在没有候选时不是 `TextField`（它是个 `SenderField`）。
  Finder subjectField() => find.byType(TextField).at(1);

  testWidgets('E1 焦点在主题栏按 Esc：页面弹掉，且防抖里那几个字进了草稿',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await pumpCompose(tester, db);
    expect(find.byType(ComposeScreen), findsOneWidget, reason: '前提：页面在');

    // 正文里打一句，**只推一帧** —— 250 ms 的防抖没烧完，这正是要复现的窗口。
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    editor.controller.replaceText(
      0,
      0,
      '最后一句',
      const TextSelection.collapsed(offset: 4),
    );
    await tester.pump(const Duration(milliseconds: 16));

    // 焦点换到主题栏（普通输入框）。Esc 要能从这里到页面那层 `Shortcuts`。
    await tester.enterText(subjectField(), '主题');
    await tester.pump();

    await pressEsc(tester);

    expect(
      find.byType(ComposeScreen),
      findsNothing,
      reason: 'Esc 就是「离开这一页」—— 与 X 按钮同一个出口',
    );
    final drafts = await storedDrafts(db);
    expect(drafts, hasLength(1), reason: '「离开页面一律存草稿」这条承诺对 Esc 同样成立');
    expect(
      drafts.single.content,
      contains('最后一句'),
      reason: '防抖没烧完的正文必须由 `_flushBody()` 补上 —— '
          '少了它，用户最后打的那一句既不在 state 也不在草稿里',
    );
    expect(
      drafts.single.subject,
      '主题',
      reason: '主题栏也算「打过的东西」—— `saveDraftOnExit` 的 `wroteSomething` '
          '里三项都会让它成立，存的时候当然也要一起存',
    );
    await db.close();
  });

  testWidgets('E3 发送中按 Esc：页面**还在**（不能从发送流程底下抽走）',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    const args = ComposeArgs();
    final container = await pumpCompose(
      tester,
      db,
      args: args,
      send: _hangingSend,
      // 直发那一支才会 `busy = true` 等网络；入队是本地落库、瞬间完成。
      sendDelaySeconds: 0,
    );

    // 凑一封「能发出去」的信：收件人 + 正文。
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    editor.controller.replaceText(
      0,
      0,
      '正文',
      const TextSelection.collapsed(offset: 2),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField).first, 'to@b.example,');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // **前提先钉住**：没有这一条，「页面还在」可能只是因为它压根没开始发 ——
    // 那样这条用例测的是「点发送没反应」，与 Esc 无关。
    expect(
      container.read(composeControllerProvider(args)).busy,
      isTrue,
      reason: '前提：请求已经发出去了（假仓储那条 future 永远不完成）',
    );

    await pressEsc(tester);

    expect(
      find.byType(ComposeScreen),
      findsOneWidget,
      reason: '这一封已经在网上了 —— 抽走页面等于让用户看不到结果',
    );
    await db.close();
  });

  testWidgets('E2 焦点在正文（quill）里按 Esc：同样退出（走 onKeyPressed）',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await pumpCompose(tester, db);

    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    editor.controller.replaceText(
      0,
      0,
      '正文',
      const TextSelection.collapsed(offset: 2),
    );
    await tester.pump(const Duration(milliseconds: 400));
    editor.focusNode.requestFocus();
    await tester.pump();

    await pressEsc(tester);

    expect(
      find.byType(ComposeScreen),
      findsNothing,
      reason: '光标在正文里是最常见的状态 —— 这里按 Esc 没反应等于这个功能不存在。'
          'quill 自己的 `Shortcuts` 无条件吃了 escape，只有 `onKeyPressed` 挡得住',
    );
    expect((await storedDrafts(db)).single.content, contains('正文'));
    await db.close();
  });

  testWidgets('Ctrl+Enter 发送：与「发送」按钮同一件事（信进了发件箱队列）',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await pumpCompose(tester, db);

    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    editor.controller.replaceText(
      0,
      0,
      '正文',
      const TextSelection.collapsed(offset: 2),
    );
    await tester.pump(const Duration(milliseconds: 400));
    // 收件人：用 `enterText` 打进去但**不回车**（`effectiveRecipients` 会把
    // 输入框里那半截也算上）。焦点随后挪到主题栏 —— 光标留在收件人输入框里
    // 的话，`Enter` 会被 `RecipientField._onKey` 先吃掉（那是「提交这个地址」
    // 的快捷键），`Ctrl+Enter` 跟着一起在里面没了。
    await tester.enterText(find.byType(TextField).first, 'to@b.example,');
    await tester.pump();
    await tester.enterText(subjectField(), '主题');
    await tester.pump();

    await pressSend(tester);

    final outbox = await db.select(db.outboxEntries).get();
    expect(outbox, hasLength(1), reason: '默认延迟不为 0 → 入队（「后悔窗口」）');
    final payload = SendRepository.decodePayload(outbox.single.payloadJson)!;
    expect(payload.recipients, contains('to@b.example'));
    expect(payload.content, contains('正文'));
    expect(
      find.byType(ComposeScreen),
      findsNothing,
      reason: '发送成功的收尾是「先 pop、再把提示弹到下一屏去」（见 `_scheduleNotice`）',
    );
    await db.close();
  });
}

/// 一个「永远发不完」的发信仓储。
///
/// E3 要的正是 `state.busy == true` 的那一刻，而真的 `SendRepository` 在测试里
/// 根本到不了 `_sendDirect` 就失败了（没有 runtime → `NetworkException`，
/// 一瞬间就 `busy=false`）。把 `sendNow` 换成一条永不完成的 future，
/// 那个窗口就稳稳地留在那儿。
///
/// 用 `Mock implements SendRepository` 而不是 `extends`：真构造函数要凑齐
/// registry / profiles / emails 三件套，而这一组**只碰 `sendNow` 这一个方法**
/// （发送链路里其余落库动作走的是 `localDao`，与仓储无关）。
class _HangingSend extends Mock implements SendRepository {}

/// 让它永远「正在发」。
SendRepository _hangingSend(AppDatabase db, PrefsStore prefs) {
  final repo = _HangingSend();
  when(
    () => repo.sendNow(
      any(),
      profileId: any(named: 'profileId'),
      cancelToken: any(named: 'cancelToken'),
      onSendProgress: any(named: 'onSendProgress'),
    ),
  ).thenAnswer((_) => Completer<List<MailRow>>().future);
  return repo;
}

