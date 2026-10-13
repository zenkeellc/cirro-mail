import 'package:flutter/material.dart';

import '../../ai/ai_prompts.dart';
import '../../ai/ai_run.dart';
import '../../ai/ai_stream_view.dart';

/// 起草面板要的东西。做成一个对象而不是一串位置参数：**这些值要一起被断言**
/// （「用当前主题」这条开关直接影响 prompt 里有没有主题），凑在一起测试好读。
class DraftRequest {
  const DraftRequest({
    required this.points,
    required this.tone,
    required this.length,
    required this.useSubject,
  });

  final String points;
  final RewriteTone tone;
  final DraftLength length;

  /// 是否把当前主题告诉模型。**只在面板真的有主题可给时才会是 true** ——
  /// 没有主题时那个开关根本不显示，用户不会看到「用当前主题」这种空话。
  final bool useSubject;

  @override
  String toString() =>
      'DraftRequest(${tone.name}, ${length.name}, useSubject=$useSubject)';
}

/// ② 要点成文：给几条要点 → 一整封正文 → 插进正文。
///
/// 与改写面板（D12）的区别在**起点**：改写是「有原文、换个说法」，起草是
/// 「什么都没有、从要点写」。所以这里的核心是那几行要点，以及两个会影响
/// 结果的旋钮（语气、篇幅）。
class AiDraftSheet extends StatefulWidget {
  const AiDraftSheet({
    super.key,
    required this.start,
    this.subject,
    this.initialTone = RewriteTone.polish,
    this.initialLength = DraftLength.medium,
  });

  /// 起一次生成，由调用方接上 `AiService`。
  final AiRun Function(DraftRequest request) start;

  /// 当前邮件主题。为空时面板**不显示**「用当前主题」这个开关。
  final String? subject;

  final RewriteTone initialTone;
  final DraftLength initialLength;

  @override
  State<AiDraftSheet> createState() => _AiDraftSheetState();
}

class _AiDraftSheetState extends State<AiDraftSheet> {
  final TextEditingController _points = TextEditingController();
  late RewriteTone _tone = widget.initialTone;
  late DraftLength _length = widget.initialLength;
  var _useSubject = true;

  /// **null 表示「还没生成」**。不拿 `AiRun.pending()` 当初始态：那个的
  /// `running` 是 true，面板一打开就会转圈 —— 而用户连要点都还没填。
  AiRun? _run;

  bool get _hasSubject => (widget.subject ?? '').trim().isNotEmpty;

  @override
  void dispose() {
    _run?.dispose();
    _points.dispose();
    super.dispose();
  }

  bool get _canGenerate => _points.text.trim().isNotEmpty;

  void _generate() {
    if (!_canGenerate) return;
    setState(() {
      // 旧的先收摊：`cancel()` 之后流还会回调一次，而那时 notifier 已经
      // 被回收（见 `AiRun.dispose` 的注释）。
      _run?.dispose();
      _run = widget.start(DraftRequest(
        points: _points.text.trim(),
        tone: _tone,
        length: _length,
        // 没有主题时一律 false —— 免得把「空主题」当主题发给模型。
        useSubject: _hasSubject && _useSubject,
      ));
    });
  }

  void _insert() {
    final text = _run?.text.value ?? '';
    if (text.trim().isEmpty) return;
    Navigator.of(context).pop(text);
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
              Text('AI 起草', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('draft-points'),
                controller: _points,
                minLines: 3,
                maxLines: 6,
                // 要点一变，「生成」按钮的可点状态就得跟着变。
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '写几条要点，一行一条。例如：\n周四下午三点评审顺延\n新时间待定',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),

              _ChipRow<RewriteTone>(
                keyPrefix: 'tone',
                values: RewriteTone.values,
                isSelected: (tone) => _tone == tone,
                labelOf: (tone) => tone.label,
                onPick: (tone) => setState(() => _tone = tone),
              ),
              const SizedBox(height: 4),
              _ChipRow<DraftLength>(
                keyPrefix: 'length',
                values: DraftLength.values,
                isSelected: (length) => _length == length,
                labelOf: (length) => length.label,
                onPick: (length) => setState(() => _length = length),
              ),

              if (_hasSubject)
                CheckboxListTile(
                  key: const ValueKey('draft-use-subject'),
                  value: _useSubject,
                  onChanged: (v) => setState(() => _useSubject = v ?? false),
                  title: const Text('把当前主题也告诉 AI'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              const Divider(height: 16),

              if (_run == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '填好要点后点「生成」',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              else
                AiStreamView(run: _run!, placeholder: '正在起草…'),
              const SizedBox(height: 8),

              Row(
                children: <Widget>[
                  if (_run != null)
                    // 订阅 running：不订阅的话按钮的可点状态**不会跟着变**
                    // （build 里读 `.value` 只读一次）。
                    ValueListenableBuilder<bool>(
                      valueListenable: _run!.running,
                      builder: (context, running, _) => TextButton.icon(
                        key: const ValueKey('ai-retry'),
                        onPressed: running ? null : _generate,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('重新生成'),
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey('draft-generate'),
                    onPressed: _run == null
                        ? (_canGenerate ? _generate : null)
                        : null,
                    child: const Text('生成'),
                  ),
                  if (_run != null) ...<Widget>[
                    const SizedBox(width: 8),
                    _InsertButton(run: _run!, onInsert: _insert),
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

/// 「插入正文」：**只有生成成功才可点**。
///
/// 出错时不给（没内容可插），生成中不给（插一个半截句子进去比不插糟），
/// 用户自己按停的例外（半截留在眼前，他觉得能用就能用）。
class _InsertButton extends StatelessWidget {
  const _InsertButton({required this.run, required this.onInsert});

  final AiRun run;
  final VoidCallback onInsert;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: run.running,
      builder: (context, running, _) => ValueListenableBuilder<String>(
        valueListenable: run.message,
        builder: (context, message, _) => ValueListenableBuilder<String>(
          valueListenable: run.text,
          builder: (context, text, _) {
            final ready = !running && message.isEmpty && text.trim().isNotEmpty;
            return OutlinedButton(
              key: const ValueKey('draft-insert'),
              onPressed: ready ? onInsert : null,
              child: const Text('插入正文'),
            );
          },
        ),
      ),
    );
  }
}

/// 一行单选的 chip。语气与篇幅两组长得一样，抽出来省得两份样式慢慢跑偏。
class _ChipRow<T> extends StatelessWidget {
  const _ChipRow({
    required this.keyPrefix,
    required this.values,
    required this.isSelected,
    required this.labelOf,
    required this.onPick,
  });

  final String keyPrefix;
  final List<T> values;
  final bool Function(T value) isSelected;
  final String Function(T value) labelOf;
  final void Function(T value) onPick;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: <Widget>[
        for (final value in values)
          ChoiceChip(
            key: ValueKey('$keyPrefix-${_slug(value)}'),
            label: Text(labelOf(value)),
            selected: isSelected(value),
            onSelected: (_) => onPick(value),
          ),
      ],
    );
  }

  /// chip 的 key 用**枚举名**（`tone-formal` / `length-short`），不用 label ——
  /// label 是给人看的界面文案，改一个汉字不该让测试找不到按钮。
  String _slug(T value) => switch (value) {
        RewriteTone tone => tone.name,
        DraftLength length => length.name,
        _ => value.toString(),
      };
}
