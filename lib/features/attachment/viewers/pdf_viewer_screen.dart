import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

/// PDF 附件预览。
///
/// 用 `PdfViewPinch`（缩放/拖动）而不是 `PdfView`（逐页翻）：
/// 邮件附件多是合同、发票、登机牌这类**单页或短文档**，连续滚动比
/// 一页一页翻更自然；`PdfViewPinch` 也顺带给了双指缩放。
///
/// 只接受**本地路径**：`PdfDocument.openFile` 是唯一稳定的入口，
/// 而 `openData` 要把整个 PDF 读进内存（大 PDF 会直接 OOM）。
/// 调用方（`attachment_sheet`）保证先下载再进来。
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.path,
    this.title,
    this.embedded = false,
  });

  final String path;
  final String? title;

  /// 嵌在分栏右栏里（附件缓存页宽屏的右栏，见 `attachment_cache_screen.dart` 的 `_AttachmentPreview`），而不是 push 上来的整页。
  ///
  /// 差别是两处：不自己撑 `Scaffold` / `AppBar`；以及 `AppBar` 底下那行
  /// 「N 页」**挪到页脚**—— 它是这一页唯一独占的信息，跟着头一起消失就没了。
  final bool embedded;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  late final PdfControllerPinch _controller = PdfControllerPinch(
    document: _open(),
  );
  int _pages = 0;
  String? _error;

  Future<PdfDocument> _open() async {
    try {
      final document = await PdfDocument.openFile(widget.path);
      if (mounted) {
        setState(() {
          _pages = document.pagesCount;
          _error = null;
        });
      }
      return document;
    } catch (e) {
      // 走到这里多半不是「PDF 坏了」而是「压根不是 PDF」
      // （服务端返回了别的东西、或文件被系统清掉了）。
      if (mounted) setState(() => _error = '$e');
      rethrow;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;

    final viewer = error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.picture_as_pdf_outlined, size: 48),
                  const SizedBox(height: 16),
                  const Text('PDF 打不开'),
                  const SizedBox(height: 8),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          )
        : PdfViewPinch(
            controller: _controller,
            builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
              options: const DefaultBuilderOptions(),
              documentLoaderBuilder: (_) => const Center(
                child: CircularProgressIndicator(),
              ),
              pageLoaderBuilder: (_) => const Center(
                child: CircularProgressIndicator(),
              ),
            ),
          );

    if (widget.embedded) {
      // 页数还没解出来（`_open` 是异步的）时那一条先不出现 —— 一条
      // 「0 页」比没有更糟。
      if (_pages <= 0) return viewer;
      return Column(
        children: <Widget>[
          Expanded(child: viewer),
          _PageCountFooter(pages: _pages),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? 'PDF',
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        bottom: _pages > 0
            ? PreferredSize(
                preferredSize: const Size.fromHeight(18),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '$_pages 页',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              )
            : null,
      ),
      body: viewer,
    );
  }
}

/// 内嵌形态底下的「N 页」条（整页形态下这一行在 `AppBar.bottom` 里）。
class _PageCountFooter extends StatelessWidget {
  const _PageCountFooter({required this.pages});

  final int pages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        '$pages 页',
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
