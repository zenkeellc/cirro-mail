import 'package:mime/mime.dart';

import '../../data/models/mail_attachment.dart';
import '../config/app_defaults.dart';

/// 一个附件「是什么类型」的**唯一**判定处。
///
/// 在这之前这件事有三份互不相同的实现（`attachment_sheet.dart` 里的
/// `AttachmentRepositoryMime.of` 扩展名硬编码表、`attachment_repository.dart`
/// 的 `AttachmentRepository.mimeOf` 用的 `package:mime`、以及
/// `attachment_cache_screen.dart` 里直接写的 `mimeType.startsWith('image/')`），
/// 于是同一个 PDF 在不同页面上会拿到不同结论。
///
/// 为什么不能只信服务端给的 `mimeType`：
/// 1. **S3 / KV 后端的下发永远是 `application/octet-stream`** ——
///    `mail-worker/src/api/r2-api.js` 的下载头只认 R2 的 `httpMetadata`，
///    换成 S3/KV 后那个字段不存在，一路落到默认值（见 README 的坑清单）。
/// 2. **入站邮件本身就可能没声明类型** —— `postal-mime` 解析出什么就存什么。
///
/// 所以：**扩展名兜底是必需项，不是优化**。
enum AttachmentKind {
  image,
  pdf,
  text,
  csv,
  markdown,
  docx,
  xlsx,
  pptx,
  audio,
  video,
  archive,
  other,
}

/// MIME 推断与「类型 → kind」的映射。纯 Dart，不依赖 Flutter。
abstract final class AttachmentMime {
  /// 一个附件是否可能被应用内预览，只看类型与体积（**不看平台**）。
  ///
  /// 平台那一半在 `features/attachment/attachment_kind.dart` 的
  /// [canPreview] 里 —— 拆开是为了让这一个能在纯 Dart 单测里跑。
  static bool previewable({
    required AttachmentKind kind,
    required int size,
  }) {
    if (kind == AttachmentKind.other || kind == AttachmentKind.archive) {
      return false;
    }
    if (size > AppDefaults.attachmentPreviewLimit) return false;
    return true;
  }

  /// 附件类型。**[attachment.mimeType] 优先但不可尽信**（见文件头）。
  static String of(MailAttachment attachment) =>
      ofFilename(attachment.displayName, declared: attachment.mimeType);

  /// 按文件名推断，可带上服务端声明的类型作为首选。
  ///
  /// 顺序：声明值（若非空且不是那个通用兜底）→ `package:mime` 的扩展名表
  /// → 本仓库的补丁表 → 通用兜底。
  static String ofFilename(String filename, {String? declared}) {
    if (declared != null && declared.isNotEmpty && !_isGeneric(declared)) {
      return declared;
    }
    // `lookupMimeType` 需要**带点**的路径才能取到扩展名；`MailAttachment`
    // 的 `displayName` 是完整文件名，直接用即可。
    final byPackage = lookupMimeType(filename);
    if (byPackage != null) return byPackage;
    final ext = _extensionOf(filename);
    if (ext.isEmpty) return _generic;
    // `package:mime` 的扩展名表（`extensionToMedia`）里**没有** docx / pptx /
    // yaml / yml，而这几个恰恰是最常见的附件类型，所以必须自己补一张。
    return _patched[ext] ?? _generic;
  }

  /// 类型 + 文件名 → kind。
  ///
  /// 文件名要参与判断，不能只看 MIME：`.csv` 的 mime 是 `text/csv`、
  /// `.md` 是 `text/markdown`，而**两者都可能是 `text/plain` 或
  /// `application/octet-stream`**（发件方的客户端决定），只看 MIME 会把
  /// 它们当成普通文本，于是 CSV 表格与 Markdown 排版都出不来。
  static AttachmentKind kindOf(String mime, {String filename = ''}) {
    final ext = _extensionOf(filename);
    final base = _baseOf(mime);

    // 先让**扩展名**在少数几个已知冲突上胜出。
    switch (ext) {
      case 'csv' || 'tsv':
        return AttachmentKind.csv;
      case 'md' || 'markdown':
        return AttachmentKind.markdown;
      case 'docx':
        return AttachmentKind.docx;
      case 'xlsx' || 'xlsm':
        return AttachmentKind.xlsx;
      case 'pptx':
        return AttachmentKind.pptx;
    }

    if (base.startsWith('image/')) return AttachmentKind.image;
    if (base == 'application/pdf') return AttachmentKind.pdf;

    // OOXML 三件套：**扩展名那一关没拦到**（文件名没有扩展名、或扩展名是
    // 别的）时才轮到 mime 说话。这三条必须排在下面的 zip 判断**之前** ——
    // 它们的 mime 字面上也是 zip 家族的，排后面就全成了「压缩包」。
    if (base == _docxMime) return AttachmentKind.docx;
    if (base == _xlsxMime) return AttachmentKind.xlsx;
    if (base == _pptxMime) return AttachmentKind.pptx;

    if (base.startsWith('audio/')) return AttachmentKind.audio;
    if (base.startsWith('video/')) return AttachmentKind.video;
    if (base == 'application/ogg' || base == 'application/x-ogg') {
      return AttachmentKind.audio;
    }

    if (base == 'text/csv' || base == 'text/tab-separated-values') {
      return AttachmentKind.csv;
    }
    if (base == 'text/markdown' || base == 'text/x-markdown') {
      return AttachmentKind.markdown;
    }

    if (_zipBased.contains(base)) {
      // `.doc` / `.xls` / `.ppt`（老二进制格式）与 `.zip` 都落在这里 ——
      // 前者我们解不了，后者本来就不是文档。
      return AttachmentKind.archive;
    }

    if (base == 'application/msword') return AttachmentKind.other;
    if (base == 'application/vnd.ms-excel') return AttachmentKind.other;
    if (base == 'application/vnd.ms-powerpoint') return AttachmentKind.other;

    if (base.startsWith('text/')) return AttachmentKind.text;
    // 代码 / 配置类：当文本显示比「用其他应用打开」有用得多。
    if (_textLike.contains(base)) return AttachmentKind.text;

    return AttachmentKind.other;
  }

  /// 直接给 kind，省得调用方自己去取 mime。
  static AttachmentKind kindFor(MailAttachment attachment) =>
      kindOf(of(attachment), filename: attachment.displayName);

  // ---------------------------------------------------------------- 内部

  static const String _generic = 'application/octet-stream';

  static const String _docxMime =
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  static const String _xlsxMime =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  static const String _pptxMime =
      'application/vnd.openxmlformats-officedocument.presentationml.presentation';

  static bool _isGeneric(String mime) =>
      mime == _generic || mime == 'binary/octet-stream';

  static final Set<String> _zipBased = <String>{
    'application/zip',
    'application/x-zip-compressed',
    'application/x-zip',
  };

  /// `package:mime` 认不出来的几个。**只补它没有的** ——
  /// 已经有的一律走它，免得两处说法不一致。
  static const Map<String, String> _patched = <String, String>{
    'docx': _docxMime,
    'pptx': _pptxMime,
    'yaml': 'text/yaml',
    'yml': 'text/yaml',
  };

  /// 内容是文本、但 mime 不是 `text/*` 的那些。
  static final Set<String> _textLike = <String>{
    'application/json',
    'application/xml',
    'application/javascript',
    'application/x-sh',
    'application/rtf',
    'message/rfc822',
    'text/x-vcard',
    'text/calendar',
  };

  static String _baseOf(String mime) {
    final value = mime.trim().toLowerCase();
    final semi = value.indexOf(';');
    return (semi < 0 ? value : value.substring(0, semi)).trim();
  }

  /// 不带点的小写扩展名，没有则空串。
  static String _extensionOf(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return '';
    return filename.substring(dot + 1).toLowerCase();
  }
}
