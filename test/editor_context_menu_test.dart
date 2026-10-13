import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/editor_context_menu.dart';
import 'package:mail_app/features/compose/editor/editor_toolbar.dart';

/// F-3 / 「常见邮件菜单」这一组：右击（桌面）或长按（触屏）弹出来的编辑菜单。
///
/// 关键不是「菜单画得好看」，而是 `state.contextMenuButtonItems` 这一份
/// **条目**真的能用 —— 上游把 `enableSelectionToolbar` 置 false 时，
/// `contextMenuBuilder` 会一起变 null，`copyEnabled`/`pasteEnabled` 等随之
/// 全假，菜单成了一个点了没反应的壳。所以这里既验「菜单出现了」，
/// 也验「条目带着可用的回调」。
void main() {
  /// 一个最小的编辑器宿，只为了拿到真的 `QuillRawEditorState`。
  Future<void> pumpEditor(
    WidgetTester tester, {
    required q.QuillController controller,
    required q.QuillEditorContextMenuBuilder builder,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: q.QuillEditor(
          controller: controller,
          focusNode: FocusNode(),
          scrollController: ScrollController(),
          config: q.QuillEditorConfig(
            enableSelectionToolbar: true,
            contextMenuBuilder: builder,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('选中一段文字后弹出的条目里，复制/剪切/粘贴/全选都带回调', (tester) async {
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句话\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);

    late List<ContextMenuButtonItem> items;
    await pumpEditor(
      tester,
      controller: controller,
      builder: (context, state) {
        items = state.contextMenuButtonItems;
        return MailQuillContextMenu(
          child: AdaptiveTextSelectionToolbar.buttonItems(
            buttonItems: items,
            anchors: state.contextMenuAnchors,
          ),
        );
      },
    );
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      q.ChangeSource.local,
    );
    await tester.pumpAndSettle();

    // 右键弹出上下文菜单（桌面）—— 触屏上是长按，走同一个 builder。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(q.QuillEditor)),
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(items, isNotEmpty, reason: '菜单条目是空的 → 菜单成了空壳');
    for (final item in items) {
      expect(
        item.onPressed,
        isNotNull,
        reason: '条目 ${item.type} 没有回调（enableSelectionToolbar 被关掉了？）',
      );
    }
    final types = items.map((i) => i.type).toSet();
    expect(
      types,
      containsAll(<ContextMenuButtonType>[
        ContextMenuButtonType.copy,
        ContextMenuButtonType.cut,
        ContextMenuButtonType.paste,
        ContextMenuButtonType.selectAll,
      ]),
    );
  });

  testWidgets('菜单出现又消失时，presence 回调一进一出', (tester) async {
    final seen = <bool>[];
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句话\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);

    // 先直接验这层壳：挂上 → true，卸载 → false。
    await tester.pumpWidget(MaterialApp(
      home: MailQuillContextMenu(
        onPresenceChanged: seen.add,
        child: const Text('菜单'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(seen, [true]);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(seen, [true, false]);
  });

  group('浮动工具栏让位（EditorToolbar.suppressed）', () {
    q.QuillController? controller;
    Widget host({required bool suppressed}) {
      controller = q.QuillController(
        document: q.Document.fromJson([
          {'insert': '一句话\n'},
        ]),
        selection: const TextSelection(baseOffset: 0, extentOffset: 2),
      );
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 400,
            child: Stack(
              children: [
                q.QuillEditor(
                  controller: controller!,
                  focusNode: FocusNode(),
                  scrollController: ScrollController(),
                  config: q.QuillEditorConfig(
                    editorKey: GlobalKey<q.EditorState>(),
                    enableSelectionToolbar: false,
                  ),
                ),
                EditorToolbar(
                  controller: controller!,
                  editorKey: GlobalKey<q.EditorState>(),
                  viewportKey: GlobalKey(),
                  suppressed: suppressed,
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('suppressed 为 true 时一个按钮都不画', (tester) async {
      await tester.pumpWidget(host(suppressed: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tb-bold')), findsNothing);
      expect(tester.takeException(), isNull);
      controller!.dispose();
    });
  });

  /// 「菜单跟着鼠标」这一条 —— 用户报的第二个问题。
  ///
  /// 老行为：锚点由 `state.contextMenuAnchors` 算，而 quill 那一份**只看
  /// 选区端点**。选中一段之后在别处右击，菜单于是停在**旧选区**上（探针实测
  /// 在 (40,200) 右击，菜单跑到 y≈29；把鼠标挪到 (40,400)，菜单纹丝不动）。
  /// 这一组钉住修好之后的行为：菜单落在鼠标处，且光标跟着落到右击的位置。
  group('编辑菜单跟随鼠标', () {
    /// 一个和 `MailQuillEditor` 同样的宿主 —— 这里**手动套一层 `Listener`**，
    /// 因为 `MailQuillEditor` 自己没有暴露内部状态，而这一组要控制的正是
    /// 「谁在什么时候往下传右击坐标」。
    ///
    /// 默认平台是 android；工具条那一支要 macOS（桌面）才走
    /// `DesktopTextSelectionToolbar`，**文字是英文 Copy/Cut/Paste**。
    /// 所以这里统一覆盖成 macOS，并且挂上本地化代理（没有它工具条画不出来）。
    Future<void> pumpWithAnchor(
      WidgetTester tester, {
      required q.QuillController controller,
      required Offset? Function() anchor,
    }) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 600,
            child: q.QuillEditor(
              controller: controller,
              focusNode: FocusNode(),
              scrollController: ScrollController(),
              config: q.QuillEditorConfig(
                enableSelectionToolbar: true,
                contextMenuBuilder: mailContextMenuBuilder(
                  rightClickAnchor: anchor,
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    /// 在 macOS 平台设定下跑 [body] —— 只在 `body` 期间生效。
    ///
    /// 必须在**测试体内部**把它设回去：`debugDefaultTargetPlatformOverride`
    /// 是 foundation 的调试变量，`_verifyInvariants`（在测试体结束时跑）
    /// 见到它没被复位就直接判测试失败，`addTearDown` 来不及。
    Future<void> onMacOS(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('右击**选区外面**：菜单落在鼠标处（不是旧选区）', (tester) async {
      await onMacOS(() async {
        final controller = q.QuillController(
          document: q.Document.fromJson([
            {'insert': '第一行文字\n第二行文字\n第三行文字\n第四行文字\n'},
          ]),
          selection: const TextSelection(baseOffset: 0, extentOffset: 3),
        );
        addTearDown(controller.dispose);
        Offset? anchor;
        await pumpWithAnchor(
          tester,
          controller: controller,
          anchor: () => anchor,
        );

        anchor = const Offset(40, 200);
        final gesture = await tester.startGesture(
          anchor,
          buttons: kSecondaryMouseButton,
        );
        await gesture.up();
        await tester.pumpAndSettle();

        final copy = find.text('Copy');
        expect(copy, findsOneWidget, reason: '菜单没弹出来（本地化代理漏了？）');
        final rect = tester.getRect(copy);
        expect(
          rect.center.dx,
          closeTo(anchor.dx, 80),
          reason: '菜单没有横向落在鼠标附近 —— 还锚在旧选区上？',
        );
        expect(
          rect.center.dy,
          closeTo(anchor.dy, 80),
          reason: '菜单没有纵向落在鼠标附近 —— 老行为会停在旧选区那一行',
        );
      });
    });

    testWidgets('没有右击坐标（长按那条路）时退回选区锚点，不抛', (tester) async {
      await onMacOS(() async {
        final controller = q.QuillController(
          document: q.Document.fromJson([
            {'insert': '第一行文字\n第二行文字\n'},
          ]),
          selection: const TextSelection(baseOffset: 0, extentOffset: 3),
        );
        addTearDown(controller.dispose);
        await pumpWithAnchor(
          tester,
          controller: controller,
          anchor: () => null,
        );

        final gesture = await tester.startGesture(
          const Offset(40, 200),
          buttons: kSecondaryMouseButton,
        );
        await gesture.up();
        await tester.pumpAndSettle();

        expect(find.text('Copy'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  });
}
