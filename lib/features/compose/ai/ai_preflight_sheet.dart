import 'package:flutter/material.dart';

import '../../ai/ai_prompts.dart';
import '../../ai/ai_run.dart';
import '../../ai/ai_stream_view.dart';
import '../../ai/preflight.dart';

/// 用户在发送前检查里做的决定。
enum PreflightDecision {
  /// 仍然发送（本地/AI 的建议都只是建议，spec §4.3④ 明确不拦）。
  sendAnyway,

  /// 回去改。
  backToEdit,
}

/// ④b 发送前检查：**本地规则 + 可选的模型建议**，两段分得很清楚。
///
/// 为什么分两段而不是混成一个列表：本地那几条（声明了附件却没附件、主题空着）
/// 是**确定的**、零成本的、每次发送都能给；模型那几条是概率性的、要花钱的、
/// 要不要看由用户决定。混在一起的话，用户没法判断「这条到底靠不靠谱」——
/// 而「要不要为了它停下来」正是他要做的判断。
///
/// **本地那段永远先算完再开面板**（调用方算好传进来），所以没配 Key 的用户
/// 也能拿到最有价值的那条检查。
class AiPreflightSheet extends StatefulWidget {
  const AiPreflightSheet({
    super.key,
    required this.local,
    this.startReview,
  });

  /// 本地规则的结论。**由调用方算好**（`AiPreflight.checkLocal`）——
  /// 于是面板自己不需要正文、主题、附件数这些东西。
  final List<PreflightFinding> local;

  /// 起一次模型检查。**null = 这次不给模型检查**（没配 Key、或用户在设置里
  /// 关掉了）——这时那一整段都不显示，而不是给一个点不动的按钮。
  final AiRun Function()? startReview;

  @override
  State<AiPreflightSheet> createState() => _AiPreflightSheetState();
}

class _AiPreflightSheetState extends State<AiPreflightSheet> {
  /// **不自动开模型检查**：它要花用户自己的 token，而每次点发送都自动跑一遍
  /// 是不可接受的（用户按「仍然发送」时并没有同意再花一次钱）。
  AiRun? _review;

  @override
  void dispose() {
    _review?.dispose();
    super.dispose();
  }

  void _startReview() {
    if (widget.startReview == null) return;
    setState(() {
      // 先收摊再换（见 `AiRun.dispose` 的注释）。
      _review?.dispose();
      _review = widget.startReview!();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('发送前检查', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),

              Text('本地检查', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              if (widget.local.isEmpty)
                Text(
                  key: const ValueKey('preflight-local-clean'),
                  '没有发现问题',
                  style: theme.textTheme.bodySmall,
                )
              else
                // 用下标做 key（不用 `indexOf(finding)`：两条文案相同的发现在
                // `indexOf` 眼里是同一条，key 会撞）。
                for (var i = 0; i < widget.local.length; i++)
                  _FindingTile(
                    key: ValueKey('local-$i'),
                    finding: widget.local[i],
                  ),

              if (widget.startReview != null) ...<Widget>[
                const Divider(height: 24),
                Text('AI 建议', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                if (_review == null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('preflight-ask-ai'),
                      onPressed: _startReview,
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('让 AI 再看看（会消耗一次调用）'),
                    ),
                  )
                else ...<Widget>[
                  AiStreamView(run: _review!, placeholder: '正在检查…'),
                  _ReviewList(run: _review!),
                ],
              ],
              const SizedBox(height: 12),

              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    key: const ValueKey('preflight-back'),
                    onPressed: () =>
                        Navigator.of(context).pop(PreflightDecision.backToEdit),
                    child: const Text('返回修改'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('preflight-send'),
                    onPressed: () =>
                        Navigator.of(context).pop(PreflightDecision.sendAnyway),
                    child: const Text('仍然发送'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一条本地发现。**不带任何按钮** —— 它只是提示用户去改，检查面板不负责改。
class _FindingTile extends StatelessWidget {
  const _FindingTile({super.key, required this.finding});

  final PreflightFinding finding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = finding.severity == PreflightSeverity.warning;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            warning ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: warning ? theme.colorScheme.error : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              finding.message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: warning ? theme.colorScheme.error : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 模型给的那几条。用 `AiPrompts.parseLines` 拆 —— 与标题候选同一套解析，
/// 于是「模型多顶一句『没有问题』」这类事只在一个地方处理。
class _ReviewList extends StatelessWidget {
  const _ReviewList({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: run.running,
      builder: (context, running, _) => ValueListenableBuilder<String>(
        valueListenable: run.message,
        builder: (context, message, _) => ValueListenableBuilder<String>(
          valueListenable: run.text,
          builder: (context, text, _) {
            // 出错时由 `AiStreamView` 显示原因，这里不再补一句。
            if (running || message.isNotEmpty) return const SizedBox.shrink();
            final lines = AiPrompts.parseLines(text);
            if (lines.isEmpty) {
              return Text(
                key: const ValueKey('preflight-ai-clean'),
                'AI 也没看出问题',
                style: Theme.of(context).textTheme.bodySmall,
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var i = 0; i < lines.length; i++)
                  Padding(
                    key: ValueKey('ai-finding-$i'),
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Icon(Icons.lightbulb_outline, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            lines[i],
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
