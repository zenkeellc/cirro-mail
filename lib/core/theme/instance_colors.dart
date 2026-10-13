import 'package:flutter/material.dart';

/// 实例色标。
///
/// 聚合时间线里每一行都要能一眼看出「这封来自哪个实例」，靠左侧一条细色带 +
/// 实例首字母圆点。颜色按 `profile.colorIndex` 取模，用户可在设置里改。
///
/// 注意用 `Colors.primaries` 里**饱和度适中**的几个：太亮的（yellow/lime）在
/// 浅色主题下白字看不清，太暗的（indigo/blueGrey 深色档）在深色主题下发灰。
class InstanceColors {
  const InstanceColors._();

  /// 可选色板。顺序稳定 —— `colorIndex` 落库后不能因为改了这个列表而变色。
  static const List<Color> palette = <Color>[
    Color(0xFF2F6FED), // 蓝
    Color(0xFF14A085), // 青绿
    Color(0xFFD97706), // 琥珀
    Color(0xFF9333EA), // 紫
    Color(0xFFDC2626), // 红
    Color(0xFF0891B2), // 天青
    Color(0xFF65A30D), // 橄榄
    Color(0xFFDB2777), // 品红
  ];

  static int get length => palette.length;

  /// 取色（越界取模，老数据里 colorIndex 越界也不会崩）。
  static Color of(int index) {
    if (palette.isEmpty) return const Color(0xFF2F6FED);
    final safe = index % palette.length;
    return palette[safe < 0 ? safe + palette.length : safe];
  }

  /// 在一组已用过的下标里挑一个「用得最少」的，让新实例的颜色尽量不撞。
  static int nextIndex(Iterable<int> used) {
    final counts = List<int>.filled(palette.length, 0);
    for (final index in used) {
      final safe = index % palette.length;
      counts[safe < 0 ? safe + palette.length : safe]++;
    }
    var best = 0;
    for (var i = 1; i < counts.length; i++) {
      if (counts[i] < counts[best]) best = i;
    }
    return best;
  }

  /// 实例色标的稳定底色（浅色主题下）。
  static Color background(BuildContext context, int index) =>
      of(index).withValues(alpha: 0.12);

  /// 实例首字母（侧栏圆点用）。
  static String initial(String label) {
    final text = label.trim();
    if (text.isEmpty) return '?';
    return text.characters.first.toUpperCase();
  }
}
