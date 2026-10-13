import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/database.dart';
import '../../core/theme/breakpoints.dart';
import '../../core/theme/instance_colors.dart';
import '../../core/util/time_utils.dart';
import '../../data/models/profile.dart';
import '../../data/models/send_payload.dart';
import '../../data/repositories/send_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/profile_providers.dart';
import '../../providers/settings_providers.dart';
import '../../providers/sync_providers.dart';
import '../../router.dart';
import '../mail_list/mail_panes.dart' show PaneHeader;
import '../sync/sync_status_panel.dart';
import 'outbox_actions.dart';
import 'outbox_preview.dart';
import 'outbox_status.dart';

/// 发件箱。
///
/// 与「已发送」文件夹**不是一回事**：那个是服务端 `email` 表里 `type=1` 的
/// 记录，这个纯粹是本机的待发队列（`outbox` 表）。两者的关系是
/// 「发生的顺序」—— 一封信先躺在这里，发出去之后才会变成服务端的一行。
///
/// 页面上唯一需要小心的地方是**状态语义**（见 [OutboxStatus]）：
/// - `pending`：还没试过，或者上一次是「确定没送达」的失败 —— 可以自动重发；
/// - `sending`：正在发；
/// - `failed`：判死了（附件被删了、配额不够、格式不对）。**不会自动重发**，
///   要用户自己点重试；
/// - `unknown`：请求超时了，**服务端可能已经收到**。这一条最危险，
///   `/email/send` 没有幂等键，点一次重试就真的可能投递两封。
///
/// 所以「重试」按钮在 `failed`/`unknown` 上都要先问一句，
/// 而不是点一下就发。那三个动作收在 [OutboxActions] 里，本页与整页预览
/// 共用同一份。
///
/// ## 外壳与收件箱一致（spec §2.4）
///
/// 顶部条宽屏走 [PaneHeader]（与列表栏同高 52）、窄屏走 `AppBar`，
/// 右上角都是同步按钮；宽屏进分栏：左栏是列表，右栏是那条的只读预览。
///
/// 选中态用 `?sel=`，与邮件列表同一个语法 —— 只改查询参数时 go_router 的
/// `pageKey`（取路由**模式串**）不变，Navigator 原地更新那一页，列表的
/// State 与滚动位置都保住（详见 `Routes.mailOf` 的注释）。
///
/// **与草稿箱的唯一差别**：这里有右栏，草稿箱没有（草稿点开是「进写邮件页
/// 继续编辑」，不是预览）。
class OutboxScreen extends ConsumerWidget {
  const OutboxScreen({super.key, this.selectedId = 0});

  /// 宽屏下左栏选中的那条（来自 `?sel=`）；窄屏恒为 0。
  final int selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final entries = ref.watch(outboxProvider).value ?? const <DbOutboxEntry>[];
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    final flushing = ref.watch(outboxFlushingProvider);
    final wantedWidth = ref.watch(paneListWidthProvider);
    final panes = Breakpoints.panesOf(context);

    DbOutboxEntry? selected;
    for (final entry in entries) {
      if (entry.id == selectedId) {
        selected = entry;
        break;
      }
    }

    final actions = <Widget>[
      IconButton(
        tooltip: l10n.outboxFlush,
        icon: flushing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.send_and_archive_outlined),
        onPressed:
            flushing || entries.isEmpty ? null : () => _flush(context, ref),
      ),
      const SyncStatusButton(),
    ];

    final list = entries.isEmpty
        ? _Empty(hint: l10n.outboxEmpty, note: l10n.outboxHint)
        : ListView.separated(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: entries.length + 1,
            separatorBuilder: (_, index) =>
                index == 0 ? const SizedBox.shrink() : const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Text(
                    l10n.outboxHint,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                );
              }
              final entry = entries[index - 1];
              return OutboxTile(
                entry: entry,
                profile: _profileOf(profiles, entry.profileId),
                selected: panes && entry.id == selectedId,
                onOpen: () => _open(context, entry, panes: panes),
              );
            },
          );

    if (panes) {
      // 左栏宽度用**内容区**宽度去夹（`LayoutBuilder` 的 maxWidth），不是窗口
      // 宽度 —— 这一层外面还有 232px 的一级导航侧栏，拿窗口宽去夹会在刚够
      // 分栏的尺寸上给出一个挤没阅读区的宽度。与 `MailPanes` 同一个口径。
      return Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: <Widget>[
                SizedBox(
                  width: Breakpoints.clampListWidth(
                    wantedWidth,
                    constraints.maxWidth,
                  ),
                  child: Column(
                    children: <Widget>[
                      PaneHeader(
                        actions: actions,
                        child: Text(
                          l10n.outbox,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Expanded(child: list),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selected == null
                      ? const OutboxNoSelectionPane()
                      : OutboxPreview(
                          entry: selected,
                          onClose: () => context.go(Routes.outbox),
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.outbox), actions: actions),
      body: list,
    );
  }

  Profile? _profileOf(List<Profile> profiles, String id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// 点开一条。
  ///
  /// 宽屏改 URL 而不 push（见本页类注释）；窄屏 push 一整页
  /// —— 与邮件列表的处理完全一致。
  void _open(BuildContext context, DbOutboxEntry entry, {required bool panes}) {
    if (panes) {
      context.go(Routes.outboxWith(entry.id));
      return;
    }
    context.push(Routes.outboxDetailOf(entry.id));
  }

  Future<void> _flush(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    await ref.read(outboxFlushingProvider.notifier).flush();
    messenger?.showSnackBar(SnackBar(content: Text(l10n.syncNow)));
  }
}

/// 一条待发邮件。
///
/// 公开类（而不是留在本文件里的 `_OutboxTile`）：宽屏分栏与窄屏列表都要用它，
/// 而它的信息结构（状态词、收件人、失败原因、重试次数）是一整套口径，
/// 挪进别的文件时不该被改走样。
class OutboxTile extends StatelessWidget {
  const OutboxTile({
    super.key,
    required this.entry,
    required this.profile,
    required this.onOpen,
    this.selected = false,
  });

  final DbOutboxEntry entry;
  final Profile? profile;

  /// 点整行。窄屏 push 整页、宽屏改 URL —— 由调用方决定。
  final VoidCallback onOpen;

  /// 宽屏左栏选中态。
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // 坏数据的兜底：`decodePayload` 返回 null 表示这条记录的 JSON 已经解不开
    // 了。**不把它藏起来** —— 用户会看到「有一封信躺在发件箱里但打不开」，
    // 比它凭空消失好（后者会让人以为已经发出去了）。
    final payload = SendRepository.decodePayload(entry.payloadJson);
    final status = OutboxStatus.of(entry);

    return ListTile(
      isThreeLine: true,
      selected: selected,
      leading: CircleAvatar(
        backgroundColor: status.color(theme),
        child: Icon(status.icon, size: 18, color: Colors.white),
      ),
      title: Text(
        payload == null
            ? l10n.sendDraftCorrupted
            : (payload.subject.trim().isEmpty
                ? l10n.noSubject
                : payload.subject),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: payload == null ? TextStyle(color: theme.colorScheme.error) : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _subtitle(l10n, payload),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Row(
            children: <Widget>[
              Text(
                status.label(l10n, entry),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: status.color(theme),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                TimeUtils.fromNow(entry.createdAt),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              if (profile != null && profile!.displayName.isNotEmpty) ...<Widget>[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    profile!.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: InstanceColors.of(profile!.colorIndex)),
                  ),
                ),
              ],
            ],
          ),
          if (entry.lastError != null && entry.lastError!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                l10n.outboxLastError(entry.lastError!),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          if (entry.attempts > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                l10n.outboxAttempts(entry.attempts),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
        ],
      ),
      trailing: OutboxEntryMenu(entry: entry),
      // 点整行 = 打开预览。
      //
      // 原来是「点整行 = 重试」—— 那在窄屏上还说得过去（用户来发件箱
      // 就是想把这封信弄出去），但宽屏分栏之后它是错的：右栏空着，
      // 点一行却触发了一次**可能重复投递**的动作。
      // 重试/删除留在右边那个菜单里，那里本来就写清楚了。
      onTap: onOpen,
    );
  }

  String _subtitle(AppLocalizations l10n, SendPayload? payload) {
    if (payload == null) return '';
    final to = payload.recipients.join(', ');
    final count = payload.attachments.length;
    // 收件人优先用「收件人」这层语义标注一下 —— 发件箱里一眼看去分不清
    // 这行地址是收件人还是发件人（它跟「已发送」列表长得太像了）。
    final head = to.isEmpty ? '' : l10n.outboxAddressed(to);
    if (count == 0) return head;
    final attachments = l10n.composeAttachmentCount(count);
    return head.isEmpty ? attachments : '$head · $attachments';
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.hint, required this.note});

  final String hint;
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.outbox_outlined,
              size: 48,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(height: 12),
            Text(hint, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            Text(
              note,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
