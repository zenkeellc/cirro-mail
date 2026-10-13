import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/app_exception.dart';
import '../../core/storage/attachment_launcher.dart';
import '../../data/models/mail_attachment.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import 'attachment_kind.dart';
import 'attachment_preview.dart';

/// 附件能做的四件事：预览 / 打开 / 分享 / 另存为，外加删掉本地副本。
///
/// 做成底部面板而不是给每个附件配一排按钮：手机上附件区空间本来就紧，
/// 一排四个图标按钮会把文件名挤没；而且**四个动作里有三个需要「先下载」**，
/// 摊在列表里会让用户以为点了就立刻打开。
///
/// 面板打开时**不预下载**任何东西 —— 下载由具体动作触发，进度显示在面板里。
/// 用户点开面板只是想看看有什么，不该为此付一次流量。
///
/// 文案与图标不在这里定义：`formatAttachmentSize` / `iconOf` 在
/// `attachment_kind.dart`，因为缓存管理页、发件箱预览、详情页附件区
/// 都要用同一份（早先各写一份，同一个 PDF 在两处会显示成不同图标）。
Future<void> showAttachmentActions({
  required BuildContext context,
  required WidgetRef ref,
  required MailAttachment attachment,
  required String profileId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _AttachmentSheet(
      attachment: attachment,
      profileId: profileId,
    ),
  );
}

class _AttachmentSheet extends ConsumerStatefulWidget {
  const _AttachmentSheet({
    required this.attachment,
    required this.profileId,
  });

  final MailAttachment attachment;
  final String profileId;

  @override
  ConsumerState<_AttachmentSheet> createState() => _AttachmentSheetState();
}

class _AttachmentSheetState extends ConsumerState<_AttachmentSheet> {
  bool _busy = false;
  double? _progress;
  String? _error;

  MailAttachment get _attachment => widget.attachment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _attachment.displayName,
              style: theme.textTheme.titleSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              <String>[
                if (_attachment.size > 0) formatAttachmentSize(_attachment.size),
                if (_attachment.isDownloaded) l10n.attachmentDownloaded,
              ].join(' · '),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),

            if (_busy) ...<Widget>[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(
                _progress == null
                    ? l10n.downloading
                    : '${l10n.downloading} ${(_progress! * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.labelSmall,
              ),
            ] else
              Column(
                children: <Widget>[
                  if (canPreview(_attachment)) ...<Widget>[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.visibility_outlined),
                      title: Text(l10n.preview),
                      onTap: () => _run(_preview),
                    ),
                    const Divider(height: 1),
                  ],
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.open_in_new),
                    title: Text(l10n.openWith),
                    onTap: () => _run(_open),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.ios_share),
                    title: Text(l10n.share),
                    onTap: () => _run(_share),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.save_alt),
                    title: Text(l10n.saveAs),
                    onTap: () => _run(_saveAs),
                  ),
                  if (_attachment.isDownloaded) ...<Widget>[
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline,
                          color: theme.colorScheme.error),
                      title: Text(
                        l10n.clearCache,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      // 只删本地副本，服务端那份不动 —— 文案要说清。
                      subtitle: Text(l10n.attachmentDeleted,
                          style: theme.textTheme.labelSmall),
                      onTap: () => _run((_) async {
                        await ref
                            .read(attachmentRepositoryProvider)
                            .removeLocal(_attachment);
                      }),
                    ),
                  ],
                ],
              ),

            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.error_outline,
                      size: 16, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 包一层：所有动作都先「确保本地有文件」，再干活。
  ///
  /// 顺序不能反 —— 「打开一个还没下载的文件」是没有意义的，
  /// 而把下载摊进每个动作里会四处重复。
  Future<void> _run(Future<void> Function(String path) action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress = null;
    });

    try {
      final repo = ref.read(attachmentRepositoryProvider);
      final path = await repo.ensureLocal(
        _attachment,
        profileId: widget.profileId,
        onProgress: (sent, total) {
          if (!mounted || total <= 0) return;
          setState(() => _progress = sent / total);
        },
      );
      if (!mounted) return;
      await action(path);
    } on AppException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview(String path) async {
    final navigator = Navigator.of(context);
    navigator.pop();
    await openAttachmentPreview(
      navigator,
      path: path,
      title: _attachment.displayName,
      attachment: _attachment,
    );
  }

  Future<void> _open(String path) async {
    final l10n = AppLocalizations.of(context);
    final opened = await AttachmentLauncher.open(path);
    if (!mounted) return;
    if (opened) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = l10n.openFailed);
    }
  }

  Future<void> _share(String path) async {
    final l10n = AppLocalizations.of(context);
    // iPad / macOS 上分享气泡必须有个锚点，否则直接崩。
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final ok = await AttachmentLauncher.share(
      paths: <String>[path],
      subject: _attachment.displayName,
      origin: origin,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = l10n.shareUnavailable);
    }
  }

  Future<void> _saveAs(String path) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final saved = await AttachmentLauncher.saveAs(
      sourcePath: path,
      suggestedName: _attachment.displayName,
      mimeType: AttachmentMime.of(_attachment),
      dialogTitle: l10n.saveAs,
    );
    if (!mounted) return;
    if (saved != null) {
      Navigator.of(context).pop();
      messenger?.showSnackBar(SnackBar(content: Text(l10n.savedTo(saved))));
    }
    // 用户取消（null）不是错误，什么都不用做。
  }
}
