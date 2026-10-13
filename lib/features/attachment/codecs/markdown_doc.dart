import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:markdown/markdown.dart' as md;

/// `.md` 附件的渲染，外加一层**解析前**的守卫。
///
/// ## 为什么需要守卫
///
/// `package:markdown` 的块解析是**按嵌套深度递归**的（`BlockParser.parseLines`
/// → `BlockSyntax.parse` → 子 `BlockParser`），行内解析则对括号 / 星号做回溯。
/// 一份畸形或敌意的文本能把两者一起点着。实测（探针，macOS 开发机，
/// `ExtensionSet.gitHubFlavored`，全是**只有几十 KB** 的输入）：
///
/// | 输入 | 长度 | 结果 |
/// |---|---|---|
/// | `'>' * 20000 + ' x'`（一行两万个 `>`） | 20 KB | **47 秒后 StackOverflowError** |
/// | `'>' * 50000 + ' x'` | 50 KB | 7.3 秒后 StackOverflowError |
/// | `'[' * 20000 + 'a' + ']' * 20000` | 40 KB | 21 秒（没崩，就是慢） |
/// | `'[a' * 20000 + ']' * 20000` | 60 KB | 33 秒 |
/// | 嵌套列表，1000 层缩进 | 1.0 MB | 3.2 秒 |
///
/// 前两栏才是要害：**长度只有几十 KB 就已经崩了**，所以「限长度」这条路走不通
/// —— 想把 20 秒压到 0.2 秒，括号那一档只能放到 4 KB，真实 README 都过不去。
/// 能压住的是**深度**，不是长度（同样 161 KB：深度 400 的嵌套列表 258ms，
/// 而 400 行浅列表 234ms，量级相同；但 `'[' * k + 'a' + ']' * k` 在 k=5000/10KB
/// 就已经 1.4 秒 —— 深度是把同长度输入拉开两个数量级的那一项）。
///
/// 邮件附件是**不可信输入**，和正文 HTML 一样。本仓库已经为正文 HTML 写过
/// 同型的 `HtmlDepthGuard`（`features/compose/html/html_depth_guard.dart`），
/// 理由、失败方向、近似扫描的取舍都一致：超出阈值就**不再解析**，退回能看的
/// 东西，而不是让 App 冻住几十秒再崩。
///
/// ## 扫描是近似的，方向是「宁可高估」
///
/// 一次 O(n) 字符串扫描，量三样东西：
/// 1. **引用深度**：一行的前导 `>` 个数（`> > >` 与 `>>>` 都算 3）；
/// 2. **列表缩进**：前导空格数 ÷ 2，取最大值；
/// 3. **括号嵌套**：全文 `[` 减 `]` 的**运行峰值**（转义的 `\[` 不算）。
///
/// 围栏代码块（``` / ~~~）整段跳过 —— 那是全篇最可能出现「一串 `[`」的地方，
/// 而它恰恰是**不会被解析**的内容。行内代码（`` ` ``）不跳过：它的代价低
/// （`'text \`' + bad + '\`'` 实测 3ms），高估一点无所谓。
///
/// 识别围栏时**宁可漏认、不可错认**：漏认只是把代码块的括号也数进去
/// （高估 → 退回源码视图，安全），错认却会让守卫跳过一段**解析器照样会解析**
/// 的正文，那就是一条绕过路径。所以这里的规则严格照抄 `markdown` 包
/// `codeFencePattern` 的形状，不自己发挥（比如「反引号围栏的 info string
/// 里不能出现反引号」这条也照抄 —— 少了它，`` ```a`b `` 这种行会被我当成
/// 围栏，解析器却当成普通段落，后面跟着一串 `[` 就绕过去了）。
///
/// 高估的代价只是「一份本来能渲染的文档退回源码视图」，低估的代价是冻住甚至
/// 崩溃 —— 所以三个阈值都取得比真实文档宽得多（见各自注释），近似的误差留在
/// 安全的那一侧。降级时界面会说明原因，用户仍看得到完整源码。
abstract final class MarkdownDoc {
  const MarkdownDoc._();

  /// 引用深度上限。
  ///
  /// 真实 `.md` 里 `>` 引用极少超过 3 层（邮件回复链那种是 HTML 不是 md）。
  /// 200 层实测 2ms；崩溃要到 2 万层，留了 100 倍余量。
  static const int maxQuoteDepth = 200;

  /// 列表缩进上限，单位是「2 个空格算一层」。
  ///
  /// 真实文档的深层列表到 8 层就算很深了。100 层（缩进 200 列）在实测里
  /// 不到 25ms，而 1000 层要 3.2 秒。
  static const int maxIndentLevels = 100;

  /// 括号嵌套上限。
  ///
  /// 全篇 `[` 与 `]` 的运行峰值。真实 markdown 里这个值基本就是个位数
  /// （`[文本](链接)` 一开一合、代码里的 `a[i]`）；200 层实测 2ms，
  /// 而 5000 层要 1.4 秒、2 万层要 21 秒。
  static const int maxBracketDepth = 200;

  /// 这段文本能不能安全地交给 `markdown` 解析。
  static bool exceedsLimit(String source) {
    if (source.isEmpty) return false;

    var maxQuote = 0;
    var maxIndent = 0;
    var bracket = 0;
    var maxBracket = 0;
    var inFence = false;

    var start = 0;
    while (start <= source.length) {
      var end = source.indexOf('\n', start);
      final last = end < 0;
      if (last) end = source.length;

      final line = source.substring(start, end);
      start = end + 1;

      if (_isFence(line)) {
        inFence = !inFence;
        if (last) break;
        continue;
      }
      if (inFence) {
        if (last) break;
        continue;
      }

      // 前导 `>`：`>>>`、`> > >`、`  > x`（最多 3 个前导空格）都算。
      final quotes = _countQuotes(line);
      if (quotes > 0) {
        if (quotes > maxQuote) maxQuote = quotes;
      } else {
        // 空行不参与缩进判断：`\n\n` 之后那点空白不是嵌套。
        if (line.trim().isNotEmpty) {
          final indent = _leadingSpaces(line) ~/ 2;
          if (indent > maxIndent) maxIndent = indent;
        }
      }

      // 括号：只在这一行里数，跨行继续累加（列表项之间也连着）。
      for (var i = 0; i < line.length; i++) {
        final ch = line.codeUnitAt(i);
        if (ch == _openBracket) {
          // `\[` 是转义的、markdown 会把它当字面量 —— 但 `\\[` 不是：
          // 反斜杠自己也被转义了，那个 `[` 是**真括号**。所以判据是
          // 「前面紧挨着**奇数个**反斜杠」而不是「前面有反斜杠」。
          // 数错这一格等于给攻击者留一条绕过路径（`'\\[' * n` 在守卫这里
          // 显示 0 层，解析器却数出 n 层）。
          if (_escaped(line, i)) continue;
          bracket++;
          if (bracket > maxBracket) maxBracket = bracket;
        } else if (ch == _closeBracket) {
          if (_escaped(line, i)) continue;
          if (bracket > 0) bracket--;
        }
      }

      if (maxQuote > maxQuoteDepth ||
          maxIndent > maxIndentLevels ||
          maxBracket > maxBracketDepth) {
        return true;
      }

      if (last) break;
    }
    return false;
  }

  /// 把 markdown 渲染成 HTML；**超限时返回 null**。
  ///
  /// 返回的是 HTML 片段，交给 `HtmlBodyView`（它会再过一遍
  /// `sanitizeEmailHtml`）—— 不新写一套 markdown → widget 映射。
  ///
  /// 用 [md.ExtensionSet.gitHubFlavored]（表格、任务列表、删除线、自动链接）
  /// 而不是 `gitHubWeb`：后者会额外认 `<style>` / `<script>` 这类裸 HTML 块，
  /// 而这里的输入是**不可信文件**，多认一种块级语法就是多一条解析路径。
  /// 行内 HTML 仍然会原样透出（`InlineHtmlSyntax` 两个扩展集都带），
  /// 那是安全的 —— 下游 `sanitizeEmailHtml` 会把危险标签摘掉。
  static String? toHtml(String source) {
    if (exceedsLimit(source)) return null;
    // `<tag>` 的行内直通保持默认：关掉它会让正文里的 `a < b` 更容易混淆，
    // 而安全本来就不靠这里 —— 下游净化才是那道关。
    final html = md.markdownToHtml(
      source,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );
    // 图片换成占位文字（见 [_replaceImages]）。**必须在生成 HTML 之后、
    // 交给 `HtmlBodyView` 之前**做：附件是本地文件，那里的 `src` 是相对于
    // `.md` 所在目录的路径，而这个 HTML 最终会由 `cached_network_image`
    // 按 HTTP URL 去取 —— 取不到，只会留一片空白和一个被卡住的加载态。
    return _replaceImages(html);
  }

  /// 把渲染出来的 `<img>` 换成 `[图片: alt]`。
  ///
  /// 为什么走 DOM 而不是正则：`alt` / `src` 里的 `>` `"` 会被渲染器转义成
  /// `&gt;` `&quot;`（实测），所以正则本身是安全的 —— 但那个**事实**没有保证，
  /// 而这里处理的是不可信输入。用 `package:html` 解析一次再按元素替换，
  /// 就没有「什么字符能打破正则」这个问题；顺带还能一眼看清换了几个。
  ///
  /// 不走 `sanitizeEmailHtml` 那条路是因为它**保留** `img` 的 `src`
  /// （正文里的内嵌图是 http URL，正是要留着的），这里要的是相反的处置。
  static String _replaceImages(String html) {
    if (!html.contains('<img')) return html;
    final fragment = html_parser.parseFragment(html);
    final images = fragment.querySelectorAll('img');
    for (final image in images) {
      final alt = (image.attributes['alt'] ?? '').trim();
      image.replaceWith(
        dom.Text(alt.isEmpty ? '[图片]' : '[图片: $alt]'),
      );
    }
    return fragment.outerHtml;
  }

  // ---------------------------------------------------------------- 内部

  /// 是不是围栏代码块的边界行。
  ///
  /// 照抄 `markdown` 包的 `codeFencePattern` 形状：最多 3 个前导空格，
  /// 三个及以上的 ``` 或 ~~~，**反引号围栏的 info string 里不许再出现反引号**
  /// （`~` 围栏没有这条限制）。任一条不满足就当作「不是围栏」。
  static bool _isFence(String line) {
    var i = 0;
    while (i < line.length && i < 3 && line.codeUnitAt(i) == _space) {
      i++;
    }
    if (i >= line.length) return false;
    final ch = line.codeUnitAt(i);
    if (ch != _backtick && ch != _tilde) return false;
    var run = 0;
    while (i < line.length && line.codeUnitAt(i) == ch) {
      i++;
      run++;
    }
    if (run < 3) return false;
    final info = line.substring(i);
    if (ch == _backtick && info.contains('`')) return false;
    return true;
  }

  /// 前导 `>` 的个数：`> > >` 与 `>>>` 都算 3，`  >x` 算 1。
  static int _countQuotes(String line) {
    var i = 0;
    var count = 0;
    // 行首最多 3 个空格（markdown 的块级缩进余量）。
    while (i < line.length && i < 3 && line.codeUnitAt(i) == _space) {
      i++;
    }
    while (i < line.length && line.codeUnitAt(i) == _gt) {
      count++;
      i++;
      // `>` 与 `>` 之间允许一个空格。
      if (i < line.length && line.codeUnitAt(i) == _space) i++;
    }
    return count;
  }

  /// [line] 里下标 [i] 的字符是不是被反斜杠转义了。
  ///
  /// 判据是**前面紧挨着奇数个** `\` —— `\[` 转义（`[` 是字面量），
  /// `\\[` 不转义（`\` 自己被转义，`[` 是真括号）。只看「前一个字符是不是
  /// 反斜杠」会把 `\\[` 也当成转义，正是绕过路径。
  static bool _escaped(String line, int i) {
    var backslashes = 0;
    var j = i - 1;
    while (j >= 0 && line.codeUnitAt(j) == _backslash) {
      backslashes++;
      j--;
    }
    return backslashes.isOdd;
  }

  static int _leadingSpaces(String line) {
    var i = 0;
    while (i < line.length && line.codeUnitAt(i) == _space) {
      i++;
    }
    return i;
  }

  static const int _space = 0x20;
  static const int _gt = 0x3E;
  static const int _backslash = 0x5C;
  static const int _openBracket = 0x5B;
  static const int _closeBracket = 0x5D;
  static const int _backtick = 0x60;
  static const int _tilde = 0x7E;
}
