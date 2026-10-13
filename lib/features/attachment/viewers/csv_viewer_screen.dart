import 'package:flutter/material.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/storage/local_file.dart';
import '../../../l10n/app_localizations.dart';
import '../codecs/csv.dart';
import '../codecs/text_codec.dart';

/// CSV / TSV 附件的预览：表头钉在顶上，横向纵向都能滚。
///
/// 只吃**本地路径**（调用方先 `ensureLocal`）—— 和另外几个 viewer 一致。
///
/// ## 为什么表头是 `Column` 的一行、而不是 `ListView` 的第一项
///
/// 钉住表头有两条路：`SliverPersistentHeader`（或 `ListView` 里判
/// `index == 0` 换一种样式）与「表头放 `Column` 里、`ListView` 只管正文」。
/// 走后者是因为**横向滚动要跟表头共用**：表格横向滚到第 30 列时表头也得跟着
/// 走，否则「这一列是什么」就没法看了。两者都放进同一个
/// `SingleChildScrollView(scrollDirection: horizontal)` 里，联动是天然的，
/// 不用给两个控制器拉同步。
///
/// 纵向则相反：表头在 `ListView` **外面**，所以它不会被滚走。
///
/// ## 单元格定宽、点开看全文
///
/// 定宽不只是审美：不定宽就得按最宽那个单元格撑，一份有一个 5 万字符字段的
/// CSV 会让整张表横向撑出几万像素。定宽 + 溢出省略 + 点一下弹全文，
/// 是「扫一眼」与「拿到确切内容」两头都顾上的做法。
///
/// ## 不做的事
///
/// **冻结第一列**、排序、筛选、行列高亮，本轮都不做。冻结列要双向联动滚动
/// （横向那个滚动条的表头 + 正文 + 冻结列三份）与列宽实测，是另一个量级的
/// 复杂度，而它解决的是「列很多的大表」这个 20MB 预览上限之外的场景。
/// 首行当表头也不猜 —— 猜错比不猜更让人困惑（见 [CsvCodec] 文件头）。
class CsvViewerScreen extends StatefulWidget {
  const CsvViewerScreen({super.key, required this.path, this.title});

  final String path;
  final String? title;

  @override
  State<CsvViewerScreen> createState() => _CsvViewerScreenState();
}

class _CsvViewerScreenState extends State<CsvViewerScreen> {
  CsvDocument? _doc;
  DecodedText? _decoded;

  /// 读不出来时的原因：见 [_ViewerError]。
  String? _error;

  @override
  void initState() {
    super.initState();
    // 与文本预览同一套理由：这条链路上 `readBytes` 是同步读、
    // `CsvCodec.parse` 是纯计算，都放 `initState` 里会把首帧一起卡住。
    // 这里排的是**宏任务**（timer）—— `Future.microtask` 会在当前帧结束前
    // 就跑掉，等于没推迟。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>(_load);
    });
  }

  Future<void> _load() async {
    final bytes = LocalFile.readBytes(
      widget.path,
      maxBytes: AppDefaults.attachmentPreviewLimit,
    );
    if (!mounted) return;
    if (bytes == null) {
      // 区分两种 null，**按长度判**而不是「还在不在」：文件在、但读的时候
      // 刚被别处删掉，也会走到这里，那时说一句「太大了」是在骗人。
      // 前者用户要重新下载，后者只要「用其他应用打开」就行 ——
      // 同一句话描述不了这两件事。
      final size = LocalFile.length(widget.path);
      setState(() {
        _error = size > AppDefaults.attachmentPreviewLimit
            ? _ViewerError.tooLarge
            : _ViewerError.gone;
      });
      return;
    }

    // CSV 的解码与 `.txt` 走**同一条**兜底链（BOM → 严格 UTF-8 → GB18030
    // → 宽容 UTF-8）。国内导出的 CSV 里 GBK 很常见，这一条不能省。
    final decoded = decodeText(bytes);
    final doc = CsvCodec.parse(decoded.text);

    if (!mounted) return;
    setState(() {
      _decoded = decoded;
      _doc = doc;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final doc = _doc;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? l10n.preview,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: switch ((_error, doc)) {
        (final String reason, _) => _Message.forError(reason, l10n),
        // 空文件：一句「（空文件）」比一张只有表头的空表格诚实。
        (_, final CsvDocument d) when d.isEmpty =>
          _Message(icon: Icons.table_chart_outlined, text: l10n.viewerEmpty),
        (_, final CsvDocument d) => _table(d, _decoded!, l10n),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _table(CsvDocument doc, DecodedText decoded, AppLocalizations l10n) {
    return Column(
      children: <Widget>[
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cellWidth = _cellWidth(constraints.maxWidth);
              // 列数可能少于 `columns`（某一行短几格）—— 显示时补齐，
              // 但**只在显示这一层**：`CsvDocument.rows` 保持原样（见
              // `CsvCodec` 文件头，补空等于伪造数据）。
              final width = cellWidth * doc.columns;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width < constraints.maxWidth
                      ? constraints.maxWidth
                      : width,
                  child: Column(
                    children: <Widget>[
                      _Row(
                        cells: doc.header,
                        columns: doc.columns,
                        cellWidth: cellWidth,
                        header: true,
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: doc.body.length,
                          itemBuilder: (_, index) => _Row(
                            cells: doc.body[index],
                            columns: doc.columns,
                            cellWidth: cellWidth,
                            header: false,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        _Footer(
          notes: <String>[
            if (doc.truncated)
              l10n.csvTruncated(CsvCodec.maxRows, CsvCodec.maxColumns),
            l10n.csvDelimiter(doc.delimiterLabel),
            if (decoded.isLossy) l10n.viewerEncodingLossy(decoded.encoding),
          ],
        ),
      ],
    );
  }

  /// 单元格宽度。
  ///
  /// 240pt 在桌面上正好够看一到两个词；手机上（可用宽度 400 上下）240 就是
  /// 大半屏，一屏只放得下一列多，横向滚动会变成主要操作。所以窄屏按
  /// 「一屏两列半」缩，下限 140（再窄就看不出列的形状了）。
  static double _cellWidth(double available) =>
      (available / 2.5).clamp(140.0, 240.0);
}

/// 一行的固定高度 —— 两行文字（13pt，高 1.35）加一点内边距。
const double _rowHeight = 46;

/// 表格里的一行。
class _Row extends StatelessWidget {
  const _Row({
    required this.cells,
    required this.columns,
    required this.cellWidth,
    required this.header,
  });

  final List<String> cells;
  final int columns;
  final double cellWidth;
  final bool header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _rowHeight,
      child: Row(
        children: List<Widget>.generate(columns, (index) {
          final value = index < cells.length ? cells[index] : '';
          return _Cell(
            value: value,
            width: cellWidth,
            header: header,
            theme: theme,
          );
        }),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.value,
    required this.width,
    required this.header,
    required this.theme,
  });

  final String value;
  final double width;
  final bool header;
  final ThemeData theme;

  /// 点开看全文。
  ///
  /// 只有**截断过**的单元格才弹：弹出框是模态的，两个字符的「是」也弹一下
  /// 就成了纯粹的打扰。判据用 `TextPainter` 实测过的行数，比按字符数估准。
  void _showFull(BuildContext context, bool truncated) {
    if (!truncated) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final dialogL10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(
            dialogL10n.preview,
            style: const TextStyle(fontSize: 14),
          ),
          content: SingleChildScrollView(
            // 全文可以选中：这张表里最可能被复制的就是「完整的那串 ID」。
            child: SelectionArea(child: Text(value)),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(dialogL10n.close),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final style = (header
            ? theme.textTheme.labelMedium
            : theme.textTheme.bodySmall)
        ?.copyWith(
      fontWeight: header ? FontWeight.w600 : null,
      height: 1.35,
    );

    // 溢出与否只能靠排版算出来（`maxLines: 2` 是排完才知道切没切）。
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      maxLines: 2,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width - 16);
    final truncated = painter.didExceedMaxLines;

    return InkWell(
      onTap: truncated ? () => _showFull(context, true) : null,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: header ? scheme.surfaceContainerHighest : null,
          border: Border(
            right: BorderSide(color: scheme.outlineVariant, width: 0.5),
            bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            // 两行而不是一行：一份表里最常见的列（名字、地址、描述）一行放不下，
            // 两行能让「需要点开」的比例显著下降。
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ),
    );
  }
}

/// 底部那一条说明。任何一条都没有时不占位置。
class _Footer extends StatelessWidget {
  const _Footer({required this.notes});

  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        notes.join(' · '),
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 读不出来 / 没内容时的整页提示。
class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  factory _Message.forError(String reason, AppLocalizations l10n) {
    return switch (reason) {
      _ViewerError.tooLarge => _Message(
          icon: Icons.file_present_outlined,
          text: l10n.previewUnsupported,
        ),
      _ => _Message(icon: Icons.error_outline, text: l10n.viewerFileGone),
    };
  }

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

abstract final class _ViewerError {
  static const String gone = 'gone';
  static const String tooLarge = 'tooLarge';
}
