import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `context.push` 是 go_router 的扩展方法，`router.dart` **不 re-export** 它
// （它自己只 import 了 `package:go_router/go_router.dart`）。本仓库里另外
// 8 个用 `context.push` 的文件都直接 import 这个包。
import 'package:go_router/go_router.dart';

import '../../core/util/time_utils.dart';
import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/mail_providers.dart';
import '../../providers/notification_providers.dart';
import '../../router.dart';
import 'mail_action.dart';
import 'suggest_draft.dart';
import 'suggestion.dart';

/// 稍后提醒的四个来源（spec §7.4）。
enum RemindKind { today, tomorrow, nextMonday, custom }

/// 一个快捷选项：**本机墙上时间**（`isUtc == false`）。
///
/// 刻意不在这里 `toUtc()`：spec §7.5 把那次换算**写死在落库之前那一步**，
/// 只发生一次。这一层要是提前换掉，界面显示的就成了 UTC 的钟点。
class RemindOption {
  const RemindOption({required this.kind, required this.at});

  final RemindKind kind;
  final DateTime at;
}

/// 本规格新加的动作的**唯一执行处**（spec §6.1）。
///
/// 列表行菜单与详情页顶栏各调一次它。不这么做的话，两处会各自实现一遍
/// 「删除时怎么收尾」—— 而详情页内嵌形态那条路径（`widget.onClose?.call()`）
/// 是最容易漏的那一条。
///
/// [onDeleted] 是视图相关的收尾（内嵌详情页要把选中清掉），由调用方给。
abstract final class MailActionRunner {
  const MailActionRunner._();

  static Future<void> execute(
    BuildContext context,
    WidgetRef ref, {
    required MailRow row,
    required SuggestionChoice choice,
    VoidCallback? onDeleted,
  }) async {
    final l10n = ref.read(l10nProvider);
    final mailRef = MailRef(profileId: row.profileId, emailId: row.emailId);
    switch (choice.action) {
      case MailAction.none:
        // 用户点「无需处理」的意思就是「别再问我了」—— **不提示**
        // （spec §6.6）。面板已经自己 pop 掉了，这里什么都不做。
        return;

      case MailAction.reply:
        await _openCompose(
          context,
          ref,
          row: row,
          draft: SuggestDraft.reply(
            row: row,
            aiText: choice.replyDraft ?? '',
            ossBase: ref.read(ossBaseProvider(row.profileId)),
            wroteLabel: l10n.wrote,
          ),
        );

      case MailAction.forward:
        await _openCompose(
          context,
          ref,
          row: row,
          draft: SuggestDraft.forward(
            row: row,
            // 模型给的 `forwardNote` 当附言第一行；`reason` 补在后面 ——
            // 收件人要知道**为什么**被转（spec §6.2 末段）。
            note: _forwardNote(choice),
            ossBase: ref.read(ossBaseProvider(row.profileId)),
          ),
        );

      case MailAction.remind:
        await _remind(context, ref, l10n: l10n, row: row);

      case MailAction.delete:
        await _delete(context, ref, l10n: l10n, row: row, onDeleted: onDeleted);

      case MailAction.markRead:
      case MailAction.markUnread:
        await _guard(context, l10n, () async {
          await ref.read(emailRepositoryProvider).markRead(
                <MailRef>[mailRef],
                // `read` 是**目标**状态。标未读只在本地生效（服务端
                // `PUT /email/read` 写死 `unread = READ`），这条限制
                // `mail_detail_screen.dart` 的注释里已经写着，不重复。
                read: choice.action == MailAction.markRead,
              );
        });

      case MailAction.star:
      case MailAction.unstar:
        await _guard(context, l10n, () async {
          await ref
              .read(emailRepositoryProvider)
              .setStar(mailRef, starred: choice.action == MailAction.star);
        });
    }
  }

  /// 批量动作的**唯一执行处**（多选）。
  ///
  /// 只收 [MailAction] 里那几种「对一批信都说得通」的：标记已读 / 标未读 /
  /// 标星 / 取消星标 / 删除。答复、转发、稍后提醒、AI 建议这些**按封信才有
  /// 意义**的动作不在这里 —— 调用方（`MailRowMenu` / 多选面板）也不该把
  /// 它们放进菜单。
  ///
  /// 与单封那条 [execute] 的关系：**刻意不合并**。单封那条要处理「一封」
  /// 的一串上下文（AI 建议、转发附言、提醒时间），批量这几条则是「N 封做
  /// 同一件事」—— 硬塞进一个函数会让它变成一个按长度分叉的巨物，而两条路
  /// 真正共享的只有「删除时要撤提醒」这一条，那条已经抽成 [_cancelReminders]。
  ///
  /// **删除与其余几个在收尾上不同**：删完之后选中的行已经不存在了，调用方
  /// 应该借 [onDeleted] 退出多选；标已读 / 标星之后信还在原地，选择要留着
  /// （用户接着处理下一件事）。
  static Future<void> executeBatch(
    BuildContext context,
    WidgetRef ref, {
    required List<MailRow> rows,
    required MailAction action,
    VoidCallback? onDeleted,
  }) async {
    if (rows.isEmpty) return;
    final l10n = ref.read(l10nProvider);
    final refs = <MailRef>[
      for (final row in rows) MailRef(profileId: row.profileId, emailId: row.emailId),
    ];

    switch (action) {
      case MailAction.markRead:
      case MailAction.markUnread:
        await _guard(context, l10n, () async {
          // 与单封那条同一句：`read` 是**目标**状态，标未读只改本地
          // （服务端 `PUT /email/read` 写死 `unread = READ`）。
          await ref.read(emailRepositoryProvider).markRead(
                refs,
                read: action == MailAction.markRead,
              );
        });

      case MailAction.star:
      case MailAction.unstar:
        await _guard(context, l10n, () async {
          await ref.read(emailRepositoryProvider).setStarAll(
                refs,
                starred: action == MailAction.star,
              );
        });

      case MailAction.delete:
        // **一次确认，不是每封一次**：用户勾了 8 封再点删除，弹 8 个框是
        // 折磨；而这批是谁他已经在上一步（勾选 + 菜单里那句「已选 8 封」）
        // 看到了。
        final ok = await _confirm(context, l10n.selectionDeleteConfirm(rows.length));
        if (!ok || !context.mounted) return;
        try {
          // 删除之前先撤提醒，逐封来 —— 理由与单封那条一字不差
          // （见 [_delete]），只是这里要循环 N 次。
          for (final one in refs) {
            await _cancelReminders(ref, one);
          }
          await ref.read(emailRepositoryProvider).delete(refs);
        } catch (e) {
          if (context.mounted) _toast(context, '$e');
          return;
        }
        onDeleted?.call();

      case MailAction.reply:
      case MailAction.forward:
      case MailAction.remind:
      case MailAction.none:
        // 不可批量：调用方不该把这些放进批量菜单（`MailRowMenu` 多选时
        // 只有读/星/删三项）。真走到了这里就什么都不做 —— 比猜一个「最像
        // 的动作」去执行好，猜错就是删了一批用户的信。
        return;
    }
  }

  /// 撤掉某一封上排着的提醒（如果确实有）。
  ///
  /// 一封邮件上**可能有不止一条**提醒（用户改了时间就是又排了一条），
  /// 但撤的不是「每一条」，而是那一个通知 id —— 它只由 `(profileId,
  /// emailId)` 拼出来（C3 的 `reminderId`），所以查得到就撤一次。
  static Future<void> _cancelReminders(WidgetRef ref, MailRef mailRef) async {
    final reminders = await ref.read(databaseProvider).reminderDao.forMail(
          mailRef.profileId,
          mailRef.emailId,
        );
    if (reminders.isEmpty) return;
    await ref
        .read(notificationServiceProvider)
        .cancelReminder(mailRef.profileId, mailRef.emailId);
  }

  /// 转发附言：`forwardNote` 有就用它，没有退到 `reason`。
  ///
  /// 两者都是模型给的一句话，`forwardNote` 是「转给谁、为什么」的专用字段
  /// （不是每次都有），`reason` 一定有（解析器给空串兜底）—— 所以顺序不能反。
  static String _forwardNote(SuggestionChoice choice) {
    final note = (choice.forwardNote ?? '').trim();
    if (note.isNotEmpty) return note;
    return choice.reason.trim();
  }

  /// 「答复 / 转发」：**先落草稿、再打开写邮件页**（spec §6.2 那个选定方案）。
  ///
  /// 落库用的是 `row.mailboxEmail` 当发件邮箱 —— 聚合视图里不指定的话，写邮件
  /// 页会挑到别的实例的默认邮箱上去。
  static Future<void> _openCompose(
    BuildContext context,
    WidgetRef ref, {
    required MailRow row,
    required SuggestDraft draft,
  }) async {
    final db = ref.read(databaseProvider);
    int id;
    try {
      id = await db.localDao.saveDraft(
        profileId: row.profileId,
        accountEmail: draft.accountEmail,
        recipientsJson: draft.recipientsJson,
        subject: draft.subject,
        content: draft.content,
      );
    } catch (e) {
      if (context.mounted) _toast(context, '$e');
      return;
    }
    if (!context.mounted) return;
    await context.push(
      Routes.composeOf(profileId: row.profileId, draftId: id),
    );
  }

  /// 稍后提醒（spec §7.3 雷三 / §7.4 / §7.5）。
  static Future<void> _remind(
    BuildContext context,
    WidgetRef ref, {
    required AppLocalizations l10n,
    required MailRow row,
  }) async {
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      builder: (sheetContext) => _RemindSheet(row: row),
    );
    if (picked == null || !context.mounted) return;

    // 雷三：插件对过去的时间直接抛。自定义选择器也要过这一道。
    final now = DateTime.now();
    if (!picked.isAfter(now)) {
      _toast(context, l10n.remindPast);
      return;
    }

    // **两个「时间」在界面与库之间只有一次换算，位置写死在这里**（spec §7.5）：
    // 落库的是 UTC（与 `OutboxEntries.scheduledAt` 同一套约定），
    // `scheduleReminder` 收到的也是 UTC。
    final utc = picked.toUtc();
    try {
      // **先落库、再排期**：反过来的话，落库失败会留下一条排好了但记录不存在
      // 的提醒 —— 用户取消不掉它，因为它不在任何列表里。反过来那一种失败是
      // 「记了但没排上」，下一轮 ticker 会补，是可恢复的。
      await ref.read(databaseProvider).reminderDao.insert(
            profileId: row.profileId,
            emailId: row.emailId,
            subject: row.subject,
            sender: row.displaySender,
            remindAt: utc,
            createdAt: DateTime.now().toUtc(),
          );
      await ref.read(notificationServiceProvider).scheduleReminder(
            profileId: row.profileId,
            emailId: row.emailId,
            remindAt: utc,
            subject: row.subject,
            sender: row.displaySender,
          );
    } catch (e) {
      if (context.mounted) _toast(context, '$e');
      return;
    }
    if (!context.mounted) return;
    _toast(context, l10n.remindScheduled(TimeUtils.formatDetailTime(picked)));
  }

  /// 删除（spec §6.3）。
  static Future<void> _delete(
    BuildContext context,
    WidgetRef ref, {
    required AppLocalizations l10n,
    required MailRow row,
    VoidCallback? onDeleted,
  }) async {
    // **确认框要说清是哪封信**：从列表菜单进来的路径上用户可能已经点开好几封，
    // 一句光秃秃的「删除这封邮件？」不够。
    final ok =
        await _confirm(context, l10n.aiSuggestDeleteConfirm(row.displaySubject));
    if (!ok || !context.mounted) return;

    final mailRef = MailRef(profileId: row.profileId, emailId: row.emailId);
    try {
      // **删除之前先撤掉排期**：通知已经交给 OS 了，不撤的话用户删了信还会
      // 在周五被提醒一次那封已经不存在的邮件（spec §6.3）。细节见
      // [_cancelReminders]。
      await _cancelReminders(ref, mailRef);
      await ref.read(emailRepositoryProvider).delete(<MailRef>[mailRef]);
    } catch (e) {
      if (context.mounted) _toast(context, '$e');
      return;
    }
    // 视图相关的收尾交给调用方：内嵌详情页要清选中，整页要 pop。
    onDeleted?.call();
  }

  /// 快捷选项（spec §7.4）：`今天 18:00` / `明天 9:00` / `下周一 9:00`。
  ///
  /// **已经过去的不返回**（§7.3 雷三）—— 少一项比给一个点了必报错的选项好。
  /// **不提供「1 小时后」**：用户说「稍后提醒」时心里想的是「今天下班前」
  /// 「明天再说」这类**定点**，不是「一小时后」。
  @visibleForTesting
  static List<RemindOption> quickRemindOptions(DateTime now) {
    // `DateTime(y, m, d + 1, …)` 的跨月/跨年由 `DateTime` 自己归一，
    // 不需要手写「这个月有几天」。
    final today = DateTime(now.year, now.month, now.day, 18);
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 9);
    // 「下周一」= **严格在下一个**周一。今天是周一时是 7 天后，
    // 不是今天（否则用户点「下周一」会得到一个已经过去的 9:00）。
    final untilMonday = (DateTime.monday - now.weekday + 7) % 7;
    final monday = DateTime(
      now.year,
      now.month,
      now.day + (untilMonday == 0 ? 7 : untilMonday),
      9,
    );
    return <RemindOption>[
      if (today.isAfter(now)) RemindOption(kind: RemindKind.today, at: today),
      if (tomorrow.isAfter(now))
        RemindOption(kind: RemindKind.tomorrow, at: tomorrow),
      RemindOption(kind: RemindKind.nextMonday, at: monday),
    ];
  }

  /// 一次动作里可能抛的异常（网络、权限、库写坏）统一变成一条 SnackBar。
  static Future<void> _guard(
    BuildContext context,
    AppLocalizations l10n,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) _toast(context, '$e');
    }
  }

  static Future<bool> _confirm(BuildContext context, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppLocalizations.of(dialogContext).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(AppLocalizations.of(dialogContext).confirm),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 选提醒时间的那个底部弹窗（§7.4 的四个选项）。
class _RemindSheet extends StatelessWidget {
  const _RemindSheet({required this.row});

  final MailRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final options = MailActionRunner.quickRemindOptions(DateTime.now());
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(l10n.remindTitle, style: theme.textTheme.titleMedium),
          ),
          for (final option in options)
            ListTile(
              key: ValueKey<String>('remind-${option.kind.name}'),
              title: Text(_labelOf(option.kind, l10n)),
              onTap: () => Navigator.of(context).pop(option.at),
            ),
          ListTile(
            key: const ValueKey('remind-custom'),
            title: Text(l10n.remindCustom),
            onTap: () async {
              final at = await _pickCustom(context);
              if (at == null) return;
              if (!context.mounted) return;
              Navigator.of(context).pop(at);
            },
          ),
        ],
      ),
    );
  }

  /// [RemindKind] 的 l10n 文案。
  ///
  /// 计划里另有一个 `remindLabelKey(kind) => 'remindToday'`（「kind → 键名」）
  /// 和一条断言四个键名各不相同的用例 —— 两者一起删了：那个映射没有任何生产
  /// 调用方（这里直接读 `l10n.remindX`），而那条用例删掉函数也照样绿。
  static String _labelOf(RemindKind kind, AppLocalizations l10n) =>
      switch (kind) {
        RemindKind.today => l10n.remindToday,
        RemindKind.tomorrow => l10n.remindTomorrow,
        RemindKind.nextMonday => l10n.remindNextMonday,
        RemindKind.custom => l10n.remindCustom,
      };

  /// 自定义：先选日期再选时间。**选完不在这里校验未来** —— 校验只有一处
  /// （`MailActionRunner._remind` 里那个 `isAfter(now)`），两处校验迟早不一致。
  static Future<DateTime?> _pickCustom(BuildContext context) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      // 过去 = 一定会被 `_remind` 挡下来，不如在日历里就不给选。
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
    );
    if (date == null || !context.mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }
}
