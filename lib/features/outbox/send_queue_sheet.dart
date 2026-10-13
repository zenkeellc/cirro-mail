import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/database.dart';
import '../../core/util/time_utils.dart';
import '../../data/repositories/send_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/sync_providers.dart';
import '../../router.dart';
import 'outbox_status.dart';

/// 点列表底部那条微标签弹出来的队列面板（需求六）。
///
/// 与「发件箱」页的分工：那个页面是**全部**状态的台账（含判死与结果不明的，
/// 那些需要用户做决定）；这个面板只列**还在等的那几封**，因为用户是从
/// 「还有 N 封排着队」这句话点进来的，他想看到的就是那 N 封。
/// 要处理失败的条目，面板底部有一个去发件箱的入口。
///
/// 弹层而不是新路由：反悔是一个「顺手」的动作，跳走一整页再回来
/// 会把用户从邮件列表里摘出去。
Future<void> showSendQueueSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    // 队列可能很长（连着排队几封），默认的半屏高度不够看完。
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => const _SendQueueSheet(),
  );
}

class _SendQueueSheet extends ConsumerWidget {
  const _SendQueueSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // 只留 `pending`：`sending` 正有一个请求在飞（撤不回来了），
    // `failed` / `unknown` 属于「等你决定」而不是「在排队」。
    final entries = (ref.watch(outboxProvider).value ?? const <DbOutboxEntry>[])
        .where((e) => e.status == 'pending')
        .toList(growable: false);

    return SafeArea(
      child: ConstrainedBox(
        // 最高 70%：再高就没法一眼看出这是个弹层了。
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: <Widget>[
                  Text(l10n.sendQueueTitle, style: theme.textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Text(
                    l10n.sendQueueCount(entries.length),
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: Text(
                  l10n.outboxEmpty,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _QueueTile(
                    entry: entries[index],
                    onSendNow: () => _sendNow(context, ref, entries[index]),
                    onCancel: () => _cancel(context, ref, entries[index]),
                  ),
                ),
              ),
            const Divider(height: 1),
            TextButton.icon(
              // 「去发件箱」：先关掉面板，再压一整页发件箱上去。
              //
              // 用 `push` 而不是 `go`：这个面板是从**邮件列表**底部那条
              // 微标签点开的，用户关掉发件箱之后该回到他刚才在看的那一屏。
              // `go` 会把这一支的栈换成发件箱，退回来时人就不在原处了。
              onPressed: () {
                Navigator.of(context).pop();
                context.push(Routes.outbox);
              },
              icon: const Icon(Icons.outbox_outlined, size: 18),
              label: Text(l10n.sendQueueViewAll),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendNow(
    BuildContext context,
    WidgetRef ref,
    DbOutboxEntry entry,
  ) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    // 先关掉弹层：发送要几秒到几分钟（大附件），让用户盯着一个不动的
    // 列表不如放他回列表页 —— 结果用 SnackBar 告诉他。
    Navigator.of(context).pop();
    final sent = await ref.read(sendRepositoryProvider).sendDueNow(entry.id);
    messenger?.showSnackBar(
      SnackBar(content: Text(sent ? l10n.outboxSent : l10n.outboxFailed)),
    );
  }

  /// 取消 = 删掉本地那一行（见 `SendRepository.discard`）。
  ///
  /// **一律先确认**：队列是用户唯一能反悔的地方，手滑一下信就没了。
  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    DbOutboxEntry entry,
  ) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.sendQueueCancelConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              l10n.outboxDiscard,
              style: TextStyle(color: Theme.of(dialogContext).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(sendRepositoryProvider).discard(entry.id);
  }
}

/// 队列里的一封。刻意比发件箱的 tile 更扁：这里是「还有哪几封在等着」，
/// 不是「每封信出了什么事」。
class _QueueTile extends StatelessWidget {
  const _QueueTile({
    required this.entry,
    required this.onSendNow,
    required this.onCancel,
  });

  final DbOutboxEntry entry;
  final VoidCallback onSendNow;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final payload = SendRepository.decodePayload(entry.payloadJson);
    final status = OutboxStatus.of(entry);
    final to = payload?.recipients.join(', ') ?? '';

    return ListTile(
      dense: true,
      leading: Icon(status.icon, color: status.color(theme)),
      title: Text(
        payload == null
            ? l10n.sendDraftCorrupted
            : (payload.subject.trim().isEmpty ? l10n.noSubject : payload.subject),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        <String>[
          status.label(l10n, entry),
          if (to.isNotEmpty) l10n.outboxAddressed(to),
          TimeUtils.fromNow(entry.createdAt),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextButton(
            onPressed: onSendNow,
            child: Text(l10n.sendQueueSendNow),
          ),
          IconButton(
            tooltip: l10n.outboxDiscard,
            icon: Icon(Icons.close, color: theme.colorScheme.error),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}
