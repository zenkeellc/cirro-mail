import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/compose/compose_html.dart';
import 'package:mail_app/features/compose/html/delta_to_email_html.dart';
import 'package:mail_app/features/compose/html/document_codec.dart';

void main() {
  group('ComposeHtml.replyQuote 现在产出 Delta', () {
    test('产出的是一个能 decode 回 Document 的 Delta JSON', () {
      final delta = ComposeHtml.replyQuote(
        _row(),
        ossBase: 'https://oss.example.com',
        wroteLabel: '写道：',
      );
      // 这就是 `ComposeState.body` 将来躺的那个字符串的形状。
      expect(delta.trimLeft().startsWith('['), isTrue);
      final doc = DocumentCodec.decode(delta);
      expect(doc.toPlainText(), contains('写道：'));
      expect(doc.toPlainText(), contains('第一段'));
      // 引用块是**行属性**，不是 HTML 标签 —— 它现在是一个能被编辑的块。
      final ops = jsonDecode(delta) as List<dynamic>;
      expect(
        ops.any((op) =>
            op is Map &&
            (op['attributes'] as Map?)?['blockquote'] == true),
        isTrue,
        reason: '引用块没有落成 blockquote 行属性的话，它在编辑器里'
            '只是一段普通缩进文字，用户改完发出去就不再是引用了',
      );
    });

    test('引用块与正文之间有一条横线（`---` 那一段），且引用区带标记', () {
      // 用户要的就是那条线：Web 端只有一条 1px 左边框，长回复里分不开。
      // 导出时 `---` → `<hr>`（见 `delta_to_email_html.dart` 与
      // `mail_html_to_delta.dart` 的 `_markDividers`），这里是它的入口那半。
      final delta = ComposeHtml.replyQuote(
        _row(),
        ossBase: '',
        wroteLabel: '写道：',
      );
      final doc = DocumentCodec.decode(delta);
      expect(doc.toPlainText(), contains('---'));
      final ops = jsonDecode(delta) as List<dynamic>;
      final marked = ops
          .where((op) =>
              op is Map &&
              (op['attributes'] as Map?)?['mail-quote'] == true)
          .length;
      expect(
        marked,
        greaterThanOrEqualTo(4),
        reason: '引用区（分隔线 / 归属行 / 原文各行）的行尾都得带 mail-quote —— '
            'AI 润色靠它把引用排除在外，漏标就会把别人的原信改写一遍',
      );
      // 分隔线本身也在标记里：它是随引用一起带进来的。
      expect(
        ops.first,
        <String, dynamic>{'insert': '\n---'},
        reason: '第一条 `---` 应该紧跟在留给用户的那个空行后面',
      );
    });

    test('encode → decode → encode 幂等（草稿反复存不会越长越怪）', () {
      final once = ComposeHtml.replyQuote(
        _row(),
        ossBase: '',
        wroteLabel: '写道：',
      );
      final twice = DocumentCodec.encode(DocumentCodec.decode(once));
      expect(twice, once);
    });

    test('空正文 + 引用块 → 引用块还在（转发一个字不写也是对的）', () {
      final doc = DocumentCodec.decode(
        ComposeHtml.forwardBody(_row(), ossBase: ''),
      );
      expect(doc.toPlainText(), contains('第一段'));
      // 转发与回复一样：横线在前，原文在后（用户裁定两条路一致处理）。
      expect(doc.toPlainText(), contains('---'));
    });
  });

  group('空正文的判定落在 Delta 这一层', () {
    test('空文档 / 只有空白的文档都算空', () {
      expect(DocumentCodec.isEmptyDelta(DocumentCodec.emptyDelta), isTrue);
      expect(
        DocumentCodec.isEmptyDelta(
          DocumentCodec.encode(DocumentCodec.decode('   \n')),
        ),
        isTrue,
      );
    });

    test('写了字就不算空', () {
      expect(
        DocumentCodec.isEmptyDelta(
          DocumentCodec.encode(DocumentCodec.decode('好\n')),
        ),
        isFalse,
      );
    });

    test('只有一张图的文档**不算空**', () {
      final withImage = jsonEncode(<dynamic>[
        <String, dynamic>{
          'insert': <String, dynamic>{
            'image': 'data:image/png;base64,AAA',
          },
        },
        <String, dynamic>{'insert': '\n'},
      ]);
      expect(DocumentCodec.isEmptyDelta(withImage), isFalse,
          reason: '一封只有图的信是能发出去的 —— 图在纯文本里是 ￼，'
              '不特判的话它会被当成空正文拦住');
    });

    test('导出的 HTML 对空文档**不为空** —— 所以不能拿它当判据', () {
      // 这一条是 probe67 的结论，钉在这里防将来有人「顺手简化」。
      expect(
        DeltaToEmailHtml.convert(
          jsonDecode(DocumentCodec.emptyDelta) as List<dynamic>,
        ).trim().isEmpty,
        isFalse,
      );
    });
  });
}

MailRow _row() => MailRow(
      emailId: 1,
      profileId: 'p1',
      accountId: 1,
      subject: '主题',
      sendEmail: 'alice@example.com',
      name: 'Alice',
      // `MailRow.createTime` 是 `DateTime?` —— **不能给字符串**
      // （构造函数不做转换，顺手写一个 `const` 会连带编译不过）。
      createTime: DateTime.parse('2026-10-10T12:00:00.000Z'),
      content: '<p>第一段</p><p>第二段</p>',
    );
