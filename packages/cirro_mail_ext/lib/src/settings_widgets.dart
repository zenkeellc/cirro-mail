/// 设置页各分类共用的视觉积木。
///
/// ## 为什么住在 `cirro_mail_ext` 而不是核心 App
///
/// 商业包（账号 / 订阅那一栏）只依赖这个公开包，**不能** import 核心 App。
/// 两边的设置页要长得一模一样，积木就必须放在两边都 import 得到的地方。
/// 核心 App 的 `features/settings/settings_widgets.dart` 只是把这些名字
/// re-export 出去 —— 历史 import 路径与调用点都不用改。
///
/// ## 这一套积木解决什么
///
/// 以前的设置页是一条 `ListView` 里平铺 `ListTile` + 大段 `Text`：每行之间
/// 没有分隔、说明文字和正文一个字号，扫一眼全是字。四种积木把版面分成
/// 「组 → 行 → 说明」三层：
///
/// - [SettingsGroup]：一张圆角卡片装一组设置项，行间自动画细分隔线；
/// - [SettingsTile]：组里的标准一行（图标 + 标题 + 副标题 + 尾部）；
/// - [SettingsHint]：组内/组下的补充说明（小字、次要色、行高放宽）；
/// - [SettingsNote]：整块提示（隐私声明、安全提醒），带底色与图标。
///
/// 另外两件不是「积木」而是版面约定：
///
/// - [SettingsPage]：各分类正文的外壳 —— 统一内边距，**宽屏限宽并居中**
///   （一行字横跨 1400px 读起来很累）；
/// - [SettingsSectionHeader]：老的分组小标题，保留（部分页面还在用它，
///   与 [SettingsGroup] 的标题同一套字号/颜色）。
library;

import 'package:flutter/material.dart';


/// 设置页里各分类正文的外壳。
///
/// 统一两件事：
///
/// 1. **滚动与内边距**：分类正文一律用它，不要每页自己写 `ListView`；
/// 2. **宽屏限宽**：窗口再宽，正文最宽也只铺 [maxWidth]，并居中 ——
///    一条说明文字横跨整屏会非常难读（正文行长超过约 40 个汉字之后，
///    眼睛回行会丢行）。
///
/// 窄屏（`maxWidth + 两侧留白` 以内）时子项直接铺满，不做任何居中：
/// 手机 / 平板本来就窄，再限宽只会浪费宽度。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.children,
    this.maxWidth = 760,
    this.padding = const EdgeInsets.only(top: 8, bottom: 40),
  });

  final List<Widget> children;

  /// 正文最大宽度（逻辑像素）。默认 760 —— 一张设置卡片在这个宽度里
  /// 标题与说明都能一行放下，又不至于让说明文字长到难读。
  final double maxWidth;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          // 两侧各留 16 的呼吸位：窗口刚好等于正文宽时仍算「窄」，铺满。
          if (constraints.maxWidth <= maxWidth + 32) {
            return ListView(padding: padding, children: children);
          }
          return ListView(
            padding: padding,
            children: <Widget>[
              for (final child in children)
                Center(child: SizedBox(width: maxWidth, child: child)),
            ],
          );
        },
      );
}

/// 一组设置项：可选图标 + 标题 + 可选说明，下面是一张装了若干行的卡片。
///
/// 行与行之间自动插一条**细**分隔线（`outlineVariant` 的半透明），所以
/// 调用方只管把行按顺序放进来，不用自己 `Divider`。卡片整体是 Material 3
/// 的 `surfaceContainerLow` 底色 + 描边 + 12 圆角，深浅色都成立。
///
/// [trailing] 在标题行右侧（例如刷新按钮、状态徽章）；[description] 是
/// 标题下的一句说明（小字、次要色）。
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.icon,
    this.description,
    this.trailing,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
  });

  /// 分组标题。为空时不画标题行（纯卡片）。
  final String? title;

  /// 标题左边的图标（16px，主题色）。设置页的「图标」不是装饰：扫视时
  /// 它比文字先被认出来，用户靠它定位「我要找的那一块在哪儿」。
  final IconData? icon;

  /// 标题下的一句说明。
  final String? description;

  /// 标题行右侧的控件（与标题同一行）。
  final Widget? trailing;

  final List<Widget> children;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 16,
            endIndent: 16,
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        );
      }
      rows.add(children[i]);
    }

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (title != null || icon != null || trailing != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                  ],
                  if (title != null)
                    Expanded(
                      child: Text(
                        title!,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  ?trailing,
                ],
              ),
            ),
          if (description != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                description!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          // 用 Material 而不是 Container：ListTile 的点击水波纹画在最近的
          // Material 祖先上，套一个带底色的 Container 会让它被盖住（Flutter
          // 调试断言会直接报「background color or ink splashes may be
          // invisible」）。Material 同时提供圆角/描边与那层祖先。
          Material(
            color: scheme.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ],
      ),
    );
  }
}

/// 组里的一行：图标 + 标题 + 可选副标题 + 可选尾部控件。
///
/// 与裸 `ListTile` 的区别是三处**统一**：图标尺寸/颜色（20px 次要色）、
/// 副标题样式（小字次要色、行高 1.4）、内边距（左右 16、上下 6）。
/// 有开关 / 下拉的行走 `SwitchListTile` / `ListTile` 也行，[SettingsGroup]
/// 只负责插分隔线，不强求用它。
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.icon,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final String title;

  /// 左侧图标。**尽量给**：整页扫下来，先被看到的是图标列。
  final IconData? icon;

  /// 副标题（说明 / 当前值 / 一句话解释）。
  final String? subtitle;

  /// 右侧控件（下拉、按钮、徽章、开关……）。开关请直接用
  /// `SwitchListTile(secondary: Icon(...))`，那才是无障碍正确的形状。
  final Widget? trailing;

  final VoidCallback? onTap;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      enabled: enabled,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: icon == null
          ? null
          : Icon(icon, size: 20, color: scheme.onSurfaceVariant),
      title: Text(
        title,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: enabled ? null : scheme.onSurfaceVariant,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
      trailing: trailing,
    );
  }
}

/// 一行补充说明（小字、次要色、行高放宽）。
///
/// 放在分组卡片**外面**（组与组之间、页尾）：卡片内部的行用
/// `SettingsTile.subtitle`，不要塞一段 [SettingsHint] 进去 —— 那会把
/// 「行」和「段落」混在一张卡里，正是以前乱的原因。
class SettingsHint extends StatelessWidget {
  const SettingsHint(
    this.text, {
    super.key,
    this.icon,
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 12),
    this.color,
  });

  final String text;

  /// 说明前的图标（可选，14px）。
  final IconData? icon;

  final EdgeInsetsGeometry padding;

  /// 覆盖文字颜色（例如错误/警告说明）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: color ?? scheme.onSurfaceVariant,
      height: 1.45,
    );
    if (icon == null) {
      return Padding(
        padding: padding,
        child: Text(text, style: style),
      );
    }
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 14, color: color ?? scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}

/// 整块提示（隐私声明、安全提醒、升级说明）。
///
/// 与 [SettingsHint] 的区别：这是一张**有底色的小卡**，用来承接一整段
/// 「需要读完」的话；灰字段落只承接「顺带看一眼」的补充。全页最多用一两处，
/// 多了又会变成另一堆色块。
class SettingsNote extends StatelessWidget {
  const SettingsNote({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.accent,
    this.action,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
  });

  final String text;

  final IconData icon;

  /// 强调色（图标与左侧竖线）。默认用主题色；警告类可传错误色。
  final Color? accent;

  /// 提示右侧/下方的一个动作（例如「去激活」「了解更多」）。
  final Widget? action;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = accent ?? scheme.primary;
    return Padding(
      padding: padding,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: tint.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 18, color: tint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                  height: 1.45,
                ),
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(width: 4),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 空态（还没有域名、还没有设备、还没有实例……）。
///
/// 图标 + 一句话 + 可选动作，居中但**不占满整屏** —— 设置页的空态只是
/// 某个分组暂时没内容，不要把整页画成一张巨大的「空」。
class SettingsEmptyState extends StatelessWidget {
  const SettingsEmptyState({
    super.key,
    required this.text,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 16),
  });

  final String text;

  final IconData icon;

  final Widget? action;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
          if (action != null) ...<Widget>[
            const SizedBox(width: 8),
            action!,
          ],
        ],
      ),
    );
  }
}

/// 分段小标题（组标题的旧形态）。
///
/// 新代码优先用 [SettingsGroup] 自带标题；[SettingsGroup] 还装不下的老页面
/// （例如一个分类里还有别的手工排版块）继续用它，保证字号/颜色/间距一致。
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({super.key, required this.title, this.icon});

  final String title;

  /// 标题前的图标（与 [SettingsGroup.title] 同口径，可选）。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
