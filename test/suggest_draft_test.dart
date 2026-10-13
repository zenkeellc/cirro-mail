import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/compose/compose_html.dart';
import 'package:mail_app/features/compose/compose_quote.dart';
import 'package:mail_app/features/compose/html/document_codec.dart';
import 'package:mail_app/features/suggest/suggest_draft.dart';

const String _ossBase = 'https://oss.example.com';
const String _wrote = '写道：';

/// 一封别人发来的信：有完整正文（`replyQuote` 要它拼引用块）。
MailRow original() => MailRow(
      emailId: 7,
      profileId: 'p1',
      name: '张三',
      sendEmail: 'alice@example.com',
      subject: '上线时间',
      mailboxEmail: 'me@example.com',
      content: '<p>会议时间定了吗？</p>',
      createTime: DateTime.utc(2026, 10, 11, 3, 4),
    );

/// 用户区（引用块之前那一半）的**原始字符**。
///
/// 刻意**不走** `ComposeQuote.plainText`（Delta → HTML → 纯文本那一圈）：
/// `PlainText.fromHtml` 会把段落之间的换行变成空行再 `trim()`，于是
/// 「插进去的到底是哪几个字符」这件事在那一圈里量不准。这里直接拼
/// `userDelta` 的字符串 op —— 与探针量的是同一个东西。
String userRaw(String encoded) {
  final delta = DocumentCodec.decode(encoded).toDelta().toJson();
  final buffer = StringBuffer();
  for (final op in ComposeQuote.userDelta(delta)) {
    final insert = (op as Map)['insert'];
    if (insert is String) buffer.write(insert);
  }
  return buffer.toString();
}

/// 用户区到哪里为止（角色偏移）。探针量过：带引用块的新文档里它是
/// 「用户最后那一行的行尾 `\n` 的位置」，于是 `[0, end)` 正好是用户写的那几个字。
int userEnd(String encoded) =>
    ComposeQuote.userEnd(DocumentCodec.decode(encoded).toDelta().toJson());

/// 一份正文里有几行带引用标记。
int quoteLines(String encoded) {
  var count = 0;
  // 显式标成 `List<dynamic>`：`toJson()` 静态类型是 `List<Map<String, dynamic>>`，
  // 那样下面那句 `op is! Map` 就成了死代码（analyzer 会报
  // unnecessary_type_check / dead_code）。引用块那半边本来就可能混进非 Map 的
  // op（嵌入），守卫要真的活着 —— 与 `ComposeQuote` 里 `List<dynamic>` 参数上的
  // 那句同形。
  final List<dynamic> delta = DocumentCodec.decode(encoded).toDelta().toJson();
  for (final op in delta) {
    if (op is! Map) continue;
    if (ComposeQuote.isQuoteLine(op['attributes'])) {
      final insert = op['insert'];
      if (insert is String) {
        count += '\n'.allMatches(insert).length;
      }
    }
  }
  return count;
}

String replyBody(String aiText) => SuggestDraft.replyBody(
      row: original(),
      aiText: aiText,
      ossBase: _ossBase,
      wroteLabel: _wrote,
    );

void main() {
  test('AI 文本里的 `<` / `>` 是**字面字符**，不是标签（spec §6.2 那条契约）', () {
    const ai = '条件是 a < b 且 c > d\n';
    final body = replyBody(ai);

    // 最直接的证据：Delta 的 JSON 里就是这几个字符本身。
    expect(body, contains('a < b 且 c > d'));
    // 用户区读回来也还是它们（没有被哪一层转义过）。
    expect(userRaw(body), ai);
    expect(userRaw(body), isNot(contains('&lt;')));
    expect(userRaw(body), isNot(contains('&gt;')));
  });

  test('引用块还在：插 AI 文本不动它那半边', () {
    final quote = ComposeHtml.replyQuote(
      original(),
      ossBase: _ossBase,
      wroteLabel: _wrote,
    );
    final before = quoteLines(quote);
    expect(before, greaterThan(0), reason: '前提：replyQuote 本来就带引用标记');

    final body = replyBody('你好，\n\n我确认一下时间。\n');
    expect(quoteLines(body), before, reason: '引用块的行数一个字没变');
  });

  test('AI 文本插在**引用块上方**：userEnd 落在插入的那段之后', () {
    const ai = '你好，\n\n我确认一下时间。\n';
    expect(userRaw(replyBody(ai)), ai);
    // 探针实测：插 14 个字符之后 userEnd == 14（引用块的第一行从 15 开始）。
    expect(userEnd(replyBody(ai)), ai.length);
  });

  test('AI 文本是空的（或全空白）：正文与只有引用块的那一份**逐字相同**', () {
    final quote = ComposeHtml.replyQuote(
      original(),
      ossBase: _ossBase,
      wroteLabel: _wrote,
    );
    expect(replyBody(''), quote);
    expect(replyBody('   \n\n  '), quote);
  });

  group('`_asPlainBlock` 的归一化', () {
    test(r'\r\n 与 \r 都变成 \n', () {
      expect(userRaw(replyBody('甲\r\n乙\r丙')), '甲\n乙\n丙\n');
    });

    test('连续空行压成一个空行，结尾恰好一个 \\n', () {
      expect(userRaw(replyBody('甲\n\n\n\n乙\n\n\n')), '甲\n\n乙\n');
    });

    test('段落之间的单个空行留着', () {
      expect(userRaw(replyBody('第一段\n\n第二段')), '第一段\n\n第二段\n');
    });

    test('两端空白掐掉', () {
      expect(userRaw(replyBody('\n\n  中间  \n\n')), '中间\n');
    });
  });

  group('落进草稿表的那四个参数（spec §6.2）', () {
    test('答复：收件人是原发件人、主题加 Re: 前缀、发件邮箱是 row.mailboxEmail', () {
      final draft = SuggestDraft.reply(
        row: original(),
        aiText: '好的。\n',
        ossBase: _ossBase,
        wroteLabel: _wrote,
      );
      expect(draft.recipientsJson, '["alice@example.com"]');
      expect(draft.subject, 'Re: 上线时间');
      expect(draft.accountEmail, 'me@example.com');
      expect(draft.content, replyBody('好的。\n'));
    });

    test('已经是回复的主题不重复加前缀', () {
      final draft = SuggestDraft.reply(
        row: MailRow(
          emailId: 9,
          profileId: 'p1',
          sendEmail: 'bob@example.com',
          subject: 'Re：上线时间',
          mailboxEmail: 'me@example.com',
          content: '<p>好的</p>',
        ),
        aiText: '',
        ossBase: _ossBase,
        wroteLabel: _wrote,
      );
      expect(draft.subject, 'Re：上线时间');
    });

    test('原信没有发件人地址时收件人是空串（不猜）', () {
      final draft = SuggestDraft.reply(
        row: MailRow(
          emailId: 10,
          profileId: 'p1',
          subject: '无发件人',
          mailboxEmail: 'me@example.com',
          content: '<p>x</p>',
        ),
        aiText: '',
        ossBase: _ossBase,
        wroteLabel: _wrote,
      );
      expect(draft.recipientsJson, '');
    });

    test('转发：收件人**留空**（不猜）、主题原样、正文是 forwardBody + 附言', () {
      final draft = SuggestDraft.forward(
        row: original(),
        note: '转给你看看。\n',
        ossBase: _ossBase,
      );
      expect(draft.recipientsJson, '', reason: '转发不替用户决定转给谁');
      expect(draft.subject, '上线时间', reason: '转发不改主题（与 Web 端一致）');
      expect(draft.accountEmail, 'me@example.com');
      expect(userRaw(draft.content), '转给你看看。\n');
      // 正文那一半是 forwardBody，不是 replyQuote：没有「张三 写道：」那行抬头。
      expect(draft.content, isNot(contains(_wrote)));
    });

    test('转发的附言也是空的时，正文与 forwardBody 逐字相同', () {
      final quote = ComposeHtml.forwardBody(original(), ossBase: _ossBase);
      final draft = SuggestDraft.forward(
        row: original(),
        note: '',
        ossBase: _ossBase,
      );
      expect(draft.content, quote);
    });
  });
}
