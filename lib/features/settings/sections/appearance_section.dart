import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/settings_providers.dart';

/// 设置 → 外观。
///
/// 主题与语言两行，各自一个下拉。都是**即时生效**的：改主题不改数据、
/// 改语言不改数据，两者都是「选完当场看见结果」的那一类，所以没有保存按钮。
///
/// 版面走设置页的统一积木：一张 [SettingsGroup] 卡片装这两行（行间分隔线由
/// 它画），行本身用 [SettingsTile] —— 图标 / 标题 / 尾部下拉同一套尺寸与
/// 间距，与其他分类页一眼能对上。
///
/// ## 主题画廊（扩展提供时才出现）
///
/// 扩展注册表里有 [ThemePack] 时，在下面再铺一块「主题配色」：每套一张卡，
/// 卡里并排画亮 / 暗两个缩影，点一张立刻生效（并写进 prefs）。注册表为空
/// （公开版）时这块**完全不出现** —— 这页与接缝出现之前逐字一致。
class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final packs = ref.watch(registeredThemePacksProvider);
    return SettingsPage(
      children: <Widget>[
        SettingsGroup(
          title: l10n.appearance,
          icon: Icons.palette_outlined,
          children: const <Widget>[
            _ThemeTile(),
            _LanguageTile(),
          ],
        ),
        if (packs.isNotEmpty) _ThemeGallery(packs: packs),
      ],
    );
  }
}

class _ThemeTile extends ConsumerWidget {
  const _ThemeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final mode = ref.watch(themeModeProvider);
    return SettingsTile(
      icon: Icons.brightness_6_outlined,
      title: l10n.theme,
      trailing: DropdownButton<ThemeMode>(
        value: mode,
        underline: const SizedBox.shrink(),
        onChanged: (next) {
          if (next == null) return;
          ref.read(themeModeProvider.notifier).set(next);
        },
        items: <DropdownMenuItem<ThemeMode>>[
          DropdownMenuItem(
            value: ThemeMode.system,
            child: Text(l10n.themeSystem),
          ),
          DropdownMenuItem(
            value: ThemeMode.light,
            child: Text(l10n.themeLight),
          ),
          DropdownMenuItem(
            value: ThemeMode.dark,
            child: Text(l10n.themeDark),
          ),
        ],
      ),
    );
  }
}

class _LanguageTile extends ConsumerWidget {
  const _LanguageTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final locale = ref.watch(localeProvider);
    return SettingsTile(
      icon: Icons.translate,
      title: l10n.language,
      trailing: DropdownButton<String>(
        value: locale?.languageCode ?? 'system',
        underline: const SizedBox.shrink(),
        onChanged: (next) {
          ref
              .read(localeProvider.notifier)
              .set(next == null || next == 'system' ? null : next);
        },
        items: <DropdownMenuItem<String>>[
          DropdownMenuItem(
            value: 'system',
            child: Text(l10n.languageSystem),
          ),
          const DropdownMenuItem<String>(value: 'zh', child: Text('简体中文')),
          const DropdownMenuItem<String>(value: 'en', child: Text('English')),
        ],
      ),
    );
  }
}

/// 「主题配色」画廊：内置默认主题 + 扩展提供的每一套。
///
/// 卡片是**纯色块缩影**，不截图也不讲故事 —— 一张卡里就能看出这套主题的
/// 表面色、文字色、主色与强调色，比文字描述准得多。
class _ThemeGallery extends ConsumerWidget {
  const _ThemeGallery({required this.packs});

  final List<ThemePack> packs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context);
    final selectedId = ref.watch(themePackProvider);

    final entries = <_GalleryEntry>[
      _GalleryEntry(
        id: null,
        name: l10n.themeDefault,
        family: '',
        light: AppTheme.light(),
        dark: AppTheme.dark(),
      ),
      for (final pack in packs)
        _GalleryEntry(
          id: pack.id,
          name: pack.name(locale),
          family: pack.family(locale),
          light: pack.build(Brightness.light),
          dark: pack.build(Brightness.dark),
        ),
    ];

    return SettingsGroup(
      title: l10n.themeGalleryTitle,
      icon: Icons.auto_awesome_outlined,
      description: l10n.themeGalleryHint,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 760 的正文宽里三列刚好；窄屏（手机、窄窗）退到两列，
              // 再窄就单列 —— 缩影本身有最小可读宽度，硬塞三列会糊成一团。
              final maxWidth = constraints.maxWidth;
              final columns = maxWidth >= 560 ? 3 : (maxWidth >= 340 ? 2 : 1);
              const spacing = 12.0;
              final width = (maxWidth - spacing * (columns - 1)) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: <Widget>[
                  for (final entry in entries)
                    SizedBox(
                      width: width,
                      child: _ThemeCard(
                        entry: entry,
                        selected: entry.id == selectedId,
                        onTap: () => ref
                            .read(themePackProvider.notifier)
                            .set(entry.id),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 画廊里的一张卡：亮 / 暗两个缩影 + 名字 + 分组 + 选中态。
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final _GalleryEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: entry.name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: 0.7),
              width: selected ? 2 : 1,
            ),
            color: selected
                ? scheme.primary.withValues(alpha: 0.04)
                : Colors.transparent,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: _MiniShell(theme: entry.light)),
                  const SizedBox(width: 6),
                  Expanded(child: _MiniShell(theme: entry.dark)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge,
                        ),
                        if (entry.family.isNotEmpty)
                          Text(
                            entry.family,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle,
                      size: 16,
                      color: scheme.primary,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一套主题的缩影：侧栏一条 + 三行文字 + 主色按钮 + 强调点。
///
/// 用**这套主题自己的 `ThemeData`** 取色（不是当前界面的色），所以同一张卡里
/// 亮 / 暗、以及不同主题之间都是真颜色，不会受当前选中主题影响。
class _MiniShell extends StatelessWidget {
  const _MiniShell({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final bar = scheme.onSurface;
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: <Widget>[
          Container(width: 12, color: scheme.surfaceContainerHighest),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 7, 6, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _bar(bar, 0.72, 22),
                  const SizedBox(height: 4),
                  _bar(bar, 0.45, 30),
                  const Spacer(),
                  Row(
                    children: <Widget>[
                      Container(
                        width: 10,
                        height: 6,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: scheme.tertiary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: 14,
                        height: 6,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar(Color color, double alpha, double width) => Container(
        width: width,
        height: 3,
        decoration: BoxDecoration(
          color: color.withValues(alpha: alpha),
          borderRadius: BorderRadius.circular(2),
        ),
      );
}

/// 画廊里一格的数据（内置默认主题的 `id` 是 null）。
class _GalleryEntry {
  const _GalleryEntry({
    required this.id,
    required this.name,
    required this.family,
    required this.light,
    required this.dark,
  });

  final String? id;
  final String name;
  final String family;
  final ThemeData light;
  final ThemeData dark;
}
