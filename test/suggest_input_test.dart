import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_attachment.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/recipient.dart';
import 'package:mail_app/features/suggest/suggest_input.dart';

MailRow row({
  String? content,
  String? text,
  List<MailAttachment> attList = const <MailAttachment>[],
  String name = '张三',
  String sendEmail = 'alice@example.com',
  String subject = '主题',
  int unread = UnreadState.unread,
  int isStar = 0,
  String toEmail = 'me@example.com',
  List<Recipient> recipients = const <Recipient>[],
}) =>
    MailRow(
      emailId: 7,
      profileId: 'p1',
      subject: subject,
      sendEmail: sendEmail,
      name: name,
      toEmail: toEmail,
      recipients: recipients,
      unread: unread,
      isStar: isStar,
      createTime: DateTime.parse('2026-10-11T03:04:00.000Z'),
      content: content,
      text: text,
      attList: attList,
    );

void main() {
  group('剥引用链：先结构、后文本（spec §5.2）', () {
    test('平级 <blockquote> 之后的一切都算引用', () {
      final input = SuggestInput.build(row(
        content: '<p>这一轮</p><blockquote><p>旧信</p></blockquote><p>尾注</p>',
      ));
      expect(input.text, contains('这一轮'));
      expect(input.text, isNot(contains('旧信')));
      expect(input.text, isNot(contains('尾注')));
      expect(input.quotedDropped, isTrue);
    });

    test('Web 端包裹类（.gmail_quote）当引用 —— 它通常不带 <blockquote>', () {
      final input = SuggestInput.build(row(
        content: '<p>这一轮</p><div class="gmail_quote">旧的历史</div>',
      ));
      expect(input.text, contains('这一轮'));
      expect(input.text, isNot(contains('旧的历史')));
      expect(input.quotedDropped, isTrue);
    });

    test('包裹类里套着 blockquote：整块切掉，归属行也不留', () {
      final input = SuggestInput.build(row(
        content: '<div>这一轮</div>'
            '<div class="gmail_quote"><div>2026 年 10 月 1 日 张三 写道：</div>'
            '<blockquote>旧</blockquote></div>',
      ));
      expect(input.text, contains('这一轮'));
      expect(input.text, isNot(contains('写道：')));
      expect(input.text, isNot(contains('旧')));
    });

    test('#divRplyFwdMsg 与 [class*=yahoo_quoted] 一样认', () {
      final outlook = SuggestInput.build(row(
        content: '<p>这轮</p><div id="divRplyFwdMsg">旧的</div>',
      ));
      expect(outlook.text, isNot(contains('旧的')));
      expect(outlook.quotedDropped, isTrue);

      final yahoo = SuggestInput.build(row(
        content: '<p>这轮</p><div class="x yahoo_quoted_2024">旧的</div>',
      ));
      expect(yahoo.text, isNot(contains('旧的')));
      expect(yahoo.quotedDropped, isTrue);
    });

    test('没有引用时一个字不切，quotedDropped 是 false', () {
      final input = SuggestInput.build(row(
        content: '<p>就这一段</p><p>还有这一段</p>',
      ));
      expect(input.text, contains('就这一段'));
      expect(input.text, contains('还有这一段'));
      expect(input.quotedDropped, isFalse);
    });

    test('整封都是引用 → 正文空，quotedDropped 是 true', () {
      final input = SuggestInput.build(row(content: '<blockquote>只有旧信</blockquote>'));
      expect(input.bodyChars, 0);
      expect(input.hasBody, isFalse);
      expect(input.quotedDropped, isTrue);
    });

    test('块级标签之间要换行，不能粘成一坨', () {
      final input = SuggestInput.build(row(content: '<p>甲</p><p>乙</p><div>丙</div>'));
      expect(input.text, contains('甲\n乙\n丙'));
    });

    test('script / style 里的字不进正文', () {
      final input = SuggestInput.build(row(
        content: '<style>p{color:red}</style><p>正文</p><script>alert(1)</script>',
      ));
      expect(input.text, contains('正文'));
      expect(input.text, isNot(contains('color:red')));
      expect(input.text, isNot(contains('alert')));
    });

    test('content 为空时在 row.text 上做同样的归属行剥离', () {
      final input = SuggestInput.build(row(
        text: '这一轮说的话\n\n在 2026年10月1日 张三 写道：\n> 旧信',
      ));
      expect(input.text, contains('这一轮说的话'));
      expect(input.text, isNot(contains('旧信')));
      expect(input.text, isNot(contains('写道：')));
      expect(input.quotedDropped, isTrue);
    });

    test('纯文本英文的归属行也认（On … wrote: / -----Original Message-----）', () {
      final a = SuggestInput.build(
        row(text: 'Sounds good.\n\nOn Oct 1, 2026, Zhang wrote:\n> old'),
      );
      expect(a.text, contains('Sounds good.'));
      expect(a.text, isNot(contains('old')));
      expect(a.quotedDropped, isTrue);

      final b = SuggestInput.build(
        row(text: 'Fine.\n\n-----Original Message-----\nold stuff'),
      );
      expect(b.text, contains('Fine.'));
      expect(b.text, isNot(contains('old stuff')));
    });

    test('从下往上找？不 —— 从**上**往下取第一条归属行，之后全切', () {
      // 「先结构后文本」里文本那一支是按行找第一条，命中即切到末尾。
      final input = SuggestInput.build(
        row(text: '第一段\n在 2020 年 写道：\n中间\n在 2021 年 写道：\n末尾'),
      );
      expect(input.text, contains('第一段'));
      expect(input.text, isNot(contains('中间')));
      expect(input.text, isNot(contains('末尾')));
    });
  });

  group('8000 字符上限（spec §5.3）', () {
    test('超长时从头截，truncated 为 true，originalChars 是原本的字数', () {
      final body = '甲' * 9000;
      final input = SuggestInput.build(row(content: '<p>$body</p>'));
      expect(input.bodyChars, 8000);
      expect(input.originalChars, 9000);
      expect(input.truncated, isTrue);
    });

    test('刚好 8000 不算截断', () {
      final input = SuggestInput.build(row(content: '<p>${'甲' * 8000}</p>'));
      expect(input.bodyChars, 8000);
      expect(input.truncated, isFalse);
    });

    test('maxChars 可传（测试与将来调档用）', () {
      final input = SuggestInput.build(row(content: '<p>${'甲' * 50}</p>'), maxChars: 10);
      expect(input.bodyChars, 10);
      expect(input.originalChars, 50);
      expect(input.truncated, isTrue);
    });
  });

  group('抬头字段（spec §4.2 / §5.4）', () {
    test('附件只给名字与大小，不给内容也不给链接', () {
      final input = SuggestInput.build(row(
        content: '<p>正文</p>',
        attList: const <MailAttachment>[
          MailAttachment(attId: 1, emailId: 7, profileId: 'p1', filename: '季度报告.pdf', size: 1258291),
          MailAttachment(attId: 2, emailId: 7, profileId: 'p1', filename: '数据.xlsx', size: 348160),
        ],
      ));
      expect(input.attachmentCount, 2);
      expect(input.text, contains('季度报告.pdf'));
      expect(input.text, contains('1.2 MB'));
      expect(input.text, contains('数据.xlsx'));
      expect(input.text, contains('340 KB'));
    });

    test('没有附件时抬头里没有「附件」二字', () {
      final input = SuggestInput.build(row(content: '<p>正文</p>'));
      expect(input.attachmentCount, 0);
      expect(input.text, isNot(contains('附件')));
    });

    test('**没有「送信人」这一行** —— MailRow 里根本没有那个字段（计划事实 14）', () {
      final input = SuggestInput.build(row(content: '<p>正文</p>'));
      expect(input.text, isNot(contains('送信人')));
    });

    test('当前状态那一行解释「为什么池子里没有 star」', () {
      final unread = SuggestInput.build(row(content: '<p>正文</p>'));
      expect(unread.text, contains('未读'));

      final starred = SuggestInput.build(row(content: '<p>正文</p>', isStar: 1));
      expect(starred.text, contains('已加星标'));
    });

    test('截断时正文前面那句如实告诉模型（§5.3 不能偷偷截）', () {
      final input = SuggestInput.build(row(content: '<p>${'甲' * 9000}</p>'));
      expect(input.text, contains('已截断'));
      expect(input.text, contains('9000'));
      expect(input.text, contains('8000'));
    });

    test('正文与抬头之间有分隔线，正文从分隔线之后开始', () {
      final input = SuggestInput.build(row(content: '<p>正文第一句</p>'));
      final at = input.text.indexOf('正文第一句');
      final sep = input.text.indexOf('─');
      expect(sep, greaterThanOrEqualTo(0));
      expect(sep, lessThan(at));
    });
  });

  group('空正文', () {
    test('content 与 text 都空 → bodyChars 0、hasBody false', () {
      final input = SuggestInput.build(row());
      expect(input.bodyChars, 0);
      expect(input.hasBody, isFalse);
      expect(input.originalChars, 0);
      expect(input.truncated, isFalse);
    });

    test('只有 text 也能用', () {
      final input = SuggestInput.build(row(text: '摘要行里的一句话'));
      expect(input.hasBody, isTrue);
      expect(input.text, contains('摘要行里的一句话'));
    });
  });

  group('深嵌套的畸形 HTML（不可信输入，别把整个流程带走）', () {
    test('一万两千层嵌套不崩、还读得出正文', () {
      // 没有守卫时这一步实测 **2.1 秒之后抛 `StackOverflowError`** —— 那是
      // `Error` 不是 `Exception`，`_stripByDom` 里那个 `try/catch` 接不住，
      // 一次点击就把分析流程连人带面板一起带走。守卫走的是非递归扫描器。
      final html = '${'<div>' * 12000}<p>这一轮的正文</p>${'</div>' * 12000}';
      final input = SuggestInput.build(row(content: html));
      expect(input.text, contains('这一轮的正文'));
      expect(input.hasBody, isTrue);
    });

    test('降级**不**把 <script> / <style> 的源码喂给模型', () {
      // 深嵌套走的是 `_deepFallback` 而不是 `_htmlToPlainText`，两者跳过
      // script / style 的手法不一样 —— 这条钉住降级路也干净。
      final html = '${'<div>' * 12000}'
          '<style>p{color:red}</style>'
          '<p>正文</p>'
          '<script>alert(1)</script>'
          '${'</div>' * 12000}';
      final input = SuggestInput.build(row(content: html));
      expect(input.text, contains('正文'));
      expect(input.text, isNot(contains('color:red')));
      expect(input.text, isNot(contains('alert')));
    });

    test('深度**没**超限时走原来的 DOM 那支（守卫不许误伤正常邮件）', () {
      // 顺带钉住「引用照剥」没有被守卫改掉。
      final html = '${'<div>' * 20}<p>这一轮</p><blockquote>旧信</blockquote>'
          '${'</div>' * 20}';
      final input = SuggestInput.build(row(content: html));
      expect(input.text, contains('这一轮'));
      expect(input.text, isNot(contains('旧信')));
      expect(input.quotedDropped, isTrue);
    });
  });
}
