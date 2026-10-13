import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/compose/compose_html.dart';
import 'package:mail_app/features/compose/compose_quote.dart';
import 'package:mail_app/features/compose/html/delta_to_email_html.dart';
import 'package:mail_app/features/compose/html/document_codec.dart';
import 'package:mail_app/features/compose/html/mail_html_to_delta.dart';

/// 「用户写的那部分」与「引用进来的旧邮件」之间的那条边界。
///
/// 这一组全是**纯逻辑**（不启 widget 树）：边界靠行属性 `mail-quote` 认，
/// 而那个属性是 [ComposeHtml.replyQuote] / [ComposeHtml.forwardBody] 在导入时
/// 打上去的。用户报的 bug 是「AI 润色把引用也改了」，这条边界就是它的修法。
void main() {
  group('引用标记', () {
    test('回复：分隔线 + 归属行 + 引用块都在标记里，用户区是空的', () {
      final delta = _delta(ComposeHtml.replyQuote(
        _row(),
        ossBase: '',
        wroteLabel: '写道：',
      ));
      // 一条都没敲时用户区就是空的 —— 润色该提示「正文还是空的」。
      expect(ComposeQuote.userEnd(delta), 0);
      expect(ComposeQuote.plainText(delta), '');

      // 引用区每一行的**行尾**都得带标记：分隔线、归属行、两段原文。
      // （归属行自己那个 `\n` 是 op4，所以是 4 个 op，不是 5 行里的每一个。）
      expect(_linesWithMarker(delta), hasLength(4));
      expect(ComposeQuote.userDelta(delta), isEmpty);
    });

    test('转发：同样有标记（用户裁定两条路一致处理）', () {
      final delta = _delta(ComposeHtml.forwardBody(_row(), ossBase: ''));
      expect(ComposeQuote.userEnd(delta), 0);
      expect(_linesWithMarker(delta), hasLength(3));
    });

    test('encode → decode → encode 幂等（标记过一趟 Document 还在）', () {
      final once = ComposeHtml.replyQuote(_row(), ossBase: '', wroteLabel: '写道：');
      expect(DocumentCodec.encode(DocumentCodec.decode(once)), once);
    });
  });

  group('userEnd', () {
    test('用户写了两行：边界落在引用前那个 \\n 上，不含行尾', () {
      // `Document.toDelta()` 把相邻同属性 op 合并，探针实测出现过
      // `{"insert":"你好\n谢谢\n---"}` —— 边界必须在**字符**上算。
      final delta = <dynamic>[
        {'insert': '你好\n谢谢\n---'},
        {'insert': '\n', 'attributes': {'mail-quote': true}},
        {'insert': '引用'},
        {'insert': '\n', 'attributes': {'mail-quote': true}},
      ];
      expect(ComposeQuote.userEnd(delta), 5);
      expect(ComposeQuote.plainText(delta), '你好\n谢谢');
    });

    test('没有标记（旧草稿 / 引用被整段删掉）：退化成「末尾换行之前」', () {
      final delta = <dynamic>[
        {'insert': '你好'},
        {'insert': '\n'},
      ];
      expect(ComposeQuote.userEnd(delta), 2);
      expect(ComposeQuote.plainText(delta), '你好');
    });

    test('空 delta 不会算出负数', () {
      expect(ComposeQuote.userEnd(const <dynamic>[]), 0);
    });

    test('标记落在文档第一行：边界是 0，不会变成 -1', () {
      final delta = <dynamic>[
        {'insert': '---'},
        {'insert': '\n', 'attributes': {'mail-quote': true}},
      ];
      expect(ComposeQuote.userEnd(delta), 0);
    });

    test('用户自己插的分隔线**不会**被当成引用边界', () {
      // 文本判据（「从上往下找到第一条内容正好是 `---` 的行」）在这里会把
      // 边界挪到用户自己插的那条分隔线上 —— `---` 之后的「乙」明明是用户写
      // 的，却会被算成引用、润色时被跳过。标记只认引用区那个属性，
      // 用户区的分隔线只是个普通段落，边界仍落在**带标记那一行**的行首前。
      final delta = <dynamic>[
        // 相邻同属性的 op 会被 `Document.toDelta()` 合并成一条，边界因此
        // 必须在**字符**上算。
        {'insert': '甲\n---\n乙'},
        {'insert': '\n', 'attributes': {'mail-quote': true}},
        {'insert': '引用'},
        {'insert': '\n', 'attributes': {'mail-quote': true}},
      ];
      // 标记挂在「乙」那一行的行尾 `\n` 上 → 那一行本身也是引用，
      // 用户区到「乙」之前为止（`甲\n---`）。
      expect(ComposeQuote.userEnd(delta), 5);
      final text = ComposeQuote.plainText(delta);
      expect(text, contains('甲'));
      expect(text, isNot(contains('引用')));
    });
  });

  group('userDelta', () {
    test('切出来的 op 只含用户文字，导出成 HTML 也不带引用', () {
      final delta = <dynamic>[
        {'insert': '你好\n---'},
        {'insert': '\n', 'attributes': {'mail-quote': true}},
        {'insert': '归属行'},
        {'insert': '\n', 'attributes': {'mail-quote': true}},
      ];
      final html = DeltaToEmailHtml.convert(ComposeQuote.userDelta(delta));
      expect(html, contains('你好'));
      expect(html, isNot(contains('归属行')));
      expect(html, isNot(contains('<hr')));
    });
  });

  group('润色落地（`ComposeScreen._replaceUserBody` 的算法）', () {
    /// 照着 `_replaceUserBody` 做一遍：`replaceText(0, userEnd, 新文字)`。
    void polish(q.Document doc, String text) {
      final end = ComposeQuote.userEnd(doc.toDelta().toJson());
      doc.replace(0, end, text);
    }

    test('引用一字不动，横线还在，用户那段被换掉', () {
      final doc = DocumentCodec.decode(
        ComposeHtml.replyQuote(_row(), ossBase: '', wroteLabel: '写道：'),
      );
      doc.insert(0, '你好');
      doc.insert(2, '\n谢谢');
      expect(ComposeQuote.plainText(doc.toDelta().toJson()), '你好\n谢谢');

      polish(doc, '您好');

      final after = doc.toDelta().toJson();
      // 用户那段没了、新文字在。
      expect(ComposeQuote.plainText(after), '您好');
      // 引用区与横线原样。
      final html = DeltaToEmailHtml.convert(after);
      expect(html, contains('第一段'));
      expect(html, contains('写道：'));
      expect(
        html,
        contains('<hr '),
        reason: '横线没了 = 替换把上一行的行尾 `\\n` 也吃掉了（userEnd 取错位置）',
      );
      expect(html, contains('<blockquote '));
      // 横线仍然是**自己独占一行**的那一段 `---`。
      expect(
        after.any(
            (op) => (op['attributes'] as Map?)?['mail-quote'] == true),
        isTrue,
        reason: '引用标记在替换之后必须还在 —— 没了的话下一次润色就会把引用也改一遍',
      );
    });

    test('旧草稿没有标记时，替换的是整篇（末尾 `\\n` 不动）', () {
      final doc = q.Document.fromJson(<dynamic>[
        {'insert': '你好\n'},
      ]);
      polish(doc, '您好');
      expect(doc.toPlainText(), '您好\n');
    });
  });

  group('hasEmbed', () {
    test('引用里的图片不算「用户正文里有图」', () {
      final delta = <dynamic>[
        {'insert': '你好'},
        {'insert': '\n'},
        {'insert': <String, dynamic>{'image': 'data:image/png;base64,AAA'}},
        {'insert': '\n', 'attributes': {'mail-quote': true}},
      ];
      expect(ComposeQuote.hasEmbed(delta), isTrue);
      expect(
        ComposeQuote.hasEmbed(delta, before: ComposeQuote.userEnd(delta)),
        isFalse,
        reason: '引用里的图不该拦住润色 —— 否则「回复一封带图的邮件」整条润色都用不了',
      );
    });

    test('用户自己写的图仍然拦得住', () {
      final delta = <dynamic>[
        {'insert': <String, dynamic>{'image': 'data:image/png;base64,AAA'}},
        {'insert': '\n'},
        {'insert': '引用'},
        {'insert': '\n', 'attributes': {'mail-quote': true}},
      ];
      expect(
        ComposeQuote.hasEmbed(delta, before: ComposeQuote.userEnd(delta)),
        isTrue,
      );
    });
  });

  group('标记不进收件人的邮件', () {
    test('整篇导出成 HTML 时看不到 mail-quote', () {
      final delta = _delta(ComposeHtml.replyQuote(
        _row(),
        ossBase: '',
        wroteLabel: '写道：',
      ));
      final html = DeltaToEmailHtml.convert(delta);
      expect(html, isNot(contains('mail-quote')));
      expect(html, isNot(contains('mail_quote')));
      // 横线仍然落成 <hr>，引用仍然是 blockquote。
      expect(html, contains('<hr '));
      expect(html, contains('<blockquote '));
    });
  });

  group('markQuoted', () {
    test('没有 `---` 那一行就原样返回', () {
      final ops = MailHtmlToDelta.convert('<p>你好</p>');
      expect(ComposeQuote.markQuoted(ops), same(ops));
      expect(
        _linesWithMarker(ComposeQuote.markQuoted(ops)),
        isEmpty,
      );
    });

    test('从第一条 `---` 起往后标，之前的一行不标', () {
      final ops = MailHtmlToDelta.convert(
        '<p>写在上面</p><hr><p>引用</p>',
      );
      final marked = ComposeQuote.markQuoted(ops);
      final json = marked.map((op) => jsonEncode(op)).toList();
      expect(json.first, contains('写在上面'));
      expect(json.first, isNot(contains(MailHtmlToDelta.quoteAttribute)));
      expect(
        marked.where((op) => (op['attributes'] as Map?)?[
                MailHtmlToDelta.quoteAttribute] == true),
        isNotEmpty,
      );
    });
  });
}

/// 每条带标记的 op 数一数 —— 一句话就能验「标记罩住了哪几行」。
List<Map<String, dynamic>> _linesWithMarker(List<dynamic> delta) => [
      for (final raw in delta)
        if (raw is Map &&
            raw['attributes'] is Map &&
            (raw['attributes'] as Map)[MailHtmlToDelta.quoteAttribute] == true)
          Map<String, dynamic>.from(raw),
    ];

List<dynamic> _delta(String json) =>
    (jsonDecode(json) as List<dynamic>).cast<dynamic>();

MailRow _row() => MailRow(
      emailId: 1,
      profileId: 'p1',
      accountId: 1,
      subject: '主题',
      sendEmail: 'alice@example.com',
      name: 'Alice',
      // `MailRow.createTime` 是 `DateTime?` —— 不能给字符串。
      createTime: DateTime.parse('2026-10-10T12:00:00.000Z'),
      content: '<p>第一段</p><p>第二段</p>',
    );
