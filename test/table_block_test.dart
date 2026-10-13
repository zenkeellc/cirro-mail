import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/table/table_block.dart';
import 'package:mail_app/features/compose/table/table_html_codec.dart';
import 'package:mail_app/features/compose/table/table_model.dart';

Widget host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

q.QuillController docWithTable(String html) => q.QuillController(
      document: q.Document.fromJson([
        {'insert': '前\n'},
        {
          'insert': {tableEmbedType: html},
        },
        {'insert': '\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );

/// 逐键驱动**平台文本输入通道**（而不是 `tester.enterText`）。
///
/// 为什么不能用 `tester.enterText`：它直接改 `EditableTextState` 的
/// `TextEditingValue`，**绕过**了 `TextInput` 连接。而 F-1 那个 bug 的表现
/// 恰恰是「element 被 key 重建 → 旧的平台连接被关掉、新 widget 的 controller
/// 没有 live 连接」—— 只有真走一遍 `updateEditingValue` 才看得见「第二次
/// 按键被吞」。所以这里必须先 `showKeyboard` 拿到连接，再逐键喂。
Future<void> typeByKey(WidgetTester tester, Finder field, String text) async {
  await tester.showKeyboard(field);
  var value = '';
  for (final ch in text.split('')) {
    value += ch;
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    ));
    await tester.pump();
  }
}

/// F-1 的宿主：把单元格回调**再喂回去**（用新模型重建 `MailTableBlock`），
/// 复刻 `MailTableEmbedBuilder` 的写回链路 —— 只有「内容变化 → 模型重建」
/// 这条回路存在时，key 里含内容导致的 element 重建才会真的把输入吞掉。
class RebuildingHost extends StatefulWidget {
  const RebuildingHost({super.key, required this.initial, this.rawHtml});

  final MailTableModel initial;
  final String? rawHtml;

  @override
  State<RebuildingHost> createState() => RebuildingHostState();
}

class RebuildingHostState extends State<RebuildingHost> {
  late MailTableModel model = widget.initial;
  final List<MailTableModel> seen = <MailTableModel>[];

  @override
  Widget build(BuildContext context) =>
      host(MailTableBlock(
        table: model,
        rawHtml: widget.rawHtml,
        callbacks: TableBlockCallbacks(
          onChanged: (next) => setState(() {
            seen.add(next);
            model = next;
          }),
          onHtmlChanged: (_, next) => setState(() {
            seen.add(next);
            model = next;
          }),
        ),
      ));
}

void main() {
  group('MailTableBlock 的网格与行列操作', () {
    testWidgets('渲染全部单元格；没选中时没有操作栏', (tester) async {
      var changes = 0;
      await tester.pumpWidget(host(MailTableBlock(
        table: MailTableModel(cells: [['甲', '乙'], ['丙', '丁']]),
        callbacks: TableBlockCallbacks(onChanged: (_) => changes++),
      )));
      await tester.pumpAndSettle();
      for (final text in ['甲', '乙', '丙', '丁']) {
        expect(find.text(text), findsOneWidget);
      }
      expect(find.text('下方插行'), findsNothing);
      expect(changes, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点一个格子 → 出操作栏；再操作就回调新模型', (tester) async {
      final seen = <MailTableModel>[];
      await tester.pumpWidget(host(MailTableBlock(
        table: MailTableModel(cells: [['甲', '乙']]),
        callbacks: TableBlockCallbacks(onChanged: seen.add),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-cell-0,0')));
      await tester.pumpAndSettle();
      expect(find.text('下方插行'), findsOneWidget);

      await tester.tap(find.text('右侧插列'));
      await tester.pumpAndSettle();
      expect(seen, hasLength(1));
      expect(seen.single.columnCount, 3);
      expect(seen.single.cells[0], ['甲', '', '乙']);
      expect(tester.takeException(), isNull);
    });

    // F-5（第二种表现）：点格子那一下**不能把格子自己重建掉**。
    //
    // 早先点一下格子的结果是「操作栏出来了，但焦点不在格子里」：`_active`
    // 一变，`Column` 的第 0 个槽位从 `SingleChildScrollView` 换成 `Padding`
    // （或者格子 `Container` 的 `color` 从 null 换成有颜色、子树里多出一层
    // `ColoredBox`），两处都会让 Flutter 把整棵子树重建 —— 被点中的
    // `TextField` 连同它的 `FocusNode` 一起被丢掉。
    testWidgets('F-5：点一下格子，格子真的拿到焦点（没被重建掉）', (tester) async {
      await tester.pumpWidget(host(MailTableBlock(
        table: MailTableModel(cells: [['甲', '乙']]),
        callbacks: TableBlockCallbacks(onChanged: (_) {}),
      )));
      await tester.pumpAndSettle();

      final field = find.byType(EditableText).first;
      final before = tester.widget<EditableText>(field).focusNode;
      await tester.tap(field);
      await tester.pumpAndSettle();

      final after = tester.widget<EditableText>(field).focusNode;
      expect(identical(before, after), isTrue,
          reason: '点一下就换 FocusNode 说明 element 被重建了');
      expect(after.hasFocus, isTrue, reason: '点了格子，焦点该在格子里');
      expect(FocusManager.instance.primaryFocus, same(after));
    });

    testWidgets('F-5：选中态切换不重建单元格（controller 是同一个）',
        (tester) async {
      await tester.pumpWidget(host(MailTableBlock(
        table: MailTableModel(cells: [['甲', '乙']]),
        callbacks: TableBlockCallbacks(onChanged: (_) {}),
      )));
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      final controllers = [
        for (var i = 0; i < fields.evaluate().length; i++)
          tester.widget<TextField>(fields.at(i)).controller,
      ];

      await tester.tap(find.byKey(const ValueKey('table-cell-0,0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-cell-0,1')));
      await tester.pumpAndSettle();

      for (var i = 0; i < controllers.length; i++) {
        expect(identical(controllers[i], tester.widget<TextField>(fields.at(i)).controller),
            isTrue,
            reason: '第 $i 个格子的输入控制器在选中态切换时换了对象');
      }
    });

    testWidgets('改单元格文字 → 回调新模型（内容变了 Table 才会重建）',
        (tester) async {
      final seen = <MailTableModel>[];
      await tester.pumpWidget(host(MailTableBlock(
        table: MailTableModel(cells: [['甲']]),
        callbacks: TableBlockCallbacks(onChanged: seen.add),
      )));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '改过了');
      await tester.pumpAndSettle();
      expect(seen, isNotEmpty);
      expect(seen.last.cellAt(0, 0), '改过了');
      expect(tester.takeException(), isNull);
    });

    testWidgets('只有一行时「删本行」置灰（空表格没有意义）', (tester) async {
      await tester.pumpWidget(host(MailTableBlock(
        table: MailTableModel(cells: [['甲']]),
        callbacks: TableBlockCallbacks(onChanged: (_) {}),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-cell-0,0')));
      await tester.pumpAndSettle();
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('删本行'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('readOnly 时不出现操作栏，格子也点不出选中态', (tester) async {
      await tester.pumpWidget(host(MailTableBlock(
        table: MailTableModel(cells: [['甲']]),
        callbacks: TableBlockCallbacks(onChanged: (_) {}),
        readOnly: true,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-cell-0,0')));
      await tester.pumpAndSettle();
      expect(find.text('下方插行'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('F-1 逐键输入（走平台文本输入通道）', () {
    testWidgets('连续敲多个字符会累积，不会被第二次按键吞掉', (tester) async {
      await tester.pumpWidget(RebuildingHost(
        initial: MailTableModel(cells: [
          [''],
        ]),
      ));
      await tester.pumpAndSettle();

      // 现状（key 里含内容）：第二次按键时 element 被重建、平台连接断掉，
      // controller.text 停在 'a'。修法是把 key 变成稳定的（只含行列）。
      await typeByKey(tester, find.byType(TextField), 'abc');
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'abc',
        reason: 'controller 里必须是累积的文本，而不是只剩第一个字符',
      );
      final seen = tester.state<RebuildingHostState>(find.byType(RebuildingHost)).seen;
      expect(seen, isNotEmpty);
      // 每次按键回调出来的模型也必须是累积的（写回文档用的是它）。
      expect(seen.last.cellAt(0, 0), 'abc');
      expect(tester.takeException(), isNull);
    });

    testWidgets('内容变化后选中态仍指向同一个格子', (tester) async {
      await tester.pumpWidget(RebuildingHost(
        initial: MailTableModel(cells: [
          ['', ''],
        ]),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-cell-0,0')));
      await tester.pumpAndSettle();
      // 选中 0,0 之后应当出现操作栏（那是选中态的唯一可见证据）。
      expect(find.text('下方插行'), findsOneWidget);

      await typeByKey(tester, find.byType(TextField).first, 'x');
      await tester.pumpAndSettle();

      // 内容变了（模型重建）但 key 稳定 → 选中态不该跳走；操作栏仍在。
      expect(find.text('下方插行'), findsOneWidget);
      // 光标仍落在被选中的那一格（选中态由 _active 驱动，且没被内容变化清掉）。
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'x',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('F-2 文本编辑只定点替换，不整表重编码', () {
    test('改一个格子不动没碰过的格子：<br> 保住', () {
      const html = '<table><tr><td>a<br>b</td><td>c</td></tr></table>';
      final out = editTableCellText(html, 0, 1, 'Z')!;
      expect(out, contains('a<br>b'), reason: '没碰的那一格里的语义换行必须还在');
      expect(TableHtmlCodec.decode(out)!.cellAt(0, 1), 'Z');
    });

    test('colspan 保住（不被拍平）', () {
      const html = '<table><tr><td colspan="2">A</td><td>B</td></tr></table>';
      // 注意 colspan 是**视图层**的东西：`TableHtmlCodec.decode` 一律忽略它
      // （网格要真能编辑），所以模型里这一行是两个格子 A、B。这里编辑第 2 个
      // （B），断言 colspan 仍留在**没碰**的第一个格子上。
      final out = editTableCellText(html, 0, 1, 'Z')!;
      expect(out, contains('colspan="2"'), reason: '合并单元格不能被拍平成普通 td');
      expect(TableHtmlCodec.decode(out)!.cellAt(0, 1), 'Z');
    });

    test('没碰的那一格首尾空格保住（不被 trim）', () {
      const html = '<table><tr><td>  x  </td><td>y</td></tr></table>';
      final out = editTableCellText(html, 0, 1, 'Z')!;
      expect(out, contains('  x  '), reason: '首尾空格是用户内容，不能 trim');
    });

    test('中间的空 <tr> 保住（不被吃掉）', () {
      const html =
          '<table><tr><td>a</td></tr><tr></tr><tr><td>b</td></tr></table>';
      final out = editTableCellText(html, 0, 0, 'Z')!;
      // 空行也要在：数一下 tr 数（不是靠 decode —— decode 本来就会跳过空行）。
      final rows = RegExp(r'<tr[\s>]').allMatches(out).length;
      expect(rows, 3, reason: '空 <tr> 不能被定点替换顺手删掉');
      expect(out, contains('>Z<'));
    });

    test('嵌套表格保住，且不多出模型行', () {
      const html =
          '<table><tr><td>A</td><td>n<table><tr><td>i1</td><td>i2</td></tr></table></td></tr>'
          '<tr><td>B</td><td>C</td></tr></table>';
      final before = TableHtmlCodec.decode(html)!.rowCount;
      final out = editTableCellText(html, 0, 0, 'Z')!;
      expect(out, contains('<table>'), reason: '内层表格必须还在');
      expect(
        TableHtmlCodec.decode(out)!.rowCount,
        before,
        reason: '定点替换不该改变行数',
      );
      expect(TableHtmlCodec.decode(out)!.cellAt(0, 0), 'Z');
    });

    test('被编辑的那一格确实变成新值，且序列化会转义', () {
      const html = '<table><tr><td>a</td><td>b</td></tr></table>';
      final out = editTableCellText(html, 0, 0, 'a < b & "c"')!;
      final decoded = TableHtmlCodec.decode(out)!;
      expect(decoded.cellAt(0, 0), 'a < b & "c"');
      expect(decoded.cellAt(0, 1), 'b');
    });

    test('越界的行列 / 非表格 HTML → null（调用方退回整表重编码），不抛', () {
      const html = '<table><tr><td>a</td></tr></table>';
      expect(editTableCellText(html, 5, 5, 'Z'), isNull);
      expect(editTableCellText(html, -1, 0, 'Z'), isNull);
      expect(editTableCellText('<p>不是表格</p>', 0, 0, 'Z'), isNull);
      expect(editTableCellText('', 0, 0, 'Z'), isNull);
    });

    testWidgets('MailTableBlock 文本编辑走 onHtmlChanged（定点），结构编辑走 onChanged',
        (tester) async {
      const raw = '<table><tr><td>a<br>b</td><td>c</td></tr></table>';
      final htmls = <String>[];
      final models = <MailTableModel>[];
      await tester.pumpWidget(host(MailTableBlock(
        table: TableHtmlCodec.decode(raw)!,
        rawHtml: raw,
        callbacks: TableBlockCallbacks(
          onChanged: models.add,
          onHtmlChanged: (html, next) {
            htmls.add(html);
            models.add(next);
          },
        ),
      )));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(1), 'Z');
      await tester.pumpAndSettle();

      expect(htmls, isNotEmpty);
      expect(htmls.last, contains('a<br>b'), reason: '未碰的格子必须保真');
      expect(models.last.cellAt(0, 1), 'Z');
      expect(tester.takeException(), isNull);
    });
  });

  group('MailTableEmbedBuilder 写回文档', () {
    testWidgets('改一个格子 → 文档里那个嵌入被换成新 HTML，位置不跑',
        (tester) async {
      final controller = docWithTable(
        TableHtmlCodec.encode(MailTableModel(cells: [['甲']])),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: q.QuillEditor(
              controller: controller,
              focusNode: FocusNode(),
              scrollController: ScrollController(),
              config: q.QuillEditorConfig(
                embedBuilders: [
                  MailTableEmbedBuilder(
                    controller: controller,
                    callbacks: TableBlockCallbacks(onChanged: (_) {}),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('甲'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '乙');
      await tester.pumpAndSettle();

      final ops = controller.document.toDelta().toJson();
      final embed = ops
          .cast<Map>()
          .map((op) => op['insert'])
          .whereType<Map>()
          .firstWhere((insert) => insert.containsKey(tableEmbedType));
      expect(embed[tableEmbedType], contains('>乙<'));
      // 嵌入还是**一个** op，且后面的换行还在 —— 没有把相邻内容吃掉。
      expect(ops.where((op) => op['insert'] is Map).length, 1);
      // 两行 —— `{'insert': '前\n'}` 是第 1 行，嵌入后面那个 `\n` 是第 2 行
      // 自己的收尾（不是第 3 行）。嵌入独占一行的判据在这里就看得见。
      expect(
        controller.document.root.children.map((n) => n.toPlainText()).toList(),
        ['前\n', '￼\n'],
      );
      expect(tester.takeException(), isNull);
      controller.dispose();
    });

    testWidgets('写回的光标落在嵌入之后（不嵌进对象内部）', (tester) async {
      final controller = docWithTable(
        TableHtmlCodec.encode(MailTableModel(cells: [['甲']])),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: q.QuillEditor(
              controller: controller,
              focusNode: FocusNode(),
              scrollController: ScrollController(),
              config: q.QuillEditorConfig(
                embedBuilders: [
                  MailTableEmbedBuilder(
                    controller: controller,
                    callbacks: TableBlockCallbacks(onChanged: (_) {}),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '乙');
      await tester.pumpAndSettle();
      expect(controller.selection.isCollapsed, isTrue);
      // 嵌入在 offset 2（「前\n」之后），光标应当落到 3。
      expect(controller.selection.extentOffset, 3);
      expect(tester.takeException(), isNull);
      controller.dispose();
    });

    testWidgets('F-2 端到端：改一格后，文档里的 HTML 里没碰过的格子仍保真',
        (tester) async {
      // 原始 HTML 带 `<br>`（解码会丢它）—— 定点替换必须把它留住。
      const raw = '<table><tr><td>a<br>b</td><td>c</td></tr></table>';
      final controller = docWithTable(raw);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: q.QuillEditor(
              controller: controller,
              focusNode: FocusNode(),
              scrollController: ScrollController(),
              config: q.QuillEditorConfig(
                embedBuilders: [
                  MailTableEmbedBuilder(
                    controller: controller,
                    callbacks: TableBlockCallbacks(onChanged: (_) {}),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(1), 'Z');
      await tester.pumpAndSettle();

      final ops = controller.document.toDelta().toJson();
      final embed = ops
          .cast<Map>()
          .map((op) => op['insert'])
          .whereType<Map>()
          .firstWhere((insert) => insert.containsKey(tableEmbedType));
      final out = embed[tableEmbedType] as String;
      expect(out, contains('a<br>b'), reason: '没碰的那一格里的 <br> 必须还在');
      expect(out, contains('>Z<'), reason: '被改的那一格应当是 Z');
      expect(tester.takeException(), isNull);
      controller.dispose();
    });

    testWidgets('脏 HTML 落进来也不崩（解不出来就给一张最小的表）', (tester) async {
      final controller = docWithTable('<p>这不是表格</p>');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: q.QuillEditor(
              controller: controller,
              focusNode: FocusNode(),
              scrollController: ScrollController(),
              config: q.QuillEditorConfig(
                embedBuilders: [
                  MailTableEmbedBuilder(
                    controller: controller,
                    callbacks: TableBlockCallbacks(onChanged: (_) {}),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      controller.dispose();
    });
  });
}
