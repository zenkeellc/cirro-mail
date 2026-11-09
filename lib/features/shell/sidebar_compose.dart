import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/settings_providers.dart';
import '../../router.dart';
import '../compose/compose_controller.dart';
import '../compose/compose_launcher.dart';
import 'nav_sidebar.dart';

/// 左侧一级导航里的「邮件撰写」分类。
///
/// 上级一项可展开/收起（**默认展开**，状态落 prefs），下级是**此刻打开着的
/// 撰写页** —— 数据源是 `openDraftsProvider`（`drafts` 表 INNER JOIN
/// `compose_pages`），按最后编辑时间倒序，所以新开的邮件永远在最前。
///
/// **不是草稿箱**：草稿箱页列的是**全部**草稿（含已经关掉、归档的），
/// 这里只列「正在编辑」的那几页。两者共用同一张草稿表，差别只是「打开中」
/// 这个本机状态（见 `ComposePages` 表的注释）。
///
/// 点击子项 = `go('/compose?draft=<id>&from=<当前地址>')`：撰写页是「邮件」
/// 那一支里的根路由，没有可 pop 的栈，进去/出来都靠地址（见 `openComposeAt`）。
class SidebarComposeGroup extends ConsumerWidget {
  const SidebarComposeGroup({super.key, required this.uri});

  /// **整条当前地址**（由外壳取好传进来，与侧栏其它分组同一个口径）。
  final Uri uri;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final drafts =
        ref.watch(openDraftsProvider).value ?? const <DbDraft>[];
    final expanded = ref.watch(sidebarComposeExpandedProvider);
    // 高亮哪一条：地址里带了 `draft` 就听地址的（从草稿箱/侧栏点进来的那
    // 几页）；没带的（回复、转发、写新邮件）听页面自己发布的那个 id ——
    // 那些页面的草稿行是进页之后才建出来的，地址里没有可读的东西。
    //
    // 不能为了高亮去给地址补 `draft=`：`router.dart` 里 compose 路由的
    // page key 含 `draft`，地址一变页面 State 就重建（写了一半的字会丢）。
    final routeDraftId = composeDraftIdOf(uri);
    final activeDraftId = ref.watch(activeComposeDraftIdProvider);
    final selectedId = routeDraftId > 0
        ? routeDraftId
        : (isComposeRoute(uri) ? activeDraftId : 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        NavSidebarItem(
          icon: Icons.edit_note_outlined,
          selectedIcon: Icons.edit_note,
          label: l10n.composePages,
          // 父项自身也算「在这一屏」：停在任意一封撰写页上时整行高亮，
          // 具体是哪一封由下面子项的高亮回答。
          selected: isComposeRoute(uri),
          count: drafts.length,
          trailing: IconButton(
            tooltip: expanded ? l10n.sidebarCollapse : l10n.sidebarExpand,
            onPressed: () =>
                ref.read(sidebarComposeExpandedProvider.notifier).toggle(),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            icon: Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
            ),
          ),
          // 点整行 = 展开/收起。这一项**没有页面**可去：撰写页是子项，
          // 点父项若也跳转（比如去草稿箱）会让人以为「邮件撰写」就是草稿箱。
          onTap: () =>
              ref.read(sidebarComposeExpandedProvider.notifier).toggle(),
        ),
        if (expanded)
          if (drafts.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 6, 12, 10),
              child: Text(
                l10n.composePagesEmpty,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            )
          else
            for (final draft in drafts)
              _ComposePageRow(
                key: ValueKey<int>(draft.id),
                draft: draft,
                selected: selectedId == draft.id,
                onTap: () => openComposeDraft(
                  context,
                  draftId: draft.id,
                  profileId: draft.profileId,
                ),
              ),
      ],
    );
  }
}

/// 撰写页子项的一行：缩进 + 图标 + 主题（空则「（无主题）」）。
///
/// 与 `SidebarMailboxRow` 的邮箱子行同一套视觉语言（缩进 36、图标 16、
/// 标签退到 `onSurfaceVariant`），但**不复用那个控件**：它一半的参数
/// （实例色、浅色总数、未读徽章）在这里全都无意义，复用会让调用点为了
/// 凑参数写一堆默认值。
class _ComposePageRow extends StatefulWidget {
  const _ComposePageRow({
    super.key,
    required this.draft,
    required this.selected,
    required this.onTap,
  });

  final DbDraft draft;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ComposePageRow> createState() => _ComposePageRowState();
}

class _ComposePageRowState extends State<_ComposePageRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final selected = widget.selected;
    final foreground =
        selected ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant;
    final background = selected
        ? theme.colorScheme.secondaryContainer
        : (_hovered
            ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.08)
            : Colors.transparent);
    final subject = widget.draft.subject.trim();
    final label = subject.isEmpty ? l10n.noSubject : subject;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 8, 0),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.description_outlined, size: 16, color: foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: foreground,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
