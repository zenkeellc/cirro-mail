import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../providers/settings_providers.dart';
import '../settings_widgets.dart';

/// 设置 → 外观。
///
/// 主题与语言两行，各自一个下拉。都是**即时生效**的：改主题不改数据、
/// 改语言不改数据，两者都是「选完当场看见结果」的那一类，所以没有保存按钮。
///
/// 版面走设置页的统一积木：一张 [SettingsGroup] 卡片装这两行（行间分隔线由
/// 它画），行本身用 [SettingsTile] —— 图标 / 标题 / 尾部下拉同一套尺寸与
/// 间距，与其他分类页一眼能对上。
class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
