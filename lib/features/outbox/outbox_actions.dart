import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/sync_providers.dart';
import 'outbox_status.dart';

/// 一条待发邮件上的三个动作：重试 / 立即发送 / 删除。
///
/// 抽成静态方法而不是留在 `OutboxScreen` 的私有方法里：**发件箱列表行的
/// 菜单**与**窄屏那条整页预览的菜单**（两处都是 [OutboxEntryMenu]）都要触发
/// 它们，而这里面有一处判断错不得 —— `unknown` 那条的重试会真的把同一封信
/// **再投一次**（`/email/send` 没有幂等键）。两处各写一遍，迟早有一处漏掉
/// 那句确认。
abstract final class OutboxActions {
  const OutboxActions._();

  /// 重发一条。
  static Future<void> retry(
    BuildContext context,
    WidgetRef ref,
    DbOutboxEntry entry,
  ) async {
    final l10n = AppLocalizations.of(context);
    // 只有「结果未知」的那条要额外确认：服务端可能已经收到这封信了，
    // 而 `/email/send` 没有幂等键 —— 点下去就是**再投一次**。
    // `pending` / `failed` 都是「确定没送达」，点重试就是用户想要的结果，
    // 多问一句只是烦人。
    if (entry.status == 'unknown') {
      final ok = await _confirm(
        context,
        message: l10n.outboxUnknownResultHint,
        confirmLabel: l10n.outboxRetry,
      );
      if (!ok) return;
    }
    // 先乐观地把这条挪进队列（用户会看到状态立刻变成「待发」），再真的发。
    await ref.read(sendRepositoryProvider).retry(entry.id);
    if (!context.mounted) return;
    final sent = !(ref.read(outboxProvider).value ?? const <DbOutboxEntry>[])
        .any((e) => e.id == entry.id);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(sent ? l10n.outboxSent : l10n.outboxFailed)),
    );
  }

  /// 「立即发送」一条**还在排期**的信：跳过剩下那点等待，当场发出去。
  ///
  /// 与 [retry] 的区别是入参的由来：这条从没试过、只是在等，所以不需要
  /// 那句「可能已经送达」的确认（见 `SendRepository.sendDueNow`）。
  static Future<void> sendNow(
    BuildContext context,
    WidgetRef ref,
    DbOutboxEntry entry,
  ) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final sent = await ref.read(sendRepositoryProvider).sendDueNow(entry.id);
    messenger?.showSnackBar(
      SnackBar(content: Text(sent ? l10n.outboxSent : l10n.outboxFailed)),
    );
  }

  /// 删掉本地这一行（它从来没发出去过，所以是「放弃」而不是「撤回」）。
  static Future<void> discard(
    BuildContext context,
    WidgetRef ref,
    DbOutboxEntry entry,
  ) async {
    final l10n = AppLocalizations.of(context);
    final ok = await _confirm(
      context,
      message: l10n.outboxDiscardConfirm,
      confirmLabel: l10n.outboxDiscard,
      destructive: true,
    );
    if (!ok) return;
    await ref.read(sendRepositoryProvider).discard(entry.id);
  }

  static Future<bool> _confirm(
    BuildContext context, {
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              confirmLabel,
              style: destructive
                  ? TextStyle(color: Theme.of(dialogContext).colorScheme.error)
                  : null,
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

/// 一条待发邮件的动作菜单。
///
/// 单独一个控件而不是把菜单项抄在两处：**哪条此刻能做哪个动作**是一条判断
/// （`sending` 的那条正有一个请求在飞，重试会把同一封信发两遍；排期中的那条
/// 该给的是「立即发送」而不是「重试」）。两处各写一份菜单，等于把这条判断
/// 抄两遍 —— 而它错一次就是重复投递。
class OutboxEntryMenu extends ConsumerWidget {
  const OutboxEntryMenu({super.key, required this.entry});

  final DbOutboxEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = OutboxStatus.of(entry);

    return PopupMenuButton<String>(
      onSelected: (value) async {
        switch (value) {
          case 'sendNow':
            await OutboxActions.sendNow(context, ref, entry);
          case 'retry':
            await OutboxActions.retry(context, ref, entry);
          case 'discard':
            await OutboxActions.discard(context, ref, entry);
        }
      },
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        // 排期中的那条：先把「立即发送」放在最前 —— 它是这封信此刻
        // 唯一有意义的动作（用户来这里就是嫌等太久）。
        if (status == OutboxStatus.scheduled)
          PopupMenuItem(value: 'sendNow', child: Text(l10n.sendQueueSendNow)),
        // `sending` 的那条不给重试（见类注释）。
        if (entry.status != 'sending' && status != OutboxStatus.scheduled)
          PopupMenuItem(value: 'retry', child: Text(l10n.outboxRetry)),
        PopupMenuItem(
          value: 'discard',
          child: Text(
            l10n.outboxDiscard,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      ],
    );
  }
}
