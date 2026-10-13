import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;

import '../compose/compose_quote.dart';
import '../compose/compose_text.dart';
import '../compose/html/delta_to_email_html.dart';

/// 一次续写请求要发给模型的**整段上下文**。
///
/// [marked] 是整封邮件（含用户区与引用区），光标处插了 [InlineContinuation.marker]。
/// 两个 `trimmed` 只作诊断与测试用 —— 模型看不到它们。
class ContinuationInput {
  const ContinuationInput({
    required this.marked,
    required this.quoteTrimmed,
    required this.userTrimmed,
  });

  /// 整封邮件，光标位置插了标记。
  final String marked;

  /// 引用区因为超预算被截断过（**优先剪它**）。
  final bool quoteTrimmed;

  /// 剪完引用仍超预算，用户区（光标之前的部分）也被剪了头。
  final bool userTrimmed;

  @override
  String toString() =>
      'ContinuationInput(len=${marked.length}, quoteTrimmed=$quoteTrimmed, '
      'userTrimmed=$userTrimmed)';
}

/// 「行内续写」的触发判定与上下文截取。
///
/// 只有**纯逻辑**：什么时候该请求、发多少上下文给模型、结果怎么落在编辑器里。
/// 计时器与请求由调用方（widget）持有 —— 这样判定规则可以单测，而不用在
/// 测试里等 [idleDelay] 那么长的真实延迟。
abstract final class InlineContinuation {
  const InlineContinuation._();

  /// 光标停住多久算「停下来了」。太短会在打字过程中反复打断，太长就没人等。
  ///
  /// **1500ms**：续写现在每次都要把整封邮件（含引用）发出去，比只发光标前
  /// 一段时更贵、也更需要「用户是真的停下来了」这个信号。加上「打字过程中
  /// 会取消在飞的请求」之后，误触的代价是**一次被取消的调用**（钱多半还是
  /// 花了），所以宁可让用户多等半秒。500ms 那档在手感上是「打字停顿」，
  /// 1500ms 才是「写完一句、在想要接什么」。
  static const Duration idleDelay = Duration(milliseconds: 1500);

  /// 送进模型的**上下文字符预算**（用户区 + 引用区的总长）。
  ///
  /// 超预算时**先剪引用**（见 [build]）：引用是「别人发来的原信」，只是参考；
  /// 用户自己写的那段才是要续的地方，非到最后一步不动它。
  static const int maxContextChars = 3000;

  /// 光标位置的标记。模型据此知道「该从哪儿接着写」。
  ///
  /// 用一对全角方括号而不是 `|` / `<cursor>` 这类：`<cursor>` 容易被模型当成
  /// 真 HTML 标签丢掉或改写，`|` 在正文里可能本来就出现。这个形状很显眼、
  /// 且不会与邮件正文里的常见字符撞上。
  static const String marker = '【光标位置】';

  /// 引用区与用户区之间的分隔说明。**不要**指望模型读懂花哨的格式 —— 就是
  /// 一行平白的话，把「下面这段是引用的原文」说清楚。
  static const String quoteLead = '\n--- 以下是邮件里被引用的原信（仅供参考，不要改写、不要接着写它）---\n';

  /// 光标处该不该请求续写。
  ///
  /// 六条限制，每一条都是「不然会很烦」：
  /// 1. 总开关关着 → 不续（默认就是关的，见 `AiSettings`）；
  /// 2. 有选区 → 不续（用户正在做别的事）；
  /// 3. 光标不在行尾（后面还有字）→ 不续（插在句子中间毫无意义）；
  /// 4. 当前行太短（少于 [minLineChars]）→ 不续 —— 刚敲两三个字就弹建议
  ///    是很典型的骚扰；
  /// 5. 光标所在的块是**代码块或引用块** → 不续：那两类块里塞一句自然语言
  ///    是纯粹的破坏（代码块尤其：模型续出来的中文注释会变成语法错误）。
  /// 6. 上一个字符是空白/标点收尾的「结束感」→ 交给模型判断（见 prompt），
  ///    这里不拦。
  ///
  /// 注：**输入法组合态（IME composing）在这一层看不见** —— 那是 widget 层
  /// 的 `TextEditingValue.composing`。这里不硬凑（凑出来也不可靠），留给
  /// 调用续写的 widget 在更上层判断。
  static bool shouldRequest({
    required q.QuillController controller,
    required bool enabled,
    required bool isGenerating,
  }) {
    if (!enabled || isGenerating) return false;
    final selection = controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return false;
    final cursor = selection.extentOffset;
    if (cursor <= 0 || cursor >= controller.document.length) return false;

    // 规则 5：代码块 / 引用块里不续。
    if (_inCodeOrQuoteBlock(controller)) return false;

    final plain = controller.document.getPlainText(0, cursor);
    // 规则 3：光标后面还有内容就不续。
    final after = controller.document
        .getPlainText(cursor, controller.document.length - cursor);
    if (after.isNotEmpty && !after.startsWith('\n')) return false;

    // 规则 4：当前行要有足够的内容。
    final lineBreakAt = plain.lastIndexOf('\n');
    final line = plain.substring(lineBreakAt + 1);
    if (line.trim().length < minLineChars) return false;
    return true;
  }

  /// 光标所在的块是不是代码块 / 引用块。
  ///
  /// 用 `getSelectionStyle()`：光标折叠时它给出**当前块**的块级属性，对
  /// 代码块返回 `code-block`、对引用块返回 `blockquote`（实测）。这比自己去
  /// 遍历 `document.root` 找行、再读 `Line.style` 简单，也不受块结构变化影响。
  static bool _inCodeOrQuoteBlock(q.QuillController controller) {
    final attrs = controller.getSelectionStyle().attributes;
    return attrs.containsKey(q.Attribute.codeBlock.key) ||
        attrs.containsKey(q.Attribute.blockQuote.key);
  }

  /// 当前行至少要有这么多字才请求。
  static const int minLineChars = 8;

  /// 组装给模型的整段上下文。**纯函数，不碰网络也不碰 widget**。
  ///
  /// 拼装顺序与剪裁规则：
  /// 1. 用 [ComposeQuote.userEnd] 把正文切成**用户区** `[0, userEnd)` 与
  ///    **引用区** `[userEnd, 长度)`（判据与润色、导出用的是同一套，不另起一套）。
  /// 2. 用户区按**文档偏移**逐字符走一遍，在 [marker] 处插入光标标记 ——
  ///    这样标记的位置与光标在文档里的位置严格一致，不受「引用里有没有图」
  ///    这类事影响。嵌入（图片/表格）在用户区里被跳过，不留占位符。
  /// 3. 引用区经 **Delta → HTML → 纯文本** 这一圈转出来（与
  ///    `ComposeScreen.composePlainText` 同路）—— 直接 `toPlainText()` 会把
  ///    图片/表格变成孤零零的 `￼`，而模型正好要靠这些判断「光标后面还有
  ///    一封别人发来的原信」。
  /// 4. **超预算先剪引用**（从尾部截，保留对方来信的开头）；仍超再剪用户区
  ///    的**头部**（保留离光标最近的一段）。
  static ContinuationInput build(q.QuillController controller, {int? limit}) {
    final cap = limit ?? maxContextChars;
    final delta = controller.document.toDelta().toJson();
    final total = controller.document.length;
    final cursor =
        controller.selection.extentOffset.clamp(0, total);
    final userEnd = ComposeQuote.userEnd(delta).clamp(0, total);

    var user = _plainWithMarker(delta, end: userEnd, cursor: cursor);
    var quote = _quoteText(delta, userEnd, total);
    var quoteTrimmed = false;
    var userTrimmed = false;

    if (user.length + quote.length + quoteLead.length > cap) {
      // 先剪引用：给用户区与分隔说明留出位置，剩下的才轮到引用。
      final room = cap - user.length - quoteLead.length;
      if (room < quote.length) {
        quoteTrimmed = true;
        quote = room <= 0 ? '' : quote.substring(0, room);
      }
      // 剪完引用还超（用户区自己就吃光了预算）→ 再剪用户区的头，保住光标
      // 附近那一段（标记在尾部，头被剪掉不会把标记剪没）。
      final over = user.length + quote.length + quoteLead.length - cap;
      if (over > 0) {
        userTrimmed = true;
        user = user.substring(over.clamp(0, user.length));
      }
    }

    final hasQuote = quote.trim().isNotEmpty;
    return ContinuationInput(
      marked: hasQuote ? '$user$quoteLead$quote' : user,
      quoteTrimmed: quoteTrimmed,
      userTrimmed: userTrimmed,
    );
  }

  /// 用户区 `[0, end)` 的纯文本，在文档偏移 [cursor] 处插一个 [marker]。
  ///
  /// 逐字符走（不按 op 切）：`Document.toDelta()` 会把属性相同的相邻 op 合并，
  /// 一个 op 里可能同时有行尾 `\n` 与下一行的字。嵌入占一个文档偏移，但不产出
  /// 任何文本 —— 于是「跳过它」不会让后面的偏移算错。
  static String _plainWithMarker(
    List<dynamic> delta, {
    required int end,
    required int cursor,
  }) {
    final buf = StringBuffer();
    var offset = 0;
    var marked = false;
    void markIfDue() {
      if (!marked && offset >= cursor) {
        buf.write(marker);
        marked = true;
      }
    }

    outer:
    for (final raw in delta) {
      if (raw is! Map) continue;
      final data = raw['insert'];
      if (data is String) {
        for (var i = 0; i < data.length; i++) {
          if (offset >= end) break outer;
          markIfDue();
          final ch = data[i];
          // 嵌入的占位符（U+FFFC）不写出来：模型看不懂它。
          if (ch != '￼') buf.write(ch);
          offset++;
        }
      } else {
        if (offset >= end) break;
        markIfDue();
        offset++;
      }
    }
    // 光标正好在用户区末尾（最常见：光标停在最后一段的行尾）时兜底补上。
    if (!marked) buf.write(marker);
    return buf.toString();
  }

  /// 引用区 `[start, end)` 的纯文本。走导出器那一路，图片/表格才有像样的文本。
  static String _quoteText(List<dynamic> delta, int start, int end) {
    if (end <= start) return '';
    final ops = _sliceOps(delta, start, end);
    if (ops.isEmpty) return '';
    return PlainText.fromHtml(DeltaToEmailHtml.convert(ops)).trim();
  }

  /// 按**字符**切出 `[start, end)` 这一段 op。
  ///
  /// 与 `ComposeQuote.userDelta` 同一个理由：边界可能落在 op 中间，只能按字符
  /// 切，不能按 op 切。嵌入占一个字符，切不进它内部。
  static List<dynamic> _sliceOps(List<dynamic> delta, int start, int end) {
    final out = <dynamic>[];
    var offset = 0;
    for (final raw in delta) {
      if (raw is! Map) continue;
      final data = raw['insert'];
      final length = data is String ? data.length : 1;
      final opEnd = offset + length;
      if (opEnd <= start) {
        offset = opEnd;
        continue;
      }
      if (offset >= end) break;
      if (data is String) {
        final from = (start - offset).clamp(0, data.length);
        final to = (end - offset).clamp(0, data.length);
        if (to > from) {
          final copy = Map<String, dynamic>.from(raw);
          copy['insert'] = data.substring(from, to);
          out.add(copy);
        }
      } else if (offset >= start && offset < end) {
        out.add(raw);
      }
      offset = opEnd;
    }
    return out;
  }

  /// 接受建议：把幽灵文本真正写进文档。
  ///
  /// **只在 `Tab` 时调用**，且**只插一次**（[accepted] 由调用方保证，
  /// 重复调用会插两遍）。光标落到新文本之后。
  static void accept(q.QuillController controller, String suggestion) {
    if (suggestion.isEmpty) return;
    final at = controller.selection.isValid
        ? controller.selection.extentOffset
        : controller.document.length - 1;
    controller.replaceText(
      at,
      0,
      suggestion,
      TextSelection.collapsed(offset: at + suggestion.length),
    );
  }

  /// 要不要丢弃当前的建议。
  ///
  /// 规则：用户**继续打字**或**移动了光标** → 丢掉。这是「幽灵文本」的基本
  /// 礼貌 —— 不能让一段已经过时的建议留在眼前、还能被 Tab 接受下来。
  static bool shouldDiscard({
    required int suggestionAt,
    required q.QuillController controller,
  }) {
    final selection = controller.selection;
    if (!selection.isValid) return true;
    return selection.extentOffset != suggestionAt;
  }
}
