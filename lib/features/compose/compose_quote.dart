import 'compose_text.dart';
import 'html/delta_to_email_html.dart';
import 'html/mail_html_to_delta.dart';

/// 「这条线以上是用户写的，以下是引用进来的旧邮件」—— 边界怎么打、怎么读。
///
/// ## 为什么需要它
///
/// 回复 / 转发时引用块是**正文文档的一部分**（spec §3.6 之后它可见可编辑），
/// 于是「润色正文」这件事必须先回答一个问题：**引用算不算正文？** 不算。
/// 用户点润色是想把自己写的措辞理顺，不是让模型把别人发来的原信重写一遍
/// （改写了引用发给对方，是比不改更糟的结果）。同理，「正文里有没有图片」
/// 这类守卫也不该被引用里的图片触发 —— 那会让「回复一封带图的邮件」整条
/// 润色都用不了。
///
/// ## 边界是**行属性**，不是文本
///
/// 引用区的每一行（含把引用与正文隔开的那条 `---` 分隔线）行尾 `\n` 上带
/// [MailHtmlToDelta.quoteAttribute]。读的时候只看这个属性。
///
/// 刻意**不**用「从上往下找到第一行内容正好是 `---`」这种文本判据：用户在
/// 分隔线上打一个字、把分隔线删掉、或者自己用斜杠菜单插一条分隔线，三种
/// 情况它都会认错，而且错得很安静。行属性只在**整行结构变化**（删掉整行、
/// 把两行合成一行）时才丢 —— 而那时它确实不再是一条独立的引用了。
///
/// ## 没有标记时行为与从前完全一样
///
/// 旧草稿里没有这个属性，用户把引用整段删掉之后也没有。[userEnd] 遇到
/// 「一行都没标」时退化成「**末尾那个 `\n` 之前**」，于是 [plainText] 给出的是
/// 整篇、[userDelta] 原样返回 —— 与这个文件出现之前的行为逐字相同，不需要
/// 任何迁移。
abstract final class ComposeQuote {
  const ComposeQuote._();

  /// 给 [MailHtmlToDelta.convert] 出来的 ops 打上「这是引用」的标记。
  ///
  /// 从**第一条内容正好是 `---` 的行**开始（含它自己）往后标。那一条就是
  /// [ComposeHtml.replyQuote] 插在引用前面的分隔线 —— 它本身也该算引用区，
  /// 因为它是被引用原文一起带进来的，不该被 AI 当成用户写的正文。
  ///
  /// 找不到 `---` 那一行时**原样返回**（没有引用区的文档，打标记无从谈起）。
  static List<Map<String, dynamic>> markQuoted(List<Map<String, dynamic>> ops) {
    final lines = _lines(ops);
    final first = lines.indexWhere((line) => line.text.trim() == '---');
    if (first < 0) return ops;
    return _markFrom(ops, lines[first].start);
  }

  /// 用户自己写的内容到哪里为止（角色偏移）。
  ///
  /// 返回的是**第一条带标记的那一行前面那个 `\n` 的位置** —— 于是
  /// `[0, userEnd)` 正好是用户写的那几个字符，**不含任何行尾换行**。
  ///
  /// 为什么不是「带标记那一行的行首」：那个位置**含**着上一行的行尾 `\n`，
  /// 而润色落地时是「把 `[0, userEnd)` 换成模型给的文字」—— 模型给的是
  /// 一段没有行尾的文本，换完 `你好\n---` 会变成 `您好---`：横线的
  /// `html == '---'` 判据当场失效（见 `delta_to_email_html.dart:52`），
  /// 用户要的那条线就没了。取到 `\n` 的位置，`\n` 就留在原地当分隔，横线仍在
  /// 自己那一行上。
  ///
  /// 没有带标记的行时返回 `长度 - 1`（与「整篇替换但留住末尾那个 `\n`」一致，
  /// 见 `ComposeScreen._replaceUserBody`）—— 于是「用户把引用整段删掉」「旧草稿
  /// 里没有标记」两种情况的行为跟打标记之前逐字相同，不需要迁移。
  static int userEnd(List<dynamic> delta) {
    for (final line in _lines(delta)) {
      if (isQuoteLine(line.attributes)) {
        return line.start - 1 < 0 ? 0 : line.start - 1;
      }
    }
    final total = _totalLength(delta);
    return total <= 0 ? 0 : total - 1;
  }

  /// 只留用户自己写的部分。返回的是可以直接喂给
  /// [DeltaToEmailHtml.convert] 的 op 列表。
  ///
  /// 边界**可能落在一个 op 中间**：`Document.toDelta()` 会把属性相同的相邻
  /// op 合并（探针实测出现过 `{"insert":"\n---"}` 这种「上一行的行尾」与
  /// 「下一行的开头」合体的 op），所以这里按**字符**切，不是按 op 切。
  static List<dynamic> userDelta(List<dynamic> delta) {
    final end = userEnd(delta);
    if (end <= 0) return const <dynamic>[];
    final out = <dynamic>[];
    var offset = 0;
    for (final raw in delta) {
      if (raw is! Map) continue;
      final data = raw['insert'];
      final length = data is String ? data.length : 1;
      if (offset + length <= end) {
        out.add(raw);
        offset += length;
        continue;
      }
      if (offset >= end) break;
      // 切在 op 中间：只可能是文本（嵌入占一个字符，切不进它内部）。
      if (data is String) {
        final copy = Map<String, dynamic>.from(raw);
        copy['insert'] = data.substring(0, end - offset);
        out.add(copy);
      }
      break;
    }
    return out;
  }

  /// 用户自己写的部分的**纯文本**（喂给模型用）。
  ///
  /// 绕一圈（Delta → HTML → 纯文本）与 `ComposeScreen.composePlainText` 同路，
  /// 于是「模型看到的正文」与「收件人看到的正文」永远是同一个形状。
  static String plainText(List<dynamic> delta) =>
      PlainText.fromHtml(DeltaToEmailHtml.convert(userDelta(delta)));

  /// 这段 delta 里有没有块级/行内嵌入（图片、表格）。
  ///
  /// [before] 给定时只看到那个角色偏移为止 —— 润色的守卫要的是「**用户写的
  /// 那段**里有没有嵌入」，引用里带的图片不归它管（那是引用，本来就要原样
  /// 留着）。不给就是整段。
  static bool hasEmbed(List<dynamic> delta, {int? before}) {
    var offset = 0;
    for (final raw in delta) {
      if (raw is! Map) continue;
      final data = raw['insert'];
      if (data is! String) {
        if (before == null || offset < before) return true;
        offset += 1;
        continue;
      }
      offset += data.length;
    }
    return false;
  }

  /// 一行行尾的属性算不算「引用」。
  static bool isQuoteLine(Object? attributes) =>
      attributes is Map &&
      attributes[MailHtmlToDelta.quoteAttribute] == true;

  // --------------------------------------------------------------- 内部

  /// delta 的总长度（角色数）。嵌入占一个字符 —— 与 `Document.length`、
  /// 选区偏移同一套坐标系。
  static int _totalLength(List<dynamic> delta) {
    var total = 0;
    for (final raw in delta) {
      if (raw is! Map) continue;
      final data = raw['insert'];
      total += data is String ? data.length : 1;
    }
    return total;
  }

  /// 逐字符走一遍 delta，每遇到一个 `\n` 就产出一行。
  ///
  /// **必须按字符走**：`Document.toDelta()` 合并属性相同的相邻 op 之后，
  /// 「行尾 `\n`」与「下一行的文字」可能在同一个 op 里（`{"insert":"\n---"}`），
  /// 按 op 切会算错边界。最后若还有没被 `\n` 收尾的内容，那不是一行（Quill
  /// 的文档永远以 `\n` 收尾，这一支只是防御）。
  static List<_QuoteLine> _lines(List<dynamic> delta) {
    final out = <_QuoteLine>[];
    final text = StringBuffer();
    var offset = 0;
    var start = 0;
    for (final raw in delta) {
      if (raw is! Map) continue;
      final data = raw['insert'];
      if (data is! String) {
        // 嵌入：占一个字符，且行内出现嵌入意味着这行只有它（quill 的硬约束）。
        text.write('￼');
        offset += 1;
        continue;
      }
      var i = 0;
      while (true) {
        final at = data.indexOf('\n', i);
        if (at < 0) {
          text.write(data.substring(i));
          offset += data.length - i;
          break;
        }
        text.write(data.substring(i, at));
        offset += at - i;
        out.add(_QuoteLine(
          start: start,
          text: text.toString(),
          attributes: raw['attributes'],
        ));
        offset += 1; // 换行本身
        start = offset;
        text.clear();
        i = at + 1;
      }
    }
    return out;
  }

  /// 把 [from]（角色偏移）之后的行尾 `\n` 都标上 [MailHtmlToDelta.quoteAttribute]。
  ///
  /// 逐 op 判断「这个 op 里有没有一个 `\n` 落在 [from] 之后」—— 有就把整个 op
  /// 标上（一个 op 里的 `\n` 只可能是同一段引用的行尾，不存在「一半在线上
  /// 一半在线下」）。
  static List<Map<String, dynamic>> _markFrom(
    List<Map<String, dynamic>> ops,
    int from,
  ) {
    final out = <Map<String, dynamic>>[];
    var offset = 0;
    for (final op in ops) {
      final data = op['insert'];
      if (data is! String) {
        out.add(op);
        offset += 1;
        continue;
      }
      var touches = false;
      for (var i = 0; i < data.length; i++) {
        if (data.codeUnitAt(i) == 0x0A && offset + i >= from) {
          touches = true;
          break;
        }
      }
      if (!touches) {
        out.add(op);
        offset += data.length;
        continue;
      }
      final attrs = <String, dynamic>{
        if (op['attributes'] is Map)
          ...Map<String, dynamic>.from(op['attributes'] as Map),
        MailHtmlToDelta.quoteAttribute: true,
      };
      out.add(<String, dynamic>{'insert': data, 'attributes': attrs});
      offset += data.length;
    }
    return out;
  }
}

/// 一行：行首的角色偏移、这一行的文字（不含行尾 `\n`）、行尾那个 `\n` 的属性。
class _QuoteLine {
  const _QuoteLine({
    required this.start,
    required this.text,
    required this.attributes,
  });

  final int start;
  final String text;
  final Object? attributes;
}
