import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// 发送中的进度卡片（模态，不可点掉）。
///
/// 为什么**不可取消**：`/email/send` 没有幂等键，请求发到一半撤掉，
/// 服务端可能已经落库并投递了 —— 那时用户看到的是「已取消」，而收件人
/// 其实收到了。所以这里没有取消按钮，只有进度。
///
/// [progress] 为 null 表示**进度不可知**（body 还在组装、或服务端还不认识
/// `Content-Length`）—— 那时显示不确定态，而不是假的 0%。
class SendProgressSheet extends StatelessWidget {
  const SendProgressSheet({super.key, required this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final value = progress;
    final percent = value == null ? null : (value * 100).clamp(0, 100).round();

    return AlertDialog(
      title: Text(l10n.sending),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LinearProgressIndicator(value: value),
          const SizedBox(height: 12),
          Text(
            percent == null
                ? l10n.sending
                : l10n.sendingProgress(percent),
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 8),
          // 大附件走的是「边编码边上传」，这一步最长。提前说明，
          // 免得用户以为卡死了。
          Text(
            l10n.composeLargeAttachmentHint,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
      actions: const <Widget>[],
    );
  }
}
