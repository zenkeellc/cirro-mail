import 'package:flutter/material.dart';

/// 写邮件页表头三行（发件人 / 收件人 / 主题）共用的尺寸与间距。
///
/// 收成一处的理由：这三行原来是各写各的
/// `Padding(top: 10) + Text(label) + SizedBox(width: 12)`，而 label 的宽度
/// **跟着字数变**（「主题」两个字 vs 「发件邮箱」四个字）—— 于是右侧输入区的
/// 左边界三行对不齐：主题框比收件人框往左缩了 28px。单看一行不觉得，
/// 三行叠在一起就是「没排过版」。
///
/// 现在 label 进固定宽度的列，输入区一律从
/// `16 + 64 + 8 = 88` 起算。要改就改这里，三行一起动。
const double kComposeFieldLabelWidth = 64;

/// label 列与内容之间的间距。
const double kComposeFieldGap = 8;

/// 表头每一行的左右内边距。
///
/// 上下各 6：单行内容高 30，加上就是一行 42 —— 比 Material 默认的 48 紧，
/// 但比改造前的「label 自带 top:10」更整齐（那一版行高是浮动的）。
const EdgeInsets kComposeFieldRowPadding = EdgeInsets.fromLTRB(16, 6, 16, 6);

/// 表头内容**第一行**的高度。
///
/// 单选输入框与收件人 chip 都用这个高度：两行的高度一致，label 才能用
/// 同一个上留白对齐。收件人 chip 有多行时，label 只对第一行。
const double kComposeFieldLineHeight = 30;

/// 表头输入框的上下 `contentPadding`（主题行是 5/5）。
///
/// 只用于算 label 的对齐偏移：内容高度 = 文字行高 + 2×这个数，大字号时
/// 输入框会比 [kComposeFieldLineHeight] 高，label 得跟着内容的中线走。
const double kComposeFieldContentPadding = 5;

/// 表头的一行：固定宽度的 label 列 + 内容 +（可选）行尾控件。
///
/// 对齐方式：`Row` 的 `crossAxisAlignment` 是 **start**，label 自己带一个
/// 上留白，让它的首行文字与内容第一行**同一中线**（不是「顶边对齐」——
/// 顶边对齐在 30 高的输入框上会看着 label 偏高）。
///
/// 内容不要自己再套 `Expanded`：[child] 已经在这个 `Expanded` 里了。
class ComposeFieldRow extends StatelessWidget {
  const ComposeFieldRow({
    super.key,
    required this.label,
    required this.child,
    this.trailing,
    this.onTap,
    this.labelWidth = kComposeFieldLabelWidth,
    this.padding = kComposeFieldRowPadding,
    this.firstLineHeight = kComposeFieldLineHeight,
    this.labelStyle,
  });

  final String label;

  final Widget child;

  /// 行尾控件（主题栏的「AI 起标题」）。与内容顶端对齐到同一中线。
  final Widget? trailing;

  /// 点整行（含 label）时的回调 —— 用来把焦点请进输入框。
  final VoidCallback? onTap;

  final double labelWidth;
  final EdgeInsets padding;
  final double firstLineHeight;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = labelStyle ??
        theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    // label 的文字行高（bodyMedium 是 14sp × 1.43 ≈ 20）。
    //
    // 用 `textScalerOf` 一起缩放：系统放大字体时内容第一行也跟着变高，
    // 而 firstLineHeight 是个固定值 —— 不缩放的话大字号下 label 会越来越偏上。
    final scaledLine = MediaQuery.textScalerOf(context)
        .scale(style?.fontSize ?? 14) *
        (style?.height ?? 1.43);
    // 内容第一行的**实际**高度：常规字号时就是 [firstLineHeight]（30）；
    // 字号放大到 20sp 以上时，文字本身 + 上下各 5 的 `contentPadding`
    // 会超过 30 —— 输入框跟着长高，label 要按新的行高算才不会偏。
    //
    // 那个 5 是写邮件表头输入框的约定（主题行 `contentPadding: 5/5`、
    // 发件人触发行 30 高）。它不该抽成参数：三行的内容高度本来就该一致，
    // 各自传一个数只会让「对齐」这件事重新散开。
    final contentLine = scaledLine + kComposeFieldContentPadding * 2 >
            firstLineHeight
        ? scaledLine + kComposeFieldContentPadding * 2
        : firstLineHeight;
    // 内容第一行的中线在 contentLine/2，label 的中线要落在同一处。
    final inset = ((contentLine - scaledLine) / 2).clamp(0.0, double.infinity);

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: labelWidth,
          child: Padding(
            padding: EdgeInsets.only(top: inset),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ),
        const SizedBox(width: kComposeFieldGap),
        Expanded(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: firstLineHeight),
            child: child,
          ),
        ),
        if (trailing != null)
          Padding(
            padding: EdgeInsets.only(top: inset),
            child: trailing,
          ),
      ],
    );

    return Padding(
      padding: padding,
      child: onTap == null
          ? row
          // `behavior: translucent`：内容自己还要收到指针事件（TextField、
          // chip 的删除按钮），这里只补「点空白处也能进输入框」。
          : GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onTap,
              child: row,
            ),
    );
  }
}
