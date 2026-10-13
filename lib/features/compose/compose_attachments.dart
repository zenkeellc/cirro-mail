import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';

import '../../core/storage/local_file.dart';
import '../../data/models/send_payload.dart';

/// 选附件：`file_picker` → [SendAttachment] 的唯一入口。
///
/// 三条刻意的做法：
///
/// 1. **只要路径，不要字节**。发送链路本来就是流式读盘的（见
///    `stream_body_builder.dart`），在选文件这一步先把几十 MB 拉进内存
///    再交给它，等于把那个优化抵掉了。所以只从 `PlatformFile.path` 拿路径。
/// 2. **大小从磁盘现问**。`PlatformFile.length()` 在某些平台返回 null，
///    那就退回 `XFile.length()`；`size` 是总量上限与 base64 长度的计算依据，
///    不能猜 —— 猜错会让流式 body 的 `Content-Length` 跟着一起算错。
/// 3. **数量与体积不在这里判**。这里只负责把文件描述出来，
///    超限要一次性告诉用户（`ComposeController` 的 `problems`），
///    而不是在选文件的对话框里一条一条弹。
abstract final class ComposeAttachments {
  const ComposeAttachments._();

  /// 弹系统文件选择器。[dialogTitle] 由调用方本地化。
  ///
  /// 用户取消时返回空列表（`file_picker` 13 的 `pickFiles` 返回 `List`，
  /// 取消是空列表而不是 null）。
  static Future<List<SendAttachment>> pick({String? dialogTitle}) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      type: FileType.any,
    );
    return fromPlatformFiles(picked);
  }

  /// 把 `file_picker` 的结果转成发送用的附件描述。
  ///
  /// 抽出来是为了可测：单测里构造不出真的系统对话框，但可以直接喂
  /// `PlatformFile`。
  static Future<List<SendAttachment>> fromPlatformFiles(
    List<PlatformFile> files,
  ) async {
    final result = <SendAttachment>[];
    for (final file in files) {
      final path = file.path;
      // 没有路径就拿不到「发送时才读」的那个文件，这条只能跳过 ——
      // 放进列表只会在发送时变成一条莫名其妙的失败。
      if (path == null || path.isEmpty) continue;

      final size = await _sizeOf(file, path);
      // 大小拿不到（平台不给、文件已经没了）同样跳过：`SendAttachment.size`
      // 参与总量校验与 base64 长度预算，猜一个数会让两者都算错。
      if (size == null) continue;

      result.add(
        SendAttachment(
          path: path,
          filename: _filename(file, path),
          size: size,
          mimeType: _guessMime(path),
        ),
      );
    }
    return result;
  }

  /// 大小优先问 `file_picker`，它没给（或给了 0）就去问磁盘。
  ///
  /// 两个来源都拿不到有效值时返回 null，调用方会跳过这个文件 ——
  /// `SendAttachment.size` 同时参与总量校验与流式 body 的 `Content-Length`
  /// 预算，猜一个数会让两者一起算错，而算错 `Content-Length` 的后果是
  /// 请求在服务端被截断，报出来的错和真正的原因毫无关系。
  static Future<int?> _sizeOf(PlatformFile file, String path) async {
    final declared = await file.length();
    if (declared != null && declared > 0) return declared;
    final onDisk = LocalFile.length(path);
    if (onDisk > 0) return onDisk;
    return declared;
  }

  /// 从**已有的路径**建附件（桌面拖放用）。
  ///
  /// 与 [fromPlatformFiles] 是同一条规矩：文件名从路径取、MIME 从路径猜、
  /// 大小从盘上现问。**读不出大小就跳过** —— 与选择器那条路一致，让
  /// 「0 字节的附件」永远进不来（`SendAttachment.size` 是要拿去算 base64
  /// 膨胀的，见它的 `base64Length`）。
  static Future<List<SendAttachment>> fromPaths(List<String> paths) async {
    final out = <SendAttachment>[];
    for (final path in paths) {
      if (path.isEmpty) continue;
      final size = await _sizeOfPath(path);
      if (size == null || size == 0) continue;
      out.add(SendAttachment(
        path: path,
        filename: _filenameFromPath(path),
        size: size,
        mimeType: lookupMimeType(path) ?? 'application/octet-stream',
      ));
    }
    return out;
  }

  /// 从盘上问长度。`LocalFile.length` 读不到（文件没了 / 没权限）给 0。
  ///
  /// `LocalFile.length` 是**同步**的（返回 `int`，不是 `Future`）—— 与
  /// `_sizeOf` 里那一处的用法一致。计划原文写的是 `await LocalFile.length`，
  /// 按仓库实际去掉 `await`（保留了 `async` 外壳，调用点不用改）。
  static Future<int?> _sizeOfPath(String path) async {
    try {
      final length = LocalFile.length(path);
      return length <= 0 ? null : length;
    } catch (_) {
      return null;
    }
  }

  /// 路径的最后一段。桌面端 `DropItem.name` 与它一致，但**别依赖那个** ——
  /// 这个助手只拿到路径。
  static String _filenameFromPath(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }

  static String _filename(PlatformFile file, String path) {
    if (file.name.isNotEmpty) return file.name;
    final separator = path.contains('\\') ? '\\' : '/';
    final index = path.lastIndexOf(separator);
    return index >= 0 ? path.substring(index + 1) : path;
  }

  static String _guessMime(String path) =>
      lookupMimeType(path) ?? 'application/octet-stream';
}
