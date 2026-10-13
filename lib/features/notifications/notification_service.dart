import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../l10n/app_localizations.dart';
import 'notification_policy_seam.dart';

/// 新邮件的**本地**通知。
///
/// ## 它是什么，以及它**不是**什么
///
/// 这是「App 活着的时候，新邮件到了弹一条横幅」。它**不是推送**：
/// 进程被杀掉之后什么都不会弹。真正的后台推送要等 `mail-push` 中转
/// Worker + FCM（计划里的 M5），而那条路依赖用户先去 Firebase 建项目、
/// 再在实例后台填 webhook —— 不是这里能替你决定的事。
///
/// 所以这个类的定位是：**在轮询已经在跑的前提下，把「新邮件」这件事从
/// 列表里的一声动静变成一条系统通知**。它不引入任何新的依赖面。
///
/// ## 三个刻意的取舍
///
/// 1. **不补弹历史**。第一次见到某个实例时，只记下它的最大 `emailId`
///    作为基线，不为已经存在的邮件弹通知。否则新装 App（或加一个新实例）
///    的那一刻会被几百条通知糊满屏幕 —— 那是这个功能最容易被做坏的地方。
/// 2. **一轮一封，合并弹出**。同一实例一轮同步来了 30 封，弹 30 条通知是
///    骚扰；合成一条「3 个邮箱收到 30 封新邮件」才是用户想要的。
/// 3. **权限在「用户主动打开开关」时请求**，不在启动时。冷启动第一屏就弹
///    权限框，用户多半会顺手点「不允许」，之后再想要这个功能就得去系统设置里翻。
class NotificationService {
  /// 不做参数注入：`FlutterLocalNotificationsPlugin` 是个单例
  /// （`factory` 永远返回同一个 `_instance`），传进来的也只能是它自己 ——
  /// 留一个假的注入口反而会让人以为单测里能换成 mock。
  ///
  /// [requestPermission] 只在**后台任务那个 isolate** 里要关掉，见 [_requestPermission]。
  NotificationService({this.requestPermission = true});

  /// 允不允许主动弹系统权限框。
  ///
  /// 后台 isolate 里必须为 false：Android 插件要用一个已附加的
  /// `Activity`（`mainActivity`）才能 `requestPermissions`，
  /// 而 `workmanager` 起的那个后台引擎**没有 Activity**（它只有 application
  /// context）。在那里请求权限会抛 `PlatformException`（甚至 NPE），
  /// 结果和我们想要的正好相反 —— 不是「问一下」，而是「白白失败一次」。
  ///
  /// 更重要的一点：**后台本来就不该弹权限框**。用户看不见那个框，
  /// 系统也不会显示它，真弹出来只会在日志里留下一条异常。
  /// 权限该由前台的「打开通知开关」那一步去要（见 `settings_screen.dart`），
  /// 后台只负责「有就给，没有就算了」。
  final bool requestPermission;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final NotificationGate _gate = NotificationGate();

  /// 通知被点击后的去向。由 `NotificationHost` 在挂载后通过
  /// [attachOpenHandler] 设置 —— 导航需要 `BuildContext`/router，
  /// 而本服务活在 widget 树之外，拿不到。
  void Function(MailRef ref)? _onOpen;

  /// 还没有送出去的点击。
  ///
  /// 覆盖两种时序：冷启动时点击事件在 `init()` 里就到了（那时 host 还没挂），
  /// 以及 App 在前台时用户点了通知但当时正在导航。攒起来，等 host 挂上补送。
  final List<MailRef> _pendingOpen = <MailRef>[];

  /// 语言包。通知的文案在 UI 之外生成，拿不到 `BuildContext`，
  /// 所以由 `NotificationHost` 把当前的 [AppLocalizations] 推过来。
  /// 为 null 时用中文字面量兜底（宁可文案没跟着切，也不要因为
  /// 拿不到 l10n 就整条通知不弹）。
  AppLocalizations? _l10n;

  bool _initialized = false;
  bool _supported = true;
  Future<bool>? _permissionPending;

  /// 这个平台能不能弹。不能弹时全部方法都是安全的空操作。
  bool get isSupported => _supported;

  void attachL10n(AppLocalizations? l10n) => _l10n = l10n;

  /// 挂上「点通知之后去哪」的处理者，并把**攒着的**点击补送一次。
  ///
  /// 补送是必须的：冷启动那条路上，点击事件在 `init()` 里就到手了，
  /// 而那时 widget 树还没建起来。攒着等 host 挂上再送，用户点通知
  /// 打开 App 才能真的落在那封信上（而不是停在聚合列表）。
  void attachOpenHandler(void Function(MailRef ref) handler) {
    _onOpen = handler;
    if (_pendingOpen.isEmpty) return;
    final queued = List<MailRef>.of(_pendingOpen);
    _pendingOpen.clear();
    for (final ref in queued) {
      handler(ref);
    }
  }

  /// 初始化。**必须早于任何一次 [showFor]**，重复调用是安全的。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await _plugin.initialize(
        settings: _initializationSettings(),
        onDidReceiveNotificationResponse: _onTap,
      );
      // App 被通知**冷启动**时（进程当时已经死了），点击事件不在上面的
      // 回调里，而是通过 launch details 拿 —— 少这一步就会出现
      // 「点通知打开 App，但停在列表页」。
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        _onTap(NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: launch?.notificationResponse?.payload,
        ));
      }
    } catch (e) {
      // 初始化失败（插件缺失、权限服务异常、Windows 上注册不了通知）
      // 只降级为「不弹通知」，**绝不能**把同步链路带崩。
      _supported = false;
      debugPrint('通知：初始化失败，本次运行内不再尝试：$e');
    }
  }

  /// 确认通知权限。返回是否拿到。
  ///
  /// 同一个进程内只真正问一次（之后的调用复用同一个 Future）——
  /// 系统本身也不会重复弹框，但复用可以避免多条并发的权限请求
  /// 各自拿到一次「拒绝」再互相覆盖结论。
  ///
  /// 走哪条路由 [requestPermission] 决定：前台是「问一下」，后台是「查一下」。
  Future<bool> ensurePermission() {
    if (!_supported) return Future<bool>.value(false);
    return _permissionPending ??=
        requestPermission ? _requestPermission() : _probePermission();
  }

  /// **只查不问**。后台 isolate 走的这条路。
  ///
  /// 两个 API 的区别恰好就是我们要的那条分界线：
  /// - `requestNotificationsPermission()` → Java 侧
  ///   `ContextCompat.checkSelfPermission(mainActivity, ...)` +
  ///   `ActivityCompat.requestPermissions(mainActivity, ...)`，**依赖一个
  ///   已附加的 Activity**；
  /// - `areNotificationsEnabled()` → Java 侧只调
  ///   `getNotificationManager(applicationContext)`，**只要 context**。
  ///
  /// 后台引擎拿不到 Activity，所以前者在那里要么抛异常、要么（更坏）
  /// 静默地永远返回 false，把「有通知权限」误判成「没有」—— 那样后台
  /// 兜底任务就彻底不弹了，而且日志里什么都看不出来。
  ///
  /// 探测不到（插件没实现这个方法、平台通道不通）时**乐观返回 true**：
  /// 这时候真正该做的判断是「弹一条试试」，而不是「因为检测失败所以不弹」。
  /// `_plugin.show` 自己会处理没有权限的情况。
  Future<bool> _probePermission() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        return await android?.areNotificationsEnabled() ?? true;
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final ios = _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        return (await ios?.checkPermissions())?.isEnabled ?? true;
      }
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        final macos = _plugin.resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>();
        return (await macos?.checkPermissions())?.isEnabled ?? true;
      }
      return true;
    } catch (e) {
      debugPrint('通知：探测权限失败，按有权限处理：$e');
      return true;
    }
  }

  Future<bool> _requestPermission() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        // Android 13+ 才有运行时权限；13 以下是 null（= 已经可以弹）。
        return await android?.requestNotificationsPermission() ?? true;
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final ios = _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        return await ios?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            true;
      }
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        final macos = _plugin.resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>();
        return await macos?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            true;
      }
      // Linux 走 Desktop Notifications 规范，Windows 走 Toast，都没有
      // 需要主动申请的运行时权限。
      return true;
    } catch (e) {
      debugPrint('通知：请求权限失败：$e');
      return false;
    }
  }

  /// 一轮同步结束后的入口。
  ///
  /// [rows] 必须是**本轮新写入的行**（`NewMailBus` 的语义就是如此）。
  /// 首次见到 [profileId] 时只建立基线，不弹。
  ///
  /// [display] 为 false 时（用户关掉了「应用内横幅」开关）**仍然要调** ——
  /// 闸门顺带负责推进基线。关掉通知的这一周里攒下的邮件，不该在重新
  /// 打开的那一刻被当成新的、一次全弹出来。
  ///
  /// [profileName] 是给通知文案用的实例名（合并弹一条时要说清是哪个实例）。
  /// 调用方现取现传，而不是让本服务缓存一份 —— 用户可能刚改过备注名，
  /// 而这条信就是改名之后到的。
  ///
  /// [delta] 为 true 表示 [rows] **已经是「本轮新到的」那批**，不是一页历史。
  /// 后台任务必须传 true，理由见 [NotificationGate.select]。
  Future<void> showFor({
    required String profileId,
    required List<MailRow> rows,
    bool display = true,
    bool delta = false,
    String? profileName,
  }) async {
    final fresh = _gate.select(profileId, rows, delta: delta);
    if (fresh.isEmpty || !display) return;
    if (!_supported) return;

    if (!await ensurePermission()) return;
    await _show(profileId, fresh, profileName);
  }

  Future<void> _show(
    String profileId,
    List<MailRow> fresh,
    String? profileName,
  ) async {
    final l10n = _l10n;
    final name = profileName ?? profileId;
    // 取最新的一封作为标题：通知栏里用户先看到的是「谁发的、什么标题」。
    final latest = fresh.reduce((a, b) => a.emailId > b.emailId ? a : b);

    final title = fresh.length == 1
        ? latest.displaySender
        : (l10n?.newMail ?? '新邮件');
    final body = fresh.length == 1
        ? latest.displaySubject
        : (l10n?.newMailSummary(name, fresh.length) ??
            '$name：${fresh.length} 封新邮件');

    try {
      await _plugin.show(
        // 通知 id 由 `(profileId, emailId)` 算出：同一封重弹会覆盖而不是
        // 叠一条；不同实例的同号邮件也各成一条。
        id: notificationId(profileId, latest.emailId),
        title: title,
        body: body,
        notificationDetails: _details(),
        payload: encodePayload(profileId, latest.emailId),
      );
    } catch (e) {
      // 弹不出来不该影响同步链路。
      debugPrint('通知：弹出失败：$e');
    }
  }

  /// 撤掉某一封的通知（用户点开它之后，通知栏里那条就过期了）。
  Future<void> cancelFor(MailRef ref) async {
    if (!_supported) return;
    try {
      await _plugin.cancel(id: notificationId(ref.profileId, ref.emailId));
    } catch (e) {
      debugPrint('通知：撤销失败：$e');
    }
  }

  // --------------------------------------------------------- 稍后提醒

  /// 排一条提醒（spec §7.5）。[remindAt] 是 **UTC**。
  ///
  /// 两处刻意：
  /// 1. **`tz.UTC` 恒等换算，不查时区库。** `DateTime` 的本机 → UTC 换算在
  ///    用户选时间那一刻就做完了，这里只把它原样交给插件 —— 「本机时区」
  ///    在这条链路上只出现一次。
  /// 2. **`androidScheduleMode: exactAllowWhileIdle`**，配套 manifest 里的
  ///    `USE_EXACT_ALARM`。少任何一样，通知永远不弹且**日志里什么都没有**
  ///    （见 `test/notification_reminder_source_test.dart` 那条文本断言）。
  ///
  /// Linux 上 `zonedSchedule` 没实现（平台接口直接抛 `UnimplementedError`），
  /// 那条路由 `ReminderTicker` 顶上（spec §7.6）—— 所以这里的失败只 `debugPrint`。
  Future<void> scheduleReminder({
    required String profileId,
    required int emailId,
    required DateTime remindAt,
    required String subject,
    required String sender,
  }) async {
    if (!_supported) return;
    try {
      await _plugin.zonedSchedule(
        id: reminderId(profileId, emailId),
        scheduledDate: tz.TZDateTime.from(remindAt, tz.UTC),
        notificationDetails: _details(reminder: true),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        title: sender,
        body: subject,
        payload: encodePayload(profileId, emailId),
      );
    } catch (e) {
      // 排不上不该把调用方带崩 —— Linux 那条路由 ticker 兜底，
      // 其余情况用户至少还有 App 里那封信。
      debugPrint('通知：提醒排期失败：$e');
    }
  }

  /// 撤掉某封邮件的提醒（用户删了信、或改主意了）。
  ///
  /// 通知已经交给 OS 了，不主动撤的话用户删了信还会在周五被提醒一次那封
  /// **已经不存在的邮件**。
  Future<void> cancelReminder(String profileId, int emailId) async {
    if (!_supported) return;
    try {
      await _plugin.cancel(id: reminderId(profileId, emailId));
    } catch (e) {
      debugPrint('通知：撤销提醒失败：$e');
    }
  }

  /// 降级路专用的**即时**弹出（Linux，见 `ReminderTicker`）。
  ///
  /// 与 [scheduleReminder] **共用 [reminderId]**：同一封邮件的提醒不管走哪条
  /// 路都是同一个 id，所以「系统排期弹过一条、ticker 又弹一条」不会在通知栏
  /// 里并排两条。
  ///
  /// 渠道用 [reminder] 那一份（`mail_reminder`）：Linux 的
  /// `LinuxNotificationDetails()` 在 `_details()` 的两个分支里是同一个对象，
  /// 渠道只在 Android 上有意义，所以这里不存在「Linux 上多出一个渠道」。
  Future<void> showReminderNow({
    required String profileId,
    required int emailId,
    required String subject,
    required String sender,
  }) async {
    if (!_supported) return;
    try {
      await _plugin.show(
        id: reminderId(profileId, emailId),
        title: sender,
        body: subject,
        notificationDetails: _details(reminder: true),
        payload: encodePayload(profileId, emailId),
      );
    } catch (e) {
      // 弹不出来要让调用方知道（ticker 据此决定不置 firedAt），所以这里
      // **不吞**：`_plugin.show` 真失败时把异常留给 `ReminderTicker` 那条
      // 逐条的 try。**与 `showFor` 的取舍不同** —— 那边是「新邮件提醒弹不出来
      // 不该影响同步链路」，而这边弹不出来是一件需要重试的事。
      debugPrint('通知：提醒弹出失败：$e');
      rethrow;
    }
  }

  /// `(profileId, emailId)` → **提醒**的通知 id。**与新邮件那个不同的拼法**：
  /// 同一封邮件既可能有一条「新邮件」通知又有一条「提醒」通知，共用 id 会让
  /// 后者把前者顶掉（或反过来）。
  @visibleForTesting
  static int reminderId(String profileId, int emailId) =>
      _fnv1a('reminder|$profileId|$emailId') & 0x7fffffff;

  // ------------------------------------------------------------- 内部

  void _onTap(NotificationResponse response) {
    final ref = decodePayload(response.payload);
    if (ref == null) return;
    final handler = _onOpen;
    if (handler == null) {
      // host 还没挂上（冷启动那一路）—— 攒着，等它挂上补送。
      _pendingOpen.add(ref);
    } else {
      handler(ref);
    }
  }

  /// 通知外观。默认那一份是**新邮件**用的 —— 渠道 id `new_mail` 与名字
  /// 「新邮件」都是**装在用户手机上**的东西。Android 上渠道建好之后 id 与
  /// 名字都改不了，新 id 会变成第二条渠道（旧的还在设置里躺着），所以
  /// `_details()` 的默认值一个字都不能动。
  ///
  /// [reminder] 为 true 时换成「邮件提醒」那一条渠道：用户可能想静音提醒
  /// 但保留新邮件通知（这两件事的紧迫程度本来就不一样）。
  ///
  /// **方法体不能再是表达式体的 `const`**：渠道 id 现在是参数。
  NotificationDetails _details({bool reminder = false}) => NotificationDetails(
        android: reminder
            ? const AndroidNotificationDetails(
                _reminderChannelId,
                _reminderChannelName,
                channelDescription: '你让它稍后提醒你的邮件',
                importance: Importance.high,
                priority: Priority.high,
              )
            : const AndroidNotificationDetails(
                _channelId,
                _channelName,
                channelDescription: '收到新邮件时提醒',
                importance: Importance.high,
                priority: Priority.high,
              ),
        iOS: const DarwinNotificationDetails(),
        macOS: const DarwinNotificationDetails(),
        linux: const LinuxNotificationDetails(),
        // Windows 的默认 Toast 只有标题和正文，够用了。
        windows: const WindowsNotificationDetails(),
      );

  static const String _channelId = 'new_mail';
  static const String _channelName = '新邮件';
  static const String _reminderChannelId = 'mail_reminder';
  static const String _reminderChannelName = '邮件提醒';

  /// `(profileId, emailId)` → 通知 id。
  ///
  /// 只用 `emailId` 会让两个实例的同号邮件互相覆盖：它们本来就是不同的信，
  /// 却在通知栏里抢同一个位置。混进 `profileId` 就分开了。
  ///
  /// **不能用 `Object.hash`**：它带一个每个 isolate 随机生成的种子，
  /// 同一个字符串在两次运行里会得到不同的值（Dart 官方文档明确说不保证
  /// 跨运行一致）。那样一来，「App 重启后点通知 → 撤掉那条通知」算出的 id
  /// 跟当初 `show` 用的对不上，`cancel` 静默失败，通知会一直挂在通知栏里。
  /// 所以这里是手写的 FNV-1a，跨进程稳定。
  @visibleForTesting
  static int notificationId(String profileId, int emailId) =>
      _fnv1a('$profileId|$emailId') & 0x7fffffff;

  /// FNV-1a 32 位。选它是因为实现只有几行、无需依赖、且分布对
  /// 「几十个 kind 相似的短字符串」足够好 —— 这里的输入规模就这么点。
  static int _fnv1a(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      // 乘 16777619 再用 32 位掩码截断。Dart 的 int 是 64 位，
      // 不截断会让结果溢出成另一个值，且不再是 32 位混合。
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  /// 通知的 `payload`：`<profileId>|<emailId>`。
  ///
  /// 用一个字符分隔而不是 JSON：这个串会被系统在进程重建后原样交回来，
  /// 越简单越不容易在编码上出岔子。profileId 是 uuid（只有 `-` 和字母数字），
  /// 不可能含 `|`。
  @visibleForTesting
  static String encodePayload(String profileId, int emailId) =>
      '$profileId|$emailId';

  @visibleForTesting
  static MailRef? decodePayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    final at = payload.lastIndexOf('|');
    if (at <= 0) return null;
    final emailId = int.tryParse(payload.substring(at + 1));
    if (emailId == null || emailId <= 0) return null;
    return MailRef(profileId: payload.substring(0, at), emailId: emailId);
  }

  /// Windows 的 Toast 需要三样**固定**的身份信息（改了就等于换了一个 App，
  /// 用户已有的通知会全部失效），所以它们写在代码里而不是运行时生成。
  static const String _winAppName = 'Cirro Mail';
  static const String _winAumid = 'CloudMail.MailApp';
  static const String _winGuid = 'bd19a4dd-9ddc-41fa-96bd-245cdb7b6976';

  /// 通知栏小图标。
  ///
  /// Android 只从 **drawable** 里按名字找（插件用的是
  /// `getIdentifier(name, "drawable", ...)`），`@mipmap/ic_launcher` 找不到 ——
  /// 所以这里必须是一个 drawable 资源名，而不是 manifest 里那个启动图标。
  /// `android/app/src/main/res/drawable/ic_notification.xml` 就是它。
  static const String _androidIcon = 'ic_notification';

  InitializationSettings _initializationSettings() {
    // 每个平台只填自己那一份 —— 插件对「当前平台缺设置」是直接抛
    // ArgumentError 的；全填上更安全，多出来的会被忽略。
    return const InitializationSettings(
      android: AndroidInitializationSettings(_androidIcon),
      iOS: DarwinInitializationSettings(
        // 初始化时**不**请求权限，见类注释第 3 条。
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
      ),
      macOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
      ),
      linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      windows: WindowsInitializationSettings(
        appName: _winAppName,
        appUserModelId: _winAumid,
        guid: _winGuid,
      ),
    );
  }
}

/// 「哪些行真的该弹」——**与插件无关的纯逻辑**，单独抽出来是为了能单测。
///
/// 这里最容易错的是三个过滤条件叠加时的语义（基线、方向、未读），
/// 而那部分完全不需要真插件、也不需要平台通道。
@visibleForTesting
class NotificationGate {
  /// [policy] 是「这一行该不该弹」的判定，默认走 [isNotifiable]（通用条件 +
  /// 已注册扩展的规则，见 `notification_policy_seam.dart`）。
  ///
  /// 留一个可注入的口子是为了**闸门自己的测试**：它关心的是游标语义（基线
  /// 什么时候推进），不该被「当前进程里恰好注册了哪些扩展」影响，也不该为了
  /// 造一条假的静音规则去搭一个真的扩展。
  NotificationGate({NotifiablePredicate? policy})
      : _policy = policy ?? isNotifiable;

  final NotifiablePredicate _policy;

  /// 每个实例「已经见过」的最大 `emailId`。
  ///
  /// 只在内存里，**不落盘**：它描述的是「这次进程运行期间弹过哪些」。
  /// 重启后重新建立基线，正好符合「不补弹历史」的取舍。
  final Map<String, int> _baseline = <String, int>{};

  /// 返回**真的该弹**的那些行；同时推进基线。首轮只建基线，返回空。
  ///
  /// [delta] 为 true 时表示调用方给的 [rows] **已经是「本轮新到的」那批**，
  /// 而不是一页历史 —— 后台任务那条路（`SyncEngine.syncOnce` 的返回值）
  /// 就是这种形状。此时不能走「首轮只建基线」那条分支：后台每次唤醒都是
  /// **一个全新的进程**（`_baseline` 是内存态，必定是空的），照前台那套
  /// 走的话每一轮都会被当成首轮、永远不弹。
  ///
  /// 去重靠什么？`emailId > baseline` 这个条件本身 —— 打的是**上一轮
  /// 同步到的最大 id**，而这个值是从本地库读出来的，不受进程重启影响。
  List<MailRow> select(
    String profileId,
    List<MailRow> rows, {
    bool delta = false,
  }) {
    if (rows.isEmpty) return const <MailRow>[];

    // 基线取的是「已经见过的最大 `emailId`」，**不先按未读/方向筛**。
    // 它是游标的语义（走到哪儿了），不是「哪些值得弹」的语义 ——
    // 拿筛过的子集去推进基线，会让一份已读的来信推不动游标，下一次
    // 重扫时又原样回到候选里（虽然按 id 比大小最终不会误弹，但让
    // 「见过」这件事依赖过滤条件是一颗定时炸弹）。
    final maxId =
        rows.map((row) => row.emailId).reduce((a, b) => a > b ? a : b);
    final baseline = _baseline[profileId];
    _baseline[profileId] =
        baseline == null || maxId > baseline ? maxId : baseline;

    // 只有「一整页历史」那种调用才需要这道闸：第一次见到这个实例时只记
    // 基线，不为已经存在的邮件弹通知（见类注释第 1 条）。[delta] 的调用方
    // 已经把范围收到「本轮新到的」了，**包括后台那个全新进程**（内存基线
    // 必然是空的，照前一套走就永远不会弹）。
    if (baseline == null && !delta) return const <MailRow>[];

    // 两个过滤条件叠加：
    // - `emailId > baseline` —— 基线之后**真的新**的那些。`rows` 里可能
    //   混着旧邮件（服务端补发、空洞重扫），不筛的话重扫一次就把整页
    //   旧邮件弹一遍。基线为 null 时（后台那种 delta 调用）不挡；
    // - [_policy] —— 未读 + 收件方向（这两条以前写在这儿），外加已注册扩展
    //   的规则。抽成 [isNotifiable] 是因为后台计数那条路要用**同一个**判定，
    //   两处各写一遍早晚会漂（见 `notification_policy_seam.dart`）。
    //
    // 注意这一道**不参与上面基线的推进** —— 被静音的行照样把游标推过去。
    // 静音是「这次别弹」，不是「当它没来过」：游标停在被静音的那封上，之后
    // 用户解除静音，攒下的旧信不会被补弹一遍。
    return rows
        .where((row) => baseline == null || row.emailId > baseline)
        .where(_policy)
        .toList(growable: false);
  }
}
