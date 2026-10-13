import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/database.dart';
import '../../core/db/mappers.dart' show decodeAttachmentPaths;
import '../../core/theme/breakpoints.dart';
import '../../core/theme/instance_colors.dart';
import '../../core/util/time_utils.dart';
import '../../data/models/profile.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/profile_providers.dart';
import '../../router.dart';
import '../mail_list/mail_panes.dart' show PaneHeader;
import '../sync/sync_status_panel.dart';
import 'compose_controller.dart';
import 'compose_text.dart';
import 'html/document_codec.dart';

/// 草稿箱。
///
/// **纯本地**，与 Web 端不互通：Web 端的草稿存在浏览器 IndexedDB 里，
/// App 读不到也写不进去（服务端根本没有草稿这个实体）。这件事必须写在页面上
/// —— 用户换到电脑上打不开手机里存了一半的信，会以为是同步坏了。
///
/// 列出**全部实例**的草稿：草稿是「我在这台设备上没写完的东西」，
/// 按实例分开看只会让人找不到它。
///
/// ## 外壳与收件箱一致（spec §2.4）
///
/// 顶部条宽屏走 [PaneHeader]、窄屏走 `AppBar`，右上角都是同步按钮。
///
/// **宽屏没有右栏** —— 三个本机页面里唯一的行为差别：草稿点开不是「看」，
/// 而是**进写邮件页继续编辑**（spec §2.4），所以列表栏直接铺满，
/// 不像发件箱那样还要留一块只读预览。
class DraftsScreen extends ConsumerWidget {
  const DraftsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final drafts = ref.watch(draftsProvider(null)).value ?? const <DbDraft>[];
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];

    final list = drafts.isEmpty
        ? _Empty(hint: l10n.draftEmpty, note: l10n.draftsHint)
        : ListView.separated(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: drafts.length + 1,
            separatorBuilder: (_, index) =>
                index == 0 ? const SizedBox.shrink() : const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Text(
                    l10n.draftsHint,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                );
              }
              final draft = drafts[index - 1];
              return _DraftTile(
                draft: draft,
                profile: _profileOf(profiles, draft.profileId),
                onOpen: () => _open(context, draft),
                onDelete: () => _delete(context, ref, draft),
              );
            },
          );

    if (Breakpoints.panesOf(context)) {
      // 顶部条撑 `PaneHeader`（52）而不是 `AppBar`（56）——「外壳一致」里
      // 最实的一条就是**顶部条高度**：宽屏下从收件箱切到草稿箱，
      // 标题与同步按钮不该上下跳 4px。
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: <Widget>[
              PaneHeader(
                actions: const <Widget>[SyncStatusButton()],
                child: Text(
                  l10n.drafts,
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
        title: Text(l10n.drafts),
        actions: const <Widget>[SyncStatusButton()],
      ),
      body: list,
    );
  }

  Profile? _profileOf(List<Profile> profiles, String id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// 打开草稿 = 进写邮件页并带着这条 id（见 `ComposeArgs.draftId`）。
  ///
  /// 不做「先删掉再新建」：那样中途反悔就没有退路了。写邮件页自己会在
  /// 原来的那一行上更新（`LocalDao.saveDraft(id:)`），一条草稿自始至终
  /// 只占一行。
  void _open(BuildContext context, DbDraft draft) {
    context.push(
      Routes.composeOf(profileId: draft.profileId, draftId: draft.id),
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    DbDraft draft,
  ) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.draftDiscardConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              l10n.draftDiscard,
              style: TextStyle(color: Theme.of(dialogContext).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(databaseProvider).localDao.deleteDraft(draft.id);
  }

  /// 带 `@visibleForTesting` 的入口，只为让摘要逻辑可单测。
  @visibleForTesting
  static String previewForTest(String content) => _preview(content);

  /// 草稿摘要。
  ///
  /// `content` 从这一轮起是 **Delta JSON**（`DocumentCodec.encode` 的输出），
  /// 但库里还躺着**旧格式的纯文本**草稿 —— `DocumentCodec.decode` 两种都能吃
  /// （它靠嗅探，不做格式迁移），所以这里只需要走它一遍再取纯文本。
  ///
  /// 带嵌入的文档在纯文本里是 `￼`（对象替换符）—— 压掉它，否则那些
  /// 摘要会以一个看不见的字符开头，看起来像缩进错位。
  static String _preview(String content) {
    if (content.isEmpty) return '';
    final text = DocumentCodec.decode(content)
        .toPlainText()
        .replaceAll('￼', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // 兜底：`DocumentCodec.decode` 解析不出来时**退回「当纯文本」**，于是
    // 一份畸形 Delta 会被原样显示成一串 JSON。原文是 Delta 形状、解出来却
    // 还带着 `"insert"` 的，就是这种情况 —— 列表里宁可空着。
    //
    // `contains` 必须带引号：不带的话，一封正文里恰好写了 `insert` 这个词
    // 的正常邮件会被误伤成空摘要。
    if (text.contains('"insert"')) return '';
    return text;
  }
}

class _DraftTile extends StatelessWidget {
  const _DraftTile({
    required this.draft,
    required this.profile,
    required this.onOpen,
    required this.onDelete,
  });

  final DbDraft draft;
  final Profile? profile;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final recipients = decodeRecipientAddresses(draft.recipientsJson);
    final attachmentCount =
        decodeAttachmentPaths(draft.attachmentPathsJson).length;

    return ListTile(
      isThreeLine: true,
      leading: CircleAvatar(
        backgroundColor: profile == null
            ? theme.colorScheme.outline
            : InstanceColors.of(profile!.colorIndex),
        child: const Icon(Icons.edit_note, size: 18, color: Colors.white),
      ),
      title: Text(
        draft.subject.trim().isEmpty ? l10n.noSubject : draft.subject.trim(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            // 收件人还没填也是常态（写了一半就走）—— 那就拿正文开头当预览，
            // 否则一行草稿看上去全是「无主题 · 无收件人」，分不出哪个是哪个。
            recipients.isNotEmpty
                ? recipients.join(', ')
                : DraftsScreen._preview(draft.content),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Row(
            children: <Widget>[
              Text(
                TimeUtils.fromNow(draft.updatedAt),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              if (attachmentCount > 0) ...<Widget>[
                const SizedBox(width: 8),
                Icon(Icons.attach_file,
                    size: 12, color: theme.colorScheme.outline),
                Text(
                  '$attachmentCount',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
              if (profile != null) ...<Widget>[
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
        ],
      ),
      trailing: IconButton(
        tooltip: l10n.draftDiscard,
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      ),
      onTap: onOpen,
    );
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
              Icons.drafts_outlined,
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
