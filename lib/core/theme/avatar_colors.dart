import 'package:flutter/material.dart';

/// 发件人头像的色板。
///
/// **刻意与 [InstanceColors] 分开**（两者都在 `core/theme/` 下，但解决的是
/// 两件事）：实例色表达「这封来自哪个实例」，头像色表达「这封是谁发的」。
/// 共用一套色板会让这两个互不相干的信息看起来像同一回事 —— 而聚合视图里
/// 两者正好同框（左边一条实例色带，右边一颗头像）。
///
/// 取色规则是**按发件地址哈希**，所以同一个人在不同实例、不同文件夹里
/// 永远是同一个颜色。
class AvatarColors {
  const AvatarColors._();

  /// 头像底色。12 色（比实例那 8 色多，因为「认人」比「认实例」更依赖颜色：
  /// 一个账号可能对上几百个发件人）。
  ///
  /// 顺序稳定 —— 改了会让所有人的头像变色。全部是**深色**：白字压在上面，
  /// 对比度由 `avatar_colors_test.dart` 钉住（≥4.5:1）。
  static const List<Color> palette = <Color>[
    Color(0xFF1D4ED8), // 蓝
    Color(0xFF0F766E), // 青
    Color(0xFFB45309), // 琥珀
    Color(0xFF7E22CE), // 紫
    Color(0xFFB91C1C), // 红
    Color(0xFF0E7490), // 天青
    Color(0xFF4D7C0F), // 橄榄
    Color(0xFFBE185D), // 品红
    Color(0xFF4338CA), // 靛
    Color(0xFF047857), // 翠
    Color(0xFF9A3412), // 赭
    Color(0xFF6D28D9), // 蓝紫
  ];

  static int get length => palette.length;

  /// 按发件地址取底色。
  ///
  /// 越界取模，与 [InstanceColors.of] 同一套防御（老数据/异常输入不崩）。
  static Color of(String id) {
    final safe = indexOf(id) % palette.length;
    return palette[safe < 0 ? safe + palette.length : safe];
  }

  /// 地址 → 色板下标。
  ///
  /// 用**自己写的 FNV-1a**而不是 `String.hashCode`：后者的值不保证跨版本、
  /// 跨平台稳定，而这里要的恰恰是「同一个人永远是同一个颜色」—— 一次
  /// Dart 版本升级让全列表换色，用户会以为自己看错了。
  ///
  /// 先 `trim().toLowerCase()`：服务端给的名字大小写不总是一致，而
  /// 「Alice@x.com」和「alice@x.com」显然是同一个人。
  static int indexOf(String id) {
    var hash = 0x811c9dc5;
    for (final unit in id.trim().toLowerCase().codeUnits) {
      hash ^= unit;
      // FNV 质数 16777619。`& 0xFFFFFFFF` 把结果钉在 32 位无符号范围内
      // —— Dart 的 int 是 64 位，不截断的话越乘越大。
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash % palette.length;
  }

  /// 头像上的那个字：取首个可见字符（`characters` 而不是 `[0]`，否则
  /// emoji 与组合字符会被切成半个）。
  static String initial(String label) {
    final text = label.trim();
    if (text.isEmpty) return '?';
    return text.characters.first.toUpperCase();
  }
}
