import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/notifications/notification_service.dart';
import '../features/notifications/push_service.dart';
import '../features/notifications/reminder_ticker.dart';
import 'core_providers.dart';

/// 前台收到的推送事件。
///
/// 从 `PushService.foreground` 转成 provider，是为了让 UI 那一侧（
/// `NotificationHost`）用 `ref.listen` 统一消费 —— 它已经这样听着
/// `newMailProvider`，再加一条流式监听比在这里另开一个订阅点更一致。
final StreamProvider<PushMailEvent> pushMailEventProvider =
    StreamProvider<PushMailEvent>(
  (ref) => ref.watch(pushServiceProvider).foreground,
  name: 'pushMailEvent',
);

/// **不在前台**时收到的推送事件。
///
/// 与 [pushMailEventProvider] 平行、**刻意不合并**：两条流走的是不同的
/// 平台通道（`Messaging#onMessage` / `Messaging#onBackgroundMessage`），
/// 合起来之后日志里就再也分不出「前台推送」和「后台推送」了 —— 而这恰好
/// 是排查「后台到底有没有被叫醒」时唯一要看的东西。
///
/// 消费方（`NotificationHost`）对两者的处理完全相同：都去触发一轮同步。
final StreamProvider<PushMailEvent> pushBackgroundEventProvider =
    StreamProvider<PushMailEvent>(
  (ref) => ref.watch(pushServiceProvider).background,
  name: 'pushBackgroundEvent',
);

/// 本地通知服务，全局唯一。
///
/// 不做自动释放：它持有一份「每个实例弹过哪些」的内存基线，
/// 被回收一次就等于「重新装了一遍 App」—— 下一次同步会把整页
/// 旧邮件当成新的弹出来。
final Provider<NotificationService> notificationServiceProvider =
    Provider<NotificationService>(
  (ref) => NotificationService(),
  name: 'notificationService',
);

/// 真·后台推送（FCM + `mail-push` 中转），全局唯一。
///
/// 与 [notificationServiceProvider] 的关系：这个负责「信到了，把 App 叫醒
/// 或记一笔」，那个负责「在通知栏里画出来」。两者都活着的时候，同一封信
/// 会被推送和轮询各看到一次 —— 去重靠 [NotificationService] 的基线闸门
/// （它按 `(profileId, emailId)` 推进游标），所以这里不需要再做一层。
final Provider<PushService> pushServiceProvider = Provider<PushService>(
  (ref) {
    final db = ref.watch(databaseProvider);
    return PushService(
      prefs: ref.watch(prefsStoreProvider),
      tokens: ref.watch(tokenStoreProvider),
      // 直连 dao 而不是走 `profilesProvider`：那是个 AsyncNotifier，
      // 在 provider 构造时读它会把「实例列表加载中」这个状态引进来，
      // 而这里要的只是「现在库里有谁」。
      readProfiles: () => db.profileDao.allProfiles(),
      readMailboxes: (profileId) => db.profileDao.mailboxesOf(profileId),
    );
  },
  name: 'pushService',
);

/// 推送配置是否可用（三条值填全 + 平台支持）。
///
/// 单独抽一个 provider 是为了让设置页与诊断页**同一口径**地判断 ——
/// 「有没有推送」在代码里有三处会问，三处各写一遍迟早会漂。
final Provider<bool> pushConfiguredProvider = Provider<bool>(
  (ref) => ref.watch(pushServiceProvider).isConfigured,
  name: 'pushConfigured',
);

/// 稍后提醒的**降级路**（只 Linux 用，spec §7.6）。
///
/// 只在 Linux 上挂到心跳上：其余平台由 `NotificationService.scheduleReminder`
/// 交给系统排期，再挂一条轮询就是每 20 秒白查一次库。
final Provider<ReminderTicker> reminderTickerProvider =
    Provider<ReminderTicker>(
  (ref) => ReminderTicker(
    dao: ref.watch(databaseProvider).reminderDao,
    show: (reminder) => ref.read(notificationServiceProvider).showReminderNow(
      profileId: reminder.profileId,
      emailId: reminder.emailId,
      subject: reminder.subject,
      sender: reminder.sender,
    ),
  ),
  name: 'reminderTicker',
);
