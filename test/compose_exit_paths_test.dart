// 两条「退出/发送」通路上的回归：正文换成 Delta 之后，这两处的判据与刷新
// 时机都跟着变了形状。
//
// 一、**空正文要能被拦住**。`SendPayload.validate` 用 `content.trim().isEmpty`
//     判空正文，而正文改成 Delta 之后，空文档导出来是
//     `<p style="margin:0 0 12px 0"><br></p>` —— `trim()` 之后永远非空，
//     于是 `emptyContent` 成了死代码，**空信能直接发出去**。
//     `_maybePreflight` 里还写着「空正文本就让它过，交给 buildPayload 那条
//     emptyContent 报错」—— 那句话当时已经不成立了。
//
// 二、**系统返回手势也要落一次盘**。正文回写有 250 ms 防抖，`X` 按钮那条路
//     有 `_flushBody()` 兜底；安卓返回键 / iOS 边缘滑动走的是 Navigator 的
//     pop，不经过 `_leave`，于是那 250 ms 里打的字既不在 state、也没进草稿。
//     `compose_screen.dart` 自己写着「离开页面**一律**存草稿」，这一条兑现它。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/send_payload.dart';
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 把写邮件页**推**进导航栈（而不是当 `home:`）：返回手势会把它弹掉，
  /// 它必须是能被弹掉的那一层。
  ///
  /// 每条用例自带一个内存库：不给 `databaseProvider` 兜底的话，控制器
  /// `build()` 里那个 `refreshQuota()` 会去开**真的** `cloud_mail` 库文件，
  /// 用例之间互相看得见（drift 会为此再警告一句「同一个库被创建了多次」）。
  Future<ProviderContainer> pumpCompose(
    WidgetTester tester,
    AppDatabase db, {
    ComposeArgs args = const ComposeArgs(),
  }) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        currentProfileIdProvider.overrideWithValue('p1'),
      ],
    );
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
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
    return container;
  }

  /// 按一次系统返回键（安卓返回键 / iOS 边缘滑动走的是同一条路）。
  ///
  /// **不能写成 `await tester.binding.handlePopRoute()`**：那个 future 要等
  /// 弹出的一整套流程跑完才完成，而流程要靠**帧**推进（路由退场动画由 ticker
  /// 驱动）。直接 await 会把测试体钉死在那一行 —— 它等不到下一帧，整个用例
  /// 空转到超时。先拿到 future、把帧推完、再 await 它，才是这条路的走法。
  /// （探针 zz_probe_pop / zz_probe_await 两版对照过：先推帧的那版
  /// `handlePopRoute` 早已返回 true。）
  Future<void> pressSystemBack(WidgetTester tester) async {
    final popped = tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(await popped, isTrue, reason: '返回手势应当被页面接住');
  }

  /// 建一个内存库 + 写邮件页，用完关库。四条「空正文」用例共用。
  Future<(ProviderContainer, AppDatabase)> openBlank(
    WidgetTester tester, {
    ComposeArgs args = const ComposeArgs(),
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = await pumpCompose(tester, db, args: args);
    return (container, db);
  }

  /// 读出库里所有草稿。
  ///
  /// **用 `select().get()` 而不是 `localDao.watchDrafts(...).first`**：后者是
  /// **流**查询，drift 的 `StreamQueryStore` 在订阅结束时留一个保活计时器，
  /// 而 `testWidgets` 的假时钟不会去推它 —— 于是紧随其后的 `db.close()` 再也
  /// 回不来，整个用例空转到超时。对比探针（同一条用例只换读法）：
  /// `watchDrafts` 那版停在 `X2 rows=…`，`get()` 那版 `X1 closed` 正常收尾。
  /// 这里要的只是「库里现在有什么」，查询形状无关，用普通 query 即可。
  Future<List<String>> storedDrafts(AppDatabase db) async {
    final rows = await db.select(db.drafts).get();
    return rows.map((r) => r.content).toList();
  }

  group('空正文拦得住（导出的 HTML 对空文档不为空，判据必须落回 Delta）', () {
    testWidgets('一个字没写的信：payload 里带 emptyContent', (tester) async {
      const args = ComposeArgs();
      final (container, db) = await openBlank(tester, args: args);
      final payload =
          container.read(composeControllerProvider(args).notifier).buildPayload();

      expect(
        payload.content,
        isEmpty,
        reason: '空正文的 content 必须是空串 —— 导出器会给那对 '
            '<p><br></p>，trim() 之后非空，emptyContent 就永远不会触发',
      );
      expect(
        payload.validate().contains(SendValidationError.emptyContent),
        isTrue,
        reason: '计划 §G 第 2 条：清空正文再发，要出现「正文不能为空」',
      );
      await db.close();
    });

    testWidgets('打一个字再删掉：同样是空正文', (tester) async {
      const args = ComposeArgs();
      final (container, db) = await openBlank(tester, args: args);
      final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
      editor.controller.replaceText(
        0,
        0,
        '嗯',
        const TextSelection.collapsed(offset: 1),
      );
      editor.controller.replaceText(0, 1, '', const TextSelection.collapsed(offset: 0));
      await tester.pump(const Duration(milliseconds: 400));

      final payload =
          container.read(composeControllerProvider(args).notifier).buildPayload();
      expect(payload.content, isEmpty);
      expect(
        payload.validate().contains(SendValidationError.emptyContent),
        isTrue,
      );
      await db.close();
    });

    testWidgets('写了字就有 content，不再报空', (tester) async {
      const args = ComposeArgs();
      final (container, db) = await openBlank(tester, args: args);
      final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
      editor.controller.replaceText(
        0,
        0,
        '你好',
        const TextSelection.collapsed(offset: 2),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final payload =
          container.read(composeControllerProvider(args).notifier).buildPayload();
      expect(payload.content, contains('你好'));
      expect(
        payload.validate().contains(SendValidationError.emptyContent),
        isFalse,
      );
      await db.close();
    });

    testWidgets('只有一张图：**不算**空正文（一封只有图的信是能发的）', (tester) async {
      const args = ComposeArgs();
      final (container, db) = await openBlank(tester, args: args);
      final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
      // 落点取文末那个 `\n` **之前**：`document.length` 含末尾换行，合法内容
      // 偏移的上界是 `length - 1`。空白页上它就是 0。
      final at = editor.controller.document.length - 1;
      // **数据必须是 `Embeddable`**，不能给 `{'image': …}` 那种裸 Map ——
      // `replaceText` 的 `assert(data is String || data is Embeddable ||
      // data is Delta)`（`quill_controller.dart:273`）会把裸 Map 挡下来。
      // 这一条要的是「文档里真的有一张图」，所以走 `BlockEmbed.image`。
      editor.controller.replaceText(
        at,
        0,
        q.BlockEmbed.image('data:image/png;base64,AAAA'),
        TextSelection.collapsed(offset: at + 1),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final payload =
          container.read(composeControllerProvider(args).notifier).buildPayload();
      expect(payload.content, isNotEmpty);
      expect(
        payload.validate().contains(SendValidationError.emptyContent),
        isFalse,
        reason: '嵌入算内容 —— 纯文本里它只是 `￼`，拿纯文本判空会误杀',
      );
      await db.close();
    });
  });

  group('旧草稿（纯文本）读进来时组报文不炸', () {
    testWidgets('正文还是纯文本时 buildPayload 退回空正文，不抛 FormatException', (tester) async {
      const args = ComposeArgs();
      final (container, db) = await openBlank(tester, args: args);
      final controller = container.read(composeControllerProvider(args).notifier);

      // 造出那个窗口：`_restoreDraft` 把旧草稿的 `content`（**纯文本**，见
      // [DocumentCodec] 的契约）直接搬进 `state.body`，而回写成 Delta 要等
      // 编辑器 250 ms 的防抖烧完。`setBody` 不带 `bodyRevision`，编辑器不会
      // 来把它换成 Delta —— 这就是那一刻的 state。
      //
      // 直接 `setBody` 而不是塞一条草稿进库再打开：那条路要 `pumpAndSettle`
      // 才走得到，而 settle 顺手把防抖也烧了，`state.body` 早就是 Delta 了，
      // 这个窗口根本露不出来。
      controller.setBody('写了一半的正文\n');

      // 加附件走的 `_reportLimits` 会调它。抛出去的话，用户看到的是
      // 「打开一条旧草稿、加个附件，写邮件页红了」。
      final payload = controller.buildPayload();
      expect(
        payload.content,
        isEmpty,
        reason: '解析不出来时退回空文档 —— 宁可给一个空正文，也不能抛',
      );
      expect(
        payload.validate().contains(SendValidationError.emptyContent),
        isTrue,
      );
      await db.close();
    });
  });

  group('系统返回手势（不走 X 按钮）', () {
    testWidgets('打完字立刻按返回：那 250ms 里的字要进草稿', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await pumpCompose(tester, db);
      final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));

      editor.controller.replaceText(
        0,
        0,
        '最后一句',
        const TextSelection.collapsed(offset: 4),
      );
      // **故意只推一帧**：250 ms 的防抖没烧完，这正是要复现的窗口。
      await tester.pump(const Duration(milliseconds: 16));

      await pressSystemBack(tester);

      final drafts = await storedDrafts(db);
      expect(
        drafts.join(),
        contains('最后一句'),
        reason: '「离开页面一律存草稿」是这一页自己的承诺 —— '
            '返回手势也是离开，那一段字不能就这么没了',
      );
      await db.close();
    });

    testWidgets('什么都没写就按返回：不留空草稿', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await pumpCompose(tester, db);
      await pressSystemBack(tester);

      final drafts = await storedDrafts(db);
      expect(drafts, isEmpty, reason: '空信不存这条规矩不能因为换了条退出路径就破');
      await db.close();
    });

    // 这一条盯的是**装载初值**那一趟回写：编辑器换文档时会通知两回
    // （`replaceText` 一回、`updateSelection` 一回），两回都够把防抖的
    // `_pushBody` 点着，而 `_pushBody` 默认会 `dirty: true` —— 于是「打开一封
    // 回复、一个字都不动就退出」也会留下一份草稿。E4 之前与 `main` 上都是
    // `dirty=false`、草稿 0 条（探针 zz_pr 三版比过：只罩 replaceText 时
    // `dirty=true`、留下一条 133 字的记录；罩住两回才回到 `dirty=false`）。
    testWidgets('回复页什么都没改就按返回：不留草稿（预填的引用块不算「写过」）', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await pumpCompose(
        tester,
        db,
        args: ComposeArgs(mode: ComposeMode.reply, mail: _quoteSource()),
      );
      await pressSystemBack(tester);

      final drafts = await storedDrafts(db);
      expect(
        drafts,
        isEmpty,
        reason: '打开回复页本身不是「写过东西」—— '
            '预填的引用块是**我们**放进去的，用户在退出前一个字都没敲',
      );
      await db.close();
    });

    testWidgets('回复页真的敲了字再按返回：那条草稿在', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final args = ComposeArgs(mode: ComposeMode.reply, mail: _quoteSource());
      await pumpCompose(tester, db, args: args);
      final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
      editor.controller.replaceText(
        0,
        0,
        '我的回复',
        const TextSelection.collapsed(offset: 4),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await pressSystemBack(tester);

      final drafts = await storedDrafts(db);
      expect(
        drafts.join(),
        contains('我的回复'),
        reason: '上面那条闸不许连坐 —— 用户敲过的字一条都不能少',
      );
      await db.close();
    });

    // 判据只能是**文档内容**变没变，不能是「收到过通知」：`QuillController`
    // 是 `ChangeNotifier`，**光把光标挪一下**（点正文某处、拖个选择、输入法
    // 动一下光标）同样通知。拿通知当判据时，用户在回复页里点一下正文再退出，
    // 就会留下一条一个字没写的草稿（探针 zz_sel：`X1a dirty=true` →
    // 退出后 `drafts=1`；这一条现在盯住它）。
    testWidgets('回复页只点了一下正文、一个字没敲：同样不留草稿', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final args = ComposeArgs(mode: ComposeMode.reply, mail: _quoteSource());
      await pumpCompose(tester, db, args: args);
      final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
      // 只换选区 —— 文档一个字符都没变。用户的真实动作是「点了正文里某处」。
      editor.controller.updateSelection(
        const TextSelection.collapsed(offset: 3),
        q.ChangeSource.local,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await pressSystemBack(tester);

      final drafts = await storedDrafts(db);
      expect(
        drafts,
        isEmpty,
        reason: '换了选区但没有编辑 —— 这不是「写过东西」',
      );
      await db.close();
    });

    // 反向的一条：判据只在**回写**时更新基准，不在每次通知时更新。若在通知里
    // 也刷基准，用户「打字 → 点一下正文 → 立刻退出」这串动作里，后一次（选区）
    // 通知会把基准刷成当前状态，刚敲的字于是被算成「没变」—— 那段字既不置脏
    // 也不进草稿（探针 zz_lost 实测：通知里刷基准时 `Y1 drafts=0`，且正文连
    // 一个字都留不下来）。这条把「不许丢字」钉死在最刁的那条路上。
    testWidgets('打完字、又点了一下正文、再立刻返回：字一个不少', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await pumpCompose(tester, db);
      final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));

      editor.controller.replaceText(
        0,
        0,
        '刚打的字',
        const TextSelection.collapsed(offset: 4),
      );
      // 防抖没烧完，用户又点了正文别处 —— 文档没变，只是光标动了。
      await tester.pump(const Duration(milliseconds: 16));
      editor.controller.updateSelection(
        const TextSelection.collapsed(offset: 1),
        q.ChangeSource.local,
      );

      await pressSystemBack(tester);

      final drafts = await storedDrafts(db);
      expect(
        drafts.join(),
        contains('刚打的字'),
        reason: '光标动过不代表没写过 —— 基准不能被选区通知刷掉',
      );
      await db.close();
    });
  });
}

/// 回复页要有一封原邮件才立得起来（主题带上 `Re:`、正文预填引用块）。
MailRow _quoteSource() => MailRow(
      emailId: 1,
      profileId: 'p1',
      accountId: 1,
      subject: '主题',
      sendEmail: 'alice@example.com',
      name: 'Alice',
      createTime: DateTime.parse('2026-10-10T12:00:00.000Z'),
      content: '<p>第一段</p>',
    );
