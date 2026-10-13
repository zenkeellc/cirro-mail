import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter/widgets.dart' show TextSelection;
import 'package:mime/mime.dart';

import 'embed_line_break.dart';

/// 内联图片的**插入**：来源是粘贴的位图、拖进来的文件、或文件选择器选的图。
///
/// 三条必须守住的规则：
/// 1. 一律转成 `data:image/...;base64,...` —— 服务端 `toImageUrlHtml`
///    （`mail-worker/src/service/att-service.js:50`）就是靠这个前缀认出内联图、
///    改写成 `cid:` 内嵌附件的（spec §1.3）。**本地不要自己转成 URL**，
///    那会绕开 cid 内嵌。
/// 2. 内嵌图额度 10 张（`SendPayload.validate`）。超了要**在插入前**拦住，
///    并在界面上说清「已用几张」。
/// 3. 单张图的大小上限（这里是 5 MB）：base64 之后约涨 1/3，而整封信的总量
///    上限是 20 MB，一张超大图会把额度一次吃光。
abstract final class ImageInsert {
  const ImageInsert._();

  /// 内嵌图上限。与 `SendPayload.validate` 的 `maxInlineImages` 保持一致 ——
  /// 改了这里必须一起改那里。
  static const int maxInlineImages = 10;

  /// 单张图上限。
  static const int maxBytes = 5 * 1024 * 1024;

  /// 允许内联的图片类型。**只认这几种** —— `image/svg+xml` 不在内是因为
  /// 邮件客户端对 SVG 的支持极不一致，而且 SVG 可以带脚本。
  static const List<String> allowedMime = [
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/bmp',
  ];

  /// 字节 → `data:` URI。类型认不出来时按 png 处理（用户拖进来的多半是截图）。
  static String toDataUri(Uint8List bytes, {String? mimeType}) {
    final mime = (mimeType != null && allowedMime.contains(mimeType))
        ? mimeType
        : 'image/png';
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  /// 一个文件该不该**内联进正文**（而不是当附件）。
  ///
  /// 判据是「它是不是图片」—— 这是 spec §5.3 的决定：拖进来的图片，用户的
  /// 意图是让它出现在正文里；其他文件进附件 chips。
  static bool isInlineImage({required String? mimeType, required String name}) {
    final mime = mimeType ?? lookupMimeType(name);
    return mime != null && allowedMime.contains(mime);
  }

  /// 现在还能插几张。约束是**两个**：张数与总大小。
  static int remainingSlots(int used) =>
      used >= maxInlineImages ? 0 : maxInlineImages - used;

  /// 能不能再插这一张。[used] 是当前已用的张数，[bytes] 是这张的大小。
  static ImageInsertDecision canInsert({
    required int used,
    required int bytes,
  }) {
    if (bytes > maxBytes) return ImageInsertDecision.tooLarge;
    if (remainingSlots(used) <= 0) return ImageInsertDecision.tooMany;
    return ImageInsertDecision.ok;
  }

  /// 把一张 `data:` 图片插到光标处。返回 false 表示额度/大小不够，没插。
  static bool insertDataImage(
    q.QuillController controller, {
    required String dataUri,
    required int used,
    required int byteLength,
  }) {
    if (canInsert(used: used, bytes: byteLength) != ImageInsertDecision.ok) {
      return false;
    }
    // **偏移要夹取**：`Document.length` 含末尾那个 `\n`，合法内容偏移的
    // 上界是 `length - 1`；而 `extentOffset` 在选区贴到文末时**会等于
    // `length`**。不夹的话 `_breakLineAt` 里 `indexOf('\n', cursor)` 返回 -1、
    // `lineEnd = plain.length`，`replaceText` 就落到文档之外，
    // `container.dart:137` 的断言直接炸（F-3：该文档长度下 10/23 个位置会抛）。
    final maxOffset = controller.document.length - 1;
    var at = controller.selection.isValid
        ? controller.selection.extentOffset.clamp(0, maxOffset < 0 ? 0 : maxOffset)
        : (maxOffset < 0 ? 0 : maxOffset);
    // **先腾出一整行**，见 [EmbedLineBreak.at] 的说明 —— 直接把嵌入塞进行中间
    // 会得到「￼跟着半行文字」的一行，flutter_quill 渲染时就崩。
    at = EmbedLineBreak.at(controller, at);
    controller.replaceText(
      at,
      0,
      q.BlockEmbed.image(dataUri),
      TextSelection.collapsed(offset: at + 1),
    );
    return true;
  }

  /// 从磁盘读一个图片文件并转成 `data:` URI。读不出来（不存在、太大、
  /// 不是图片）返回 null —— 调用方据此提示用户，而不是崩。
  static Future<String?> readFileAsDataUri(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) return null;
    final mime = lookupMimeType(path, headerBytes: bytes.take(12).toList());
    if (mime == null || !allowedMime.contains(mime)) return null;
    return toDataUri(bytes, mimeType: mime);
  }

  /// 数一份 Delta 里现有的内联图张数（用于额度提示与发送前校验）。
  static int countInlineImages(List<dynamic> delta) {
    var count = 0;
    for (final op in delta) {
      if (op is! Map) continue;
      final insert = op['insert'];
      if (insert is Map && insert.containsKey(q.BlockEmbed.imageType)) {
        final src = insert[q.BlockEmbed.imageType];
        if (src is String && src.startsWith('data:image')) count++;
      }
    }
    return count;
  }
}

enum ImageInsertDecision { ok, tooLarge, tooMany }
