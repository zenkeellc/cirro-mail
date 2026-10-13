import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/util/time_utils.dart';
import '../../data/models/send_payload.dart';
import '../../data/repositories/send_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/profile_providers.dart';
import '../../providers/sync_providers.dart';
import '../attachment/attachment_kind.dart'
    show formatAttachmentSize, iconOfName;
import '../mail_detail/html_body_view.dart';
import '../sync/sync_status_panel.dart';
import 'outbox_actions.dart';
import 'outbox_status.dart';

/// 窄屏：一条待发邮件的整页预览。
///
/// 从 [outboxProvider] 里按 id 找那条 —— 而不是把条目当路由参数传下来：
/// 传下来（`extra`）会在进程被系统杀掉重启之后变成一个打不开的页面，
/// 而 id 是能从库里重新查到的。
///
/// 动作按钮在这一页的 AppBar 上（窄屏只有这一处能触发重试/删除）；
/// 宽屏分栏下由左栏的行菜单提供，右栏那个 [OutboxPreview] 是纯展示的。
class OutboxEntryScreen extends ConsumerWidget {
  const OutboxEntryScreen({super.key, required this.entryId});

  final int entryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final entries = ref.watch(outboxProvider).value ?? const <DbOutboxEntry>[];
    DbOutboxEntry? entry;
    for (final candidate in entries) {
      if (candidate.id == entryId) {
        entry = candidate;
        break;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.outbox),
        actions: <Widget>[
          if (entry != null) OutboxEntryMenu(entry: entry),
          const SyncStatusButton(),
        ],
      ),
      // 已经不在队列里了（发出去了、或被用户删了）—— 不是错误，
      // 说清楚就行。
      body: entry == null
          ? Center(child: Text(l10n.outboxEmpty))
          : OutboxPreview(entry: entry),
    );
  }
}

/// 发件箱里一条的**只读预览**：正文 + 附件 + 发送状态。
///
/// 与「已发送」文件夹里的邮件**不是一回事**（见 `OutboxScreen` 的类注释）：
/// 那是服务端 `email` 表里的记录，这个是本机的待发队列 —— 正文在
/// `payloadJson` 里而不是 `mails` 表里，**所以它不能复用 `MailDetailScreen`**
/// （那个要的是一行 `MailRow`，发件箱里根本没有）。这里就只是把 payload
/// 摊开给用户看一眼。
///
/// 有意**不做**成可编辑的：用户想改一封没发出去的信，正确做法是「存成草稿
/// 再改」，而不是在一个「马上要发出去的队列」里就地编辑 —— 边发边改会让人
/// 搞不清到底发出去了哪一版。
///
/// **不带动作按钮**（重试 / 删除）：宽屏右栏也要用它，而右栏里的动作按钮
/// 分不清用户指的是左栏选中的那条；按 spec §2.4 由左栏的行菜单提供。
class OutboxPreview extends ConsumerWidget {
  const OutboxPreview({super.key, required this.entry, this.onClose});

  final DbOutboxEntry entry;

  /// 宽屏右栏那个「关掉」按钮；窄屏那一页不需要（顶上本来就有返回箭头）。
  ///
  /// 与 `MailDetailScreen.onClose` 同一个理由：选中态是查询参数，
  /// 系统返回手势关不掉它，得让用户有个能点的地方。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final payload = SendRepository.decodePayload(entry.payloadJson);
    final profile = ref.watch(profileByIdProvider(entry.profileId));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (onClose != null)
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: l10n.close,
              icon: const Icon(Icons.close, size: 20),
              onPressed: onClose,
            ),
          ),
        Text(
          payload == null
              ? l10n.sendDraftCorrupted
              : (payload.subject.trim().isEmpty
                  ? l10n.noSubject
                  : payload.subject),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: payload == null ? theme.colorScheme.error : null,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          <String>[
            if (profile != null) profile.displayName,
            TimeUtils.fromNow(entry.createdAt),
          ].join(' · '),
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            OutboxStatusChip(entry: entry),
            if (entry.attempts > 0) ...<Widget>[
              const SizedBox(width: 8),
              Text(
                l10n.outboxAttempts(entry.attempts),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ],
        ),
        if (entry.lastError != null && entry.lastError!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            entry.lastError!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        // 「结果未知」要有一句解释。这条状态与另外几种不是一个量级：
        // `/email/send` 没有幂等键，点重试就是**真的再投一次**。
        if (entry.status == 'unknown') ...<Widget>[
          const SizedBox(height: 8),
          Text(
            l10n.outboxUnknownResultHint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.tertiary),
          ),
        ],
        // 坏数据不能静默：`decodePayload` 返回 null 时说清楚是这封信本身
        // 解不开，而不是让正文区空着（空着看起来像「这封信没有正文」）。
        if (payload == null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              l10n.sendDraftCorrupted,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          )
        else ...<Widget>[
          const SizedBox(height: 8),
          Text(
            l10n.outboxAddressed(payload.recipients.join(', ')),
            style: theme.textTheme.bodySmall,
          ),
          if (payload.attachments.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            for (final attachment in payload.attachments)
              PendingAttachmentRow(attachment: attachment),
          ],
          const Divider(height: 28),
          HtmlBodyView(
            html: payload.content,
            // 发件箱里的内嵌图还没上传，没有可用的 oss 前缀 —— 给空串，
            // `HtmlBodyView` 会把相对地址原样留着（渲染成断图，而不是一个
            // 会点出去 404 的坏链接）。
            ossBase: '',
            shrinkWrap: true,
          ),
        ],
      ],
    );
  }
}

/// 还没发出去的附件。
///
/// **与已下载的附件不是一回事**：这条只有一个本机路径（`SendAttachment.path`），
/// 文件可能已经被用户从「附件缓存」里清掉了 —— 那种情况下重试必然失败
/// （`SendRepository` 会把它判死）。所以这里如实显示它有多大，而不是假装
/// 它一定会发出去。
class PendingAttachmentRow extends StatelessWidget {
  const PendingAttachmentRow({super.key, required this.attachment});

  final SendAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.attach_file, size: 18),
      title: Text(
        attachment.filename.isEmpty ? l10n.unknown : attachment.filename,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      subtitle: Text(
        formatAttachmentSize(attachment.size),
        style: theme.textTheme.labelSmall,
      ),
      trailing: Icon(
        iconOfName(attachment.filename, mimeType: attachment.mimeType),
        size: 16,
        color: theme.colorScheme.outline,
      ),
    );
  }
}

/// 宽屏右栏还没选中任何一条时的样子。
///
/// 与 `MailPanes._NoSelectionPane` 同一个意思，但**不能复用那个类**：
/// 它在 `mail_panes.dart` 里是私有的，而且那一个的图标说的是「邮件」，
/// 这里的语境是「还没有发出去的信」。
class OutboxNoSelectionPane extends StatelessWidget {
  const OutboxNoSelectionPane({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.outbox_outlined,
            size: 40,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            AppLocalizations.of(context).pickMail,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
