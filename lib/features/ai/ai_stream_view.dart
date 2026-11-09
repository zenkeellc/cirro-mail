import 'package:cirro_mail_ext/cirro_mail_ext.dart';
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
          //
          // 提示下方是扩展的**动作槽**（设计稿 §5.3 / §5.5 / 接缝 S7）：
          // 「去订阅 / 去填 Key / 重新登录」这类下一步的文案与落点都是实现方
          // 的，核心只提供位置。空注册表（公开版）时列表为空、这一支原样返回
          // 那颗提示 —— 失败态的外观逐像素不变。
          final extras = AppExtensionRegistry.instance.aiNoticeExtras(context);
          if (extras.isEmpty) return _Notice(message: message);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Notice(message: message),
              // 动作紧贴它解释的那句话：中间不加分隔线，读起来是一块。
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Wrap(spacing: 8, runSpacing: 4, children: extras),
              ),
            ],
          );
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
///
/// 它**自己不带动作**：「再去试一次 / 去订阅 / 去填 Key」这些落点分两处 ——
/// 面板自己的「重新生成」留在面板底栏，实现方的引导走上面的 `aiNoticeExtras`
/// 槽。所以这里只需要一句话。
class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

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

/// AI 输出处的**来源署名**：`[hub] 订阅通道`（设计稿 §7.5、接缝 S5）。
///
/// 为什么住在 `ai_stream_view.dart` 而不是新开一个文件：它的两个使用方
/// （五个撰写面板、建议面板）本就已经 import 这个文件 —— 这里放的是「AI 结果
/// 长什么样」的公共积木，署名与结果在同一处出现，为三十行新开一个文件只会多
/// 一个 import。
///
/// 只有 [label] 非空才调用它：`null` 是公开版与 BYOK 的常态，那时调用方连
/// 这个 widget 都不建（`AiPanelHeader` 会原样退回一个 [Text]），所以「空注册表
/// = 逐像素不变」这条护栏不受影响。
class AiSourceChip extends StatelessWidget {
  const AiSourceChip({super.key, required this.label});

  /// 来源的显示名，由实现方给（`AiTransport.sourceLabel`），核心只原样显示。
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 12px 灰：它是**注脚**，不能与标题抢注意力，也不能盖在正文上。
    final color = theme.colorScheme.onSurfaceVariant;
    return ConstrainedBox(
      // 内层是 `Flexible(child: Text)`，需要一个**有界**宽度才不会在
      // `Row` 里抛「非零 flex + 无界约束」。放在这里而不是指望每个调用点
      // 都包一层：AppBar 的 actions、面板抬头行给的是两种不同约束。
      constraints: const BoxConstraints(maxWidth: 220),
      child: Container(
        // 最小高度而不是写死 18：200% 字号下文字撑高时要跟着长。
        constraints: const BoxConstraints(minHeight: 18),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.hub_outlined, size: 12, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AI 面板抬头的**标题行**：标题左、来源 chip 右（设计稿 §6.3 / §7.5）。
///
/// 抽出来的唯一理由是「`sourceLabel == null` 时必须**逐像素**等于从前那一颗
/// 标题 `Text`」：五个面板各写一遍条件分支，迟早有一个写成 `Row` 里套
/// `Expanded` 的版本，那会连公开版的外观一起改掉。这里把该分支收在一处。
class AiPanelHeader extends StatelessWidget {
  const AiPanelHeader({super.key, required this.title, this.sourceLabel});

  final String title;

  /// 来源署名。null（公开版 / BYOK）= 不画 chip，只画标题。
  final String? sourceLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Text(title, style: theme.textTheme.titleMedium);
    final label = sourceLabel;
    // 没有署名就退回原本那颗 `Text` —— 不是「Row 里只有它」，布局逐像素一致。
    if (label == null) return heading;
    return Row(
      children: <Widget>[
        // 标题吃掉剩余宽度：窗口窄时先省略标题，chip 不换行。
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        AiSourceChip(label: label),
      ],
    );
  }
}
