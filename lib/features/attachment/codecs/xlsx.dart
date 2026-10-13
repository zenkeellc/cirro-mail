import 'package:xml/xml.dart';

import 'ooxml.dart';

/// 工作簿里的一个单元格。
///
/// **值一律是字符串**。日期、数字、布尔在 OOXML 里都是「原始值 + 格式」，
/// 而预览要显示的是**格式化之后**的样子（`47628` → `2025-05-01`）。与其在
/// 模型里留一个 `dynamic` 让渲染层去猜，不如在解析时就把格式应用掉 ——
/// 反正解析器已经读过 `styles.xml` 了。
class SheetCell {
  const SheetCell(this.text, {this.isNumber = false});

  final String text;

  /// 数字（含日期序列号）—— 渲染时可以右对齐。
  final bool isNumber;
}

/// 一行：**稀疏**的（列号 → 单元格）。
///
/// xlsx 里一行常常只有几个格子（`<row>` 里只写有内容的 `<c>`），而它们的
/// `r` 属性直接给出列号。用稀疏结构就不用为「A 列有、Z 列有、中间全空」
/// 造 25 个空对象，渲染时按 `columns` 补齐即可。
class SheetRow {
  const SheetRow(this.index, this.cells);

  /// 1 起的行号（`<row r="3">`）。
  final int index;

  /// 列号（0 起）→ 单元格。
  final Map<int, SheetCell> cells;
}

class Sheet {
  const Sheet({
    required this.name,
    required this.rows,
    required this.columns,
    this.truncated = false,
  });

  final String name;
  final List<SheetRow> rows;

  /// 最宽那一行的列数（**格子本身占几列**，不考虑合并）。
  final int columns;

  /// 这张表**本身**被裁过（行或列撞上了 [XlsxCodec.maxRows] /
  /// [XlsxCodec.maxColumns]）。
  ///
  /// 和 [Workbook.truncated] 是两件事：那个说的是「有表被整个丢掉了」，
  /// 这个说的是「这张表在这儿但少了后面一截」。裁掉的那部分行数通常很大
  /// （一张几万行的导出表），用户需要知道看到的是不是全部，所以两者都要。
  final bool truncated;

  bool get isEmpty => rows.isEmpty;
}

/// xlsx 的解析结果。
///
/// [truncated] 是「有整张表被丢掉了」（超过 [XlsxCodec.maxSheets]，或者
/// 那张表压根读不出来）。单张表内部被裁另见 [Sheet.truncated]。
class Workbook {
  const Workbook({required this.sheets, required this.truncated});

  final List<Sheet> sheets;
  final bool truncated;
}

/// `.xlsx` → [Workbook]。
///
/// ## 日期序列号是这里最容易翻车的地方
///
/// xlsx 里的日期**不是一个类型**，而是一个数字加一个格式：`2025-05-01` 存成
/// `45778`，然后靠 `styles.xml` 里那条 `numFmtId=14`（内建的 `m/d/yy`）说
/// 「请按日期显示」。不做这一步，日期列就会显示成一串五位数 —— 这是所有
/// 自己做 xlsx 预览的人都会踩的一脚。
///
/// 换算规则也有两个坑：
/// 1. **基准是 1899-12-30**，不是 1900-01-01。Excel 为了兼容 Lotus 1-2-3 把
///    1900 当成闰年（2 月 29 日存在），于是序列号 60 对应那个不存在的日子，
///    而 61 之后才对得上。用 1899-12-30 做基准，恰好把 1900-03-01 之后的
///    全部对齐（这是 Excel 自己的做法）。
/// 2. **序列号 60 及之前**在 1899-12-30 基准下会**差一天**。那一档是
///    1900 年 2 月以前的老日期，实际文件里几乎不存在，所以不特殊处理 ——
///    但要在测试里钉住这个已知偏差，免得以后有人当 bug 改。
///
/// 纯函数：吃字节，吐模型，不 import `dart:io`、不 import widget。
abstract final class XlsxCodec {
  const XlsxCodec._();

  /// 单张表最多保留多少行 / 列。与 CSV 那一侧取同一组数（见 `csv.dart`）。
  static const int maxRows = 5000;
  static const int maxColumns = 100;

  /// 最多解几张表。一份工作簿有几十个 sheet 是常事，但一屏只能看一张。
  static const int maxSheets = 20;

  static ParseResult<Workbook> parse(List<int> bytes) {
    final opened = Ooxml.open(bytes);
    if (opened is ParseFailed<OoxmlPackage>) {
      return ParseFailed<Workbook>(opened.reason, opened.detail);
    }
    final package = (opened as ParseOk<OoxmlPackage>).value;

    final workbookPath = package.relationshipTarget(
          '_rels/.rels',
          typeSuffix: '/officeDocument',
        ) ??
        'xl/workbook.xml';

    final workbookXml = package.xml(workbookPath);
    if (workbookXml is ParseFailed<XmlDocument>) {
      return ParseFailed<Workbook>(workbookXml.reason, workbookXml.detail);
    }
    final root = (workbookXml as ParseOk<XmlDocument>).value.rootElement;

    // `workbook.xml` 的**目录**才是 worksheet 相对路径的基准。
    final workbookDir = workbookPath.contains('/')
        ? workbookPath.substring(0, workbookPath.lastIndexOf('/'))
        : '';
    final relsPath = workbookDir.isEmpty
        ? '_rels/workbook.xml.rels'
        : '$workbookDir/_rels/${workbookPath.split('/').last}.rels';

    final sharedStrings = _sharedStrings(package);
    final dateStyles = _dateStyles(package);

    final sheetsNode = _child(root, 'sheets');
    if (sheetsNode == null) {
      return ParseResult.fail(ParseFailure.missingPart, 'sheets');
    }

    // sheet 的 `r:id` → 包内绝对路径。
    //
    // 基准是 **workbook.xml 所在的那个目录**（`xl/`），不是 rels 文件所在的
    // `xl/_rels/` —— 把这一步做对，后面就不用再拼一次（拼两次会得到
    // `xl/xl/worksheets/...`，而且那种路径读不到时**不会报错**，
    // 只会显示成一张空表）。
    final targets = _relationshipMap(package, relsPath, workbookDir);

    final sheets = <Sheet>[];
    var truncated = false;
    var sequence = 0;
    for (final node in sheetsNode.childElements) {
      if (node.name.local != 'sheet') continue;
      sequence++;
      if (sheets.length >= maxSheets) {
        truncated = true;
        break;
      }
      final name = node.getAttribute('name') ?? 'Sheet$sequence';
      final relId = node.getAttribute('id', namespaceUri: _r) ??
          node.getAttribute('id');
      // rels 里没有就退回约定路径 —— 绝大多数导出工具用的就是它。
      final path = (relId == null ? null : targets[relId]) ??
          _join(workbookDir, 'worksheets/sheet$sequence.xml');

      final sheetXml = package.xml(path);
      // 一张表读不出来不该让整个工作簿报废：跳过它，别的表照显示。
      final document = sheetXml.valueOrNull;
      if (document == null) {
        truncated = true;
        continue;
      }

      sheets.add(_readSheet(name, document, sharedStrings, dateStyles));
    }

    if (sheets.isEmpty) {
      // 有 `sheets` 节点却一张也没读出来 —— 包是坏的，或者说这压根不是
      // 一份工作簿（比如是个只放了别的东西的 zip）。
      return ParseResult.fail(ParseFailure.missingPart, 'worksheets');
    }
    return ParseResult.ok(Workbook(sheets: sheets, truncated: truncated));
  }

  // ------------------------------------------------------------ 共享字符串

  /// 共享字符串表：`t="s"` 的单元格里存的是这张表的下标。
  static List<String> _sharedStrings(OoxmlPackage package) {
    final document = package.xml('xl/sharedStrings.xml').valueOrNull;
    if (document == null) return const <String>[];
    final out = <String>[];
    for (final si in document.rootElement.childElements) {
      if (si.name.local != 'si') continue;
      // `si` 里可以直接是 `t`，也可以是一串 `r`（富文本分片）——
      // 富文本那一路要把每一片的 `t` 接起来，只取第一个会丢掉后半句。
      final buffer = StringBuffer();
      for (final node in si.descendantElements) {
        if (node.name.local == 't') buffer.write(node.innerText);
      }
      out.add(buffer.toString());
    }
    return out;
  }

  /// `styles.xml` 里**哪些 cellXfs 下标是日期格式**。
  ///
  /// 判据有两层：
  /// 1. `numFmtId` 是内建的日期档（14–22、45–47）。这几个不需要查
  ///    `numFmts`，Excel 把它们编在规范里。
  /// 2. 自定义 `numFmt` 的 `formatCode` 里有日期记号（`y` `m` `d` `h` `s`，
  ///    但**不能**落在引号包起来的字面量里 —— `"年"0` 这种格式里的 `年`
  ///    是文字不是日期记号，不过它前面通常也确实有 `y`，所以这条判据只要
  ///    **不在引号内**就够了）。
  static Set<int> _dateStyles(OoxmlPackage package) {
    final document = package.xml('xl/styles.xml').valueOrNull;
    if (document == null) return const <int>{};
    final root = document.rootElement;

    // 自定义格式号 → 格式串。
    final customs = <int, String>{};
    final numFmts = _child(root, 'numFmts');
    if (numFmts != null) {
      for (final fmt in numFmts.childElements) {
        if (fmt.name.local != 'numFmt') continue;
        final id = int.tryParse(fmt.getAttribute('numFmtId') ?? '');
        final code = fmt.getAttribute('formatCode');
        if (id != null && code != null) customs[id] = code;
      }
    }

    final dates = <int>{};
    final cellXfs = _child(root, 'cellXfs');
    if (cellXfs == null) return dates;
    var index = 0;
    for (final xf in cellXfs.childElements) {
      if (xf.name.local != 'xf') continue;
      final id = int.tryParse(xf.getAttribute('numFmtId') ?? '') ?? 0;
      if (_builtinDateFormats.contains(id) ||
          _looksLikeDate(customs[id] ?? '')) {
        dates.add(index);
      }
      index++;
    }
    return dates;
  }

  /// 规范里的内建日期 / 时间格式号。
  static const Set<int> _builtinDateFormats = <int>{
    14, 15, 16, 17, 18, 19, 20, 21, 22, // 日期与时间
    27, 28, 29, 30, 31, 32, 33, 34, 35, 36, // 中日韩的日期格式
    45, 46, 47, // 已用时间
    50, 51, 52, 53, 54, 55, 56, 57, 58, // 亚洲的日期格式
  };

  static bool _looksLikeDate(String formatCode) {
    if (formatCode.isEmpty) return false;
    var inLiteral = false;
    for (var i = 0; i < formatCode.length; i++) {
      final ch = formatCode[i];
      if (ch == '"') {
        inLiteral = !inLiteral;
        continue;
      }
      if (inLiteral) continue;
      // `\y` 是转义的字面量，`[red]` 是颜色标记 —— 都跳过。
      if (ch == r'\') {
        i++;
        continue;
      }
      if (ch == '[') {
        while (i < formatCode.length && formatCode[i] != ']') {
          i++;
        }
        continue;
      }
      final lower = ch.toLowerCase();
      if (lower == 'y' || lower == 'd' || lower == 'h' || lower == 's') {
        return true;
      }
      // `m` 单独判：`mm` 既可能是月也可能是分钟，都是日期时间的一部分。
      // 风险是 `0.00` 这种「货币 + 单位 m」的格式 —— 但那要 `m` 在数字
      // 占位符之后，而那种格式里几乎总是带引号（`0"m"`），已经被上面
      // 那条排掉了。
      if (lower == 'm') return true;
    }
    return false;
  }

  // ------------------------------------------------------------ 单元格

  /// 读一张表。[truncated] 置位表示这张表被裁到了上限。
  static Sheet _readSheet(
    String name,
    XmlDocument document,
    List<String> sharedStrings,
    Set<int> dateStyles,
  ) {
    final sheetData = _child(document.rootElement, 'sheetData');
    if (sheetData == null) {
      return Sheet(name: name, rows: const [], columns: 0);
    }

    final rows = <SheetRow>[];
    var columns = 0;
    var truncated = false;
    var columnsTruncated = false;

    for (final rowNode in sheetData.childElements) {
      if (rowNode.name.local != 'row') continue;
      if (rows.length >= maxRows) {
        truncated = true;
        break;
      }
      // `r` 可能缺失（少数导出工具不写）—— 那就按出现顺序数。
      final declared = int.tryParse(rowNode.getAttribute('r') ?? '');
      final rowIndex = declared ?? (rows.length + 1);

      final cells = <int, SheetCell>{};
      var position = 0;
      for (final cellNode in rowNode.childElements) {
        if (cellNode.name.local != 'c') continue;
        final ref = cellNode.getAttribute('r');
        final column = ref == null ? position : _columnOf(ref);
        if (column == null) continue;
        position = column + 1;
        if (column >= maxColumns) {
          truncated = true;
          columnsTruncated = true;
          continue;
        }
        final cell = _cell(cellNode, sharedStrings, dateStyles);
        if (cell == null) continue;
        cells[column] = cell;
        if (column + 1 > columns) columns = column + 1;
      }
      rows.add(SheetRow(rowIndex, cells));
    }

    // 撞了列上限：把宽度撑到上限，让渲染层画出那一整排空格子。
    //
    // 不这么做的话，「只有 Z 列有内容」的表格（`maxColumns` 之外）会显得
    // 一行都没有 —— 用户以为这是一张空表，其实是**右边界那一档被裁了**。
    // 撑满至少能让人看出「这里有一片列，只是看不到」。
    if (columnsTruncated) columns = maxColumns;

    return Sheet(
      name: name,
      rows: rows,
      columns: columns,
      truncated: truncated,
    );
  }

  /// 一个 `<c>` → [SheetCell]。空单元格返回 null（不渲染空值）。
  static SheetCell? _cell(
    XmlElement node,
    List<String> sharedStrings,
    Set<int> dateStyles,
  ) {
    final type = node.getAttribute('t') ?? 'n';
    final styleIndex = int.tryParse(node.getAttribute('s') ?? '');

    switch (type) {
      case 's':
        final index = int.tryParse(_valueText(node) ?? '');
        if (index == null || index < 0 || index >= sharedStrings.length) {
          return null;
        }
        final text = sharedStrings[index];
        return text.isEmpty ? null : SheetCell(text);
      case 'inlineStr':
        final inline = _child(node, 'is');
        if (inline == null) return null;
        final buffer = StringBuffer();
        for (final t in inline.descendantElements) {
          if (t.name.local == 't') buffer.write(t.innerText);
        }
        return buffer.isEmpty ? null : SheetCell(buffer.toString());
      case 'b':
        // 布尔在 xlsx 里是 `0` / `1`。
        return SheetCell(_valueText(node) == '1' ? 'TRUE' : 'FALSE');
      case 'e':
        // 错误值（`#DIV/0!` 之类）**原样显示** —— 那是这份表的一部分，
        // 藏起来反而会让人以为公式没写过。
        final error = _valueText(node);
        return error == null ? null : SheetCell(error);
      case 'str':
        // 公式的字符串结果。
        final text = _valueText(node);
        return text == null || text.isEmpty ? null : SheetCell(text);
      default:
        final raw = _valueText(node);
        if (raw == null || raw.isEmpty) return null;
        final number = num.tryParse(raw);
        if (number == null) return SheetCell(raw);
        if (styleIndex != null && dateStyles.contains(styleIndex)) {
          return SheetCell(formatSerial(number), isNumber: true);
        }
        return SheetCell(_formatNumber(number), isNumber: true);
    }
  }

  /// `<c>` 里的 `<v>`；也接受 `<is>` 之外少数工具写的 `<t>`。
  static String? _valueText(XmlElement node) {
    for (final child in node.childElements) {
      if (child.name.local == 'v') return child.innerText;
    }
    for (final child in node.childElements) {
      if (child.name.local == 't') return child.innerText;
    }
    return null;
  }

  /// 数字的显示：整数不带小数点，小数最多留 10 位有效数字。
  ///
  /// 不做「按格式串渲染」（`0.00%`、`¥#,##0.00`）—— 那要把数字格式那套
  /// 迷你语言实现一遍，而预览里最重要的是**数值本身对不对**。
  /// 但日期是例外：把 `45778` 原样显示出来等于没显示（见类注释）。
  static String _formatNumber(num value) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    // `toStringAsPrecision` 会在末尾补零（`1.5` → `1.500000000`），
    // 再削掉一遍。
    var text = value.toStringAsPrecision(10);
    if (text.contains('.') && !text.contains('e')) {
      while (text.endsWith('0')) {
        text = text.substring(0, text.length - 1);
      }
      if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    }
    return text;
  }

  /// 日期序列号 → 日期文本。
  ///
  /// 基准 1899-12-30，见类注释。只要小数部分不为零就带上时间 ——
  /// 一个纯日期列的每一格都补个 `00:00` 只是噪声。
  static String formatSerial(num serial) {
    // `45778.5` 的整天数在整数部分，时间在**小数**部分（一天 = 1.0）。
    final days = serial.floor();
    final fraction = serial - days;

    final date = DateTime.utc(1899, 12, 30).add(Duration(days: days));
    final buffer = StringBuffer()
      ..write(date.year.toString().padLeft(4, '0'))
      ..write('-')
      ..write(date.month.toString().padLeft(2, '0'))
      ..write('-')
      ..write(date.day.toString().padLeft(2, '0'));

    // 浮点误差容忍：`0.0000001` 这种来自 `1/24/60` 的残留不该显示成
    // `00:00:01`。半天（0.5）= 12 小时，所以阈值取一秒的一百分之一。
    if (fraction > 1e-4) {
      final totalSeconds = (fraction * 86400).round();
      final hours = totalSeconds ~/ 3600;
      final minutes = (totalSeconds % 3600) ~/ 60;
      final seconds = totalSeconds % 60;
      buffer
        ..write(' ')
        ..write(hours.toString().padLeft(2, '0'))
        ..write(':')
        ..write(minutes.toString().padLeft(2, '0'));
      if (seconds != 0) {
        buffer
          ..write(':')
          ..write(seconds.toString().padLeft(2, '0'));
      }
    }
    return buffer.toString();
  }

  /// `AB12` → 列号（0 起）。返回 null 表示这不是一个像样的引用。
  static int? _columnOf(String reference) {
    var column = 0;
    var sawLetter = false;
    for (var i = 0; i < reference.length; i++) {
      final ch = reference.codeUnitAt(i);
      if (ch >= 0x41 && ch <= 0x5A) {
        column = column * 26 + (ch - 0x40);
        sawLetter = true;
        continue;
      }
      if (ch >= 0x61 && ch <= 0x7A) {
        column = column * 26 + (ch - 0x60);
        sawLetter = true;
        continue;
      }
      break;
    }
    if (!sawLetter) return null;
    return column - 1;
  }

  static const String _r =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

  /// 工作簿那一层的 rels：`rId` → 包内**绝对**路径。
  ///
  /// [baseDir] 是 workbook.xml 所在的目录（`xl/`）—— `Target` 的基准是
  /// **部件所在的目录**，不是 rels 文件所在的那一层。
  static Map<String, String> _relationshipMap(
    OoxmlPackage package,
    String relsPath,
    String baseDir,
  ) {
    final document = package.xml(relsPath).valueOrNull;
    if (document == null) return const <String, String>{};
    // 这里不复用 `package.relationshipTarget`：那个只返回**第一条**匹配
    // 指定 Type 的，而工作表有一整列（每个 `r:id` 都要能查到），
    // 而且我们要的是「已经拼成绝对路径」的结果。
    final out = <String, String>{};
    for (final rel in document.rootElement.childElements) {
      if (rel.name.local != 'Relationship') continue;
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id == null || target == null) continue;
      out[id] = _resolveFrom(baseDir, target);
    }
    return out;
  }

  /// 把一个相对目标解成包内绝对路径。
  static String _resolveFrom(String baseDir, String target) {
    if (target.startsWith('/')) return target.replaceAll(RegExp(r'^/+'), '');
    final stack = baseDir.isEmpty ? <String>[] : baseDir.split('/');
    for (final segment in target.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (stack.isNotEmpty) stack.removeLast();
        continue;
      }
      stack.add(segment);
    }
    return stack.join('/');
  }

  static String _join(String dir, String path) {
    if (path.startsWith('/')) return path.replaceAll(RegExp(r'^/+'), '');
    if (dir.isEmpty) return path;
    return '$dir/$path';
  }

  static XmlElement? _child(XmlElement parent, String local) {
    for (final child in parent.childElements) {
      if (child.name.local == local) return child;
    }
    return null;
  }
}
