import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/profile_providers.dart';
import '../../providers/sync_providers.dart';
import '../shell/nav_sidebar.dart';
import '../shell/sidebar_mailboxes.dart';
import 'home_entries.dart';
import 'home_nav.dart';

/// 主屏菜单：收件箱那一支的第一屏。
///
/// **只服务窄屏（< 600）**：宽屏（>= 600）下左侧栏本身就是菜单（见
/// spec §2.2），主屏网格再出现一次就是同一件事说两遍。（中屏 600–1023
/// 也走侧栏，所以网格的实际出现区间就是 `< Breakpoints.compact`。）
///
/// 每个入口的图标、文案、落点、选中判据全部来自 [HomeEntries] ——
/// 与宽屏侧栏共用同一份定义。网格下面那组邮箱同理，与侧栏共用
/// `SidebarMailboxTree`。
class HomeMenuScreen extends ConsumerWidget {
  const HomeMenuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final profiles = ref.watch(activeProfilesProvider);
    final unread = ref.watch(totalUnreadProvider);
    final outbox = ref.watch(outboxPendingCountProvider);
    final drafts = ref.watch(draftCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(l10n.mailTab),
            Text(
              l10n.instanceCount(profiles.length),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
      // 写邮件入口**不在这里**：外壳（`AppShell`）统一挂着一颗 FAB，画在各页
      // 之上。这一页再挂一颗会被它盖住 —— 看不见，却还在跑代码。
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: <Widget>[
          // 网格嵌在列表里：下面还要追加一组邮箱（见下），而两样东西一起
          // 滚才像一屏菜单。`shrinkWrap` + `NeverScrollableScrollPhysics`
          // 是必须的 —— 不写就是两个滚动容器各滚各的（外层滚不动，
          // 网格自己滚），用户会把「滚不动」当成页面坏了。
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: <Widget>[
              for (final entry in HomeEntries.all)
                _EntryTile(
                  entry: entry,
                  count: _countOf(
                    entry,
                    unread: unread,
                    outbox: outbox,
                    drafts: drafts,
                  ),
                  // 没登录任何实例时点进去只会看到空列表 —— 直接不给点。
                  //
                  // `push: true`：窄屏这一屏是**唯一**能进这几个页面的地方，
                  // 而底部导航只认三支。压上去之后各页 `AppBar` 自带返回箭头，
                  // 系统返回键也成立（理由见 `openHomeEntry`）。
                  onTap: profiles.isEmpty
                      ? null
                      : () => openHomeEntry(
                            context,
                            ref,
                            entry,
                            current: GoRouterState.of(context).uri,
                            push: true,
                          ),
                ),
            ],
          ),
          // 邮箱下级菜单。与宽屏侧栏**共用同一份实现**（见那一族的类注释）——
          // 窄屏没有侧栏，不给这一组就等于「某个邮箱的收件箱」这条路径在窄屏
          // 根本走不通。一台实例都没登录时它自己返回 `SizedBox.shrink()`，
          // 连标题也不画。
          if (profiles.isNotEmpty) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
              child: Text(
                l10n.mailbox,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            // 窄屏网格这一支必须 `push`（与上面 `openHomeEntry` 同一个理由）。
            SidebarMailboxTree(uri: GoRouterState.of(context).uri, push: true),
          ],
        ],
      ),
    );
  }

  /// 入口角标。`null` 表示不显示。
  ///
  /// **发件箱是唯一一个「0 也要显示」的**：它的用途是让用户知道还有这么个
  /// 地方 —— 这正是把入口从设置里搬出来的理由（spec §2.4）。
  int? _countOf(
    HomeEntry entry, {
    required int unread,
    required int outbox,
    required int drafts,
  }) =>
      switch (entry.id) {
        'unread' => unread,
        'inbox' => unread,
        'outbox' => outbox,
        'drafts' => drafts == 0 ? null : drafts,
        _ => null,
      };
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.count, this.onTap});

  final HomeEntry entry;
  final int? count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final label = homeEntryLabel(entry, l10n);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _EntryIcon(entry: entry, count: count),
            const SizedBox(height: 6),
            Text(label, style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

/// 入口图标 + 角标。
///
/// 单开一个 `StatelessWidget` 而不是内联：`BadgedIcon` 的约定是
/// `count <= 0` 不显示角标，而**发件箱要的是「0 也显示」** ——
/// 它的用途是让人知道「还有这么个地方」（spec §2.4）。所以那一个入口
/// 单独画一个角标，不走 `BadgedIcon` 的抑制逻辑。
class _EntryIcon extends StatelessWidget {
  const _EntryIcon({required this.entry, required this.count});

  final HomeEntry entry;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = Icon(entry.icon, color: theme.colorScheme.primary);

    if (entry.id == 'outbox') {
      return Badge(
        label: Text('${count ?? 0}'),
        child: icon,
      );
    }
    return count == null
        ? icon
        : BadgedIcon(
            icon: entry.icon,
            count: count!,
            color: theme.colorScheme.primary,
          );
  }
}
