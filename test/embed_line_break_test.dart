import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/embed_line_break.dart';

/// 块级嵌入（图片 / 表格）落进文档后，**那一行只能有嵌入**。
///
/// flutter_quill 的 `Line` 文档注释把这条写死了（"When a line contains an
/// embed, it fully occupies the line, no other embeds or text nodes are
/// allowed."），而 `replaceText` 不管这件事 —— 所以插入前必须先把行劈开。
/// 这里用**真的插一个块嵌入**来验，而不是只看返回的偏移。
List<Map<String, dynamic>> _doc(String plain) => [
      {'insert': plain},
    ];

/// 把 delta 按行切开（一行的结束就是字符串 op 里的 `\n`），
/// 返回「含有嵌入的那些行」。
List<List<Map<String, dynamic>>> _embedLines(List<dynamic> json) {
  final lines = <List<Map<String, dynamic>>>[];
  var current = <Map<String, dynamic>>[];
  for (final op in json) {
    if (op is! Map) continue;
    final map = Map<String, dynamic>.from(op);
    final insert = map['insert'];
    if (insert is String && insert.contains('\n')) {
      // 「甲\n乙」这种一个 op 跨两行的形状（`replaceText` 会这么写）要拆开。
      final parts = insert.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].isNotEmpty) {
          current.add(<String, dynamic>{'insert': parts[i]});
        }
        if (i < parts.length - 1) {
          lines.add(current);
          current = <Map<String, dynamic>>[];
        }
      }
      continue;
    }
    current.add(map);
  }
  if (current.isNotEmpty) lines.add(current);
  return lines
      .where((line) => line.any((op) => op['insert'] is Map))
      .toList();
}

void check(String label, String plain, int cursor) {
  test('$label：行中/行首/行尾插嵌入后，那一行只有嵌入', () {
    final controller = q.QuillController(
      document: q.Document.fromJson(_doc(plain)),
      selection: TextSelection.collapsed(offset: cursor),
    );
    addTearDown(controller.dispose);

    final at = EmbedLineBreak.at(controller, cursor);
    controller.replaceText(
      at,
      0,
      q.BlockEmbed('x-email-table', '<table></table>'),
      TextSelection.collapsed(offset: at + 1),
    );

    final delta = controller.document.toDelta().toJson();
    final lines = _embedLines(delta);
    expect(lines.length, 1, reason: '$label：嵌入应当独占一行（delta=$delta）');
    final line = lines.single;
    final text = line
        .where((op) => op['insert'] is String)
        .map((op) => op['insert'] as String)
        .join();
    expect(
      text,
      isEmpty,
      reason: '$label 的嵌入那一行还留着文字：$text（delta=$delta）',
    );
    expect(line.where((op) => op['insert'] is Map).length, 1);
  });
}

void main() {
  check('行中', '你好世界\n', 2);
  check('行首', '你好世界\n', 0);
  check('行尾', '你好世界\n', 4);
  check('段首（第二段）', '第一段\n第二段\n', 4);
  check('空文档', '\n', 0);

  test('越界的光标位置会被夹进文档内（不抛）', () {
    final controller = q.QuillController(
      document: q.Document.fromJson(_doc('短\n')),
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);
    expect(() => EmbedLineBreak.at(controller, 999), returnsNormally);
    expect(() => EmbedLineBreak.at(controller, -5), returnsNormally);
  });

  test('光标已经独占一行时，返回原位置（不多插换行）', () {
    final controller = q.QuillController(
      document: q.Document.fromJson(_doc('甲\n\n乙\n')),
      selection: const TextSelection.collapsed(offset: 2),
    );
    addTearDown(controller.dispose);
    final before = controller.document.toPlainText();
    expect(EmbedLineBreak.at(controller, 2), 2);
    expect(controller.document.toPlainText(), before);
  });
}
