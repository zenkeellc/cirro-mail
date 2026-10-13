import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/breakpoints.dart';
import '../../core/theme/instance_colors.dart';
import '../../data/models/enums.dart';
import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../data/models/profile.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/mail_providers.dart';
import '../../providers/profile_providers.dart';
import '../../router.dart';
import '../mail_list/mail_list_view.dart';
import '../mail_list/mail_panes.dart';
import '../mail_list/mail_selection.dart';
import '../mail_list/mail_selection_pane.dart';
import '../mail_list/mailbox_filter.dart';
import '../sync/sync_status_panel.dart';

/// 星标文件夹。
///
/// 与邮件列表的**一处关键差异**：`GET /star/list` 不返回 `total`，
/// 也没有「最新邮件」游标，所以这里
/// - 不显示任何计数（显示一个猜出来的数字比不显示更糟）；
/// - 翻页游标与邮件列表共用 `emailId` 口径（服务端就是 `lt(star.emailId)`）。
///
/// 实例筛选沿用聚合页的语义（空集 = 全部），但**不需要 prefs**：星标是
/// 一次性的查看行为，不值得记住。
class StarredScreen extends ConsumerStatefulWidget {
  const StarredScreen({super.key, this.selected});

  /// 分栏形态下右栏打开的那封（URL 里的 `sel` + `profile`）。窄屏恒为 null。
  final MailRef? selected;

  @override
  ConsumerState<StarredScreen> createState() => _StarredScreenState();
}

class _StarredScreenState extends ConsumerState<StarredScreen> {
  /// 0 = 全部实例。
  String? _profileId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final profiles = ref.watch(activeProfilesProvider);

    // 选中的实例被删掉/登出后，退回「全部」。
    if (_profileId != null && !profiles.any((p) => p.id == _profileId)) {
      _profileId = null;
    }

    final query = MailListQuery(
      mailboxes: _profileId == null
          ? const <MailboxFilter>[]
          : <MailboxFilter>[
              MailboxFilter(profileId: _profileId!, accountId: kAllMailboxes),
            ],
      folder: MailFolder.starred,
    );

    // 这一屏是不是正在多选（判据与 `MailListView` 画复选框时同一处）。
    //
    // 星标页的 scope **必须带上实例 Tab**：切 Tab 换的只是 `mailboxes`，节点
    // 还是 `all` —— 少了这一项，切个 Tab 之后同一批行下标会指向另外几封信，
    // 而列表看上去「差不多」，用户根本发现不了。
    final scope = selectionScopeForQuery(query);
    final selecting =
        selectionAppliesTo(ref.watch(mailSelectionProvider), scope);
    final stats =
        selecting ? ref.watch(selectedRowsProvider(query)) : const SelectedMails();

    final tabs = profiles.length > 1
        ? _InstanceTabs(
            profiles: profiles,
            selected: _profileId,
            onChanged: (id) => setState(() => _profileId = id),
          )
        : null;

    final list = Column(
      children: <Widget>[
        ?tabs,
        Expanded(
          child: MailListView(
            query: query,
            // 只有「全部实例」时才加实例色带 —— 选了单个实例后每行同色是噪声。
            showInstanceBand: _profileId == null && profiles.length > 1,
            emptyHint: '还没有标星的邮件',
            selected: widget.selected,
            // 宽屏下点一行只改 URL，不 push（见 `Routes.mailOf`）。
            onOpen: _open,
            // 星标列表也接多选（最常见的批量动作就是「取消星标」/「删除」）。
            multiSelect: true,
          ),
        ),
      ],
    );

    if (Breakpoints.panesOf(context)) {
      return Scaffold(
        body: MailPanes(
          selected: widget.selected,
          onClosed: _clearSelection,
          pane: selecting ? MailSelectionPane(stats: stats) : null,
          list: Column(
            children: <Widget>[
              PaneHeader(
                child: Text(
                  l10n.starred,
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
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.starred),
        bottom: tabs,
        actions: const <Widget>[SyncStatusButton()],
      ),
      body: list,
    );
  }

  /// 分栏形态下选中一封：改 URL，不 push。
  ///
  /// 星标列表里的 `emailId` 跨实例重号，所以必须连 `profile` 一起带上。
  void _open(MailRow row) {
    context.go(paneSelectionOf(
      root: Routes.starred,
      profileId: row.profileId,
      emailId: row.emailId,
    ));
  }

  void _clearSelection() => context.go(Routes.starred);
}

/// 顶部实例切换（星标页专用，用 Tab 而不是 FilterChip：
/// 这里始终只选一个，而聚合页是多选）。
class _InstanceTabs extends StatelessWidget implements PreferredSizeWidget {
  const _InstanceTabs({
    required this.profiles,
    required this.selected,
    required this.onChanged,
  });

  final List<Profile> profiles;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Size get preferredSize => const Size.fromHeight(44);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: <Widget>[
          _Chip(
            label: AppLocalizations.of(context).all,
            color: null,
            selected: selected == null,
            onTap: () => onChanged(null),
          ),
          for (final profile in profiles)
            _Chip(
              label: profile.displayName,
              color: InstanceColors.of(profile.colorIndex),
              selected: selected == profile.id,
              onTap: () => onChanged(profile.id),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: ActionChip(
        avatar: color == null
            ? null
            : Icon(Icons.circle, size: 10, color: color),
        label: Text(label),
        onPressed: onTap,
        backgroundColor:
            selected ? theme.colorScheme.primaryContainer : null,
      ),
    );
  }
}
