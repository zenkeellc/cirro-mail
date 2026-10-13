import 'package:flutter/material.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/storage/local_file.dart';
import '../../../l10n/app_localizations.dart';
import '../codecs/ooxml.dart';
import '../codecs/pptx.dart';
import 'doc_blocks_view.dart';
import 'docx_viewer_screen.dart' show OfficeErrorView, OfficeFooter;

/// `.pptx` 附件的预览：一页一张纯文本卡片。
///
/// 只吃**本地路径**（调用方先 `ensureLocal`）—— 和另外几个 viewer 一致。
///
/// ## 读之前先说清这是「能读内容」而不是「能看幻灯片」
///
/// 一份演示文稿的信息量有一大半在版式里（谁大谁小、谁在左上角、配图与
/// 配色），而这一版只抽文字（见 `pptx.dart` 里的取舍说明）。所以：
/// **页头只写「第 N 页 / 共 M 页」**，不去模仿幻灯片的比例与留白 ——
/// 画一个 16:9 的空框再把字塞进去，只会让人以为「这页怎么这么空」。
///
/// 页头带页码，是为了能跟旁边开着 PowerPoint 的同事对上话：
/// 「你翻到第 3 页」在这里点得准。
///
/// ## 不做全屏、翻页动画、缩略图栏
///
/// 这不是放映器。列表滚动本身就是翻页，而缩略图需要先把每页渲染一遍
/// 才有图可缩 —— 那是把整套版式渲染实现了才划算的事。
class PptxViewerScreen extends StatefulWidget {
  const PptxViewerScreen({super.key, required this.path, this.title});

  final String path;
  final String? title;

  @override
  State<PptxViewerScreen> createState() => _PptxViewerScreenState();
}

class _PptxViewerScreenState extends State<PptxViewerScreen> {
  Presentation? _presentation;

  /// 见 [OfficeErrorView] 的 `reason`。
  String? _error;

  @override
  void initState() {
    super.initState();
    // 与 docx / xlsx viewer 同一套：读盘与解析都放 `initState` 里会把首帧
    // 一起卡住。排的是**宏任务**（timer）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>(_load);
    });
  }

  Future<void> _load() async {
    final bytes = LocalFile.readBytes(
      widget.path,
      // 整份解析：截一半的 zip 一定解不开（同另两个 office viewer）。
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

    final result = PptxCodec.parse(bytes);
    if (!mounted) return;
    final presentation = result.valueOrNull;
    setState(() {
      _presentation = presentation;
      _error = presentation == null
          ? switch (result.failureOrNull) {
              ParseFailure.notAPackage => 'notAPackage',
              ParseFailure.missingPart => 'missingPart',
              ParseFailure.malformed => 'malformed',
              ParseFailure.tooLarge => 'tooLarge',
              null => 'gone',
            }
          : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final presentation = _presentation;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? l10n.preview,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: switch ((_error, presentation)) {
        (final String reason, _) => OfficeErrorView(reason: reason),
        (_, final Presentation deck) => _deck(deck, l10n),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _deck(Presentation deck, AppLocalizations l10n) {
    final total = deck.slides.length;
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: total,
            itemBuilder: (context, index) => _SlideCard(
              slide: deck.slides[index],
              total: total,
              l10n: l10n,
            ),
          ),
        ),
        OfficeFooter(
          notes: <String>[
            if (deck.truncated) l10n.pptxSlidesTruncated(PptxCodec.maxSlides),
            l10n.pptxPartial,
          ],
        ),
      ],
    );
  }
}

/// 一页幻灯片。
class _SlideCard extends StatelessWidget {
  const _SlideCard({
    required this.slide,
    required this.total,
    required this.l10n,
  });

  final Slide slide;
  final int total;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              l10n.pptxSlideOf(slide.index, total),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          if (slide.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.pptxSlideEmpty,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          else
            // 用与 docx 正文**同一个**渲染器：标题字号、项目符号缩进、
            // 表格边框这些只写一份（见 [DocBlocksView] 的类注释）。
            DocBlocksView(
              blocks: slide.blocks,
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            ),
        ],
      ),
    );
  }
}
