import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/instance_colors.dart';
import '../../../core/util/time_utils.dart';
import '../../../data/models/instance_capabilities.dart';
import '../../../data/models/profile.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/auth_providers.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/mail_providers.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/sync_providers.dart';
import '../../../router.dart' as app_router;

/// 设置 → 实例。
///
/// **全 App 唯一的实例管理入口** —— 加、改、切、登出、删都在这。
///
/// 搬到 `sections/` 之后它只剩「这一块的内容」，`Scaffold` / `AppBar` /
/// 分类栏由 `SettingsScreen` 给。所有弹出物（底部详情面板、两个对话框）
/// 仍然直接 `showModalBottomSheet` / `showDialog` —— 它们挂在最近的那个
/// `Navigator` 上，与宿主是整页还是右栏无关。
class InstancesSection extends ConsumerWidget {
  const InstancesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        if (profiles.isEmpty)
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(l10n.addFirstInstance),
            onTap: () => context.go(app_router.Routes.setup),
          )
        else
          for (final profile in profiles)
            _InstanceTile(key: ValueKey<String>(profile.id), profile: profile),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: OutlinedButton.icon(
            onPressed: () => context.go(app_router.Routes.addInstance),
            icon: const Icon(Icons.add),
            label: Text(l10n.addInstance),
          ),
        ),
      ],
    );
  }
}

/// 一个实例的一行：色标 + 名称 + 状态，点开进入操作菜单。
class _InstanceTile extends ConsumerWidget {
  const _InstanceTile({super.key, required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final isActive = ref.watch(currentProfileIdProvider) == profile.id;
    final color = InstanceColors.of(profile.colorIndex);
    final caps = ref.watch(capabilitiesProvider(profile.id)).value ??
        const InstanceCapabilities();

    // 状态这句**说实话**，四个态各自可辨：
    //
    // 改之前这里只有三分支，而最下面那个分支是骗人的：`lastSyncAt` 从没有
    // 任何地方写过（`setLastSyncAt` 零个调用者），于是它恒为 null，
    // 界面上**永远**是「正在同步」——包括同步早就死掉、或者根本没建起
    // 同步循环的时候。用户看到「正在同步」而收件箱一动不动，这是 1 号
    // bug 的观感来源。
    //
    // 现在按重要性排：没登录 > 缺 token（钥匙串里没有，重启就没了）>
    // 需要重登 > 同步中的实况 > 上次成功时间。
    final overview = syncOverviewOfWidget(ref, profile.id);
    final status = !profile.isLoggedIn
        ? l10n.needsLogin
        : overview == null
            ? l10n.syncing
            : overview.syncing
                ? l10n.syncStateSyncing
                : overview.lastSuccessAt == null
                    ? l10n.syncStateWaiting
                    : l10n.lastSyncAt(
                        TimeUtils.fromNow(overview.lastSuccessAt),
                      );
    // 「需要重登」的实例给一个**当场能点的补救**：先前只在这里标一红条，
    // 用户得自己点进弹出菜单里翻「登录」。而这一条恰恰是同步停摆时
    // 最该被看见的动作。
    final needsAttention = !profile.isLoggedIn || profile.needsLogin;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color,
        child: Text(
          InstanceColors.initial(profile.displayName),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              profile.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isActive) ...<Widget>[
            const SizedBox(width: 6),
            Icon(Icons.check_circle, size: 14, color: theme.colorScheme.primary),
          ],
          if (!profile.isLoggedIn) ...<Widget>[
            const SizedBox(width: 6),
            Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
          ],
        ],
      ),
      subtitle: Text(
        '$status · ${profile.subtitle}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: needsAttention
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      // 「需要重登」时把主行动摊到标题右边，而不是只藏在弹出菜单里。
      trailing: needsAttention
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextButton(
                  // 带上 `?next=settings`：登录页是顶层路由（壳之外、全屏），
                  // 退出时靠这个参数知道该回设置页而不是聚合列表
                  // （见 `LoginScreen._leave`）。登录成功后的落点也是它。
                  onPressed: () => context.go(
                    '${app_router.Routes.login}/${profile.id}?next=settings',
                  ),
                  child: Text(l10n.login),
                ),
                _menu(context, ref, l10n, caps, theme, isActive),
              ],
            )
          : _menu(context, ref, l10n, caps, theme, isActive),
      onTap: () => _onAction(context, ref, 'detail', caps),
    );
  }

  Widget _menu(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    InstanceCapabilities caps,
    ThemeData theme,
    bool isActive,
  ) =>
      PopupMenuButton<String>(
        onSelected: (value) => _onAction(context, ref, value, caps),
        itemBuilder: (context) => <PopupMenuEntry<String>>[
          if (!isActive)
            PopupMenuItem(value: 'activate', child: Text(l10n.setAsCurrent)),
          PopupMenuItem(value: 'relogin', child: Text(l10n.login)),
          PopupMenuItem(value: 'rename', child: Text(l10n.nickname)),
          PopupMenuItem(
            value: 'clear-attachments',
            child: Text(l10n.clearProfileAttachments),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'signout',
            child: Text(l10n.logoutKeepServer),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              l10n.removeInstance,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      );

  Future<void> _onAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    InstanceCapabilities caps,
  ) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final profiles = ref.read(profileRepositoryProvider);
    final registry = ref.read(runtimeRegistryProvider);

    switch (action) {
      case 'activate':
        await profiles.setActive(profile.id);
        // 让调度器把「活跃实例」换成它 —— 它会被优先调度、并马上拉一轮。
        ref.read(syncControllerProvider.notifier).setActiveProfile(profile.id);
        messenger?.showSnackBar(
          SnackBar(content: Text(l10n.setAsCurrentOk(profile.displayName))),
        );

      case 'relogin':
        if (!context.mounted) return;
        // 同上面那颗「登录」：从设置页进来的，退出与登录成功都回设置页。
        context.go('${app_router.Routes.login}/${profile.id}?next=settings');

      case 'rename':
        final name = await _promptText(
          context,
          title: l10n.nickname,
          initial: profile.displayName,
          hint: profile.serverTitle,
        );
        if (name != null) await profiles.rename(profile.id, name.trim());

      case 'clear-attachments':
        final ok = await _confirm(
          context,
          l10n.clearProfileAttachmentsConfirm(profile.displayName),
        );
        if (!ok) return;
        // 只清这个实例的**附件缓存**，邮件本身留在库里。
        await ref.read(attachmentRepositoryProvider).clearProfile(profile.id);
        messenger?.showSnackBar(SnackBar(content: Text(l10n.cacheEmpty)));

      case 'signout':
        final ok = await _confirm(context, l10n.signOutConfirm(profile.displayName));
        if (!ok) return;
        // 先通知服务端注销这一个 token，再清本地。
        try {
          await ref.read(authRepositoryProvider(profile.id)).logout();
        } catch (_) {
          // 服务端注销失败不该把用户卡住 —— 本地清理才是目的。
        }
        await profiles.signOut(profile.id);
        registry.discard(profile.id);

      case 'delete':
        final ok = await _confirm(
          context,
          l10n.removeInstanceConfirm(profile.displayName),
        );
        if (!ok) return;
        // 先丢掉 runtime（它持着一条指向该实例的 Dio），再删 token 与本地数据。
        // token 必须显式删：否则下次新建实例拿到同一个 id 时会「凭空登录」。
        registry.discard(profile.id);
        await ref.read(tokenStoreProvider).delete(profile.id);
        await profiles.delete(profile.id);

      case 'detail':
        if (!context.mounted) return;
        await showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (_) => _InstanceSheet(profile: profile, caps: caps),
        );
    }
  }

  Future<bool> _confirm(BuildContext context, String message) async {
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<String?> _promptText(
    BuildContext context, {
    required String title,
    String initial = '',
    String? hint,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _PromptTextDialog(
        title: title,
        initial: initial,
        hint: hint,
      ),
    );
    return result;
  }
}

/// 文本输入对话框（实例备注名那条路径）。
///
/// 控制器**归对话框所有**（建在 `State` 里、由 `State.dispose` 释放），
/// 而不是由调用方 `_promptText` 在 `await showDialog(...)` 之后立刻释放 ——
/// 那条返回时路由还没走完，退场动画（150ms）期间 `TextField` 还活着、会被
/// 焦点持有并重建，于是撞上
/// `A TextEditingController was used after being disposed.`
/// 以及连锁的 `_dependents.isEmpty is not true`。
///
/// 形状与 `mailboxes_section.dart` 的 `_RenameDialog` 一致。
class _PromptTextDialog extends StatefulWidget {
  const _PromptTextDialog({
    required this.title,
    required this.initial,
    this.hint,
  });

  final String title;
  final String initial;
  final String? hint;

  @override
  State<_PromptTextDialog> createState() => _PromptTextDialogState();
}

class _PromptTextDialogState extends State<_PromptTextDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    // 控制器归对话框所有、也由对话框释放 —— **不能**在 `_promptText` 里
    // `await showDialog(...)` 之后立刻 dispose：那句话返回时路由还没走完，
    // 退场动画（150ms）期间 `TextField` 还活着，会被焦点持有并重建，
    // 于是撞上 `A TextEditingController was used after being disposed.`
    // 以及连锁的 `_dependents.isEmpty is not true`。
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

/// 实例详情底部面板：能力 + 配置，只读。
///
/// 放在这里（而不是塞进诊断页）是因为用户最常见的疑问是「这个实例怎么少了个
/// 功能」，答案就在这张能力表里；诊断页是给「出问题了」用的，更重。
class _InstanceSheet extends ConsumerWidget {
  const _InstanceSheet({required this.profile, required this.caps});

  final Profile profile;
  final InstanceCapabilities caps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(profile.displayName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            SelectableText(
              profile.baseUrl,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text(l10n.capabilities, style: theme.textTheme.labelMedium),
            const SizedBox(height: 8),
            for (final row in caps.toDiagnosticRows().entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 110,
                      child: Text(
                        row.key,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(row.value, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await ref
                          .read(syncSchedulerProvider)
                          .refreshNow(profileId: profile.id);
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.sync),
                    label: Text(l10n.syncNow),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
