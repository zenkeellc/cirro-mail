import 'package:flutter/material.dart';

/// 应用主题。
///
/// 只做一件事：给 Element Plus 风格的浅蓝一个品牌色，其余交给 Material 3。
/// 刻意不引入任何字体包 —— 邮件正文要跟着系统字体走，UI 字体跟着系统走
/// 才不会在中日韩混排时出现突兀的字形切换。
class AppTheme {
  const AppTheme._();

  /// 对齐 Web 端 `--el-color-primary` 的蓝（`#0E70DF` 附近）。
  static const Color seed = Color(0xFF2F6FED);

  /// 邮件正文里链接的颜色，与 `mail-vue` 的 shadow-html 默认样式一致。
  static const Color bodyLink = Color(0xFF0E70DF);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // 桌面端（Windows/Linux）默认的紧凑密度更接近邮件的使用习惯。
      visualDensity: VisualDensity.standard,
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      // 列表 / 详情里的分割线用最淡的一档，邮件的行数很多。
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.5),
      ),
      listTileTheme: const ListTileThemeData(
        // 邮件列表要在一屏塞下尽量多的行。
        dense: true,
        visualDensity: VisualDensity.compact,
        minVerticalPadding: 8,
      ),
      // 标签（收件人 chips、邮箱标签）要能一行排下好几个，所以只压内边距，
      // 不动 `materialTapTargetSize` —— 那个字段在 ChipThemeData 上不存在，
      // 点击热区由 ThemeData.visualDensity 统一管。
      chipTheme: base.chipTheme.copyWith(
        labelPadding: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
    );
  }
}
