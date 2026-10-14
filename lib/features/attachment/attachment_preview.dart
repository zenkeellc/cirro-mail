import 'package:flutter/material.dart';

import '../../data/models/mail_attachment.dart';
import 'attachment_kind.dart';
import 'viewers/audio_viewer_screen.dart';
import 'viewers/csv_viewer_screen.dart';
import 'viewers/docx_viewer_screen.dart';
import 'viewers/local_image_viewer_screen.dart';
import 'viewers/pdf_viewer_screen.dart';
import 'viewers/pptx_viewer_screen.dart';
import 'viewers/text_viewer_screen.dart';
import 'viewers/video_viewer_screen.dart';
import 'viewers/xlsx_viewer_screen.dart';

/// 应用内预览的**唯一**入口。
///
/// 在这之前这件事是 `attachment_sheet.dart` 里的一对私有成员
/// （`_canPreview` 判据 + `_preview` 分发），而 `_preview` 的兜底分支是
/// 「不是 PDF 就当图片」—— 任何一个将来新增的类型，只要 `_canPreview` 漏了
/// 而下一行 `if` 没跟上，就会被塞进图片预览器，报一个「图片打不开」。
///
/// 现在把两件事拆开、都收在这里：
/// - 判据（[canPreview]）= 类型 / 体积（`AttachmentMime.previewable`）
///   × 平台能力（`ViewerSupport.supports`）× **viewer 实现了没有**（[implements_]）。
/// - 分发（[openAttachmentPreview]）= 一个 `switch`，**没有兜底分支**。
///
/// 「没有兜底分支」是刻意的：将来加类型时忘了改这里，是编译错误
/// （`switch` 穷尽性），而不是一个跑到图片预览器里的 bug。
abstract final class AttachmentViewers {
  /// 已经有 viewer 的 kind。
  ///
  /// 每加一个 viewer 就在这里加一条 —— [canPreview] 与
  /// [openAttachmentPreview] 都认这一个判据，所以不会出现「面板说有预览、
  /// 点进去没有页面」。
  static bool implemented(AttachmentKind kind) => switch (kind) {
        AttachmentKind.image ||
        AttachmentKind.pdf ||
        AttachmentKind.text ||
        AttachmentKind.markdown ||
        AttachmentKind.csv ||
        AttachmentKind.docx ||
        AttachmentKind.xlsx ||
        AttachmentKind.pptx ||
        AttachmentKind.audio ||
        AttachmentKind.video =>
          true,
        AttachmentKind.archive || AttachmentKind.other => false,
      };
}

/// 这个附件现在、在这台机器上，能不能应用内预览。
///
/// 判 false 的，附件面板里**「预览」那一行直接不出现**（见
/// `attachment_sheet.dart`）—— 不给一个点了会失败的按钮。
bool canPreview(MailAttachment attachment, {TargetPlatform? platform}) {
  if (!previewableOn(attachment, platform: platform)) return false;
  return AttachmentViewers.implemented(AttachmentMime.kindFor(attachment));
}

/// 按类型造出那个 viewer。**[embedded] 只决定它要不要自撑外壳**
/// （`Scaffold` + `AppBar`）—— 内容、控件、错误提示一套都不少。
///
/// 返回 null 表示这个 kind 没有 viewer（与 [AttachmentViewers.implemented]
/// 是同一份判断）。**刻意不是兜底分支**：将来加 kind 时这里忘了改，是
/// `switch` 的编译错误，而不是一个跑进图片预览器里的 bug。
Widget? buildAttachmentPreview({
  required MailAttachment attachment,
  required String path,
  required String title,
  bool embedded = false,
}) {
  final kind = AttachmentMime.kindFor(attachment);
  return switch (kind) {
    AttachmentKind.pdf =>
      PdfViewerScreen(path: path, title: title, embedded: embedded),
    AttachmentKind.image =>
      LocalImageViewerScreen(path: path, title: title, embedded: embedded),
    // 文本与 Markdown 共用一个 viewer：两者只是「要不要走 markdown 渲染」
    // 的差别，为它再写一个页面等于把行渲染、截断提示、选中那一套复制两份。
    AttachmentKind.text || AttachmentKind.markdown => TextViewerScreen(
        path: path,
        title: title,
        kind: kind,
        embedded: embedded,
      ),
    AttachmentKind.csv =>
      CsvViewerScreen(path: path, title: title, embedded: embedded),
    AttachmentKind.docx =>
      DocxViewerScreen(path: path, title: title, embedded: embedded),
    AttachmentKind.xlsx =>
      XlsxViewerScreen(path: path, title: title, embedded: embedded),
    AttachmentKind.pptx =>
      PptxViewerScreen(path: path, title: title, embedded: embedded),
    AttachmentKind.audio =>
      AudioViewerScreen(path: path, title: title, embedded: embedded),
    // 视频在 Windows / Linux 上走不到这里（那两平台的 `canPreview` 已判
    // false，面板里没有「预览」这一行），见 `attachment_kind.dart`。
    AttachmentKind.video =>
      VideoViewerScreen(path: path, title: title, embedded: embedded),
    // 这两个 kind 明确不提供预览（见 [AttachmentViewers.implemented]）。
    AttachmentKind.archive || AttachmentKind.other => null,
  };
}

/// 推进预览页。[path] 必须是**已经落盘的本地路径**（调用方先
/// `ensureLocal`），本函数不打网络。
///
/// 这是**整页形态**。同一个 viewer 还有内嵌形态（附件缓存页宽屏的右栏），
/// 走 [buildAttachmentPreview] 的 `embedded: true` —— 两条路共用上面那一个
/// `switch`，免得出现「整页能预览、右栏说不能」。
Future<void> openAttachmentPreview(
  NavigatorState navigator, {
  required String path,
  required String title,
  required MailAttachment attachment,
}) {
  final viewer = buildAttachmentPreview(
    attachment: attachment,
    path: path,
    title: title,
  );
  // 走到这里说明清单一处说「没实现」、另一处说「实现」—— 与其推一个
  // 空页面，不如把矛盾当场炸出来。
  if (viewer == null) {
    throw StateError(
      '附件预览：${AttachmentMime.kindFor(attachment)} 还没有 viewer'
      '（见 AttachmentViewers.implemented）',
    );
  }
  return navigator.push<void>(
    MaterialPageRoute<void>(builder: (_) => viewer),
  );
}
