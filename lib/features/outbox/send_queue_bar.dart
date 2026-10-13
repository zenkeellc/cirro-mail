import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/sync_providers.dart';
import 'send_queue_sheet.dart';

/// 邮件列表底部那条**发送队列**微标签（需求六）。
///
/// 为什么挂在 `MailListView` 内部而不是各个页面：聚合 / 收件箱 / 星标 / 已发送
/// 四个入口共用同一个列表主体，挂一次就四处都有了。放到 AppShell 那一层
/// 反而会在窄屏（没有侧栏）上漏掉。
///
/// 它是**常驻条**不是浮层：发送队列这件事的特点是「用户不知道它存在」——
/// 信安静地排着队、到点自己走。做成 SnackBar 只在入队那一刻闪一下的话，
/// 用户三分钟后想起来要反悔时就没有入口了。
///
/// 队列空时返回 `SizedBox.shrink()`（而不是留一条 28px 的空壳）——
/// 没有待发信件是一件常态，常态不该占着一行高度。
class SendQueueBar extends ConsumerStatefulWidget {
  const SendQueueBar({super.key});

  @override
  ConsumerState<SendQueueBar> createState() => _SendQueueBarState();
}

class _SendQueueBarState extends ConsumerState<SendQueueBar> {
  /// 一秒一跳，只为了让「N 秒后发送」在走。**只在确有排期时才建** ——
  /// 常驻一个每秒醒一次的重建器，在没有队列的用户那里是纯浪费。
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker(bool needed) {
    if (needed && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needed && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final queue = ref.watch(sendQueueProvider);
    final nextAt = queue.nextAt;
    _syncTicker(nextAt != null);

    if (queue.count == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final String text;
    if (nextAt == null) {
      // 队列里有信但都没排期 = 都在等下一轮发件箱时钟（或正在发）。
      text = l10n.sendQueueCount(queue.count);
    } else {
      final left = nextAt.difference(DateTime.now().toUtc());
      text = '${l10n.sendQueueCount(queue.count)} · '
          '${l10n.sendQueueIn(left.inSeconds.clamp(0, 3600))}';
    }

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => showSendQueueSheet(context, ref),
        child: SizedBox(
          height: 28,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 12),
              Icon(
                Icons.schedule_send_outlined,
                size: 15,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(
                Icons.expand_less,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
