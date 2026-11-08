import 'package:flutter/material.dart';

/// 一套可选的界面主题。
///
/// ## 为什么是「一整套 ThemeData」，而不是一个种子色
///
/// Material 3 的 `ColorScheme.fromSeed` 会把任何种子色压成同一档明度/饱和度
/// 的派生色 —— 多个种子色喂进去，出来的界面**几乎一样**。要做「青花瓷」和
/// 「赛博朋克」这种气质差很远的主题，必须能自己定表面色、文字色、主色与
/// 强调色，所以接口收的是成品 [ThemeData]，不是种子。
///
/// ## 「背板」是主题的一部分，但不是主题的全部
///
/// [buildBackdrop] 返回的 widget 铺在**整棵 UI 下面**（`MaterialApp.builder`
/// 里、router 内容之下），用来做渐变 / 纹理这类不靠配色的视觉。内核会替它包
/// 一层 `IgnorePointer` 与 `RepaintBoundary`，实现方不要自己加手势或动画。
///
/// 想让它露出来，[build] 给出的 `ThemeData.scaffoldBackgroundColor` 要留一点
/// 透明度（典型 88%~92%）—— 全不透明等于背板被盖死，反而白画。
///
/// ## 纪律
///
/// - [build] 必须是**纯函数**：不读 prefs、不读注册表、不碰 IO，同一个
///   brightness 反复调用结果一致（核心会在每次重建主题时调用它）；
/// - [name] / [family] 按 [Locale] 现选文案（核心的 ARB 是公开仓库资产，
///   不会为主题名加词条）；
/// - [id] 稳定且唯一 —— 用户的选择按 id 存进 prefs，改 id 等于把用户的选择
///   弄丢。
@immutable
abstract class ThemePack {
  const ThemePack();

  /// 稳定标识。约定用短横线小写（`qinghua`、`starship-hud`）。
  String get id;

  /// 显示名（画廊卡片标题）。
  String name(Locale locale);

  /// 分组名（画廊卡片的副标题，例如「东方 · 器物」）。空串 = 不显示。
  String family(Locale locale) => '';

  /// 这一套的亮色 / 暗色两版。
  ///
  /// 两版都要给：主题与「亮/暗/跟随系统」是**两个正交的维度**，用户可以在
  /// 任一主题下切换明暗。
  ThemeData build(Brightness brightness);

  /// 铺在 UI 下面的背板。返回 null = 这套主题不要背板（纯配色主题）。
  ///
  /// 画布尺寸由内核给的约束决定（通常就是窗口大小），实现方自己用
  /// `CustomPaint` / `DecoratedBox` 铺满即可。**不要**在里面放大图资源。
  Widget? buildBackdrop(BuildContext context) => null;

  @override
  String toString() => 'ThemePack($id)';
}
