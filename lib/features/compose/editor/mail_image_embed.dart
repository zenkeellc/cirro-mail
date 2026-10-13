import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

import 'image_actions.dart' show EmbedTapCallback;

/// 内联图片的**渲染**。
///
/// 为什么自写而不引 `flutter_quill_extensions`：那个包 11.0.0 之后没再发版，
/// 而它声明的 `flutter_quill: ^11.0.0` 与本项目锁的 11.6.0 之间隔着若干次
/// EmbedBuilder 接口调整。图片嵌入要的能力很窄（认 `data:` 与 http 两种 src），
/// 自写三十行比升一个不确定的包便宜。
class MailImageEmbedBuilder extends q.EmbedBuilder {
  const MailImageEmbedBuilder({this.onImageTap});

  /// 点一张正文里的图时回调，参数是**这个嵌入在当前文档里的偏移**。
  /// **为空 = 不可点**（收信侧渲染的图就不该点）。
  ///
  /// 偏移由 `embedContext.node.documentOffset` 现算（`node.dart:88`，沿
  /// `parent` 链路算），所以它**属于 build 那一帧**；点击回调里拿到它时
  /// 文档可能已经变了 —— 调用方要拿 [imageOffsets] 复核一次。
  final EmbedTapCallback? onImageTap;

  @override
  String get key => q.BlockEmbed.imageType;

  /// 纯文本摘要里图片的位置 —— 用「[图片]」而不是 emoji，因为 `SendPayload.text`
  /// 会进对方客户端的预览行，那里不该出现符号。
  @override
  String toPlainText(q.Embed node) => '[图片]';

  @override
  Widget build(BuildContext context, q.EmbedContext embedContext) {
    final source = embedContext.node.value.data;
    if (source is! String || source.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return MailImage(
      source: source,
      // 偏移在**这一帧**算好、绑进闭包；点下去时拿到的就是「点的是哪一张」，
      // 不用去猜「离光标最近的那张」。
      onImageTap: onImageTap == null
          ? null
          : () => onImageTap!(embedContext.node.documentOffset),
    );
  }
}

/// 一张内联图。**两种 src 都要认**：
/// - `data:image/...;base64,...` —— 粘贴/拖入的图就长这样（服务端会把它转成
///   规范的 MIME 内嵌附件，见 spec §1.3）；
/// - `http(s)://...` —— 从网页复制过来的图，以及**收到的**转发内容里的图。
class MailImage extends StatelessWidget {
  const MailImage({
    super.key,
    required this.source,
    this.maxWidth = 480,
    this.onImageTap,
  });

  final String source;

  /// 正文里的图不该撑破页面。给一个上限，并保持比例。
  final double maxWidth;

  /// 点这张图。**为空时不可点** —— 收信侧渲染的图（只读视图）就不该点。
  ///
  /// 为空时**连一层 `GestureDetector` 都不加**：这条渲染路径同时也给只读
  /// 视图用，多包一层会悄悄改变它的命中行为（比如把整块矩形变成「吞掉点击」
  /// 的区域，压掉底下选区的拖选）。
  final VoidCallback? onImageTap;

  @override
  Widget build(BuildContext context) {
    final child = _content(context);
    if (onImageTap == null) return child;
    // **包在最外层**（`ConstrainedBox` 之外）：把 `GestureDetector` 包在里层
    // 时，能点的只有「图自己画出来的那一块」，而块级嵌入在行里分到的盒子里
    // 还有一圈不属于图本身的空白 —— 用户点的往往正是边缘那一下。
    //
    // `HitTestBehavior.opaque`：不透明地认领自己这一整块。默认的
    // `deferToChild` 在**两张图**上会失效 —— `Image.memory` 自己
    // `hitTestSelf => true`（`rendering/image.dart:394`）还行，但裂图那个
    // 占位是 `Row(mainAxisSize: min)`，它只有图标与文字那几个像素能命中，
    // 裂图于是「看得见、点不着」。而**裂图恰恰是最需要换掉的那张**。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onImageTap,
      child: child,
    );
  }

  Widget _content(BuildContext context) {
    final bytes = decodeDataImage(source);
    if (bytes != null) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          // [decodeDataImage] 已经用魔数挡掉了「不是图片却 decode 成功」的输入，
          // 但魔数只保证**开头像**：截断的 PNG、坏掉的 IDAT 仍会让解码器抛。
          // 渲染路径上抛一次就是白屏，所以这里也兜一个占位（与 network 那条一致）。
          errorBuilder: (context, error, stack) => _broken(context),
        ),
      );
    }
    // 是 `data:` URI 却解不出字节：内容不是图片 / base64 坏了 / 太大。
    // **绝不能**退回 [Image.network] —— 那会拿 `data:image/...;base64,...`
    // 当网络地址去拉（一个荒谬的 URL）。直接给占位。
    if (source.startsWith('data:')) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: _broken(context),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Image.network(
        source,
        fit: BoxFit.contain,
        // 拉不到图时给一个明确占位，不要留一片空白（用户会以为编辑器坏了）。
        errorBuilder: (context, error, stack) => _broken(context),
      ),
    );
  }

  Widget _broken(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined, size: 16),
            const SizedBox(width: 6),
            Text(
              '图片无法显示',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );

  /// 解码后的字节上限。base64 解出超过这个数（约 8 MB）就不解了 ——
  /// 解码本身是 CPU 活（实测 2 MB 约 15ms），而且 `Image.memory` 的解码缓存
  /// 会让每帧都贵；不可信输入不该有机会把渲染拖死。
  static const int maxDataImageBytes = 8 * 1024 * 1024;

  /// `data:image/...;base64,xxxx` → 字节。不是这种形态（或 base64 坏了、
  /// **内容不是图片**、或太大）给 null。
  ///
  /// 自己解而不用 `Uri.parse(...).data`：那个对**非法 base64** 会抛
  /// `FormatException`，而这里是渲染路径，崩一次就是白屏。
  ///
  /// 为什么要校验魔数：任何 decode 成功、**内容却不是图片**的 data URI
  /// （`data:image/png;base64,AA==` 就是）都会走到 `Image.memory` 并抛
  /// `Exception: Invalid image data`（F-6）。魔数是「这段字节到底是不是它
  /// 声明的图片」的第一道、也是唯一便宜的判据。
  ///
  /// 返回 null 的两种分支要分清：
  /// - **不是** `data:` 形态（空、缺逗号、非 base64 声明）→ 调用方仍可以拿
  ///   原串走 `Image.network`（http 链接那条路）。
  /// - **是** `data:image/...;base64,...` 但内容不是图片/太大 → 调用方必须给
  ///   占位，**绝不能**退回 `Image.network(source)`（拿 `data:` URI 当网络
  ///   地址更荒唐 —— 会去拉一个叫 `data:image/...` 的 URL）。
  static Uint8List? decodeDataImage(String source) {
    if (!source.startsWith('data:image/')) return null;
    final comma = source.indexOf(',');
    if (comma < 0) return null;
    final header = source.substring(5, comma);
    if (!header.contains('base64')) return null;
    late final Uint8List bytes;
    try {
      bytes = base64Decode(source.substring(comma + 1));
    } on FormatException {
      return null;
    }
    if (bytes.length > maxDataImageBytes) return null;
    return _looksLikeImage(bytes) ? bytes : null;
  }

  /// 按魔数判断这段字节是不是图片。魔数认不全也没关系 —— 认不出来的一律
  /// 当「不是图片」挡掉（宁可少显示一张，也别在渲染路径上抛）。
  static bool _looksLikeImage(Uint8List bytes) {
    bool startsWith(List<int> magic) {
      if (bytes.length < magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[i] != magic[i]) return false;
      }
      return true;
    }

    // PNG
    if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return true;
    // JPEG
    if (startsWith(const [0xFF, 0xD8, 0xFF])) return true;
    // GIF87a / GIF89a
    if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return true;
    // BMP
    if (startsWith(const [0x42, 0x4D])) return true;
    // WEBP：RIFF????WEBP（第 9..12 字节才是格式标识）
    if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
        bytes.length >= 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    return false;
  }
}
