import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/slash_command.dart';

q.QuillController at(String text, int offset) => q.QuillController(
      document: q.Document.fromJson([{'insert': '$text\n'}]),
      selection: TextSelection.collapsed(offset: offset),
    );

q.QuillController selected(String text, int a, int b) => q.QuillController(
      document: q.Document.fromJson([{'insert': '$text\n'}]),
      selection: TextSelection(baseOffset: a, extentOffset: b),
    );

void main() {
  test('空行敲 / → 弹出，query 为空', () {
    final c = at('/', 1);
    final t = SlashCommand.detect(c)!;
    expect(t.query, '');
    expect(t.start, 0);
    c.dispose();
  });

  test('敲了几个字 → query 跟着走', () {
    final c = at('/biaoti', 7);
    final t = SlashCommand.detect(c)!;
    expect(t.query, 'biaoti');
    expect(t.start, 0);
    c.dispose();
  });

  test('段中间的 / 不触发（A/B）', () {
    expect(SlashCommand.detect(at('A/B', 3)), isNull);
  });

  test('URL 里的 // 不触发', () {
    expect(SlashCommand.detect(at('见 http://x', 11)), isNull);
  });

  test('行首但前面有文字的行不触发（只有第一行行首才算）', () {
    expect(SlashCommand.detect(at('上一行\n/表', 8)), isNull);
  });

  test('第二行行首的 / 触发，且 start 是这一行的位置', () {
    final c = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '上一行\n'},
        {'insert': '/表\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 6),
    );
    final t = SlashCommand.detect(c)!;
    expect(t.query, '表');
    expect(t.start, 4);
    c.dispose();
  });

  test('查询串里有空格 → 不触发（在写路径）', () {
    expect(SlashCommand.detect(at('/usr loc', 8)), isNull);
  });

  test('查询串过长 → 不触发', () {
    final long = '/${'a' * 30}';
    expect(SlashCommand.detect(at(long, long.length)), isNull);
  });

  test('有选区（非折叠）→ 不触发', () {
    expect(SlashCommand.detect(selected('/abc', 1, 3)), isNull);
  });

  test('光标不在文末也算（在 / 后面回退过）', () {
    expect(SlashCommand.detect(at('/abcd', 3))!.query, 'ab');
  });

  test('当前行「有文字又有嵌入」→ 不触发（哪怕 / 在行首）', () {
    // F-5：嵌入渲染成 `￼`。一行里既有文字又有嵌入是渲染不正常的坏形状，
    // 它的行文本是 `ab￼/表` 这样的拼接串。旧的「行首 /」判据会被糊弄：
    // `/ab￼表` 这种行（`/` 在行首、嵌入夹在中间）以前会弹出菜单。
    final mixed = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '/ab'},
        {'insert': {q.BlockEmbed.imageType: 'data:image/png;base64,AA=='}},
        {'insert': '表\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 5),
    );
    expect(SlashCommand.detect(mixed), isNull);
    mixed.dispose();
  });

  test('行首就是嵌入、后面跟 `/表` → 也不触发', () {
    final c = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '/'},
        {'insert': {q.BlockEmbed.imageType: 'data:image/png;base64,AA=='}},
        {'insert': '表\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 3),
    );
    expect(SlashCommand.detect(c), isNull);
    c.dispose();
  });

  test('纯文字行首 `/表` → 仍正常触发', () {
    final c = at('/表', 2);
    final t = SlashCommand.detect(c)!;
    expect(t.query, '表');
    expect(t.start, 0);
    c.dispose();
  });

  test('过滤：空 query 给全部（含 AI）', () {
    expect(SlashCommand.filter('').length, SlashItem.values.length);
  });

  test('过滤：英文关键字', () {
    expect(SlashCommand.filter('tab'), contains(SlashItem.table));
    expect(SlashCommand.filter('h1'), contains(SlashItem.heading1));
  });

  test('过滤：中文关键字', () {
    expect(SlashCommand.filter('表格'), [SlashItem.table]);
    expect(SlashCommand.filter('引用'), [SlashItem.quote]);
  });

  test('过滤：没配 Key 时不给 AI 起草', () {
    expect(
      SlashCommand.filter('', allowAi: false),
      isNot(contains(SlashItem.aiDraft)),
    );
    expect(SlashCommand.filter('ai', allowAi: false), isEmpty);
  });

  test('过滤：匹配不到就是空列表（菜单显示「没有匹配项」）', () {
    expect(SlashCommand.filter('zzzz'), isEmpty);
  });

  test('清触发器：把 /query 整段删掉，光标落在原位置', () {
    final c = at('/表格', 3);
    final t = SlashCommand.detect(c)!;
    SlashCommand.clearTrigger(c, t);
    expect(c.document.toPlainText(), '\n');
    expect(c.selection.baseOffset, 0);
    c.dispose();
  });

  test('清触发器：后面还有字时只删 /query', () {
    final c = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '/表\n后面\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 2),
    );
    final t = SlashCommand.detect(c)!;
    SlashCommand.clearTrigger(c, t);
    expect(c.document.toPlainText(), '\n后面\n');
    c.dispose();
  });

  test('清触发器：带空格的 `/表 后面` 不触发，所以没有触发器可清', () {
    final c = at('/表 后面', 8);
    expect(SlashCommand.detect(c), isNull);
    c.dispose();
  });

  test('isOnEmptyLine：空白行算空行', () {
    expect(SlashCommand.isOnEmptyLine(at('  ', 2)), isTrue);
    expect(SlashCommand.isOnEmptyLine(at('x', 1)), isFalse);
    expect(SlashCommand.isOnEmptyLine(at('上一行\n', 4)), isTrue);
  });

  test('currentLine 给出行文本与起点', () {
    final c = q.QuillController(
      document: q.Document.fromJson([
        {'insert': 'aa\nbb\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 5),
    );
    final line = SlashCommand.currentLine(c);
    expect(line.text, 'bb');
    expect(line.start, 3);
    c.dispose();
  });
}
