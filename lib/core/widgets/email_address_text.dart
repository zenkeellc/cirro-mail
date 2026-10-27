import 'package:flutter/material.dart';

import '../util/email_address.dart';

/// 显示一个邮箱地址：**本地部分加粗，`@` 与域名保持常规字重**。
///
/// 用在所有「一格里写着 `xxxx@xxx.com`」的地方（侧栏邮箱列表、邮箱筛选面板、
/// 设置里的邮箱列表、邮件列表的发件人）。理由：一张列表里域名几乎恒定，
/// 扫视时要先认出来的是「谁」—— 本地部分加重、域名退回去，落差就出来了。
///
/// 一段文字里可能有 0 个、1 个或多个地址：发件行是 `a@x.com、b@y.com`，
/// 收件人显示名是 `张三 <a@x.com>`。**只有地址的本地部分变重**，名字、
/// 分隔符、`@域名` 全是原样式。
///
/// 传进来的 [style] 是「常规」那一档（颜色、字号、已读/未读的基础字重）；
/// 本地部分只是在这之上再压一个 [localWeight]。所以给 `style` 时字重要按
/// 「域名该有多重」来定 —— 给成加粗的话整段一起变粗，本地部分就显不出
/// 落差了。
class EmailAddressText extends StatelessWidget {
  const EmailAddressText(
    this.text, {
    super.key,
    this.style,
    this.localWeight = FontWeight.w700,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  /// 要显示的原文。可能是一个地址、一串地址，也可能只是一句话（显示名、
  /// 「全部邮箱」这类文案）—— 后者原样输出，不加粗任何东西。
  final String text;

  /// 常规字重的那一档样式。`null` = 跟随外层 `DefaultTextStyle`。
  final TextStyle? style;

  /// 地址本地部分用的字重。默认 `w700`。
  ///
  /// 留成参数是为了「整段本来就该有轻重」的地方：邮件列表的收件行用
  /// 发件人的名字（不是地址），未读/已读的差别本来就压在基础字重上。
  final FontWeight localWeight;

  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: emailAddressSpans(text, localWeight: localWeight),
      ),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}

/// 把 [text] 切成若干 span：地址的本地部分挂上 [localWeight]，其余不挂
/// （继承外层样式）。
///
/// 单独抽出来是为了能脱离 widget 测「切的边界」—— 这个函数最容易错的地方
/// 是切错位置（把 `@` 或域名一起加粗、或把显示名当成地址），而它的输出
/// 在 widget 树里只表现为看不见的样式差异，肉眼复查不可靠。
@visibleForTesting
List<InlineSpan> emailAddressSpans(
  String text, {
  FontWeight localWeight = FontWeight.w700,
}) {
  if (text.isEmpty) return const <InlineSpan>[];

  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in emailAddressInTextPattern.allMatches(text)) {
    final at = text.indexOf('@', match.start);
    // 理论上一定能找到（正则里就有 `@`）；防一手，别让坏数据把整段吞掉。
    if (at <= match.start || at >= match.end) continue;
    // `@域名` 不单独成 span：它和后面那段普通文字一起收尾，字重自然是常规的。
    if (match.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, match.start)));
    }
    spans.add(TextSpan(
      text: text.substring(match.start, at),
      style: TextStyle(fontWeight: localWeight),
    ));
    cursor = at;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return spans;
}
