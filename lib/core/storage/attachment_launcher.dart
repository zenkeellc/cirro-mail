import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// 把一个**已经在磁盘上**的文件交给操作系统。
///
/// 与 [AttachmentRepository] 的分工：那边负责「字节落盘」，这里负责
/// 「落盘之后拿它怎么办」—— 打开、分享、另存为。分开是因为这一层的
/// 依赖（`open_filex` / `share_plus` / `file_picker`）会拉起原生活动或
/// 系统对话框，而下载逻辑需要能在后台（无 UI）跑。
abstract final class AttachmentLauncher {
  /// 用系统关联的应用打开。
  ///
  /// Linux 上没有 `open_filex` 的实现，退回 `url_launcher` 的 `file://`
  /// —— 桌面发行版一般会交给 xdg-open。
  static Future<bool> open(String path, {String? mimeType}) async {
    if (path.isEmpty) return false;
    if (Platform.isLinux) {
      return launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);
    }
    final result = await OpenFilex.open(path, type: mimeType);
    return result.type == ResultType.done;
  }

  /// 拉起系统分享面板。
  ///
  /// [origin] 是 iPad / macOS 上分享气泡的锚点（不传会在 iPad 上崩），
  /// 由调用方从 widget 的 `RenderBox` 算出来。
  static Future<bool> share({
    required List<String> paths,
    String? subject,
    String? text,
    Rect? origin,
  }) async {
    final files = <XFile>[
      for (final path in paths)
        if (path.isNotEmpty) XFile(path),
    ];
    if (files.isEmpty) return false;
    final result = await SharePlus.instance.share(
      ShareParams(
        files: files,
        subject: subject,
        text: text,
        sharePositionOrigin: origin,
      ),
    );
    // `unavailable` 表示当前环境没有分享面板（部分桌面发行版）——
    // 调用方据此提示用户改用「打开」或「另存为」。
    return result.status != ShareResultStatus.unavailable;
  }

  /// 另存为到用户自选的位置。返回保存到哪了（用户取消时返回 null）。
  ///
  /// 两条路径，**按平台分**而不是图省事都用一条：
  ///
  /// - **桌面**：`getDirectoryPath()` 选目录，再用 [File.copy] 复制。
  ///   `File.copy` 是流式的，15 MB 的附件不会整份进内存；
  ///   而 `FilePicker.saveFile` 的签名要求 `Uint8List bytes` ——
  ///   它把整个文件读进内存，桌面端没必要付这个代价。
  /// - **移动端**：必须用 `saveFile`。Android 的 SAF 目录选择器返回的是
  ///   `content://` URI，拿到目录路径也没法直接写着色；`saveFile` 让系统
  ///   自己把字节写进用户选的位置（相册/文件 App/下载目录）。
  static Future<String?> saveAs({
    required String sourcePath,
    required String suggestedName,
    String mimeType = 'application/octet-stream',
    String? dialogTitle,
  }) async {
    if (sourcePath.isEmpty) return null;
    final source = File(sourcePath);
    if (!await source.exists()) return null;

    if (_isDesktop) {
      final directory = await FilePicker.getDirectoryPath(
        dialogTitle: dialogTitle,
      );
      if (directory == null || directory.isEmpty) return null;
      final target = _uniqueTarget(directory, suggestedName);
      await source.copy(target);
      return target;
    }

    final uri = await FilePicker.saveFile(
      fileName: suggestedName,
      bytes: await source.readAsBytes(),
      mimeType: mimeType,
      dialogTitle: dialogTitle,
    );
    return uri?.toString();
  }

  /// 同名时加序号，**不覆盖**用户已有的文件 —— 另存为的语义是
  /// 「放在这儿」，不是「替换掉这儿的东西」。
  static String _uniqueTarget(String directory, String filename) {
    final separator = Platform.pathSeparator;
    final dot = filename.lastIndexOf('.');
    final stem = dot > 0 ? filename.substring(0, dot) : filename;
    final ext = dot > 0 ? filename.substring(dot) : '';

    var candidate = '$directory$separator$filename';
    var index = 2;
    while (File(candidate).existsSync() && index < 1000) {
      candidate = '$directory$separator$stem ($index)$ext';
      index++;
    }
    return candidate;
  }

  static bool get _isDesktop => !kIsWeb &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
}
