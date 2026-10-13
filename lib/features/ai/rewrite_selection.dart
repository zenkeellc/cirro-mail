import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;

/// 当前选区**能不能**被替换，以及不能的原因。见
/// [RewriteSelection.replaceability]。
enum SelectionReplaceability {
  /// 可以替换。
  ok,

  /// 选区无效或已折叠（用户点了别处，或根本没选）—— 拿旧偏移去改会改到别人。
  collapsed,

  /// 选区里含块级嵌入（图片等）—— 改写返回的纯文本插回去必然静默删掉它。
  hasEmbed,
}

/// 「选中即改」的落地动作。
///
/// **为什么单独一层**：这段代码动的是用户的文档，写错了就是「选中一段按改写、
/// 结果别的段落被吃掉」。所以它不碰 UI、不碰网络，只做一次可测的编辑。
abstract final class RewriteSelection {
  const RewriteSelection._();

  /// 选中的**纯文本**（按文档顺序）。选区反向时（从后往前选）也要正确 ——
  /// `selection.start` / `.end` 已经处理了这一层，别自己算偏移。
  ///
  /// 选区里若含内联图片等**嵌入**，它在纯文本里表现为一个 U+FFFC，这里
  /// **显式排除**（替换成空）：改写的输入是纯文本，塞不进图片；选区是否含
  /// 嵌入由 [replaceSelection] 另行判定并拒绝改写。这个取向要钉住 ——
  /// 否则会让人误以为图片内容被带进了改写请求。
  static String selectedText(q.QuillController controller) {
    final selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) return '';
    // `getPlainText(index, len)` 的第二个参数是**长度**不是结束位置 ——
    // 传 `end` 会拿到「从 start 起再多要 end 个字符」，选区越靠后错得越多。
    return controller.document
        .getPlainText(selection.start, selection.end - selection.start)
        .replaceAll('￼', '');
  }

  /// 当前选区能不能被 [replaceSelection] 换掉；不能的话是什么原因。
  ///
  /// **公开出来的理由**：界面必须在**不动文档**的前提下先知道结局，才能决定
  /// 提示用户哪一句（见 `ComposeAi.applyRewrite`）。它和 [replaceSelection]
  /// 走同一套判断，所以不会出现「判据说能改、真改时却被拒」这种不一致。
  static SelectionReplaceability replaceability(q.QuillController controller) {
    final selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) {
      return SelectionReplaceability.collapsed;
    }
    if (selection.end - selection.start <= 0) {
      return SelectionReplaceability.collapsed;
    }
    if (_selectionHasEmbed(controller.document, selection.start, selection.end)) {
      return SelectionReplaceability.hasEmbed;
    }
    return SelectionReplaceability.ok;
  }

  /// 用 [replacement] 替换当前选区。返回是否真的改了东西。
  ///
  /// 四条刻意的约束：
  /// 1. **选区折叠或无效时什么都不做** —— 否则会往光标处插一段文字，
  ///    而用户以为是「改写」；
  /// 2. **选区里含嵌入（图片等）时什么都不做，返回 false** —— 关于这个返回
  ///    语义见下；
  /// 3. 结果里若含换行，Quill 会自然拆成多个块（正是「改写成一段话」想要的）；
  /// 4. 落到 `controller.replaceText` 上 —— 它走的是 `History`，
  ///    所以 `Ctrl/Cmd+Z` 能一次回退掉整次改写。
  ///
  /// **关于「选区含嵌入 → 返回 false」**：改写返回的是**纯文本**，而选区里
  /// 可能嵌着图片/分隔线这类 `Embed`。原样插回去必然把嵌入丢掉，且用户是
  /// 在「只是改文字」的预期下操作的 —— 那是静默的数据丢失。与其如此，
  /// 不如**拒绝**：`false` 的含义是「这次改写没有发生，文档一字未动」，
  /// 调用方据此提示用户「选区里含图片，无法改写」（D12 面板会用到）。
  ///
  /// **入口先做换行规范化**：`\r\n` / `\r` 直接插进 Quill 会变成正文里的
  /// 裸回车，随后进发出的邮件。这里不假设调用方一定走过 [normalize]。
  ///
  /// 拒绝的两种情况（选区不在 / 含嵌入）由 [replaceability] 统一判定 ——
  /// 那里的返回值就是「没改成的**原因**」，界面据此提示。这里用同一个判据，
  /// 保证「界面预料的结果」与「真落地时的结果」一致。
  static bool replaceSelection(
    q.QuillController controller,
    String replacement,
  ) {
    if (replaceability(controller) != SelectionReplaceability.ok) return false;
    final selection = controller.selection;
    final index = selection.start;
    final length = selection.end - selection.start;
    final text = _normalizeNewlines(replacement);
    controller.replaceText(
      index,
      length,
      text,
      TextSelection.collapsed(offset: index + text.length),
    );
    return true;
  }

  /// 选区内是否含任何 `Embed`（图片、分隔线……）。
  ///
  /// 走 `toDelta()`：非字符串的 op 就是嵌入，占**一个**偏移量（与文档长度、
  /// 选区偏移同一坐标系）。逐 op 累加偏移即可判断某个嵌入是否落在 `[start, end)`。
  static bool _selectionHasEmbed(q.Document document, int start, int end) {
    var offset = 0;
    for (final op in document.toDelta().toList()) {
      final data = op.data;
      if (data is String) {
        offset += data.length;
      } else {
        if (offset >= start && offset < end) return true;
        offset += 1;
      }
    }
    return false;
  }

  /// 只统一换行符。与 [normalize] 分开：落盘前的规范化会顺手去围栏/零宽字符，
  /// 而这里对「模型给的文本」只做最保守的一件事 —— 别把裸 `\r` 带进文档。
  static String _normalizeNewlines(String raw) =>
      raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// 把 [text] 插到选区**下方**（「插入到下方」那个按钮）。
  ///
  /// 做法：把光标落到选区末尾，插入 `\n` + 文本 —— **换行在前**，于是新内容
  /// 落在选区所在那一行的**下一行**，原文一字不动（换行在后的话，插入点正好
  /// 是行尾的 `\n`，结果会和原文挤在同一行）。
  ///
  /// 与 [replaceSelection] 一样在入口先做换行规范化（理由同）。
  static bool insertBelow(q.QuillController controller, String text) {
    final selection = controller.selection;
    if (!selection.isValid) return false;
    final normalized = _normalizeNewlines(text);
    final body =
        normalized.endsWith('\n') ? normalized.substring(0, normalized.length - 1) : normalized;
    final at = selection.end;
    controller.replaceText(
      at,
      0,
      '\n$body',
      TextSelection.collapsed(offset: at + 1 + body.length),
    );
    return true;
  }

  /// AI 返回的文本落地前的**规范化**：只留邮件安全子集里表达得出的东西。
  ///
  /// 做四件事，顺序不能反：
  /// 1. 统一换行（`\r\n` / `\r` → `\n`）；
  /// 2. 去掉整行是 ``` 的围栏（模型很爱加，但编辑器里不该出现这三个反引号）；
  /// 3. 去掉零宽字符（模型偶尔会吐 U+200B，肉眼看不见，会污染纯文本摘要）；
  /// 4. 压掉三个以上的连续空行（模型喜欢用空行分层，四五个连空在邮件里是浪费）。
  static String normalize(String raw) {
    var text = _normalizeNewlines(raw);
    // 语言标记放得很宽（字母/数字/`_`/`+`/`#`/`-`）：模型会用 ```objective-c、
    // ```objective-c++、```c#、```vue-ts 这类带连字符与 `#` 的标记，收紧成
    // `[a-zA-Z0-9]*` 会让整行围栏原样落进正文（prompt 明说不要围栏）。
    text = text.replaceAll(
        RegExp(r'^\s*```[a-zA-Z0-9_+#-]*\s*$', multiLine: true), '');
    text = text.replaceAll('​', '').replaceAll('﻿', '');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    // 去掉首尾多余空行 —— 落地时外层会自己加分段。
    return text.trim();
  }

  /// 模型有时会用 markdown 的 `**粗体**` 回话，但把它当纯文本插进去会显示
  /// 出星号。这里只做**最常见**的三种（`**b**` / `*i*` / `` `c` ``）转成
  /// Delta 属性，其余原样 —— 猜错格式比不猜更糟。
  static List<Map<String, dynamic>> markdownToOps(String markdown) {
    final ops = <Map<String, dynamic>>[];
    var cursor = 0;
    final pattern = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    for (final match in pattern.allMatches(markdown)) {
      if (match.start > cursor) {
        ops.add({'insert': markdown.substring(cursor, match.start)});
      }
      if (match.group(1) != null) {
        ops.add({
          'insert': match.group(1),
          'attributes': {'bold': true},
        });
      } else {
        ops.add({
          'insert': match.group(2),
          'attributes': {'code': true},
        });
      }
      cursor = match.end;
    }
    if (cursor < markdown.length) {
      ops.add({'insert': markdown.substring(cursor)});
    }
    if (ops.isEmpty) ops.add({'insert': markdown});
    return ops;
  }
}
