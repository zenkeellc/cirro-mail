import 'package:flutter/material.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/storage/local_file.dart';
import '../../../l10n/app_localizations.dart';
import '../codecs/doc_model.dart';
import '../codecs/docx.dart';
import '../codecs/ooxml.dart';
import 'doc_blocks_view.dart';

/// `.docx` 附件的预览。
///
/// 只吃**本地路径**（调用方先 `ensureLocal`）—— 和另外几个 viewer 一致。
///
/// ## 这是个「能看内容」的预览
///
/// 解析器只认识段落、行内样式与表格（见 `docx.dart`）。图片 / 图形 / 公式 /
/// 文本框 / 页眉页脚 / 精确版式一律不显示 —— 界面上会有两处说明：
/// 正文里图片的位置是 `[图片]` 占位（在内容该在的地方），页脚那条说明
/// 「图片与版式未显示」告诉用户**整份文档**少了些什么。两处都要有：
/// 只给占位，用户不知道是「这里没有图」还是「所有图都没画」。
class DocxViewerScreen extends StatefulWidget {
  const DocxViewerScreen({
    super.key,
    required this.path,
    this.title,
    this.embedded = false,
  });

  final String path;
  final String? title;

  /// 嵌在分栏右栏里（附件缓存页宽屏的右栏，见 `attachment_cache_screen.dart` 的 `_AttachmentPreview`），而不是 push 上来的整页。
  /// 差别只有一处：不自己撑 `Scaffold` / `AppBar`。正文与页脚照旧。
  final bool embedded;

  @override
  State<DocxViewerScreen> createState() => _DocxViewerScreenState();
}

class _DocxViewerScreenState extends State<DocxViewerScreen> {
  List<DocBlock>? _blocks;

  /// 见 [_OfficeError]。
  String? _error;

  @override
  void initState() {
    super.initState();
    // 与其它 viewer 同一套：读盘与解析都是同步的，放 `initState` 里会把
    // 首帧一起卡住。这里排的是**宏任务**（timer）—— `Future.microtask`
    // 会在当前帧结束前就跑掉，等于没推迟。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>(_load);
    });
  }

  Future<void> _load() async {
    final bytes = LocalFile.readBytes(
      widget.path,
      // 整份解析：截一半的 zip 一定解不开，与其给一个残缺的结果，
      // 不如在这里就判掉（超限的附件本来就不该走到这个页面 ——
      // 面板那一侧已经用 `canPreview` 挡过一道，这里是第二道）。
      maxBytes: AppDefaults.attachmentPreviewLimit,
    );
    if (!mounted) return;
    if (bytes == null) {
      setState(() {
        _error = LocalFile.length(widget.path) >
                AppDefaults.attachmentPreviewLimit
            ? _OfficeError.tooLarge
            : _OfficeError.gone;
      });
      return;
    }

    final result = DocxCodec.parse(bytes);
    if (!mounted) return;
    final blocks = result.valueOrNull;
    setState(() {
      _blocks = blocks;
      _error = blocks == null ? _OfficeError.forFailure(result.failureOrNull) : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final blocks = _blocks;

    final body = switch ((_error, blocks)) {
      (final String reason, _) => OfficeErrorView(reason: reason),
      (_, final List<DocBlock> list) => Column(
          children: <Widget>[
            Expanded(child: DocBlocksView(blocks: list)),
            OfficeFooter(
              notes: <String>[l10n.viewerOfficePartial],
            ),
          ],
        ),
      _ => const Center(child: CircularProgressIndicator()),
    };
    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? l10n.preview,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: body,
    );
  }
}

/// 读不出来时的原因。**分得开很重要**：「不是 Word 文档」「文档坏了」
/// 「太大了」「文件没了」四句话对用户意味着四种完全不同的下一步。
abstract final class _OfficeError {
  static const String gone = 'gone';
  static const String tooLarge = 'tooLarge';

  static String forFailure(ParseFailure? failure) => switch (failure) {
        ParseFailure.notAPackage => 'notAPackage',
        ParseFailure.missingPart => 'missingPart',
        ParseFailure.malformed => 'malformed',
        ParseFailure.tooLarge => tooLarge,
        null => gone,
      };
}

/// 四种失败原因 → 四句话。
///
/// 做成公开 widget 是因为 xlsx / pptx 两个 viewer 要用同一份 ——
/// 三处各写一遍迟早会出现「同一个坏文件在三个页面说三种话」。
class OfficeErrorView extends StatelessWidget {
  const OfficeErrorView({super.key, required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (icon, text) = switch (reason) {
      'notAPackage' => (Icons.description_outlined, l10n.viewerNotADocument),
      'missingPart' || 'malformed' => (
          Icons.broken_image_outlined,
          l10n.viewerDocumentBroken,
        ),
      'tooLarge' => (Icons.file_present_outlined, l10n.previewUnsupported),
      _ => (Icons.error_outline, l10n.viewerFileGone),
    };

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

/// viewer 底部那一条说明（可能有好几条）。
class OfficeFooter extends StatelessWidget {
  const OfficeFooter({super.key, required this.notes});

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
