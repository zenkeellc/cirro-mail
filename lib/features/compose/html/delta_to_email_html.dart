import 'package:mail_app/features/compose/editor/text_styles.dart';

/// Quill Delta → 邮件安全 HTML。
abstract final class DeltaToEmailHtml {
  const DeltaToEmailHtml._();

  static const String _blockMargin = 'margin:0 0 12px 0';
  static const String _linkStyle = 'color:#1A73E8;text-decoration:underline';

  static const Map<int, String> _headerSizes = <int, String>{
    1: 'font-size:22px;font-weight:700',
    2: 'font-size:19px;font-weight:700',
    3: 'font-size:16px;font-weight:700',
  };

  /// 合法的对齐值。Quill 只会产出这四个；其余一律丢掉 —— 这个值是拼进
  /// `style` 属性的，不白名单就等于把属性值交给了不可信输入。
  static const Set<String> _aligns = <String>{
    'left',
    'center',
    'right',
    'justify',
  };

  static String convert(List<dynamic> delta) {
    if (delta.isEmpty) return '';
    // 先扫一遍再决定包不包 —— 不能边生成边决定（容器要包在最外面）。
    final usesColour = delta.any(_opUsesColour);
    final body = _renderOps(delta); // 现有的主体，原样不动
    // `body.isEmpty` 守卫：颜色只挂在没有文字的裸属性位上时（例如
    // `[{'insert':'','attributes':{'color':'#d93025'}}]`）正文会是空串，
    // 包出来的 `<div style="background:#ffffff"></div>` 是一层没有内容的壳。
    if (!usesColour || body.isEmpty) return body;
    return '$_whiteBackdropStart$body$_whiteBackdropEnd';
  }

  /// 白底容器的开关。
  ///
  /// 邮件客户端的深色模式会把「没指定背景色」的正文区域渲染成深色，
  /// 而我们调色盘里那十个颜色是按浅底挑的 —— 黑字在深底上、深蓝在深底上
  /// 都会糊。**包一层白底**就把这件事按住了。
  ///
  /// 但**只在真的用了颜色/高亮时才包**：
  /// 1. 不用颜色的邮件保持输出**逐字节不变**（不然所有人的发送内容都被改了，
  ///    而他们根本没碰过这个功能）；
  /// 2. 多一层 `div` 会让部分客户端的引用折叠（`_splitQuoteLines`）多一次
  ///    拆箱，能不加就不加。
  ///
  /// 这层容器**只导出、不往返**（收件人回复时它进不来，不会变成每个段落上
  /// 的一层背景）。**它的两道拦截都不叫「简写不在白名单」**：
  ///
  /// * 容器标签是 `<div>`。导入端的 `div` 由上游 `divToOp`
  ///   （`default_html_to_ops.dart:204`）处理：它把 `style` 解析进一个局部
  ///   `attributes` map，**再往下就没用过这个 map** —— 递归 `resolveCurrentElement`
  ///   后只做 `delta.insert(op.data, op.attributes)`（用的是**孩子**的属性），
  ///   自己的属性从头到尾没并进任何 op。所以 `<div>` 上的 `color` /
  ///   `background-color` / `font-size` / `padding-left` / `text-align` 一个都
  ///   读不出来（实测：上面这些属性放在 `<div>` 上，`MailHtmlToDelta.convert`
  ///   读回来都没有属性），而同样的属性放在 `<p>` / `<span>`（走 `paragraphToOp`
  ///   / `spanToOp`，它们会把自己的属性并进那处 `\n`）就能读出来。
  ///   —— 导出的容器正是因为用了 `<div>`，才没变成「每个段落带一层白底」。
  /// * 万一它以非 `<div>` 元素（`<span>` / `<p>`）形态经剪贴板回灌，才轮到
  ///   `EmailHtmlSanitizer.toSafeSubset`：`background` 简写不在白名单
  ///   （白名单是 `background-color`），会被整条削掉（实测
  ///   `<p style="background:#ffffff">` → `<p>`），而 `background-color`
  ///   会被原样留下。
  ///
  /// 用 `background` **简写**正是为了堵第二条路；第一条路由 `<div>` 自己堵。
  /// 这条契约由用例钉住（`compose_rich_text_test.dart` 的「容器只导出不往返」
  /// 对导出结果再跑一次 `toSafeSubset`，断言容器那层 `#ffffff` 被削掉；
  /// 把这里换成 `background-color` 它就会红）。**别把第一条归因成
  /// `HtmlToDelta.blackNodesList`** —— 本仓库构造 `HtmlToDelta` 时根本没传这个
  /// 参数（`mail_html_to_delta.dart:192` 只给了 `isBlockValidator`），
  /// 而且实测加上 `blackNodesList: ['div']` 也不改变结果：属性消失发生在
  /// `divToOp` 内部，与黑名单无关。
  static const String _whiteBackdropStart = '<div style="background:#ffffff">';
  static const String _whiteBackdropEnd = '</div>';

  /// 这一份 op 有没有用到颜色或高亮。**数字字号不算** ——
  /// 它不需要浅底（14px 的黑字放哪都看得清），包了反而白改输出。
  ///
  /// **`attrs['color']` 不能写成 `as String?`**：`as String?` 在碰到
  /// **非 String 且非 null** 的值时**会抛**（`as String?` 只容许 String 与
  /// null 两种，`42` 会抛 `_TypeError` —— 探针实测）。而 `convert` 拿到的
  /// 是**落库再读出来的 Delta**，属性值类型没有任何人保证，`as String?`
  /// 等于把一个「看一眼」的函数变成会崩整封邮件的地方。
  /// 所以一律先 `is String` 判过再传（判不过就是「没用颜色」，正是想要的）。
  ///
  /// 形参是 `Object?` 而不是具体类型：`delta.any(...)` 要的是
  /// `bool Function(dynamic)` —— `delta` 的元素是 `dynamic`。判据是「收进来
  /// 再判」，与 `convert` 里 `if (raw is! Map) continue;`、`_stringOf` 同一条
  /// 脏类型纪律。
  static bool _opUsesColour(Object? op) {
    if (op is! Map) return false;
    final attrs = op['attributes'];
    if (attrs is! Map) return false;
    final colour = attrs['color'];
    final background = attrs['background'];
    return (colour is String && safeHexColor(colour) != null) ||
        (background is String && safeHexColor(background) != null);
  }

  static String _renderOps(List<dynamic> delta) {
    if (delta.isEmpty) return '';
    final buffer = StringBuffer();
    final line = StringBuffer();
    var lineHasBlockEmbed = false;
    _OpenBlock? open;
    final lists = _ListWriter(buffer);

    /// 只收 `_OpenBlock`（blockquote / code-block），**不动列表**。
    /// 列表条目自己要开列表容器，不能顺手把它收掉 —— 见 list 分支。
    void closeBlock() {
      final tail = open;
      if (tail != null) buffer.write(tail.closing);
      open = null;
    }

    void closeContainer() {
      // 列表容器也要在这里收干净 —— 它和 blockquote/code-block 一样是
      // 「跨多行的容器」，离开时必须闭合，否则整篇 HTML 都是错的。
      lists.close();
      closeBlock();
    }

    void flush(Map<String, dynamic>? attrs) {
      final html = line.toString();
      final isBlock = lineHasBlockEmbed;
      line.clear();
      lineHasBlockEmbed = false;

      if (isBlock) {
        closeContainer();
        buffer.write(html);
        return;
      }

      // 列表交给 _ListWriter：它的开/关由**嵌套深度**驱动，而且开一层时
      // 父级那个 `<li>` 要**搁着不关**（嵌套列表得写在父级 `<li>` 里）。
      // 这套 _OpenBlock 的单开单关模型表达不了这种「延迟关闭」。
      final list = attrs?['list'];
      if (list == 'bullet' || list == 'ordered') {
        closeBlock();
        lists.item(list!, _indentOf(attrs), html);
        return;
      }
      // 走到这里就不再是列表了 —— 把列表容器收掉，后面的段落才不会被
      // 包进 <ul> 里。
      lists.close();

      // 分隔线：正文里它是**一段只有 `---` 的文字**（Delta 里没有「分隔线」
      // 这个属性，Quill 也没有），收件人那边该看到一条线。这对形状是
      // `MailHtmlToDelta._markDividers` 与斜杠菜单的「分隔线」条目约定的，
      // 两头都要认。
      if (html == '---' && _openBlockFor(attrs).key == null) {
        closeContainer();
        buffer.write('<hr style="$_blockMargin;border:none;'
            'border-top:1px solid #DDDDDD">');
        return;
      }

      final next = _openBlockFor(attrs);
      final current = open;
      // 还在同一个容器里：行与行之间的分隔符得由容器给（引用用 <br>、
      // 代码块用真换行、列表不需要）。
      final same = current != null && current.key == next.key;
      if (!same) {
        closeContainer();
        if (next.key != null) {
          buffer.write(next.opening);
          open = next;
        }
      }
      final active = open;
      if (same && active != null) {
        buffer.write('${active.separator}$html');
      } else {
        buffer.write(active == null ? _wrapParagraph(html, attrs) : html);
      }
    }

    for (final raw in delta) {
      if (raw is! Map) continue; // 脏数据跳过，绝不抛
      final op = raw;
      final attrs = op['attributes'] is Map
          ? _stringKeyed(op['attributes'] as Map)
          : null;
      final data = op['insert'];

      if (data is Map) {
        final rendered = _renderEmbed(data);
        if (rendered.block) lineHasBlockEmbed = true;
        line.write(rendered.html);
        continue;
      }

      final text = data is String ? data : '';
      if (text == '\n') {
        flush(attrs);
        continue;
      }

      // **一个 op 里可以有多个 `\n`** —— `Document.toDelta()` 会把相邻的
      // 同属性文本合并（`{"insert":"甲\n乙\n"}`），而那是本导出器要面对的
      // **常态**：它拿到的就是 `DocumentCodec.encode` 存下来再读出来的 Delta。
      // 在 Quill 的文档树里 `\n` 永远表示「这一行结束」，所以这里必须逐个
      // 把它当成行尾去 `flush`，而不是拼成 `<br>`：
      // 拼 `<br>` 的话「两个段落」会导出成「一个段落里夹一个 `<br>`」，
      // 收件人看到的是一段，而编辑器里明明是两个段落。
      final parts = text.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) flush(attrs);
        if (parts[i].isEmpty) continue;
        line.write(_renderInline(parts[i], attrs));
      }
    }
    if (line.isNotEmpty) flush(null);
    closeContainer();
    return buffer.toString();
  }

  static Map<String, dynamic> _stringKeyed(Map attrs) =>
      attrs.map((k, v) => MapEntry(k.toString(), v));

  /// 取一个属性值当字符串；不是 `String`（含 null）就给 null。
  ///
  /// **别用 `attrs['x'] as String?`** —— 非 null 不是 String 时 `as` 会抛
  /// `_TypeError`（实测 `42 as String?` 就抛），而 `attrs` 是从存下来的
  /// Delta 里读的、值可能是任何东西。这里要的是「认不出就当没有」。
  static String? _stringOf(Object? value) => value is String ? value : null;

  /// 行内属性的嵌套顺序（spec §4.1）。**从里往外**包，所以下面这个列表
  /// 是「最内层 → 最外层」：
  ///
  /// ```
  /// <code> <span color> <span bg> <span font-size>
  ///   <s> <u> <em> <strong> <sup>/<sub> <a>
  /// ```
  ///
  /// 顺序本身唯一的目的就是**可预测** —— 同一份格式两次导出必须同一个结果
  /// （spec §4.1 原话）。`<code>` 最里、颜色/背景/字号三个 span 居中、
  /// `<a>` 最外这三者的相对位置是 spec §4.1 钉死的。
  ///
  /// **注意：§4.1 那条箭头列表与它自己给的技术理由相抵**，以理由为准 ——
  /// 那条理由要求三个 `<span>` 在四个语义标签**以里**（`<sup>/<sub>` 的垂直
  /// 对齐要相对最终的 `font-size` 计算，更接近浏览器 / `fwfh` 的实际解析
  /// 路径），也就是本文件这一版。读者手上的 spec 若是旧版，箭头列表可能还
  /// 停在另一种排法。
  ///
  /// 四个语义标签（`<strong>`/`<em>`/`<u>`/`<s>`）的相对次序**是任选的**，
  /// 唯一的要求是**定死**（可预测）。选中这一种要付的代价是：外层带
  /// `text-decoration` 时内层的 `<u>`/`<s>` 会被吃掉（`<a>` 最外就会这样），
  /// 这个取舍由用例 `'嵌套顺序：code 最里、a 最外'` 连上面整条链一起钉住。
  ///
  /// 为什么 `code` 最里：就是 spec §4.1 定的次序，且与 `<span>` 那一档的理由
  /// 同向 —— `monospace` 与文字颜色/底色的作用对象都是**叶子文字**，谁在外
  /// 只影响继承来源，不需要靠「外层盖掉内层」来解释。
  /// 为什么 `a` 最外：`<a>` 的 `text-decoration:underline` 会把内层
  /// `<u>` 吃掉，套在里面就等于白设。
  static String _renderInline(String text, Object? attrs) {
    var html = _escape(text);
    if (attrs is! Map) return html;
    if (attrs['code'] == true) html = '<code>$html</code>';
    // 颜色 / 背景 / 字号取「按类型取值」而不是 `as String?`：`attrs` 从存下来
    // 的 Delta 里读，值可能是 42 / true / List 之类的任何东西，而
    // `42 as String?` 会抛 `_TypeError` —— 那会把整封邮件的导出带崩（本函数
    // 的契约是纯函数、绝不抛，与 `convert` 开头 `if (raw is! Map) continue;` 同一条）。
    // 形状不对或不是档位的值一律当没有，交由 `safeHexColor`/`fontSizeCss` 返回 null。
    final colour = safeHexColor(_stringOf(attrs['color']));
    if (colour != null) html = '<span style="color:$colour">$html</span>';
    final bg = safeHexColor(_stringOf(attrs['background']));
    if (bg != null) html = '<span style="background-color:$bg">$html</span>';
    final size = fontSizeCss(_stringOf(attrs['size']));
    if (size != null) html = '<span style="font-size:$size">$html</span>';
    if (attrs['strike'] == true) html = '<s>$html</s>';
    if (attrs['underline'] == true) html = '<u>$html</u>';
    if (attrs['italic'] == true) html = '<em>$html</em>';
    if (attrs['bold'] == true) html = '<strong>$html</strong>';
    // 上下标的取值只有 `super` / `sub`（上游解析器硬编码这两个字符串，
    // `node_processor.dart:43-44`；quill 的 `ScriptAttributes` 枚举另有一份
    // 相同取值，别把两处当成同一处），
    // **按值分支而不是拼标签名** —— 拼的话这个值就是不可信输入，而它落进
    // 的是标签名。与 `_aligns` 同一条规矩。
    //
    // 这里只看得见**行内 run** 上的 `script`。挂在行尾 `\n` 上的 `script`
    // （行级属性位）不产标签、直接丢 —— 与 `header`/`list` 那些走的是另一条
    // 路径（`flush` → `_wrapParagraph`/`_openBlockFor`，那里没有行内属性这一说）。
    // 实测上游与本仓库的编辑器都产不出那个形状（`formatSelection` 从不给裸
    // `\n` 设 script），所以是记录一条不可达路径，不是待修的缺口。
    if (attrs['script'] == 'super') html = '<sup>$html</sup>';
    if (attrs['script'] == 'sub') html = '<sub>$html</sub>';
    final link = attrs['link'];
    // 导入端（`MailHtmlToDelta._normalize` 的 `_isDangerousLink`）也有一道，
    // 这里是导出端的兜底 —— 两边判据必须一致。危险协议不生成 `link`（文字照常
    // 输出）：这个函数只是丢格式，不是造链接。
    if (link is String && link.isNotEmpty && !_isDangerousLink(link)) {
      html = '<a href="${_escapeAttribute(link)}" style="$_linkStyle">$html</a>';
    }
    return html;
  }

  static bool _isDangerousLink(String value) {
    final normalized = value.trim().toLowerCase().replaceAll(RegExp(r'\s'), '');
    return normalized.startsWith('javascript:') ||
        normalized.startsWith('vbscript:') ||
        normalized.startsWith('data:text/html');
  }

  static _RenderedEmbed _renderEmbed(Map data) {
    final image = data['image'];
    if (image is String && image.isNotEmpty) {
      return _RenderedEmbed(
        '<img src="${_escapeAttribute(image)}" alt="" style="max-width:100%;height:auto">',
        block: false,
      );
    }
    final table = data['x-email-table'];
    // 表格 HTML 由导入端（`MailHtmlToDelta` 经 `EmailHtmlSanitizer.toSafeSubset`）
    // 与 `TableHtmlCodec.encode` 保证已净化，这里原样直出；不要在这里再跑一次
    // sanitizer，它会削掉表格自己的 `border-collapse`/`padding` 样式。
    if (table is String) return _RenderedEmbed(table, block: true);
    return const _RenderedEmbed('', block: false);
  }

  static String _wrapParagraph(String html, Map<String, dynamic>? attrs) {
    final header = attrs?['header'];
    final align = attrs?['align'];
    final alignStyle =
        align is String && _aligns.contains(align) ? ';text-align:$align' : '';
    // 缩进排在 `text-align` **前面**：`_filterStyle` 是逐条过滤、顺序无关，
    // 但固定顺序让「同一份格式两次导出同一个结果」这条能一句话说清。
    final indentStyle = _paragraphIndent(attrs);
    final body = html.isEmpty ? '<br>' : html;
    if (header is int && _headerSizes.containsKey(header)) {
      return '<h$header style="$_blockMargin$indentStyle;'
          '${_headerSizes[header]}$alignStyle">$body</h$header>';
    }
    if (header is int && header > 3) {
      return '<p style="$_blockMargin$indentStyle;font-weight:700$alignStyle">'
          '$body</p>';
    }
    return '<p style="$_blockMargin$indentStyle$alignStyle">$body</p>';
  }

  /// 段落缩进的 `style` 片段（含前导分号），没有缩进时是空串。
  ///
  /// **像素必须是 16 的整数倍**：上游 `parseToIndent`（`indent_parser.dart:19-27`）
  /// 是 `px / 16` 四舍五入，16px = 1 级、32px = 2 级。这与列表那条**历史**
  /// 公式（已被删除的列表老公式 `12 + indent * 24`，见 `21fe260` 起列表改用
  /// 容器嵌套）**不是一回事**，别顺手复用 —— 36px 会读回 2 级。
  static String _paragraphIndent(Map<String, dynamic>? attrs) {
    final indent = attrs?['indent'];
    if (indent is! int || indent <= 0) return '';
    final clamped = indent > 5 ? 5 : indent;
    return ';padding-left:${clamped * 16}px';
  }

  /// 引用块 / 代码块行的 `opening` 是**整块**的标签（`<blockquote …>` /
  /// `<pre …>`，边框与内边距都写死在里面），所以行属性里的 `indent` 在这里
  /// **不被采用**：`flush` 走到这两个分支时直接把 `opening` 写出去，
  /// **不经过 [_wrapParagraph]** —— 那 16px 的 `padding-left` 是在
  /// [_wrapParagraph] 里拼的，在这条路上没有落脚的地方。
  ///
  /// **这是有意为之，不是漏写。** 这是一处已知限制：编辑器里
  /// `indentSelection` 对引用行是生效的、也画得出来，于是存在「看得见、
  /// 发不出去」的缩进 —— 工具栏的缩进按钮落在引用行上时不会有收件人可见
  /// 的效果。
  ///
  /// **原因就是上面那句结构事实本身**，别把它归到「导入端也读不出来」
  /// 之类的理由上：早先这里的措辞写的是「两个方向都丢」，并拿
  /// 实测 `MailHtmlToDelta.convert('<blockquote style="padding-left:28px">q</blockquote>')`
  /// 读不出 `indent`（`padding-left:80px` 同样读不出）当依据。那句实测
  /// **本身没错**（导入端确实不从 `<blockquote>` / `<pre>` **自己**的
  /// `style` 上取行属性），但它不是这里不采用 `indent` 的原因 —— 这里不
  /// 采用纯粹是「这两个分支不经过 [_wrapParagraph]」。把它当理由会导出
  /// 一个错误结论：好像导入端哪天学会读这个属性，导出端就会自动跟上。
  /// 不会 —— 得把这两个分支也送去拼 `padding-left` 才行，那是另一件事。
  static _OpenBlock _openBlockFor(Map<String, dynamic>? attrs) {
    if (attrs?['blockquote'] == true) {
      return const _OpenBlock(
        key: 'blockquote',
        opening: '<blockquote style="$_blockMargin;border-left:2px solid #CCCCCC;padding-left:12px">',
        closing: '</blockquote>',
        separator: '<br>',
      );
    }
    if (attrs?['code-block'] == true) {
      return const _OpenBlock(
        key: 'code-block',
        opening: '<pre style="$_blockMargin;white-space:pre-wrap;font-family:monospace">',
        closing: '</pre>',
        separator: '\n',
      );
    }
    return const _OpenBlock(key: null, opening: '', closing: '', separator: '');
  }

  static String _escape(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  static String _escapeAttribute(String raw) => raw
      // `&` 必须第一个替换，否则会把后面刚生成的实体再转一遍。
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

class _RenderedEmbed {
  const _RenderedEmbed(this.html, {required this.block});
  final String html;
  final bool block;
}

class _OpenBlock {
  const _OpenBlock({
    required this.key,
    required this.opening,
    required this.closing,
    required this.separator,
  });

  final String? key;
  final String opening;
  final String closing;
  final String separator;
}

/// 列表容器的写入器：**嵌套由容器嵌套深度表达**。
///
/// 为什么不能沿用「平铺 `<ul>` + `<li style="padding-left:…">`」那套：
/// 上游 `listToOp`（`default_html_to_ops.dart:260`）的 `indent` **只从嵌套
/// 深度推**，`<li>` 自己的 `padding-left` 它读都不读。实测
/// `<ul><li>甲</li><li style="padding-left:32px">乙</li></ul>` 出来的乙
/// **没有** `indent`；只有真正的 `<ul><li>甲<ul><li>乙</li></ul></li></ul>`
/// 才给出 `indent:1`。所以 1 级缩进在 HTML 里没有别的表达方式。
class _ListWriter {
  _ListWriter(this._out);

  final StringBuffer _out;
  final List<_ListLevel> _levels = <_ListLevel>[];

  /// 外层容器（整篇的第一层列表）留出整段的上下间距。
  static const String _outerStyle = 'margin:0 0 12px 0;padding-left:24px';

  /// 内层容器：自己的 `margin` 收成 0（间距只由最外层给），
  /// `padding-left` 只是左缩进的视觉值 —— **层级由嵌套深度决定**，这个
  /// 24 写多少都不影响回读出来的 `indent`。
  static const String _nestedStyle = 'margin:0;padding-left:24px';

  /// 写一个列表条目。[level] 是 Delta 的 `indent`（0 起）。
  void item(String listType, int level, String html) {
    final tag = listType == 'ordered' ? 'ol' : 'ul';
    // 跳级收敛：一次最多深一层。Delta 里 `0 → 2` 这种跳级在 HTML 里表达
    // 不出来（上游按嵌套深度计数），导出时收敛成「深一层」。见 Task A1 的
    // 往返用例「跳级（0 → 2）收敛成深一层」。
    final target = (level + 1).clamp(1, _levels.length + 1);
    while (_levels.length > target) {
      _closeLevel();
    }
    // 同层换标签（无序紧接着有序）：**只有最外层能另起一个容器**。
    // 深度 ≥ 2 的另起不行 —— 那个新容器会落在父级 `<li>` 里面，
    // `package:html` 重新解析时把整棵子树丢掉，条目**无声消失**
    // （实测：`bullet(1) 子` 之后接 `ordered(1) 序`，回读时「序」没了）。
    // 所以深度 ≥ 2 一律沿用当前层的标签：条目与缩进都保住，
    // 只损失「这一条是编号还是圆点」这一点。
    // `_levels.length == 1` 这个守卫不能省：第一条列表条目时 `_levels`
    // 还是空的（`target` 也是 1），直接取 `_levels.last` 会抛。
    if (target == 1 && _levels.length == 1 && _levels.last.tag != tag) {
      _closeLevel();
    }
    while (_levels.length < target) {
      _openLevel(tag);
    }
    _closeItem();
    _out.write('<li>${html.isEmpty ? '<br>' : html}');
    _levels.last.itemOpen = true;
  }

  /// 开一层新列表。**父级那个 `<li>` 刻意不关** —— 嵌套列表必须写在当前
  /// `<li>` 里面；写成兄弟 `<ul>`（先关 `</li>` 再开）会得到非法的嵌套，
  /// `package:html` 重新解析时把新容器整棵丢掉，回读时条目**无声消失**。
  void _openLevel(String tag) {
    _out.write('<$tag style="${_levels.isEmpty ? _outerStyle : _nestedStyle}">');
    _levels.add(_ListLevel(tag));
  }

  /// 关一层：先关它自己的 `<li>` 与结束标签，**再补上父级那个被搁着的
  /// `</li>`**（对应 [_openLevel] 里没关的那一个）。漏掉后一步会得到悬空的
  /// `<li>`，`package:html` 会替你补，补的位置不对整段结构就错了。
  void _closeLevel() {
    _closeItem();
    _out.write('</${_levels.removeLast().tag}>');
    _closeItem();
  }

  void _closeItem() {
    if (_levels.isEmpty) return;
    final top = _levels.last;
    if (top.itemOpen) {
      _out.write('</li>');
      top.itemOpen = false;
    }
  }

  /// 收干净（离开列表、或整篇结束）。**幂等** —— `flush` 每次切容器都会调。
  void close() {
    while (_levels.isNotEmpty) {
      _closeLevel();
    }
  }
}

class _ListLevel {
  _ListLevel(this.tag);
  final String tag;
  bool itemOpen = false;
}

/// 列表条目的缩进级别（夹到 0..5，与上游 `parseToIndent` 的上限一致）。
///
/// **只在列表上下文里有意义** —— 段落缩进的像素换算是另一套
/// （见 Task A2 的 `_paragraphIndent`）：上游 `parseToIndent` 是 `px / 16`，
/// 而列表这里根本不用像素表达层级。
int _indentOf(Map<String, dynamic>? attrs) {
  final indent = attrs?['indent'];
  if (indent is! int || indent <= 0) return 0;
  return indent > 5 ? 5 : indent;
}
