import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/rewrite_selection.dart';

q.QuillController controllerWith(String text, {int? start, int? end}) {
  final doc = q.Document.fromJson([{'insert': '$text\n'}]);
  return q.QuillController(
    document: doc,
    selection: start == null
        ? const TextSelection.collapsed(offset: 0)
        : TextSelection(baseOffset: start, extentOffset: end ?? start),
  );
}

/// 正文里嵌一张图（`ab` + image + `cd`）。文档纯文本里图片占一个 U+FFFC，
/// 所以各文本偏移量是：a=0, b=1, 图片=2, c=3, d=4, 换行=5。
q.QuillController controllerWithImage({int? start, int? end}) {
  final doc = q.Document.fromJson([
    {'insert': 'ab'},
    {'insert': {'image': 'https://x/y.png'}},
    {'insert': 'cd\n'},
  ]);
  return q.QuillController(
    document: doc,
    selection: start == null
        ? const TextSelection.collapsed(offset: 0)
        : TextSelection(baseOffset: start, extentOffset: end ?? start),
  );
}

void main() {
  test('选中文本按顺序取出（含中文）', () {
    final c = controllerWith('今天天气不错', start: 2, end: 4);
    expect(RewriteSelection.selectedText(c), '天气');
  });

  test('反向选区（从后往前拖）取到的仍是正序文本', () {
    final c = controllerWith('今天天气不错', start: 4, end: 2);
    expect(RewriteSelection.selectedText(c), '天气');
  });

  test('选区折叠时选中文本是空串', () {
    final c = controllerWith('abc', start: 1, end: 1);
    expect(RewriteSelection.selectedText(c), '');
  });

  test('替换选区：原文被换掉，其余不动，光标落在新文本之后', () {
    final c = controllerWith('今天天气不错', start: 2, end: 4);
    expect(RewriteSelection.replaceSelection(c, '气候'), isTrue);
    expect(c.document.toPlainText(), '今天气候不错\n');
    expect(c.selection.baseOffset, 4);
    expect(c.selection.isCollapsed, isTrue);
  });

  test('替换能一次 Ctrl+Z 全部回退（不是逐字符撤）', () {
    final c = controllerWith('今天天气不错', start: 2, end: 4);
    RewriteSelection.replaceSelection(c, '气候宜人又舒服');
    expect(c.document.toPlainText(), '今天气候宜人又舒服不错\n');
    c.undo();
    expect(c.document.toPlainText(), '今天天气不错\n',
        reason: '一次改写应当是一次可撤销的编辑');
  });

  test('选区折叠时替换什么都不做（避免「改写」变成「插入」）', () {
    final c = controllerWith('abc', start: 1, end: 1);
    expect(RewriteSelection.replaceSelection(c, 'ZZZ'), isFalse);
    expect(c.document.toPlainText(), 'abc\n');
  });

  test('替换成多段文本 → 自然拆成多个块', () {
    final c = controllerWith('甲', start: 0, end: 1);
    RewriteSelection.replaceSelection(c, '第一行\n第二行');
    expect(c.document.root.children.length, 2);
    expect(c.document.toPlainText(), '第一行\n第二行\n');
  });

  test('插入到下方：原文保留，新内容另起一段', () {
    final c = controllerWith('原文', start: 0, end: 2);
    RewriteSelection.insertBelow(c, '建议');
    expect(c.document.toPlainText(), '原文\n建议\n');
    expect(c.document.root.children.length, 2);
  });

  test('插入到下方：多段建议也拆成块', () {
    final c = controllerWith('原文', start: 0, end: 2);
    RewriteSelection.insertBelow(c, 'A\nB');
    expect(c.document.root.children.length, 3);
  });

  test('规范化：CRLF / 围栏 / 零宽字符 / 连空行', () {
    expect(RewriteSelection.normalize('a\r\nb'), 'a\nb');
    expect(RewriteSelection.normalize('```\n正文\n```'), '正文');
    expect(RewriteSelection.normalize('```dart\nvar a;\n```'), 'var a;');
    expect(RewriteSelection.normalize('有​零宽'), '有零宽');
    expect(RewriteSelection.normalize('a\n\n\n\n\nb'), 'a\n\nb');
    expect(RewriteSelection.normalize('\n\n 正文 \n\n'), '正文');
  });

  test('规范化不碰行内的反引号（那是行内代码，是合法内容）', () {
    expect(RewriteSelection.normalize('用 `var` 声明'), '用 `var` 声明');
  });

  test('markdown → ops：粗体与行内代码转成属性', () {
    final ops = RewriteSelection.markdownToOps('这是**重点**和`代码`。');
    expect(ops.length, 5);
    expect(ops[1]['attributes'], {'bold': true});
    expect(ops[1]['insert'], '重点');
    expect(ops[3]['attributes'], {'code': true});
  });

  test('markdown → ops：没有标记时只有一段', () {
    final ops = RewriteSelection.markdownToOps('普通文本');
    expect(ops.length, 1);
    expect(ops.single['insert'], '普通文本');
  });

  test('markdown → ops：开头就是标记', () {
    final ops = RewriteSelection.markdownToOps('**开头**结尾');
    expect(ops.first['attributes'], {'bold': true});
    expect(ops.last['insert'], '结尾');
  });

  test('markdown → ops：单星号斜体**不**处理（猜错格式比不猜更糟）', () {
    final ops = RewriteSelection.markdownToOps('*斜*');
    expect(ops.length, 1);
    expect(ops.single['insert'], '*斜*');
  });

  // ---- H-1：围栏语言标记带连字符 / # / + 时也要剥干净 ----
  test('H-1：objective-c / objective-c++ / c# / f# / vue-ts 围栏都被剥掉', () {
    expect(RewriteSelection.normalize('```objective-c\nNSLog(@"x");\n```'),
        'NSLog(@"x");');
    expect(RewriteSelection.normalize('```objective-c++\nint x;\n```'), 'int x;');
    expect(RewriteSelection.normalize('```c#\nvar x = 1;\n```'), 'var x = 1;');
    expect(RewriteSelection.normalize('```f#\nlet x = 1\n```'), 'let x = 1');
    expect(RewriteSelection.normalize('```vue-ts\n<p>hi</p>\n```'), '<p>hi</p>');
    // 原有无语言标记的围栏继续有效。
    expect(RewriteSelection.normalize('```\n正文\n```'), '正文');
  });

  // ---- M-2：replaceSelection / insertBelow 入口做换行规范化 ----
  test('M-2：replaceSelection 传入的 CRLF 不会把 \\r 带进文档', () {
    final c = controllerWith('hello world', start: 0, end: 5);
    expect(RewriteSelection.replaceSelection(c, 'A\r\nB'), isTrue);
    expect(c.document.toPlainText().contains('\r'), isFalse);
    expect(c.document.toPlainText(), 'A\nB world\n');
  });

  test('M-2：单独的 \\r 也被规范化成 \\n', () {
    final c = controllerWith('hello world', start: 0, end: 5);
    RewriteSelection.replaceSelection(c, 'A\rB');
    expect(c.document.toPlainText().contains('\r'), isFalse);
    expect(c.document.toPlainText(), 'A\nB world\n');
  });

  test('M-2：insertBelow 传入的 CRLF 同样被规范化', () {
    final c = controllerWith('原文', start: 0, end: 2);
    RewriteSelection.insertBelow(c, 'A\r\nB');
    expect(c.document.toPlainText().contains('\r'), isFalse);
    expect(c.document.toPlainText(), '原文\nA\nB\n');
  });

  // ---- M-3：选区含嵌入时拒绝改写，保住图片 ----
  test('M-3：选区含内联图 → 拒绝改写且文档逐字不变', () {
    // 选区 [0,5) 覆盖 `ab￼cd`，其中 ￼ 就是图片嵌入。
    final c = controllerWithImage(start: 0, end: 5);
    final before = c.document.toDelta().toJson();
    expect(RewriteSelection.replaceSelection(c, 'XX'), isFalse);
    expect(c.document.toDelta().toJson(), before,
        reason: '拒绝改写时一个字都不能动（图片必须还在）');
    expect(c.document.toDelta().toJson().toString(), contains('https://x/y.png'));
  });

  test('M-3：选区不含嵌入 → 仍能正常改写', () {
    final c = controllerWithImage(start: 0, end: 2); // 只选 `ab`
    expect(RewriteSelection.replaceSelection(c, 'ZZ'), isTrue);
    expect(c.document.toPlainText(), 'ZZ￼cd\n',
        reason: '图片（U+FFFC）被原地保留');
  });

  test('M-3：selectedText 对含嵌入的选区把嵌入显式排除（图片在纯文本里不可表达）', () {
    final c = controllerWithImage(start: 0, end: 5);
    // 约定：嵌入在 selectedText 里被**排除**（不返回 U+FFFC），因为改写输入是
    // 纯文本、塞不进图片；「选区是否含嵌入」由 replaceSelection 自己另行判定。
    // 这里钉住这个取向，避免以后有人误以为图片被带上了。
    expect(RewriteSelection.selectedText(c), 'abcd');
    expect(RewriteSelection.selectedText(c).contains('￼'), isFalse);
  });

  test('M-3：选区不含嵌入时 selectedText 行为不变', () {
    final c = controllerWith('今天天气不错', start: 2, end: 4);
    expect(RewriteSelection.selectedText(c), '天气');
  });

  // ---- 缺口 1：选区「会不会被拒、为什么」要能预先判定（供界面提示） ----
  group('replaceability：不改文档就能知道结局', () {
    test('正常选区 → ok', () {
      final c = controllerWith('今天天气不错', start: 2, end: 4);
      expect(RewriteSelection.replaceability(c), SelectionReplaceability.ok);
    });

    test('折叠选区 → collapsed（「选区不在了」这一类）', () {
      final c = controllerWith('abc', start: 1, end: 1);
      expect(RewriteSelection.replaceability(c), SelectionReplaceability.collapsed);
    });

    test('选区含内联图 → hasEmbed（与 collapsed 区分开）', () {
      final c = controllerWithImage(start: 0, end: 5);
      expect(
        RewriteSelection.replaceability(c),
        SelectionReplaceability.hasEmbed,
      );
    });

    test('选区不含嵌入（只选图前文字）→ ok', () {
      final c = controllerWithImage(start: 0, end: 2);
      expect(RewriteSelection.replaceability(c), SelectionReplaceability.ok);
    });

    test('判定与 replaceSelection 的结论一致（判 ok 就真的能改）', () {
      final c = controllerWith('今天天气不错', start: 2, end: 4);
      expect(RewriteSelection.replaceability(c), SelectionReplaceability.ok);
      expect(RewriteSelection.replaceSelection(c, '气候'), isTrue);
    });
  });
}
