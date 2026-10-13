import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/attachment_chips.dart';
import 'package:mail_app/features/compose/editor/compose_toolbar.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/features/compose/html/document_codec.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 这一组测试**只验证「编辑器装上了、能打字、能经得起没配 AI」**，
/// 不碰数据库也不碰网络：`ComposeController.build()` 会去读库与拉配额，
/// 但两条都是 `scheduleMicrotask` 出去的、失败被吞掉，而这里只关心
/// 正文区有没有挂上一个 `MailQuillEditor`。
///
/// **不 override 那两条 provider**（database / runtime）是刻意的：
/// `pumpAndSettle` 会等所有 microtask，让它们在里面真的跑一遍失败，
/// 好过在这里假装成功。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 建一个**能被测试读到 state** 的容器：回写那条断言要拿
  /// `composeControllerProvider(args).body`，而 `ProviderScope` 里那个
  /// 容器从外面够不着（这也是 Task D9 的测试用 `ProviderContainer.test` 的
  /// 同一个理由）。
  ///
  /// **不要自己再 `addTearDown(container.dispose)`** —— `ProviderContainer.test`
  /// 内部已经挂了一个（`provider_container.dart:963`），dispose 两次会报
  /// 「already disposed」。
  Future<ProviderContainer> pumpCompose(
    WidgetTester tester, {
    ComposeArgs args = const ComposeArgs(),
  }) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      // 不写 `<Override>[]`：riverpod 3.4 里 `Override` 是 `sealed` 且没有对外
      // 导出（`ai_settings_section_test.dart` 记过同一坑），显式类型参数会报
      // 「'Override' isn't a type」。
      overrides: [prefsStoreProvider.overrideWithValue(prefs)],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: ComposeScreen(args: args),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('正文区挂的是 MailQuillEditor', (tester) async {
    await pumpCompose(tester);
    expect(find.byType(MailQuillEditor), findsOneWidget);
    // 页面上其余那两个 `TextField`（主题、收件人）还在，说明换掉的**只有**
    // 正文区 —— 这条断言是给它上的一道保险。
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('空文档时显示占位提示', (tester) async {
    await pumpCompose(tester);
    // `findRichText: true` **必须给**：flutter_quill 的占位提示是直接画在一个
    // `RichText` 里的（`raw_editor_state` 把 placeholder 拼进文档后由
    // `RichTextProxy` 渲染），不是 `Text` / `EditableText`。默认的
    // `findRichText: false` 会跳过裸 `RichText`，于是「提示明明在屏幕上、
    // 断言却说找不到」。
    expect(find.text('写点什么…', findRichText: true), findsOneWidget);
  });

  testWidgets('编辑器里打的字会回写进 state（Delta JSON）', (tester) async {
    const args = ComposeArgs();
    final container = await pumpCompose(tester, args: args);
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    editor.controller.replaceText(
      0,
      0,
      '你好',
      const TextSelection.collapsed(offset: 2),
    );
    // 防抖窗口（`_writeBackDelay` = 250 ms）过去之后才会回写。
    await tester.pump(const Duration(milliseconds: 400));

    final body = container.read(composeControllerProvider(args)).body;
    expect(body, startsWith('['), reason: 'state.body 应该是 Delta JSON');
    expect(DocumentCodec.decode(body).toPlainText(), contains('你好'));
    // 打的是字，不是 JSON —— 别把 encode 的输出灌进文档里。
    expect(body, isNot(contains('￼')));
  });

  testWidgets('没配 AI 时：工具栏上没有 AI 按钮，也没有幽灵文本', (tester) async {
    await pumpCompose(tester);
    expect(find.byKey(const ValueKey('tb-ai')), findsNothing);
    // 常驻那条上的 AI 入口同理（`aiUsable` 为假时页面根本不传 `onAi`）。
    expect(find.byKey(const ValueKey('ct-ai')), findsNothing);
    expect(find.byKey(const ValueKey('ai-ghost')), findsNothing);
  });

  testWidgets('正文上方是常驻工具栏；底部不再有「+ 插入」与附件按钮', (tester) async {
    await pumpCompose(tester);
    // ① 常驻工具栏在正文上方 —— 这是本次改动的核心诉求。
    final toolbar = find.byType(ComposeToolbar);
    expect(toolbar, findsOneWidget);
    final editor = find.byType(MailQuillEditor);
    expect(
      tester.getRect(toolbar).top,
      lessThan(tester.getRect(editor).top),
      reason: '工具栏要摆在正文区之上，不是下面',
    );
    // ② 底部那两颗入口删掉了：插入能力与附件都进了工具栏。
    expect(find.byKey(const ValueKey('compose-insert')), findsNothing);
    // 「添加附件」那颗按钮的文字没了 —— 附件入口只剩工具栏上的回形针。
    expect(find.text('添加附件'), findsNothing);
    expect(find.byKey(const ValueKey('ct-attach')), findsOneWidget);
  });

  testWidgets('附件条：没有附件时整条不出现', (tester) async {
    await pumpCompose(tester);
    // 原来那条 44px 的空行是靠两颗按钮撑着的，按钮删掉之后它只剩空白。
    expect(find.byType(AttachmentChips), findsOneWidget);
    expect(find.byType(InputChip), findsNothing);
  });

  testWidgets('回复进来时：引用块在正文里，光标在 0（写在引用块上方）',
      (tester) async {
    await pumpCompose(
      tester,
      args: ComposeArgs(mode: ComposeMode.reply, mail: _row),
    );
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    expect(editor.controller.document.toPlainText(), contains('写道：'));
    // 首行是留给用户的空行，紧接着就是那条横线 —— 光标必须落在空行上
    // （偏移 0），否则用户一敲字就把 `---` 写成 `你好---`、横线没了。
    expect(editor.controller.document.toPlainText(), contains('---'));
    expect(editor.controller.selection, const TextSelection.collapsed(offset: 0));
  });
}

/// `MailRow.createTime` 是 `DateTime?` —— 这里必须给一个 `DateTime`，
/// 字符串是编译不过的（`MailRow` 的构造函数不做任何转换）。
final _row = MailRow(
  emailId: 7,
  profileId: 'p1',
  accountId: 1,
  subject: '主题',
  sendEmail: 'alice@example.com',
  name: 'Alice',
  createTime: DateTime.parse('2026-10-10T12:00:00.000Z'),
  content: '<p>第一段</p>',
);
