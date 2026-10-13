import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/mail_detail/html_body_view.dart';

/// 正文净化是**安全边界**（邮件是不可信输入），所以要逐条钉住行为：
/// 脚本类标签必须消失、`javascript:` 链接必须失效，而正常正文必须原样留下。
void main() {
  group('sanitizeEmailHtml', () {
    test('去掉 script / iframe / object / embed / form', () {
      const html = '<p>hi</p>'
          '<script>alert(1)</script>'
          '<iframe src="https://evil.example"></iframe>'
          '<object data="x"></object>'
          '<embed src="y">'
          '<form action="/steal"><input name="p"></form>';
      final out = sanitizeEmailHtml(html).html;
      expect(out, contains('<p>hi</p>'));
      for (final tag in <String>['script', 'iframe', 'object', 'embed', 'form']) {
        expect(out.toLowerCase(), isNot(contains('<$tag')));
      }
    });

    test('剥掉 on* 事件属性', () {
      final out = sanitizeEmailHtml(
        '<a href="https://a.example" onclick="alert(1)" onmouseover="x()">a</a>',
      ).html;
      expect(out, contains('href="https://a.example"'));
      expect(out.toLowerCase(), isNot(contains('onclick')));
      expect(out.toLowerCase(), isNot(contains('onmouseover')));
    });

    test('javascript: / vbscript: 链接会被摘掉，但保留其余属性', () {
      final out = sanitizeEmailHtml(
        '<a href="javascript:alert(1)" title="t">x</a>'
        '<img src="vbscript:msgbox" alt="a">',
      ).html;
      expect(out.toLowerCase(), isNot(contains('javascript:')));
      expect(out.toLowerCase(), isNot(contains('vbscript:')));
      expect(out, contains('title="t"'));
      expect(out, contains('alt="a"'));
    });

    test('普通正文与转义原样保留（不能被解码成标签）', () {
      final out = sanitizeEmailHtml('<p>a &lt;b&gt; c &amp; d</p>').html;
      expect(out, contains('&lt;b&gt;'));
      expect(out, contains('&amp;'));
    });

    test('空输入返回空串而不是抛异常', () {
      expect(sanitizeEmailHtml('').html, '');
      expect(sanitizeEmailHtml('   ').html, '');
    });

    test('从 <body style> 抠出字号 / 行高 / 颜色', () {
      final parsed = sanitizeEmailHtml(
        '<html><body style="font-size:15px;line-height:1.6;color:#ff0000">'
        '<p>hi</p></body></html>',
      );
      expect(parsed.bodyStyle.fontSize, 15);
      expect(parsed.bodyStyle.lineHeight, 1.6);
      expect(parsed.bodyStyle.color?.toARGB32(), 0xFFFF0000);
      // body 外壳标签本身要被去掉，否则 fwfh 会把它当成一个块级容器。
      expect(parsed.html.toLowerCase(), isNot(contains('<body')));
      expect(parsed.html.toLowerCase(), isNot(contains('<html')));
    });

    test('不认识的 body 样式一律忽略（不是抛异常）', () {
      final parsed = sanitizeEmailHtml(
        '<body style="font-size:1.2em;display:flex;color:red">x</body>',
      );
      expect(parsed.bodyStyle.fontSize, isNull);
      expect(parsed.bodyStyle.color, isNull);
      expect(parsed.html, contains('x'));
    });

    test('深嵌套正文不解析、直接降级成转义纯文本', () {
      // 修复前：`sanitizeEmailHtml` 完全没有深度守卫，2 万层要 6.9 秒才跑完
      // （这条用例本身就慢得可当红）。修复后：毫秒级，且输出里没有真标签。
      final deep =
          '${'<div>' * 20000}<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>${'</div>' * 20000}';
      final out = sanitizeEmailHtml(deep);
      expect(out.html, contains('&lt;script&gt;')); // 文字还在
      expect(out.html, isNot(contains('<div'))); // 没有真标签
      expect(out.html, isNot(contains('<script')));
    });
  });
}
