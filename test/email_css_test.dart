import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:mail_app/features/mail_detail/email_css.dart';

/// [EmailCss] 的单元测试。
///
/// 覆盖 spec（`.tmp/dup-investigate/CSS-FIX-SPEC.md`）§3.3 列出的每一条：
/// 顶层规则、`@media` 按桌面视口求值、specificity / `!important` / 文档顺序、
/// 各种选择器形态、伪类与属性选择器整条跳过、坏 CSS 不抛、深嵌套与超长输入
/// 不爆栈，以及真实 Apple 邮件头部片段算出 `.m7 → none` 而 `.n11` 不受影响。
///
/// 注意：这里刻意让「解析样式表的 HTML」与「取元素的 HTML」是**两次独立
/// 解析**，与生产路径一致（`EmailCss.parse` 解析原始 HTML，`displayFor`
/// 收到的是 fwfh 自己再解析一遍的 DOM）—— 匹配只能靠标签/class/id/祖先结构，
/// 不能靠节点身份。
void main() {
  /// 用 [style] 构造一封邮件，取 [body] 里 `selector` 命中元素的最终 display。
  String? displayIn(String style, String body, String selector) {
    final css = EmailCss.parse('<html><head>$style</head><body>$body</body></html>');
    final fragment = html_parser.parseFragment(body);
    final element = fragment.querySelector(selector);
    expect(element, isNotNull, reason: 'fixture 里找不到 $selector');
    return css.displayFor(element!);
  }

  /// 只在 `@media query { .a {display:none} }` 里藏元素，返回 `.a` 的 display。
  String? underMedia(String query) => displayIn(
        '<style>@media $query { .a { display: none } }</style>',
        '<div class="a">x</div>',
        '.a',
      );

  group('顶层规则', () {
    test('命中的元素返回 display，没命中的返回 null', () {
      final css = EmailCss.parse(
        '<html><head><style>.hidden{display:none}.shown{display:block}</style></head>'
        '<body><div class="hidden" id="h">a</div>'
        '<div id="plain">b</div></body></html>',
      );
      final fragment = html_parser.parseFragment(
        '<div class="hidden" id="h">a</div><div id="plain">b</div>',
      );
      expect(css.displayFor(fragment.querySelector('#h')!), 'none');
      expect(css.displayFor(fragment.querySelector('#plain')!), isNull);
    });

    test('多个 <style> 块都参与，文档顺序按出现先后', () {
      final css = EmailCss.parse(
        '<style>.a{display:none}</style>'
        '<p>中间正文</p>'
        '<style>.a{display:inline-block}</style>',
      );
      final fragment = html_parser.parseFragment('<div class="a">x</div>');
      expect(css.displayFor(fragment.querySelector('.a')!), 'inline-block');
    });

    test('display 值去掉 !important、保留原始关键字', () {
      expect(
        displayIn('<style>.a{display: inline-block ! important}</style>',
            '<div class="a">x</div>', '.a'),
        'inline-block',
      );
      expect(
        displayIn('<style>.a{display:TABLE}</style>',
            '<div class="a">x</div>', '.a'),
        'table',
      );
    });

    test('没有 <style> / 空字符串 → 什么都算不出来', () {
      expect(EmailCss.parse('').displayFor(_anyElement()), isNull);
      expect(
        EmailCss.parse('<p>纯文本</p>').displayFor(_anyElement()),
        isNull,
      );
    });
  });

  group('媒体查询按固定桌面视口（800px / screen / 浅色）求值', () {
    test('width 边界', () {
      expect(underMedia('(max-width: 480px)'), isNull);
      expect(underMedia('(min-width: 481px)'), 'none');
      expect(underMedia('(min-width: 800px)'), 'none'); // 800 >= 800
      expect(underMedia('(max-width: 800px)'), 'none');
      expect(underMedia('(min-width: 801px)'), isNull);
      expect(underMedia('(max-width: 799px)'), isNull);
    });

    test('device-width 按同一桌面宽度算', () {
      expect(underMedia('(min-device-width: 400px)'), 'none');
      expect(underMedia('(max-device-width: 480px)'), isNull);
    });

    test('screen / all 命中，print 不命中', () {
      expect(underMedia('screen'), 'none');
      expect(underMedia('all'), 'none');
      expect(underMedia('print'), isNull);
    });

    test('only 只是前缀，不影响结果', () {
      expect(underMedia('only screen and (min-width: 481px)'), 'none');
      expect(underMedia('only screen and (max-width: 480px)'), isNull);
    });

    test('逗号 = OR', () {
      expect(underMedia('print, (min-width: 481px)'), 'none');
      expect(underMedia('print, (max-width: 480px)'), isNull);
      expect(underMedia('screen and (max-width: 480px), print'), isNull);
    });

    test('not 取反', () {
      // screen 命中、max-width:480 不命中 → 整体 false → not 后命中。
      expect(underMedia('not screen and (max-width: 480px)'), 'none');
      // 特性本身命中 → not 后不命中。
      expect(underMedia('not (min-width: 481px)'), isNull);
      expect(underMedia('not (prefers-color-scheme: dark)'), 'none');
    });

    test('prefers-color-scheme 固定浅色', () {
      expect(underMedia('(prefers-color-scheme: light)'), 'none');
      expect(underMedia('(prefers-color-scheme: dark)'), isNull);
    });

    test('em / rem 按 16px 折算', () {
      expect(underMedia('(min-width: 50em)'), 'none'); // 800px
      expect(underMedia('(min-width: 30em)'), 'none'); // 480px
      expect(underMedia('(max-width: 30em)'), isNull);
      expect(underMedia('(max-width: 50rem)'), 'none');
    });

    test('不认识的媒体特性 → 整块不应用（宁可不藏）', () {
      expect(underMedia('(min-resolution: 2dppx)'), isNull);
      expect(underMedia('(orientation: landscape)'), isNull);
      expect(underMedia('(hover: hover)'), isNull);
      expect(underMedia('(width: 800px)'), isNull);
      expect(underMedia('(min-width: 481px) and (min-resolution: 2dppx)'), isNull);
    });

    test('嵌套 @media 取条件交集', () {
      expect(
        displayIn(
          '<style>@media (min-width: 481px) {'
          '@media (prefers-color-scheme: light) { .a { display: none } }'
          '}</style>',
          '<div class="a">x</div>',
          '.a',
        ),
        'none',
      );
      expect(
        displayIn(
          '<style>@media (min-width: 481px) {'
          '@media (max-width: 480px) { .a { display: none } }'
          '}</style>',
          '<div class="a">x</div>',
          '.a',
        ),
        isNull,
      );
    });

    test('@media 之外的规则永远参与，块外的 @font-face 整块跳过', () {
      final css = EmailCss.parse(
        '<style>@font-face{font-family:x;src:url(y)}'
        '@media (max-width: 480px){ .mobile { display: none } }'
        '.desktop { display: block }</style>',
      );
      final fragment = html_parser.parseFragment(
        '<div class="mobile" id="m">x</div><div class="desktop" id="d">y</div>',
      );
      expect(css.displayFor(fragment.querySelector('#m')!), isNull);
      expect(css.displayFor(fragment.querySelector('#d')!), 'block');
    });
  });

  group('级联：specificity / !important / 文档顺序', () {
    const body = '<div class="a b" id="i">x</div>';

    test('同权重后者胜', () {
      expect(
        displayIn('<style>.a{display:block}.a{display:none}</style>', body, '#i'),
        'none',
      );
    });

    test('!important 压普通声明，与先后无关', () {
      expect(
        displayIn(
          '<style>.a{display:block!important}.a{display:none}</style>',
          body,
          '#i',
        ),
        'block',
      );
      expect(
        displayIn(
          '<style>.a{display:none}.a{display:block!important}</style>',
          body,
          '#i',
        ),
        'block',
      );
    });

    test('同是 !important 时仍按权重 / 顺序', () {
      expect(
        displayIn(
          '<style>.a{display:block!important}'
          '#i{display:none!important}</style>',
          body,
          '#i',
        ),
        'none',
      );
      expect(
        displayIn(
          '<style>.a{display:block!important}'
          '.a{display:none!important}</style>',
          body,
          '#i',
        ),
        'none',
      );
    });

    test('id > class > tag，important 压过一切 weight', () {
      expect(
        displayIn('<style>#i{display:none}.a{display:block}</style>', body, '#i'),
        'none',
      );
      expect(
        displayIn('<style>div{display:block}.a{display:none}</style>', body, '#i'),
        'none',
      );
      expect(
        displayIn(
          '<style>#i{display:block}.a{display:none!important}</style>',
          body,
          '#i',
        ),
        'none',
      );
    });

    test('多 class 的复合选择器权重更高', () {
      expect(
        displayIn(
          '<style>.a{display:block}.a.b{display:none}</style>',
          body,
          '#i',
        ),
        'none',
      );
    });

    test('同一块里重复声明：important 优先，否则后者胜', () {
      expect(
        displayIn(
          '<style>.a{display:none;display:inline-block}</style>',
          body,
          '#i',
        ),
        'inline-block',
      );
      expect(
        displayIn(
          '<style>.a{display:none!important;display:inline-block}</style>',
          body,
          '#i',
        ),
        'none',
      );
    });
  });

  group('选择器形态', () {
    const body = '<div class="outer" id="o">'
        '<div class="mid">'
        '<p class="inner" id="p">x</p>'
        '</div>'
        '</div>'
        '<span class="inner" id="lonely">y</span>';

    test('* / 标签 / .class / #id', () {
      expect(displayIn('<style>*{display:none}</style>', body, '#p'), 'none');
      expect(displayIn('<style>p{display:none}</style>', body, '#p'), 'none');
      expect(displayIn('<style>.inner{display:none}</style>', body, '#p'), 'none');
      expect(displayIn('<style>#p{display:none}</style>', body, '#p'), 'none');
    });

    test('复合选择器 tag.c / .a.b / #x.y', () {
      expect(
        displayIn('<style>p.inner{display:none}</style>', body, '#p'),
        'none',
      );
      expect(
        displayIn('<style>.inner.mid{display:none}</style>', body, '#p'),
        isNull,
      );
      expect(
        displayIn('<style>div.outer#o{display:none}</style>', body, '#o'),
        'none',
      );
    });

    test('后代（空格）要求祖先命中，不要求直接父子', () {
      expect(
        displayIn('<style>.outer .inner{display:none}</style>', body, '#p'),
        'none',
      );
      expect(
        displayIn('<style>.outer .inner{display:none}</style>', body, '#lonely'),
        isNull,
      );
    });

    test('子代（>）要求直接父子', () {
      expect(
        displayIn('<style>.outer > .inner{display:none}</style>', body, '#p'),
        isNull,
      );
      expect(
        displayIn('<style>.outer > .mid{display:none}</style>', body, '.mid'),
        'none',
      );
      expect(
        displayIn('<style>.outer > p{display:none}</style>', body, '#p'),
        isNull,
      );
    });

    test('逗号组里任一条命中即生效', () {
      expect(
        displayIn('<style>.nope, #p, span{display:none}</style>', body, '#p'),
        'none',
      );
    });
  });

  group('无静态语义的选择器整条跳过', () {
    const body = '<div class="a" id="a">x</div><div class="b" id="b">y</div>'
        '<p><a href="tel:123" id="tel">t</a></p>';

    test('伪类 / 伪元素', () {
      expect(displayIn('<style>.a:hover{display:none}</style>', body, '#a'), isNull);
      expect(displayIn('<style>.a:focus{display:none}</style>', body, '#a'), isNull);
      expect(displayIn('<style>.a:active{display:none}</style>', body, '#a'), isNull);
      expect(displayIn('<style>.a:link{display:none}</style>', body, '#a'), isNull);
      expect(
        displayIn('<style>#a::before{display:none}</style>', body, '#a'),
        isNull,
      );
      expect(
        displayIn('<style>.a:not(.b){display:none}</style>', body, '#a'),
        isNull,
      );
      expect(
        displayIn('<style>.a:nth-child(1){display:none}</style>', body, '#a'),
        isNull,
      );
    });

    test('属性选择器', () {
      expect(
        displayIn('<style>a[href^="tel:"]{display:none}</style>', body, '#tel'),
        isNull,
      );
      expect(
        displayIn('<style>[href]{display:none}</style>', body, '#tel'),
        isNull,
      );
    });

    test('兄弟组合子 + / ~', () {
      expect(
        displayIn('<style>.a + .b{display:none}</style>', body, '#b'),
        isNull,
      );
      expect(
        displayIn('<style>.a ~ .b{display:none}</style>', body, '#b'),
        isNull,
      );
    });

    test('只跳过坏的那一条，同组其它选择器照旧生效', () {
      expect(
        displayIn('<style>.a:hover, .b{display:none}</style>', body, '#b'),
        'none',
      );
      expect(
        displayIn('<style>.a:hover, .b{display:none}</style>', body, '#a'),
        isNull,
      );
      expect(
        displayIn(
          '<style>a[href^="tel:"], .a{display:none}</style>',
          body,
          '#a',
        ),
        'none',
      );
    });

    test('写坏的选择器不抛，也不命中', () {
      for (final selector in <String>[
        '> .a',
        '.a >',
        '..a',
        '#',
        '.',
        'p .',
        'a[b',
        '*:hover',
        '&.a',
        '.a..b',
      ]) {
        expect(
          () => displayIn(
            '<style>$selector{display:none}</style>',
            '<div class="a" id="a">x</div>',
            '#a',
          ),
          returnsNormally,
          reason: selector,
        );
        final result = displayIn(
          '<style>$selector{display:none}</style>',
          '<div class="a" id="a">x</div>',
          '#a',
        );
        // 跳过 = 不应用；写坏的选择器绝不能变成「藏内容」。
        expect(result, isNull, reason: selector);
      }
    });
  });

  group('坏 CSS 不抛异常', () {
    test('五花八门的坏输入都只返回空结果', () {
      final samples = <String>[
        '',
        '<style>',
        '<style></style>',
        '<style>/* 未闭合注释',
        '<style>}}}{{{ ::: ;;;',
        '<style>@media { .a { display: none } }',
        '<style>@media screen {',
        '<style>.a{display:}</style>',
        '<style>.a{:none}</style>',
        '<style>.a{display:none;}</style>', // 这条其实是合法的
        '<style>@import url("x.css")</style>',
        '<style>@keyframes x { from { display:none } }</style>',
        '<style>.a{content:"}"}</style>',
        '<style>.a{background:url(data:image/png;base64,AAAA;BBBB)}</style>',
        '<style>.a{display:inline-block;;;}</style>',
        '<style>@media (max-width: 480px) { .a:hover { display: none } }</style>',
        '<style>${'}x{display:none}' * 500}</style>',
        '<style>${'x' * 100000}</style>',
      ];
      for (final sample in samples) {
        late EmailCss css;
        expect(() => css = EmailCss.parse(sample), returnsNormally);
        expect(() => css.displayFor(_anyElement()), returnsNormally);
      }
    });

    test('引号 / 括号里的 ; } 不会被当成结构', () {
      // content 里的 `}` 不影响后面的 display 声明；url 里的 `;` 不切碎声明。
      expect(
        displayIn(
          '<style>.a{content:"}";display:none}</style>',
          '<div class="a">x</div>',
          '.a',
        ),
        'none',
      );
      expect(
        displayIn(
          '<style>.a{background:url(data:image/png;base64,AA;BB);'
          'display:block}</style>',
          '<div class="a">x</div>',
          '.a',
        ),
        'block',
      );
      // 属性选择器里的 `;` 不能把选择器切开。
      expect(
        displayIn(
          '<style>.a[title=";"]{display:none}</style>',
          '<div class="a">x</div>',
          '.a',
        ),
        isNull,
      );
    });
  });

  group('深嵌套 / 超长输入', () {
    test('上千层 HTML 里的目标元素能正常匹配（不爆栈）', () {
      // 深度刻意取 1000：再深 `package:html` 自己的解析会成为瓶颈，
      // 这里要验的是 EmailCss 的匹配不随 HTML 深度递归。
      final buffer = StringBuffer('<div class="outer">');
      for (var i = 0; i < 1000; i++) {
        buffer.write('<div>');
      }
      buffer.write('<span class="deep" id="target">x</span>');
      for (var i = 0; i < 1000; i++) {
        buffer.write('</div>');
      }
      buffer.write('</div>');
      final html = buffer.toString();
      final css = EmailCss.parse(
        '<style>.outer .deep{display:none}</style>',
      );
      late dom.Element target;
      expect(
        () {
          final fragment = html_parser.parseFragment(html);
          target = fragment.querySelector('#target')!;
        },
        returnsNormally,
      );
      // 祖先链匹配是迭代的，不随 HTML 深度递归。
      expect(css.displayFor(target), 'none');
    });

    test('病态长选择器被丢弃，不爆栈也不误藏', () {
      final selector = List<String>.filled(100, 'div').join(' ');
      final css = EmailCss.parse(
        '<style>$selector{display:none}</style>',
      );
      expect(() => css.displayFor(_anyElement()), returnsNormally);
      expect(css.displayFor(_anyElement()), isNull);
    });

    test('@media 嵌套超过上限时忽略更深的块，不抛', () {
      final buffer = StringBuffer('<style>');
      for (var i = 0; i < 50; i++) {
        buffer.write('@media (min-width: 1px) {');
      }
      buffer.write('.a { display: none }');
      for (var i = 0; i < 50; i++) {
        buffer.write('}');
      }
      buffer.write('</style>');
      late EmailCss css;
      expect(() => css = EmailCss.parse(buffer.toString()), returnsNormally);
      expect(
        css.displayFor(html_parser.parseFragment(
            '<div class="a">x</div>').querySelector('.a')!),
        isNull,
      );
    });

    test('超长样式表 + 上千元素仍在可控时间内完成', () {
      // 4000 条只含 display 的规则 + 1000 个元素。真实邮件不会这么极端，
      // 这里只做「不会退化成分钟级」的冒烟上限，不当性能基准用。
      final style = StringBuffer('<style>');
      for (var i = 0; i < 4000; i++) {
        style.write('.r$i{display:${i.isEven ? 'none' : 'block'}}');
      }
      style.write('</style>');
      final body = StringBuffer();
      for (var i = 0; i < 1000; i++) {
        body.write('<div class="r${i * 4}" id="e$i">x</div>');
      }
      final css = EmailCss.parse('<html><head>$style</head><body>$body</body></html>');
      final fragment = html_parser.parseFragment(body.toString());
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        expect(css.displayFor(fragment.querySelector('#e$i')!), 'none');
      }
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(5000));
    });
  });

  group('真实 Apple 邮件头部片段', () {
    // 从真实邮件 `.m7`/`.n11` 那几条规则里裁出来的等价片段。
    const appleStyle = '''
<style>
.brs, .m7, .m8 .m9 { display: none }
.n23, .m7 { display: none !important }
@media only screen and (max-width:480px){
  .brm, .m8 .n11, .m8 .n12, .n11 { display: none !important }
  .brs, .m7, .ms { display: inline !important }
}
</style>
''';
    const appleBody = '<table class="m8"><tr><td class="m8">'
        '<span class="m7" id="mobile"><img alt="Apple"></span>'
        '<span class="n11" id="desktop"><img alt="Apple" class="m27"></span>'
        '</td></tr></table>';

    test('.m7 被藏掉，.n11 不受影响', () {
      final css = EmailCss.parse('<html><head>$appleStyle</head>'
          '<body>$appleBody</body></html>');
      final fragment = html_parser.parseFragment(appleBody);
      expect(css.displayFor(fragment.querySelector('#mobile')!), 'none');
      // `.n11` 只在 max-width:480 里被藏，桌面视口下不该命中。
      expect(css.displayFor(fragment.querySelector('#desktop')!), isNull);
    });

    test('桌面独有规则（min-width:481px）里的 .m8 .m7 也命中', () {
      final css = EmailCss.parse(
        '<style>@media only screen and (min-width:481px){'
        '.m8 .m7,.m8 .n24{display:none!important}'
        '.m8 .n12{display:inline-block}}</style>',
      );
      final fragment = html_parser.parseFragment('<table class="m8"><tr>'
          '<td class="m8"><span class="m7" id="mobile">x</span>'
          '<img class="n12" id="desk-img"></td></tr></table>');
      expect(css.displayFor(fragment.querySelector('#mobile')!), 'none');
      expect(css.displayFor(fragment.querySelector('#desk-img')!), 'inline-block');
    });
  });
}

/// 随便造一个元素：用于「不该抛」的断言，不关心匹配结果。
dom.Element _anyElement() =>
    html_parser.parseFragment('<div>x</div>').querySelector('div')!;
