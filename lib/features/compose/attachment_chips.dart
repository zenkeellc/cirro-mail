import 'package:flutter/material.dart';

import '../../data/models/send_payload.dart';
import '../../l10n/app_localizations.dart';

/// 附件条：横向一排 chip + 一行「N 个附件 · 共 X MB」。
///
/// 用横向滚动而不是 `Wrap`：附件多起来（上限 10 个）时 `Wrap` 会长成两三行，
/// 把正文区挤掉；横滑只占一行，代价是超出部分要点一下才看得到 —— 这一点由
/// 末尾的「共 X MB」补上（用户真正关心的其实是总量，不是有哪几个）。
///
/// **这里不再有「+ 插入」与「添加附件」两颗按钮**：插入能力按类拆进了正文上方
/// 的常驻工具栏（`ComposeToolbar`），附件入口是那条工具栏上的回形针。这一条现在
/// 只负责**显示已经选了什么** —— 一件事一个地方。
class AttachmentChips extends StatelessWidget {
  const AttachmentChips({
    super.key,
    required this.attachments,
    required this.onRemove,
  });

  final List<SendAttachment> attachments;

  final ValueChanged<SendAttachment> onRemove;

  /// 附件总量（字节）。与 `ComposeState.attachmentBytes` 同口径 ——
  /// 传进来而不是在这里重算，避免两处算出不同的数字。
  int get _totalBytes =>
      attachments.fold<int>(0, (sum, a) => sum + a.size);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 没有附件时**整条不出现**：空了就是一行 44px 的空白，而它的存在
        // 意义全在 chips 上（入口已经在工具栏里了）。
        if (attachments.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: <Widget>[
                for (final attachment in attachments)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 6, bottom: 6),
                    child: InputChip(
                      avatar: const Icon(Icons.insert_drive_file, size: 16),
                      label: Text(
                        '${attachment.filename} · ${formatBytes(attachment.size)}',
                      ),
                      onDeleted: () => onRemove(attachment),
                      deleteButtonTooltipMessage: l10n.delete,
                    ),
                  ),
              ],
            ),
          ),
        if (attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              '${l10n.composeAttachmentCount(attachments.length)} · '
              '${l10n.composeAttachmentTotal(formatBytes(_totalBytes))}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: _totalBytes > _softLimitBytes
                    ? theme.colorScheme.error
                    : theme.colorScheme.outline,
              ),
            ),
          ),
      ],
    );
  }

  /// 与服务端同一组值（`ComposeController` 里的私有常量）：超了就变红，
  /// 真正的拦截在发送前的 `SendPayload.validate`。
  static const int _softLimitBytes = 20 * 1024 * 1024;
}

/// 字节数 → 人读的短串。
///
/// 单独抽出来是因为它同时被写邮件页和发件箱页用；两处各写一份的话，
/// 「15 MB」和「15000 KB」会出现在同一个屏幕上。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
