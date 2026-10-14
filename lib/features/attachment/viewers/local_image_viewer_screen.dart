import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

/// 本地图片附件的全屏预览（已下载到磁盘的那份）。
///
/// 与 [ImageViewerScreen]（正文内嵌图，数据源是远程 URL）分开：
/// 那个走 `cached_network_image` 自己管缓存，这个用的是附件缓存目录里的文件
/// —— 两者共用一套逻辑会让「附件已下载但预览时又去打网络」这种怪事发生。
class LocalImageViewerScreen extends StatelessWidget {
  const LocalImageViewerScreen({
    super.key,
    required this.path,
    this.title,
    this.embedded = false,
  });

  final String path;
  final String? title;

  /// 嵌在分栏右栏里（附件缓存页宽屏的右栏，见 `attachment_cache_screen.dart` 的 `_AttachmentPreview`），而不是 push 上来的整页。
  /// 差别只有一处：不自己撑 `Scaffold` / `AppBar` —— 宿主已经给了一个头，
  /// 这里再来一条就是两条。黑底与 `PhotoView` 那套照旧。
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    // `Scaffold` 那一层还带着黑底：整页形态下窗口留白（比如图片比窗口矮）
    // 也该是黑的。
    final body = PhotoView(
      imageProvider: FileImage(File(path)),
      backgroundDecoration: const BoxDecoration(color: Colors.black),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 4,
      errorBuilder: (context, error, stackTrace) => const Center(
        child: Text(
          '图片打不开',
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );

    if (embedded) {
      return ColoredBox(color: Colors.black, child: body);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          title ?? '',
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: body,
    );
  }
}
