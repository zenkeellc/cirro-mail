import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/html/email_html_sanitizer.dart';
import 'package:mail_app/features/compose/table/table_html_codec.dart';
import 'package:mail_app/features/compose/table/table_model.dart';

void main() {
  group('stripUnsafe', () {
    test('删掉 script 标签连同内容', () {
      final out = EmailHtmlSanitizer.stripUnsafe(
        '<p>前</p><script>alert(1)</script><p>后</p>',
      );
      expect(out, isNot(contains('script')));
      expect(out, isNot(contains('alert')));
      expect(out, contains('前'));
      expect(out, contains('后'));
    });

    test('删掉 style 标签（邮件客户端也会丢，留着只会骗自己）', () {
      final out = EmailHtmlSanitizer.stripUnsafe(
        '<style>p{color:red}</style><p>正文</p>',
      );
      expect(out, isNot(contains('color:red')));
      expect(out, contains('正文'));
    });

    test('删掉 on* 事件属性', () {
      final out = EmailHtmlSanitizer.stripUnsafe(
        '<p onclick="evil()" onmouseover="x()">正文</p>',
      );
      expect(out, isNot(contains('onclick')));
      expect(out, isNot(contains('onmouseover')));
      expect(out, contains('正文'));
    });

    test('javascript: 链接被中和', () {
      final out = EmailHtmlSanitizer.stripUnsafe(
        '<a href="javascript:alert(1)">点我</a>',
      );
      expect(out, isNot(contains('javascript:')));
      expect(out, contains('点我'));
    });

    test('vbscript: 与 data:text/html 同样被中和', () {
      expect(
        EmailHtmlSanitizer.stripUnsafe('<a href="vbscript:x">a</a>'),
        isNot(contains('vbscript:')),
      );
      expect(
        EmailHtmlSanitizer.stripUnsafe('<a href="data:text/html;base64,AA">a</a>'),
        isNot(contains('data:text/html')),
      );
    });

    test('正常的 http(s) 链接与图片不动', () {
      final out = EmailHtmlSanitizer.stripUnsafe(
        '<a href="https://e.com">x</a><img src="https://e.com/a.png">',
      );
      expect(out, contains('href="https://e.com"'));
      expect(out, contains('src="https://e.com/a.png"'));
    });

    test('data:image 的 src 必须留着（粘贴进来的图片就是它）', () {
      final out = EmailHtmlSanitizer.stripUnsafe(
        '<img src="data:image/png;base64,AAAA">',
      );
      expect(out, contains('data:image/png;base64,AAAA'));
    });
  });

  group('normalizeStyles', () {
    test('删掉 class 与 id', () {
      final out = EmailHtmlSanitizer.normalizeStyles(
        '<p class="a" id="b">正文</p>',
      );
      expect(out, isNot(contains('class=')));
      expect(out, isNot(contains('id=')));
      expect(out, contains('正文'));
    });

    test('style 只留白名单里的属性：具名色与非法字号丢掉', () {
      // 批 B 起 `font-size` 与 `color` 都进白名单，但只放行合法**值形状**：
      // 具名色 `red`（非 `#rrggbb`）与超界字号 `1200px` 仍被整条丢掉。
      final out = EmailHtmlSanitizer.normalizeStyles(
        '<p style="color:red;font-size:1200px;text-align:center;line-height:2">中</p>',
      );
      expect(out, contains('text-align:center'));
      expect(out, isNot(contains('color')));
      expect(out, isNot(contains('font-size')));
      expect(out, isNot(contains('line-height')));
    });

    test('单元格额外保留 width / border / padding', () {
      // 必须包在 <table> 里：游离的 <td> 会被 HTML 解析器按「隐含表格结构」
      // 的规则直接丢掉，属性自然也就无从保留。
      final out = EmailHtmlSanitizer.normalizeStyles(
        '<table><tr>'
        '<td style="width:120px;border:1px solid #ccc;padding:4px;color:red">x</td>'
        '</tr></table>',
      );
      expect(out, contains('width:120px'));
      expect(out, contains('border:1px solid #ccc'));
      expect(out, contains('padding:4px'));
      expect(out, isNot(contains('color')));
    });

    test('style 被掏空时属性整个去掉，不留 style=""', () {
      final out = EmailHtmlSanitizer.normalizeStyles(
        '<p style="color:red">x</p>',
      );
      expect(out, isNot(contains('style=')));
    });

    test('padding-left 只认纯像素值，别的一律整条削掉', () {
      // 值形状锚定到整串：只要有一个字符不在 `^\d{1,3}px$` 里就丢掉。
      // 这条测试是**守卫本身**的测试，不是「我加的白名单生效了」——
      // 下面那组畸形值是真正会绕守卫的形状。
      //
      // 挡法分两层，两层都在这条用例里钉住：`url(...)`/`expression(...)`/
      // `!important`/`calc(...)`/`-16px`/`16`/`16em` 走的是新加的
      // `^\d{1,3}px$`；`1}6px`/`16px<x` 更早一步被 `_filterStyle` 的
      // 「值里含 `}`/`<`/`>` 整条丢」拦下。后两个留在循环里是为了把**守卫的
      // 输出形状**钉死（任何入口都不得留下 `padding-left`），不是因为它们
      // 能走到正则。
      for (final bad in <String>[
        'padding-left:url(javascript:alert(1))',
        'padding-left:expression(alert(1))',
        'padding-left:16px!important',
        'padding-left:calc(100% - 20px)',
        'padding-left:-16px',
        'padding-left:16',
        'padding-left:16em',
        'padding-left:1}6px',
        'padding-left:16px<x',
      ]) {
        final out = EmailHtmlSanitizer.normalizeStyles('<p style="$bad">x</p>');
        expect(out, isNot(contains('padding-left')), reason: bad);
      }
      // 多声明的形状不一样：`;` 在 `style` 属性里本来就是**声明分隔符**，
      // 所以 `padding-left:16px;background:red` 的合法那半**本就该留下** ——
      // 该被削掉的是多出来的那半（`background`）。这与上面那 9 条「一条声明
      // 里塞垃圾」是两回事，所以单独断言、不混进循环。
      expect(
        EmailHtmlSanitizer.normalizeStyles(
          '<p style="padding-left:16px;background:red">x</p>',
        ),
        '<p style="padding-left:16px">x</p>',
      );
      // 正常值照留。
      expect(
        EmailHtmlSanitizer.normalizeStyles('<p style="padding-left:32px">x</p>'),
        contains('padding-left:32px'),
      );
      // 超大值也过形状（`\d{1,3}` 上限 999），但上游 `parseToIndent` 会
      // 把它夹到 5 级 —— 越界在这里不是安全问题，是显示问题。
      expect(
        EmailHtmlSanitizer.normalizeStyles('<p style="padding-left:999px">x</p>'),
        contains('padding-left:999px'),
      );
    });
  });

  group('toSafeSubset', () {
    test('两步一次做完', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<div class="c"><style>p{}</style>'
        '<p style="color:red;text-align:right" onclick="x()">正文</p></div>',
      );
      expect(out, isNot(contains('class=')));
      expect(out, isNot(contains('onclick')));
      expect(out, isNot(contains('color')));
      expect(out, contains('text-align:right'));
    });

    test('畸形 HTML 不抛异常', () {
      expect(
        () => EmailHtmlSanitizer.toSafeSubset('<p>a<span>b</p></span><table>'),
        returnsNormally,
      );
    });

    test('两条绕过路径同样被拦成降级（修复前会红）', () {
      for (final opener in <String>[
        '<![CDATA[', '<![cdata[', '<!-->', '<!--->', '<!-- y --!>',
      ]) {
        final deep = '$opener${'<div>' * 1500}';
        // 修复前：守卫数出 0 → 继续解析 → 返回一大堆 <div>。
        // 修复后：判定超限 → 降级成纯文本（这段输入里没有可见文字，故为空串）。
        expect(EmailHtmlSanitizer.toSafeSubset(deep), '', reason: opener);
        // 三个入口口径一致。
        expect(EmailHtmlSanitizer.stripUnsafe(deep), '', reason: opener);
        expect(EmailHtmlSanitizer.normalizeStyles(deep), '', reason: opener);
      }
    });

    test('嵌套表格不会被「解析后反而更深」误降级（修复前会红）', () {
      // 输入深度 900（< 1000，外层守卫沉默），但 `package:html` 会为每个
      // `<tr>` 补一层 `<tbody>` → 序列化后再数就是 1200 → 旧实现里
      // `normalizeStyles` 收到的是**解析后**的字符串，于是降级、整张表格丢光。
      final sb = StringBuffer();
      for (var i = 0; i < 300; i++) {
        sb.write('<table><tr><td>');
      }
      sb.write('MARK');
      for (var i = 0; i < 300; i++) {
        sb.write('</td></tr></table>');
      }
      final out = EmailHtmlSanitizer.toSafeSubset(sb.toString());
      expect(out, contains('MARK'));
      expect(out, contains('<table')); // 表格结构必须保住
    });

    test('表格级样式 cross-module 回归锁：TableHtmlCodec 的形状不被误伤', () {
      // 跨模块回归锁 —— 表格真正上线时 `TableHtmlCodec.encode` 的输出会先
      // 经过这里。`<table>` 本身只带 border-collapse/width，这两项必须活下来。
      final html = TableHtmlCodec.encode(
        MailTableModel(
          cells: [['甲', '乙'], ['丙', '丁']],
          widths: [120, 80],
          hasHeaderRow: true,
        ),
      );
      final out = EmailHtmlSanitizer.toSafeSubset(html);
      // 净化器会把 <tr> 包进 <tbody>（package:html 的解析行为），
      // 所以用 contains 而不是全等。
      expect(out, contains('border-collapse:collapse'));
      expect(out, contains('width:100%'));
      // 每个 td/th 的完整样式逐字保住。
      expect(
        out,
        contains('style="border:1px solid #CCCCCC;padding:6px 8px;'
            'text-align:left;width:120px"'),
      );
      expect(
        out,
        contains('style="border:1px solid #CCCCCC;padding:6px 8px;'
            'text-align:left;width:80px"'),
      );
    });

    test('表格反例：非白名单样式/超长宽度/url(...) 一律被削', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<table style="border-collapse:collapse;position:fixed;'
        'width:99999px;background:url(x)"><tr><td>x</td></tr></table>',
      );
      // 只有 border-collapse 该活下来。
      expect(out, contains('border-collapse:collapse'));
      expect(out, isNot(contains('position')));
      expect(out, isNot(contains('background')));
      expect(out, isNot(contains('url(')));
      // 5 位宽的 99999 不匹配 ^\d{1,4}$，整条 width 丢失（表格没有别的 width）。
      expect(out, isNot(contains('width:')));
    });
  });

  group('对抗性输入', () {
    test('data:image/svg+xml 被拒绝（SVG 能执行 JS，是 XSS 洞）', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<img src="data:image/svg+xml,<svg onload=alert(1)>">',
      );
      // SVG 不是「粘贴进来的图片」，是「一段可执行的标记」；精确前缀必须
      // 到分号，只认光栅格式。
      expect(out, isNot(contains('svg')));
    });

    test('真的内联 PNG 仍然放行（不能误伤剪贴板图片路径）', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<img src="data:image/png;base64,AAAA">',
      );
      expect(out, contains('data:image/png;base64,AAAA'));
    });

    test('data:application/xhtml+xml 被中和（不是图片源）', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<a href="data:application/xhtml+xml,<script>alert(1)</script>">click</a>',
      );
      expect(out, isNot(contains('data:')));
      expect(out, contains('click'));
    });

    test('file: 与 blob: 被中和', () {
      expect(
        EmailHtmlSanitizer.toSafeSubset('<a href="file:///etc/passwd">x</a>'),
        isNot(contains('file:')),
      );
      expect(
        EmailHtmlSanitizer.toSafeSubset('<a href="blob:https://e/x">x</a>'),
        isNot(contains('blob:')),
      );
    });

    test('NUL 走私：控制字符剥离后命中的 scheme 必须被放行（mail\\u0000to:）', () {
      // 为什么挑 `mail\0to:` 而不是 `java\0script:`：未知 scheme 本来就一律
      // 被中和成 `#`，所以「方案名里夹 NUL」这两种输入会得到**逐字节相同**
      // 的输出，断言分不出剥离逻辑在不在。要能区分 mutate，输入必须是
      // 「剥离之后会命中允许列表」的形状 —— `mailto:` 在允许列表里：
      //   剥离 → href="mailto:x@e.com"（保留）
      //   不剥离 → 归一化后 scheme 变成 `mail\0to:`（不在白名单）→ 中和成 `#`
      // 顺序很重要：必须**先规范化（删控制字符）再判断是否放行**。浏览器
      // 对 URL 里的 NUL 是替换成 U+FFFD 而不是删除，所以「删除」是我们自己
      // 的规范化；若反过来先判断再规范化，`mail\0to:` 会被当成未知 scheme
      // 拒绝掉，一个合法链接就被误杀。
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<a href="mail\u0000to:x@e.com">x</a>',
      );
      expect(out, contains('href="mailto:x@e.com"'));
      expect(out, isNot(contains('href="#"')));
      // 归一化后的 href 里不应残留 NUL 或替换字符。
      expect(out, isNot(contains('\u0000')));
      expect(out, isNot(contains('�')));
    });

    test('NUL 走私：剥离后才是未知 scheme 的仍被中和', () {
      // 对照组：`java\0script:` 剥离后仍是 `javascript:`（不在白名单）→ 中和。
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<a href="java\u0000script:alert(1)">x</a>',
      );
      expect(out, contains('href="#"'));
      expect(out, isNot(contains('javascript')));
    });

    test('大小写混写的 JaVaScRiPt: 被中和', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<a href="JaVaScRiPt:alert(1)">x</a>',
      );
      expect(out, isNot(contains('JaVaScRiPt')));
      expect(out, isNot(contains('javascript')));
    });

    test('单元格 width 值里的 url(...) 走私被丢', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<table><tr><td style="width:url(javascript:alert(1))">x</td></tr></table>',
      );
      expect(out, isNot(contains('url(')));
    });

    test('单元格 padding 值里的 expression(...) 走私被丢', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<table><tr><td style="padding:expression(alert(1))">x</td></tr></table>',
      );
      expect(out, isNot(contains('expression')));
    });

    test('段落 text-align 值里的 url(...) 走私被丢', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<p style="text-align:url(javascript:alert(1))">x</p>',
      );
      expect(out, isNot(contains('url(')));
    });

    test('TableHtmlCodec 生成的真实形状不能被误伤', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<table><tr><td style="width:120px;border:1px solid #cccccc;'
        'padding:6px 8px;text-align:left">x</td></tr></table>',
      );
      expect(out, contains('width:120px'));
      expect(out, contains('border:1px solid #cccccc'));
      expect(out, contains('padding:6px 8px'));
      expect(out, contains('text-align:left'));
    });

    test('常见合法 URL 全部保留', () {
      expect(
        EmailHtmlSanitizer.toSafeSubset('<a href="https://e.com">x</a>'),
        contains('href="https://e.com"'),
      );
      expect(
        EmailHtmlSanitizer.toSafeSubset('<a href="mailto:a@b.c">x</a>'),
        contains('href="mailto:a@b.c"'),
      );
      expect(
        EmailHtmlSanitizer.toSafeSubset('<a href="#anchor">x</a>'),
        contains('href="#anchor"'),
      );
      expect(
        EmailHtmlSanitizer.toSafeSubset('<a href="a/b.png">x</a>'),
        contains('href="a/b.png"'),
      );
      expect(
        EmailHtmlSanitizer.toSafeSubset('<a href="tel:+86">x</a>'),
        contains('href="tel:+86"'),
      );
      expect(
        EmailHtmlSanitizer.toSafeSubset('<img src="cid:abc">'),
        contains('src="cid:abc"'),
      );
    });

    test('template / math 连同内容一起删（藏 script 的经典位置）', () {
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<template><script>alert(1)</script></template><p>正文</p>',
      );
      expect(out, isNot(contains('script')));
      expect(out, contains('正文'));
    });
  });

  group('深嵌套预检（防爆栈 / 防卡住）', () {
    // 背景：`package:html` 的解析与序列化是**按深度递归**的，深嵌套输入会先
    // 卡住几十秒再抛 `StackOverflowError`（`Error`，`catch` 兜不住）。
    // 十层 div 那次崩溃（10 万层、约 192 秒）是复核者用探针手动验证的，
    // **当时进不了 CI** —— 修复前跑一次要几分钟。守卫挪到 `toSafeSubset`
    // 入口（守原始输入、超限根本不解析）之后，同一条输入**毫秒级**返回，
    // 所以现在它是一条正经的回归用例了（见下面「十万层」那一条）。

    test('正常输入逐字节不变：预检只在超限时改变输出', () {
      // 这是对「不动既有行为」的钉住：这些字面量是修复前的输出，逐字节比对。
      // 三个入口各自的行为不同（`normalizeStyles` 本来就不负责安全），所以分开钉。
      const toSafeSubsetCases = <String, String>{
        '<p style="text-align:center">中央</p>':
            '<p style="text-align:center">中央</p>',
        '<table><tr><td style="width:120px">x</td></tr></table>':
            '<table><tbody><tr><td style="width:120px">x</td></tr></tbody></table>',
        '<a href="javascript:alert(1)">x</a>': '<a href="#">x</a>',
        '<p>&lt;script&gt; &amp; &#65;</p>': '<p>&lt;script&gt; &amp; A</p>',
        '<div><span>a</span><b>b</b></div>':
            '<div><span>a</span><b>b</b></div>',
      };
      for (final entry in toSafeSubsetCases.entries) {
        expect(
          EmailHtmlSanitizer.toSafeSubset(entry.key),
          entry.value,
          reason: 'toSafeSubset: ${entry.key}',
        );
        expect(
          EmailHtmlSanitizer.stripUnsafe(entry.key),
          entry.value,
          reason: 'stripUnsafe: ${entry.key}',
        );
      }

      // `normalizeStyles` 只去 class/id + 压 style 白名单，**不负责安全**，
      // 所以 `javascript:` 链接它照留 —— 这是既有行为，也要钉住。
      const normalizeStylesCases = <String, String>{
        // 批 B 更新：`font-size:9px` 形状合法（`^[1-9]\d{0,2}px$`）→ 保留；
        // 具名色 `color:red` 非 `#rrggbb` → 丢掉。批 B 之前这两条都丢。
        '<p class="x" id="y" style="color:red;text-align:right;font-size:9px">z</p>':
            '<p style="text-align:right;font-size:9px">z</p>',
        '<a href="javascript:alert(1)">x</a>':
            '<a href="javascript:alert(1)">x</a>',
      };
      for (final entry in normalizeStylesCases.entries) {
        expect(
          EmailHtmlSanitizer.normalizeStyles(entry.key),
          entry.value,
          reason: 'normalizeStyles: ${entry.key}',
        );
      }
    });

    test('超限时降到纯文本（毫秒级），不解析、不抛', () {
      final deep =
          '${'<div>' * 1500}<p>Hello &amp; &lt;b&gt; world</p>${'</div>' * 1500}';
      final out = EmailHtmlSanitizer.toSafeSubset(deep);
      // 内容是**转义过的纯文本**，不是标签。
      expect(out, 'Hello &amp; &lt;b&gt; world');
      // 其余两个入口行为一致。
      expect(EmailHtmlSanitizer.stripUnsafe(deep), out);
      expect(EmailHtmlSanitizer.normalizeStyles(deep), out);
    });

    test('十万层 div：修复前爆栈（复核者的现场），现在不抛也不卡', () {
      // 这一条钉的是「守卫的**位置**」，不是阈值 —— 阈值在上面那条 1500 里。
      // 现场：`toSafeSubset(10 万层)` 在 `6880d04` 之前抛
      // `StackOverflowError`（`Error`，`catch` 兜不住），耗时 38–192 秒，
      // 复核者据此判定「封顶放在解析之后、结构上救不了」。
      // 修法是把守卫挪到**入口**（守原始输入）：超限就根本不进 `parseFragment`。
      //
      // 为什么不担心它慢：这条输入 110 万字符，走的是「扫一遍数深度」那条
      // 迭代路径（`HtmlDepthGuard`，实测 38 ms），不解析、不序列化。
      // 三个入口都要过 —— 读信页走的是 `stripUnsafe` / `normalizeStyles`
      // 那两个公开入口，只钉 `toSafeSubset` 会漏掉它。
      final deep =
          '${'<div>' * 100000}<p>MARK</p>${'</div>' * 100000}';
      for (final entry in <String Function(String)>[
        EmailHtmlSanitizer.toSafeSubset,
        EmailHtmlSanitizer.stripUnsafe,
        EmailHtmlSanitizer.normalizeStyles,
      ]) {
        late final String out;
        expect(
          () => out = entry(deep),
          returnsNormally,
          reason: '超限的输入不该走到解析器里去',
        );
        // 降级成纯文本：标记文字还在，但已经没有任何真标签。
        expect(out, contains('MARK'));
        expect(out, isNot(contains('<div')));
        expect(out, isNot(contains('<p>')));
      }
    });

    test('降级输出不会再被解析成标签 —— 深嵌套这条路不能变成 XSS', () {
      // 深嵌套本来是拒绝服务；若降级把邮件里「长得像标签的文字」原样交回去，
      // 读信页再解析一次就等于把 DoS 换成了 XSS —— 那种「以为降级了、其实把
      // `<script>` 放回去了」的路径最难发现，所以要钉住转义。
      //
      // 输入里的 `<` 用 `&lt;` 写成**文字**（邮件里表示「尖括号」的常规写法），
      // 属性里的 `onerror` 也一并带上，看降级之后读者还能不能拿回一个可解析
      // 的标签 / 事件属性。
      final payload =
          '<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>'
          '<a href="javascript:alert(2)" onclick="alert(3)">点我</a>';
      final deep = '${'<div>' * 1200}$payload${'</div>' * 1200}';
      final out = EmailHtmlSanitizer.toSafeSubset(deep);
      // 没有任何真标签，也没有 `on*` 属性、没有 `javascript:`。
      expect(out, isNot(contains('<script')));
      expect(out, isNot(contains('onclick')));
      expect(out, isNot(contains('javascript:')));
      // 尖括号只剩下转义形态（再解析一遍也只会是文字）。
      expect(out, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
      expect(out, contains('点我'));
    });

    test('空内容的超限输入给空串（与既有「空输入 → 空」一致）', () {
      final deep = '${'<div>' * 5000}${'</div>' * 5000}';
      expect(EmailHtmlSanitizer.toSafeSubset(deep), '');
    });
  });

  group('颜色与字号：放行的是值形状，不是属性名', () {
    test('规范颜色与字号原样留下', () {
      expect(
        EmailHtmlSanitizer.toSafeSubset(
          '<p><span style="color:#1a73e8;background-color:#e6f4ea;font-size:19px">x</span></p>',
        ),
        '<p><span style="color:#1a73e8;background-color:#e6f4ea;font-size:19px">x</span></p>',
      );
    });

    test('颜色值形状不对就整条丢掉', () {
      // 只认 `#rrggbb` 六位。`red`、`#abc`、`rgb(...)`、`var(...)`
      // 一律丢 —— **不转换**（转换等于自己实现一套 CSS 颜色解析，
      // 而 `rgb()` 里能塞的东西比想象的多）。
      //
      // **⚠️ 大小写不在这一条里**：`_filterStyle` 是
      // `pattern.hasMatch(value.toLowerCase())` —— **匹配用小写、写回用原样**。
      // 实测 `style="color:#ABCDEF"` 经 `toSafeSubset` **原样留下**。
      // 所以这里放一条 `#ABCDEF` 会**永远绿不了**（不是实现错了，是断言写错了）。
      // 大小写的处理见下一条用例。
      for (final bad in <String>[
        'red',
        '#abc',
        'rgb(1,2,3)',
        'var(--x)',
        'expression(alert(1))',
        '#1a73e8ff',   // 八位：看着像 hex，但不在我们的形状里
        '#12345',      // 五位
        '#1a73e8}body{display:none', // 带 `}`，被 `_filterStyle` 的老防线丢
        '#1a73e8!important',
      ]) {
        final html = '<p><span style="color:$bad">x</span></p>';
        final out = EmailHtmlSanitizer.toSafeSubset(html);
        expect(out, isNot(contains('color:')), reason: '放过了一个: $bad');
      }
    });

    test('大写颜色被放行 —— 这是已知的、与 kHexColorPattern 不一致的地方', () {
      // 与 `kHexColorPattern`（`^#[0-9a-f]{6}$`，小写）**不一致**：净化器这一层
      // 匹配小写、但把原值原样写回，所以大写活了下来，而它在导入端
      // （`MailHtmlToDelta`）与导出端（`safeHexColor`）都认不出 → 颜色被丢。
      // **失败方向是安全的**（丢一个颜色，不是放一个危险值进来），所以本计划
      // **接受**这个不一致、不为此改净化器；这条用例把它钉成**已知行为**，
      // 免得以后有人看见 `#ABCDEF` 活着而误以为大小写被统一处理过。
      expect(
        EmailHtmlSanitizer.toSafeSubset(
          '<p><span style="color:#ABCDEF">x</span></p>',
        ),
        contains('#ABCDEF'),
      );
    });

    test('字号值只认 px 的 1-3 位（且不认 0）', () {
      expect(
        EmailHtmlSanitizer.toSafeSubset('<p><span style="font-size:19px">x</span></p>'),
        contains('font-size:19px'),
      );
      for (final bad in <String>['19', '0px', '19em', '19pt', '1200px', '1.2em', 'calc(1px)']) {
        final out = EmailHtmlSanitizer.toSafeSubset(
          '<p><span style="font-size:$bad">x</span></p>',
        );
        expect(out, isNot(contains('font-size')), reason: '放过了一个: $bad');
      }
    });

    test('属性名塞不进 style 里', () {
      // 值里带 `}` / `<` / `>` 的老防线还在。
      final out = EmailHtmlSanitizer.toSafeSubset(
        '<p><span style="color:#1a73e8}body{display:none">x</span></p>',
      );
      expect(out, isNot(contains('display:none')));
    });
  });
}
