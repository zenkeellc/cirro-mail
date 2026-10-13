/// docx / pptx 共用的**中性文档模型**：段落、行内样式、表格。
///
/// 为什么要有这一层而不是各自直接输出 widget：三个 Office 解析器与它们的
/// viewer 是两组东西（解析器是纯函数、可以在没有插件的测试里跑），中间必须
/// 有一个不含 Flutter 的表示。这一层也就顺手让 docx 与 pptx 共用一套渲染
/// ——ppt x 的一页里除标题外也就是若干段落。
///
/// 它**刻意很小**。OOXML 能表达的东西远不止这些，而附件预览要的是
/// 「能看内容」：分页、版式、文本框、图表、SmartArt 一律不进这个模型，
/// 因为不进模型就不会有「渲染得似是而非」的中间状态。
library;

/// 行内样式。这四个是文档里真正常见的（加粗、斜体、下划线、删除线），
/// 其余的（阴影、描边、字距）一律不表示。
enum DocScript { normal, superscript, subscript }

/// 一段连续的同样式文本。
class DocRun {
  const DocRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.script = DocScript.normal,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final DocScript script;

  /// 有没有任何样式 —— 渲染时用来跳过纯文本那条更便宜的路。
  bool get isPlain =>
      !bold &&
      !italic &&
      !underline &&
      !strike &&
      script == DocScript.normal;

  @override
  String toString() => 'DocRun(${text.length} chars'
      '${bold ? ' b' : ''}${italic ? ' i' : ''}'
      '${underline ? ' u' : ''}${strike ? ' s' : ''})';
}

/// 段落的块级语义。
///
/// **没有「有序列表」这一档**：OOXML 里一个列表项是有序还是无序，写在
/// `numbering.xml` 的 `w:abstractNum/w:lvl/w:numFmt` 里，而 `numPr` 只给一个
/// `numId` —— 要判就得把编号定义整份读进来（还要处理「同一份定义被多处
/// 覆盖」的继承）。为了一个预览去实现那一套不划算，所以**一律当项目符号**，
/// 界面底部如实说明（见 `office_viewer_screen.dart`）。这是本轮明确接受的
/// 降级，不是为了少写代码而留的坑。
enum DocBlockStyle {
  /// 正文。
  body,

  /// 标题，级别见 [DocParagraph.level]（1 最高）。
  heading,

  /// 列表项（无序）。
  bullet,

  /// 引用块。
  quote,
}

/// 一个段落。
class DocParagraph {
  const DocParagraph({
    required this.runs,
    this.style = DocBlockStyle.body,
    this.level = 0,
    this.align,
  });

  final List<DocRun> runs;
  final DocBlockStyle style;

  /// 标题级别（1–6；0 表示不是标题）或列表的缩进层级（`w:ilvl`）。
  final int level;

  /// 对齐方式：`left` / `center` / `right` / `justify`，没写明是 null。
  final String? align;

  String get text => runs.map((r) => r.text).join();

  bool get isEmpty => text.trim().isEmpty;
}

/// 表格里的一格。
class DocCell {
  const DocCell({required this.paragraphs, this.colSpan = 1});

  final List<DocParagraph> paragraphs;

  /// 横跨几列（`w:gridSpan`）。
  final int colSpan;

  String get text => paragraphs.map((p) => p.text).join('\n');
}

class DocTableRow {
  const DocTableRow(this.cells);
  final List<DocCell> cells;
}

class DocTable {
  const DocTable(this.rows);

  final List<DocTableRow> rows;

  /// 最宽那一行的格子数 —— 行尾不齐时渲染要按它铺。
  int get columns {
    var max = 0;
    for (final row in rows) {
      var count = 0;
      for (final cell in row.cells) {
        count += cell.colSpan;
      }
      if (count > max) max = count;
    }
    return max;
  }

  bool get isEmpty => rows.isEmpty || columns == 0;
}

/// 块级元素。
sealed class DocBlock {
  const DocBlock();
}

/// 一段由 [DocParagraph] 表达的块。
class DocParagraphBlock extends DocBlock {
  const DocParagraphBlock(this.paragraph);
  final DocParagraph paragraph;
}

/// 一张表。
class DocTableBlock extends DocBlock {
  const DocTableBlock(this.table);
  final DocTable table;
}

/// 一个**占位**：原文档这里有一张图 / 一个公式 / 一个图表，我们不渲染它。
///
/// 显式用占位符而不是直接跳过：跳过去之后用户看到的是「文字接得上但少了
/// 一段」，会以为是文件坏了或预览 bug。一个 `[图片]` 让「看不到」这件事
/// 本身变得可见 —— 和 markdown 处理图片是同一个做法。
class DocPlaceholderBlock extends DocBlock {
  const DocPlaceholderBlock(this.label);
  final String label;
}
