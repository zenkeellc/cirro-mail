import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/text_styles.dart';
import 'package:mail_app/features/compose/html/delta_to_email_html.dart';
import 'package:mail_app/features/compose/html/email_html_sanitizer.dart';
import 'package:mail_app/features/compose/html/mail_html_to_delta.dart';
import 'package:mail_app/features/mail_detail/html_body_view.dart'
    show sanitizeEmailHtml;

/// 批 B 的护栏测试：**调色盘只有一份定义，且三边（下拉 / 导出 / 净化）
/// 对它一致**。这一组红了，就说明有人在某一边另抄了一份。

void main() {
  group('调色盘形状', () {
    test('每个颜色都是净化器认的形状', () {
      for (final c in [...kTextColors, ...kHighlightColors]) {
        expect(kHexColorPattern.hasMatch(c.hex), isTrue, reason: c.hex);
        expect(c.hex, c.hex.toLowerCase(), reason: '存小写，别让大小写漂');
      }
    });

    test('净化器放行调色盘里的每一个颜色', () {
      for (final c in [...kTextColors, ...kHighlightColors]) {
        final html = '<p><span style="color:${c.hex}">x</span></p>';
        expect(
          EmailHtmlSanitizer.toSafeSubset(html),
          contains('color:${c.hex}'),
          reason: '下拉里给了 ${c.hex}，净化器却不放行 —— 用户选了色发出去会丢',
        );
        final bg = '<p><span style="background-color:${c.hex}">x</span></p>';
        expect(EmailHtmlSanitizer.toSafeSubset(bg), contains('background-color:${c.hex}'));
      }
    });
  });

  group('字号夹取', () {
    test('四个档位原样认', () {
      for (final key in kFontSizes.keys) {
        expect(clampFontSize(key), key);
      }
    });

    test('上游给的各种形状都夹到最近档位', () {
      // 这些值来自 §0.2 第 18 条的实测。
      expect(clampFontSize('19'), '19');   // 19px
      expect(clampFontSize('15'), '14');   // 12pt
      expect(clampFontSize('32'), '24');   // 2rem
      expect(clampFontSize('120'), '24');  // 120px，不能原样信
      expect(clampFontSize('8'), '14');
      expect(clampFontSize('small'), isNull, reason: '非数字串不设字号');
      expect(clampFontSize(''), isNull);
    });

    test('导出端只认四个档位', () {
      expect(fontSizeCss('19'), '19px');
      expect(fontSizeCss('120'), isNull, reason: '不认识就不写，别吐 120px');
      expect(fontSizeCss(null), isNull);
    });
  });

  group('往返：颜色与字号', () {
    test('颜色 / 高亮 / 字号经导出再导入都还在', () {
      final delta = <dynamic>[
        {'insert': '红'},
        {'insert': '底', 'attributes': {'background': '#e6f4ea'}},
        {'insert': '大', 'attributes': {'size': '19'}},
        {'insert': '普', 'attributes': {'color': '#d93025'}},
        {'insert': '\n'},
      ];
      final html = DeltaToEmailHtml.convert(delta);
      final back = MailHtmlToDelta.convert(html);
      final encoded = back.toString();
      expect(encoded, contains('#d93025'));
      expect(encoded, contains('#e6f4ea'));
      expect(encoded, contains('19'));
    });
  });

  group('白底容器', () {
    test('没用颜色/高亮时，输出里一个字节都不多', () {
      final plain = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '普通一段\n'},
      ]);
      expect(plain, '<p style="margin:0 0 12px 0">普通一段</p>');
      expect(plain, isNot(contains('background')), reason: '没用颜色就别包，别改所有人的输出');
    });

    test('用了颜色就包一层白底 div', () {
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '红', 'attributes': {'color': '#d93025'}},
        {'insert': '\n'},
      ]);
      expect(html, startsWith('<div style="background:#ffffff">'));
      expect(html, endsWith('</div>'));
    });

    test('容器只导出不往返：净化器把容器那层白底削掉', () {
      // 判据是**会红**（变异实测）：把 `_whiteBackdropStart` 换成
      // `<div style="background-color:#ffffff">`，这条就红 —— 因为
      // `#ffffff` 在这个用例里**只由容器带进来**（内层 span 是 `#e6f4ea`），
      // 而 `background-color` 在净化器白名单里、会被原样留下。
      // 只写「不含 background-color:#ffffff」是**恒真**的：输入里压根没有
      // 这个字面量，挡不住任何东西。
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '红', 'attributes': {'background': '#e6f4ea'}},
        {'insert': '\n'},
      ]);
      expect(html, contains('background:#ffffff')); // 导出时白底在
      final safe = EmailHtmlSanitizer.toSafeSubset(html);
      expect(
        safe,
        isNot(contains('#ffffff')),
        reason: '容器那层白底在净化后必须被削掉（简写不在白名单／div 属性整体丢）',
      );
      expect(safe, contains('#e6f4ea'), reason: '内容自己的高亮要活着，别一起削没了');
    });

    test('只有高亮也算「用了」', () {
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '底', 'attributes': {'background': '#e6f4ea'}},
        {'insert': '\n'},
      ]);
      expect(html, startsWith('<div style="background:#ffffff">'));
    });

    test('字号单独出现不包白底', () {
      // 14px 的黑字放哪都看得清，浅底对它没意义 —— 包了只是白改所有
      // 「只调了字号」的邮件。现有用例里字号总和颜色混在一起，
      // 区分不出到底是谁触发的。
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '大', 'attributes': {'size': '19'}},
        {'insert': '\n'},
      ]);
      expect(html, isNot(contains('background')));
    });

    test('形状不对的颜色不触发白底', () {
      for (final bad in <Object>['javascript:alert(1)', 42, true]) {
        final html = DeltaToEmailHtml.convert(<dynamic>[
          {'insert': 'x', 'attributes': {'color': bad}},
          {'insert': '\n'},
        ]);
        expect(html, isNot(contains('background')), reason: 'color=$bad 不该触发');
      }
    });

    test('颜色只挂在空属性位上时不包（不生成空壳）', () {
      // `convert` 只扫属性，这一位没有文字 ⇒ body 是空串。
      // 包出来会是一个没有内容的 `<div style="background:#ffffff"></div>`。
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '', 'attributes': {'color': '#d93025'}},
      ]);
      expect(html, '');
    });
  });

  test('读信侧的净化（黑名单式）本来就留颜色与上下标', () {
    // 这条是**回归**而不是新功能：批 B 全靠它成立 —— 如果哪天读信侧改成
    // 白名单并且只认排版属性，收件人看到的就是没颜色的正文，
    // 而发送侧一切测试都会是绿的。
    const sent = '<p><span style="color:#d93025;background-color:#e6f4ea;font-size:19px">'
        '红<sup>2</sup></span></p>';
    // `sanitizeEmailHtml` 返回的是 `SanitizedHtml`（一个带 `html` 与
    // `bodyStyle` 两条的记录），**不是 String** —— 要取 `.html`。
    final shown = sanitizeEmailHtml(sent).html;
    expect(shown, contains('#d93025'));
    expect(shown, contains('#e6f4ea'));
    expect(shown, contains('19px'));
    expect(shown, contains('<sup>'));
  });
}
