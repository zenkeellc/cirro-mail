import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_defaults.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/notification_providers.dart';
import '../../../providers/settings_providers.dart';
import '../../../providers/sync_providers.dart';
import '../../notifications/background_sync_task.dart';
import '../settings_widgets.dart';

/// 设置 → 轮询。
///
/// 「多久检查一次新邮件」+「发送延迟」+「预取正文」+「通知」四块。
///
/// **「后台推送」不在这里** —— 它以前是这一组里的一条 `ListTile`，点开整页
/// push 进 `/settings/push`。现在推送自己有分类（`PushSection` 那个位置），
/// 两条入口讲同一件事只会让人不知道该点哪个。
///
/// 版面按「这件事发生在什么时候」分成三张卡片：
///
/// - **轮询**：多久收一次、收的时候要不要顺带拉正文（收信这件事本身）；
/// - **发送**：点发送之后还能反悔多久（发信这件事）；
/// - **通知**：收不信要不要打扰你（两种开关，横幅那个只在能弹通知时才出现）。
///
/// 行间分隔线由 [SettingsGroup] 画，调用方不再手写 `Divider`。
class PollingSection extends ConsumerWidget {
  const PollingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // 横幅开关只在「收信开着」且「平台真的能弹通知」时才有意义 —— 判断放在
    // 这里，是为了让它和上面那个开关成为**同一张卡片里各自独立的一行**
    // （分隔线由 `SettingsGroup` 画），而不是挤在一个 Column 里。
    final notifyOn = ref.watch(notifyEnabledProvider);
    final service = ref.watch(notificationServiceProvider);
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
        SettingsGroup(
          title: l10n.send,
          icon: Icons.send_outlined,
          children: const <Widget>[_SendDelayTiles()],
        ),
        SettingsGroup(
          title: l10n.notifications,
          icon: Icons.notifications_outlined,
          children: <Widget>[
            const _NotifyEnabledTile(),
            // 平台不支持本地通知（初始化失败）时，把子开关藏掉而不是留一个
            // 点了没反应的开关 —— 后者会让人以为是自己没配对。
            if (notifyOn && service.isSupported) const _NotifyBannerTile(),
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

/// 「发送延迟」：点发送之后还能反悔多久（需求六）。
///
/// 做成下拉档位而不是滑块：可选值是**离散的几档**（立刻 / 1 / 3 / 5 分钟），
/// 滑块能拖出来的 47 秒没有任何意义，还会让用户以为精度很重要。
/// 与 [_PollIntervalTile] 一样用 `DropdownButton`，视觉上不引入新控件。
class _SendDelayTiles extends ConsumerWidget {
  const _SendDelayTiles();

  static const List<int> _seconds = <int>[0, 60, 180, 300];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(sendDelayProvider).inSeconds;
    return SettingsTile(
      icon: Icons.schedule_send_outlined,
      title: l10n.sendDelay,
      subtitle: l10n.sendDelayHint,
      trailing: DropdownButton<int>(
        value: _nearest(value),
        underline: const SizedBox.shrink(),
        onChanged: (seconds) {
          if (seconds == null) return;
          ref.read(sendDelayProvider.notifier).set(Duration(seconds: seconds));
        },
        items: <DropdownMenuItem<int>>[
          for (final seconds in _seconds)
            DropdownMenuItem<int>(
              value: seconds,
              child: Text(
                seconds == 0
                    ? l10n.sendDelayNone
                    : l10n.sendDelayMinutes(seconds ~/ 60),
              ),
            ),
        ],
      ),
    );
  }

  /// 存过的值可能不在档位里（手改 prefs / 旧版本），取最接近的一档当显示值，
  /// 否则 `DropdownButton` 会因为 value 不在 items 里直接抛断言。
  static int _nearest(int seconds) {
    var best = _seconds.first;
    for (final candidate in _seconds) {
      if ((candidate - seconds).abs() < (best - seconds).abs()) best = candidate;
    }
    return best;
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

/// 「收信 / 提醒」总开关。
///
/// 它关掉的是**收信本身**（`SyncController.pause()`），不只是提醒 —— 文案
/// 说的是「已收到的邮件仍可正常阅读」，就是这件事。
class _NotifyEnabledTile extends ConsumerWidget {
  const _NotifyEnabledTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(notifyEnabledProvider);
    final service = ref.watch(notificationServiceProvider);
    return SwitchListTile(
      secondary: const Icon(Icons.notifications_outlined, size: 20),
      title: Text(l10n.notifications),
      // 说实话：这个开关关掉的是**收信本身**（`SyncController.pause()`），
      // 不只是提醒。要「别打扰我」用下面那个。
      subtitle: Text(l10n.notifyEnabledHint),
      value: value,
      onChanged: (next) {
        ref.read(notifyEnabledProvider.notifier).set(next);
        final controller = ref.read(syncControllerProvider.notifier);
        if (next) {
          controller.resume();
          // 用户主动要通知 —— 这是最适合要权限的时刻：他刚在这个开关上
          // 表达了意图。冷启动就弹框只会被顺手点掉，之后再想要这个功能
          // 就得去系统设置里翻。
          unawaited(service.ensurePermission());
        } else {
          controller.pause();
        }
        // 后台兜底任务跟着这个开关走：关掉还留着周期任务，系统每 15 分钟
        // 叫醒一次、每次都因为 `notifyEnabled == false` 立刻返回 ——
        // 用户看不到任何东西，但电池和唤醒次数是被真真切切扣掉的。
        //
        // 这里 fire-and-forget：注册是平台调用，不该让开关的 UI 等它。
        if (next) {
          unawaited(BackgroundSyncTask.register());
        } else {
          unawaited(BackgroundSyncTask.cancel());
        }
      },
    );
  }
}

/// 应用内横幅提醒：只在总开关开着、且这个平台真的能弹通知时才出现。
class _NotifyBannerTile extends ConsumerWidget {
  const _NotifyBannerTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return SwitchListTile(
      secondary: const Icon(Icons.chat_bubble_outline, size: 20),
      title: Text(l10n.notifyBanner),
      subtitle: Text(l10n.notifyBannerHint),
      value: ref.watch(notifyBannerProvider),
      onChanged: (next) => ref.read(notifyBannerProvider.notifier).set(next),
    );
  }
}
