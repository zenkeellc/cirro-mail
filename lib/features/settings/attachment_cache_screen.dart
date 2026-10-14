import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/attachment_cache.dart';
import '../../core/theme/breakpoints.dart';
import '../../core/theme/instance_colors.dart';
import '../../core/util/time_utils.dart';
import '../../data/models/mail_attachment.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/settings_providers.dart';
import '../attachment/attachment_kind.dart'
    show formatAttachmentSize, iconOf;
import '../attachment/attachment_preview.dart'
    show buildAttachmentPreview, canPreview;
import '../attachment/attachment_sheet.dart' show showAttachmentActions;
import '../mail_list/mail_panes.dart' show PaneHeader;
import '../sync/sync_status_panel.dart';

/// 附件缓存管理。
///
/// 三件事：**看占用**、**按实例清理**、**清空**。
///
/// 一个刻意的设计：列表读的是**库里的下载记录**，而总占用读的是**磁盘**
/// （[AttachmentCache.usage]）。两者不一致是正常的 —— 用户可能在系统文件
/// 管理器里删过文件，或系统在存储紧张时清理过 Caches。显示磁盘真实占用
/// 才不会出现「清了 200MB 但数字没变」那种让人以为清理无效的观感。
///
/// ## 外壳与收件箱一致（spec §2.4）
///
/// 顶部条宽屏走 [PaneHeader]、窄屏走 `AppBar`，右上角都是同步按钮。
/// 宽屏进分栏：左栏是列表，右栏是选中那个附件的预览 —— 能应用内预览的
/// 类型就用详情页那套 viewer 在本栏里渲染，没有 viewer 的类型（压缩包、
/// 老格式）给图标 + 文件名 + 说明 + 落盘路径，没选就是空态。
class AttachmentCacheScreen extends ConsumerStatefulWidget {
  const AttachmentCacheScreen({super.key});

  @override
  ConsumerState<AttachmentCacheScreen> createState() =>
      _AttachmentCacheScreenState();
}

class _AttachmentCacheScreenState
    extends ConsumerState<AttachmentCacheScreen> {
  List<MailAttachment>? _items;
  ({int bytes, int files})? _usage;
  bool _busy = false;

  /// 宽屏左栏选中的那个附件（`MailAttachment` 没有稳定的 id，用
  /// `profileId:attId` 当键 —— 两个实例的 `attId` 会重号）。
  String? _selectedKey;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final repo = ref.read(attachmentRepositoryProvider);
    final items = await repo.downloaded();
    final usage = await repo.usage();
    if (!mounted) return;
    setState(() {
      _items = items;
      _usage = usage;
      // 选中的那个刚被删掉了 —— 右栏不能继续显示一条已经不存在的记录。
      if (_selectedKey != null &&
          !items.any((item) => _keyOf(item) == _selectedKey)) {
        _selectedKey = null;
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final items = _items;
    final usage = _usage;
    final panes = Breakpoints.panesOf(context);

    final actions = <Widget>[
      IconButton(
        tooltip: l10n.clearAllAttachments,
        icon: const Icon(Icons.delete_sweep_outlined),
        onPressed: items == null || items.isEmpty ? null : _clearAll,
      ),
      const SyncStatusButton(),
    ];

    final list = items == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: <Widget>[
              if (usage != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        l10n.cacheUsage(
                          usage.files,
                          formatAttachmentSize(usage.bytes),
                        ),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.attachmentCacheHint,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      l10n.cacheEmpty,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else ...<Widget>[
                const Divider(),
                for (final item in items)
                  _AttachmentRow(
                    key: ValueKey<String>(_keyOf(item)),
                    attachment: item,
                    selected: panes && _keyOf(item) == _selectedKey,
                    onDelete: () => _run(
                      () => ref
                          .read(attachmentRepositoryProvider)
                          .removeLocal(item),
                    ),
                    onOpen: () => _open(item, panes: panes),
                  ),
              ],
            ],
          );

    if (panes) {
      MailAttachment? found;
      for (final item in items ?? const <MailAttachment>[]) {
        if (_keyOf(item) == _selectedKey) {
          found = item;
          break;
        }
      }
      // 先收到一个 `final` 再往下走：右栏那个删除回调是**异步之后**才跑的，
      // 直接闭包捕获循环变量的话，编译期它就是个可变局部 —— 语义上没问题，
      // 但读的人要在脑子里追一遍「它是不是还是刚才那个值」。
      final selected = found;

      return Scaffold(
        body: SafeArea(
          // 左栏宽度用**内容区**宽度去夹（`LayoutBuilder` 的 maxWidth），
          // 不是窗口宽度 —— 这一层外面还有 232px 的一级导航侧栏，拿窗口宽
          // 去夹会在刚够分栏的尺寸上给出一个挤没右栏的宽度。
          // 与 `MailPanes`、`OutboxScreen` 同一个口径。
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: <Widget>[
                SizedBox(
                  width: Breakpoints.clampListWidth(
                    ref.watch(paneListWidthProvider),
                    constraints.maxWidth,
                  ),
                  child: Column(
                    children: <Widget>[
                      PaneHeader(
                        actions: actions,
                        child: Text(
                          l10n.attachmentCache,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium
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
                      ? const _NoSelectionPane()
                      : _AttachmentPreview(
                          attachment: selected,
                          onDelete: () => _run(
                            () => ref
                                .read(attachmentRepositoryProvider)
                                .removeLocal(selected),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.attachmentCache), actions: actions),
      body: list,
    );
  }

  /// 一条附件的稳定键。`attId` 只在实例内唯一，两个实例会重号。
  static String _keyOf(MailAttachment item) =>
      '${item.profileId}:${item.attId}';

  /// 点一行。
  ///
  /// 窄屏：弹出动作面板（预览 / 打开 / 分享 / 另存为）—— 这一页本来就是
  /// 「清理的地方」，用户点一条十有八九是想打开看看再决定删不删。
  /// 宽屏：选中它、右栏出预览，动作面板从右栏的按钮进。
  void _open(MailAttachment item, {required bool panes}) {
    if (panes) {
      setState(() => _selectedKey = _keyOf(item));
      return;
    }
    showAttachmentActions(
      context: context,
      ref: ref,
      attachment: item,
      profileId: item.profileId,
    );
  }

  Future<void> _clearAll() async {
    final l10n = AppLocalizations.of(context);
    final ok = await _confirm(l10n.clearAllAttachmentsConfirm);
    if (!ok) return;
    await _run(() => ref.read(attachmentRepositoryProvider).clearAll());
  }

  Future<bool> _confirm(String message) async {
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
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

class _AttachmentRow extends ConsumerWidget {
  const _AttachmentRow({
    super.key,
    required this.attachment,
    required this.onDelete,
    required this.onOpen,
    this.selected = false,
  });

  final MailAttachment attachment;
  final VoidCallback onDelete;
  final VoidCallback onOpen;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final profile = ref.watch(profileByIdProvider(attachment.profileId));
    final color = InstanceColors.of(profile?.colorIndex ?? 0);

    return ListTile(
      selected: selected,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: color.withValues(alpha: 0.18),
        child: Icon(iconOf(attachment), size: 16, color: color),
      ),
      title: Text(
        attachment.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        <String>[
          // 实例名放进来：清缓存时用户需要知道这条是谁的。
          profile?.displayName ?? l10n.unknown,
          if (attachment.size > 0) formatAttachmentSize(attachment.size),
          if (attachment.downloadedAt != null)
            TimeUtils.fromNow(attachment.downloadedAt),
        ].join(' · '),
        style: theme.textTheme.labelSmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: l10n.delete,
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      ),
      onTap: onOpen,
    );
  }
}

/// 宽屏右栏：一个附件的预览。
///
/// **右栏就是一条预览通道**：能应用内预览的类型（图片 / PDF / Word / Excel /
/// PPT / CSV / 文本 / Markdown / 音频 / 视频）直接用邮件详情页那一套 viewer
/// 在当前这一栏里渲染（`buildAttachmentPreview` 的 `embedded: true`）。这一页
/// 存在的理由是「腾地方」，而「这个东西到底还值不值得留着」在大多数时候
/// 没法从文件名判断 —— 早先只有图片能看，其余一律是一张图标卡，用户被逼着
/// 先「用其他应用打开」才能决定删不删。
///
/// 没有 viewer 的类型（压缩包、`.doc` 这类老格式、未知二进制）仍然给
/// [_FileCard]：图标 + 文件名 + 落盘路径，路径是这一页的另一半用途。
/// 判据用的是 [canPreview] ——与附件面板里「预览」那一行的判据**同一个**，
/// 所以不会出现「右栏说能看、面板里没有预览」或者反过来。
///
/// 底部那一条（文件名 + 大小 + 打开方式 + 删除）两种形态都有：图标卡也要
/// 能打开和删除，能预览的更要。
class _AttachmentPreview extends ConsumerWidget {
  const _AttachmentPreview({
    required this.attachment,
    required this.onDelete,
  });

  final MailAttachment attachment;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final path = attachment.localPath;

    // 判据用 [canPreview]（类型 / 体积 / 平台 / viewer 有没有，四道都和
    // 附件面板里「预览」那一行**一模一样**）。**不能**只看
    // `buildAttachmentPreview` 返不返回 null：那个只判「有没有这个 kind 的
    // viewer」，不管体积与平台 —— 一份 50MB 的 docx 会在这一栏里被整份读进
    // 内存解析，Linux 上的 PDF 会当场抛。
    final viewer = path == null || path.isEmpty || !canPreview(attachment)
        ? null
        : buildAttachmentPreview(
            attachment: attachment,
            path: path,
            title: attachment.displayName,
            embedded: true,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          // `key` 不是可选的：换一条附件时**类型往往不变**（两个 PDF、两个
          // docx），没有 key 的话 `State` 会被复用，而几个 viewer 的
          // `late final _controller` / `_load()` 都只在 `initState` 里跑一次
          // —— 右栏会继续显示上一条的内容。`MailPanes` 给详情页挂 key 是
          // 同一个理由。
          child: KeyedSubtree(
            key: ValueKey<String>('${attachment.profileId}:${attachment.attId}'),
            child: viewer ?? _FileCard(attachment: attachment),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  attachment.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              SizedBox(
                width: 140,
                child: Text(
                  formatAttachmentSize(attachment.size),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
              IconButton(
                tooltip: l10n.openWith,
                icon: const Icon(Icons.open_in_new),
                onPressed: () => showAttachmentActions(
                  context: context,
                  ref: ref,
                  attachment: attachment,
                  profileId: attachment.profileId,
                ),
              ),
              IconButton(
                tooltip: l10n.delete,
                icon: Icon(Icons.delete_outline,
                    color: theme.colorScheme.error),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 没有预览的附件在右栏里的样子：图标 + 文件名 + 说明 + 落盘路径。
///
/// 路径要显示出来：这一页的另一半用途是「这些文件到底占在哪儿」，
/// 用户要去系统里手动核对时，唯一能对上的就是这串路径。
class _FileCard extends StatelessWidget {
  const _FileCard({required this.attachment});

  final MailAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final path = attachment.localPath;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              iconOf(attachment),
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              attachment.displayName,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              path == null || path.isEmpty ? l10n.unknown : path,
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

/// 宽屏右栏还没选中任何附件时的样子（与 `MailPanes._NoSelectionPane` 同一个意思）。
class _NoSelectionPane extends StatelessWidget {
  const _NoSelectionPane();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.attach_file, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            l10n.pickAttachment,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
