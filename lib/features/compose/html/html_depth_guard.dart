/// 深嵌套 HTML 的**解析前**守卫：一次 O(n) 的字符串扫描，外加一个纯文本降级器。
///
/// ## 为什么守卫必须放在「解析之前」
///
/// 这一族崩溃的根因是**按 DOM 深度递归**的实现：
///
/// - `package:html` 的解析按深度递归建树，序列化在 `_addOuterHtml` /
///   `_addInnerHtml` 之间互递归（`dom.dart` 的 `_outerHtml`）；
/// - 上游 `flutter_quill_delta_from_html` 的 `processNode` 同样递归，深度由输入决定；
/// - 本目录 `mail_html_to_delta.dart` 里的 `_visitChildren` / `_visitElement` 也是。
///
/// 所以一封畸形 / 敌意的邮件（`'<div>' * n + 正文 + '</div>' * n`）能让写信页
/// 抛 `StackOverflowError`。两个要点让它特别难缠：
///
/// 1. `StackOverflowError` 是 `Error` 不是 `Exception` —— 现有的 `catch`
///    一条都兜不住；
/// 2. **它崩之前会先卡住**。实测（探针，macOS 开发机，见提交说明）：
///    `EmailHtmlSanitizer.toSafeSubset` 1000 层 78ms、2000 层 136ms、
///    4000 层 480ms、8000 层 930ms 后 `StackOverflowError`；
///    2 万层要 6.7s、5 万层要 40s 才抛出；`MailHtmlToDelta.convert` 在 10 万层
///    要 **192 秒**才崩。用户看到的是「粘了一下，写信页冻住一到三分钟，然后白屏」。
///
/// 因此「先把 DOM 建起来、再在某处剪枝」在结构上就不成立：剪枝代码自己也在
/// 递归里（会先崩），而且那几十秒已经花掉了。唯一的出路是对**原始字符串**做一次
/// 廉价预检，超限就根本不解析它。
///
/// ## 扫描是近似的
///
/// [maxNestingDepth] 只做「开始标签 +1 / 结束标签 -1 / 取运行最大值」，不实现
/// HTML5 的树构造算法，因此与真实 DOM 深度在两个方向都可能偏差：
///
/// - **高估**：有自动闭合语义的标签（连写一堆 `<p>` / `<li>` / `<a>`，解析器
///   其实只建很浅的树）会被逐个计数；
/// - **低估**：解析器**隐式补出**的容器（`<tr>` 外补 `<tbody>`、孤立的 `<li>`
///   外补 `<ul>`）不在输入里、数不到 —— 但这类补偿是**每层加一个常数**，
///   不会把一个浅输入变成上千层。
///
/// 高估只会在极端输入上提前降级（安全的失败方向），低估才会放过一次爆栈，
/// 而低估的幅度是常数级；阈值 [maxSafeDepth] 又留了约 8 倍余量，近似足够。
///
/// ## `<!…` / `<?…` 必须与 tokenizer 语义对齐
///
/// 「注释 / doctype / 处理指令一律跳过」这句话**曾经**被实现成「`<!…` 跳到第
/// 一个 `>`、`<!--` 跳到 `-->`」，那是两处**低估**的绕过路径：
///
/// - HTML 注释有**提前闭合**写法（`<!-->`、`<!--->`、`--!>`），解析器的注释
///   状态机认这些。只找 `-->` 的朴素实现会把注释一路吃到串尾，于是注释**后面
///   的真标签**在守卫这里全被吞掉 —— 深度数成 0，而解析器照样把它们建成 DOM
///   （实测 `'<!-->' + '<div>' * 50000`：守卫 0 层，解析约 42 秒后爆栈）。
/// - `<![CDATA[` 只在**外来内容（SVG / MathML）里**才是真 CDATA；在 HTML 正文里
///   它落到 tokenizer 的 **bogus comment**，遇到第一个 `>` 就结束。所以
///   `'<![CDATA[' + '<div>' * 50000` 里的 `<div>` 全是**真元素**，跳到 `]]>`
///   同样会数出 0 层（实测 44 秒后爆栈）。
///
/// 现在按 `package:html` tokenizer 的真实语义处理：注释走状态机（含提前闭合），
/// 其余 `<!…` / `<?…` 一律 bogus comment（跳到第一个 `>`）。见 [_commentEnd]。
///
/// 一个已知的、**高估**方向的小偏差：真 CDATA（外来内容 SVG / MathML 里）与
/// 直到串尾仍未闭合的注释，现实解析器会把其中**被吃掉**的 `<div>` 当文字，而
/// 本扫描器仍按普通标签计数 —— 方向是「多算」，只会提前降级，不会放过爆栈。
library;

abstract final class HtmlDepthGuard {
  const HtmlDepthGuard._();

  /// 允许解析的最大标签嵌套深度；超过它一律**降级**（不再解析）。
  ///
  /// 取值 1000 的依据（全是实测）：
  ///
  /// - **真实邮件远低于它**：仿 Gmail / Apple Mail 的
  ///   「`div` > 文字 + `blockquote`」回复链在 98 层仍然完整保留；真实客户端
  ///   （Gmail / Outlook / Apple Mail）你回我回我顶多十几到几十层。网页复制
  ///   出来的布局 HTML（嵌套 `div` / `table` 排版）通常也就二三十层。
  /// - **卡顿与崩溃远高于它**：见类注释的实测曲线 —— 4 千层已经 0.48s、
  ///   8 千层抛栈溢出。1000 层在开发机上是 78ms，离崩溃阈值还有约 8 倍。
  /// - 留出的余量是给**移动端**的：手机比开发机慢几倍，1000 层在那边也是
  ///   百毫秒量级，不会变成「冻住」。
  static const int maxSafeDepth = 1000;

  /// 原始 HTML 字符串里的**最大标签嵌套深度**（近似值，非递归、O(n)）。
  ///
  /// 做了这些事：跳过注释 / doctype / 处理指令，跳过引号包起来的属性值
  /// （`<a title="a>b">` 里的 `>` 不算标签结束），跳过 HTML 的 void 元素
  /// （`<br>` / `<img>` 这些不增深度），结束标签把深度减回去并在 0 处
  /// 夹住（对付不成对的 `</div>`）。
  ///
  /// `<` 后面不是标签名（`a < b`、`<3`）时当普通文字跳过，不计数。
  ///
  /// **`<div/>` 这种「自闭合写法」按普通开始标签计数**：HTML5 在 HTML
  /// 命名空间里**不认** `/>`，`<div/>` 与 `<div>` 一模一样（`/>` 只有在外来
  /// 内容 SVG / MathML 里才真正自闭）。若按「自闭合 → 不增深度」处理，
  /// `'<div/>' * 500000` 就会在守卫这里显示成 0 层、却被解析器建成五十万层，
  /// 正好绕过守卫 —— 攻击者要的就是这个。宁可对少量真自闭合标签（内联 SVG）
  /// **高估**深度，也不能给出一条绕过路径。
  static int maxNestingDepth(String html) {
    var depth = 0;
    var max = 0;
    var i = 0;
    final len = html.length;
    while (i < len) {
      final lt = html.indexOf('<', i);
      if (lt < 0) break;
      final (next, name, closing, isMarkup) = _scanTag(html, lt, len);
      i = next > lt ? next : lt + 1;
      // 注释 / doctype / 处理指令：不增不减。
      if (isMarkup || name == null) continue;
      // void 元素的结束标签（`</br>`）解析器直接忽略 —— 这里也不许减，否则
      // 一堆 `</br>` 会把深度压到 0，让真正深的输入蒙混过关。
      if (closing) {
        if (!_voidTags.contains(name) && depth > 0) depth--;
        continue;
      }
      if (_voidTags.contains(name)) continue;
      depth++;
      if (depth > max) max = depth;
    }
    return max;
  }

  /// 深度是否超过 [maxSafeDepth]（也就是「解析它就会卡 / 会爆栈」）。
  static bool exceedsLimit(String html) => maxNestingDepth(html) > maxSafeDepth;

  /// 把 HTML **当纯文本**抽出来：剥标签、解常见实体，**非递归、O(n)**。
  ///
  /// 用途是**降级**：深度超限的输入不再解析，而是把可见文字原样交给用户
  /// （见两个调用点）。所以只求两件事：
  ///
  /// 1. **绝不递归、绝不进 `package:html`** —— 否则降级路径自己就会爆栈，
  ///    那就等于没降级；
  /// 2. 块级标签的边界落成换行，让「一段接一段」的文字不至于糊成一整行。
  ///
  /// **不做安全清洗**：这里产出的是纯文本，安全由调用方负责（写侧直接进 Delta
  /// 的文本 op；读侧再转义一次）。实体解码只覆盖 `&amp;` `&lt;` `&gt;` `&quot;`
  /// `&apos;` `&nbsp;` 与数字引用 —— 这是个降级路径，漏掉的实体会原样出现在
  /// 文字里，不影响安全。
  static String plainText(String html) {
    final out = StringBuffer();
    var i = 0;
    final len = html.length;
    while (i < len) {
      final lt = html.indexOf('<', i);
      if (lt < 0) {
        _writeText(out, html.substring(i));
        break;
      }
      if (lt > i) _writeText(out, html.substring(i, lt));
      final (next, name, _, isMarkup) = _scanTag(html, lt, len);
      if (name == null) {
        // 不是标签（`a < b`）：把 `<` 原样留下。注释 / doctype 整段丢掉。
        if (!isMarkup) out.write('<');
      } else if (_blockTags.contains(name)) {
        out.write('\n');
      }
      i = next > lt ? next : lt + 1;
    }
    return _tidy(out.toString());
  }

  /// [plainText] 的**转义**版本：把 `<` `>` `&` 换成实体，保证返回值再被
  /// HTML 解析一遍时**不可能**重新变成标签。
  ///
  /// 两个调用方（写信页粘贴的降级、读信页渲染的降级）都会把结果交给一个会
  /// 解析 HTML 的下游，所以转义是必需的：不转义等于把拒绝服务换成了 XSS。
  static String plainTextEscaped(String html) {
    final text = plainText(html);
    if (text.trim().isEmpty) return '';
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  /// 解析 `html[start]`（必须指向 `<`）处的一个 `<...>` 结构。
  ///
  /// 返回 `(next, name, closing, isMarkup)`：
  ///
  /// - `next`：下一个待扫描位置（已越过整个结构）；
  /// - `name`：标签名（小写）；**不是标签**时为 `null`；
  /// - `closing`：是否结束标签；
  /// - `isMarkup`：注释 / doctype / 处理指令 / bogus comment —— 整段无深度影响，
  ///   且内容不该当正文（`name` 也是 null，用它与「裸 `<`」区分）。
  static (int, String?, bool, bool) _scanTag(String html, int start, int len) {
    var i = start + 1;
    if (i >= len) return (len, null, false, false);
    final first = html.codeUnitAt(i);

    // `<!-- 注释 -->`：按 tokenizer 的注释状态机找结束（含 `<!-->` /
    // `<!--->` / `--!>` 三种提前闭合）。
    if (first == _bang) {
      if (html.startsWith('<!--', start)) {
        final end = _commentEnd(html, start + 4);
        return (end > start ? end : start + 1, null, false, true);
      }
      // 其余 `<!…`（doctype / `<!x` / `[CDATA[` …）在 HTML 正文里一律落到
      // tokenizer 的 **bogus comment**：跳到**第一个 `>`**。
      //
      // 特别注意 `<![CDATA[`：它只在**外来内容（SVG / MathML）里**才是真
      // CDATA。正文里 `<!…` 走 bogus comment，`<![CDATA[<div><div>…` 的
      // 第一个 `>` 一过，后面的 `<div>` 全是**真元素** —— 跳到 `]]>` 会低估
      // 深度、放行一次爆栈（实测：守卫 0 层 → 解析 44 秒后 StackOverflowError）。
      final end = html.indexOf('>', i);
      return (end < 0 ? len : end + 1, null, false, true);
    }
    // `<?…`（`<?xml … ?>` 等）：与其余 `<!…` 一样是 tokenizer 的 **bogus
    // comment** —— 跳过到第一个 `>`，不是 XML 那样找 `?>`。
    if (first == _question) {
      final end = html.indexOf('>', i);
      return (end < 0 ? len : end + 1, null, false, true);
    }

    var closing = false;
    if (first == _slash) {
      closing = true;
      i++;
    }

    final nameStart = i;
    if (i < len && _isNameStart(html.codeUnitAt(i))) {
      i++;
      while (i < len && _isNameChar(html.codeUnitAt(i))) {
        i++;
      }
    }
    if (i == nameStart) {
      // `<` 后面不是标签名：这不是标签，`<` 当普通文字。
      return (start + 1, null, false, false);
    }
    final name = html.substring(nameStart, i).toLowerCase();

    // 扫到 `>` 为止；引号里的 `>` 不算结束（`<a title="a>b">`）。
    while (i < len) {
      final ch = html.codeUnitAt(i);
      if (ch == _doubleQuote || ch == _singleQuote) {
        final close = html.indexOf(String.fromCharCode(ch), i + 1);
        i = close < 0 ? len : close + 1;
        continue;
      }
      if (ch == _gt) {
        i++;
        break;
      }
      i++;
    }
    return (i, name, closing, false);
  }

  /// 注释结束位置：忠实复刻 `package:html` tokenizer 的
  /// commentStart / commentStartDash / comment / commentEndDash / commentEnd /
  /// commentEndBang 六个状态。返回**终止 `>` 之后**的下标；没有终止则返回 [s] 的长度。
  ///
  /// [start] 指向 `<!--` **之后**（状态机入口）；调用方保证 `s` 在该处确实以
  /// `<!--` 开头。
  ///
  /// 为什么值得逐态复刻：HTML 的注释有**提前闭合**写法（`<!-->`、`<!--->`、
  /// `--!>`），解析器认这些；只找 `-->` 的朴素实现会把「注释」一路吃到串尾，
  /// 于是注释后面的**真标签**在守卫这里全被吞掉 —— 深度数成 0，而解析器照样
  /// 把它们建成 DOM。这正是绕过路径的成因。
  ///
  /// 写成**迭代** + 显式状态变量而不是六个互递归方法：注释里的每个字符都要走
  /// 状态机，深嵌套输入动辄几十万字符，递归版会把栈按输入长度吃掉。
  static int _commentEnd(String s, int start) {
    final len = s.length;
    var i = start;
    var state = _commentStart;
    while (i < len) {
      final ch = s.codeUnitAt(i);
      if (state == _commentStart) {
        if (ch == _dash) {
          state = _commentStartDash;
        } else if (ch == _gt) {
          return i + 1; // `<!-->`
        } else {
          state = _comment;
        }
      } else if (state == _commentStartDash) {
        if (ch == _dash) {
          state = _commentEndState;
        } else if (ch == _gt) {
          return i + 1; // `<!--->`
        } else {
          state = _comment;
        }
      } else if (state == _comment) {
        if (ch == _dash) state = _commentEndDash;
        // 其余字符（含 NUL）留在 comment 状态。
      } else if (state == _commentEndDash) {
        if (ch == _dash) {
          state = _commentEndState;
        } else {
          state = _comment;
        }
      } else if (state == _commentEndState) {
        if (ch == _gt) {
          return i + 1; // `-->`
        } else if (ch == _bang) {
          state = _commentEndBang; // `--!` 之后还看一个字符
        } else if (ch != _dash) {
          state = _comment;
        }
        // ch == '-' → 留在 commentEnd（`--->` 里的中间那道 `-`）。
      } else {
        // _commentEndBang
        if (ch == _gt) {
          return i + 1; // `--!>`
        } else if (ch == _dash) {
          state = _commentEndDash;
        } else {
          state = _comment;
        }
      }
      i++;
    }
    return len;
  }

  /// 写一段**文本**（已确认不含标签）：解常见实体后追加。
  static void _writeText(StringBuffer out, String raw) {
    if (!raw.contains('&')) {
      out.write(raw);
      return;
    }
    out.write(
      raw.replaceAllMapped(_entity, (match) {
        final named = match.group(1);
        if (named != null) return _namedEntities[named] ?? match.group(0)!;
        final hex = match.group(2);
        final code = hex != null
            ? int.tryParse(hex, radix: 16)
            : int.tryParse(match.group(3)!);
        // 解不开或落在代理区 / 超出 Unicode 的引用原样保留，别造出坏字符。
        if (code == null || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
          return match.group(0)!;
        }
        return String.fromCharCode(code);
      }),
    );
  }

  /// 收尾：统一换行、去掉空行（HTML 排版缩进会制造一堆）、每行 trim。
  ///
  /// 段落之间**只留一个** `\n` —— 调用方按 `\n` 分段即可（读侧一段一个 `<p>`，
  /// 写侧一行一个段落）。
  static String _tidy(String text) {
    final kept = <String>[];
    for (final line in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      kept.add(trimmed);
    }
    return kept.join('\n');
  }

  /// HTML 里的 void 元素：只有开始标签、不可能有孩子，不增加嵌套深度。
  static const Set<String> _voidTags = <String>{
    'area', 'base', 'basefont', 'bgsound', 'br', 'col', 'embed', 'frame',
    'hr', 'img', 'input', 'keygen', 'link', 'meta', 'param', 'source',
    'track', 'wbr',
  };

  /// 边界要落成换行的标签（纯文本降级时用）。开 / 结束标签都算。
  static const Set<String> _blockTags = <String>{
    'address', 'article', 'aside', 'blockquote', 'br', 'center', 'dd', 'div',
    'dl', 'dt', 'fieldset', 'figcaption', 'figure', 'footer', 'form',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr', 'li', 'main', 'nav',
    'ol', 'p', 'pre', 'section', 'table', 'tbody', 'td', 'tfoot', 'th',
    'thead', 'tr', 'ul',
  };

  /// 实体解码的覆盖范围，见 [plainText] 的说明。
  static const Map<String, String> _namedEntities = <String, String>{
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
  };

  static final RegExp _entity = RegExp(
    r'&(?:([a-zA-Z][a-zA-Z0-9]*)|#[xX]([0-9a-fA-F]+)|#(\d+));',
  );

  // 注释状态机的六个状态（见 [_commentEnd]）。
  static const int _commentStart = 0;
  static const int _commentStartDash = 1;
  static const int _comment = 2;
  static const int _commentEndDash = 3;
  static const int _commentEndState = 4;
  static const int _commentEndBang = 5;

  static const int _bang = 0x21; // !
  static const int _question = 0x3F; // ?
  static const int _slash = 0x2F; // /
  static const int _gt = 0x3E; // >
  static const int _dash = 0x2D; // -
  static const int _doubleQuote = 0x22; // "
  static const int _singleQuote = 0x27; // '

  static bool _isNameStart(int c) =>
      (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

  static bool _isNameChar(int c) =>
      _isNameStart(c) ||
      (c >= 0x30 && c <= 0x39) ||
      c == 0x2D || // -
      c == 0x5F || // _
      c == 0x3A || // :
      c == 0x2E; // .
}
