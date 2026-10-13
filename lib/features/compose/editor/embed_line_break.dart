import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter/widgets.dart' show TextSelection;

/// 插入**块级嵌入**（图片、表格）之前，先把落点那一行劈开。
///
/// 为什么必须劈：flutter_quill 的 [q.Line] 文档注释写得很直白 ——
/// **一行里只允许有嵌入，不许再有文字**（"When a line contains an embed,
/// it fully occupies the line, no other embeds or text nodes are allowed."）。
/// 而 `replaceText` 只是把嵌入插到那个偏移上，**不做任何占行的处理**
/// （探针实测：在 `前|后` 的行中间插图，得到的 delta 是
/// `[{insert: 前}, {insert: {image: …}}, {insert: '\n后\n'}]`，
/// 第 2 行同时有嵌入和「后」）。这种行渲染时会走到 `Line._getEmbedBuilder`
/// 之外的路径，轻则排版错乱、重则白屏。
///
/// 两处调用者都踩过这个坑：插图（`ImageInsert`）与插表
/// （`ComposeScreen._insertTable`）。
abstract final class EmbedLineBreak {
  const EmbedLineBreak._();

  /// 把 [offset] 处的行劈开，返回「一个空的、独占一行的行首」的位置。
  ///
  /// 劈一次不一定够：在空行上劈会**把那个空行变成两个**（`\n` 是在行首插的，
  /// 光标原地不动就落到拼接出来的那行上），所以这里循环到光标真的落在空行为止。
  /// 探针实测四种落点（行首 / 行中 / 行尾 / 段首）都收敛在两次以内，上限取 4
  /// 防死循环。
  ///
  /// [offset] 可以越界（选区贴到文末时会等于 `Document.length`）—— 这里自己夹。
  static int at(q.QuillController controller, int offset) {
    // 防御性夹取：调用方可能已经夹过一次，但这里直接对 `toPlainText()` 的
    // 下标做运算，多一道保险 —— 越界时下面 `lastIndexOf` / `indexOf` 会给出
    // 荒谬的行边界，`replaceText` 就落到文档外（`container.dart:137` 的断言）。
    final last = controller.document.length - 1;
    var cursor = offset.clamp(0, last < 0 ? 0 : last);
    for (var guard = 0; guard < 4; guard++) {
      final plain = controller.document.toPlainText();
      final lineStart = cursor == 0 ? 0 : plain.lastIndexOf('\n', cursor - 1) + 1;
      final lineEnd0 = plain.indexOf('\n', cursor);
      final lineEnd = lineEnd0 < 0 ? plain.length : lineEnd0;
      if (cursor == lineStart && lineEnd == cursor) return cursor;
      final insertAt = cursor.clamp(0, controller.document.length - 1);
      controller.replaceText(
        insertAt,
        0,
        '\n',
        TextSelection.collapsed(offset: insertAt + 1),
      );
      // 光标原本就在行尾时，多出来的那个换行在它**前面**，劈完要跳过它
      // 才能落到新行上。（字符插在 `cursor` 处，光标原本停在 `cursor`，
      // 这会把它挤到下一行；`lineEnd` 是劈之前算的，正好可以拿来判这件事。）
      if (cursor == lineEnd) cursor = insertAt + 1;
      cursor = cursor.clamp(0, controller.document.length - 1);
    }
    return cursor;
  }
}
