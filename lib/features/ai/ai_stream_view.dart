import 'package:flutter/material.dart';

import 'ai_run.dart';

/// 一次生成的公共显示：文字 + 转圈 + 停止 + 出错提示。
///
/// 四个 AI 面板都要这一块，各写一份必然出现「有一个忘了在失败时关掉转圈」。
/// 它**只读 [AiRun]**，不碰编辑器也不知道自己在哪个面板里 —— 于是能单独测。
class AiStreamView extends StatelessWidget {
  const AiStreamView({
    super.key,
    required this.run,
    this.placeholder = '正在生成…',
    this.textStyle,
    this.maxHeight = 240,
  });

  final AiRun run;

  /// 还没出第一个字时显示的话。
  final String placeholder;

  final TextStyle? textStyle;

  /// 生成结果区的高度上限：AI 可能吐很长，不能把面板顶爆。
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<String>(
      valueListenable: run.message,
      builder: (context, message, _) {
        if (message.isNotEmpty) {
          // 出错/没开始都走这里。**不留转圈** —— 这是四个面板最容易漏的一条。
          return _Notice(message: message, onRetry: null);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                child: ValueListenableBuilder<String>(
                  valueListenable: run.text,
                  builder: (context, text, _) {
                    if (text.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 10),
                            Text(placeholder, style: theme.textTheme.bodySmall),
                          ],
                        ),
                      );
                    }
                    return SelectableText(text, style: textStyle);
                  },
                ),
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: run.running,
              builder: (context, running, _) => running
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('ai-stop'),
                        onPressed: run.stop,
                        icon: const Icon(Icons.stop_circle_outlined, size: 18),
                        label: const Text('停止'),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }
}

/// 出错或「没配好」时那一句提示。**不是** SnackBar：它要留在面板里，
/// 用户看完就知道该怎么改。
class _Notice extends StatelessWidget {
  const _Notice({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}
