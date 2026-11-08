import 'package:flutter/material.dart';

/// 邮件正文（HTML 渲染）里跟随主题走的颜色。
///
/// 为什么单独一个 [ThemeExtension] 而不是直接用 `colorScheme.primary`：
/// **默认主题的形状不能变**。公开版至今把正文链接钉在 `AppTheme.bodyLink`
/// （`#0E70DF`，与 Web 端 shadow-html 一致）；如果这里直接读 primary，公开版
/// 的链接色会跟着 Material 3 的调色一起漂移。做成「有 tokens 就用 tokens、
/// 没有就回落到老常量」之后：
///
/// - 公开版 / 内置默认主题：一个 tokens 都不注册 → 颜色逐字不变；
/// - 扩展主题（商业版的 8 套）：在自己的 `ThemeData.extensions` 里塞一份，
///   正文链接就跟着主题走（否则水墨主题里跳出一条电商蓝链接）。
@immutable
class MailBodyTokens extends ThemeExtension<MailBodyTokens> {
  const MailBodyTokens({required this.link});

  /// 正文里 `<a>` 的颜色。
  final Color link;

  @override
  MailBodyTokens copyWith({Color? link}) =>
      MailBodyTokens(link: link ?? this.link);

  @override
  MailBodyTokens lerp(ThemeExtension<MailBodyTokens>? other, double t) {
    if (other is! MailBodyTokens) return this;
    return MailBodyTokens(link: Color.lerp(link, other.link, t) ?? link);
  }

  @override
  String toString() => 'MailBodyTokens(link: $link)';
}
