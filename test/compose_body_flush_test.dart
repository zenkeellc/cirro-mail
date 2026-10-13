// `_flushBody` 的回归测试：正文回写有 250 ms 防抖，而 `buildPayload()` 与
// `saveDraftOnExit()` 读的都是 `state.body`（防抖的**副本**）。
//
// 修之前：打完最后一个字立刻点 `X`（或发送），那 250 ms 里打的东西既没进
// state、也没进草稿 —— 发送出去的是一封少一段甚至整篇空白的信。
//
// 这一组只钉**页面这一层**的接线：打完字 → 立刻点 `X` → `state.body` 里必须
// 已经有那段字。发送那一侧走不了（测试里没有邮箱 → `canSendNow` 为 false，
// 发送按钮是灰的），但两条路调的是同一个 `_flushBody()`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/features/compose/html/document_codec.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 把写邮件页**推**进导航栈（而不是当 `home:`）：关窗按钮会 `pop`，
  /// 它必须是能被弹掉的那一层。
  ///
  /// 返回的 `captured` 是**关窗之前最后一次**看到的正文 —— 页面一弹走，
  /// `composeControllerProvider` 这个 `isAutoDispose` 的 family 就会被回收，
  /// 事后再 `read` 拿到的是重建出来的空状态（这是这一组测试先前踩过的坑）。
  Future<(ProviderContainer, String? Function(), bool Function())> pumpCompose(
    WidgetTester tester, {
    ComposeArgs args = const ComposeArgs(),
  }) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [prefsStoreProvider.overrideWithValue(prefs)],
    );
    String? captured;
    var capturedDirty = false;
    container.listen<ComposeState>(
      composeControllerProvider(args),
      (previous, next) {
        captured = next.body;
        capturedDirty = next.dirty;
      },
      fireImmediately: true,
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
    return (container, () => captured, () => capturedDirty);
  }

  testWidgets('打完字立刻关窗（防抖没烧完）：正文已经写进 state 了', (tester) async {
    const args = ComposeArgs();
    final (container, body, dirty) = await pumpCompose(tester, args: args);
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));

    editor.controller.replaceText(
      0,
      0,
      '刚打的字',
      const TextSelection.collapsed(offset: 4),
    );
    // 只推进一帧 —— 250 ms 的防抖**故意没烧完**，这正是要复现的窗口。
    await tester.pump(const Duration(milliseconds: 16));

    expect(
      container.read(composeControllerProvider(args)).body,
      isEmpty,
      reason: '防抖还没到点时 state.body 确实还是旧的（这是缺陷的成因）',
    );

    // **这里不能 `pumpAndSettle`**：它按 100 ms 一步推进假时钟，弹窗动画的
    // 那几百毫秒顺手就把 250 ms 的防抖也烧掉了 —— 那样「通过」的是定时器，
    // 不是要验的这次 flush。所以 `tap` 之后**一帧都不推**就断言：
    // `_leave` 是 async，但 `_flushBody()` 在第一个 `await` 之前，
    // 所以在 `tap` 里同步跑完。
    await tester.tap(find.byIcon(Icons.close));

    expect(
      DocumentCodec.decode(body()).toPlainText(),
      contains('刚打的字'),
      reason: '关窗之前必须把防抖中的正文推下去，否则这段字哪儿都没留下',
    );
    // 这条 flush 是**用户敲的字**引起的，得照常把页面标脏 —— 否则它进了
    // `state.body` 也不会被 `saveDraftOnExit`（第一行 `if (!state.dirty) return`）
    // 存下来，等于白推。装载初值那一趟才是唯一该免掉置脏的。
    expect(dirty(), isTrue, reason: '这条 flush 不是装载初值，必须置脏');
    await tester.pumpAndSettle();
  });

  testWidgets('防抖正常烧完时照旧（flush 不改变没有待办时的行为）', (tester) async {
    final (_, body, _) = await pumpCompose(tester);
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));

    editor.controller.replaceText(
      0,
      0,
      '你好',
      const TextSelection.collapsed(offset: 2),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(DocumentCodec.decode(body()).toPlainText(), contains('你好'));
  });

  testWidgets('回复页：装好的引用块不会被 flush 弄丢', (tester) async {
    final args = ComposeArgs(mode: ComposeMode.reply, mail: _row);
    final (_, body, dirty) = await pumpCompose(tester, args: args);
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));

    // 用户写在引用块**上方**，然后立刻关窗。
    editor.controller.replaceText(
      0,
      0,
      '我的回复',
      const TextSelection.collapsed(offset: 4),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    final text = DocumentCodec.decode(body()).toPlainText();
    expect(text, contains('我的回复'));
    expect(text, contains('写道：'), reason: '引用块不能被这次 flush 吃掉');
    expect(dirty(), isTrue, reason: '用户敲过字，这一趟必须置脏');
  });
}

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
