import 'package:flutter/material.dart';

import '../../ai/ai_prompts.dart';
import '../../ai/ai_run.dart';
import '../../ai/ai_stream_view.dart';

/// ⑤ 回复建议面板：流式显示，**能点的时候才让点**。
///
/// ## 与改写面板（①）的关键区别
///
/// 改写有「原文」，所以三个按钮是「替换 / 插到下方 / 丢弃」。回复建议
/// **没有原文可换** —— 它是**新增**内容，所以只有一个动作：插到光标处
/// （spec §6.4）。少一个「替换」也少了一类误操作。
///
/// ## 候选是**流完了才抠**的
///
/// 生成中不给「选一条插入」的按钮：`AiPrompts.replyCandidates` 是对**整段**
/// 输出做的行拆分，流到一半时最后一行还是半截话，点了会把半句插进正文。
/// 所以按钮只在 `!running` 时可用。
class AiReplySheet extends StatefulWidget {
  const AiReplySheet({super.key, required this.incoming, required this.start});

  /// 来信正文。**只用来显示**（顶部一小段，让用户确认「它在看的是这封信」）。
  final String incoming;

  /// 起一次生成，由调用方接上 `AiService`。
  final AiRun Function() start;

  @override
  State<AiReplySheet> createState() => _AiReplySheetState();
}

class _AiReplySheetState extends State<AiReplySheet> {
  /// 面板一构造就发请求（点这颗按钮的人就是要这个 —— 与改写面板不同，
  /// 那边要先让用户挑语气，这里没有参数可挑）。
  late AiRun _run = widget.start();

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  /// 「重新生成」：**换一个 `AiRun`**，把上一次的增量与错误一起丢掉。
  /// 不换的话上一次的 `message` 会留着，用户一按就看不到新结果。
  ///
  /// 形状照抄 `ai_rewrite_sheet.dart` 的 `_regenerate`：先 dispose 旧的、
  /// 再在 `setState` 里换成新的那个 `widget.start()`。
  void _regenerate() {
    setState(() {
      _run.dispose();
      _run = widget.start();
    });
  }

  /// 把候选摊成一个二次选择 —— 用二次弹出的列表，而不是底部一排按钮：
  /// 候选是完整句子，按钮标签放不下，用户得读全了才能选。
  Future<void> _pick(BuildContext context) async {
    final candidates = AiPrompts.replyCandidates(_run.text.value);
    if (candidates.isEmpty) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      // 二次弹出也是一层新弹层，根 widget 同样要包 [TextFieldTapRegion]
      // （spec §1.3 硬约束）。少了它，点候选那一下会先把正文失焦、选区塌掉
      // —— 这一层返回的正是**要插到光标处**的那一句话，选区塌了它就落到
      // 别的地方（见 [build] 里的说明）。
      builder: (sheetContext) => TextFieldTapRegion(
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var i = 0; i < candidates.length; i++)
                ListTile(
                  key: ValueKey('ai-reply-candidate-$i'),
                  title: Text(candidates[i]),
                  onTap: () => Navigator.of(sheetContext).pop(candidates[i]),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null) return;
    if (!context.mounted) return;
    Navigator.of(context).pop(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 面板根包一层 [TextFieldTapRegion]（spec §1.3 硬约束）：`showModalBottomSheet`
    // 是一次**新路由**，点它等于「点到编辑器外面」，flutter_quill 的
    // `onTapOutsideEnabled` 会立刻 `unfocus()` 正文。
    //
    // 这一条**比别的弹层更要紧**：回复建议产出的文字由 `_suggestReply` 走
    // `insertSnippet(_quill, text)` 插在**光标处**（`compose_screen.dart`）。
    // 失焦的后果不只是「选区高亮消失」，是候选插到不是用户留下的那个位置。
    // 手法与 `toolbar_button.dart` / `_ImageActionsSheet` 一致。
    //
    // ⚠️ **实测（本机 `flutter test`，探针在 `/tmp`）：这两层 region 在这里
    // 量不到行为差异。** 去掉它们、反复点面板与候选，`hasFocus` 与
    // `controller.selection` 逐字不变、插进去的落点也一样。底层的
    // `showModalBottomSheet` 是**路由**：它是顶层 `PopupRoute`，自己的
    // `_ModalScopeState` 在动画起步就抢走 primary focus，正文那一圈
    // `TextFieldTapRegion` 拦不住它（六种 `TargetPlatform` 都试过，一样）。
    // 所以留着这两层是**照 spec §1.3 的一致做法**（与别的弹层同形、将来若
    // quill 的 `onTapOutside` 行为变了也在防），不是因为本机能量到收益 ——
    // 护栏写成结构断言，见 `test/ai_reply_test.dart` 里那条用例的注释。
    return TextFieldTapRegion(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('回复建议', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),

              // 来信：只读，且**限高**（来信很长时不能把面板撑爆）。
              // 用户看一眼就知道「它在看的是这封信」。
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
                    widget.incoming,
                    key: const ValueKey('ai-reply-incoming'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
              const SizedBox(height: 12),

              AiStreamView(run: _run, placeholder: '正在想怎么开头…'),
              const SizedBox(height: 8),

              ValueListenableBuilder<bool>(
                valueListenable: _run.running,
                builder: (context, running, _) => Row(
                  children: <Widget>[
                    TextButton.icon(
                      key: const ValueKey('ai-reply-retry'),
                      onPressed: running ? null : _regenerate,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('重新生成'),
                    ),
                    const Spacer(),
                    // **生成中不给**：候选是对整段输出做的行拆分，流到一半时
                    // 最后一行还是半截话，点了会把半句插进正文（见类注释）。
                    FilledButton(
                      key: const ValueKey('ai-reply-insert'),
                      onPressed: running ? null : () => _pick(context),
                      child: const Text('选一条插入'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
