import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/editor_toolbar.dart';

/// 测试宿主。**必须给 Stack 一个真实尺寸**（`SizedBox.expand`）：`Scaffold.body`
/// 拿到的约束是**松的**，裸 `Stack` 会缩成非定位子项（编辑器）的高度 —— 一行文字
/// 也就 30 来像素，工具栏摆在 `top: 46` 就跑到 Stack 的框**外面**去了。
/// `RenderStack.hitTest` 会以自身 size 为准拒掉框外的点，表现是「按钮找得到、
/// 却点不动」。真实页面里这个 Stack 是撑满的，所以这是测试宿主的坑，不是产品的。
Widget host({
  required q.QuillController controller,
  required GlobalKey<q.EditorState> editorKey,
  required GlobalKey viewportKey,
  VoidCallback? onAiRewrite,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          child: Stack(
            key: viewportKey,
            children: [
              q.QuillEditor(
                controller: controller,
                focusNode: FocusNode(),
                scrollController: ScrollController(),
                config: q.QuillEditorConfig(
                  editorKey: editorKey,
                  // 本文件只测**浮动工具栏**的定位与按钮：把 flutter_quill 自带
                  // 的选区气泡关掉，免得它跟工具栏抢同一个选区。
                  // 生产是**开着**的（`MailQuillEditor` 给了一个自己的
                  // `contextMenuBuilder`），见那里的 F-3 说明。
                  enableSelectionToolbar: false,
                ),
              ),
              EditorToolbar(
                controller: controller,
                editorKey: editorKey,
                viewportKey: viewportKey,
                onAiRewrite: onAiRewrite,
              ),
            ],
          ),
        ),
      ),
    );

void main() {
  testWidgets('没选中 → 工具栏不出现', (tester) async {
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句话\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tb-bold')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中之后出现，且加粗能生效', (tester) async {
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句话\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
      onAiRewrite: () {},
    ));
    await tester.pumpAndSettle();

    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      q.ChangeSource.local,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tb-bold')), findsOneWidget);
    expect(find.byKey(const ValueKey('tb-ai')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tb-bold')));
    await tester.pumpAndSettle();
    final delta = controller.document.toDelta().toJson();
    expect(
      delta.any((op) =>
          op['attributes'] is Map && (op['attributes'] as Map)['bold'] == true),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('标题互斥：先 H1 再 H2，只留 H2', (tester) async {
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '标题行\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
    ));
    await tester.pumpAndSettle();
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 1),
      q.ChangeSource.local,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tb-h1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tb-h2')));
    await tester.pumpAndSettle();

    final delta = controller.document.toDelta().toJson();
    final headerOps = delta
        .where((op) =>
            op['attributes'] is Map &&
            (op['attributes'] as Map).containsKey('header'))
        .toList();
    expect(headerOps.length, 1);
    expect((headerOps.single['attributes'] as Map)['header'], 2);
  });

  testWidgets('没有 AI 回调时不显示 AI 按钮', (tester) async {
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句话\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(
      controller: controller,
      editorKey: GlobalKey<q.EditorState>(),
      viewportKey: GlobalKey(),
    ));
    await tester.pumpAndSettle();
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      q.ChangeSource.local,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tb-ai')), findsNothing);
    expect(find.byKey(const ValueKey('tb-bold')), findsOneWidget);
  });

  testWidgets('F-7 320px 视口里最右边的按钮也点得到，且整条不越界', (tester) async {
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '很长的一句话，长到足以让选区落在靠近右边的地方\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    final editorKey = GlobalKey<q.EditorState>();
    final viewportKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          // **必须给高度**：Stack 的 size 会缩到它第一个非定位子项（编辑器）
          // 的高度，工具栏是 Positioned、会跑到 Stack 盒子**外面**，
          // `RenderStack.hitTest` 拒收框外的点 —— 表现是「按钮找得到点不动」。
          // 真实页面里这个 Stack 是撑满的（见文件头的 host 说明）。
          width: 320,
          height: 600,
          child: Stack(
            key: viewportKey,
            children: [
              q.QuillEditor(
                controller: controller,
                focusNode: FocusNode(),
                scrollController: ScrollController(),
                config: q.QuillEditorConfig(
                  editorKey: editorKey,
                  enableSelectionToolbar: false,
                ),
              ),
              EditorToolbar(
                controller: controller,
                editorKey: editorKey,
                viewportKey: viewportKey,
                onAiRewrite: () {},
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      q.ChangeSource.local,
    );
    await tester.pumpAndSettle();

    // 工具栏整条都在视口内。
    final bar = find
        .ancestor(
          of: find.byKey(const ValueKey('tb-bold')),
          matching: find.byType(Material),
        )
        .first;
    final rect = tester.getRect(bar);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(320));

    // 最右边那几个按钮必须**点得到**：tb-quote 与 tb-align-right 在旧实现里
    // 渲染在屏幕外（工具栏撑到 ~636px），`tester.tap` 会抛。
    for (final k in ['tb-quote', 'tb-align-right']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: '$k 应当在树里');
    }
    // 选区在第 0..2 上，align-right 是行属性 —— 生效后行属性里应当有它。
    await tester.tap(find.byKey(const ValueKey('tb-align-right')));
    await tester.pumpAndSettle();
    final delta = controller.document.toDelta().toJson();
    expect(
      delta.any((op) =>
          op['attributes'] is Map &&
          (op['attributes'] as Map)['align'] == 'right'),
      isTrue,
      reason: 'align-right 必须真的生效（说明按钮点得到）',
    );
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('工具栏实渲染高度与位置算法用的高度一致（钉住耦合）', (tester) async {
    // `_toolbarHeight` 是写死的常量（先算位置再渲染，避免第一帧闪）。
    // 一旦改了按钮高度/内边距却忘了同步它，工具栏就会画在偏掉的位置上，
    // 所以这条测试把「渲染出来的真实高度」钉在与它相同的值上。
    final editorKey = GlobalKey<q.EditorState>();
    final viewportKey = GlobalKey();
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句话\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(
      controller: controller,
      editorKey: editorKey,
      viewportKey: viewportKey,
      onAiRewrite: () {},
    ));
    await tester.pumpAndSettle();
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      q.ChangeSource.local,
    );
    await tester.pumpAndSettle();

    final bar = find
        .ancestor(
          of: find.byKey(const ValueKey('tb-bold')),
          matching: find.byType(Material),
        )
        .first;
    // 32 = 2 * vertical(2) + buttonHeight(28)，与 `EditorToolbar._toolbarHeight` 相同。
    expect(tester.getSize(bar).height, 32);
    controller.dispose();
  });

  group('toolbarAnchor', () {
    testWidgets('选区靠顶 → 翻到选区下方', (tester) async {
      final editorKey = GlobalKey<q.EditorState>();
      final viewportKey = GlobalKey();
      final controller = q.QuillController(
        document: q.Document.fromJson([
          {'insert': '第一行\n'},
        ]),
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pumpWidget(host(
        controller: controller,
        editorKey: editorKey,
        viewportKey: viewportKey,
      ));
      await tester.pumpAndSettle();
      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 2),
        q.ChangeSource.local,
      );
      await tester.pumpAndSettle();

      final rect = toolbarAnchor(
        editorState: editorKey.currentState,
        viewportKey: viewportKey,
        selection: controller.selection,
        toolbarWidth: 420,
        toolbarHeight: 44,
      )!;
      // 第一行贴着顶，上方放不下 44+8，所以 y 必须 > 0（在选区下方）。
      expect(rect.top, greaterThan(0));
      expect(rect.left, greaterThanOrEqualTo(0));
    });

    testWidgets('窄视口里工具栏不越出右边', (tester) async {
      final editorKey = GlobalKey<q.EditorState>();
      final viewportKey = GlobalKey();
      final controller = q.QuillController(
        document: q.Document.fromJson([
          {'insert': '很长的一句话，长到足以让选区落在靠近右边的地方\n'},
        ]),
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: Stack(
              key: viewportKey,
              children: [
                q.QuillEditor(
                  controller: controller,
                  focusNode: FocusNode(),
                  scrollController: ScrollController(),
                  config: q.QuillEditorConfig(
                    editorKey: editorKey,
                    enableSelectionToolbar: false,
                  ),
                ),
                EditorToolbar(
                  controller: controller,
                  editorKey: editorKey,
                  viewportKey: viewportKey,
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final length = controller.document.length - 1;
      controller.updateSelection(
        TextSelection(baseOffset: length - 4, extentOffset: length),
        q.ChangeSource.local,
      );
      await tester.pumpAndSettle();

      final rect = toolbarAnchor(
        editorState: editorKey.currentState,
        viewportKey: viewportKey,
        selection: controller.selection,
        toolbarWidth: 320,
        toolbarHeight: 44,
      )!;
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
    });

    testWidgets('拿不到几何信息 → null（不画，而不是画在 (0,0)）', (tester) async {
      expect(
        toolbarAnchor(
          editorState: null,
          viewportKey: GlobalKey(),
          selection: const TextSelection(baseOffset: 0, extentOffset: 1),
          toolbarWidth: 100,
          toolbarHeight: 44,
        ),
        isNull,
      );
    });
  });
}
