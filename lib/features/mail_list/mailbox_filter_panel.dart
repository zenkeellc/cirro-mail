import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/mailbox_account.dart';
import '../../data/models/profile.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/mail_providers.dart';
import '../../providers/profile_providers.dart';
import 'mailbox_filter.dart';

/// 筛选面板的**内容**（不含定位与开关）。
///
/// 定位、点外部关闭、Esc、宽度夹取全在 `MailboxFilterHeaderButton` 里 ——
/// 这个文件只管「长什么样」与「勾一下做什么」。这么分是因为面板本身是纯
/// widget 树，而让它出现在哪儿是 overlay 的事；混在一起的话，面板一改布局
/// 就得连锚定逻辑一起读。
///
/// **没有「应用」按钮**：每一勾立刻写 prefs（见 spec §2.3）。[onClose] 只是
/// 那个关掉浮层的叉 —— 触屏上没有「点外部」这个概念可循，桌面才有。
class MailboxFilterPanel extends ConsumerStatefulWidget {
  const MailboxFilterPanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<MailboxFilterPanel> createState() => _MailboxFilterPanelState();
}

class _MailboxFilterPanelState extends ConsumerState<MailboxFilterPanel> {
  /// 「最少留一个邮箱」的提示锚点。
  ///
  /// 用 `TooltipTriggerMode.manual` + [TooltipState.ensureTooltipVisible]：
  /// 被拒时状态**没有变化**，勾选框不会有任何视觉反馈，所以提示只能由代码
  /// 主动弹。
  ///
  /// 挂在整张表单上（而不是某一行）是因为被拒的那一行**推不出来**：
  /// `MailboxSelection` 被拒时 `selected` 原样保留，前后对比看不出用户点的是
  /// 哪一行 —— 提示语本身只讲「至少留一个」这条规则，不指认具体行。
  final GlobalKey<TooltipState> _hintKey = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final selection = ref.watch(mailboxFilterDraftProvider);
    final byProfile = ref.watch(allMailboxesByProfileProvider);
    final profiles = ref.watch(activeProfilesProvider);

    // 勾选被「最少留一个」挡下来时给一句提示（状态没有变化）。
    //
    // **比 `rejectionSeq` 而不是 `rejected` 那个布尔**：布尔只有上升沿，
    // 用户连点两下「取消最后一个」时第二次什么都不会发生（`prev.rejected`
    // 已经是 true 了）。面板从「弹一下就没」的底部弹层变成常驻浮层之后，
    // 这个 bug 会变得很显眼。
    ref.listen(mailboxFilterDraftProvider, (previous, next) {
      if (next.rejectionSeq != (previous?.rejectionSeq ?? 0)) {
        _hintKey.currentState?.ensureTooltipVisible();
      }
    });

    if (selection.all.isEmpty) {
      // 一个可勾的邮箱都没有（还没登录任何实例）。
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Text(
          l10n.noMailbox,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    return Tooltip(
      key: _hintKey,
      message: l10n.mailboxKeptOne,
      // 只能由上面的 ref.listen 主动弹；轻触/长按都不该触发它。
      triggerMode: TooltipTriggerMode.manual,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(l10n.filterByMailbox, style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton(
                onPressed: selection.isAll
                    ? null
                    : () =>
                        ref.read(mailboxFilterDraftProvider.notifier).selectAll(),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(l10n.selectAll),
              ),
              IconButton(
                tooltip: l10n.close,
                onPressed: widget.onClose,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.filterByMailboxHint,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          Flexible(
            child: ListView(
              // 面板可能有很多邮箱，必须能滚。`primary: false` 是硬要求：
              // 浮层挂在 Overlay 上，跟着列表页那棵树的 `PrimaryScrollController`
              // 走会让两个 ScrollPosition 抢同一个 controller（实测直接抛
              // `The PrimaryScrollController is attached to more than one
              // ScrollPosition`）。
              primary: false,
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              children: <Widget>[
                for (final profileId in profileOrderOf(selection.all))
                  ..._group(
                    context,
                    ref,
                    profileId: profileId,
                    profileName: _nameOf(profiles, profileId),
                    selection: selection,
                    byProfile: byProfile,
                    l10n: l10n,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _nameOf(List<Profile> profiles, String profileId) {
    for (final profile in profiles) {
      if (profile.id == profileId) return profile.displayName;
    }
    return profileId;
  }

  List<Widget> _group(
    BuildContext context,
    WidgetRef ref, {
    required String profileId,
    required String profileName,
    required MailboxSelection selection,
    required Map<String, List<MailboxAccount>> byProfile,
    required AppLocalizations l10n,
  }) {
    final boxes = boxesOfProfile(profileId, byProfile[profileId] ?? const []);
    final state = selection.profileState(profileId);
    final notifier = ref.read(mailboxFilterDraftProvider.notifier);

    return <Widget>[
      // ---- 实例行：勾上 = 该实例全部邮箱（有自己的半选态）----
      ListTile(
        dense: true,
        leading: MailboxTriCheckbox(
          state: state,
          onTap: () => notifier.toggleProfile(profileId),
        ),
        title: Text(profileName, style: Theme.of(context).textTheme.titleSmall),
        onTap: () => notifier.toggleProfile(profileId),
      ),
      // ---- 邮箱行 ----
      for (final box in boxes)
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: ListTile(
            dense: true,
            leading: MailboxTriCheckbox(
              state: selection.selected.contains(box)
                  ? MailboxTriState.all
                  : MailboxTriState.none,
              onTap: () => notifier.toggle(box),
            ),
            title: Text(
              mailboxLabelOf(box, byProfile, allMailboxesLabel: l10n.allMailboxes),
            ),
            trailing: MailboxUnreadLabel(box: box),
            onTap: () => notifier.toggle(box),
          ),
        ),
    ];
  }
}

/// 三态勾选框。`Checkbox` 只能表达两态，实例行的半选态必须自己画。
class MailboxTriCheckbox extends StatelessWidget {
  const MailboxTriCheckbox({super.key, required this.state, required this.onTap});

  final MailboxTriState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (state) {
      MailboxTriState.all => Icons.check_box,
      MailboxTriState.partial => Icons.indeterminate_check_box,
      MailboxTriState.none => Icons.check_box_outline_blank,
    };
    return IconButton(
      icon: Icon(
        icon,
        color: state == MailboxTriState.none ? scheme.outline : scheme.primary,
      ),
      onPressed: onTap,
    );
  }
}

/// 邮箱行右侧的未读数（只在 > 0 时显示）。
class MailboxUnreadLabel extends ConsumerWidget {
  const MailboxUnreadLabel({super.key, required this.box, this.style});

  final MailboxFilter box;

  /// 覆盖默认样式（侧栏那种更窄的地方要更小的字号）。
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 合并项（accountId = 0）没有「这一个邮箱的未读数」可言，不显示。
    if (box.accountId == kAllMailboxes) return const SizedBox.shrink();
    final count = ref.watch(
      mailboxUnreadProvider(
        (profileId: box.profileId, accountId: box.accountId),
      ),
    );
    if (count <= 0) return const SizedBox.shrink();
    return Text(
      AppLocalizations.of(context).unreadCount(count),
      style: (style ?? Theme.of(context).textTheme.labelSmall)
          ?.copyWith(color: Theme.of(context).colorScheme.error),
    );
  }
}
