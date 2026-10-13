import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/db/database.dart';
import '../../core/network/auth_events.dart';
import '../../core/storage/prefs_store.dart';
import '../../core/storage/token_store.dart';
import '../../data/models/enums.dart';
import '../../data/models/mail_row.dart';
import '../../data/models/profile.dart';
import '../../data/repositories/account_repository.dart';
import '../../data/repositories/capability_repository.dart';
import '../../data/repositories/email_repository.dart';
import '../../data/repositories/profile_repository.dart';
import '../../instance/runtime_registry.dart';
import '../../instance/sync_engine.dart';
import '../../l10n/app_localizations.dart';
import 'notification_service.dart';

/// 后台兜底同步（Android 的 `workmanager`）。
///
/// ## 它解决的是哪个问题
///
/// App 退到后台、或被系统冻结之后，进程内的 `SyncScheduler` 就不再跑了。
/// 这时候唯一还能把「有新邮件」送到用户眼前的路有两条：
///
/// 1. **FCM 真推送**（`PushService` + `mail-push` 中转）—— 快，但依赖用户
///    自己去 Firebase 建项目、往实例后台填 webhook，不是每台设备都有；
/// 2. **这里的兜底轮询** —— 慢（Android 的周期任务最快 15 分钟一次），
///    但**零配置**：只要 App 装上了、有已登录的实例，它就能跑。
///
/// 两者不冲突：推送那条路会 `scheduler.refreshNow()`，轮询这条路本来就在拉，
/// 最终都汇进 `NotificationGate` 那一个基线闸门，同一封信不会弹两次。
///
/// ## 为什么只能在后台 isolate 里另起一套依赖
///
/// 后台任务跑在一个**新的 Flutter 引擎**里（`BackgroundWorker.kt` 建的），
/// 那里没有 `ProviderScope`，`ref.read(...)` 一个都拿不到。所以这里把
/// `bootstrap()` 干的事重做一遍：开库、建 `TokenStore`/`PrefsStore`、
/// 手工拼出仓储与 `SyncEngine`。多出来的这几十行是「不能用 Riverpod」
/// 的直接代价。
///
/// 插件本身是可用的 —— `BackgroundWorker` 建引擎时 `FlutterEngine` 会顺着
/// `flutterEmbedding=2` 这个 meta-data 自动跑 `GeneratedPluginRegistrant`，
/// 所以 shared_preferences / flutter_secure_storage / sqflite /
/// flutter_local_notifications 在这个 isolate 里都注册好了。
///
/// ## 平台边界
///
/// **只在 Android 上注册**。三个理由，缺一不可：
/// - `workmanager` 的 Windows 实现根本不存在（`_PlaceholderImplementation`
///   会抛 `UnimplementedError`），Linux 走的是 systemd 用户单元、语义完全不同；
/// - iOS 上它是**机会式**调度 —— 系统只在它高兴的时候跑一次，用户强杀 App
///   之后一次都不跑，靠它保证「一定收到提醒」是自欺欺人；iOS 的正路是 APNs；
/// - macOS 虽然能注册，但桌面 App 关掉窗口后进程本来就还在（`SyncController`
///   对桌面刻意不停调度器），再加一个后台任务只会重复拉同一批邮件。
///
/// 也就是说：这个文件是 Android 专用兜底，别把它当成「五平台通用后台同步」。
class BackgroundSyncTask {
  const BackgroundSyncTask._();

  /// 唯一名。改它等于换一个任务 —— 已经排进 WorkManager 的旧任务会
  /// 一直留在系统里跑到自己被取消为止。
  static const String uniqueName = 'cloudmail.periodicSync';

  /// `taskName` 会原样交给 `callbackDispatcher`。
  static const String taskName = 'cloudmail.sync';

  /// 周期任务的间隔。
  ///
  /// **15 分钟是 Android WorkManager 的硬下限**，写比它更小的值不会更快，
  /// 只会有两种结果：要么注册失败，要么系统把它当「你其实想要一次性任务」。
  /// 所以这里的常量不是「我们挑的间隔」，而是「平台允许的最小值」。
  static const Duration frequency = Duration(minutes: 15);

  /// 只在 Android 上注册。
  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android;
  }

  /// `initialize` 的结果。**只做一次**。
  ///
  /// 它把 [backgroundSyncCallbackDispatcher] 的函数句柄写进平台侧
  /// （`PluginUtilities.getCallbackHandle`），后台引擎就是靠这个句柄找回入口。
  /// 攒成一个 Future 是为了让 [register] 能等它落定 —— 句柄没登记好就注册，
  /// 会出现「任务排上了，跑起来却找不到入口」这种最难查的状态。
  static Future<void>? _entrypoint;

  static Future<void> _ensureEntrypoint() {
    if (!isSupported) return Future<void>.value();
    return _entrypoint ??= Workmanager().initialize(
      backgroundSyncCallbackDispatcher,
    );
  }

  /// 在 `main()` 里调，**早于 [register]**。
  static Future<void> bootstrap() => _ensureEntrypoint();

  /// 排上周期任务。**幂等**，每次 App 启动都会调一次。
  ///
  /// 用 [ExistingPeriodicWorkPolicy.update] 而不是 `keep`：任务的参数
  /// （间隔、约束）会随版本变化，`keep` 会让老设备一直跑着上一次装 App 时
  /// 的旧参数，而且永远不会被纠正。`update` 需要 WorkManager 2.8.0+，
  /// 由 `workmanager_android` 的传递依赖满足。
  static Future<void> register() async {
    if (!isSupported) return;
    try {
      await _ensureEntrypoint();
      await Workmanager().registerPeriodicTask(
        uniqueName,
        taskName,
        frequency: frequency,
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        // 断网时排进等待队列，恢复后系统自己跑 —— 比「到点了跑一次、
        // 失败、再等 15 分钟」省一整个周期。
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } catch (e) {
      // 注册失败不是致命错误：App 在前台时照常轮询，只是退到后台之后
      // 没有兜底。不抛，免得把一个「后台提醒不灵」的问题变成启动崩溃。
      debugPrint('后台同步：注册周期任务失败：$e');
    }
  }

  /// 撤掉周期任务（用户在设置里关掉「后台轮询与通知」时调用）。
  static Future<void> cancel() async {
    if (!isSupported) return;
    try {
      await Workmanager().cancelByUniqueName(uniqueName);
    } catch (e) {
      debugPrint('后台同步：取消周期任务失败：$e');
    }
  }

  /// 一批「本轮新写入的行」里，有多少封**值得提醒**。
  ///
  /// 与 `NotificationGate.select` 的过滤条件刻意保持一致（未读 + 收件方向）——
  /// 两边不一致的话，静默通知的数字会和正常横幅的内容对不上，
  /// 而用户是拿这两个当同一件事看的。抽出来单独放是为了能单测。
  @visibleForTesting
  static int countNotifiable(Iterable<MailRow> rows) => rows
      .where((row) => row.isUnread && row.type == MailType.receive)
      .length;
}

/// 后台 isolate 的入口。**必须是顶层函数**，`@pragma('vm:entry-point')`
/// 保证 AOT 编译不会把它当作未使用的代码摇掉。
///
/// 插件是拿 `callbackHandle` 存进 SharedPreferences、再由后台引擎反射调用的，
/// 静态分析看不出来它被引用过。
@pragma('vm:entry-point')
void backgroundSyncCallbackDispatcher() {
  Workmanager().executeTask((_, _) => _runBackgroundSync());
}

/// 跑一轮：开库 → 拉所有已登录实例 → 弹通知 → 关库。
///
/// 返回值直接决定 WorkManager 的调度结果（见 `BackgroundWorker.executeTask`：
/// true → `Result.success()`，false → `Result.retry()`）。所以**真正的失败**
/// （库打不开、prefs 读不到、某个实例拉不动）返回 false，让系统按退避重试；
/// 而「没有已登录实例」「用户关掉了开关」这种**没有活可干**的情况返回 true，
/// 不去无谓地唤醒下一次。
Future<bool> _runBackgroundSync() async {
  AppDatabase? db;
  AuthEvents? authEvents;
  RuntimeRegistry? registry;
  var ok = true;
  try {
    db = AppDatabase();
    // 首次打开会跑 migration 建表。这一步也顺便验证了库文件确实能读 ——
    // 后台 isolate 里没有 UI 可以展示错误，只能靠返回值让系统重试。
    await db.customSelect('SELECT 1').get();

    final prefs = await _openPrefs();
    if (prefs == null) return false;

    // 用户在设置里关掉了「后台轮询与通知」——后台当然也不该拉。
    if (!prefs.notifyEnabled) return true;

    final tokens = TokenStore();
    final profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);
    final loggedIn = (await profiles.all())
        .where((p) => p.isLoggedIn)
        .toList(growable: false);
    if (loggedIn.isEmpty) return true;

    authEvents = AuthEvents();
    registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      // 401 必须落库，理由与 `core_providers` 里那段注释完全相同：
      // 后台发现 token 废了、前台却还以为「已登录」，用户会卡在一个
      // 每次请求都 401 的收件箱里跳不出去。**这个回调比前台那份更要紧** ——
      // 后台正是最容易撞上「token 被别的设备挤掉」的地方。
      onAuthExpired: (id) => unawaited(profiles.markNeedsLogin(id)),
    );

    final capabilities = CapabilityRepository(db);
    final emails = EmailRepository(
      db: db,
      registry: registry,
      capabilities: capabilities,
      profiles: profiles,
      prefs: prefs,
    );
    final accounts = AccountRepository(
      db: db,
      registry: registry,
      capabilities: capabilities,
    );

    final fresh = <({String profileId, List<MailRow> rows})>[];

    // 一个实例一个实例地来。这里**没有**用 `SyncScheduler`：那个类一半的
    // 价值是「活跃/空闲两档间隔 + 1 秒心跳 + 各自退避」，而我们在后台只跑
    // 一次、跑完就死，那套时钟语义毫无意义；直接用 engine 跑一轮更直白。
    for (final profile in loggedIn) {
      try {
        final engine = SyncEngine(
          profile: profile,
          registry: registry,
          emails: emails,
          accounts: accounts,
          capabilities: capabilities,
          prefs: prefs,
          // 不用回调收集（下面拿返回值），但构造参数是必填的。
          onNewMail: (_, _) {},
        );
        await registry.ensureReady(profile);
        engine.start();
        // 「已发送」方向**刻意不拉**：那是列表首页比对、成本高得多，
        // 而后台这次唤醒唯一的目的就是「有没有新到的信」。用户在 App 里
        // 打开「已发送」时，前台那套调度器自然会补上。
        final rows = await engine.syncOnce();
        if (rows.isNotEmpty) {
          fresh.add((profileId: profile.id, rows: rows));
        }
      } catch (e) {
        // 一个实例挂掉不该拖累其他实例 —— 这是多实例下最基本的要求。
        debugPrint('后台同步：${profile.id} 失败：$e');
        ok = false;
      }
    }

    if (fresh.isNotEmpty) {
      await _announce(prefs, loggedIn, fresh);
    }

    return ok;
  } catch (e, st) {
    debugPrint('后台同步：整体失败：$e\n$st');
    return false;
  } finally {
    // 自己建的东西自己收 —— 后台 isolate 的寿命由系统决定，别指望
    // `dispose` 会被谁调用；不关的话两条 Dio 会一直挂在那儿。
    registry?.dispose();
    authEvents?.dispose();
    // **必须关**：`NativeDatabase.createBackgroundConnection` 会为这个库
    // 再起一个 drift 自己管理的 isolate。后台引擎被拆掉时如果连接还开着，
    // 就会留下一个「进程还在、Dart 侧已经没人认领」的库连接。
    await db?.close();
  }
}

/// 把这一轮新到的信变成一条通知。
///
/// 两种形态二选一，取决于用户有没有关掉「应用内横幅提醒」：
/// - 开着 → 走 `NotificationService`，与前台**同一条**通知、同一个基线闸门；
/// - 关着 → 只留一条静默通知（见 [_notifySilently]）。
///
/// 关着横幅时**不能**什么都不做：那样这次后台唤醒在用户侧毫无痕迹，
/// 而「后台任务没跑」和「跑了但没新邮件」在用户看来会变成同一件事。
Future<void> _announce(
  PrefsStore prefs,
  List<Profile> profiles,
  List<({String profileId, List<MailRow> rows})> fresh,
) async {
  if (!prefs.notifyBanner) {
    // 只数**值得提醒的**（未读 + 收件方向）。`syncOnce` 返回的是「本轮新写入
    // 的行」，里面可能混着在别的设备上刚读过的信、以及发件方向的补偿行 ——
    // 把它们算进「N 封新邮件」会让这个数字看起来永远偏大。
    final count = fresh.fold<int>(
      0,
      (sum, e) => sum + BackgroundSyncTask.countNotifiable(e.rows),
    );
    if (count > 0) await _notifySilently(count);
    return;
  }

  // `requestPermission: false` 是这里**必须**传的：后台引擎没有 Activity，
  // 而 Android 插件的 `requestNotificationsPermission()` 要用 Activity 去
  // `checkSelfPermission` / `requestPermissions`（见插件 Java 侧
  // `FlutterLocalNotificationsPlugin.java:1925-1934`）—— 拿到 null 之后
  // 那条路要么抛、要么静默地把「有权限」判成「没权限」。权限是前台
  // 「打开通知开关」那一步要来的，后台只做只读探测。
  final service = NotificationService(requestPermission: false);
  service.attachL10n(lookupAppLocalizations(
    Locale(prefs.localeCode == 'en' ? 'en' : 'zh'),
  ));
  await service.init();
  for (final entry in fresh) {
    await service.showFor(
      profileId: entry.profileId,
      rows: entry.rows,
      display: true,
      // `entry.rows` 是 `SyncEngine.syncOnce()` 的返回值，语义上就是
      // 「本轮新写入的行」—— 那个 API 的形状和前台 `NewMailBus` 一模一样。
      // 但基线闸门是**内存态**，而后台每次唤醒都是一个全新进程，
      // 不告诉它「这批已经是增量」的话，它会把每一轮都当成首轮、
      // 只建基线不弹 —— 后台通知就永远静默了。
      delta: true,
      profileName: _nameOf(profiles, entry.profileId),
    );
  }
}

String? _nameOf(List<Profile> profiles, String id) {
  for (final profile in profiles) {
    if (profile.id == id) return profile.displayName;
  }
  return null;
}

Future<PrefsStore?> _openPrefs() async {
  try {
    return await PrefsStore.open();
  } catch (e) {
    debugPrint('后台同步：偏好设置打不开：$e');
    return null;
  }
}

/// 「别响，但留个痕迹」。
///
/// 用一个**低优先级、静音**的渠道：Android 的渠道一旦建好，它的重要性就由
/// 用户在系统设置里说了算，我们改不了 —— 所以它必须是另一个 id
/// （`new_mail_silent`），不能复用 `new_mail`，否则用户在这条静默通知上做的
/// 任何调整都会连带影响正常的新邮件提醒。
Future<void> _notifySilently(int count) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
    );
    await plugin.show(
      id: 0,
      title: null,
      body: '$count 封新邮件',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'new_mail_silent',
          '新邮件（静默）',
          channelDescription: '只在通知栏留下一个数字，不响不震',
          importance: Importance.low,
          priority: Priority.low,
          playSound: false,
          enableVibration: false,
          // 用户多半正在别的 App 里忙着，别把图标定在状态栏上。
          ongoing: false,
          onlyAlertOnce: true,
        ),
      ),
      // 不带 payload —— 静默通知本来就是「有个数字」，指不到具体哪封信。
      // 点它只会打开 App 落在聚合列表。
    );
  } catch (e) {
    debugPrint('后台同步：静默通知失败：$e');
  }
}
