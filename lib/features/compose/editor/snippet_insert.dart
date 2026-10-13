import 'package:flutter/material.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;

import 'slash_actions.dart';
import 'slash_command.dart';

/// 把一段多行纯文本插到光标处（签名 / 常用语走这里）。
///
/// **语义是「在光标处另起一段」**：光标在行内时先断行，所以**光标前后的字都
/// 保住**；代价是这一行会被切成两段（断行处那张 `\n` 归到前一段），而新段落
/// **不带块级属性** —— 断行插的是裸 `\n`，它的块级属性为空，所以新段落不会
/// 继承原来那行的 `header` / `list`。原来那行自己的属性也不动。
///
/// **为什么不能直接 `replaceText`。** 试过 `replaceText(at, 0, 'a\nb', sel)`：
/// 它**确实会**把 `a\nb` 拆成两个段落（实测：在 `标题` + `\n{header:1}` 上跑
/// 出 `[{insert:"a\nb标题"},{insert:"\n",attributes:{header:1}}]`，纯文本是
/// `a\nb标题\n`），但它在**段落属性上完全不管** —— 新段落不带块级属性这件事它
/// 碰巧对（因为没传 attribute），可原来那行行尾 `\n` 上的 `header` 会原样留着。
/// [insertParagraphText] 处理的正是「先清块级属性（含行尾 `\n`）再写回」这件事
/// （见 `slash_actions.dart` 的 `insertParagraphText`）。
///
/// 为什么还留这个包装：给调用方一个**语义明确的名字**
/// （「插入签名」不该读成「插一段落」），也留一个地方放将来可能加的
/// 「签名前补一个空行」这类规则。
///
/// **空串是这里挡的，不是 [insertParagraphText] 挡的。** 实测阅读
/// `slash_actions.dart` 的 `insertParagraphText` 的实现：它对空串**不**安全 ——
/// 它执行的 `replaceText(line.start, line.text.length, '\n', null)` 覆盖的是
/// `[line.start, caret)` 那一段（`line.text` 就是**光标之前那半行**，见
/// [_breakLineAtCaret]）：光标签在一行文字中间或行尾时，这半行会被**抹掉**、
/// 换成一个空段落（插一个空签名 = 那半行字没了）；光标落在**段尾**时覆盖范围
/// 越过文档末尾，直接抛 `container.dart` 的断言。所以
/// `if (text.isEmpty) return;` 不只是「表达调用方的意图」，它是**必需**的一道闸。
/// 「没签名就别插」这条判断放在这里，比散在三处调用点各写一遍清楚。
void insertSnippet(q.QuillController controller, String text) {
  if (text.isEmpty) return;
  _breakLineAtCaret(controller);
  insertParagraphText(controller, text);
}

/// 光标若在行内（不在行首），先在光标处断一次行。
///
/// 修的是「整行替换」这个坑：[insertParagraphText] 换的是**当前行整行的文字**，
/// 不是「在光标处插入」。它眼里的「这一行」是 `line.text` —— 那是
/// `getPlainText(0, caret)` 在最后一个 `\n` 处切出来的那半段，也就是**光标
/// 之前**的文字；随后 `replaceText(line.start, line.text.length, …)` 覆盖的
/// 正是 `[line.start, caret)`。所以光标停在一行中间时，它吞掉的是**光标之前
/// 的字**，光标之后的字不在这个范围里、反而活下来。实测（flutter_quill
/// 11.6.0）：文档 `ABCDEFG\n` 光标 5，直接调 `insertParagraphText`（修之前的
/// 路径）得到 `签名\nFG\n` —— `ABCDE` 没了、`FG` 还在；修之后是
/// `ABCDE\n签名\nFG\n`。最自然的一击是写完一句话点「签名」：点段落末尾时编辑器给的偏移是
/// `document.length - 1`（quill 把收尾 `\n` 当不可移动，见
/// `quill_controller.dart:477`；本仓库用的是 flutter_quill 11.6.0），整句话会被
/// 静默吃掉。先断一次行，光标之后的字就落到了下一段，
/// `insertParagraphText` 再整行替换时碰不到它们。
void _breakLineAtCaret(q.QuillController controller) {
  final doc = controller.document;
  final selection = controller.selection;
  if (!selection.isValid) return;
  // 夹到 `document.length - 1`（不是 `document.length`）：quill 的
  // `QuillController._updateSelection` 把任何选区夹到这个上界
  // （`quill_controller.dart:477`，它当收尾 `\n` 不可移动）。传
  // `document.length` 再去 `replaceText` 会踩 `container.dart` 的
  // `assert(index == 0 || (index > 0 && index < length))`。
  final caret = selection.start.clamp(0, doc.length - 1);
  controller.updateSelection(
    TextSelection.collapsed(offset: caret),
    q.ChangeSource.local,
  );
  final line = SlashCommand.currentLine(controller);
  // 行首不必断：`insertParagraphText` 在行首本来就是「在原行之前纯插入」，
  // 顺带把原行的块级属性清掉，正确。只有行内才需要先断。
  if (caret <= line.start) return;
  // 用 `selection.start`（不是 `extentOffset`）落的光标：头锚选区（base >
  // extent）会被归一化到 start，所以选区不会被截断。
  controller.replaceText(caret, 0, '\n', null);
  controller.updateSelection(
    TextSelection.collapsed(offset: caret + 1),
    q.ChangeSource.local,
  );
}
