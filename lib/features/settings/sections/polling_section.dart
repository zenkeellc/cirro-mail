import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_defaults.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/settings_providers.dart';
import '../settings_widgets.dart';

/// 设置 → 收信。
///
/// **只有一件半事**：多久检查一次新邮件、检查的时候要不要顺带把正文拉下来。
///
/// 以前这一页还装着「发送延迟」和两张提醒开关，三件事各自住在别的分类里更
/// 顺：发送延迟是**写信的收尾**（见 `compose_section.dart` 的「发送」组），
/// 提醒开关是「新邮件到了要不要打扰我」那一整页的起点（见
/// `notifications_section.dart`）。挤在叫「收信」的页面里，用户想撤销发送
/// 不会来这里找，想关提醒也得先猜它藏在收信里。
///
/// 行间分隔线由 [SettingsGroup] 画，调用方不再手写 `Divider`。
class PollingSection extends ConsumerWidget {
  const PollingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return SettingsPage(
      children: <Widget>[
        SettingsGroup(
          title: l10n.polling,
          icon: Icons.sync_outlined,
          children: const <Widget>[
            _PollIntervalTile(),
            _PrefetchTile(),
          ],
        ),
      ],
    );
  }
}

/// 「多久检查一次新邮件」。
///
/// 只有一行：以前这里是「活跃实例 / 其他实例」两行，但两行回答的是同一个
/// 问题，用户每台机器都要调两遍。合成一行之后，档位来自
/// [AppDefaults.pollChoices]（1 分钟 … 1 小时），默认 5 分钟。
///
/// 与 [_SendDelayTiles] 一样用 `DropdownButton` 而不是滑块或输入框：离散
/// 档位，滑块能拖出来的 47 分钟没有意义。
class _PollIntervalTile extends ConsumerWidget {
  const _PollIntervalTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // 显示值过一道 `nearestPollChoice`：存过的值（旧版本的 30 秒 / 10 分钟、
    // 或手改过 prefs）可能不在档位里，而 `DropdownButton` 的 value 不在
    // items 里会直接抛断言。
    final current =
        AppDefaults.nearestPollChoice(ref.watch(pollIntervalProvider));
    return SettingsTile(
      icon: Icons.schedule_outlined,
      title: l10n.pollInterval,
      subtitle: l10n.pollIntervalHint,
      trailing: DropdownButton<Duration>(
        value: current,
        underline: const SizedBox.shrink(),
        onChanged: (value) {
          if (value == null) return;
          ref.read(pollIntervalProvider.notifier).set(value);
        },
        items: <DropdownMenuItem<Duration>>[
          for (final choice in AppDefaults.pollChoices)
            DropdownMenuItem<Duration>(
              value: choice,
              child: Text(l10n.minutesCount(choice.inMinutes)),
            ),
        ],
      ),
    );
  }
}

class _PrefetchTile extends ConsumerWidget {
  const _PrefetchTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(prefetchFullProvider);
    return SwitchListTile(
      secondary: const Icon(Icons.download_for_offline_outlined, size: 20),
      title: Text(l10n.prefetchTitle),
      subtitle: Text(l10n.prefetchHint),
      value: value,
      onChanged: (next) => ref.read(prefetchFullProvider.notifier).set(next),
    );
  }
}
