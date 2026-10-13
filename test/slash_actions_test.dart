import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/slash_actions.dart';
import 'package:mail_app/features/compose/editor/slash_command.dart';
import 'package:mail_app/features/compose/html/mail_html_to_delta.dart';
import 'package:mail_app/features/compose/table/table_model.dart';

/// 记下条目里那几个「由页面实现的动作」被调了几次，不真的去动文档 ——
/// 「点了哪个条目」与「条目干了什么」分开测，后者就是这一整个文件。
class Spy {
  var tables = 0;
  var images = 0;
  var drafts = 0;
  var rows = 0;
  var columns = 0;
}

/// 跑一个条目 —— **直接调它的 `run`，不经过任何界面**。
///
/// 早先这组断言是「打开底部『+』面板 → 点 `insert-heading1`」（见已删除的
/// `insert_menu_test.dart`）。面板删掉之后，界面那层只剩斜杠浮层
/// （`slash_menu_test.dart` 盯着），条目**行为**在这里直接验 —— 少一层宿主，
/// 也就少一处会跟着 UI 重构一起碎的断言。
Future<void> runItem(
  q.QuillController controller,
  SlashItem item, {
  Spy? spy,
}) async {
  final s = spy ?? Spy();
  final focus = FocusNode();
  addTearDown(focus.dispose);
  final context = SlashContext(
    controller: controller,
    focusNode: focus,
    onInsertTable: (rows, columns) {
      s.tables++;
      s.rows = rows;
      s.columns = columns;
    },
    onPickImage: () async => s.images++,
    onAiDraft: () async => s.drafts++,
  );
  await slashEntries.firstWhere((e) => e.item == item).run(context);
}

q.QuillController doc(String plain) => q.QuillController(
      document: q.Document.fromJson([
        {'insert': plain},
      ]),
      selection: TextSelection.collapsed(offset: plain.length - 1),
    );

/// 带**行属性**的文档（属性挂在行尾那个 `\n` 上）。
q.QuillController docWithLineAttr(
  String plain,
  String attrKey,
  Object attrValue,
) =>
    q.QuillController(
      document: q.Document.fromJson([
        {
          'insert': plain,
          'attributes': {attrKey: attrValue},
        },
      ]),
      selection: TextSelection.collapsed(offset: plain.length - 1),
    );

/// 整行属性（header / list / blockquote / code-block）落在**行尾那个 `\n`**
/// 上，不在行内文字上 —— 从 Delta 里找行属性就得看带 `\n` 的 op。
Map<String, dynamic> lineAttributes(q.QuillController controller) {
  for (final op in controller.document.toDelta().toJson()) {
    final insert = op['insert'];
    if (insert is String && insert.contains('\n') && op['attributes'] is Map) {
      return Map<String, dynamic>.from(op['attributes'] as Map);
    }
  }
  return const <String, dynamic>{};
}

void main() {
  group('emptyTable', () {
    test('尺寸可调', () {
      expect(emptyTable(rows: 2, columns: 4).rowCount, 2);
      expect(emptyTable(rows: 2, columns: 4).columnCount, 4);
    });

    test('默认 3×3、全空', () {
      final table = emptyTable();
      expect(table.rowCount, 3);
      expect(table.columnCount, 3);
      for (final row in table.cells) {
        for (final cell in row) {
          expect(cell, '');
        }
      }
      expect(table, isA<MailTableModel>());
    });
  });

  group('块级条目', () {
    test('大标题 → 行属性里出现 header:1', () async {
      final controller = doc('一句话\n');
      await runItem(controller, SlashItem.heading1);
      expect(lineAttributes(controller)['header'], 1);
      controller.dispose();
    });

    test('项目符号 → 行属性里出现 list:bullet', () async {
      final controller = doc('一句话\n');
      await runItem(controller, SlashItem.bulletList);
      expect(lineAttributes(controller)['list'], 'bullet');
      controller.dispose();
    });

    test('引用 → blockquote:true；代码块 → code-block:true', () async {
      final quoted = doc('一句话\n');
      await runItem(quoted, SlashItem.quote);
      expect(lineAttributes(quoted)['blockquote'], isTrue);
      quoted.dispose();

      final code = doc('一句话\n');
      await runItem(code, SlashItem.codeBlock);
      expect(lineAttributes(code)['code-block'], isTrue);
      code.dispose();
    });

    test('正文 → 把行属性全部清掉（从一个标题退回普通段落）', () async {
      final controller = doc('一句话\n');
      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 1),
        q.ChangeSource.local,
      );
      controller.formatSelection(q.Attribute.h1);
      await runItem(controller, SlashItem.paragraph);
      expect(lineAttributes(controller).containsKey('header'), isFalse);
      controller.dispose();
    });

    test('「正文」不会把引用标记一起清掉（AI 边界靠它）', () async {
      // `mail-quote` 是「这行是从旧邮件引用来的」，不是用户排出来的格式。
      // `getAllSelectionStyles()` 会把每一行的属性都捞出来，不特判的话
      // 「正文」一点就把引用标记清干净了 —— 下一次润色就会把引用一起改写，
      // 而且看不出发生过什么。
      final controller = q.QuillController(
        document: q.Document.fromJson([
          {'insert': '引用一行\n', 'attributes': {'mail-quote': true}},
        ]),
        selection: const TextSelection.collapsed(offset: 2),
      );
      await runItem(controller, SlashItem.paragraph);
      expect(
        lineAttributes(controller)[MailHtmlToDelta.quoteAttribute],
        isTrue,
        reason: '引用标记被「正文」清掉了 —— 润色的边界随之失效',
      );
      controller.dispose();
    });
  });

  group('分隔线（F-8：插之前要先清掉当前行的块属性）', () {
    test('正文里多出一段 `---`（导出时落成 <hr>）', () async {
      final controller = doc('上面\n');
      await runItem(controller, SlashItem.divider);
      expect(controller.document.toPlainText(), contains('---'));
      controller.dispose();
    });

    test('在 h1 行插 → 那一行的 \\n 不带 header', () async {
      final controller = docWithLineAttr('标题\n', 'header', 1);
      await runItem(controller, SlashItem.divider);
      expect(lineAttributes(controller).containsKey('header'), isFalse,
          reason: '插分隔线不该把当前行的块属性留在那个 \\n 上');
      controller.dispose();
    });

    test('在列表行插 → 不带 list', () async {
      final controller = docWithLineAttr('项目\n', 'list', 'bullet');
      await runItem(controller, SlashItem.divider);
      expect(lineAttributes(controller).containsKey('list'), isFalse);
      controller.dispose();
    });

    test('在代码块行插 → 不带 code-block', () async {
      final controller = docWithLineAttr('代码\n', 'code-block', true);
      await runItem(controller, SlashItem.divider);
      expect(lineAttributes(controller).containsKey('code-block'), isFalse);
      controller.dispose();
    });
  });

  group('页面回调那一半', () {
    test('表格条目 → 用的是默认 3×3', () async {
      final spy = Spy();
      await runItem(doc('正文\n'), SlashItem.table, spy: spy);
      expect(spy.tables, 1);
      expect(spy.rows, defaultTableRows);
      expect(spy.columns, defaultTableColumns);
    });

    test('图片条目 → 走 onPickImage', () async {
      final spy = Spy();
      await runItem(doc('正文\n'), SlashItem.image, spy: spy);
      expect(spy.images, 1);
    });

    test('AI 起草 → 走 onAiDraft', () async {
      final spy = Spy();
      await runItem(doc('正文\n'), SlashItem.aiDraft, spy: spy);
      expect(spy.drafts, 1);
    });
  });

  group('clearFormatting', () {
    test('块级与行内一起清', () {
      final controller = doc('一句话\n');
      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 1),
        q.ChangeSource.local,
      );
      controller.formatSelection(q.Attribute.bold);
      controller.formatSelection(q.Attribute.h1);

      clearFormatting(controller);

      expect(lineAttributes(controller).containsKey('header'), isFalse);
      final inline = controller.document.toDelta().toJson().any((op) {
        final attrs = op['attributes'];
        return attrs is Map && attrs['bold'] != null;
      });
      expect(inline, isFalse,
          reason: '「清除格式」留下了加粗的字，用户会以为没生效');
      controller.dispose();
    });
  });

  group('filterSlashEntries', () {
    test('空查询给全量；allowAi 为假时去掉 AI 条目', () {
      final all = filterSlashEntries('');
      expect(all.length, slashEntries.length);
      final noAi = filterSlashEntries('', allowAi: false);
      expect(noAi.any((e) => e.item == SlashItem.aiDraft), isFalse);
      // 其余条目一个不少 —— 过滤 AI 不该顺手把别的东西也滤掉。
      expect(noAi.length, all.length - 1);
    });

    test('按关键字表匹配', () {
      expect(
        filterSlashEntries('h1').map((e) => e.item),
        contains(SlashItem.heading1),
      );
      expect(
        filterSlashEntries('表格').map((e) => e.item),
        contains(SlashItem.table),
      );
    });

    test('按条目**标签**匹配（关键字表里没有的词也能中）', () {
      // `/大标题` 只在标签里能中 —— 见那个函数的注释。
      expect(
        filterSlashEntries('大标题').map((e) => e.item),
        contains(SlashItem.heading1),
      );
    });

    test('allowAi 为假时，敲 ai 也搜不出 AI 条目', () {
      expect(filterSlashEntries('ai', allowAi: false), isEmpty);
      expect(
        filterSlashEntries('ai').map((e) => e.item),
        contains(SlashItem.aiDraft),
      );
    });
  });
}
