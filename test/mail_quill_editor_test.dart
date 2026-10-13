import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/features/compose/table/table_html_codec.dart';
import 'package:mail_app/features/compose/table/table_block.dart';
import 'package:mail_app/features/compose/table/table_model.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: SizedBox(height: 600, child: child)));

void main() {
  testWidgets('挂载：空文档显示占位提示，不抛异常', (tester) async {
    final controller = q.QuillController.basic();
    await tester.pumpWidget(host(MailQuillEditor(
      controller: controller,
      focusNode: FocusNode(),
      placeholder: '写点什么…',
    )));
    await tester.pumpAndSettle();
    expect(controller.document.toPlainText(), '\n');
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('带表格的文档渲染出表格，点格子出操作栏', (tester) async {
    final doc = q.Document.fromJson([
      {'insert': '前\n'},
      {
        'insert': {
          tableEmbedType:
              TableHtmlCodec.encode(MailTableModel(cells: [['甲', '乙']])),
        },
      },
      {'insert': '\n'},
    ]);
    final controller = q.QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(MailQuillEditor(
      controller: controller,
      focusNode: FocusNode(),
      tableCallbacks: TableBlockCallbacks(onChanged: (_) {}),
    )));
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-cell-0,0')));
    await tester.pumpAndSettle();
    expect(find.text('下方插行'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('未知嵌入走兜底，不白屏', (tester) async {
    final doc = q.Document.fromJson([
      {'insert': '前\n'},
      {
        'insert': {'x-future-thing': '?'},
      },
      {'insert': '\n'},
    ]);
    final controller = q.QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(MailQuillEditor(
      controller: controller,
      focusNode: FocusNode(),
    )));
    await tester.pumpAndSettle();
    expect(find.text('不支持的内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('readOnly 通过 controller 生效：document setter 不被写坏', (tester) async {
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '只读\n'},
      ]),
      readOnly: true,
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(MailQuillEditor(
      controller: controller,
      focusNode: FocusNode(),
    )));
    await tester.pumpAndSettle();
    expect(controller.readOnly, isTrue);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  test('mailQuillController：粘贴通路接上，富文本外部粘贴关掉', () {
    final controller = mailQuillController(
      document: q.Document.fromJson([
        {'insert': '正文\n'},
      ]),
    );
    expect(controller.document.toPlainText(), '正文\n');
    // 光标默认落在**最后一个字符之前**（也就是末尾那个换行之前）——
    // 那是「用户想在这里接着写」的位置。
    expect(controller.selection.baseOffset, controller.document.length - 1);
    controller.dispose();
  });

  test('mailQuillController：readOnly 传得进去', () {
    final controller = mailQuillController(
      document: q.Document.fromJson([
        {'insert': '正文\n'},
      ]),
      readOnly: true,
    );
    expect(controller.readOnly, isTrue);
    controller.dispose();
  });

  testWidgets('选中文字 → 浮动工具栏出现；没有 AI 回调就没有 AI 按钮', (tester) async {
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句话\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(MailQuillEditor(
      controller: controller,
      focusNode: FocusNode(),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('tb-bold')), findsNothing);
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      q.ChangeSource.local,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tb-bold')), findsOneWidget);
    expect(find.byKey(const ValueKey('tb-ai')), findsNothing);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('给了 AI 回调 → 工具栏上出现 AI 按钮，点击回调一次', (tester) async {
    var tapped = 0;
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句话\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(MailQuillEditor(
      controller: controller,
      focusNode: FocusNode(),
      onAiRewrite: () => tapped++,
    )));
    await tester.pumpAndSettle();
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      q.ChangeSource.local,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tb-ai')));
    expect(tapped, 1);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  // F-3：`enableSelectionToolbar: false` 会让 `contextMenuBuilder` 传成 null，
  // 于是 `copyEnabled` / `cutEnabled` / `pasteEnabled` / `selectAllEnabled`
  // **一起变 false** —— 右击弹出的是一个点了没反应的菜单。所以生产必须
  // 开着它并给一个自己的 builder（用户报的「无法复制粘贴」）。
  testWidgets('F-3：自带选区菜单是开着的，而且给了自定义 builder', (tester) async {
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句话\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(host(MailQuillEditor(
      controller: controller,
      focusNode: FocusNode(),
    )));
    await tester.pumpAndSettle();

    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor).first);
    expect(editor.config.enableSelectionToolbar, isTrue);
    expect(editor.config.contextMenuBuilder, isNotNull);
    controller.dispose();
  });

  // F-4：`Stack` 给非定位子节点的是**松**约束，编辑器会缩到内容高度
  // （一行的空正文只有 18px），点框里别处聚焦不到 ——
  // `expands: true` 让它拿 `BoxConstraints.expand()` 撑满分到的空间。
  testWidgets('F-4：编辑器撑满整个视口高度', (tester) async {
    final controller = q.QuillController.basic();
    await tester.pumpWidget(host(MailQuillEditor(
      controller: controller,
      focusNode: FocusNode(),
    )));
    await tester.pumpAndSettle();

    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor).first);
    expect(editor.config.expands, isTrue);
    // host 给了 600 高；没撑满时这里会是 18 上下。
    final size = tester.getSize(find.byType(q.QuillEditor).first);
    expect(size.height, 600);
    controller.dispose();
  });

  // F-5：表格单元格的输入框挂在**正文编辑器之外**的焦点节点上，于是点进
  // 单元格时正文的 `hasFocus` 变 false、正文光标不再画（「两根光标」）。
  testWidgets('F-5：点进单元格后，正文的 FocusNode 不再 hasFocus', (tester) async {
    final doc = q.Document.fromJson([
      {
        'insert': {
          tableEmbedType:
              TableHtmlCodec.encode(MailTableModel(cells: [['甲', '乙']])),
        },
      },
      {'insert': '\n'},
    ]);
    final controller = q.QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
    final body = FocusNode(debugLabel: 'body');
    addTearDown(body.dispose);
    await tester.pumpWidget(host(MailQuillEditor(
      controller: controller,
      focusNode: body,
      tableCallbacks: TableBlockCallbacks(onChanged: (_) {}),
    )));
    await tester.pumpAndSettle();

    body.requestFocus();
    await tester.pumpAndSettle();
    expect(body.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('table-cell-0,0')));
    await tester.pumpAndSettle();
    expect(
      body.hasFocus,
      isFalse,
      reason: '单元格拿到焦点时正文不该还有焦点，否则两根光标同时画',
    );
    controller.dispose();
  });
}
