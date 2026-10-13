import 'package:flutter/material.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/storage/local_file.dart';
import '../../../l10n/app_localizations.dart';
import '../codecs/ooxml.dart';
import '../codecs/xlsx.dart';
import 'docx_viewer_screen.dart' show OfficeErrorView, OfficeFooter;

/// `.xlsx` 附件的预览：顶部切工作表，下面一张表。
///
/// 只吃**本地路径**（调用方先 `ensureLocal`）—— 和另外几个 viewer 一致。
///
/// ## 与 CSV viewer 是两张表，不是一个控件的两种皮肤
///
/// 看起来都是「一格格的东西」，但两边的输入形状不同：CSV 是
/// `List<List<String>>`（每行等长补齐），xlsx 是**稀疏**的
/// `Map<int, SheetCell>` 加上「这一格是数字还是文字」这一个额外维度，
/// 而且没有表头（第一行就是数据）。硬凑成一个控件就要给每一格包一层
/// 「可选表头 / 可选对齐 / 可选行号」的开关，还不如各写一份 ——
/// 这一份只有几十行。
///
/// ## 列号头是**画出来的**，不是数据
///
/// 顶上那一行 `A B C …` 是列标，钉住它才能在横向滚到第 30 列时知道
/// 「这是 AE 列」—— 它对应用户在 Excel 里看到的列，不算伪造数据
/// （不像 CSV 那样「第一行是不是表头」要靠猜）。
///
/// **不做**行号栏：横向滚动时它会跟着滚走，单独为它做一条双向联动的
/// 滚动条不值当。行号的价值主要在「跟同事说第几行」，而预览里没人会引用它。
class XlsxViewerScreen extends StatefulWidget {
  const XlsxViewerScreen({super.key, required this.path, this.title});

  final String path;
  final String? title;

  @override
  State<XlsxViewerScreen> createState() => _XlsxViewerScreenState();
}

class _XlsxViewerScreenState extends State<XlsxViewerScreen> {
  Workbook? _workbook;

  /// 见 [OfficeErrorView] 的 `reason`。
  String? _error;

  int _sheet = 0;

  @override
  void initState() {
    super.initState();
    // 与 docx viewer 同一套：读盘与解析都放 `initState` 里会把首帧一起卡住。
    // 排的是**宏任务**（timer）—— `Future.microtask` 在当前帧结束前就跑掉了。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>(_load);
    });
  }

  Future<void> _load() async {
    final bytes = LocalFile.readBytes(
      widget.path,
      // 整份解析：截一半的 zip 一定解不开（同 docx viewer）。
      maxBytes: AppDefaults.attachmentPreviewLimit,
    );
    if (!mounted) return;
    if (bytes == null) {
      setState(() {
        _error = LocalFile.length(widget.path) >
                AppDefaults.attachmentPreviewLimit
            ? 'tooLarge'
            : 'gone';
      });
      return;
    }

    final result = XlsxCodec.parse(bytes);
    if (!mounted) return;
    final workbook = result.valueOrNull;
    setState(() {
      _workbook = workbook;
      _error = workbook == null
          ? switch (result.failureOrNull) {
              ParseFailure.notAPackage => 'notAPackage',
              ParseFailure.missingPart => 'missingPart',
              ParseFailure.malformed => 'malformed',
              ParseFailure.tooLarge => 'tooLarge',
              null => 'gone',
            }
          : null;
      // 换了文件（同一个 State 被复用的情况）时别把下标停在上一份的
      // 页码上 —— 那张表可能压根不存在。
      if (workbook != null && _sheet >= workbook.sheets.length) _sheet = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final workbook = _workbook;
    final error = _error;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? l10n.preview,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: switch ((error, workbook)) {
        (final String reason, _) => OfficeErrorView(reason: reason),
        (_, final Workbook book) => _body(book, l10n),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _body(Workbook workbook, AppLocalizations l10n) {
    final index = _sheet.clamp(0, workbook.sheets.length - 1);
    final sheet = workbook.sheets[index];
    final notes = <String>[
      if (sheet.truncated)
        l10n.csvTruncated(XlsxCodec.maxRows, XlsxCodec.maxColumns),
      if (workbook.truncated) l10n.xlsxSheetsTruncated(XlsxCodec.maxSheets),
      l10n.xlsxPartial,
    ];

    return Column(
      children: <Widget>[
        // 多张表时才占位置：一份只有一张表的工作簿顶上挂一条切换栏是噪声。
        if (workbook.sheets.length > 1)
          _SheetBar(
            names: workbook.sheets.map((s) => s.name).toList(growable: false),
            selected: index,
            onSelect: (value) => setState(() => _sheet = value),
          ),
        Expanded(
          child: sheet.isEmpty
              ? _Placeholder(text: l10n.xlsxSheetEmpty)
              : _Grid(sheet: sheet),
        ),
        OfficeFooter(notes: notes),
      ],
    );
  }
}

/// 顶部的工作表切换：横向可滚的一排 chip。
///
/// 不用 `TabBar`：一份工作簿有十几张表是常事，`TabBar` 会把它压成等宽的一排
/// 小字（或者滑动的下划线，十几张之后谁也找不到哪张被选中）。chip 横向滚动、
/// 选中的那张有实底色，扫一眼就知道在哪。
class _SheetBar extends StatelessWidget {
  const _SheetBar({
    required this.names,
    required this.selected,
    required this.onSelect,
  });

  final List<String> names;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: names.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final choice = ChoiceChip(
            label: Text(
              names[index],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            labelStyle: theme.textTheme.labelMedium,
            selected: index == selected,
            onSelected: (_) => onSelect(index),
          );
          // 表名可能很长（`2024 年度汇总（最终版2）`）—— 给一个上限，
          // 否则一张表名就能把整个切换栏占满，别的表全滚到屏幕外。
          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: choice,
          );
        },
      ),
    );
  }
}

/// 表格本体。
class _Grid extends StatelessWidget {
  const _Grid({required this.sheet});

  final Sheet sheet;

  /// 单元格宽度。比 CSV 那边（140–240）窄：表格里数字多，窄一点一屏能看到
  /// 更多列，而数字列本来也不需要那么宽。
  static const double _cellWidth = 120;

  /// 一行两行文字的高度 —— 与 CSV viewer 取同一个数。
  static const double _rowHeight = 46;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final columns = sheet.columns;
    if (columns == 0) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: _cellWidth * columns,
        child: Column(
          children: <Widget>[
            // 列标头跟着横向滚，纵向不动（和 CSV viewer 同一个结构）。
            SizedBox(
              height: 28,
              child: Row(
                children: List<Widget>.generate(
                  columns,
                  (index) => _HeaderCell(
                    label: columnLabel(index),
                    width: _cellWidth,
                    theme: theme,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: sheet.rows.length,
                itemBuilder: (_, index) => _Row(
                  row: sheet.rows[index],
                  columns: columns,
                  width: _cellWidth,
                  height: _rowHeight,
                  theme: theme,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({
    required this.label,
    required this.width,
    required this.theme,
  });

  final String label;
  final double width;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          right: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5),
          bottom:
              BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.row,
    required this.columns,
    required this.width,
    required this.height,
    required this.theme,
  });

  final SheetRow row;
  final int columns;
  final double width;
  final double height;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        children: List<Widget>.generate(columns, (index) {
          final cell = row.cells[index];
          return _Cell(
            cell: cell,
            width: width,
            height: height,
            theme: theme,
          );
        }),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.cell,
    required this.width,
    required this.height,
    required this.theme,
  });

  /// 空格子（这一行没写这一列）时是 null。
  final SheetCell? cell;

  final double width;
  final double height;
  final ThemeData theme;

  /// 点开看全文。只有**截断过**的格子才弹（同 CSV viewer 的理由：
  /// 弹出框是模态的，两个字符也弹一下就是打扰）。
  void _showFull(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.preview, style: const TextStyle(fontSize: 14)),
          content: SingleChildScrollView(
            child: SelectionArea(child: Text(cell!.text)),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.close),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final value = cell?.text ?? '';
    final style = theme.textTheme.bodySmall?.copyWith(height: 1.35);

    // 溢出与否只能靠排版算出来（`maxLines: 2` 是排完才知道切没切）。
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      maxLines: 2,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width - 16);
    final truncated = painter.didExceedMaxLines;

    return InkWell(
      onTap: truncated ? () => _showFull(context) : null,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: scheme.outlineVariant, width: 0.5),
            bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Align(
          // 数字靠右：一列数字右对齐才能一眼比出大小 —— 这是表格最常做的事。
          alignment:
              (cell?.isNumber ?? false) ? Alignment.centerRight : Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: (cell?.isNumber ?? false) ? TextAlign.right : TextAlign.left,
            style: style,
          ),
        ),
      ),
    );
  }
}

/// 0 → `A`，25 → `Z`，26 → `AA`。xlsx 的列引用就是这个规则（26 进制，
/// 但没有 0 这个符号，所以每一步都先减一）。
String columnLabel(int index) {
  final letters = <String>[];
  var value = index + 1;
  while (value > 0) {
    final digit = (value - 1) % 26;
    letters.add(String.fromCharCode(0x41 + digit));
    value = (value - 1) ~/ 26;
  }
  // 上面是从低位往高位攒的，要反过来。
  return letters.reversed.join();
}

/// 一张没有内容的表。
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        text,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
