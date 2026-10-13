import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../providers/settings_providers.dart';

/// 设置 → 外观。
///
/// 主题与语言两行，各自一个下拉。都是**即时生效**的：改主题不改数据、
/// 改语言不改数据，两者都是「选完当场看见结果」的那一类，所以没有保存按钮。
class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.only(bottom: 32),
    children: const <Widget>[
      _ThemeTile(),
      _LanguageTile(),
    ],
  );
}

class _ThemeTile extends ConsumerWidget {
  const _ThemeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final mode = ref.watch(themeModeProvider);
    return ListTile(
      leading: const Icon(Icons.brightness_6_outlined),
      title: Text(l10n.theme),
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
    return ListTile(
      leading: const Icon(Icons.translate),
      title: Text(l10n.language),
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
