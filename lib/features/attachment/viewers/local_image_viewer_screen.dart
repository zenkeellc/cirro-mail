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
  });

  final String path;
  final String? title;

  @override
  Widget build(BuildContext context) {
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
      body: PhotoView(
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
      ),
    );
  }
}
