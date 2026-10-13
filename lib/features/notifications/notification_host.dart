import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/window_channel.dart';
import '../../data/models/enums.dart';
import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/notification_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/settings_providers.dart';
import '../../providers/sync_providers.dart';
import '../../router.dart' as app_router;
import 'background_sync_task.dart';
import 'push_service.dart';

/// 把「本地通知」接到 App 上的那一层。
///
/// 挂在 `MaterialApp.router` **里面**（需要 `AppLocalizations` 和 router），
/// 但它本身不画任何东西 —— 只做三件事：
/// 1. 把当前语言包推给 [NotificationService]（通知文案在 UI 之外生成）；
/// 2. 订阅 `newMailProvider`，把「本轮新到的信」交给它去弹；
/// 3. 接住「点了通知」这件事，导航到那封邮件。
///
/// 这三件事都**不能**放在 `NotificationService` 自己身上：它需要
/// `AppLocalizations`、router 和 Riverpod 的 `ref`，而它必须能在
/// 没有 widget 树的地方被构造（例如单测）。
class NotificationHost extends ConsumerStatefulWidget {
  const NotificationHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NotificationHost> createState() => _NotificationHostState();
}

class _NotificationHostState extends ConsumerState<NotificationHost> {
  bool _pushWired = false;

  @override
  void initState() {
    super.initState();
    final service = ref.read(notificationServiceProvider);
    // 先挂 handler 再 init：冷启动那一路，`init()` 里就会拿到点击事件，
    // 那时如果还没有 handler，事件会被攒起来，等这里挂上之后再补送。
    service.attachOpenHandler(_openFromNotification);
    unawaited(service.init());

    // 「稍后提醒」在 Linux 上只能靠心跳兜底（那边 `zonedSchedule` 没实现，
    // 插件直接抛 `UnimplementedError`）。把 ticker 接到调度器的慢活上，
    // 再立刻补一次 —— 关着 App 的那段时间里到点的，不该等到 20 秒后才发现。
    //
    // **只 Linux 挂**：其余平台有真的系统排期，多一条轮询是每 20 秒白查一次库。
    if (defaultTargetPlatform == TargetPlatform.linux) {
      final ticker = ref.read(reminderTickerProvider);
      ref.read(syncSchedulerProvider).onSlowTick = ticker.onHeartbeat;
      unawaited(ticker.run());
    }

    // FCM 那条链路是**懒接**的：只在用户已经填好中转配置时才碰 Firebase。
    // 没配的用户（以及 Linux/Windows 这些没有 FCM 实现的平台 —— 注释里
    // 曾经把 macOS 也算进去，那在 `firebase_messaging` 16.x 之后是错的）
    // 连 `Firebase.initializeApp()` 都不会调 —— 那一步在没有配置文件时
    // 会抛，冷启动每台设备打一串异常没有任何意义。
    unawaited(_wirePush());

    // 后台兜底轮询（目前只有 Android 有）。它和 FCM 是**互补**的：
    // 推送负责「快」，这个负责「没配推送也能收到」。用户关掉了
    // 「后台轮询与通知」时不注册 —— 那个开关的语义就是「别在后台动我的东西」。
    if (ref.read(notifyEnabledProvider)) {
      unawaited(BackgroundSyncTask.register());
    } else {
      unawaited(BackgroundSyncTask.cancel());
    }
  }

  /// 接上 FCM：拿 token、挂监听、把冷启动那条深链也接过来。
  Future<void> _wirePush() async {
    if (_pushWired) return;
    final push = ref.read(pushServiceProvider);
    if (!push.isConfigured || !push.enabled) return;
    _pushWired = true;

    // 老版本存下来的设备号是**裸 UUID**，中转端对那种值一律 401（它的
    // 硬校验是 `deviceId.startsWith('<instanceId>-')`）。这条路径正是
    // 那个 bug 唯一会发作的地方 —— 用户不一定会打开设置页，而这里每次
    // 冷启动都会跑。修一次就够，之后是幂等的空操作。
    await push.ensureDeviceId();

    if (!await push.initialize()) return;
    await push.attachListeners(
      onOpen: (event) => _openFromPush(event),
    );
    // token 可能刚被轮换过，顺手把登记刷新一遍（幂等）。
    unawaited(push.syncAll(reason: '启动'));
  }

  /// 用户点了系统通知栏里的推送 —— 和点本地通知是同一件事。
  void _openFromPush(PushMailEvent event) {
    if (!mounted) return;
    final mailRef = event.ref;
    if (mailRef == null) {
      // 认不出实例：至少把当前实例拉一轮，别让用户点了没反应。
      // 桌面端还得先把窗口叫起来（macOS 是菜单栏、Windows 是托盘），否则用户
      // 点完通知屏幕上依然什么都没有 ——「拉了一轮」是看不见的。
      // 见 [WindowChannel.show]。
      unawaited(WindowChannel.show());
      unawaited(ref.read(syncSchedulerProvider).refreshNow());
      return;
    }
    _openFromNotification(mailRef);
  }

  @override
  Widget build(BuildContext context) {
    // 推送文案用的语言包。放在 build 里是为了跟 `localeProvider` 的切换同步 ——
    // 用户切了语言，下一条通知就该是新语言的。这个赋值没有副作用
    // （不触发重建），所以不需要挪到 post-frame。
    ref.read(notificationServiceProvider).attachL10n(
      AppLocalizations.of(context),
    );

    // 新邮件 → 弹通知。**这是通知链路的唯一入口** ——
    // `NewMailBus` 的语义是「本轮新写入的行」，首轮只用来建基线。
    ref.listen<AsyncValue<({String profileId, List<MailRow> mails})>>(
      newMailProvider,
      (previous, next) {
        final event = next.value;
        if (event == null) return;
        unawaited(_notify(event.profileId, event.mails));
      },
    );

    // 真·推送（FCM）：把「新邮件」这件事接进同一条通知链路。
    //
    // 两条来源（推送 / 轮询）**共用** `NotificationService` 的基线闸门，
    // 所以不需要在这里再去重：推送把游标推到 N 之后，轮询那一轮里
    // `emailId <= N` 的行就自动不再弹了（反过来也一样）。这正是
    // `NotificationGate` 被设计成有状态的原因之一。
    //
    // 这里**不补拉邮件**：拉数据是 `SyncEngine` 的事，而推送的意义就是
    // 「立刻去拉一轮」。等它的结果回来，上面那个 newMail 监听会照常弹通知。
    ref.listen<AsyncValue<PushMailEvent>>(
      pushMailEventProvider,
      (previous, next) {
        final event = next.value;
        if (event == null) return;
        unawaited(_onPush(event));
      },
    );

    // 后台那条路（App 不在前台时收到的推送）落到同一个 [_onPush]。
    // 两条流的差别只在于「谁把消息送来的」，处理方式一模一样：立刻同步
    // 那个实例。开关窗都成立 —— 窗口关掉**不等于**进程退出（见
    // `macos/Runner/AppDelegate.swift` 的 `applicationShouldTerminateAfterLastWindowClosed`），
    // 这个 widget 与各 provider 都还活着。
    ref.listen<AsyncValue<PushMailEvent>>(
      pushBackgroundEventProvider,
      (previous, next) {
        final event = next.value;
        if (event == null) return;
        unawaited(_onPush(event));
      },
    );

    return widget.child;
  }

  /// 收到推送：立刻同步那个实例（而不是在这里手搓一封 `MailRow`）。
  ///
  /// 为什么不直接照着推送的元数据弹一条通知：那样弹出来的通知点开会
  /// 落在一个本地根本不存在的 `emailId` 上，详情页只能靠翻页兜底去找 ——
  /// 而拉一轮的代价很小（一个 `/email/latest` 请求），换来的是列表、
  /// 未读角标、通知文案全部一致。
  Future<void> _onPush(PushMailEvent event) async {
    final scheduler = ref.read(syncSchedulerProvider);
    if (event.profileId.isEmpty) {
      // 认不出是哪个实例（比如配置里还没登记这个 instanceId）——
      // 全部拉一轮，总有一个会把它带回来。
      await scheduler.refreshNow();
      return;
    }
    await scheduler.refreshNow(profileId: event.profileId);
  }

  Future<void> _notify(String profileId, List<MailRow> mails) async {
    final service = ref.read(notificationServiceProvider);
    // **无论如何都要过一遍闸门**，哪怕这次不显示 —— 闸门同时负责推进基线。
    // 关掉横幅这一周里攒下的邮件，不该在重新打开的那一刻被当成新的弹出来。
    final display =
        ref.read(notifyEnabledProvider) && ref.read(notifyBannerProvider);
    await service.showFor(
      profileId: profileId,
      rows: mails,
      display: display,
      // 实例名现取而不是缓存：用户可能刚在设置里改过备注名，
      // 而这条信就是改名之后到的。
      profileName: ref.read(profileByIdProvider(profileId))?.displayName,
    );
  }

  /// 用户点了通知。
  ///
  /// 只做「导航到那封邮件的详情页」这一件事，**不在这里补拉数据**：
  /// 详情页自己知道本地没有这封时该怎么往回翻页找（`_openOnce` →
  /// `EmailRepository.locateAcrossPages`），在这里再做一遍就有了两处
  /// 互相不知道对方存在的兜底逻辑。
  void _openFromNotification(MailRef mailRef) {
    if (!mounted) return;
    // 桌面端「关窗后留在菜单栏/托盘」：窗口可能是关着的，先把外壳叫起来。
    // 这条和 `_openFromPush` 里那一处是同一件事的两条路 —— 点了通知、
    // 或者点 Dock/Cmd-Tab/托盘图标回来，都不能让用户对着空屏幕。**不 await**：
    // 导航本身不依赖窗口已经回来（引擎照样在渲染），等它反而会把跳转推迟
    // 一帧；通道那侧失败也是静默的（见 [WindowChannel.show]）。
    unawaited(WindowChannel.show());
    // 先把这一条通知撤掉：用户已经点进来了，通知栏里那条就过期了
    // （否则点开看完，通知还挂在那儿，会让人以为又来了新信）。
    unawaited(ref.read(notificationServiceProvider).cancelFor(mailRef));

    ref.read(app_router.routerProvider).go(
          app_router.detailRouteOf(
            // 路径段用聚合节点、实例走 `profile=`：通知点开落的是 App 的
            // **默认列表**（`/mail/all` 收件箱），侧栏也就停在「收件箱」上。
            // 用真实实例当节点的话，那一段对不上任何入口，整列高亮会消失
            // （见 `detailRouteOf` 的注释）。
            node: app_router.Routes.kAggregateNode,
            profileId: mailRef.profileId,
            emailId: mailRef.emailId,
            // 通知只会为 `type=receive` 的行弹出（见 `NotificationGate`），
            // 所以这里恒是收件方向。用错文件夹会让地址被算成另一个入口。
            folder: MailFolder.receive,
          ),
        );
  }
}
