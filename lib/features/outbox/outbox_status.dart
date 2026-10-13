import 'package:flutter/material.dart';

import '../../core/db/database.dart';
import '../../l10n/app_localizations.dart';

/// 一条 outbox 记录的显示口径。
///
/// 抽成公共 enum 而不是留在某个页面里的私有类：**发件箱页**与**发送队列面板**
/// （需求六）都在渲染同一批行，两边各写一份的话，「排期中」这个词迟早会在
/// 一个地方被改、另一个地方没改。状态语义见 `OutboxScreen` 的类注释。
enum OutboxStatus {
  /// 已排期，还没到点（`scheduledAt` 在未来）。**不会被 `flush` 挑中**。
  scheduled,

  /// 待发：还没试过，或上一次是「确定没送达」的失败 —— 会自动重试。
  pending,

  sending,
  failed,

  /// 请求超时，服务端可能已经收到。最危险的一种。
  unknown;

  static OutboxStatus of(DbOutboxEntry entry, {DateTime? now}) =>
      switch (entry.status) {
        'sending' => OutboxStatus.sending,
        'failed' => OutboxStatus.failed,
        'unknown' => OutboxStatus.unknown,
        // 认不出的状态按「待发」显示 —— 新版本写进来的状态值，
        // 旧版本至少不该把它当成成功。
        _ => isScheduled(entry, now: now)
            ? OutboxStatus.scheduled
            : OutboxStatus.pending,
      };

  /// 这条是不是「排在未来的队列里」。
  ///
  /// 判 `pending` 而不是所有状态：`failed` 的条目上 `scheduledAt` 可能还留着
  /// 旧值（重试时会清掉），但它的语义是「等你决定」，不是「在排队」。
  static bool isScheduled(DbOutboxEntry entry, {DateTime? now}) {
    if (entry.status != 'pending') return false;
    final at = entry.scheduledAt;
    if (at == null) return false;
    return at.isAfter(now ?? DateTime.now().toUtc());
  }

  /// 距离计划的发送时刻还有多久；不是排期中就是 null。
  static Duration? remaining(DbOutboxEntry entry, {DateTime? now}) {
    if (!isScheduled(entry, now: now)) return null;
    return entry.scheduledAt!.difference(now ?? DateTime.now().toUtc());
  }

  /// 给用户看的一句话。
  ///
  /// 只有 [scheduled] 需要读 [entry]（要把剩余时间算出来），其余三个是定值 ——
  /// 所以签名叫 `label(l10n, entry)` 而不是给枚举挂一个字段。
  String label(AppLocalizations l10n, DbOutboxEntry entry, {DateTime? now}) {
    switch (this) {
      case OutboxStatus.scheduled:
        final left = remaining(entry, now: now) ?? Duration.zero;
        // 切到「分钟」的下限是剩不到 10 秒的时候，不是 60 秒：
        // 「1 分钟后发送」在只剩 3 秒时看着像卡住了。
        if (left.inSeconds <= 10) {
          return l10n.sendScheduled(left.inSeconds.clamp(0, 10));
        }
        return l10n.sendScheduledMinutes((left.inSeconds / 60).ceil());
      case OutboxStatus.pending:
        return l10n.outboxPending;
      case OutboxStatus.sending:
        return l10n.outboxSending;
      case OutboxStatus.failed:
        return l10n.outboxFailed;
      case OutboxStatus.unknown:
        return l10n.outboxUnknown;
    }
  }

  IconData get icon => switch (this) {
        // 排队中与待发共用一个图标，但颜色与文案不同 ——
        // 用户一眼看到的是「还等着」，细节在字里。
        OutboxStatus.scheduled => Icons.schedule,
        OutboxStatus.pending => Icons.schedule,
        OutboxStatus.sending => Icons.sync,
        OutboxStatus.failed => Icons.error_outline,
        OutboxStatus.unknown => Icons.help_outline,
      };

  Color color(ThemeData theme) => switch (this) {
        OutboxStatus.scheduled => theme.colorScheme.secondary,
        OutboxStatus.pending => theme.colorScheme.primary,
        OutboxStatus.sending => theme.colorScheme.primary,
        OutboxStatus.failed => theme.colorScheme.error,
        // 「结果未知」不是错误，但也不能是「没问题」的样子 —— 用中间的调子。
        OutboxStatus.unknown => theme.colorScheme.tertiary,
      };
}

/// 一条待发邮件的状态小标（图标 + 那个词）。
///
/// 放在这里而不是各自内联：**发件箱的左栏行、宽屏右栏的预览、发送队列
/// 面板**三处都要显示同一件事，三份各画一遍的话「结果未知」这个词迟早会
/// 在一处被改、另两处没改 —— 而这个页面里它的语义最重（重试可能真的重复
/// 投递），措辞不一致会直接误导用户。
class OutboxStatusChip extends StatelessWidget {
  const OutboxStatusChip({super.key, required this.entry});

  final DbOutboxEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = OutboxStatus.of(entry);
    final color = status.color(theme);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(status.icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            status.label(l10n, entry),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
