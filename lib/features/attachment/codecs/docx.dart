import 'package:xml/xml.dart';

import 'doc_model.dart';
import 'ooxml.dart';

/// `.docx` → [DocBlock] 列表。
///
/// 只读 `word/document.xml`（路径由 `_rels/.rels` 声明，见 [Ooxml]
/// 的 [OoxmlPackage.relationshipTarget]）。**明确不做**：图片与图形
/// （`w:drawing` / `w:pict` → 一个 `[图片]` 占位）、脚注尾注、文本框、
/// SmartArt、公式、页眉页脚、精确版式与分页、批注与修订标记。
/// 界面底部会说明「图片与版式未显示」，免得用户以为文件坏了。
///
/// 纯函数：吃字节，吐模型，不 import `dart:io`、不 import widget。
abstract final class DocxCodec {
  const DocxCodec._();

  static const String _w =
      'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

  static const String _relsRelType = '/officeDocument';

  static ParseResult<List<DocBlock>> parse(List<int> bytes) {
    final opened = Ooxml.open(bytes);
    if (opened is ParseFailed<OoxmlPackage>) {
      return ParseFailed<List<DocBlock>>(opened.reason, opened.detail);
    }
    final package = (opened as ParseOk<OoxmlPackage>).value;

    // 主部件的位置是 rels 声明的；读不到就退回那个几乎总是对的约定路径。
    final path = package.relationshipTarget(
          '_rels/.rels',
          typeSuffix: _relsRelType,
        ) ??
        'word/document.xml';

    final doc = package.xml(path);
    if (doc is ParseFailed<XmlDocument>) {
      return ParseFailed<List<DocBlock>>(doc.reason, doc.detail);
    }

    final root = (doc as ParseOk<XmlDocument>).value.rootElement;
    final body = _first(root, 'body');
    if (body == null) {
      return ParseResult.fail(ParseFailure.missingPart, 'w:body');
    }

    final blocks = <DocBlock>[];
    for (final node in body.childElements) {
      switch (node.name.local) {
        case 'p':
          final paragraph = _paragraph(node);
          // 空段落不丢：它是文档里的空行，丢了段落之间会挤在一起。
          blocks.add(DocParagraphBlock(paragraph));
        case 'tbl':
          final table = _table(node);
          if (!table.isEmpty) blocks.add(DocTableBlock(table));
        case 'sdt':
          // `sdt`（结构化文档标签）是 Word 给内容加的一层包装，正文在
          // `sdtContent` 里 —— 目录、封面那类都是它。拆开接着走同一套。
          for (final inner in _sdtContent(node).childElements) {
            if (inner.name.local == 'p') {
              blocks.add(DocParagraphBlock(_paragraph(inner)));
            } else if (inner.name.local == 'tbl') {
              final table = _table(inner);
              if (!table.isEmpty) blocks.add(DocTableBlock(table));
            }
          }
      }
    }
    return ParseResult.ok(blocks);
  }

  // -------------------------------------------------------------- 段落

  static DocParagraph _paragraph(XmlElement p) {
    final pPr = _first(p, 'pPr');
    var style = DocBlockStyle.body;
    var level = 0;

    final pStyle = pPr == null ? null : _first(pPr, 'pStyle');
    final styleName = pStyle?.getAttribute('val', namespaceUri: _w) ?? '';
    final heading = _headingLevel(styleName);
    if (heading > 0) {
      style = DocBlockStyle.heading;
      level = heading;
    } else if (styleName == 'Quote' || styleName == 'IntenseQuote') {
      style = DocBlockStyle.quote;
    }

    final numPr = pPr == null ? null : _first(pPr, 'numPr');
    if (numPr != null) {
      // 见 [DocBlockStyle]：有序 / 无序一律当项目符号。
      style = DocBlockStyle.bullet;
      final ilvl = _first(numPr, 'ilvl')?.getAttribute('val', namespaceUri: _w);
      level = int.tryParse(ilvl ?? '') ?? 0;
      if (level < 0) level = 0;
      // 列表层级可以很深，但界面上的缩进得有个头，否则一段文字会被推到
      // 屏幕外。（解析器给一个上限值，渲染也就不用自己再夹一次。）
      if (level > 8) level = 8;
    }

    final align = _first(pPr ?? p, 'jc')?.getAttribute('val', namespaceUri: _w);

    final runs = <DocRun>[];
    _collectRuns(p, runs, _RunStyle());
    return DocParagraph(runs: runs, style: style, level: level, align: align);
  }

  /// 标题级别：`Heading1`…`Heading9`、以及独立出来的 `Title` / `Subtitle`。
  static int _headingLevel(String styleName) {
    if (styleName == 'Title') return 1;
    if (styleName == 'Subtitle') return 2;
    final match = RegExp(r'^Heading(\d+)$').firstMatch(styleName);
    if (match == null) return 0;
    final n = int.tryParse(match.group(1)!) ?? 0;
    // Word 有 Heading1..9，而这个模型只到 6（再深的标题在预览里
    // 和正文没有区别）。
    return n.clamp(0, 6);
  }

  /// 一行里当前生效的行内样式（`w:rPr` 是可以继承的，见 [_collectRuns]）。
  static void _collectRuns(
    XmlElement node,
    List<DocRun> out,
    _RunStyle style,
  ) {
    for (final child in node.childElements) {
      switch (child.name.local) {
        case 'r':
          final rPr = child.childElements
              .where((e) => e.name.local == 'rPr')
              .firstOrNull;
          final merged = style.mergedWith(rPr);
          final buffer = StringBuffer();
          void flush() {
            if (buffer.isEmpty) return;
            out.add(DocRun(
              buffer.toString(),
              bold: merged.bold,
              italic: merged.italic,
              underline: merged.underline,
              strike: merged.strike,
              script: merged.script,
            ));
            buffer.clear();
          }

          for (final part in child.childElements) {
            switch (part.name.local) {
              case 't':
                buffer.write(part.innerText);
              case 'tab':
                buffer.write('\t');
              case 'br' || 'cr':
                buffer.write('\n');
              case 'drawing' || 'pict' || 'object':
                // 「明确不做」的那一档（见类注释）。不渲染，但要说出来。
                flush();
                out.add(const DocRun('[图片]', bold: false, italic: true));
              case 'footnoteReference' || 'endnoteReference':
                flush();
                out.add(const DocRun('[脚注]', italic: true));
              case 'sym':
                // 符号（勾、箭头这类）在 `w:sym@w:char` 里是个字体码位，
                // 没有通用映射，直接给占位比显示一个乱码好。
                buffer.write('□');
            }
          }
          flush();
        case 'hyperlink' || 'sdt' || 'smartTag' || 'ins' || 'del':
          // 包装层：超链接、内容控件、修订标记。里面还是 run，
          // 但整段一起变样式（`del` 的内容本应划掉，这里按普通文本走）。
          _collectRuns(child.name.local == 'sdt' ? _sdtContent(child) : child,
              out, style);
        case 'bookmarkStart' || 'bookmarkEnd':
          break;
        case 'proofErr' || 'commentRangeStart' || 'commentRangeEnd':
          break;
        default:
          // 未知元素里可能还裹着 run（`w:ins` 的各种变体），
          // 递归一层比直接丢内容安全。深度由 XML 解析器自己的递归深度兜着，
          // 而输入已经过了 [Ooxml] 的字节上限。
          if (child.childElements.isNotEmpty) {
            _collectRuns(child, out, style);
          }
      }
    }
  }

  // -------------------------------------------------------------- 表格

  static DocTable _table(XmlElement tbl) {
    final rows = <DocTableRow>[];
    for (final tr in tbl.childElements) {
      if (tr.name.local != 'tr') continue;
      final cells = <DocCell>[];
      for (final tc in tr.childElements) {
        if (tc.name.local != 'tc') continue;
        final span = _first(_first(tc, 'tcPr') ?? tc, 'gridSpan')
                ?.getAttribute('val', namespaceUri: _w);
        final paragraphs = <DocParagraph>[];
        for (final inner in tc.childElements) {
          if (inner.name.local == 'p') paragraphs.add(_paragraph(inner));
        }
        cells.add(DocCell(
          paragraphs: paragraphs,
          colSpan: (int.tryParse(span ?? '') ?? 1).clamp(1, 64),
        ));
      }
      if (cells.isNotEmpty) rows.add(DocTableRow(cells));
    }
    return DocTable(rows);
  }

  // -------------------------------------------------------------- 小工具

  /// 按**本地名**找子元素，同时要求命名空间是 `w`。
  ///
  /// 只按 `local` 匹配是不够的：一份文档里可以同时有别的命名空间的同名元素
  /// （`a` 绘图、`m` 公式），`findElements('p')` 会把它们一起捞出来。
  /// 命名空间后不匹配（有几个工具写的 docx 用了别的 URI）时退回只按
  /// local 名 —— 这不是宽松，是「内容比严格更值钱」：宁可多认几个元素，
  /// 也不要给用户一个空白的预览。
  static XmlElement? _first(XmlElement parent, String local) {
    for (final child in parent.childElements) {
      if (child.name.local == local && child.name.namespaceUri == _w) {
        return child;
      }
    }
    for (final child in parent.childElements) {
      if (child.name.local == local) return child;
    }
    return null;
  }

  /// `w:sdt` 里的内容。取不到就返回它自己（让调用方接着往下走，而不是丢内容）。
  static XmlElement _sdtContent(XmlElement sdt) =>
      _first(sdt, 'sdtContent') ?? sdt;
}

/// 一路继承下来的行内样式。
///
/// `w:rPr` 是按层叠加的：`w:ins` 里可以有 `rPr`，`w:pPr/w:rPr`（段落默认）
/// 里也可以有。这里只做「子级给的覆盖父级」这一层，不做 `w:rStyle` 引用的
/// 样式表查表 —— 那要把 `styles.xml` 整份读进来，而预览里最常见的加粗 /
/// 斜体几乎都直接写在 `rPr` 上。
class _RunStyle {
  const _RunStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.script = DocScript.normal,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final DocScript script;

  _RunStyle mergedWith(XmlElement? rPr) {
    if (rPr == null) return this;
    var bold = this.bold;
    var italic = this.italic;
    var underline = this.underline;
    var strike = this.strike;
    var script = this.script;

    for (final child in rPr.childElements) {
      // `<w:b/>` 是打开，`<w:b w:val="0"/>` / `"false"` 是**关掉** ——
      // 只判元素在不在会把手动取消的加粗当成加粗。
      final on = _isOn(child);
      switch (child.name.local) {
        case 'b':
          bold = on;
        case 'i':
          italic = on;
        case 'u':
          // 下划线有好几种样式（single / double / wave…），
          // 而对预览来说「有没有」就够了。
          underline = on && (child.getAttribute('val', namespaceUri: DocxCodec._w) != 'none');
        case 'strike' || 'dstrike':
          strike = on;
        case 'vertAlign':
          final val = child.getAttribute('val', namespaceUri: DocxCodec._w);
          script = switch (val) {
            'superscript' => DocScript.superscript,
            'subscript' => DocScript.subscript,
            _ => DocScript.normal,
          };
      }
    }
    return _RunStyle(
      bold: bold,
      italic: italic,
      underline: underline,
      strike: strike,
      script: script,
    );
  }

  static bool _isOn(XmlElement element) {
    final val = element.getAttribute('val', namespaceUri: DocxCodec._w) ??
        element.getAttribute('val');
    if (val == null) return true;
    return val != '0' && val != 'false' && val != 'off';
  }
}
