import 'package:flutter/widgets.dart';

/// 文字/高亮/字号的**唯一定义**。三处共用：
///
/// 1. 工具栏三个下拉（`compose_toolbar.dart`）
/// 2. 导出端白名单（`delta_to_email_html.dart`）
/// 3. 导入端的夹取表（`mail_html_to_delta.dart` / `email_html_sanitizer.dart`）
///
/// **为什么必须只有一份**：早先的风险是「下拉里给的是 10 色、导出端白名单
/// 只认 6 色」，用户选了颜色、发出后发现没生效 —— 而且这个不一致**不会**报错。
/// 定义在一处，导出端拿它生成 `style` 值，导入端拿它夹取，三边天然一致。

/// 一个可选的文字颜色。
@immutable
class TextColorOption {
  const TextColorOption(this.hex);

  /// 小写、带 `#`、六位 —— 与净化器的 `^#[0-9a-f]{6}$` 同形。
  final String hex;

  /// 在工具栏色块里显示的颜色。
  Color get swatch => Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);
}

/// 十个文字颜色。第一格是**黑**（界面上的「默认」）。
///
/// 注意它**是设属性**（写入 `color:#000000`），不是「清掉 color」——
/// 清色走溢出菜单里的「清除格式」。所以工具栏上要有白底容器兜住
/// 「用户设了黑、收件人却是深色模式」这一种情况（spec §3 批 B）。
///
/// 为什么是这十个：邮件里能读得清的深浅各半，且都不是纯饱和的三原色
/// （纯 `#ff0000` 那种在浅色背景上刺眼、在深色背景上发糊）。
const List<TextColorOption> kTextColors = <TextColorOption>[
  TextColorOption('#000000'), // 黑
  TextColorOption('#5f6368'), // 灰
  TextColorOption('#1a73e8'), // 蓝
  TextColorOption('#188038'), // 绿
  TextColorOption('#d93025'), // 红
  TextColorOption('#e37400'), // 橙
  TextColorOption('#9334e6'), // 紫
  TextColorOption('#007b83'), // 青
  TextColorOption('#a142f4'), // 淡紫
  TextColorOption('#c5221f'), // 深红
];

/// 六个高亮色。都是浅底，配黑色字能读。
const List<TextColorOption> kHighlightColors = <TextColorOption>[
  TextColorOption('#fef7e0'), // 米黄
  TextColorOption('#e6f4ea'), // 浅绿
  TextColorOption('#e8f0fe'), // 浅蓝
  TextColorOption('#fce8e6'), // 浅红
  TextColorOption('#f3e8fd'), // 浅紫
  TextColorOption('#e4f7fb'), // 浅青
];

/// 字号档位。键是 Delta 里 `size` 属性的值，值是像素。
///
/// **键用数字字符串而不是 `'小'`/`'大'`**：上游 `getFontSize(dynamic)`
/// 对 `'small'`/`'normal'`/`'large'`/`'huge'` 是**原样透传**的
/// （`common/utils/font.dart`），而 `'14'` 这种数字串会走
/// `double.tryParse` 拿到 14 —— 我们要的是后者（见 §0.2 第 18 条：
/// `1.2em` 也被上游映成 `'19'`，说明数字串才是它的常规通道）。
const Map<String, double> kFontSizes = <String, double>{
  '14': 14,
  '16': 16,
  '19': 19,
  '24': 24,
};

/// 档位的中文名（下拉里显示）。
const Map<String, String> kFontSizeLabels = <String, String>{
  '14': '小',
  '16': '正常',
  '19': '大',
  '24': '特大',
};

/// **导入端**把上游给的字号值夹到我们认得的档位。
///
/// 上游给的东西五花八门（§0.2 第 18 条实测）：`19px`→`'19'`、
/// `1.2em`→`'19'`、`12pt`→`'15'`、`2rem`→`'32'`、`9px`→`'small'`、
/// `120px`→`'120'`。**不能原样信**：`'120'` 会让编辑器渲染出 120px 的字，
/// `'small'` 这种非数字串进 `getFontSize` 又会走另一条分支。
/// 所以这里一律映到最近的档位。
///
/// 映法：解析成数（解析不出就返回 null，即「不设字号」），
/// 再取**距离最近**的档位；正好在中间时取小的那个。
String? clampFontSize(String raw) {
  final value = double.tryParse(raw);
  if (value == null) return null;
  if (value <= 0) return null;
  String best = '16';
  var bestGap = double.infinity;
  for (final entry in kFontSizes.entries) {
    final gap = (value - entry.value).abs();
    if (gap < bestGap) {
      bestGap = gap;
      best = entry.key;
    }
  }
  return best;
}

/// **导出端**把 Delta 里的 `size` 值变成 CSS 像素。
///
/// 值不认识（不是四个档位之一）就返回 null，让导出端**不带 `font-size`**
/// —— 宁可不带，也不要写一个 `font-size:120px` 出去。
String? fontSizeCss(String? size) {
  if (size == null) return null;
  final px = kFontSizes[size];
  if (px == null) return null;
  return '${px.round()}px';
}

/// 颜色值的形状校验。导出端与导入端共用同一个正则 —— 分开写就会漂。
final RegExp kHexColorPattern = RegExp(r'^#[0-9a-f]{6}$');

/// **导出端**用的：`#1a73e8` → `#1a73e8`；形状不对给 null。
String? safeHexColor(String? raw) {
  if (raw == null) return null;
  final lower = raw.toLowerCase();
  return kHexColorPattern.hasMatch(lower) ? lower : null;
}
