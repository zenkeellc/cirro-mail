import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/html/document_codec.dart';

void main() {
  test('空串 → 可编辑的空文档（恰好一个块）', () {
    final doc = DocumentCodec.decode(null);
    expect(doc.toPlainText(), '\n');
    expect(doc.root.children.length, 1);
    doc.insert(0, '写');
    expect(doc.toPlainText(), '写\n');
  });

  test('旧纯文本草稿：按空行分段', () {
    final doc = DocumentCodec.decode('第一段\n\n第二段');
    expect(doc.toPlainText(), '第一段\n第二段\n');
    expect(doc.root.children.length, 2);
  });

  test('旧纯文本里单换行也分段（Quill 的「块」就是「行」）', () {
    final doc = DocumentCodec.decode('第一行\n第二行');
    expect(doc.toPlainText(), '第一行\n第二行\n');
    expect(doc.root.children.length, 2);
  });

  test('Delta JSON 往返无损（含块属性与行内属性）', () {
    final original = q.Document.fromJson([
      {'insert': '标题'},
      {
        'insert': '\n',
        'attributes': {'header': 1, 'align': 'center'},
      },
      {
        'insert': '粗',
        'attributes': {'bold': true},
      },
      {'insert': '\n'},
    ]);
    final backed = DocumentCodec.decode(DocumentCodec.encode(original));
    expect(backed.root.children.length, original.root.children.length);
    expect(backed.toPlainText(), original.toPlainText());
    expect(jsonEncode(backed.toDelta().toJson()), contains('"header":1'));
    expect(jsonEncode(backed.toDelta().toJson()), contains('"bold":true'));
  });

  test('段落边界不会因为 Delta 被合并而丢失（往返后还是两块）', () {
    final doc = DocumentCodec.decode('甲\n\n乙');
    final backed = DocumentCodec.decode(DocumentCodec.encode(doc));
    expect(backed.root.children.length, 2);
    expect(backed.toPlainText(), '甲\n乙\n');
  });

  test('结构像 Delta 但不合法 → 退到纯文本', () {
    expect(DocumentCodec.decode('[{"insert":123}]').toPlainText(),
        '[{"insert":123}]\n');
  });

  test('不是 JSON 的乱码 → 退到纯文本', () {
    expect(DocumentCodec.decode('{"broken":').toPlainText(), '{"broken":\n');
  });

  test('Delta 尾部不以换行收尾 → 不当 Delta，退到纯文本', () {
    expect(DocumentCodec.decode('[{"insert":"没换行"}]').toPlainText(),
        '[{"insert":"没换行"}]\n');
  });

  test('空文档 encode 出来是稳定的一行，且能 decode 回去', () {
    final stored = DocumentCodec.encode(DocumentCodec.empty());
    expect(stored, DocumentCodec.emptyDelta);
    expect(DocumentCodec.decode(stored).toPlainText(), '\n');
  });

  test('尾部空行原样保留（用户敲的，不许替他删）', () {
    final doc = q.Document.fromJson([
      {'insert': '末\n'},
      {'insert': '\n'},
    ]);
    expect(doc.toPlainText(), '末\n\n');
    expect(DocumentCodec.encode(doc), '[{"insert":"末\\n\\n"}]');
  });

  test('emoji 与中文混排：encode/decode 不丢字符', () {
    final doc = DocumentCodec.decode('早 🎉 好\n\n再见');
    expect(doc.toPlainText(), '早 🎉 好\n再见\n');
    final back = DocumentCodec.decode(DocumentCodec.encode(doc));
    expect(back.toPlainText(), doc.toPlainText());
  });

  // ---- 回归锁：换行符归一化（审阅第 1 条） ----

  test('旧草稿 CRLF 归一化：裸 \\r 不进 Delta', () {
    final doc = DocumentCodec.decode('第一行\r\n第二行');
    expect(doc.toPlainText(), '第一行\n第二行\n');
    expect(doc.root.children.length, 2);
    // 存下来的 Delta 里不允许出现任何 \r。
    expect(DocumentCodec.encode(doc), isNot(contains(r'\r')));
  });

  test('老式 CR（孤立的 \\r）也当换行，不把整段挤成一块', () {
    final doc = DocumentCodec.decode('a\rb');
    expect(doc.toPlainText(), 'a\nb\n');
    expect(doc.root.children.length, 2);
  });

  test('CRLF 分隔的空行 = 段落边界', () {
    final doc = DocumentCodec.decode('a\r\n\r\nb');
    expect(doc.toPlainText(), 'a\nb\n');
    expect(doc.root.children.length, 2);
  });

  // ---- 回归锁：分段与 trim 对齐 ComposeHtml.fromPlainText（审阅第 2 条） ----

  test('段落两侧空白被 trim 掉，与纯文本导出同构', () {
    final doc = DocumentCodec.decode('  a  \n\n  b  ');
    expect(doc.toPlainText(), 'a\nb\n');
    expect(doc.root.children.length, 2);
  });

  test('单空格「空行」不是段落分隔（\\n{2,} 才切段），内容不丢', () {
    // 与 ComposeHtml 形状不同（那边是一段、含 <br>），但旧草稿是「每行一块」，
    // 关键在于 trim 不能吃掉用户内容：这里保留成 a / ' ' / b 三块。
    final doc = DocumentCodec.decode('a\n \nb');
    expect(doc.toPlainText(), 'a\n \nb\n');
    expect(doc.root.children.length, 3);
  });

  // ---- 回归锁：畸形但被 Quill 宽容接受的 Delta（审阅第 3 条） ----

  test('畸形 Delta 被 Quill 宽容接受时不抛，且内容不丢', () {
    // 这批输入都能过嗅探（Map + insert，末 op 以 \n 结尾），且
    // flutter_quill 11.6 的 Document.fromJson 照单全收。
    const tolerated = <String>[
      '[{"insert":"a\\n"},{"insert":{"image":123}},{"insert":"\\n"}]',
      '[{"insert":"a\\n"},{"insert":"\\n","attributes":{"list":"ul","indent":"deep"}}]',
      '[{"insert":"a\\n"},{"insert":"\\n","attributes":{"link":"javascript:x"}}]',
      '[{"insert":"a\\n"},{"insert":{"video":"x"}},{"insert":"\\n"}]',
    ];
    for (final input in tolerated) {
      expect(() => DocumentCodec.decode(input), returnsNormally,
          reason: input);
      expect(DocumentCodec.decode(input).toPlainText(), startsWith('a'),
          reason: input);
    }
  });

  test('过得了嗅探但 Document.fromJson 会抛 → on Object 退到纯文本', () {
    // 审阅以为这个 catch 不可达；实测 flutter_quill 11.6 里 insert 为
    // null / bool / 数字 / List、attributes 非 Map 都会抛，于是走到这里。
    // 契约是不把异常漏给调用方：退成纯文本（连原始 JSON 一起显示成字）。
    const throwsInQuill = <String>[
      '[{"insert":"a\\n"},{"insert":null},{"insert":"\\n"}]',
      '[{"insert":"a\\n"},{"insert":true},{"insert":"\\n"}]',
      '[{"insert":"a\\n"},{"insert":123},{"insert":"\\n"}]',
      '[{"insert":"a\\n"},{"insert":["x"]},{"insert":"\\n"}]',
      '[{"insert":"a\\n"},{"insert":"\\n","attributes":"nope"}]',
    ];
    for (final input in throwsInQuill) {
      expect(() => DocumentCodec.decode(input), returnsNormally,
          reason: input);
      expect(DocumentCodec.decode(input).toPlainText(), '$input\n',
          reason: input);
    }
  });

  // ---- 回归锁：嵌入（图片 / 表格块）往返（审阅第 4 条） ----

  test('图片嵌入 decode(encode(...)) 往返无损', () {
    final original = q.Document.fromJson([
      {'insert': '前\n'},
      {'insert': {'image': 'https://e/a.png'}},
      {'insert': '\n'},
    ]);
    final stored = DocumentCodec.encode(original);
    expect(stored, contains('"image":"https://e/a.png"'));
    final back = DocumentCodec.decode(stored);
    expect(DocumentCodec.encode(back), stored);
    expect(jsonDecode(stored), jsonDecode(DocumentCodec.encode(back)));
  });

  test('表格块嵌入 decode(encode(...)) 往返无损', () {
    const stored =
        '[{"insert":"前\\n"},{"insert":{"x-email-table":"<table><tr><td>a</td></tr></table>"}},{"insert":"\\n"}]';
    final doc = DocumentCodec.decode(stored);
    expect(DocumentCodec.encode(doc), stored);
  });

  // ---- 回归锁：控制字符与孤立代理对 ----

  test('NUL 控制字符原样保留、不抛', () {
    final doc = DocumentCodec.decode('a\u0000b\n');
    expect(doc.toPlainText(), 'a\u0000b\n');
    expect(DocumentCodec.encode(doc), contains(r'\u0000'));
  });

  test('孤立代理对与超长/深嵌套输入都不抛', () {
    expect(() => DocumentCodec.decode('\ud83d'), returnsNormally);
    expect(() => DocumentCodec.decode('\udc00'), returnsNormally);
    expect(() => DocumentCodec.decode('x' * 200000), returnsNormally);
    expect(
      () => DocumentCodec.decode('${'[' * 2000}"x"${']' * 2000}'),
      returnsNormally,
    );
  });
}
