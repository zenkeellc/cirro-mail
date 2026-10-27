import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/theme/instance_colors.dart';
import '../../../core/util/email_address.dart';
import '../../../core/widgets/email_address_text.dart';
import '../../../data/models/instance_capabilities.dart';
import '../../../data/models/mailbox_account.dart';
import '../../../data/models/profile.dart';
import '../../../data/repositories/capability_repository.dart';
import '../../../features/mail_list/mailbox_scope.dart' as scope;
import '../../../l10n/app_localizations.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/mail_providers.dart';
import '../../../providers/profile_providers.dart';
import '../../../router.dart' as app_router;

/// 设置 → 邮箱。**全 App 唯一的邮箱管理入口**（添加 / 改名 / 置顶 / 删除）。
///
/// ## 形态：按实例分组，全列
///
/// 一台实例一个组头，组头下面是它的**全部**邮箱。「添加邮箱」按钮放在**组头
/// 右侧**而不是整页一个 —— 加邮箱必须指名加在哪台实例上，整页一个按钮说不清
/// 这件事（规格 §2.2）。
///
/// ## 三条闸门是三条，不是一条
///
/// 与服务端 `requirePerms` + `accountService` 逐条对齐（规格 §3）：
///
/// | 动作 | 闸门 |
/// |---|---|
/// | 添加 | perm `account:add` **且** 站点 `addEmail == 0 && manyEmail == 0` |
/// | 删除 | perm `account:delete` **且**不是主邮箱 |
/// | 改名 | perm `email:send`（**纯客户端约定** —— 服务端 `setName` 不在 `requirePerms` 里） |
/// | 置顶 | 无权限要求，且不是主邮箱 |
///
/// 提示语也分开：实例关掉了 / 没权限 / 没登录，是**三句不同的话** ——
/// 一句「你没有权限」会把能找管理员解决的与找谁都没用的混成一件事。
///
/// ## 被删掉的那个邮箱如果正被钉着，要退回实例级
///
/// 地址栏里的 `?account=<id>` 是「当前这一屏钉在哪个邮箱上」的唯一标志
/// （`mailbox_scope.dart` 里那条判据，也是左侧菜单邮箱下级菜单的落点）。
/// 删掉那个邮箱之后，这个地址指向一个不再存在的 id，而列表里**永远**不会
/// 再有那一行 —— 用户看到的是「点了删除，这一屏一直转不出来」。
class MailboxesSection extends ConsumerWidget {
  const MailboxesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];

    if (profiles.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(l10n.addFirstInstance),
            // 与 `InstancesSection` 同一写法（`router.dart` 的常量而不是字面量）。
            onTap: () => context.go(app_router.Routes.setup),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        for (final profile in profiles)
          _InstanceGroup(key: ValueKey<String>(profile.id), profile: profile),
      ],
    );
  }
}

/// 一台实例：组头（色标 + 名称 + 添加按钮）+ 它的全部邮箱。
class _InstanceGroup extends ConsumerWidget {
  const _InstanceGroup({super.key, required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final mailboxes = ref.watch(mailboxesProvider(profile.id)).value ??
        const <MailboxAccount>[];
    final caps = ref.watch(capabilitiesProvider(profile.id)).value ??
        const InstanceCapabilities();

    // 「不能加」时的**那一句实话**。顺序是有讲究的：实例没登录最先说
    // （用户自己就能解决），其次实例关掉了（找谁都没用），最后才说权限
    // （要找管理员）。
    final blocked = !profile.isLoggedIn
        ? l10n.mailboxNeedLogin
        : caps.addMailboxDisabledByConfig
            ? l10n.mailboxAddDisabledByServer
            : caps.hasAccountAdd == ProbeState.denied
                ? l10n.mailboxAddDenied
                : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ListTile(
          leading: CircleAvatar(
            backgroundColor: InstanceColors.of(profile.colorIndex),
            child: Text(
              InstanceColors.initial(profile.displayName),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          title: Text(
            profile.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            profile.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: blocked == null
              ? TextButton.icon(
                  onPressed: () => _openAdd(context, ref),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.mailboxAdd),
                )
              : null,
        ),
        if (blocked != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Text(
              blocked,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (mailboxes.isEmpty)
          ListTile(
            dense: true,
            title: Text(
              l10n.noMailbox,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          // 主邮箱 = **第一行**。
          //
          // 网页端用的是 `item.accountId !== user.account.accountId`，而
          // App 里 `UserInfo` **从不落库**，冷启动拿不到那个 id。规格 §3 给的
          // 兜底就是「该组的第一行不可删不可置顶」：本地列表已按
          // `desc(sort), asc(accountId)` 排，而主邮箱恒在榜首
          // （`setAsTop` 只会把它的 sort 抬得更高）。宁可少给一个动作，
          // 也不能给错 —— 删错的是用户的主邮箱。
          for (var i = 0; i < mailboxes.length; i++)
            _MailboxTile(
              key: ValueKey<int>(mailboxes[i].accountId),
              profile: profile,
              account: mailboxes[i],
              caps: caps,
              isPrimary: i == 0,
            ),
        const Divider(height: 1),
      ],
    );
  }

  Future<void> _openAdd(BuildContext context, WidgetRef ref) async {
    // `l10n` / `messenger` / 仓库都在 `await` **之前**取好：之后 context 可能
    // 已经不在树上了（弹窗是异步的），而 `AppLocalizations.of(context)` 在
    // await 之后用会被 `use_build_context_synchronously` 拦下来。
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    // `ref.read` 也一样在 await 前取：这是个 `ConsumerWidget`
    // （`_InstanceGroup`），整段被卸载之后再 `ref.read` 在 riverpod 3 会抛
    // `StateError`。
    final accounts = ref.read(accountRepositoryProvider);
    final added = await showDialog<MailboxAccount>(
      context: context,
      builder: (_) => _AddMailboxDialog(profile: profile),
    );
    if (added == null) return;
    // `widget` 的 `mounted` 得用 `BuildContext.mounted` —— `ConsumerWidget`
    // 没有 `State.mounted`。
    if (!context.mounted) return;

    // 服务端那边的顺序/ID 才是真相，重拉一次（`setAsTop` 同理）。
    await accounts.refresh(profile);

    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.mailboxAdded(added.email))),
    );
  }
}

/// 一个邮箱的一行。
class _MailboxTile extends ConsumerWidget {
  const _MailboxTile({
    super.key,
    required this.profile,
    required this.account,
    required this.caps,
    required this.isPrimary,
  });

  final Profile profile;
  final MailboxAccount account;
  final InstanceCapabilities caps;

  /// 是不是主邮箱（= 该组第一行，见 `_InstanceGroup` 里的长注释）。
  final bool isPrimary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    final canRename = caps.accountRenameEnabled;
    // 主邮箱不可删 / 不可置顶 —— 与网页端同一个判据（规格 §3）。
    final canDelete = !isPrimary && caps.accountDeleteEnabled;
    final canPin = !isPrimary;

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 72, right: 8),
      leading: Icon(
        isPrimary ? Icons.star_outline : Icons.mail_outline,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            // 列表里认的是「谁」：本地部分加粗，`@域名` 常规（见
            // [EmailAddressText]）。这个标题原来整串同样重，一列地址扫下去
            // 全是域名在占位。
            child: EmailAddressText(
              account.email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isPrimary) ...<Widget>[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                l10n.mailboxPrimaryBadge,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: account.name.isEmpty || account.name == account.email
          ? null
          : Text(
              account.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      trailing: (canRename || canDelete || canPin)
          ? PopupMenuButton<String>(
              onSelected: (value) => _onAction(context, ref, value),
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                if (canRename)
                  PopupMenuItem<String>(
                    value: 'rename',
                    child: Text(l10n.mailboxRename),
                  ),
                if (canPin)
                  PopupMenuItem<String>(
                    value: 'pin',
                    child: Text(l10n.mailboxPin),
                  ),
                if (canDelete) ...<PopupMenuEntry<String>>[
                  const PopupMenuDivider(),
                  PopupMenuItem<String>(
                    value: 'delete',
                    child: Text(
                      l10n.delete,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ],
            )
          : null,
    );
  }

  Future<void> _onAction(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final accounts = ref.read(accountRepositoryProvider);

    switch (action) {
      case 'rename':
        final name = await _promptName(context, initial: account.name);
        if (name == null) return;
        // 与旧名相同 → 直接关掉，不打接口（照网页端 `setName`）。
        if (name == account.name) return;
        try {
          await accounts.setName(profile, account.accountId, name);
          // 本地那行 `name` 要等下一轮 `/account/list` 才更新 —— 服务端是
          // 唯一真相，本地不自己改（`MailboxAccount.name` 与它的
          // `displayName` 都只在 refresh 里被整行覆盖）。
          await accounts.refresh(profile);
        } on AppException catch (e) {
          messenger?.showSnackBar(SnackBar(content: Text(e.userMessage)));
        }

      case 'pin':
        try {
          await accounts.setAsTop(profile, account.accountId);
          // `setAsTop` 内部已经 refresh 了一次 —— 顺序跟服务端走，本地不自己算。
        } on AppException catch (e) {
          messenger?.showSnackBar(SnackBar(content: Text(e.userMessage)));
        }

      case 'delete':
        final ok = await _confirm(
          context,
          l10n.mailboxRemoveConfirm(account.email),
        );
        if (!ok) return;
        try {
          await accounts.remove(profile, account.accountId);
        } on AppException catch (e) {
          messenger?.showSnackBar(SnackBar(content: Text(e.userMessage)));
          return;
        }
        await accounts.refresh(profile);
        messenger?.showSnackBar(
          SnackBar(content: Text(l10n.mailboxRemoved(account.email))),
        );
        // 被删的正好是当前钉着的那个 → 退回实例级列表（`?account=` 去掉）。
        //
        // 判据**在这里现解析**（而不是在 build 里算好传下来）：用户可能在
        // 确认框开着的时候点过侧栏 —— 那时地址已经变了，而我们删的仍是他
        // 原来点的那个邮箱。现解析拿到的才是「他此刻正看着哪儿」。
        // `pinnedMailboxOf` 是 `mailbox_scope.dart` 里那**唯一**一条判据，
        // 与左侧菜单邮箱下级菜单的高亮同源。
        if (!context.mounted) return;
        final now = scope.pinnedMailboxOf(GoRouterState.of(context).uri);
        if (now != null &&
            now.profileId == profile.id &&
            now.accountId == account.accountId) {
          context.go(app_router.Routes.mailOf(profile.id));
        }
    }
  }

  /// 改名对话框。
  ///
  /// 长度与空串**都在本地拦**：服务端 `setName` 只拦 `length > 30`，
  /// 空串会真的写进去，然后 `MailboxAccount.displayName` 退化成邮箱地址 ——
  /// 看起来像「改坏了」。
  ///
  /// 改到名字的框本体是 `_RenameDialog`；控制器归对话框所有、由它自己释放
  /// —— 原因见 `_RenameDialogState.dispose` 的说明。
  Future<String?> _promptName(
    BuildContext context, {
    required String initial,
  }) async {
    // `l10n` 与 `messenger` 都在 `await` **之前**取好：之后 context 可能已经
    // 不在树上了（弹窗是异步的），而 `ScaffoldMessenger.of(context)` 在 await
    // 之后用会被 `use_build_context_synchronously` 拦下来。
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: initial),
    );
    if (result == null) return null;

    final name = result.trim();
    if (name.isEmpty) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.mailboxEmptyName)));
      return null;
    }
    if (name.length > 30) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.mailboxNameTooLong)));
      return null;
    }
    return name;
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
}

/// 改名对话框的壳。
///
/// 控制器归对话框所有、由它自己释放 —— 原因见 `_RenameDialogState.dispose`
/// 的说明。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    // 控制器归对话框所有、也由对话框释放 —— **不能**在 `_promptName` 里
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
      title: Text(l10n.mailboxRename),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: l10n.mailboxTitle),
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

/// 添加邮箱对话框。
///
/// **两份数据来路不同，别混**（规格 §5.1）：
///
/// | 值 | 来路 |
/// |---|---|
/// | `domainList` / `needsTurnstile` / `minEmailPrefix` | `ConfigRepository.peek`（内存缓存、**同步**），空则回退 `caps.domainList` |
/// | perm 三项 + `addMailboxDisabledByConfig` | `capabilitiesProvider` |
class _AddMailboxDialog extends ConsumerStatefulWidget {
  const _AddMailboxDialog({required this.profile});

  final Profile profile;

  @override
  ConsumerState<_AddMailboxDialog> createState() => _AddMailboxDialogState();
}

class _AddMailboxDialogState extends ConsumerState<_AddMailboxDialog> {
  final TextEditingController _prefix = TextEditingController();
  String? _suffix;
  String? _error;
  bool _busy = false;

  /// 运行时才发现要人机验证（服务端回了 `400 emptyBotToken` / `botVerifyFail`）。
  bool _needsVerifyLate = false;

  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final profileId = widget.profile.id;
    final caps = ref.watch(capabilitiesProvider(profileId)).value ??
        const InstanceCapabilities();
    final config = ref.watch(configRepositoryProvider).peek(profileId);

    // 域名单优先用刚刚那份配置，空则回退能力表（它冷启动就有）。
    final configDomains = config?.domainList ?? const <String>[];
    final domains = configDomains.isNotEmpty ? configDomains : caps.domainList;
    final minPrefix = config?.minEmailPrefix ?? 1;
    final needsVerify = _needsVerifyLate || (config?.needsTurnstile ?? false);
    final suffix = _suffix ?? (domains.isEmpty ? null : domains.first);

    return AlertDialog(
      title: Text(l10n.mailboxAddTitle),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (needsVerify) ...<Widget>[
              // 诚实降级：不接 Turnstile 控件，直接告诉用户去哪儿做。
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.mailboxAddVerifyRequired,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (domains.isEmpty) ...<Widget>[
              // 降级成「完整地址」单框。**不做「自由后缀输入」** ——
              // 服务端 `c.env.domain.includes(...)` 会挡，让用户自己拼一个
              // 不在列表里的域名只是把失败往后推一步。
              TextField(
                key: const ValueKey<String>('mailbox-prefix'),
                controller: _prefix,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.mailboxAddFullAddress,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.mailboxDomainUnavailable,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ] else
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const ValueKey<String>('mailbox-prefix'),
                      controller: _prefix,
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(labelText: l10n.mailboxAdd),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // ⚠️ `Expanded` + `isExpanded: true` **不是**装饰：这个
                  // `Row` 里下拉自己**没有宽度约束**，`DropdownButtonFormField`
                  // 内部那层 `InputDecorator` 会以无限宽当场断言失败
                  // （"contained by a Row … constraints.maxWidth < double.infinity"，
                  // 文案里就写着「用 Expanded 或 SizedBox」）。`Expanded` 给它一个
                  // 确定的宽度，`isExpanded: true` 再让里面那行在给定宽度内收缩
                  // 而不是溢出。真触发条件是 `Row`，不是别处的 `IntrinsicWidth`
                  // —— 裸下拉放进 `IntrinsicWidth` 并不会报。
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      // 这个 SDK（Flutter 3.24.5）里 `value` 已标 deprecated，
                      // 用 `initialValue` 免得 `flutter analyze` 报警。
                      initialValue: suffix,
                      isExpanded: true,
                      items: <DropdownMenuItem<String>>[
                        for (final domain in domains)
                          DropdownMenuItem<String>(
                            value: domain,
                            child: Text(domain),
                          ),
                      ],
                      onChanged: (value) => setState(() => _suffix = value),
                    ),
                  ),
                ],
              ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        if (needsVerify)
          FilledButton.icon(
            onPressed: _busy ? null : _openWeb,
            icon: const Icon(Icons.open_in_browser, size: 18),
            label: Text(l10n.mailboxOpenWeb),
          )
        else
          FilledButton(
            onPressed: _busy ? null : () => _submit(domains, minPrefix),
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.mailboxAdd),
          ),
      ],
    );
  }

  /// 打开网页端（规格 §5.4：降级到「去网页端」而不是内嵌 webview）。
  Future<void> _openWeb() async {
    final uri = Uri.tryParse(widget.profile.baseUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 本地预校验，顺序**对齐服务端 `add()` 的前四项**（规格 §5.2）：
  /// 非空 → 格式 → 域名 → 前缀长度。省一次注定失败的往返。
  ///
  /// 前缀黑名单（`banEmailPrefix`）**不做**：`emailPrefixFilter` 是服务端
  /// `setting` 表里的一列，客户端拿不到，只能等 501 回来。
  Future<void> _submit(List<String> domains, int minPrefix) async {
    final l10n = AppLocalizations.of(context);
    final raw = _prefix.text.trim();
    final email = domains.isEmpty ? raw : '$raw${_suffix ?? domains.first}';

    // 「非空」与「格式」用的是**同一句**：空串本来就不是合法地址，
    // 而服务端的 `emptyEmail` 与 `notEmail` 在用户看来也是同一件事
    // （「你填的不对」），没必要多一个只差一个字的文案。
    if (!isEmailAddress(email)) {
      setState(() => _error = l10n.mailboxInvalidAddress);
      return;
    }
    final prefix = email.split('@').first;
    if (prefix.length < minPrefix) {
      setState(() => _error = l10n.mailboxPrefixTooShort(minPrefix));
      return;
    }

    final navigator = Navigator.of(context);
    // `await` 之前先抓住本对话框的 route。请求在途时用户点背景把对话框
    // 关掉（或先按了返回）之后，`navigator.pop` 弹的会是**栈顶**那一页 ——
    // 那时下面那一屏就成了无辜受害者（实测：在推入的 `MailboxesSection`
    // 页里开框、背景关掉、请求成功，被弹出的是宿主设置页）。`isCurrent` 的
    // 判据是「本 route 此刻在不在栈顶」，形状照 `compose_screen` 的
    // `_scheduleNotice`（`route?.isCurrent ?? false` → `navigator.pop()`）。
    final route = ModalRoute.of(context);
    // 403 分支要写坏能力表；提前拿好仓库对象，免得 await 之后在已卸载的
    // `ref` 上读（riverpod 3 会抛 `StateError`）。
    final capabilityRepo = ref.read(capabilityRepositoryProvider);
    // 「这一次已经收场了」（成功 pop / 已被卸载）—— 失败才需要在 `finally`
    // 里复位 `_busy`。成功路径靠 pop 离开，不该再 `setState`。
    var done = false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final added =
          await ref.read(accountRepositoryProvider).add(widget.profile, email);
      // 成功路径靠离开这一页收场，不进 `finally` 的 `setState`。
      if (!mounted) return;
      if (route?.isCurrent ?? false) navigator.pop(added);
      done = true;
      return;
    } on AppException catch (e) {
      // `AppException` 是 sealed 基类，网络类的 `NetworkException` /
      // `TimeoutException` / `ServerException` / 401 的 `AuthExpiredException`
      // 都是它的子类、却**不是** `ApiException`。只 catch 子类的话它们会
      // 穿透，`_busy` 永远停在 `true` —— 转圈不停、取消与确认都点不动。
      // 口径与 `push_section` / `attachment_sheet` 一致：至少 catch 到基类。
      //
      // 这两条是**已经过期**的 `addVerifyOpen` 快照造成的，走同一句降级
      // 告示 + 同一个按钮，而不是弹一句服务端的中文原文（「需要进行人机
      // 验证」在这里等于没说 —— App 里根本没有那个控件）。
      //
      // 判据是 `code == 400` 而不是去匹配文案：服务端的 message 是**按
      // accept-language 本地化过的**，拿中文串匹配会在英文界面下失效。
      // 而整个 worker 里抛 400 的**只有** `turnstile-service.js` 那两处
      // （`emptyBotToken` / `botVerifyFail`）—— 别处要么 403 要么 401。
      final verify = e.code == 400;
      final denied = e.code == 403;
      if (!mounted) return;
      setState(() {
        if (verify) {
          _needsVerifyLate = true;
        } else if (denied) {
          // 403 = 「这个账号没这个权限」。规格 §8 要求 403 的文案后面缀上
          // 「请联系管理员」—— 那句就是 `mailboxAddDenied`，比服务端原文准。
          _error = l10n.mailboxAddDenied;
        } else {
          _error = e.userMessage;
        }
      });
      if (verify) return;
      if (denied) {
        // 当场降级：写坏能力表之后，组头那个按钮与菜单项在下一次 build
        // 就没了。
        await capabilityRepo.noteDenied(widget.profile.id, CapabilityFlag.accountAdd);
      }
    } catch (e) {
      // 兜底不是「防御性编程」：`AccountRepository` 之上还有 `mapDioException`
      // 没归类到的异常（或未来新增的异常类型），漏一种就会重新出现「转圈
      // 卡死」。照 `attachment_sheet.dart:204` 的口径，给一句最小的回执。
      //
      // 走到这里的是**没归类**的异常（`mapDioException` 没包到的那些，以及
      // `noteDenied` 自己抛出来的 —— catch 子句不接住同一条 try 里 handler
      // 抛的异常）。`AppException` 有面向用户的文案就用它，其余才退回原文 ——
      // 直接把 `'$e'` 摆到用户眼前，露的是 `ServerException(...)` 这种内部类型名。
      if (!mounted) return;
      setState(() => _error = e is AppException ? e.userMessage : '$e');
    } finally {
      // 任何失败路径（含上面那条兜底）都要让对话框恢复可点；成功那次已经走
      // pop 离开（`done == true`），不在这里 `setState` —— 否则就是「已离开
      // 还 setState」。
      if (!done && mounted) setState(() => _busy = false);
    }
  }
}
