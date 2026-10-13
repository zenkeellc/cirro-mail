import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/html/html_depth_guard.dart';

/// 深嵌套爆栈 / 卡顿的**解析前预检**的纯函数测试。
///
/// 这里全部用**纯字符串**、**大 n**：`maxNestingDepth` 是一次 O(n) 扫描，
/// 十万层 <div>（约 110 万字符）也是毫秒级 —— 所以能直接拿「会爆栈的那个输入」
/// 来测预检本身，而不是等真的把 DOM 建起来。**整个文件必须在秒级跑完**，
/// 任何一条用例只要开始卡就说明构造错了。
void main() {
  group('maxNestingDepth：深度扫描', () {
    test('十万层 <div> 直接数得出来（毫秒级，不会解析 DOM）', () {
      final html = '${'<div>' * 100000}<p>MARK</p>${'</div>' * 100000}';
      // 顶层 10 万层 <div>，里面那层 <p> 是第 100001 层 —— 取的是**最大值**。
      expect(HtmlDepthGuard.maxNestingDepth(html), 100001);
    });

    test('正常输入：真实回复链的深度被如实数出来', () {
      // 仿 Gmail / Apple Mail 的一轮引用：外层 div > p + blockquote > p，三层。
      final oneRound =
          '<div><p>文字</p><blockquote><p>引用</p></blockquote></div>';
      expect(HtmlDepthGuard.maxNestingDepth(oneRound), 3);
      expect(HtmlDepthGuard.maxNestingDepth(oneRound * 10), 3);
      expect(HtmlDepthGuard.exceedsLimit(oneRound * 10), isFalse);
    });

    test('阈值边界：1000 及以下放行，1001 及以上触发降级', () {
      expect(HtmlDepthGuard.maxSafeDepth, 1000);
      final at = '${'<div>' * 1000}x${'</div>' * 1000}';
      final over = '${'<div>' * 1001}x${'</div>' * 1001}';
      expect(HtmlDepthGuard.maxNestingDepth(at), 1000);
      expect(HtmlDepthGuard.exceedsLimit(at), isFalse);
      expect(HtmlDepthGuard.maxNestingDepth(over), 1001);
      expect(HtmlDepthGuard.exceedsLimit(over), isTrue);
    });

    test('void 元素不堆深度（一堆 <br> 堆不出嵌套）', () {
      expect(HtmlDepthGuard.maxNestingDepth('<br>' * 500000), 0);
      expect(HtmlDepthGuard.maxNestingDepth('<br><br><img src=x><hr>'), 0);
      expect(HtmlDepthGuard.exceedsLimit('<img src=x>' * 500000), isFalse);
    });

    test('`<div/>` 按普通开始标签计数（HTML 命名空间里 /> 不自闭）', () {
      // 这是**绕过路径**的回归测试：解析器把 `'<div/>' * N` 建成 N 层 DOM，
      // 若守卫把 `/>` 当成自闭合就会数出 0 层，深嵌套输入将绕过预检直冲解析。
      final html = '${'<div/>' * 50000}x';
      expect(HtmlDepthGuard.maxNestingDepth(html), 50000);
      expect(HtmlDepthGuard.exceedsLimit(html), isTrue);
    });

    test('注释 / doctype / CDATA 里的标签不计数（与 tokenizer 语义对齐）', () {
      // 正常的 `<!-- ... -->` 整段不计数；doctype 本身不计数，`<p>` 是第 1 层。
      expect(HtmlDepthGuard.maxNestingDepth('<!--${'<div>' * 5000}-->x'), 0);
      expect(HtmlDepthGuard.maxNestingDepth('<!DOCTYPE html><p>x</p>'), 1);
      // **注意**：正文里的 `<![CDATA[` 走的是 tokenizer 的 **bogus comment**
      // （遇到第一个 `>` 就结束），后面的 `<div>` 是**真元素** —— 不是 0 层。
      // 见下面「正文里的 <![CDATA[ 走 bogus comment」那条回归测试。
      expect(
        HtmlDepthGuard.maxNestingDepth('<![CDATA[${'<div>' * 5000}]]>x'),
        // 第一个 `>`（第一个 <div> 的结束）之后还有 4999 个真 <div>。
        4999,
      );
    });

    test('注释的提前闭合写法不能让后面的真标签被吞掉（绕过路径回归）', () {
      // 解析器认 `<!-->` / `<!--->` / `--!>` 三种提前闭合；只找 `-->` 的实现
      // 会把注释一路吃到串尾，把后面的真标签全吞掉 → 深度 0 → 放行一次爆栈。
      for (final opener in <String>['<!-->', '<!--->', '<!-- y --!>']) {
        final html = '$opener${'<div>' * 1500}';
        expect(HtmlDepthGuard.maxNestingDepth(html), 1500, reason: opener);
        expect(HtmlDepthGuard.exceedsLimit(html), isTrue, reason: opener);
      }
      // 正常注释照旧整段不计数。
      expect(
        HtmlDepthGuard.maxNestingDepth('<!-- ${'<div>' * 1500} -->x'),
        0,
      );
    });

    test('正文里的 <![CDATA[ 走 bogus comment，后面的真标签要计数（绕过路径回归）', () {
      // CDATA 只在**外来内容（SVG / MathML）**里成立；HTML 正文里 `<!…` 一律
      // 是 bogus comment（遇到第一个 `>` 就结束）。
      // 实测 `'<![CDATA[' + '<div>'*1500` 的 DOM 里有 1499 层真 div ——
      // 守卫若跳到 `]]>` 就会数出 0 层、放行一次 40 秒后爆栈的解析。
      for (final opener in <String>['<![CDATA[', '<![cdata[']) {
        final html = '$opener${'<div>' * 1500}';
        expect(HtmlDepthGuard.maxNestingDepth(html), 1499, reason: opener);
        expect(HtmlDepthGuard.exceedsLimit(html), isTrue, reason: opener);
      }
      // 其余 `<!…` / `<?…` 同样是 bogus comment。
      expect(HtmlDepthGuard.maxNestingDepth('<!x${'<div>' * 1500}'), 1499);
      expect(HtmlDepthGuard.maxNestingDepth('<?x${'<div>' * 1500}'), 1499);
      // doctype 里没有 `<div>`，照旧只数后面的。
      expect(HtmlDepthGuard.maxNestingDepth('<!DOCTYPE html><p>x</p>'), 1);
    });

    test('处理指令按 HTML 的「bogus comment」语义处理（跳到第一个 >）', () {
      // HTML 解析器把 `<?` 当成「跳过到第一个 `>`」的 bogus comment —— 不是
      // XML 那样找到 `?>`。守卫必须跟着解析器的语义走，否则会**低估**：
      // `<?xml <div><div>…` 里第一个 `>` 之后的那一堆 `<div>` 在 DOM 里是真的
      // 元素，得照样数。
      expect(
        HtmlDepthGuard.maxNestingDepth('<?xml version="1.0"?><div><p>x</p></div>'),
        2,
      );
      expect(
        HtmlDepthGuard.maxNestingDepth('<?xml <div>${'<div>' * 4999}'),
        4999,
      );
    });

    test('属性值里的 > 不算标签结束，引号里的尖括号不干扰计数', () {
      expect(HtmlDepthGuard.maxNestingDepth('<a title="a>b"><p>x</p></a>'), 2);
      // 单引号同样处理。
      expect(HtmlDepthGuard.maxNestingDepth("<a title='a>b'><p>x</p></a>"), 2);
    });

    test('不成对的结束标签在 0 处夹住，不让深度变成负数', () {
      expect(HtmlDepthGuard.maxNestingDepth('${'</div>' * 5000}<p>x</p>'), 1);
      expect(HtmlDepthGuard.exceedsLimit('</div>' * 500000), isFalse);
    });

    test('裸 < 当普通文字（a < b、<3）', () {
      expect(HtmlDepthGuard.maxNestingDepth('a < b 和 <3 只猫'), 0);
      expect(HtmlDepthGuard.maxNestingDepth('< div>x</ div>'), 0);
    });

    test('大小写与空白/属性混排', () {
      expect(
        HtmlDepthGuard.maxNestingDepth('<DIV class="a" id=b ><span>x</span></DIV>'),
        2,
      );
    });
  });

  group('plainText：非递归降级', () {
    test('剥标签、按块边界分段、去掉排版空行', () {
      expect(
        HtmlDepthGuard.plainText('${'<div>' * 5}<p>你好</p><p>世界</p>${'</div>' * 5}'),
        '你好\n世界',
      );
    });

    test('引用块里的多个段落各自成段', () {
      expect(
        HtmlDepthGuard.plainText('<blockquote><p>甲</p><p>乙</p></blockquote>'),
        '甲\n乙',
      );
    });

    test('解常见实体与数字引用', () {
      expect(HtmlDepthGuard.plainText('a &amp; b &lt;c&gt; &#65;&#x42;&nbsp;d'), 'a & b <c> AB d');
    });

    test('解不开的实体原样保留，不造坏字符', () {
      expect(HtmlDepthGuard.plainText('&bogus; &surrogate;'), '&bogus; &surrogate;');
    });

    test('降级自身对十万层输入也是毫秒级、不抛', () {
      final html = '${'<div>' * 100000}<p>MARK</p>${'</div>' * 100000}';
      expect(HtmlDepthGuard.plainText(html), 'MARK');
    });

    test('script/style 的文字会被带出来 —— 安全性由调用方负责', () {
      // 这是**刻意的**：抽文本不做安全清洗（见调用方注释），只求不崩。
      // 写侧 `MailHtmlToDelta` 把它当纯文字，读侧 `EmailHtmlSanitizer`
      // 会把结果转义一遍。
      expect(HtmlDepthGuard.plainText('<script>alert(1)</script>正文'), 'alert(1)正文');
    });
  });
}
