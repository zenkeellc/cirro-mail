import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';

/// 正文内嵌图 / 图片附件的全屏预览。
///
/// 数据源直接用 URL 而不是先落盘：内嵌图的地址是 `/api/oss/<key>`（免鉴权），
/// `cached_network_image` 会自己管磁盘缓存，没必要先在附件缓存目录里再存一份
/// —— 那样同一张图会有两份缓存，清理时还得管两处。
///
/// 缩放交给 `photo_view`，与 Web 端的 `el-image-viewer` 行为对齐。
class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({
    super.key,
    required this.url,
    this.title,
  });

  final String url;

  /// 顶栏标题（一般是附件名）。
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          title ?? '图片',
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '复制链接',
            icon: const Icon(Icons.link),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制图片链接')),
              );
            },
          ),
        ],
      ),
      body: PhotoView(
        imageProvider: CachedNetworkImageProvider(url),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        loadingBuilder: (context, event) => const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
        // `errorBuilder` 的签名在 photo_view 各版本间变过，用 builder 形态
        // 最稳：拿不到 imageProvider 就渲染自己的错误态。
        errorBuilder: (context, error, stackTrace) => _Failed(url: url),
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.broken_image_outlined, color: Colors.white70, size: 48),
            const SizedBox(height: 16),
            const Text(
              '图片加载失败',
              style: TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              url,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
