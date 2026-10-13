import 'package:flutter/material.dart';

import '../../ai/ai_prompts.dart';
import '../../ai/ai_run.dart';
import '../../ai/ai_stream_view.dart';

/// 用户在改写面板里做出的选择。
enum RewriteAction { replace, insertBelow, discard }

/// 面板关掉时带回的东西。**文本与动作一起返回** —— 分成两个回调的话，
/// 「用户点了替换，但在回调里读到的 text 已经是下一次生成的了」这种竞态
/// 迟早会出现（重新生成之后旧的监听者还挂着）。
class RewriteOutcome {
  const RewriteOutcome({required this.action, required this.text});

  final RewriteAction action;
  final String text;
}

/// ① 选中即改：原文 → 建议 → 替换 / 插入到下方 / 丢弃。
///
/// 做成一个**返回结果**的面板而不是就地改文档，是因为这三件事里有两件
/// （替换、插入）都不可逆地动文档，用户需要先把建议读一遍。spec §4.3① 的
/// 三个按钮就是这个意思。
class AiRewriteSheet extends StatefulWidget {
  const AiRewriteSheet({
    super.key,
    required this.original,
    required this.start,
    this.initialTone = RewriteTone.polish,
  });

  /// 被改写的原文。**只用来显示**（同时出现在顶部，用户好对照）。
  final String original;

  /// 起一次生成。由调用方接上 `AiService`（面板不认识它，只用这个函数）。
  final AiRun Function(RewriteTone tone, String? extra) start;

  final RewriteTone initialTone;

  @override
  State<AiRewriteSheet> createState() => _AiRewriteSheetState();
}

class _AiRewriteSheetState extends State<AiRewriteSheet> {
  late RewriteTone _tone = widget.initialTone;

  /// **null 表示「还没生成」**。以前这里是 `late AiRun _run = widget.start(...)`
  /// —— 面板一构造就发请求，用户连语气都没看就把钱花了。现在只有点「生成」
  /// 才发（与 `AiDraftSheet`、`AiPolishSheet` 同一条规矩）。
  AiRun? _run;
  final TextEditingController _extra = TextEditingController();
  bool _showExtra = false;

  @override
  void dispose() {
    _run?.dispose();
    _extra.dispose();
    super.dispose();
  }

  /// 点「生成」/「重新生成」才走这里。**换语气 chip 不调它** —— 换 chip 只是
  /// 改一个选中态，用户点完「生成」才发请求。
  ///
  /// 换一个 `AiRun`：把上一次的增量与错误一起丢掉。不换的话上一次的 `message`
  /// 会留着，用户一按就看不到新结果。
  void _regenerate() {
    setState(() {
      _run?.dispose();
      _run = widget.start(_tone, _showExtra ? _extra.text : null);
    });
  }

  void _finish(RewriteAction action) {
    Navigator.of(context).pop(RewriteOutcome(
      action: action,
      text: _run?.text.value ?? '',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('改写', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),

            // 原文：只读，且**限高**（选中一段长文时不能把面板撑爆）。
            Container(
              constraints: const BoxConstraints(maxHeight: 96),
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: Text(
                  widget.original,
                  key: const ValueKey('ai-original'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
            const SizedBox(height: 12),

            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final tone in RewriteTone.values)
                  ChoiceChip(
                    key: ValueKey('tone-${tone.name}'),
                    label: Text(tone.label),
                    selected: _tone == tone,
                    // **只换选中态，不发请求**：发请求是下面「生成」按钮的事。
                    onSelected: (_) => setState(() => _tone = tone),
                  ),
              ],
            ),
            const SizedBox(height: 8),

            // 「额外要求」默认收起 —— 十次改写里有九次用不上，摊开只会
            // 让面板看起来更复杂。
            if (_showExtra)
              TextField(
                key: const ValueKey('ai-extra'),
                controller: _extra,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '额外要求（可选），例如：保留专业术语',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('ai-extra-toggle'),
                  onPressed: () => setState(() => _showExtra = true),
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('额外要求'),
                ),
              ),
            const Divider(height: 16),

            if (_run == null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '选好语气后点「生成」。',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              AiStreamView(run: _run!, placeholder: '正在改写…'),
            const SizedBox(height: 8),
            _Actions(
              run: _run,
              onFinish: _finish,
              onRegenerate: _regenerate,
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部的按钮行：**「生成」在还没跑过时出现，之后换成「重新生成」**；
/// 三个动作只在成功时出现。
///
/// 为什么成功时也留「重新生成」：改写十次有九次第一版不够好，用户想「换个说法
/// 再试一次」是常态。把它藏起来只会逼用户关掉面板重选一遍原文。
class _Actions extends StatelessWidget {
  const _Actions({
    required this.run,
    required this.onFinish,
    required this.onRegenerate,
  });

  /// **可空**：null = 还没生成过（面板刚打开）。那时只显示一颗「生成」。
  final AiRun? run;
  final void Function(RewriteAction action) onFinish;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    final run = this.run;
    if (run == null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          FilledButton(
            key: const ValueKey('rewrite-generate'),
            onPressed: onRegenerate,
            child: const Text('生成'),
          ),
        ],
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: run.running,
      builder: (context, running, _) => ValueListenableBuilder<String>(
        valueListenable: run.message,
        builder: (context, message, _) => ValueListenableBuilder<String>(
          valueListenable: run.text,
          builder: (context, text, _) {
            // 成功 = 跑完了、没出错、而且真的拿到字。
            final ready = !running && message.isEmpty && text.trim().isNotEmpty;
            return Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton.icon(
                  key: const ValueKey('ai-retry'),
                  onPressed: running ? null : onRegenerate,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重新生成'),
                ),
                const Spacer(),
                // 只有成功才给写进文档的动作。**出错**与**一个字都没拿到**
                // 一律不给 —— 那时候面板里根本没有内容可写，给了按钮只会让
                // 用户点下去之后发现文档没变。用户自己按停的情况例外：半截
                // 结果留在面板里看得见，他觉得能用就可以用（见 `AiRun.stop`）。
                if (ready) ...<Widget>[
                  TextButton(
                    key: const ValueKey('ai-discard'),
                    onPressed: () => onFinish(RewriteAction.discard),
                    child: const Text('丢弃'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const ValueKey('ai-insert-below'),
                    onPressed: () => onFinish(RewriteAction.insertBelow),
                    child: const Text('插入到下方'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('ai-replace'),
                    onPressed: () => onFinish(RewriteAction.replace),
                    child: const Text('替换'),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
