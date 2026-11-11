import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../providers/notification_providers.dart';
import '../../../providers/settings_providers.dart';
import '../../../providers/sync_providers.dart';
import '../../notifications/background_sync_task.dart';

/// 设置 → 通知。
///
/// 「新邮件到了，要不要打扰我」只有这一个入口。以前它散在**三个地方**：
///
/// - 「收信」页里的两张开关（应用内横幅 / 提醒总开关）；
/// - 独占一栏的「推送」（App 不在时靠中转把提醒送到手机）；
/// - 商业版独占一栏的「免打扰」（哪些发件人 / 域名不弹）。
///
/// 三处回答的是同一个问题，用户却得先猜「我这一条在哪个分类里」。现在合成
/// 一页，按**提醒从近到远**铺开：
///
/// 1. **应用内提醒**：App 就在眼前时的弹窗与横幅（开关本身也管收信）；
/// 2. **后台推送**：App 退到后台 / 被冻结时的中转提醒 —— 点进去是配置向导
///    （公开版的七页向导，商业版换成托管面板，见 [AppExtension.pushSettings]）；
/// 3. 扩展加进来的提醒规则（[AppExtension.notificationExtras]）—— 商业版的
///    「免打扰」就铺在这里，它属于同一个问题的第三层：「哪些邮件别提醒我」。
///
/// ## 为什么后台推送是**子页**而不是再占一栏
///
/// 向导有七步、自己带进度条与翻页条，塞不进这一页的卡片流；但它也不是一件
/// 独立的事 —— 它只是这一页第二组的**细**。做成子页之后分类栏少一栏，
/// 而「找推送」的路径反而更短了：以前要在一列里辨认「推送」和「通知」哪个
/// 才是自己要的，现在只有一个「通知」。
///
/// 外壳（`AppBar` / 分类栏 / 窄屏那一页）出在 `SettingsScreen` —— 这里只出
/// 内容，因此返回 `SettingsPage` 而不是 `Scaffold`。
class NotificationsSection extends ConsumerWidget {
  const NotificationsSection({super.key, required this.onOpenPush});

  /// 点「后台推送」那一行。宿主据此把子页顶上来（子页状态归宿主，与
  /// 「实例 → 添加实例」那张表单同一个理由：窄屏的返回箭头要分得清
  /// 「退子页」与「退分类」）。
  final VoidCallback onOpenPush;

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
          title: l10n.notificationsInApp,
          icon: Icons.notifications_outlined,
          children: <Widget>[
            const _NotifyEnabledTile(),
            // 平台不支持本地通知（初始化失败）时，把子开关藏掉而不是留一个
            // 点了没反应的开关 —— 后者会让人以为是自己没配对。
            if (notifyOn && service.isSupported) const _NotifyBannerTile(),
          ],
        ),
        SettingsGroup(
          title: l10n.notificationsPush,
          icon: Icons.notifications_active_outlined,
          children: <Widget>[
            SettingsTile(
              icon: Icons.settings_remote_outlined,
              title: l10n.pushTitle,
              subtitle: l10n.pushHint,
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: onOpenPush,
            ),
          ],
        ),
        // 扩展的提醒规则（商业版的「免打扰」）。空注册表时这里什么都不多 ——
        // 公开版逐字不变。
        ...AppExtensionRegistry.instance.notificationExtras(context),
      ],
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
