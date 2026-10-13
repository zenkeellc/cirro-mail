import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/time_utils.dart';
import '../../data/models/mail_row.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/mail_providers.dart';
import '../suggest/mail_action.dart';
import '../suggest/mail_action_runner.dart';
import 'sender_avatar.dart';

/// 多选时右栏（宽屏）与底部（窄屏）共用的那套控件。
///
/// 两处**必须读同一份判据**：面板上写「标记已读」而底部栏写「标记未读」，
/// 是这类界面里最容易出、也最难被发现的一类 bug。所以目标状态的算法只有
/// 一处（[batchReadTarget] / [batchStarTarget]），两个 widget 都调它。
///
/// 动作本身收口到 `MailActionRunner.executeBatch`（唯一执行处），这里只画。

/// 这一批点「已读/未读」时到底要做什么。
///
/// **全已读才标未读**：只要还有一封没读，用户点它的意思就是「全都标已读」
/// —— 而「把 8 封里那 2 封已读的单独标成未读」没有任何人想要。
MailAction batchReadTarget(List<MailRow> rows) =>
    rows.every((r) => !r.isUnread) ? MailAction.markUnread : MailAction.markRead;

/// 同上，星标版。
MailAction batchStarTarget(List<MailRow> rows) =>
    rows.every((r) => r.isStarred) ? MailAction.unstar : MailAction.star;

/// 宽屏分栏的右栏：这一批的统计 + 常用处理。
class MailSelectionPane extends ConsumerWidget {
  const MailSelectionPane({super.key, required this.stats});

  final SelectedMails stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.selectedCount(stats.count),
                  key: const ValueKey<String>('selectionPaneTitle'),
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (stats.total > 0)
                TextButton(
                  key: const ValueKey<String>('selectionPaneSelectAll'),
                  onPressed: () => _selectAll(ref, stats.total),
                  child: Text(l10n.selectionSelectAll(stats.total)),
                ),
            ],
          ),
        ),
        _SelectionStats(stats: stats),
        const Divider(height: 1),
        Expanded(
          child: _SelectedPreview(stats: stats),
        ),
        const Divider(height: 1),
        _SelectionActions(stats: stats),
      ],
    );
  }

  void _selectAll(WidgetRef ref, int rowCount) {
    // 「全选（本页 N 封）」= 当前**已经加载进列表**的这些行，不触发拉取全部。
    // 列表是懒加载的，为一次全选去翻完整个邮箱不划算，也与「统计口径 = 能
    // 解析出来的行」这条一致。
    ref.read(mailSelectionProvider.notifier).selectAll(rowCount);
  }
}

/// 窄屏的底部操作栏。
///
/// 挂在 `MailListView` 的 `Stack` 上（与 `SendQueueBar` 同一层），只在
/// `!Breakpoints.panesOf(context)` 时出现 —— 宽屏有右栏，不需要它。
class MailSelectionBar extends ConsumerWidget {
  const MailSelectionBar({super.key, required this.stats});

  final SelectedMails stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final rows = stats.rows;

    return Material(
      key: const ValueKey<String>('selectionBar'),
      color: theme.colorScheme.surfaceContainerHighest,
      elevation: 3,
      child: SafeArea(
        top: false,
        // `SendQueueBar` 可能就贴在它下面（都是 `Stack` 底部的条）。
        // 两条都出现时上面的这条要能盖住下面那条 —— `elevation` 与不透明
        // 底色保证视觉上是「压在上面」。
        child: SizedBox(
          height: 56,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  l10n.selectedCount(stats.count),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (stats.total > 0)
                IconButton(
                  key: const ValueKey<String>('selectionBarSelectAll'),
                  tooltip: l10n.selectionSelectAll(stats.total),
                  icon: const Icon(Icons.select_all),
                  onPressed: () => ref
                      .read(mailSelectionProvider.notifier)
                      .selectAll(stats.total),
                ),
              IconButton(
                key: const ValueKey<String>('selectionBarRead'),
                tooltip: _readLabel(l10n, rows),
                icon: Icon(_readIcon(rows)),
                onPressed: rows.isEmpty ? null : () => _run(context, ref, rows, batchReadTarget(rows)),
              ),
              IconButton(
                key: const ValueKey<String>('selectionBarStar'),
                tooltip: _starLabel(l10n, rows),
                icon: Icon(_starIcon(rows)),
                onPressed: rows.isEmpty ? null : () => _run(context, ref, rows, batchStarTarget(rows)),
              ),
              IconButton(
                key: const ValueKey<String>('selectionBarDelete'),
                tooltip: l10n.delete,
                icon: const Icon(Icons.delete_outline),
                onPressed: rows.isEmpty
                    ? null
                    : () => _run(context, ref, rows, MailAction.delete),
              ),
              IconButton(
                key: const ValueKey<String>('selectionBarClear'),
                tooltip: l10n.selectionClear,
                icon: const Icon(Icons.close),
                onPressed: () => ref.read(mailSelectionProvider.notifier).clear(),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// 三个按钮的图标/文案判据（面板与底部栏共用）。
///
/// 两个 widget 都调它 —— 面板上写「标记已读」而底部栏写「标记未读」，是这类
/// 界面里最容易出、也最难被发现的一类 bug。判据只有一处。

IconData _readIcon(List<MailRow> rows) => batchReadTarget(rows) == MailAction.markUnread
    ? Icons.mark_email_unread_outlined
    : Icons.mark_email_read_outlined;

IconData _starIcon(List<MailRow> rows) => batchStarTarget(rows) == MailAction.unstar
    ? Icons.star
    : Icons.star_border;

String _readLabel(AppLocalizations l10n, List<MailRow> rows) =>
    batchReadTarget(rows) == MailAction.markUnread ? l10n.markUnread : l10n.markRead;

String _starLabel(AppLocalizations l10n, List<MailRow> rows) =>
    batchStarTarget(rows) == MailAction.unstar ? l10n.unstar : l10n.star;

/// 面板下半部的那排按钮（竖排、全宽，右栏很窄）。
class _SelectionActions extends ConsumerWidget {
  const _SelectionActions({required this.stats});

  final SelectedMails stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final rows = stats.rows;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FilledButton.tonalIcon(
              key: const ValueKey<String>('selectionPaneRead'),
              onPressed: rows.isEmpty ? null : () => _run(context, ref, rows, batchReadTarget(rows)),
              icon: Icon(_readIcon(rows)),
              label: Text(_readLabel(l10n, rows)),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const ValueKey<String>('selectionPaneStar'),
              onPressed: rows.isEmpty ? null : () => _run(context, ref, rows, batchStarTarget(rows)),
              icon: Icon(_starIcon(rows)),
              label: Text(_starLabel(l10n, rows)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey<String>('selectionPaneDelete'),
              onPressed: rows.isEmpty ? null : () => _run(context, ref, rows, MailAction.delete),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.delete),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey<String>('selectionPaneClear'),
              onPressed: () => ref.read(mailSelectionProvider.notifier).clear(),
              child: Text(l10n.selectionClear),
            ),
          ],
        ),
      ),
    );
  }
}

/// 统计那几行。
class _SelectionStats extends StatelessWidget {
  const _SelectionStats({required this.stats});

  final SelectedMails stats;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rows = stats.rows;
    final span = stats.span;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          _StatChip(
            key: const ValueKey<String>('selectionStatUnread'),
            icon: Icons.mark_email_unread_outlined,
            text: l10n.selectionUnread(stats.unread),
          ),
          _StatChip(
            key: const ValueKey<String>('selectionStatAttachments'),
            icon: Icons.attach_file,
            text: l10n.selectionWithAttachments(stats.withAttachments),
          ),
          if (stats.instances > 1)
            _StatChip(
              key: const ValueKey<String>('selectionStatInstances'),
              icon: Icons.dns_outlined,
              // 「实例 J 个」—— 只有跨实例时才有信息量。
              text: l10n.instanceCount(stats.instances),
            ),
          if (span != null)
            _StatChip(
              key: const ValueKey<String>('selectionStatTime'),
              icon: Icons.schedule,
              text: l10n.selectionTimeRange(
                TimeUtils.formatListTime(span.from),
                TimeUtils.formatListTime(span.to),
              ),
            ),
          if (rows.isEmpty)
            _StatChip(
              icon: Icons.info_outline,
              text: l10n.selectionStale,
            ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            text,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 选中那几封的缩略列表（发件人 + 主题）。点一下 = 取消勾选它。
///
/// 复选那几封都是谁、还能顺手剔掉一两封 —— 不然选错了只能「取消选择」重来。
class _SelectedPreview extends ConsumerWidget {
  const _SelectedPreview({required this.stats});

  final SelectedMails stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final rows = stats.rows;
    // `stats.indices[i]` 就是 `rows[i]` 在**整块列表**里的下标 —— 与
    // `selectedRowsProvider` 同一份来源，不必在这里重新解析一次。
    final indices = stats.indices;

    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.selectionStale,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final sender = row.displaySender.isEmpty ? l10n.unknown : row.displaySender;
        return InkWell(
          onTap: () => ref.read(mailSelectionProvider.notifier).toggle(indices[index]),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: <Widget>[
                SenderAvatar(label: sender, seed: row.sendEmail, diameter: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        sender,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      Text(
                        row.displaySubject,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.close,
                  size: 16,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 两处按钮的执行 —— 都走 `MailActionRunner.executeBatch`。
Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  List<MailRow> rows,
  MailAction action,
) =>
    MailActionRunner.executeBatch(
      context,
      ref,
      rows: rows,
      action: action,
      // 删除之后选中的行已经没了，退出多选（与右键菜单那条同一个口径）。
      onDeleted: action == MailAction.delete
          ? () => ref.read(mailSelectionProvider.notifier).clear()
          : null,
    );
