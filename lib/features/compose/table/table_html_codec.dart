import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'table_model.dart';

/// `MailTableModel` ⇄ `<table>` 的 HTML 字符串。
///
/// 表格块的 `data` 就是这段 HTML —— 服务端只收 HTML，编辑器内部也没必要
/// 再引入第二套表格表示法（spec §2.4）。
///
/// 输出限制在**邮件安全子集**里：只用 `<table>/<tr>/<td>/<th>`，只给内联
/// `border-collapse` / `width` / `padding` / `text-align` / `border`。
abstract final class TableHtmlCodec {
  const TableHtmlCodec._();

  static const String _tableStyle = 'border-collapse:collapse;width:100%';
  static const String _cellStyle =
      'border:1px solid #CCCCCC;padding:6px 8px;text-align:left';

  static String encode(MailTableModel table) {
    final buffer = StringBuffer()..write('<table style="$_tableStyle">');
    for (var r = 0; r < table.rowCount; r++) {
      buffer.write('<tr>');
      for (var c = 0; c < table.columnCount; c++) {
        final isHeader = table.hasHeaderRow && r == 0;
        final tag = isHeader ? 'th' : 'td';
        final weight = isHeader ? ';font-weight:700' : '';
        buffer
          ..write('<$tag style="$_cellStyle;width:${table.widths[c]}px$weight">')
          ..write(_escape(table.cellAt(r, c)))
          ..write('</$tag>');
      }
      buffer.write('</tr>');
    }
    buffer.write('</table>');
    return buffer.toString();
  }

  /// 解析。解析不出来（空表、没有单元格）时返回 null —— 调用方据此决定
  /// 「不插入表格块」。
  ///
  /// 会做两件规整：
  /// - `colspan`/`rowspan` 一律忽略（网格要真能编辑，合并单元格是另一套模型）；
  /// - 行列补齐成矩形，缺的格子填空串。
  ///
  /// 说明：模型构造也会补齐成矩形，这里是双保险 —— 不依赖模型的新行为，
  /// 即使哪天 `MailTableModel` 的补齐被拿掉，本方法仍然产出规则网格。
  static MailTableModel? decode(String html) {
    if (html.trim().isEmpty) return null;
    final document = html_parser.parse(html);
    final table = document.querySelector('table');
    if (table == null) return null;

    final rows = <List<String>>[];
    final headerFlags = <bool>[];
    // 列宽从**实际被保留的第一行**上读。注意不能用
    // `table.querySelector('tr')` 在循环外另取一次 —— 那是文档序第一行，
    // 可能正是 `cells.isEmpty` 被跳过的空 `<tr>`，宽度会全落回默认值。
    // 同一次遍历里记下来，避免二次查询与循环走偏。
    List<int?>? firstRowWidths;
    for (final tr in table.querySelectorAll('tr')) {
      final cells = <String>[];
      final widths = <int?>[];
      var hasHeaderCell = false;
      for (final cell in tr.children) {
        final tag = cell.localName?.toLowerCase();
        if (tag != 'td' && tag != 'th') continue;
        if (tag == 'th') hasHeaderCell = true;
        cells.add(_cellText(cell));
        widths.add(_widthOf(cell));
      }
      if (cells.isEmpty) continue;
      rows.add(cells);
      headerFlags.add(hasHeaderCell);
      firstRowWidths ??= widths;
    }
    if (rows.isEmpty) return null;

    final columnCount =
        rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    for (final row in rows) {
      while (row.length < columnCount) {
        row.add('');
      }
    }

    return MailTableModel(
      cells: rows,
      widths: List<int>.generate(
        columnCount,
        (c) => (c < (firstRowWidths?.length ?? 0)
                ? (firstRowWidths![c] ?? 120)
                : 120),
      ),
      hasHeaderRow: headerFlags.isNotEmpty && headerFlags.first,
    );
  }

  /// 单元格文本 —— 不能直接用 `Element.text`。
  ///
  /// `Element.text` 把所有后代的文本拼起来，`<br>` 与块级边界全丢：
  /// `<td>a<br>b</td>` 会变成 `ab`。`<br>` 是**语义**换行（就是用户按的
  /// 回车），不是格式噪音，必须保住。这里递归收集，按「段」拼接：语义换行
  /// 切段，最后每段 trim、折叠连续空段（至多留一个空行）、去掉首尾空段。
  ///
  /// 关键区分「语义换行」与「格式化换行」：
  /// - 源码文本节点里的换行/缩进只是 HTML 折叠空白，一律先压成单个空格，
  ///   于是 `<td>\n      甲\n    </td>` 得到 `甲`（缩进是噪音）；
  /// - `<br>` 每次**总是**切段（`a<br><br>b` 就是两个换行 → 一个空行）；
  /// - 块级元素边界**幂等地**切段（`<p>a</p><p>b</p>` 只产生一个换行，
  ///   相邻边界不叠加成空行）。
  static String _cellText(dom.Element cell) {
    final segments = <String>[];
    _collectText(cell, segments);
    final lines = segments.map((s) => s.trim()).toList();
    while (lines.isNotEmpty && lines.first.isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    // 折叠：连续空段最多留一段（即最多一个空行）。
    final collapsed = <String>[];
    for (final line in lines) {
      if (line.isEmpty && collapsed.isNotEmpty && collapsed.last.isEmpty) {
        continue;
      }
      collapsed.add(line);
    }
    return collapsed.join('\n');
  }

  /// 块级元素：它们的边界是「换行」语义（`<p>a</p><p>b</p>` → 两行）。
  static const Set<String> _blockTags = <String>{
    'p', 'div', 'li', 'ul', 'ol', 'tr', 'table', 'blockquote', 'pre',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'section', 'article', 'header',
    'footer', 'figure', 'figcaption', 'address', 'dl', 'dt', 'dd',
  };

  /// 递归收集文本，按语义换行切成段。
  static void _collectText(dom.Node node, List<String> segments) {
    for (final child in node.nodes) {
      if (child is dom.Text) {
        // 源码里的换行/连续空白是 HTML 折叠空白，压成单个空格；
        // 它只在「段内」算空白，由 [_cellText] 的 trim 处理。
        _appendSegment(segments, child.text.replaceAll(RegExp(r'\s+'), ' '));
        continue;
      }
      if (child is! dom.Element) continue;
      final tag = child.localName?.toLowerCase();
      if (tag == 'br') {
        _breakLine(segments);
        continue;
      }
      final isBlock = tag != null && _blockTags.contains(tag);
      if (isBlock) _blockBoundary(segments);
      _collectText(child, segments);
      if (isBlock) _blockBoundary(segments);
    }
  }

  static void _appendSegment(List<String> segments, String text) {
    if (segments.isEmpty) {
      segments.add(text);
    } else {
      segments[segments.length - 1] = segments.last + text;
    }
  }

  /// `<br>`：总是切段 —— 两个连续的 `<br>` 就得到一个空行。
  static void _breakLine(List<String> segments) => segments.add('');

  /// 块级元素边界：幂等切段 —— 已经在空段末尾就不再切，避免
  /// `<p>a</p><p>b</p>` 这种相邻边界多叠出一个空行。
  static void _blockBoundary(List<String> segments) {
    if (segments.isNotEmpty && segments.last.isEmpty) return;
    segments.add('');
  }

  /// 宽度取 `style="width:120px"` 或 `width="120"` 属性。
  ///
  /// `style` 里的匹配加**左边界** `(?<![-\w])`：否则 `width\s*:\s*(\d+)`
  /// 会把 `max-width:500px`/`min-width:80px`/`border-width:2px` 里的数字
  /// 当成列宽。单位只认 `px` 或无单位 —— `%` 是相对宽度，而模型只存 px，
  /// 存成 50px 会把「50%」悄悄改语义。数值超过 [_maxWidth] 视为垃圾不取。
  static const int _maxWidth = 10000;

  static int? _widthOf(dom.Element cell) {
    final style = cell.attributes['style'] ?? '';
    final match =
        RegExp(r'(?<![-\w])width\s*:\s*(\d+)(px)?(?![-\w%])').firstMatch(style);
    if (match != null) {
      final value = int.tryParse(match.group(1)!);
      if (value != null && value > 0 && value <= _maxWidth) return value;
      // 命中 width 但值不可用（0/超限）→ 不取，别回退到 `width` 属性上
      // 再猜一个别的数。
      return null;
    }
    final attribute = int.tryParse(cell.attributes['width'] ?? '');
    if (attribute != null && attribute > 0 && attribute <= _maxWidth) {
      return attribute;
    }
    return null;
  }

  /// 单元格文本是**用户输入**，尖括号必须转义 —— 否则 `a < b` 会把后面的
  /// 内容当成标签吞掉，表格直接散架。
  static String _escape(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}
