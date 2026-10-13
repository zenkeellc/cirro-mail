import 'package:flutter/widgets.dart';

/// 扩展往「设置」页加的一栏。
///
/// 核心把它排在内置九栏**之后**、并在同一套载体里渲染：宽屏进分类栏的
/// `NavSidebarItem` 与右栏的 `IndexedStack`，窄屏进那张分类列表与分类页。
/// 也就是说扩展**不需要**自己搭 `Scaffold` / `AppBar` / 返回箭头 —— 那是宿主的
/// 事（理由见 `settings_screen.dart` 里关于两种形态的注释）。
///
/// ## 「关于」那一栏的位置
///
/// [AppExtension.settingsSections] 的文档里写着扩展分类统一排在**最后**。落实
/// 到实现上：核心把扩展分类插在「诊断」之后、**「关于」之前** —— 「关于」按
/// 惯例永远是最后一栏，把扩展塞到它后面会让每个 App 的最后一栏都不一样。
///
/// ## 为什么图标是两枚
///
/// 与核心的 `SettingsCategory` 同口径：分类栏靠**图标变化 + 底色**一起说
/// 「你在这儿」。只给一枚的话选中态就只剩底色一个信号。窄屏那张列表只用
/// [icon]（那里没有选中态）。
@immutable
class SettingsSection {
  const SettingsSection({
    required this.id,
    required this.icon,
    required this.selectedIcon,
    required this.title,
    required this.body,
  });

  /// 稳定标识，用于去重与日志。约定与 [AppExtension.id] 一致（反向域名）。
  final String id;

  final IconData icon;
  final IconData selectedIcon;

  /// 分类名。**由扩展自己按 `Localizations.localeOf(context)` 选** ——
  /// `SettingsSection` 是在 `settingsSections(context)` 里现造的，那一刻拿得到
  /// context。核心的 ARB 里不会有扩展的文案（那是公开仓库的本地化资产）。
  final String title;

  /// 正文。宿主已经搭好滚动容器之外的骨架，这里只出内容。
  ///
  /// 与 [AppExtension.aboutExtras] 的约定相反：**这里可以（也通常会）返回自带
  /// 滚动容器的 widget** —— 设置栏的正文本来就该自己滚。
  final WidgetBuilder body;

  @override
  String toString() => 'SettingsSection($id, "$title")';
}
