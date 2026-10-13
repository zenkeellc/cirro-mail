// 「从草稿箱点开一条草稿，正文得真的出现在编辑器里」。
//
// 缺陷（E4 把正文改成 Delta 之后暴露出来）：草稿是**异步**读出来的
// （`ComposeController.build()` 只能排一个 `scheduleMicrotask(_restoreDraft)`），
// 而 `compose_screen.dart` 的 `_adoptInitialBody` 在**第一帧的 `build()`**
// 里就把 `_bodyAdopted` 钉成 true 了 —— 那一帧 `state.body` 还是预填值
// （空写信页就是 `''`），于是 `state.body` 里后来的草稿正文**再也没有任何
// 路子进编辑器**（另一个方向只有用户在编辑器里敲字 → `_pushBody`）。
//
// 后果不只是「看不到」：用户以为正文是空的，随手敲一个字再关窗，`_pushBody`
// 回写的是一个**只含那个字**的文档，直接把库里那条草稿覆盖掉 —— 写了一半的
// 正文就此丢失（见第二个用例）。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _savedBody = '[{"insert":"这是我写了一半的正文\\n"}]';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 往内存库里塞一条草稿，返回它的 id。
  Future<(AppDatabase, int)> seedDraft() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final id = await db.localDao.saveDraft(
      profileId: 'p1',
      accountEmail: 'me@example.com',
      recipientsJson: '[]',
      subject: '半截的主题',
      content: _savedBody,
      attachmentPaths: const <String>[],
    );
    return (db, id);
  }

  Future<AppDatabase> pumpDraft(
    WidgetTester tester,
    AppDatabase db,
    int id,
  ) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        currentProfileIdProvider.overrideWithValue('p1'),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: ComposeScreen(args: ComposeArgs(draftId: id)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return db;
  }

  testWidgets('点开草稿：正文出现在编辑器里，主题也在', (tester) async {
    final (db, id) = await seedDraft();
    await pumpDraft(tester, db, id);

    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    expect(
      editor.controller.document.toPlainText(),
      contains('这是我写了一半的正文'),
      reason: '草稿是异步读出来的，装正文这件事不能只做第一帧那一次',
    );
    expect(
      find.widgetWithText(TextField, '半截的主题'),
      findsOneWidget,
      reason: '主题这一项是同步进 state 的，本来就对 —— 拿它当对照',
    );
    await db.close();
  });

  testWidgets('点开草稿后在正文里加一句再关窗：原来那份正文不能被覆盖掉', (tester) async {
    final (db, id) = await seedDraft();
    await pumpDraft(tester, db, id);

    // 用户在正文末尾续写（他看到的应当是那条草稿，不是空白页）。
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    final end = editor.controller.document.length - 1;
    editor.controller.replaceText(
      end,
      0,
      '又加了一句',
      TextSelection.collapsed(offset: end + 5),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    final after = await db.localDao.findDraft(id);
    expect(after?.content, contains('这是我写了一半的正文'));
    expect(after?.content, contains('又加了一句'));
    await db.close();
  });

  testWidgets('点开草稿时光标在文末：用户是接着上次写，不是重新开头', (tester) async {
    final (db, id) = await seedDraft();
    await pumpDraft(tester, db, id);

    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    expect(
      editor.controller.selection.baseOffset,
      editor.controller.document.length - 1,
      reason: '预填的引用块才落 0（写在引用块上方），读回来的草稿该落文末',
    );
    await db.close();
  });

  testWidgets('**带引用块**的草稿：光标落用户区末尾，不落引用块下面', (tester) async {
    // 这正是「从 AI 建议面板点答复」那条路造出来的东西：正文 = 用户/AI 写的
    // 那一段 + 引用块。用户在**上方**接着写，光标不能被丢到下面去。
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    const quoted =
        '[{"insert":"我周五之前回你\\n\\n"},'
        '{"insert":"张三 <alice@example.com> 写道：\\n",'
        '"attributes":{"mail-quote":true}},'
        '{"insert":"> 会议时间定了吗？\\n","attributes":{"mail-quote":true}}]';
    final id = await db.localDao.saveDraft(
      profileId: 'p1',
      accountEmail: 'me@example.com',
      recipientsJson: '["alice@example.com"]',
      subject: 'Re: 上线时间',
      content: quoted,
      attachmentPaths: const <String>[],
    );
    await pumpDraft(tester, db, id);

    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    final end = editor.controller.selection.baseOffset;
    // 「我周五之前回你」是 7 个字 + 一个换行 = 8 —— 用户区末尾就是 8。
    expect(
      end,
      8,
      reason: '落 document.length - 1 的话就跑到引用块下面去了（用户的字在上方）',
    );
    // 反过来说：它**不是**文末。
    expect(end, lessThan(editor.controller.document.length - 1));
    await db.close();
  });

  testWidgets('同一条草稿连开两次：两次都装得上', (tester) async {
    // 「装了没有」用的**计数**而不是 bool，就是为了这一段：两次装载发生在
    // 两个不同的屏幕实例上（各自一份 `_bodyRevision`），bool 第二次仍是 true，
    // 第二次装载会被吃掉 —— 而 `bodyRevision` 每次换初值都 +1，比得上。
    final (db, id) = await seedDraft();
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
    for (var round = 1; round <= 2; round++) {
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ComposeScreen(args: ComposeArgs(draftId: id)),
        ),
      );
      await tester.pumpAndSettle();
      final editor =
          tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
      expect(
        editor.controller.document.toPlainText(),
        contains('这是我写了一半的正文'),
        reason: '第 $round 次打开',
      );
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
    }
    await db.close();
  });
}
