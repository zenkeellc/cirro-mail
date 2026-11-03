import 'package:flutter/material.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/storage/local_file.dart';
import '../../../core/util/attachment_mime.dart';
import '../../../core/util/eml_parser.dart';
import '../../../core/util/time_utils.dart';
import '../../../core/widgets/email_address_text.dart';
import '../../../l10n/app_localizations.dart';
import '../../mail_detail/html_body_view.dart';
import '../attachment_kind.dart' show formatAttachmentSize;
import 'text_viewer_screen.dart';
import 'viewer_message.dart';

/// `.eml` / `message/rfc822` 附件的预览：**把它当一封信显示**，而不是一段
/// MIME 源码。
///
/// ## 为什么要单独一个 viewer
///
/// `.eml` 原来落在 `AttachmentKind.text` 上，预览出来是一屏 `Content-Type:` /
/// `boundary=` / base64 —— 能看懂 MIME 的人不需要 App，需要的人在评论区里
/// 找「原始邮件」这个开关。而这封信的主题、发件人、正文其实都在这份字节里，
/// 缺的只是一个解包的动作（`core/util/eml_parser.dart`）。
///
/// ## 复用了什么
///
/// - 正文渲染：`HtmlBodyView`（与正文页、发件箱预览同一个组件）；它同时负责
///   **清洗**（`sanitizeEmailHtml`）与**外部资源拦截** —— 一个来路不明的
///   `.eml` 里那张追踪像素，走的还是正文页那套「默认不加载」的规矩。
/// - 地址显示：`EmailAddressText`（本地部分加重、域名退回）。
/// - 时间：`TimeUtils.formatDetailTime`。
/// - 「看原文」：推到 `TextViewerScreen`，不另写一个源码页。
///
/// 头部布局**没有**直接复用详情页的 `_MailHeader`：那个是私有 widget，绑在
/// `MailRow` + 已入库的 `Recipient` 上（这里只有一份刚解析出来的 MIME 头），
/// 硬抽出来要它在「数据库行」与「解析结果」之间二选一。这里按同一个观感
/// 重画了十来行，比给 `_MailHeader` 加一层抽象便宜。
class EmlViewerScreen extends StatefulWidget {
  const EmlViewerScreen({
    super.key,
    required this.path,
    this.title,
    this.embedded = false,
  });

  /// 已经落盘的本地路径（调用方先 `ensureLocal`）。
  final String path;

  /// 页面标题（通常是附件名）。为空时用「预览」。
  final String? title;

  /// 嵌在分栏右栏里（附件缓存页宽屏），而不是 push 上来的整页 ——
  /// 这时不自己撑 `Scaffold` / `AppBar`（与另外几个 viewer 一致）。
  final bool embedded;

  @override
  State<EmlViewerScreen> createState() => _EmlViewerScreenState();
}

class _EmlViewerScreenState extends State<EmlViewerScreen> {
  EmlMessage? _message;

  /// 读盘失败（文件被系统清掉）或根本解析不出来。两者文案不同，别合并。
  bool _missing = false;
  bool _unparsed = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // 让第一帧先画出来再读：读整份 + 拆 MIME 都是同步调用，直接在
    // `initState` 里做会把首帧一起卡住（同 `TextViewerScreen` 的理由）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>(_load);
    });
  }

  Future<void> _load() async {
    // **整份读**，不像文本预览那样只读前缀：正文部件可能在任何一段之后，
    // 而且 HTML 正文本身可能就在文件尾。上限与「能不能预览」那道判据是同一个
    // 数（`AppDefaults.attachmentPreviewLimit`），所以判过能预览的文件一定读得进来。
    final bytes = LocalFile.readBytes(
      widget.path,
      maxBytes: AppDefaults.attachmentPreviewLimit,
    );
    if (!mounted) return;
    if (bytes == null) {
      setState(() {
        _loading = false;
        _missing = true;
      });
      return;
    }
    final message = parseEml(bytes);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _message = message;
      _unparsed = message == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final message = _message;

    // 整页形态才给「看原文」：内嵌右栏的宽度放不下第二个按钮，而那些场景
    // （缓存页预览一个 .eml）本来也能从面板里「打开」出去。
    final sourceAction = message != null && !widget.embedded
        ? TextButton.icon(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => TextViewerScreen(
                  path: widget.path,
                  title: widget.title,
                  kind: AttachmentKind.text,
                ),
              ),
            ),
            icon: const Icon(Icons.code, size: 18),
            label: Text(l10n.viewerSource),
          )
        : null;

    final body = _body(context, l10n);

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? l10n.preview,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[?sourceAction],
      ),
      body: body,
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_missing) {
      return ViewerMessage(
        icon: Icons.error_outline,
        text: l10n.viewerFileGone,
      );
    }
    final message = _message;
    if (message == null || _unparsed) {
      return _Unparsed(l10n: l10n, path: widget.path, title: widget.title);
    }
    return _MessageView(message: message);
  }
}

/// 解析不出来时的收尾：说一句人话，再给一条「看原文」的路。
///
/// 这条退路是必要的：把一份普通文本当成 `.eml` 打开（发给自己的 .txt 被标成
/// `message/rfc822`）完全可能，那时整页只剩一句「解析不出来」，用户就无路可走了。
class _Unparsed extends StatelessWidget {
  const _Unparsed({required this.l10n, required this.path, this.title});

  final AppLocalizations l10n;
  final String path;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.mail_outline, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(l10n.emlUnreadable, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => TextViewerScreen(
                  path: path,
                  title: title,
                  kind: AttachmentKind.text,
                ),
              ),
            ),
            icon: const Icon(Icons.code, size: 18),
            label: Text(l10n.viewerSource),
          ),
        ],
      ),
    );
  }
}

/// 一封解析好的邮件：头部 + 正文（+ 信里带的附件）。
class _MessageView extends StatelessWidget {
  const _MessageView({required this.message});

  final EmlMessage message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            message.subject.isEmpty ? l10n.noSubject : message.subject,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          if (message.from.isNotEmpty)
            _HeaderLine(
              label: l10n.detailFrom,
              value: message.from.map((a) => a.display).join(', '),
            ),
          if (message.to.isNotEmpty)
            _HeaderLine(
              label: l10n.detailTo,
              value: message.to.map((a) => a.display).join(', '),
            ),
          if (message.cc.isNotEmpty)
            _HeaderLine(
              label: l10n.detailCc,
              value: message.cc.map((a) => a.display).join(', '),
            ),
          if (message.date != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                TimeUtils.formatDetailTime(message.date),
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
            ),
          const Divider(height: 24),
          _Body(message: message),
          if (message.attachments.isNotEmpty) ...<Widget>[
            const Divider(height: 24),
            for (final attachment in message.attachments)
              _AttachmentRow(attachment: attachment),
          ],
        ],
      ),
    );
  }
}

/// 头部一行：`发件人  张三 <a@b.com>`。
///
/// 地址走 `EmailAddressText`（与详情页、列表页同一个约定：本地部分重、
/// `@域名` 退回），名字与地址一起传进去 —— 它扫的是**文字里的地址**，
/// `张三 <a@b.com>` 这种写法和只有地址的写法它都认。
class _HeaderLine extends StatelessWidget {
  const _HeaderLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: EmailAddressText(
              value,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 正文：有 HTML 就渲染 HTML，否则退回纯文本。
///
/// 纯文本用 `SelectionArea` + `Text` 而不是 `SelectableText`：理由与
/// `TextViewerScreen` 同一套（跨行选中来自 `SelectionArea`，不必让每一行
/// 自建一个 `EditableText`）。这里整段只有一个 `Text`。
class _Body extends StatelessWidget {
  const _Body({required this.message});

  final EmlMessage message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final html = message.html;
    if (html != null && html.trim().isNotEmpty) {
      // 与 `TextViewerScreen` 的 Markdown、发件箱预览同一条渲染链。
      return HtmlBodyView(html: html, ossBase: '', shrinkWrap: true);
    }
    final text = message.text;
    if (text != null && text.trim().isNotEmpty) {
      return SelectionArea(
        child: Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        ),
      );
    }
    return ViewerMessage(icon: Icons.mail_outline, text: l10n.emlNoBody);
  }
}

/// 信里带的一个附件。**只读**：预览不解它的字节、也没有另存入口 ——
/// 要用就「用邮件客户端打开」这封信，那边是完整的邮件客户端。
class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({required this.attachment});

  final EmlAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final l10n = AppLocalizations.of(context);
    final size = formatAttachmentSize(attachment.size);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Icon(Icons.attach_file, size: 16, color: muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              attachment.filename.isEmpty ? l10n.unknown : attachment.filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (size.isNotEmpty)
            Text(size, style: theme.textTheme.labelSmall?.copyWith(color: muted)),
        ],
      ),
    );
  }
}
