import 'package:flutter/material.dart';

import '../codecs/doc_model.dart';

/// 把一串 [DocBlock]**画出来** —— docx 的正文与 pptx 的每一页共用这一份。
///
/// 分成一个独立 widget 而不是塞进某个 viewer 里：pptx 的一页就是「若干段落
/// 加可能的表格」，和 docx 的正文是同一件东西。各写一份的话，两边的标题
/// 字号、列表缩进、表格边框会慢慢长成两个样子。
///
/// ## 样式是**读**出来的，不是等比缩放的
///
/// OOXML 里每一个 run 都带着自己的字号（`w:sz`，半磅为单位），照抄它看起来
/// 最忠实 —— 但实际上很糟：附件预览多半在手机上读，而一份按 A4 排的文档
/// 正文字号（五号 / 10.5pt）缩到手机上小得看不清。所以这里**不读字号**，
/// 用主题的字号档（body / title / headline）按语义映射。用户要的是
/// 「读得到」，不是「排版一致」。
///
/// ## 明确不画的
///
/// 页边距、分页、页眉页脚、文本框的绝对位置、图片本身（解析器已经把它换成
/// `[图片]` 了）、表格的列宽（一律等分，见 [_TableBlock]）。
class DocBlocksView extends StatelessWidget {
  const DocBlocksView({
    super.key,
    required this.blocks,
    this.shrinkWrap = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  final List<DocBlock> blocks;

  /// 内容会嵌在别的滚动体（或表格单元格）里时置 true。
  ///
  /// 置 true 时用 `Column` 而不是 `ListView`，**这不只是省一层滚动**：
  /// 单元格那一侧要 `IntrinsicHeight` 才能让同一行的格子等高，而
  /// `ListView` 的 viewport 明确不支持 intrinsic 尺寸（会抛
  /// `RenderShrinkWrappingViewport does not support returning intrinsic
  /// dimensions`）。表格单元格里的内容本来也不可能长到一个页面装不下的量级。
  final bool shrinkWrap;

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    if (shrinkWrap) {
      return Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final block in blocks) _Block(block),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: padding,
      itemCount: blocks.length,
      itemBuilder: (context, index) => _Block(blocks[index]),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block(this.block);

  final DocBlock block;

  @override
  Widget build(BuildContext context) {
    return switch (block) {
      DocParagraphBlock(paragraph: final p) => _Paragraph(p),
      DocTableBlock(table: final t) => _TableBlock(t),
      DocPlaceholderBlock(label: final l) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _Placeholder(l),
          ),
        ),
    };
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph(this.paragraph);

  final DocParagraph paragraph;

  /// 项目符号的缩进量（每层 16pt）。
  static const double _indentStep = 16;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = _styleFor(theme, paragraph);
    final indent = switch (paragraph.style) {
      DocBlockStyle.bullet => _indentStep * (paragraph.level + 1),
      // 引用块左侧那一条竖线占的宽度。
      DocBlockStyle.quote => 12.0,
      _ => 0.0,
    };

    if (paragraph.runs.isEmpty) {
      // 空段落仍然占一行的高度 —— 它是原文里的空行，抽掉段落就挤在一起了。
      return SizedBox(height: (base.fontSize ?? 14) * (base.height ?? 1.4));
    }

    final text = Text.rich(
      TextSpan(children: paragraph.runs.map(_spanFor).toList()),
      style: base,
      textAlign: _alignFor(paragraph.align),
    );

    final body = paragraph.style == DocBlockStyle.bullet
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 符号单独一列：让它和第一行文字对齐（而不是和整段的
              // 垂直中线对齐 —— 那样两行以上的列表项符号会飘到中间）。
              SizedBox(
                width: 16,
                child: Text('•', style: base, textAlign: TextAlign.center),
              ),
              Expanded(child: text),
            ],
          )
        : text;

    final wrapped = paragraph.style == DocBlockStyle.quote
        ? Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 3,
                ),
              ),
            ),
            padding: const EdgeInsets.only(left: 12),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              child: text,
            ),
          )
        : body;

    return Padding(
      padding: EdgeInsets.only(
        left: indent - (paragraph.style == DocBlockStyle.quote ? 12 : 0),
        bottom: _spacingAfter(paragraph, base),
      ),
      child: wrapped,
    );
  }

  /// 段落之间的间距：标题上下都要留白，列表项之间挨紧一点。
  static double _spacingAfter(DocParagraph paragraph, TextStyle base) {
    switch (paragraph.style) {
      case DocBlockStyle.heading:
        return 10;
      case DocBlockStyle.bullet:
        return 2;
      case DocBlockStyle.quote:
        return 8;
      case DocBlockStyle.body:
        return 8;
    }
  }

  /// 语义字号，不读 `w:sz`（见 [DocBlocksView] 类注释）。
  static TextStyle _styleFor(ThemeData theme, DocParagraph paragraph) {
    final base = theme.textTheme;
    switch (paragraph.style) {
      case DocBlockStyle.heading:
        return switch (paragraph.level) {
          1 => base.headlineSmall!.copyWith(fontWeight: FontWeight.w700),
          2 => base.titleLarge!.copyWith(fontWeight: FontWeight.w700),
          3 => base.titleMedium!.copyWith(fontWeight: FontWeight.w700),
          _ => base.titleSmall!.copyWith(fontWeight: FontWeight.w700),
        };
      case DocBlockStyle.bullet:
        return base.bodyMedium!;
      case DocBlockStyle.quote:
        return base.bodyMedium!.copyWith(fontStyle: FontStyle.italic);
      case DocBlockStyle.body:
        return base.bodyMedium!;
    }
  }

  static TextAlign _alignFor(String? align) => switch (align) {
        'center' => TextAlign.center,
        'right' || 'end' => TextAlign.right,
        'both' || 'justify' => TextAlign.justify,
        _ => TextAlign.start,
      };

  /// 一个 run → 一个 `TextSpan`。
  static TextSpan _spanFor(DocRun run) {
    final decoration = <TextDecoration>[
      if (run.underline) TextDecoration.underline,
      if (run.strike) TextDecoration.lineThrough,
    ];
    // 上下标：`fontFeatures` 那一套（`FontFeature.superscripts()`）依赖字体里
    // 有对应的 OpenType 特性，缺了就不生效；缩字号是任何字体都有的。
    // 两个都上 —— 有特性的字体排版更好，没有的也不会退化成正文一样大。
    final scripted = run.script != DocScript.normal;
    return TextSpan(
      text: run.text,
      style: TextStyle(
        fontWeight: run.bold ? FontWeight.w700 : null,
        fontStyle: run.italic ? FontStyle.italic : null,
        decoration:
            decoration.isEmpty ? null : TextDecoration.combine(decoration),
        fontSize: scripted ? 11 : null,
        height: scripted ? 1.0 : null,
        fontFeatures: scripted
            ? const <FontFeature>[
                FontFeature.subscripts(),
                FontFeature.superscripts(),
              ]
            : null,
      ),
    );
  }
}

/// 表格：等分列宽、带边框。
///
/// ## 为什么不用 `Table` widget
///
/// Flutter 的 `TableCell` **没有**跨列这个参数（`columnSpan` 不存在），而
/// OOXML 里 `w:gridSpan` 恰恰是文档表格最常见的写法之一（合并的表头）。
/// 用 `Table` 就只能把合并格拆成「第一格放内容、后面几格空着」，中间那道
/// 竖线还照样画出来 —— 看起来像数据缺失。
///
/// 所以行用 `Row` + `Expanded(flex: colSpan)` 拼：合并格天然就是一个 widget，
/// 内部没有边框。跨行对齐靠**每一行的 flex 总和都等于 [DocTable.columns]**
/// （行尾不齐时补空格子），这是 `Row` 与 `Table` 在这件事上等价的唯一前提。
///
/// ## 也不做自动列宽
///
/// 按内容算列宽要给每一列测一遍最宽的文字，而大表是常态（xlsx 那一侧更是），
/// 量一次就是几十毫秒。等分在绝大多数「两到五列」的文档表格上是可读的，
/// 而它一次排版就够。
class _TableBlock extends StatelessWidget {
  const _TableBlock(this.table);

  final DocTable table;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final columns = table.columns;
    if (columns == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      // 外框只画左、上，每个格子画右、下 —— 两道合起来才是完整的一圈，
      // 而每一格只需要一个 `Container`，不用嵌套。
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: scheme.outlineVariant, width: 0.5),
            top: BorderSide(color: scheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Column(
          children: <Widget>[
            for (final row in table.rows) _row(row, columns, scheme),
          ],
        ),
      ),
    );
  }

  Widget _row(DocTableRow row, int columns, ColorScheme scheme) {
    final children = <Widget>[];
    var span = 0;
    for (final cell in row.cells) {
      // `colSpan` 不能超过表的宽度 —— 一份声明了 gridSpan=99 而表只有 3 列的
      // 文档会让这一行的 flex 总和超额，跨行对齐就散了。
      final flex = cell.colSpan.clamp(1, columns - span);
      children.add(Expanded(flex: flex, child: _cell(cell, scheme)));
      span += flex;
      if (span >= columns) break;
    }
    // 行尾不齐时补空格子。
    if (span < columns) {
      children.add(Expanded(flex: columns - span, child: _emptyCell(scheme)));
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _cell(DocCell cell, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: _cellBorder(scheme),
      child: cell.paragraphs.isEmpty
          ? const SizedBox.shrink()
          : DocBlocksView(
              blocks: cell.paragraphs
                  .map<DocBlock>(DocParagraphBlock.new)
                  .toList(growable: false),
              shrinkWrap: true,
              padding: EdgeInsets.zero,
            ),
    );
  }

  Widget _emptyCell(ColorScheme scheme) =>
      Container(decoration: _cellBorder(scheme));
}

BoxDecoration _cellBorder(ColorScheme scheme) => BoxDecoration(
      border: Border(
        right: BorderSide(color: scheme.outlineVariant, width: 0.5),
        bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
      ),
    );

/// 「这里有个我们没画的东西」。
class _Placeholder extends StatelessWidget {
  const _Placeholder(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
