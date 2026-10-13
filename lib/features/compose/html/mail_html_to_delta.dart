import 'package:flutter_quill_delta_from_html/flutter_quill_delta_from_html.dart';
import 'package:flutter_quill_delta_from_html/parser/default_html_to_ops.dart';
// `Delta` / `Operation` 由 `flutter_quill` 的 `quill_delta.dart` 透传
// （它就是 `dart_quill_delta` 的 re-export），与 `flutter_quill_delta_from_html`
// 依赖的是同一个包实例。走这条导入是为了让 `dart_quill_delta` 保持**传递依赖**
// —— 直接 import 它会触发 `depend_on_referenced_packages`，而它本来只随
// flutter_quill 进来。仓库里别的文件（`compose_screen.dart` /`paste_handler.dart`）
// 也是这么引的。
import 'package:flutter_quill/quill_delta.dart' show Delta, Operation;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../editor/text_styles.dart';
import 'email_html_sanitizer.dart';
import 'html_depth_guard.dart';

/// 把 HTML 变成 Quill Delta 的 `List<Map>`（`Document.fromJson` 直接能吃）。
///
/// **为什么不用 `HtmlToDelta.customBlocks` 处理表格**：它的实现里匹配成功后的
/// `continue` 跳的是内层循环（`html_to_delta.dart:132`），外层照旧处理同一个
/// 节点 —— 表格会被转换两次。改用**哨兵法**：先把每个 `<table>` 换成一个带
/// 私有区字符的标记段落，转换完再按标记切开、把嵌入塞回原位。
///
/// **两条不能破的约束**（破了编辑器会白屏，见 spec §0.2 第 6 条）：
/// 1. 块级嵌入独占一行 —— 前一个 op 以 `\n` 结尾，后一个 op 恰好是 `"\n"`；
/// 2. 文档以 `\n` 收尾且非空。
abstract final class MailHtmlToDelta {
  const MailHtmlToDelta._();

  /// 私有区字符（U+E000）。**哨兵必须「不可表示」**：正文里出现的同名码位
  /// 会被 [_stripSentinels] 在抽取之前清掉，所以标记只可能由我们自己的代码
  /// （[_extractTables]）产生 —— 「概率低」不等于「不可能」。
  static const String _sentinel = '';

  /// 标记里的数字位数上限。超过这个位数的一律**不当标记**、按正文处理：
  /// `int.parse` 面对 19 位以上的纯数字会抛
  /// `FormatException: Positive input exceeds the limit of integer`，
  /// 而这个入口吃的是剪贴板 / 别人发来的邮件 —— 一条畸形 HTML 就能崩掉写信页
  /// （`DocumentCodec.decode` 的 catch 包不住 `convert()`）。
  static const int _maxMarkerDigits = 9;

  static final RegExp _marker = RegExp('$_sentinel(\\d+)$_sentinel');

  /// 行内 `<code>` 的记号。**必须与 `_sentinel` 不同**：两者是两套独立的
  /// 抽取，混用的话「表格里的行内代码」会被当成表格标记切坏。
  ///
  /// 为什么行内代码也要走哨兵：`flutter_quill_delta_from_html` 把 `<code>`
  /// 与 `<pre>` 一视同仁（`node_ext.dart:67` 的 `isCodeBlock`），所以直接交给
  /// 它的话，插入一句 `用 <code>dart run</code> 跑` 要么变成代码块、要么
  /// 属性整个丢掉。哨兵法能把「行内的」与「块级的」分开。
  static const String _codeSentinel = '';

  static final RegExp _codeMarker =
      RegExp('$_codeSentinel(.*?)$_codeSentinel', dotAll: true);

  /// 引用块嵌套深度上限。**超过就拍平**（不再逐层拆），理由见
  /// [_splitQuoteLines] 的注释。取 64 的依据：探针分阶段计时确认，n 层
  /// `<blockquote><p>x</p></blockquote>` 的开销几乎全在 `safe.trim()` /
  /// `html_parser.parse`（都在 `package:html` 内部，逐层递归），且是超线性
  /// 的 —— n=1000 时全流程 132ms、2000 → 236ms、4000 → 840ms、8000 → 3.4s。
  /// 真实邮件的引用嵌套（Outlook / Gmail / Apple Mail 你回我我回你）顶多
  /// 十几层，64 已经远超合理值，再深的一律是敌意或损坏输入。
  static const int _maxQuoteDepth = 64;

  /// 不进 Delta 的属性。
  ///
  /// `color` / `background` / `size` **不在**这里（批 B 放开）。它们的值
  /// 由导入后那一步 `_normalizeSize` 收口 —— 上游给的 `font-size` 是
  /// 无界的（§0.2 第 18 条：`120px` → `'120'`），照单全收会让编辑器
  /// 渲染出 120px 的字。
  ///
  /// `font` / `line-height` / `direction` / `marker` 仍然丢：前两个我们的
  /// 调色盘里没有对应档位，收了就是「存得下但显示不出来」；后两个是
  /// 排版方向，收信侧不保证支持。
  ///
  /// `script`（上下标）**不在**这里：它由上游从 `<sup>` / `<sub>` 产出，
  /// 取值只有 `super` / `sub`（上游解析器**硬编码**这两个字符串，
  /// `node_processor.dart:43-44`；quill 那边另有一个 `ScriptAttributes`
  /// 枚举，取值恰好相同 —— 但两者是各自定义的，别当成同一处），
  /// 导出端也按值分支（不是拼标签名），
  /// 所以没有把不可信输入带进标签名的风险。
  ///
  /// `indent` 也**不在**这里：段落缩进与列表缩进共用这个属性名，
  /// 载体（`padding-left`）与值域（上游 `parseToIndent` 夹在 0..5）
  /// **说的是从 HTML 读行属性那条路**——这一段早先的写法把它写成了
  /// 「全链路不变量」，那是错的：
  ///
  /// * `<span style="padding-left:80px">` 会产出一个**行内（run 级）**
  ///   `{indent:5}` 的形状，编辑器不显示它（上游不把 `<span>` 上的
  ///   `indent` 当行属性）；
  /// * 本层**不做值域校验**，只是把属性交出去。
  ///
  /// 两者都不危险（最坏是画不出来），所以这里不收紧，只把话说准。
  static const Set<String> _droppedAttributes = <String>{
    'font', 'line-height', 'direction', 'marker',
  };

  /// 认得的块级嵌入类型。不在这里的嵌入（比如将来别处加的）会被
  /// [_normalize] 换成段落，免得编辑器找不到 builder 而白屏。
  static const Set<String> _knownEmbeds = <String>{'image', 'x-email-table'};

  /// 引用块的行尾标记。**写邮件页自己的约定**，不是 Quill 的属性。
  ///
  /// 值域只有 `true`。它挂在引用区每一行的**行尾 `\n`** 上（含把引用与正文
  /// 隔开的那条分隔线），于是「AI 只吃用户自己写的那部分」可以靠它切出边界
  /// —— 见 `compose_quote.dart`。为什么不在读的时候靠「找 `---` 那一行」：
  /// 用户可以在分隔线上打字、可以删掉它、也可以自己插一条分隔线，文本判据
  /// 三处都会认错；行属性只在**整行结构变化**时才丢，而那正是「不再是一条
  /// 独立的引用了」的情形。
  ///
  /// 它**不会**进收件人看到的 HTML：`DeltaToEmailHtml` 只读白名单里的属性，
  /// 未知属性一律忽略。也**不会**进剪贴板（复制走 `deltaToPlainText`）。
  ///
  /// flutter_quill 会原样保留未知属性 —— `Style.fromJson` 对 registry 里没有
  /// 的 key 走 `Attribute(key, AttributeScope.ignore, value)` 兜底，所以
  /// Delta JSON 存进草稿再读回来，标记还在。
  static const String quoteAttribute = 'mail-quote';

  /// 挂在**行尾那个 `\n`** 上的属性。判定「一段文字属于哪一行」全靠它们。
  ///
  /// **公开的**：`paste_handler.dart` 的 `_pasteLines` / `_lineAttrsOf` 用的是
  /// 同一套判据（它也要把「文字里混着换行」的 op 按这套属性拆成行）。早先那边
  /// 复了一份字面量并写着「两处改动必须同步」—— 那正是会漂的写法：将来这里
  /// 加一个行级属性、那边忘了改，粘贴那一路就会把它当成行内属性留在文字上，
  /// 行切错、格式错位，而且不报错。名单只有一份，就在这里。
  ///
  /// [quoteAttribute] 也在里面：它同样是「属于这一行」的属性，粘贴时若被当成
  /// 行内属性留在文字上，切出来的行就带不上标记（AI 边界随之错位）。
  static const Set<String> lineAttributes = <String>{
    'header', 'list', 'blockquote', 'code-block', 'align', 'direction', 'indent',
    quoteAttribute,
  };

  static const Set<String> _blockTags = <String>{
    'p', 'div', 'section', 'article', 'blockquote', 'pre', 'table', 'hr',
    'ul', 'ol', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  };

  /// 引用块里**自己占一行**的标签。
  static const Set<String> _quoteLineBlocks = <String>{
    'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre', 'li',
    'blockquote', 'table', 'hr', 'dt', 'dd',
  };

  /// 上游转换器**认得**的标签。
  ///
  /// 白名单之外的元素名，`resolveCurrentElement`（`html_to_operation.dart:33`）
  /// 的 `if` 链一个都不匹配，返回**空列表** —— 它的孩子于是从来不会被访问，
  /// **内容整段消失**。实测（probe57）：`<section>甲</section>`、
  /// `<figure><img …></figure>`、`<dl>`、`<mark>`、`<small>`、`<kbd>`、`<q>`、
  /// `<abbr>`、`<center>` 全都是空文档。
  ///
  /// 网页上右键复制出来的 HTML 里 `<section>`/`<article>`/`<figure>` 很常见，
  /// 所以不能只靠「Gmail 用 div」这个假设。
  static const Set<String> _upstreamTags = <String>{
    // 行内
    'br', 'p', 'a', 'img', 'video', 'span',
    'strong', 'b', 'em', 'i', 'u', 'ins', 's', 'del', 'sub', 'sup',
    // 块级
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'ul', 'ol', 'li', 'blockquote', 'pre', 'code', 'div',
    'table', 'tbody', 'thead', 'tfoot', 'tr', 'td',
    // 空元素：留着它自己就是全部内容（剥掉 = 整条线没了）。
    'hr',
  };

  /// 转换器递归深度上限（元素嵌套层数）。见 [_unwrapUnknownBlocks] 的说明。
  ///
  /// **实测这条封顶是活的，但只在很窄的一档里生效。** 它数的是**解析之后**
  /// 的元素深度（`_visitElement` 自上而下带 `depth`），而放行与否由 [convert]
  /// 开头的 [HtmlDepthGuard.exceedsLimit] 按**原始字符串**的 1000 层判定，
  /// 解析器还会补出 `<html>`/`<body>` 之类的脚手架。于是 `'<div>'*n` 这种
  /// 输入实测：
  ///
  /// - `n ≤ 197`：正常通路，内容保住；
  /// - `n = 198…998`：预检放行（原始深度 ≤ 999），但解析后的元素深度
  ///   （`html > body > n 个 div > p` ≈ `n + 3`）越过 200 —— **内容整棵丢光**，
  ///   只落回一个换行；
  /// - `n ≥ 999`：预检就拦下了，走 [_plainTextDocument] 降级，正文反而保住。
  ///
  /// `n ≥ 999` **比 `n = 500` 的结果更好**这件事看着很怪，但它恰好是当下各道
  /// 守卫阈值不齐（200 vs 1000）的产物。调这个数之前先读
  /// `mail_html_to_delta_test.dart` 那条把 800 层嵌 `div` 当 fuzz 样本的用例：
  /// 它只断言「不抛」，所以**改 200 不会让它变红**，别指望它兜底。
  static const int _maxNestingDepth = 200;

  /// 只是**一层壳**的容器：它们的孩子才是一行，自己不是。
  ///
  /// `ul`/`ol`/`dl` 也在这里：列表本身不占一行，它的每个条目才占一行。
  static const Set<String> _quoteLineContainers = <String>{
    'div', 'section', 'article', 'center', 'font', 'ul', 'ol', 'dl',
  };

  static List<Map<String, dynamic>> convert(String html) {
    // 第一件事是**解析前的深度预检**，必须在 [_safeSubset]（也就是
    // `EmailHtmlSanitizer.toSafeSubset`）之前 —— 理由见 [html_depth_guard.dart]
    // 与该方法自己的注释：解析 / 序列化全是递归的，太深的输入会先卡住几十秒
    // 再抛 `StackOverflowError`（`Error` 不是 `Exception`，`catch` 兜不住）。
    if (HtmlDepthGuard.exceedsLimit(html)) return _plainTextDocument(html);

    final safe = _safeSubset(html);
    if (safe.trim().isEmpty) return _minimalDocument();

    final document = html_parser.parse(safe);
    _unwrapUnknownBlocks(document);
    // 顺序要紧：**先**把正文里可能出现的哨兵码位清掉，**再**由我们自己的
    // 代码（[_extractTables] / [_markInlineCode]）插入真标记。反过来的话，
    // 清正文时会把刚插进去的标记一起清掉。
    _stripSentinels(document);
    _splitQuoteLines(document);
    _markDividers(document);
    final extracted = _extractTables(document);
    _markInlineCode(document);

    // 构造参数：我们只传 `isBlockValidator`。
    // （`blackNodesList` **没传** —— 上游默认 `const []`，这个仓库里没有
    // 任何地方给它赋值。）
    //
    // 上游用 `isBlockValidator(nextNode.localName)` 决定「当前节点的操作之
    // 后要不要补一个 `\n`」（上游 `html_to_delta.dart:145`）。实测
    // `<p>甲</p><p>乙</p>`：不传时两个顶层块粘成 `{"甲乙\n"}`，传了才拆成
    // `{"甲\n"}` / `{"乙\n"}` —— 这是它实际管的事。
    //
    // 「纯容器不产生多余空行」在这个仓库里**不是靠单个参数**完成的：
    // * 上游 `resolveCurrentElement` **不认识**的壳（`section` / `article` /
    //   `center` / `font` / `figure` …，见 [_upstreamTags]：里面有 `div`、没
    //   这几个）会返回空操作列表、**内容整段消失** —— 靠
    //   [_unwrapUnknownBlocks] 在转换**之前**把它们剥掉才保住内容
    //   （实测裸 `HtmlToDelta().convert('<section>甲</section>')` 输出空，
    //   经 [convert] 才读出「甲」）。
    // * `div` 在 [_upstreamTags] 里，会被留着交给上游 `divToOp`；它自己不
    //   额外占一行。
    //
    // `replaceNormalNewLinesToBr` 保持默认 `false`（没传）。但**实测把它设成
    // `true` 输出完全一样**：上游在读到这个开关之前已经 `replaceAll('\n', '')`
    // 把输入里的换行全删了（上游 `html_to_delta.dart:110-113`），到这一步没有
    // 换行可转。所以「默认 false」是事实，「防止多出空行」不是它在这里起的作用。
    final delta = HtmlToDelta(
      htmlToOperations: _QuoteLineOperations(),
      isBlockValidator: (name) => _blockTags.contains(name),
    ).convert(document.outerHtml);

    final ops = _restoreInlineCode(_restoreTables(delta.toJson(), extracted));
    return _normalizeSize(_normalize(_splitLines(ops)));
  }

  /// 把 `size` 夹到 [kFontSizes] 的四个档位；认不出就**删掉这条属性**
  /// （宁可不设字号，也不要让一个 `'120'` 进文档）。
  ///
  /// 键名先过 [_stringKeyed]：上游塞进来的 `size` 值可能是 `'small'`
  /// （`html_utils.dart` 对 `≤10px` 与 `0.75em` 都给这个），
  /// `clampFontSize` 对它返回 null → 属性被删，正是想要的结果。
  static List<Map<String, dynamic>> _normalizeSize(List<Map<String, dynamic>> ops) {
    for (final op in ops) {
      if (op['attributes'] is! Map) continue;
      final attrs = <String, dynamic>{
        for (final e in _stringKeyed(op['attributes'] as Map).entries)
          e.key: e.value,
      };
      if (!attrs.containsKey('size')) continue;
      final raw = attrs['size'];
      final clamped = raw is String ? clampFontSize(raw) : null;
      if (clamped == null) {
        attrs.remove('size');
      } else {
        attrs['size'] = clamped;
      }
      if (attrs.isEmpty) {
        op.remove('attributes');
      } else {
        op['attributes'] = attrs;
      }
    }
    return ops;
  }

  /// 把「换行混在文字里」的 op 拆成 Quill 的规范形状。
  ///
  /// 上游转换器（以及 [_restoreTables] / [_restoreInlineCode]）产出的 op 长这样：
  /// `{"insert":"甲\n乙\n"}` —— 一个 op 里既有文字又有行尾。Quill 的
  /// `Document.fromJson` 能装进这种 op，但**它落库之后再读出来就不是这个样子了**：
  /// `Document.toDelta()` 永远按行拆开（`{"insert":"甲"}`、`{"insert":"\n"}`）。
  /// 两种形状混用会让下游（导出器、斜杠菜单、工具栏）里凡是「遇到
  /// `insert == "\n"` 才算一行结束」的地方静默错判 —— 导出器的表现就是
  /// 「段落标签丢了、只剩一串 `<br>`」。
  ///
  /// 所以这里**当场拆成规范形状**：文字是一段，`\n` 是独立的一段。
  /// 行属性（`header` / `list` / `blockquote` / `code-block` / `align`）跟着
  /// 那个 `\n` 走，行内属性（粗斜下划、链接、代码）留在文字上。
  static List<Map<String, dynamic>> _splitLines(List<Map<String, dynamic>> ops) {
    final out = <Map<String, dynamic>>[];
    for (final op in ops) {
      final data = op['insert'];
      if (data is! String || !data.contains('\n')) {
        out.add(op);
        continue;
      }
      final attrs = op['attributes'] is Map
          ? _stringKeyed(op['attributes'] as Map)
          : const <String, dynamic>{};
      final inline = <String, dynamic>{
        for (final entry in attrs.entries)
          if (!lineAttributes.contains(entry.key)) entry.key: entry.value,
      };
      final line = <String, dynamic>{
        for (final entry in attrs.entries)
          if (lineAttributes.contains(entry.key)) entry.key: entry.value,
      };
      var rest = data;
      while (true) {
        final at = rest.indexOf('\n');
        if (at < 0) break;
        final text = rest.substring(0, at);
        if (text.isNotEmpty) {
          out.add(<String, dynamic>{
            'insert': text,
            if (inline.isNotEmpty) 'attributes': inline,
          });
        }
        out.add(<String, dynamic>{
          'insert': '\n',
          if (line.isNotEmpty) 'attributes': line,
        });
        rest = rest.substring(at + 1);
      }
      if (rest.isNotEmpty) {
        out.add(<String, dynamic>{
          'insert': rest,
          if (inline.isNotEmpty) 'attributes': inline,
        });
      }
    }
    return out;
  }

  /// 把上游不认识的容器**剥掉**，只留孩子。
  ///
  /// 不能留着它们 —— 上游遇到白名单外的元素名会返回空操作列表，连孩子都不看
  /// （见 [_upstreamTags]），内容会整段消失。剥掉之后孩子直接挂在原位置，
  /// 文字与结构都保住，只是丢掉了那层壳的语义（`<section>`/`<article>` 本来
  /// 也只是语义标签，邮件里表达不出区别）。
  ///
  /// 从**最外层开始**剥：外层剥掉后内层元素仍在树上（引用没失效），继续剥就行。
  ///
  /// **顺带做深度封顶**：超过 [_maxNestingDepth] 层的元素**整棵换成空
  /// `<span>`**（子树丢弃）。这一步是**兜底**：上游
  /// `flutter_quill_delta_from_html` 的 `processNode` 是递归的，深度由输入
  /// 决定。代价：超深输入里被剪掉的那部分内容丢失 —— 但现实里 200 层嵌套的
  /// 邮件本就不存在。
  ///
  /// **注意这道封顶救不了 [convert] 开头那次 `toSafeSubset`**：它跑在**解析
  /// 回来之后**，而崩溃（`package:html` 的解析与序列化、以及 `processNode`）
  /// 在它之前就已经发生；阈值取多少都一样。真正挡在前面的是 [convert] 里的
  /// [HtmlDepthGuard.exceedsLimit] 预检（解析前的字符串扫描）。这道封顶留着
  /// 是对「预检没算准、但输入仍浅到能解析完」那类输入的二次保护。
  ///
  /// 而「预检放行、这道封顶却触发」的那一档**实测确实存在**：`'<div>'*n`
  /// 在 `n = 198…998` 时内容会整棵丢光（见 [_maxNestingDepth] 的注释）。
  /// 也就是说它不是死代码，但它的代价落在一段真实输入上，而不是「现实里
  /// 不存在的 200 层」。
  ///
  /// 用**自上而下带深度**的遍历（而不是对每个元素往上数父链）：后者是
  /// O(n·深度)，在这类深嵌套输入上会退化成 O(n²)，正是要治的病。
  static void _unwrapUnknownBlocks(dom.Document document) =>
      _visitChildren(document, 1);

  static void _visitChildren(dom.Node parent, int childDepth) {
    for (final child in parent.nodes.toList()) {
      if (child is! dom.Element) continue;
      _visitElement(child, childDepth);
    }
  }

  static void _visitElement(dom.Element element, int depth) {
    final tag = element.localName?.toLowerCase();
    if (depth > _maxNestingDepth) {
      // 超深：整棵换成空壳，子树丢弃（见上面的说明）。
      element.replaceWith(dom.Element.tag('span'));
      return;
    }
    // `<html>`/`<head>`/`<body>` 是解析器自己补的脚手架，**别动**：
    // 它们本来就会被 `.convert()` 重新解析一遍，而把它们剥掉会让内容直接
    // 挂在 `Document` 上 —— 之后 `element.parent`（只认 Element）就返回
    // null，凡是用它当「有没有爹」的判断都会静默失效。
    if (tag == null || _upstreamTags.contains(tag)) {
      _visitChildren(element, depth + 1);
      return;
    }
    if (tag == 'html' || tag == 'head' || tag == 'body') {
      _visitChildren(element, depth + 1);
      return;
    }
    // 上游不认识的壳：剥掉，孩子提到这一层继续走（新的兄弟节点不在外层
    // 快照里，所以在这里显式递归，保证每个节点只访问一次）。
    final parent = element.parentNode;
    if (parent == null) return;
    final moved = element.nodes.toList();
    _unwrap(element);
    for (final node in moved) {
      if (node is dom.Element) _visitElement(node, depth);
    }
  }

  /// 用孩子的孩子**原地替换**这个元素。
  static void _unwrap(dom.Element element) {
    final parent = element.parentNode;
    if (parent == null) return;
    for (final child in element.nodes.toList()) {
      // `insertBefore` 会先把 child 从原父节点摘下来（`NodeList._setParent`），
      // 所以这里不需要手动 remove，顺序也不会乱。
      parent.insertBefore(child, element);
    }
    element.remove();
  }

  /// 把 `<hr>` 换成一段 `---`。
  ///
  /// 邮件安全子集里表达分隔线只有 `<hr>` 一条路，但 Delta 里没有「分隔线」
  /// 这个属性（Quill 也没有），所以正文里用**一段只有 `---` 的文字**来表达，
  /// 导出时再落回 `<hr>`（`delta_to_email_html` 里那一条）。这样往返不丢。
  static void _markDividers(dom.Document document) {
    for (final rule in document.querySelectorAll('hr').toList()) {
      rule.replaceWith(dom.Element.tag('p')..text = '---');
    }
  }

  /// 把嵌套的 `<blockquote>` 拆成「一行一个 blockquote」。
  ///
  /// 上游 `blockquoteToOp`（`default_html_to_ops.dart:349`）对引用块的每个孩子
  /// 调的是 `processNode`，而 `processNode` **不认识 `<p>`/`<div>`** —— 它只负责
  /// 行内标签，遇到块级孩子就继续往下递归取文字，不补换行。于是
  /// `<blockquote><p>甲</p><p>乙</p></blockquote>` 转出来是
  /// `[{"insert":"甲乙"},{"insert":"\n","attributes":{"blockquote":true}}]`
  /// —— **两段被压成一行**（探针 probe50/54 实测；Gmail / Apple Mail /
  /// Outlook 的回复引用全是这个形状，用户看到的是一整段挤在一起的原信）。
  ///
  /// 修法不碰上游：在转换前把每个引用块按「行」拆成若干个**只有一个块**的
  /// 兄弟引用块。单个孩子走 `processNode` 时文字会被原样取出，
  /// `blockquoteToOp` 再补上那个带 `blockquote` 属性的 `\n` —— 一行一个行尾，
  /// 分段就回来了。
  ///
  /// **为什么要给深度封顶**：分阶段探针确认，深嵌套的耗时**几乎全在
  /// `package:html` 的递归序列化里**（`safe.trim()` 与 `html_parser.parse`
  /// 合计占掉 95% 以上），而且它是**超线性**的 —— n 层
  /// `<blockquote><p>x</p></blockquote>`：n=1000 全流程 132ms、2000 → 236ms、
  /// 4000 → 840ms、8000 → 3.4s。原 [_splitQuoteLines] / [_splitQuote] 里那两处
  /// `querySelectorAll('blockquote')` 全量扫描只是把小常数叠大（改成一次性
  /// 遍历后 8000 层从 8.6s 降到 3.4s）。这不是栈溢出（不会崩），但粘贴 /
  /// 引用一封陌生人的深嵌套 HTML 会**冻住写信页**。所以自上而下一次遍历、
  /// 深度带到阈值（[_maxQuoteDepth]）就**拍平降级**：这一层及更深的引用不再
  /// 逐层拆，原样交给上游转换器。**内容一个字不丢**（在
  /// [_maxNestingDepth] 这道硬上限之内；更深的输入由那道上限兜底丢弃），
  /// 代价是超深引用里的多个段落会被压回一行 —— 对「立刻能继续写信」来说
  /// 这个代价划算得多。
  static void _splitQuoteLines(dom.Document document) {
    _splitQuotesAt(document, 0);
  }

  /// 自上而下遍历，同时把真实嵌套深度带下去（每个节点只访问一次，O(n)）。
  static void _splitQuotesAt(dom.Node parent, int depth) {
    for (final child in parent.nodes.toList()) {
      if (child is! dom.Element) continue;
      if (child.localName == 'blockquote') {
        // 到顶了：拍平。见 [_maxQuoteDepth] / [_splitQuoteLines] 的说明。
        if (depth >= _maxQuoteDepth) continue;
        _splitQuote(child, depth);
      } else {
        _splitQuotesAt(child, depth);
      }
    }
  }

  /// 拆**一个**引用块。拆出来的新引用块里如果还套着引用块（网页的引用
  /// 外壳经常是 `<div><div>属性行</div><blockquote>…</blockquote></div>`），
  /// 当场再往下走一层 —— 外层的快照里没有这些新建的元素。
  static void _splitQuote(dom.Element quote, int depth) {
    // 用 `parentNode` 而不是 `parent`：后者只认 `Element`，挂在 `Document`
    // 上的引用块会被它判成「没有爹」而静默跳过。
    final parent = quote.parentNode;
    if (parent == null) return;
    final lines = _quoteLines(quote);
    if (lines.isEmpty) {
      // 空的引用块（`<blockquote></blockquote>`、只有 `<br>` 的）不占一行 ——
      // 留着只会在正文里多出一个空的引用块。
      quote.remove();
      return;
    }
    for (final line in lines) {
      final one = dom.Element.tag('blockquote');
      for (final node in line) {
        one.append(node);
      }
      parent.insertBefore(one, quote);
      // 只走进这一行里的嵌套引用（它们都是新建 `one` 的后代），
      // 且每个节点只访问一次 —— 不再用 `querySelectorAll('blockquote')`
      // 全量扫描后代（那正是 O(n²) 的来源之一）。
      _splitQuotesAt(one, depth + 1);
    }
    quote.remove();
  }

  /// 一个引用块的**内容**按行拆开，每行是一组节点。
  ///
  /// 三种孩子要区别对待：
  /// - **壳**（`div`/`section`/`ul`/`ol`…）：自己不是一行，拆开看它的孩子；
  /// - **独占一行的块**（`p`/`h1-6`/`pre`/`li`/嵌套引用…）：它自己就是一行；
  /// - **其它**（行内标签、裸文字）：跟在上一行后面。
  ///
  /// `<br>` 是显式的换行，把当前行打住。
  static List<List<dom.Node>> _quoteLines(dom.Node parent) {
    final lines = <List<dom.Node>>[];
    var run = <dom.Node>[];

    void flush() {
      if (!_hasContent(run)) {
        run = <dom.Node>[];
        return;
      }
      lines.add(run);
      run = <dom.Node>[];
    }

    // `nodes` 是活的列表，而下面会把孩子搬走 —— 先快照。
    for (final child in parent.nodes.toList()) {
      if (child is dom.Element) {
        final tag = child.localName?.toLowerCase() ?? '';
        if (_quoteLineContainers.contains(tag)) {
          flush();
          lines.addAll(_quoteLines(child));
          continue;
        }
        if (_quoteLineBlocks.contains(tag)) {
          flush();
          lines.add(<dom.Node>[child]);
          continue;
        }
        if (tag == 'br') {
          flush();
          continue;
        }
      }
      run.add(child);
    }
    flush();
    return lines;
  }

  /// 这一组节点里有没有**看得见的东西**。
  ///
  /// 用来滤掉只由空白文字节点或 `<br>` 组成的「行」：它们在正文里是空行，
  /// 而空行在引用块里没法表达（Delta 的空行是 `\n`，会被读成「这一行结束」，
  /// 而它前面没有内容）。
  ///
  /// **不能对任何 Element 无条件返回 true**：注释节点（`<!--x-->`、
  /// Outlook 条件注释、`<!--StartFragment-->`）在 `package:html` 里也是
  /// `Comment`，它的 `text` 是注释里的**文字**（非 null）—— 一律判真会让
  /// `<blockquote><!--x--></blockquote>` 产出一个空引用行。真实的「纯壳」
  /// 元素（`<span></span>`、只包着空白/`<br>` 的 `<div>`）同理，得继续下钻
  /// 看有没有可见文字。`<br>` 例外：它是显式换行，不是可见内容，但也不是
  /// 普通壳 —— 由 [_quoteLines] 单独处理（打住当前行），这里只看它「没文字」。
  static bool _hasContent(List<dom.Node> nodes) {
    for (final node in nodes) {
      if (node is dom.Comment) continue;
      if (node is dom.Element) {
        if (node.localName == 'br') continue;
        if (_elementHasVisibleContent(node)) return true;
        continue;
      }
      if (node.text != null && node.text!.trim().isNotEmpty) return true;
    }
    return false;
  }

  /// 这个元素里有没有**看得见的文字**（或图片这类可见元素）。
  ///
  /// 递归下钻：`<span><b></b></span>` 这一类的空壳都会被判成「没内容」。
  /// 认得的可见空元素（`img`）算有内容。先用 `package:html` 自己的
  /// `element.text`（它本身也是递归下钻，因此比逐层手写更快，且会在有文字时
  /// 立刻短路），只有它空的时候才手动往 `<img>` 这类无文字但可见的元素里看。
  static bool _elementHasVisibleContent(dom.Element element) {
    if (element.text.trim().isNotEmpty) return true;
    final tag = element.localName?.toLowerCase();
    if (tag == 'img') return true;
    for (final child in element.nodes) {
      if (child is dom.Comment) continue;
      if (child is dom.Element) {
        if (child.localName == 'br') continue;
        if (_elementHasVisibleContent(child)) return true;
        continue;
      }
      if (child.text != null && child.text!.trim().isNotEmpty) return true;
    }
    return false;
  }

  /// 把每个 `<table>` 换成标记段落，返回按顺序抽出来的表格 HTML。
  ///
  /// 空的表格（没有任何单元格）**不算数** —— 一个空网格插进编辑器只会让
  /// 用户困惑，而且 `outerHtml` 里只有 `<table></table>`，也算不出行列。
  static List<String> _extractTables(dom.Document document) {
    final tables = <String>[];
    for (final element in document.querySelectorAll('table').toList()) {
      if (element.querySelectorAll('td, th').isEmpty) {
        element.remove();
        continue;
      }
      tables.add(element.outerHtml);
      final marker = dom.Element.tag('p')
        ..text = '$_sentinel${tables.length - 1}$_sentinel';
      element.replaceWith(marker);
    }
    return tables;
  }

  /// 把**不在 `<pre>` 里**的 `<code>` 换成一个记号文本。
  ///
  /// `<pre><code>…</code></pre>` 是代码块，交给转换器就好 —— 只处理行内的那种。
  static void _markInlineCode(dom.Document document) {
    final inline = document.querySelectorAll('code').where((element) {
      var parent = element.parent;
      while (parent != null) {
        if (parent.localName == 'pre') return false;
        parent = parent.parent;
      }
      return true;
    }).toList();

    for (final element in inline) {
      // 用「记号 + 原文 + 记号」的文本节点替换整个 `<code>`：
      // 外层标签留着，行内其它格式（粗体等）不受影响；被包住的文字一字不丢。
      element.replaceWith(
        dom.Text('$_codeSentinel${element.text}$_codeSentinel'),
      );
    }
  }

  /// 把正文里**真实出现**的两个哨兵码位（U+E000 / U+E002）清掉。
  ///
  /// 哨兵必须是**不可表示**的，不能只靠「出现概率低」：一封陌生人的邮件里
  /// 带上 `&#xE000;0&#xE000;` 就被当成表格标记，同一张表格的 HTML 会被复制
  /// 两份插进正文中间；没有表格时哨兵字面量还会原样进 Delta、落库、发给
  /// 收件人（行内代码的 U+E002 同理）。
  ///
  /// 清洗只在**文本节点**上做（属性值不动，免得多出难查的副作用），并且
  /// 只在 [_extractTables] / [_markInlineCode] **之前**跑一次 —— 那时树里
  /// 还只有用户的原文，我们自己的标记尚未插入，所以真标记不会被误伤。
  static void _stripSentinels(dom.Document document) {
    void clean(dom.Node parent) {
      for (final child in parent.nodes.toList()) {
        if (child is dom.Comment) continue; // 注释不是正文
        if (child is dom.Text) {
          // `dom.Text.text` 声明为 `String?`，但 Text 实例上恒非 null；
          // 这里直接用它（analyzer 知道这一点）。
          child.replaceWith(dom.Text(_withoutSentinels(child.text)));
        } else {
          clean(child);
        }
      }
    }

    clean(document);
  }

  /// 去掉正文里出现的哨兵码位。
  static String _withoutSentinels(String value) {
    if (!value.contains(_sentinel) && !value.contains(_codeSentinel)) {
      return value;
    }
    return value
        .replaceAll(_sentinel, '')
        .replaceAll(_codeSentinel, '');
  }

  /// 把行内代码的记号还原成带 `code: true` 的运行段。
  ///
  /// 与表格同一套路：记号可能落在某个 op 的中间（转换器会把相邻文本合并），
  /// 所以要把一个 op 切成多段。
  static List<Map<String, dynamic>> _restoreInlineCode(
    List<Map<String, dynamic>> ops,
  ) {
    final result = <Map<String, dynamic>>[];
    for (final op in ops) {
      final data = op['insert'];
      if (data is! String || !data.contains(_codeSentinel)) {
        result.add(op);
        continue;
      }
      final base = op['attributes'] is Map
          ? _stringKeyed(op['attributes'] as Map)
          : const <String, dynamic>{};
      var rest = data;
      while (true) {
        final match = _codeMarker.firstMatch(rest);
        if (match == null) break;
        final before = rest.substring(0, match.start);
        if (before.isNotEmpty) {
          result.add(<String, dynamic>{
            'insert': before,
            if (base.isNotEmpty) 'attributes': base,
          });
        }
        result.add(<String, dynamic>{
          'insert': match.group(1) ?? '',
          'attributes': <String, dynamic>{...base, 'code': true},
        });
        rest = rest.substring(match.end);
      }
      if (rest.isNotEmpty) {
        result.add(<String, dynamic>{
          'insert': rest,
          if (base.isNotEmpty) 'attributes': base,
        });
      }
    }
    return result;
  }

  static Map<String, dynamic> _stringKeyed(Map attrs) =>
      attrs.map((k, v) => MapEntry(k.toString(), v));

  /// 按标记把嵌入塞回原位。
  ///
  /// 标记可能落在某个 op 的中间（转换器会把相邻段落合并），所以这里要能
  /// 把一个 op **切成三段**。切出来的每一段都**继承原 op 的 attributes** ——
  /// 跟 [_restoreInlineCode] 的做法一样：标记落在加粗/链接的运行段中间时，
  /// 两侧的文字不该丢掉格式（否则 `<b>甲<table>…</table>乙</b>` 里的 `乙`
  /// 会掉出加粗）。
  static List<Map<String, dynamic>> _restoreTables(
    List<dynamic> ops,
    List<String> tables,
  ) {
    if (tables.isEmpty) {
      return ops.map((o) => Map<String, dynamic>.from(o as Map)).toList();
    }
    final result = <Map<String, dynamic>>[];
    for (final raw in ops) {
      final op = Map<String, dynamic>.from(raw as Map);
      final data = op['insert'];
      if (data is! String || !_marker.hasMatch(data)) {
        result.add(op);
        continue;
      }
      final base = op['attributes'] is Map
          ? _stringKeyed(op['attributes'] as Map)
          : const <String, dynamic>{};
      var rest = data;
      while (true) {
        final match = _marker.firstMatch(rest);
        if (match == null) break;
        final before = rest.substring(0, match.start);
        if (before.isNotEmpty) {
          result.add(<String, dynamic>{
            'insert': before,
            if (base.isNotEmpty) 'attributes': base,
          });
        }
        final digits = match.group(1)!;
        final index = digits.length > _maxMarkerDigits
            ? null
            : int.tryParse(digits);
        if (index != null && index < tables.length) {
          result.add(<String, dynamic>{
            'insert': <String, dynamic>{'x-email-table': tables[index]},
          });
        } else {
          // 越界 / 位数超限：我们自己的标记索引一定落在 `0..tables.length-1`
          // 且位数很短，走到这里说明它**不是**我们插的标记。**原样留字**，
          // 不静默吞掉 —— 这正是修复前「越界索引把内容整段丢掉」的那条路径。
          // （正文里的真哨兵已在 [_stripSentinels] 里清掉，这里只是防御。）
          result.add(<String, dynamic>{
            'insert': match.group(0)!,
            if (base.isNotEmpty) 'attributes': base,
          });
        }
        rest = rest.substring(match.end);
      }
      if (rest.isNotEmpty) {
        result.add(<String, dynamic>{
          'insert': rest,
          if (base.isNotEmpty) 'attributes': base,
        });
      }
    }
    return result;
  }

  /// 属性过滤 + 块嵌入独占一行 + 收尾换行。三件事都在这里做，
  /// 因为它们是同一个不变量（「这份 Delta 必须能装进 Document」）的三面。
  static List<Map<String, dynamic>> _normalize(List<Map<String, dynamic>> ops) {
    final cleaned = <Map<String, dynamic>>[];
    for (final op in ops) {
      final insert = op['insert'];
      final attrs = op['attributes'];
      // 先过 [_guard]：认不出的嵌入（`<video>` 之类）会变成空字符串。
      final guarded = _guard(insert);
      // 空插入 + 空属性是纯噪声，**两支之前**统一剔掉：原来这条检查只在
      // `attrs is Map` 的分支里，于是 `{"insert":""}` 会漏网（`<video>` 经
      // `_guard` 变成 `{"insert":""}` 后落成编辑器里的空运行段）。
      // 注意 `{"insert":"", "attributes":{"code":true}}` **要留** —— 它是行内
      // 代码的开启记号，本身不带文字，属性非空所以不会被这一条剔掉。
      if (guarded == '' && (attrs is! Map || attrs.isEmpty)) {
        continue;
      }
      if (attrs is! Map) {
        cleaned.add(<String, dynamic>{'insert': guarded});
        continue;
      }
      final next = <String, dynamic>{};
      for (final entry in attrs.entries) {
        final key = entry.key.toString();
        if (_droppedAttributes.contains(key)) continue;
        // 危险协议在 sanitizer 里已经被改成 '#'，这里再兜一次：
        // 转换器可能从别处（比如 `style` 解析）造出 link 属性。
        if (key == 'link' && _isDangerousLink(entry.value)) continue;
        next[key] = entry.value;
      }
      // 属性被逐项过滤光之后又变回空插入（比如只剩被丢的 `line-height`）——
      // 同样按纯噪声处理。
      if (guarded == '' && next.isEmpty) continue;
      cleaned.add(<String, dynamic>{
        'insert': guarded,
        if (next.isNotEmpty) 'attributes': next,
      });
    }

    // 块级嵌入独占一行。
    final spaced = <Map<String, dynamic>>[];
    for (final op in cleaned) {
      if (!_isBlockEmbed(op)) {
        spaced.add(op);
        continue;
      }
      final previous = spaced.isEmpty ? null : spaced.last['insert'];
      final atLineStart =
          previous is String && previous.endsWith('\n') || previous == null;
      if (!atLineStart) spaced.add(<String, dynamic>{'insert': '\n'});
      spaced.add(op);
      spaced.add(<String, dynamic>{'insert': '\n'});
    }

    if (spaced.isEmpty) return _minimalDocument();
    _dropBlankLineAfterBlocks(spaced);
    _trimTrailingBlankLines(spaced);
    final last = spaced.last['insert'];
    if (last is Map || (last is String && !last.endsWith('\n'))) {
      spaced.add(<String, dynamic>{'insert': '\n'});
    }
    return spaced;
  }

  /// 认不出来的嵌入换成空字符串。
  ///
  /// 这一条是**防白屏**的：`QuillEditor` 遇到没有 builder 的嵌入类型会抛
  /// `UnimplementedError`，而错误 widget 又会引发第二个类型转换崩溃，
  /// 结果是整页空白。宁可丢一个元素，不能白屏。
  static Object _guard(Object? insert) {
    if (insert is! Map) return insert ?? '';
    final type = insert.keys.firstOrNull?.toString();
    if (type != null && _knownEmbeds.contains(type)) return insert;
    return '';
  }

  /// 块嵌入后面不留空段落。
  ///
  /// 表格是**哨兵法**抽出来的：原来的 `<table>` 位置上是一个标记 `<p>`，
  /// 上游按「这是个段落」给它补了一个行尾 `\n`。嵌入塞回原位之后那个 `\n`
  /// 就变成一个空段落 —— 每插一张表就在表后面多一行空白。用户没敲过那一行。
  ///
  /// 代价：**用户主动在表格后留的空行也会被吃掉**。两者在 Delta 里长得
  /// 一模一样（都是两个挨着的 `\n`），分不开。相比之下「每张表后面都多一个
  /// 空行」是每次都会发生、每次都得手动删的；而手写空行的位置本来也不在
  /// 表格正下方。选前者。
  static void _dropBlankLineAfterBlocks(List<Map<String, dynamic>> ops) {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < ops.length; i++) {
      final op = ops[i];
      if (i >= 2 &&
          _isBareNewline(op) &&
          _isBareNewline(ops[i - 1]) &&
          _isBlockEmbed(ops[i - 2])) {
        continue;
      }
      out.add(op);
    }
    ops
      ..clear()
      ..addAll(out);
  }

  /// 一个不带任何属性的换行 —— 也就是「一个空行」。
  static bool _isBareNewline(Map<String, dynamic> op) =>
      op['insert'] == '\n' && op['attributes'] == null;

  /// 末尾只留一个 `\n`。
  ///
  /// 上游 `divToOp` 在「`<div>` 里包着 `<p>`」时会补两次换行（`p` 自己收尾一次、
  /// `div` 见 `node.isParagraph` 又补一次，`default_html_to_ops.dart:225`）——
  /// 而 Word / Outlook / Gmail 复制出来的 HTML 恰好**全是**这个形状，于是每粘
  /// 一段就在文末多留一个空段落。用户按的是「粘到光标处」，不是「再空一行」。
  ///
  /// 中间的空行不动（那是用户有意留的段落间距），只削**末尾**。
  ///
  /// 「空行」的判定一律走 [_isBareNewline]（`insert == '\n'` **且**没有
  /// 属性）—— 只认 `insert` 会把**带属性的行尾**（`header` / `list` /
  /// `blockquote` 挂在 `\n` 上）也当成空行削掉：`<h1>标<table>…</table></h1>`
  /// 拆出来的 `{insert:'\n', attributes:{header:1}}` 就是被这里连着前一个
  /// 裸 `\n` 一起 removeLast 掉的，整条标题格式消失。
  static void _trimTrailingBlankLines(List<Map<String, dynamic>> ops) {
    while (ops.isNotEmpty) {
      final lastOp = ops.last;
      final last = lastOp['insert'];
      // 情形一：末尾空行堆在同一个 op 里（`"甲\n乙\n\n"`）。只在**无属性**
      // 的 op 上削，带属性的 op 里那个 `\n` 是行尾身份，不能动。
      if (last is String &&
          last.length >= 2 &&
          last.endsWith('\n\n') &&
          lastOp['attributes'] == null) {
        ops[ops.length - 1] = <String, dynamic>{
          ...lastOp,
          'insert': last.substring(0, last.length - 1),
        };
        continue;
      }
      // 情形二：末尾空行分在两个 op 里。**末尾那个必须是裸 `\n`**：块级嵌入
      // 后面那个 `\n` 是「独占一行」不变量的一部分，带属性的行尾也不能削。
      if (ops.length >= 2 && _isBareNewline(ops.last)) {
        final before = ops[ops.length - 2]['insert'];
        if (before is String && before.endsWith('\n')) {
          ops.removeLast();
          continue;
        }
      }
      break;
    }
  }

  static bool _isBlockEmbed(Map<String, dynamic> op) {
    final data = op['insert'];
    return data is Map && data['x-email-table'] != null;
  }

  static bool _isDangerousLink(Object? value) {
    if (value is! String) return true;
    final normalized = value.trim().toLowerCase().replaceAll(RegExp(r'\s'), '');
    return normalized.startsWith('javascript:') ||
        normalized.startsWith('vbscript:') ||
        normalized.startsWith('data:text/html');
  }

  static List<Map<String, dynamic>> _minimalDocument() =>
      <Map<String, dynamic>>[
        <String, dynamic>{'insert': '\n'},
      ];

  /// 净化。**只由 [convert] 在深度预检通过之后调用** —— 公开的
  /// `EmailHtmlSanitizer.toSafeSubset` 自己也有预检（它是对外 API，读信显示
  /// 通路也用它），但这里不能只靠它：
  ///
  /// 1. 它的预检是**降级**（退回纯文本），在编辑器这条路上我们要的是
  ///    把降级直接做成一份可编辑的文档（见 [_plainTextDocument]）；
  /// 2. [convert] 拿到的是「已经净化过」的字符串，按理不该再触发预检 ——
  ///    一旦触发就说明有 bug，那种「净化结果反而更深」的情况不该静默变成
  ///    一段纯文本，而该在测试里炸出来。
  static String _safeSubset(String html) => EmailHtmlSanitizer.toSafeSubset(html);

  /// 深度超限时的降级：把 HTML 当**纯文本**抽出来，产出一份普通段落文档。
  ///
  /// 为什么不直接给 [_minimalDocument]：用户粘的是一封（畸形 / 敌意的）
  /// 邮件，给他一份空白文档等于把内容全丢了 —— 他要的是「内容还在，只是
  /// 格式没了」。为什么不「按深度剪掉一半子树」：那会让用户拿到一封**少了
  /// 内容、而且看不出来少了**的引用，比整段降级纯文本更坏。
  ///
  /// 抽文本走 [HtmlDepthGuard.plainText]（非递归、O(n)）：降级路径自己若是
  /// 递归的就等于没降级。产物是每个非空行一个段落（`\n` 直接过
  /// [_splitLines]，落成 Quill 规范的形状）。
  static List<Map<String, dynamic>> _plainTextDocument(String html) {
    final text = HtmlDepthGuard.plainText(html);
    if (text.trim().isEmpty) return _minimalDocument();
    // 段落之间补一个 `\n`：`_splitLines` 把文字切成「一段文字 + 一个行尾」，
    // 末尾再由 [_normalize] 保证有收尾换行。
    return _normalize(_splitLines(<Map<String, dynamic>>[
      <String, dynamic>{'insert': '$text\n'},
    ]));
  }
}

/// 上游 `DefaultHtmlToOperations` 的**薄壳子类**，只改 `blockquoteToOp` /
/// `codeblockToOp` 两处：给它们的**直接孩子**也开 `addSpanAttrs: true`。
///
/// **为什么要有这个类**：这两处（`default_html_to_ops.dart:348-380`）调
/// `processNode(node, {}, delta, …)` 时**没传** `addSpanAttrs`，它默认
/// `false` —— 于是 `<span style="color:…">` 的 `style` 从头到尾没人读，
/// 引用行 / 代码行上的 `color` / `background` / `size` 一进这两个容器就被
/// 悄悄丢掉（导出端照常把它们写出去，所以是「发出去了、回不来」）。
/// 相邻的 `paragraphToOp` / `headerToOp` / `spanToOp` 都传了 `true`，
/// 唯独这两个容器漏了，这是批 B 放开颜色之后没走完的那条边。
///
/// **为什么不 fork 上游**：上游这两个方法各自还夹着「容器级的
/// blockAttributes（`{'blockquote': true}` / `{'code-block': true}`）」和它
/// 自己的 `delta.insert('\n', blockAttributes)` —— 自己重写一份就是把这段
/// 同步责任扛过来。子类只覆盖这两个 `blockXToOp`、**逐字照抄其余逻辑**，
/// 换的只是 `processNode` 的一个命名参数，其余（`resolveCurrentElement`
/// 的分派、`divToOp`、列表、表格……）全走上游原路。`onDetectLineheightCssVariable`
/// 一律传 `null`：本仓库构造 `HtmlToDelta` 时从来没传过这个变量，
/// 上游默认也是 null。
///
/// **这里加 `addSpanAttrs: true` 是安全的**（实测，见
/// `mail_html_to_delta_test.dart` 的「引用块 / 代码块行内颜色（addSpanAttrs
/// 的边）」组；prompt 里提示的「可能把 `align`/`direction`/`indent` 搬到文字
/// run 上」**没有发生**）：
///
/// - **不会把行级属性搬上文字**：`_splitQuoteLines` 把每个引用行装进一个
///   自己的 `<blockquote>`；在 `_quoteLines` 的切法下，那一行里放得下的
///   **块级**孩子最多一个（`p`/`h1-6`/`pre`/`li`/嵌套引用……各占一行，
///   其余行内标签与裸文字跟在它后面）。而 `processNode` 遇到**块级**元素
///   **根本不解析它的 `style`** —— 它只递标签名派生的 `bold`/`italic`… 往下
///   递归。所以 `p` 上的 `text-align` / `padding-left` 进不了 `spanAttributes`，
///   也就搬不到文字 run 上（实测：`<blockquote><p style="text-align:center;
///   padding-left:32px"><span style="color:#d93025">中</span></p></blockquote>`
///   的文字 run 只有 `{color}`）。
/// - **`<span>` 上的行级 CSS 本来就不该当行属性**：上游对**顶层** `<span>`
///   走 `spanToOp`，那里**主动** `styleAttributes.remove('align')`、
///   不做任何处理；行内 span 的这一档是 `processNode` 里那三行
///   `newAttributes.remove('align'/'direction'/'indent')`。两者都在说明
///   「行内元素不承载行属性」。所以这里即使把一个带 `padding-left` 的
///   `<span>` 的 `indent` 留在文字 run 上（实测确会：`<span style="padding-left:80px">`
///   在引用行里读出 `{indent:5}`），也和 `<p><span style="padding-left:80px">`
///   的既有行为一致（导入端 `_droppedAttributes` 的注释把这种形状称作
///   「编辑器不显示它」），**不是新引入的错位**。
/// - **导出端不消费 `indent`**：`DeltaToEmailHtml._openBlockFor` 对引用 / 代码
///   分支直接返回整块 opening 标签，`indent` 在那些行上**本来就不导出**，
///   所以「导入端把 indent 放到文字上」不会让「看得见、发不出去」的范围
///   扩大。
///
/// 一句话：它只让「引用 / 代码行里本来就写着的行内颜色/底色/字号」重新被
/// 读到，不改变任何行级属性的落点。
class _QuoteLineOperations extends DefaultHtmlToOperations {
  _QuoteLineOperations() : super(null);

  @override
  List<Operation> blockquoteToOp(dom.Element element) =>
      _lineToOp(element, const <String, dynamic>{'blockquote': true});

  @override
  List<Operation> codeblockToOp(dom.Element element) =>
      _lineToOp(element, const <String, dynamic>{'code-block': true});

  /// 与上游 `blockquoteToOp` / `codeblockToOp` 逐字同形，只多一个
  /// `addSpanAttrs: true`。`_splitQuoteLines` 保证这里的 `element` 只有
  /// **一个块级孩子**，所以「一个引用块 = 一行」的前提不受影响。
  static List<Operation> _lineToOp(
    dom.Element element,
    Map<String, dynamic> blockAttributes,
  ) {
    final delta = Delta();
    for (final node in element.nodes) {
      processNode(node, {}, delta, addSpanAttrs: true);
    }
    delta.insert('\n', blockAttributes);
    return delta.toList();
  }
}
