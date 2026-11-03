import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/util/eml_parser.dart';

/// 拼一封邮件：头几行 + 空行 + 正文。
///
/// 用 `\r\n` —— 真实邮件几乎都是 CRLF，顺便让「拆头部要认 CRLF」这件事被测到。
/// 需要裸 LF 的用例自己拼（`\n`），那是另一条分支。
String _eml(List<String> headerLines, [String body = '']) =>
    '${headerLines.join('\r\n')}\r\n\r\n$body';

/// 二进制版本：头是 ASCII，正文是任意字节（GBK 那几条要用）。
List<int> _emlBytes(
  List<String> headerLines, [
  List<int> body = const <int>[],
]) =>
    <int>[
      ...latin1.encode(_eml(headerLines)),
      ...body,
    ];

void main() {
  group('最小的一封信', () {
    test('头与正文各就各位', () {
      final message = parseEml(utf8.encode(_eml(
        <String>[
          'From: Alice <alice@example.com>',
          'To: Bob <bob@example.com>',
          'Subject: Hello',
          'Date: Tue, 03 Nov 2026 05:36:47 +0000',
          'Content-Type: text/plain; charset=utf-8',
        ],
        '第一行\r\n第二行',
      )))!;

      expect(message.subject, 'Hello');
      expect(message.from.single.name, 'Alice');
      expect(message.from.single.address, 'alice@example.com');
      expect(message.to.single.display, 'Bob <bob@example.com>');
      expect(message.text, '第一行\r\n第二行');
      expect(message.html, isNull);
      expect(message.hasBody, isTrue);
      expect(message.attachments, isEmpty);
      expect(message.date, DateTime.utc(2026, 11, 3, 5, 36, 47));
    });

    test('没有 Content-Type 时按 text/plain 看（老邮件就是这样）', () {
      final message = parseEml(utf8.encode(_eml(
        <String>['Subject: plain', 'From: a@b.c'],
        'just text',
      )))!;

      expect(message.text, 'just text');
      expect(message.html, isNull);
    });

    test('裸 LF 的邮件也认（有的客户端导出时不写 CR）', () {
      const raw = 'Subject: lf\nFrom: a@b.c\n\nbody line\n';
      final message = parseEml(utf8.encode(raw))!;
      expect(message.subject, 'lf');
      expect(message.text, 'body line\n');
    });

    test('空文件 / 普通文本 / 伪装成头部的文本，都不是邮件', () {
      expect(parseEml(const <int>[]), isNull);
      expect(parseEml(utf8.encode('hello world')), isNull);
      // 第一行形如 `key: value`，但没有任何可识别的邮件头。
      expect(parseEml(utf8.encode('时间: 12:00\n随便一句话\n')), isNull);
      // 只有头、没有空行与正文：仍算一封信（有些导出少了尾部空行）。
      final message = parseEml(utf8.encode('Subject: only header\r\n'));
      expect(message, isNotNull);
      expect(message!.subject, 'only header');
      expect(message.hasBody, isFalse);
    });
  });

  group('头部解码', () {
    test('RFC 2047 的 B / Q 编码词', () {
      final b = parseEml(utf8.encode(_eml(<String>[
        'Subject: =?UTF-8?B?5L2g5aW9?=',
        'From: =?UTF-8?B?5byg5LiJ?= <zs@example.com>',
      ])))!;
      expect(b.subject, '你好');
      expect(b.from.single.name, '张三');

      final q = parseEml(utf8.encode(_eml(<String>[
        'Subject: =?UTF-8?Q?=E4=BD=A0=E5=A5=BD?=',
      ])))!;
      expect(q.subject, '你好');
    });

    test('相邻编码词之间的空白要丢掉，正文里的空白要留着', () {
      final message = parseEml(utf8.encode(_eml(<String>[
        'Subject: =?UTF-8?B?5L2g?= =?UTF-8?B?5aW9?=',
      ])))!;
      expect(message.subject, '你好');
    });

    test('折行的头（续行）能接回去', () {
      final message = parseEml(utf8.encode(_eml(<String>[
        'Subject: =?UTF-8?B?5L2g?=',
        ' =?UTF-8?B?5aW9?=',
        'From: a@b.c',
      ])))!;
      expect(message.subject, '你好');
    });

    test('地址里的引号名与逗号不会被拆成两个人', () {
      final message = parseEml(utf8.encode(_eml(<String>[
        'To: "Doe, John" <john@example.com>, plain@example.com',
        'From: a@b.c',
      ])))!;
      expect(message.to, hasLength(2));
      expect(message.to.first.name, 'Doe, John');
      expect(message.to.first.address, 'john@example.com');
      expect(message.to.last.address, 'plain@example.com');
      expect(message.to.last.name, isEmpty);
    });

    test('没有 Date 时是 null，不是 1970', () {
      expect(parseEml(utf8.encode(_eml(<String>['From: a@b.c'])))!.date, isNull);
      expect(
        parseEml(utf8.encode(_eml(<String>[
          'From: a@b.c',
          'Date: not a date',
        ])))!
            .date,
        isNull,
      );
    });

    test('日期认数字时区偏移与 GMT', () {
      expect(
        parseEml(utf8.encode(_eml(<String>[
          'From: a@b.c',
          'Date: Tue, 03 Nov 2026 05:36:47 +0800',
        ])))!
            .date,
        DateTime.utc(2026, 11, 2, 21, 36, 47),
      );
      expect(
        parseEml(utf8.encode(_eml(<String>[
          'From: a@b.c',
          'Date: 3 Nov 2026 05:36:47 GMT',
        ])))!
            .date,
        DateTime.utc(2026, 11, 3, 5, 36, 47),
      );
    });
  });

  group('传输编码与字符集', () {
    test('base64 正文（base64 里带换行）', () {
      // `5L2g5aW9` 是「你好」的 UTF-8 base64，手写死值。
      final message = parseEml(utf8.encode(_eml(
        <String>[
          'From: a@b.c',
          'Content-Type: text/plain; charset="utf-8"',
          'Content-Transfer-Encoding: base64',
        ],
        '5L2g\r\n5aW9\r\n',
      )))!;
      expect(message.text, '你好');
    });

    test('quoted-printable 正文（含软换行）', () {
      final message = parseEml(utf8.encode(_eml(
        <String>[
          'From: a@b.c',
          'Content-Type: text/plain; charset="utf-8"',
          'Content-Transfer-Encoding: quoted-printable',
        ],
        '=E4=BD=A0=E5=A5=BD=\r\n世界',
      )))!;
      // `=` 在行尾是软换行：两行接起来，中间不留换行。
      expect(message.text, '你好世界');
    });

    test('声明了 GBK 就按 GBK 解（不靠嗅探）', () {
      final message = parseEml(_emlBytes(
        <String>[
          'From: a@b.c',
          'Content-Type: text/plain; charset="gbk"',
          'Content-Transfer-Encoding: 8bit',
        ],
        <int>[0xD6, 0xD0, 0xCE, 0xC4], // 「中文」的 GBK 字节，手写死值
      ))!;
      expect(message.text, '中文');
    });

    test('没有 charset 声明时按嗅探：GBK 字节能解出中文', () {
      final message = parseEml(_emlBytes(
        <String>['From: a@b.c', 'Content-Type: text/plain'],
        <int>[0xD6, 0xD0, 0xCE, 0xC4],
      ))!;
      expect(message.text, '中文');
    });

    test('声明对不上实际字节时退回嗅探，而不是给一屏乱码', () {
      final message = parseEml(_emlBytes(
        <String>[
          'From: a@b.c',
          'Content-Type: text/plain; charset="utf-8"',
        ],
        <int>[0xD6, 0xD0, 0xCE, 0xC4], // 其实是 GBK
      ))!;
      expect(message.text, '中文');
    });
  });

  group('multipart', () {
    test('alternative：有 HTML 就用 HTML，纯文本当退路', () {
      final message = parseEml(utf8.encode(_eml(
        <String>[
          'From: a@b.c',
          'Content-Type: multipart/alternative; boundary="alt"',
        ],
        <String>[
          '--alt',
          'Content-Type: text/plain; charset="utf-8"',
          '',
          '纯文本版本',
          '--alt',
          'Content-Type: text/html; charset="utf-8"',
          '',
          '<b>hi</b>',
          '--alt--',
          '',
        ].join('\r\n'),
      )))!;

      // `multipart/alternative` 的分部顺序是「从最不像到最像」，所以后出现的
      // html 才是首选 —— 两个都解出来，界面上优先用 html。
      expect(message.html, '<b>hi</b>');
      expect(message.text, '纯文本版本');
      expect(message.attachments, isEmpty);
    });

    test('alternative 里的空 plain 分部不会把 html 挡掉', () {
      final message = parseEml(utf8.encode(_eml(
        <String>[
          'From: a@b.c',
          'Content-Type: multipart/alternative; boundary="alt"',
        ],
        <String>[
          '--alt',
          'Content-Type: text/plain',
          '',
          '',
          '--alt',
          'Content-Type: text/html',
          '',
          '<p>only html</p>',
          '--alt--',
          '',
        ].join('\r\n'),
      )))!;
      expect(message.html, '<p>only html</p>');
      expect(message.text, isNull);
      expect(message.hasBody, isTrue);
    });

    test('mixed：正文取文本，附件列出来（含大小与文件名）', () {
      final message = parseEml(utf8.encode(_eml(
        <String>[
          'From: a@b.c',
          'Content-Type: multipart/mixed; boundary="mix"',
        ],
        <String>[
          '--mix',
          'Content-Type: multipart/alternative; boundary="alt"',
          '',
          '--alt',
          'Content-Type: text/plain; charset="utf-8"',
          '',
          '正文',
          '--alt--',
          '',
          '--mix',
          'Content-Type: application/pdf; name="report.pdf"',
          'Content-Disposition: attachment; filename="report.pdf"',
          'Content-Transfer-Encoding: base64',
          '',
          'JVBERi0xLjQK', // `%PDF-1.4\n` 的 base64，手写死值
          '--mix--',
          '',
        ].join('\r\n'),
      )))!;

      expect(message.text, '正文');
      expect(message.attachments, hasLength(1));
      expect(message.attachments.single.filename, 'report.pdf');
      expect(message.attachments.single.mimeType, 'application/pdf');
      // 9 字节。base64 是「数有效字符 × 3/4」，不是把附件解一遍。
      expect(message.attachments.single.size, 9);
    });

    test('multipart/related：内嵌图（cid:）不列成附件', () {
      final message = parseEml(utf8.encode(_eml(
        <String>[
          'From: a@b.c',
          'Content-Type: multipart/related; boundary="rel"',
        ],
        <String>[
          '--rel',
          'Content-Type: text/html; charset="utf-8"',
          '',
          '<img src="cid:logo">',
          '--rel',
          'Content-Type: image/png',
          'Content-ID: <logo>',
          'Content-Transfer-Encoding: base64',
          '',
          'iVBORw0KGgo=',
          '--rel--',
          '',
        ].join('\r\n'),
      )))!;

      expect(message.html, contains('cid:logo'));
      expect(message.attachments, isEmpty);
    });

    test('转发出去的那封信（message/rfc822）当一个附件，不递归渲染', () {
      final message = parseEml(utf8.encode(_eml(
        <String>[
          'From: a@b.c',
          'Content-Type: multipart/mixed; boundary="mix"',
        ],
        <String>[
          '--mix',
          'Content-Type: text/plain',
          '',
          '见附件',
          '--mix',
          'Content-Type: message/rfc822',
          'Content-Disposition: attachment; filename="forwarded.eml"',
          '',
          'Subject: inner',
          'From: inner@example.com',
          '',
          'inner body',
          '--mix--',
          '',
        ].join('\r\n'),
      )))!;

      expect(message.text, '见附件');
      expect(message.attachments.single.filename, 'forwarded.eml');
      expect(message.attachments.single.mimeType, 'message/rfc822');
    });

    test('附件名是 RFC 2047 编码时也要解', () {
      final message = parseEml(utf8.encode(_eml(
        <String>[
          'From: a@b.c',
          'Content-Type: multipart/mixed; boundary="mix"',
        ],
        <String>[
          '--mix',
          'Content-Type: text/plain',
          '',
          '正文',
          '--mix',
          'Content-Type: application/octet-stream',
          r'Content-Disposition: attachment; filename="=?UTF-8?B?5a2j5bqm5oql5ZGK?=.pdf"',
          '',
          'x',
          '--mix--',
          '',
        ].join('\r\n'),
      )))!;
      expect(message.attachments.single.filename, '季度报告.pdf');
    });

    test('boundary 带引号、带空格也能拆', () {
      final message = parseEml(utf8.encode(_eml(
        <String>[
          'From: a@b.c',
          'Content-Type: multipart/mixed; boundary="a b"',
        ],
        <String>[
          '--a b',
          'Content-Type: text/plain',
          '',
          'ok',
          '--a b--',
          '',
        ].join('\r\n'),
      )))!;
      expect(message.text, 'ok');
    });
  });
}
