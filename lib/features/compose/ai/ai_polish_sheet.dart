import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../ai/ai_prompts.dart';
import '../../ai/ai_run.dart';
import '../../ai/ai_stream_view.dart';

/// ① 整篇润色：**先设参数，再点「生成」**。
///
/// 与旧行为的区别就是这一条：以前 AppBar 上那颗图标**点一下就直接调模型**
/// （用户没有机会指定语气或额外要求，只能等结果出来不满意再点一次）。现在它
/// 只负责开这个面板，真正发请求的是面板里的「生成」。
///
/// ## 两个参数是**彼此独立**的
///
/// [RewriteTone] chips 与自定义指令框是两件不同的东西：前者是「改写成什么
/// 风格」，后者是「这次尤其要注意什么」。指令框里的字**不会**与邮件正文拼进
/// 同一个位置 —— 它一路作为 `extraInstruction` 传给 `AiPrompts.rewrite`，
/// prompt 里它自成一节（见那里的 `额外要求：`）。所以用户在这里写的任何内容
/// 都只是「对模型的指令」，不会被当成正文的一部分。
///
/// ## 返回什么
///
/// 与 `AiDraftSheet` 同型：`Navigator.pop(String?)`。点「替换全文」回生成的
/// 文本；其余（丢弃 / 划走面板）回 `null`。**只回文本、不回动作** ——
/// 这个面板只有「替换全文」一个落地动作（引用区由调用方保护），不像
/// `AiRewriteSheet` 那样要区分替换 / 插入到下方。
class AiPolishSheet extends StatefulWidget {
  const AiPolishSheet({
    super.key,
    required this.start,
    this.initialTone = RewriteTone.polish,
  });

  /// 起一次生成。由调用方接上 `AiService`（面板不认识它，只用这个函数）。
  final AiRun Function(RewriteTone tone, String? extra) start;

  final RewriteTone initialTone;

  @override
  State<AiPolishSheet> createState() => _AiPolishSheetState();
}

class _AiPolishSheetState extends State<AiPolishSheet> {
  late RewriteTone _tone = widget.initialTone;
  final TextEditingController _extra = TextEditingController();

  /// **null 表示「还没生成」**。不拿 `AiRun.pending()` 当初始态：那个的
  /// `running` 是 true，面板一打开就转圈 —— 而用户连参数都还没设。
  AiRun? _run;

  @override
  void dispose() {
    _run?.dispose();
    _extra.dispose();
    super.dispose();
  }

  /// 点「生成」/「重新生成」才走这里。**换语气 chip 不调它** —— 换 chip 只是
  /// 改一个选中态，用户点完「生成」才发请求。
  void _generate() {
    setState(() {
      // 旧的先收摊：`cancel()` 之后流还会回调一次，而那时 notifier 已经被
      // 回收（见 `AiRun.dispose` 的注释）。
      _run?.dispose();
      final extra = _extra.text.trim();
      _run = widget.start(_tone, extra.isEmpty ? null : extra);
    });
  }

  void _replaceAll() {
    final text = _run?.text.value ?? '';
    if (text.trim().isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.aiPolishTooltip, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                // 边界要在用户按下「生成」之前就说清 —— 引用区不会被改，
                // 也不必为它操心。
                l10n.aiPolishNote,
                key: const ValueKey('polish-note'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),

              // 语气。**点一下只换选中态**，不触发任何请求。
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final tone in RewriteTone.values)
                    ChoiceChip(
                      key: ValueKey('polish-tone-${tone.name}'),
                      label: Text(tone.label),
                      selected: _tone == tone,
                      onSelected: (_) => setState(() => _tone = tone),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // 自定义指令：**与邮件内容完全独立的一个输入框**。
              TextField(
                key: const ValueKey('polish-extra'),
                controller: _extra,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: l10n.aiPolishExtraHint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),

              if (_run == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.aiPolishIdle,
                    style: theme.textTheme.bodySmall,
                  ),
                )
              else
                AiStreamView(run: _run!, placeholder: '正在润色…'),
              const SizedBox(height: 8),

              Row(
                children: <Widget>[
                  if (_run != null)
                    // 订阅 running：不订阅的话按钮的可点状态不会跟着变。
                    ValueListenableBuilder<bool>(
                      valueListenable: _run!.running,
                      builder: (context, running, _) => TextButton.icon(
                        key: const ValueKey('polish-retry'),
                        onPressed: running ? null : _generate,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('重新生成'),
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey('polish-generate'),
                    // 生成过一次之后它只在「重新生成」旁边留着（那颗更明确），
                    // 免得同一件事有两个按钮。
                    onPressed: _run == null ? _generate : null,
                    child: Text(l10n.aiPolishGenerate),
                  ),
                  if (_run != null) ...<Widget>[
                    const SizedBox(width: 8),
                    _ReplaceButton(run: _run!, onReplace: _replaceAll),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「替换全文」：**只有生成成功才可点**。
///
/// 出错时不给（没内容可写）、生成中不给（写一个半截句子进正文比不写糟）、
/// 用户自己按停的例外（半截结果留在眼前，他觉得能用就能用）。
class _ReplaceButton extends StatelessWidget {
  const _ReplaceButton({required this.run, required this.onReplace});

  final AiRun run;
  final VoidCallback onReplace;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: run.running,
      builder: (context, running, _) => ValueListenableBuilder<String>(
        valueListenable: run.message,
        builder: (context, message, _) => ValueListenableBuilder<String>(
          valueListenable: run.text,
          builder: (context, text, _) {
            final ready = !running && message.isEmpty && text.trim().isNotEmpty;
            return OutlinedButton(
              key: const ValueKey('polish-replace'),
              onPressed: ready ? onReplace : null,
              child: Text(l10n.aiPolishReplaceAll),
            );
          },
        ),
      ),
    );
  }
}
