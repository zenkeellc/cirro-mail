// 宿主层装上之后，复制粘贴还通不通。这一条是本轮**唯一**有可能把已经
// 好的东西弄坏的地方：`MailShortcutHost` 是一层**新的 `Shortcuts`**，而它摆
// 在 `MaterialApp.builder` 里、比框架的 `DefaultTextEditingShortcuts` **更近**
// （见 `shortcut_host.dart` 上那段「按键表是全权的」）—— 万一它的表里混进一个
// 编辑键，用户会丢复制粘贴而我们毫不知情。
//
// ## 为什么拦 channel 而不读系统剪贴板
//
// `Clipboard.getData` 在 flutter_tester 里的 future **永不完成**（本轮的探针
// 实测把用例挂到超时）。而 `Clipboard.setData` 是一条**发出去就不用等回**的
// 调用（`services/clipboard.dart:35` → `SystemChannels.platform.invokeMethod`），
// 拦在 channel 上既能看见「谁发的」也能看见「发的是什么」。
//
// 三条断言对应三种树形状：
//   ① 宿主层 + 普通 `TextField`（宿主层正下方那个最常见的输入框）；
//   ② 同一棵树里 `Ctrl+N` 仍然开出写邮件页 —— 证伪「①之所以绿，是因为宿主层
//      压根没接上」这个解释；
//   ③ 写邮件页（宿主层 + 页面层两层 `Shortcuts`）+ 正文 quill 里复制。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/features/shortcuts/shortcut_host.dart';
import 'package:mail_app/router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 记下每一条发往平台 channel 的 `Clipboard.setData`，返回那个列表。
  ///
  /// 用 `setMockMethodCallHandler`（不是 `setMockMessageHandler`）：`Clipboard`
  /// 走的是 `MethodChannel.invokeMethod`，要的正是这一条路。
  /// 回来的 `null` 让 `invokeMethod` 正常完成 —— 真机上 clipboard 那条
  /// 也会回一个值，回 null 不会让任何调用方抛。
  List<String> captureClipboard(WidgetTester tester) {
    final writes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        // 别的平台调用（`SystemChrome` / `HapticFeedback` …）照旧放过。
        if (call.method == 'Clipboard.setData') {
          writes.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    return writes;
  }

  /// 按 `Ctrl + <key>`。用 `Control` 而不是 `Command`：flutter_tester 的默认
  /// 平台是 android，框架那张 `_clipboardShortcuts` 里认的就是 control
  /// （`default_text_editing_shortcuts.dart:301`）。mac 那一支是同表的另一个
  /// 分支，`mail_shortcuts_keymap_test.dart` 已经逐个字段钉过。
  Future<void> pressWithCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// 一棵「真路由 + 宿主层」的树，落在 `/settings` 那一页上。
  ///
  /// 用真路由器而不是 `Navigator`：`Ctrl+N` 那一条要 `context.push`
  /// （`openNewCompose` 走 go_router 的扩展方法，普通 `Navigator` 上直接抛），
  /// 而「宿主层的 Action 挂对了没有」正是这里要证伪的那件事。
  ///
  /// 写邮件页用**代替品**（把地址打出来）—— 这一组只关心「按键有没有落到
  /// 该去的地方」，页面本身有它自己的一整套用例。
  Future<void> pumpHosted(WidgetTester tester, Widget body) async {
    final router = GoRouter(
      initialLocation: Routes.settings,
      routes: <RouteBase>[
        GoRoute(path: Routes.settings, builder: (context, state) => body),
        GoRoute(
          path: Routes.compose,
          builder: (context, state) =>
              Scaffold(body: Text('compose:${state.uri}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [routerProvider.overrideWithValue(router)],
        child: MaterialApp.router(
          routerConfig: router,
          // 位置照抄 `lib/app.dart`：在 `builder` 里（`Theme.of(context).platform`
          // 只有这里拿得到）。宿主层是新的那一层，其余照旧。
          builder: (context, child) =>
              MailShortcutHost(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('① 宿主层下普通输入框：Ctrl+A 全选 + Ctrl+C 仍然发出选中的字',
      (tester) async {
    final writes = captureClipboard(tester);
    final controller = TextEditingController(text: 'hello world');
    addTearDown(controller.dispose);

    await pumpHosted(
      tester,
      Scaffold(body: TextField(controller: controller, autofocus: true)),
    );

    await pressWithCtrl(tester, LogicalKeyboardKey.keyA);
    await pressWithCtrl(tester, LogicalKeyboardKey.keyC);

    expect(
      writes,
      contains('hello world'),
      reason: '宿主层把 Ctrl+C 截走了 —— 它的表里混进了编辑键，'
          '而这一层比框架的 `DefaultTextEditingShortcuts` 近，框架再也收不到',
    );
  });

  testWidgets('② 同一棵树里 Ctrl+N 仍然开出写邮件页（宿主层确实接上了）', (tester) async {
    // ①的证伪条件：如果宿主层压根没接上，①照样绿 —— 那就什么都没测到。
    await pumpHosted(tester, const Scaffold(body: Text('设置页')));

    await pressWithCtrl(tester, LogicalKeyboardKey.keyN);

    expect(
      find.text('compose:/compose'),
      findsOneWidget,
      reason: '宿主层没接上（或者被别的层盖住了）—— 那么①的绿是白拿的',
    );
  });

  testWidgets('③ 写邮件页两层 Shortcuts 下，正文里 Ctrl+C 仍然发出选中的字',
      (tester) async {
    final writes = captureClipboard(tester);
    final controller = q.QuillController.basic();
    addTearDown(controller.dispose);
    controller.document = q.Document()..insert(0, '正文');
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      q.ChangeSource.local,
    );
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MailQuillEditor(controller: controller, focusNode: focusNode),
        ),
      ),
    );
    await tester.pumpAndSettle();

    focusNode.requestFocus();
    await tester.pumpAndSettle();

    await pressWithCtrl(tester, LogicalKeyboardKey.keyC);

    expect(
      writes,
      contains('正文'),
      reason: 'quill 的 `CopySelectionTextIntent` → `clipboardSelection` 那条路'
          '必须还在（`quill_controller.dart:554` 的 `Clipboard.setData`）。'
          '写邮件页新加的那层 `Shortcuts` 只绑了 Esc，不该碰这里',
    );
  });
}
