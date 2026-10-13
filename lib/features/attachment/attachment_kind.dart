import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/util/attachment_mime.dart';
import '../../data/models/mail_attachment.dart';

export '../../core/util/attachment_mime.dart'
    show AttachmentKind, AttachmentMime;

/// 「这个附件怎么显示、能不能应用内预览」的 Flutter 侧那一半。
///
/// 纯类型判定的那一半在 `core/util/attachment_mime.dart`（不依赖 Flutter，
/// 所以能在 `flutter test` 里单独跑）。这里只负责三件必须碰 Flutter 的事：
/// 图标、平台能力表、以及把两者拼成面板要的判据。


/// 附件图标。**唯一**一处 mime → 图标的映射。
///
/// 参数是 attachment 而不是 `String? mime`：因为服务端在 S3/KV 后端上只会
/// 给 `application/octet-stream`（见 [AttachmentMime] 的文件头），只看 mime
/// 的话「一个 .png 附件」和「一个 .zip 附件」会显示成同一个图标。
IconData iconOf(MailAttachment attachment) =>
    iconOfName(attachment.displayName, mimeType: attachment.mimeType);

/// 同上，但不要求调用方有一个 [MailAttachment]。
///
/// 发件箱里那些还没发出去的附件是 `SendAttachment`（另一套模型，字段更少），
/// 而「图标该按类型分」这件事与模型是谁无关 —— 与其给两套模型各写一份
/// switch，不如让两边都落到这一个函数上。
IconData iconOfName(String filename, {String? mimeType}) {
  final mime = AttachmentMime.ofFilename(filename, declared: mimeType);
  switch (AttachmentMime.kindOf(mime, filename: filename)) {
    case AttachmentKind.image:
      return Icons.image_outlined;
    case AttachmentKind.pdf:
      return Icons.picture_as_pdf_outlined;
    case AttachmentKind.docx:
      return Icons.description_outlined;
    case AttachmentKind.xlsx:
    case AttachmentKind.csv:
      return Icons.table_chart_outlined;
    case AttachmentKind.pptx:
      return Icons.slideshow_outlined;
    case AttachmentKind.text:
    case AttachmentKind.markdown:
      return Icons.article_outlined;
    case AttachmentKind.audio:
      return Icons.audiotrack_outlined;
    case AttachmentKind.video:
      return Icons.movie_outlined;
    case AttachmentKind.archive:
      return Icons.folder_zip_outlined;
    case AttachmentKind.other:
      return Icons.insert_drive_file_outlined;
  }
}

/// 应用内预览这一平台做不做得到。
///
/// 判 `false` 的那些，附件面板里**「预览」那一行直接不出现** ——
/// 不给一个点了会失败的按钮，也不弹「不支持」再让用户去点「打开」。
/// 这是本仓库反复吃过的一类毛病：同一个动作两个入口行为不一样。
abstract final class ViewerSupport {
  /// 视频只有 Android / iOS / macOS 三个平台有实现。
  ///
  /// `video_player` 没有 Windows / Linux 版本（它的平台表里只有
  /// android/ios/macos/web），而那两个平台的桌面构建本来就没在 CI 上验过，
  /// 所以这里**如实**说不支持。想要补齐得换 `fvp`（FFmpeg 后端），
  /// 那是一条单独的依赖决定。
  static bool video(TargetPlatform platform) =>
      platform == TargetPlatform.android ||
      platform == TargetPlatform.iOS ||
      platform == TargetPlatform.macOS;

  /// PDF 在 Linux 上没有渲染后端。
  ///
  /// `pdfx` 的平台表里有 android/ios/macos/windows/web ——**没有 linux**，
  /// 而 `linux/flutter/generated_plugin_registrant.cc` 里也确实没有它。
  static bool pdf(TargetPlatform platform) => platform != TargetPlatform.linux;

  /// 这个附件在这台机器上能不能应用内预览。
  static bool supports(AttachmentKind kind, TargetPlatform platform) {
    switch (kind) {
      case AttachmentKind.image:
      case AttachmentKind.text:
      case AttachmentKind.csv:
      case AttachmentKind.markdown:
      case AttachmentKind.docx:
      case AttachmentKind.xlsx:
      case AttachmentKind.pptx:
      case AttachmentKind.audio:
        // 音频五平台都有 `audioplayers` 实现（Linux 那条依赖系统
        // gstreamer，缺库时由播放页自己降级并提示，不在这一层判死）。
        return true;
      case AttachmentKind.pdf:
        return pdf(platform);
      case AttachmentKind.video:
        return video(platform);
      case AttachmentKind.archive:
      case AttachmentKind.other:
        return false;
    }
  }
}

/// 附件面板要不要给出「预览」这一行。
///
/// 同时受**类型/体积**与**平台**两道约束。第三道约束 ——「这个 kind 的
/// viewer 到底实现了没有」—— 在 [AttachmentViewers] 那边，由
/// `attachment_preview.dart` 的 `canPreview` 把三者拼起来。
/// [platform] 默认取当前平台；测试里显式传入。
bool previewableOn(
  MailAttachment attachment, {
  TargetPlatform? platform,
}) {
  final kind = AttachmentMime.kindFor(attachment);
  if (!AttachmentMime.previewable(kind: kind, size: attachment.size)) {
    return false;
  }
  return ViewerSupport.supports(kind, platform ?? defaultTargetPlatform);
}

/// 附件大小的显示。
///
/// 放在这里而不是某个页面里：详情页、附件面板、缓存管理页三处都要用，
/// 各写一份迟早会出现「1.5 MB」和「1.50MB」两种写法。
String formatAttachmentSize(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
