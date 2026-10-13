// 两个「系统通用」的补位键：`Cmd/Ctrl+,` 打开设置、`Cmd/Ctrl+W` 藏窗口。
//
// 这一组是**端到端**的：宿主层装了之后，那两个 Intent 有没有真的落到设置页
// 与那条原生通道上。纯表那一层（键位对不对、修饰键是哪一边）由
// `mail_shortcuts_keymap_test.dart` 钉着，这里不重复。
//
// ## 为什么 `Cmd+W` 这条要 `debugDefaultTargetPlatformOverride`
//
// `WindowChannel.hide()` 的第一句是 `if (kIsWeb || !_isDesktop) return;`
// （`window_channel.dart`）—— 非桌面平台静默空操作。而 flutter_tester 的默认
// 平台是 **android**，不覆盖的话这条通道一次都不会被调用，用例会以一个
// 假绿（「断言没收到调用」也能绿）收场。覆盖成 macOS 之后
// `defaultTargetPlatform` 才是桌面，`_isDesktop` 才成立。
//
// 复位必须放在**用例体内**（`mail_row_menu_test.dart` 的约定）：它是全局可变
// 状态，漏了复位会污染同一个文件里后面的用例。
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/features/shortcuts/shortcut_host.dart';
import 'package:mail_app/router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 「叫窗口」那条原生通道。通道名与三个 runner 注册的逐字一致
  /// （`macos/Runner/AppDelegate.swift`、`windows/runner/flutter_window.cpp`、
  /// `linux/runner/my_application.cc`）—— 换掉这个名字就是三个平台一起哑掉。
  const windowChannel = MethodChannel('com.zenkee.mailapp/window');

  /// 记下原生侧收到的每一个方法名。
  List<String> captureWindowCalls(WidgetTester tester) {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, null);
    });
    return calls;
  }

  Future<void> pressWithCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// 按 `Cmd + <key>`。
  ///
  /// ②③ 覆盖成 macOS 之后**必须**用 Meta 而不是 Ctrl：宿主层的键表是按
  /// `Theme.of(context).platform` 取的那一份（`shortcut_host.dart`），而
  /// `ThemeData` 的 platform 默认就是 `defaultTargetPlatform` —— 覆盖一生效，
  /// 表里 `Cmd+W` 那一格就是 meta，Ctrl+W 一条也匹配不上。
  Future<void> pressWithMeta(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
  }

  /// 一棵「真路由 + 宿主层」的树。形状照 `mail_shortcuts_clipboard_test.dart`
  /// 的 `pumpHosted` —— 两处是同一种脚手架，差别只在被测的是哪几个键。
  ///
  /// 起始页**故意不是**设置页：`Ctrl+,` 那条要断言「地址真的变了」，
  /// 从 `/settings` 出发的话「本来就在那儿」与「跳过去了」分不开。
  Future<void> pumpHosted(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: Routes.starred,
      routes: <RouteBase>[
        GoRoute(path: Routes.starred, builder: (context, state) => const Scaffold(body: Text('星标页'))),
        GoRoute(path: Routes.settings, builder: (context, state) => const Scaffold(body: Text('设置页'))),
        // ③ 那条要按 `Cmd+N`（`openNewCompose` → `context.push('/compose')`）——
        // 没有这一格 go_router 会落到它的错误页上，而错误页本身不抛异常，
        // 「通道没被碰」照样成立，但那是**在一个出错的地址上**成立的，
        // 说服力打折。
        GoRoute(path: Routes.compose, builder: (context, state) => const Scaffold(body: Text('写邮件'))),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [routerProvider.overrideWithValue(router)],
        child: MaterialApp.router(
          routerConfig: router,
          // 位置照抄 `lib/app.dart`：在 `builder` 里。宿主层是新的那一层。
          builder: (context, child) =>
              MailShortcutHost(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('① Ctrl+, 打开设置页', (tester) async {
    await pumpHosted(tester);
    expect(find.text('星标页'), findsOneWidget, reason: '起始页应当是星标页');

    await pressWithCtrl(tester, LogicalKeyboardKey.comma);

    expect(
      find.text('设置页'),
      findsOneWidget,
      reason: '`Ctrl+,` 没有落到设置页 —— 宿主层里那个 OpenSettingsIntent '
          '少挂了 Action，或者 action 用 `context.go` 而不是 `routerProvider`',
    );
  });

  testWidgets('② Cmd+W 走原生通道藏窗口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final calls = captureWindowCalls(tester);
    await pumpHosted(tester);

    await pressWithMeta(tester, LogicalKeyboardKey.keyW);

    expect(
      calls,
      contains('hideMainWindow'),
      reason: '`Cmd+W` 没有打到那条原生通道上 —— 检查 '
          '`WindowChannel.hide()` 的方法名与 runner 里那个字符串是否逐字一致',
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('③ 证伪条件：同一条通道上 Cmd+N 不碰它', (tester) async {
    // ②之所以绿，也可能是因为「这条通道谁按都被打一次」。钉一条反例：
    // 新建邮件走 `context.push`，与那条原生通道毫无关系。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final calls = captureWindowCalls(tester);
    await pumpHosted(tester);

    await pressWithMeta(tester, LogicalKeyboardKey.keyN);

    expect(calls, isEmpty);
    // 顺带把「这一按确实走了路由」证出来 —— 光看 `calls` 为空，
    // 「Action 没挂上」与「通道没被碰」是同一个观测结果。
    expect(find.text('写邮件'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });
}
