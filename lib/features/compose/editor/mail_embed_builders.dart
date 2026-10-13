import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

import '../table/table_block.dart';
import 'image_actions.dart' show EmbedTapCallback;
import 'mail_image_embed.dart';

/// 编辑器要注册的**全部**块级嵌入。
///
/// 为什么集中在一处、而且必须一次给全：flutter_quill 在渲染时若遇到一个没有
/// 注册 builder 的嵌入类型，`_getEmbedBuilder`（`editor.dart:385`）会抛
/// `UnimplementedError`，而这个异常发生在渲染路径里会引发连锁的类型转换崩溃
/// ——**整页白屏**。所以「加了一个新嵌入类型却忘了注册」的成本极高，这里
/// 用一个列表把它变成「只有一处要改」。
List<q.EmbedBuilder> mailEmbedBuilders({
  required q.QuillController controller,
  required TableBlockCallbacks tableCallbacks,
  FocusNode? embedFocusParent,

  /// 点正文里的图。**只读视图（收信侧）不要传** —— 图片不可点。
  EmbedTapCallback? onImageTap,
}) =>
    <q.EmbedBuilder>[
      MailImageEmbedBuilder(onImageTap: onImageTap),
      MailTableEmbedBuilder(
        controller: controller,
        callbacks: tableCallbacks,
        // 单元格输入框挂到正文编辑器**之外**的焦点节点上，免得正文那根光标
        // 与单元格的光标同时画（「两根光标」）。见 [MailTableEmbedBuilder
        // .focusParent] 与 `MailQuillEditor._embedFocusHost`。
        focusParent: embedFocusParent,
      ),
      // 兜底：伪类型永远不会被主动写入文档，但**别的地方**（旧的草稿、从
      // 网页粘进来的奇怪结构、将来某个版本写进来的新类型）可能带进来。
      // 有它在，未知嵌入只会显示成一行提示，而不是白屏。
      const UnknownEmbedBuilder(),
    ];

/// 未知嵌入的兜底渲染。
class UnknownEmbedBuilder extends q.EmbedBuilder {
  const UnknownEmbedBuilder();

  @override
  String get key => 'x-unknown';

  @override
  String toPlainText(q.Embed node) => '[不支持的内容]';

  @override
  Widget build(BuildContext context, q.EmbedContext embedContext) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.help_outline, size: 16),
            const SizedBox(width: 6),
            Text('不支持的内容',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
}
