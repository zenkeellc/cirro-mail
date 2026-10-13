import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/error/app_exception.dart';
import '../../core/storage/prefs_store.dart';
import '../../core/storage/token_store.dart';
import '../../data/models/mail_ref.dart';
import '../../data/models/mailbox_account.dart';
import '../../data/models/profile.dart';
import 'relay_client.dart';

/// 一条推送到手（App 活着的时候从 FCM 拿到的，或后台补拉到的）。
///
/// 只带**最小元数据**：正文在实例那边，App 拿到这个之后自己带 token 去拉。
/// 这是中转端刻意的取舍（见 `mail-push/src/types.ts`），所以这里也不指望
/// 能拿到 subject 之外的任何内容。
@immutable
class PushMailEvent {
  const PushMailEvent({
    required this.profileId,
    required this.emailId,
    this.mailboxEmail = '',
    this.sendEmail = '',
    this.sendName = '',
    this.subject = '',
    this.code = '',
  });

  /// 本地 profile id —— 由 `instanceId` 映射过来，映射不上就是空串。
  final String profileId;
  final int emailId;
  final String mailboxEmail;
  final String sendEmail;
  final String sendName;
  final String subject;
  final String code;

  MailRef? get ref => profileId.isEmpty ? null : MailRef(profileId: profileId, emailId: emailId);
}

/// 后台推送的原始 data 载荷。**库级而不是实例字段** —— 见
/// [pushServiceBackgroundEntry]，它必须是顶层函数，够不到任何实例。
///
/// Apple 平台上这个入口和 App 跑在同一个 isolate 里，所以这份状态一定
/// 看得见它写进去的东西；Android 上后台回调落在另一个引擎里，那时这份
/// 库里没有监听者，事件会被 [pushServiceBackgroundEntry] 直接丢掉（Android
/// 的后台同步另有一套，见 `background_sync_task.dart`）。
final StreamController<Map<String, dynamic>> _rawBackground =
    StreamController<Map<String, dynamic>>.broadcast();

/// 冷启动兜底：推送比监听者先到时先存这里，[PushService.background] 一被
/// 订阅就把它取走。
///
/// **只留最新一条**：推送的目的就是「立刻去拉一轮」，而拉一轮是全量的
/// （`SyncEngine.syncOnce`），多条推送共用一次刷新就够了。
Map<String, dynamic>? _pendingBackgroundData;

/// 后台消息的顶层入口。
///
/// **必须是顶层函数**：Android 侧插件会拿它的 `callbackHandle` 去唤醒后台
/// isolate（`FirebaseMessaging.onBackgroundMessage` 的文档也这么要求）；Apple
/// 侧不检查，但形状保持一致，省得到时候两边对不上。
///
/// 它**不查库、不解析** —— 那些是 [PushService.background] 的活。这里只
/// 决定「现在有人接，还是先存起来」。
@pragma('vm:entry-point')
Future<void> pushServiceBackgroundEntry(RemoteMessage message) async {
  if (_rawBackground.hasListener) {
    _rawBackground.add(message.data);
  } else {
    _pendingBackgroundData = message.data;
  }
}

/// 把待取槽清空。
///
/// 只给测试用：槽是库级的，而 `flutter test` 里同一个 isolate 会连着跑
/// 一大批用例，不主动清的话「上一条用留下的待取事件」会漏到下一条里。
@visibleForTesting
void resetBackgroundForTesting() {
  _pendingBackgroundData = null;
}

/// 真·后台推送（FCM）。
///
/// ## 三件互相独立的事，别混在一起
///
/// 1. **能不能用**（[available]）：这个平台有没有 FCM 插件。`firebase_messaging`
///    的 `flutter.plugin.platforms` 只声明了 android / ios / macos / web，
///    所以 **Linux 和 Windows 永远返回 false**（本工程不做 Web）—— 那两个
///    平台上推送只能靠轮询。macOS 是支持的，但要自己塞
///    `GoogleService-Info.plist`（见 [_hasConfigFile]），**还要**有带
///    Push Notifications 的 entitlements 与 Mac 描述文件（见 [initialize]）。
/// 2. **配没配**（[relayUrl]/[instanceId]/配对码）：用户有没有在中转端开位、
///    有没有把三条值填进来。没配就是没配，不该报错。
/// 3. **注册成不成功**：网络、FCM token 拿不拿得到、中转端认不认配对码。
///
/// 这三层任意一层不满足都只是「没有推送」，**轮询照跑**（那是 [SyncEngine]
/// 的事，跟这里无关）。所以本类的每个方法都不抛异常，只返回结果对象 ——
/// 推送不该有把 App 弄崩的能力。
class PushService {
  // `this._prefs` 这类私有初始化形参是 Dart 3.12 才有的：调用点仍写公开名
  // （`prefs:` / `tokens:` / `readProfiles:` / `readMailboxes:`），编译期直接
  // 落到同名私有字段上，省掉一串 `_x = x`。
  PushService({
    required this._prefs,
    required this._tokens,
    required this._readProfiles,
    required this._readMailboxes,
    @visibleForTesting bool? forceAvailable,
    @visibleForTesting this._clientFactory,
  }) : available = forceAvailable ?? _detectAvailable();

  final PrefsStore _prefs;
  final TokenStore _tokens;
  final Future<List<Profile>> Function() _readProfiles;
  final Future<List<MailboxAccount>> Function(String profileId) _readMailboxes;

  /// 这个平台 + 这份构建能不能用 FCM。
  final bool available;

  /// 这份构建里有没有 Firebase 配置文件。
  ///
  /// 公开出来只给界面用：指引页要能在用户**动手之前**就说清「这份构建
  /// 里没有配置文件，做完下面这些也不会响」。把它留在 [initialize] 内部
  /// 的话，用户得先配齐三条值、打开开关、点一次登记，才能从「没反应」
  /// 里倒推出这件事。
  ///
  /// Android/iOS 上判据并不精确（见 [_hasConfigFile]）—— 那两端的配置在
  /// 打包时进资源，运行时没有稳定路径可查，所以一律回 true，让
  /// `Firebase.initializeApp()` 去做唯一的权威判断。
  bool get hasFirebaseConfig => available && _hasConfigFile();

  /// 测试用的中转客户端工厂。生产上传空，[_client] 就按 `relayUrl` 现建。
  ///
  /// 存在的理由是「设备号到底有没有带着实例位前缀上网」这件事**只能在
  /// 请求体里看到** —— 光断言 prefs 里存对了，断不出 `_client()` 那一跳
  /// 有没有把它原样送出去（本次那个 bug 正是这样漏掉的）。
  final RelayClient Function(String baseUrl)? _clientFactory;

  bool _initialized = false;
  String _fcmToken = '';

  /// FCM 的 token 只有在**拿到之后**才可能变（App 卸载重装、数据清理、
  /// token 轮换），所以每次注册都现取，拿不到就不注册。
  String get fcmToken => _fcmToken;

  String get relayUrl => _prefs.pushRelayUrl;
  String get instanceId => _prefs.pushInstanceId;
  String get deviceId => _prefs.pushDeviceId;

  /// 三条必须值是不是都填了。
  bool get isConfigured =>
      available && relayUrl.isNotEmpty && instanceId.isNotEmpty && deviceId.isNotEmpty;

  /// 中转端认不认这个设备号。
  ///
  /// 与 [deviceIdMatchesInstance] 同一套判据，抽出来只为让 UI 一句写完。
  bool get deviceIdValid => deviceIdMatchesInstance(deviceId, instanceId);

  /// 设备号必须以 `<instanceId>-` 开头 —— 这是**中转端的硬校验**，
  /// 见 `mail-push/src/routes/register.ts` 的 `deviceId.startsWith(...)`。
  ///
  /// 之所以要求前缀：中转端的注册是 UPSERT，而它的主键是
  /// `(device_id, mailbox_email)`。没有前缀的话，A 实例的设备号可以命中
  /// B 实例上同一设备号、同一邮箱的那一行，而那行的 `instance_id` 会留在
  /// B（冲突时不更新它），于是 B 的 webhook 会推给 A 的设备。前缀（里面含
  /// 唯一实例位）把这种碰撞压到不可能。
  ///
  /// 判据与中转端**逐字一致**（`startsWith('<id>-')`），刻意不写成
  /// 「以 id 开头」：那样 `inst-1` 和 `inst-11` 会互相认成一家。
  static bool deviceIdMatchesInstance(String deviceId, String instanceId) =>
      instanceId.isNotEmpty && deviceId.startsWith('$instanceId-');

  /// 现造一个设备号：`<instanceId>-<32 位十六进制>`。
  ///
  /// 形状是照着中转端的 `newDeviceId()` 来的（也是 `<id>-<32 hex>`），
  /// 只是那边用 `crypto.getRandomValues`，这边用 UUID v4 去横线。
  static String mintDeviceId(String instanceId) =>
      '$instanceId-${const Uuid().v4().replaceAll('-', '')}';

  /// 确保 prefs 里的设备号对得上当前实例位，返回一个**一定能注册成功**的值。
  ///
  /// 这是给所有网络路径用的读法（[syncAll] / [unsubscribe] /
  /// [remoteMailboxes]），而**不是**只在设置页里修一次：
  /// 启动时的登记发生在 `NotificationHost._wirePush()`（用户根本没打开
  /// 过设置页），只在设置页做迁移的话，老用户会一直 401 到某天想起来
  /// 点进推送设置为止。
  ///
  /// 「已存的是裸 UUID」这种情况**重新掷一个**、不保留原有尾段：那个值
  /// 从来没有注册成功过（带它的每一次登记都 401），没有任何东西值得保。
  Future<String> ensureDeviceId() async {
    final current = _prefs.pushDeviceId;
    if (deviceIdMatchesInstance(current, instanceId)) return current;
    // 没有实例位就没有前缀可挂 —— 不掷（否则会掷出一个 `-xxxx` 的残废值，
    // 它还写进 prefs，用户之后填上实例位时得靠下一次 ensure 再修）。
    if (instanceId.isEmpty) return current;
    final minted = mintDeviceId(instanceId);
    await _prefs.setPushDeviceId(minted);
    if (kDebugMode) {
      debugPrint('推送：设备号 ${current.isEmpty ? '(空)' : current} → $minted');
    }
    return minted;
  }

  /// 用户有没有把「后台推送」这个开关打开。
  ///
  /// 与 [isConfigured] 是两件事：那个是「能不能」，这个是「要不要」。
  /// 用户可以把三条值填好但又关掉（比如手机在省电、暂时不想收推送），
  /// 这时候配置不该丢，也不该在启动时去注册。
  bool get enabled => _prefs.pushEnabled;

  /// 有没有配对码（配对码在密钥库里，读起来是异步的）。
  Future<bool> hasPairingCode() async {
    if (!isConfigured) return false;
    return await _tokens.readPushToken(instanceId) != null;
  }

  /// 按地址建一个中转客户端；地址为空返回 null。
  ///
  /// 生产上就是 `RelayClient(baseUrl:)`；测试里 [_clientFactory] 会先兜住，
  /// 好让「发出去的请求体长什么样」也能被断言到。
  RelayClient? clientFor(String baseUrl) => baseUrl.isEmpty
      ? null
      : (_clientFactory?.call(baseUrl) ?? RelayClient(baseUrl: baseUrl));

  RelayClient? _client() => isConfigured ? clientFor(relayUrl) : null;

  /// 初始化 FCM。**幂等**，拿不到 token 也不算失败。
  ///
  /// 三条平台上的事实，决定了这里的写法：
  /// - **Android** 必须有 `google-services.json`（构建时打进资源），
  ///   **iOS/macOS** 必须有 `GoogleService-Info.plist`。没有的话
  ///   `Firebase.initializeApp()` 直接抛 —— 而这不是错误，只是「这个
  ///   构建没配 Firebase」，用户在设置页会看到「这台设备还不能收推送」。
  /// - **Linux/Windows** 上 `firebase_messaging` 没有实现，
  ///   `FirebaseMessaging.instance` 一碰就抛 `MissingPluginException`，
  ///   所以要先判 [available]。
  /// - **macOS** 有实现，但比 iOS 多一道槛：`macos/Runner/*.entitlements`
  ///   里必须有 `com.apple.developer.aps-environment`（注意是带前缀的那个
  ///   键，iOS 写的裸 `aps-environment` 在原生 mac 上会被忽略），且签名要
  ///   用带 Push Notifications 的 Mac 描述文件。少任何一样，APNs 注册就会
  ///   静默失败，`getToken()` 抛 `apns-token-not-set` —— 详见 [lastFailure]。
  ///
  /// ## 失败原因为什么要留下来
  ///
  /// 三条原因（权限被拒 / 缺 APNs 权利 / 别的异常）在 `getToken()` 这一句
  /// 上收敛成同一个 `null`，可**用户看到的提示**和前两步完全不同。曾经这里
  /// 把 macOS 的缺 entitlement 一路说成「iOS 上通常是通知权限没有允许」，
  /// 用户于是去系统设置里白找一圈。所以失败原因在这里就分好，交给
  /// [lastFailure] 报给界面。
  Future<bool> initialize() async {
    if (!available || !isConfigured) return false;
    if (_initialized) return _fcmToken.isNotEmpty;

    if (!_hasConfigFile()) {
      debugPrint('推送：这份构建里没有 Firebase 配置文件（google-services.json / '
          'GoogleService-Info.plist），FCM 不可用。');
      _initialized = true;
      _lastFailure = PushInitFailure.firebaseConfig;
      return false;
    }

    try {
      // 已经在别的入口初始化过就复用（Firebase 是全局单例，
      // 重复 initializeApp 会抛 duplicate-app）。
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }

      final messaging = FirebaseMessaging.instance;
      // Apple 平台上这一步会问权限。**只在用户已经填好配对码、主动开推送时
      // 才会走到这里**，所以问得不算突兀。
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      // 先看权限再看 token：被拒时**照样**试着取一次 token —— iOS 上
      // 通知权限与 APNs 注册是两件事，权限被拒未必拿不到 token；真是权限
      // 的问题，下面那次 `getToken()` 会给出一模一样的空结果，我们只是
      // 把「为什么」换成了更准确的那一条。
      //
      // 这一句顺带解释了 macOS 的那次误报：权限是 allowed、APNs 那一步
      // 却失败了，报「权限没开」就是纯粹指错方向。
      final allowed = settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;

      final token = await messaging.getToken();
      _fcmToken = token ?? '';
      _initialized = true;

      if (_fcmToken.isEmpty) {
        _lastFailure =
            allowed ? PushInitFailure.apnsUnavailable : PushInitFailure.permissionDenied;
        debugPrint('推送：FCM 没有给出 token（'
            '${_lastFailure == PushInitFailure.permissionDenied ? "通知权限被拒" : "权限已允许，问题在 APNs 那一步"}）。');
        return false;
      }

      // token 轮换时把新的一起登记上去。**这个回调必须在注册之后仍然有效**，
      // 所以监听器是常驻的（只挂一次）。
      _tokenRefreshSub ??= messaging.onTokenRefresh.listen((next) {
        _fcmToken = next;
        unawaited(syncAll(reason: 'token 轮换'));
      });

      _lastFailure = null;
      return true;
    } catch (e) {
      _initialized = true;
      // 插件在 Apple 平台上拿不到 APNs token 时抛的就是这个 code
      // （`firebase_messaging_platform_interface` 的 `_APNSTokenCheck`）。
      // 它与本类的 entitlement 缺失是同一件事的两种说法。
      final apns = e is FirebaseException && e.code == 'apns-token-not-set';
      _lastFailure = apns ? PushInitFailure.apnsUnavailable : PushInitFailure.unexpected;
      debugPrint('推送：初始化 FCM 失败：$e');
      return false;
    }
  }

  PushInitFailure? _lastFailure;

  /// 上一次 [initialize] 没成功的原因；成功过或还没试过就是 `null`。
  ///
  /// 给界面用来把「拿不到 token」翻成人话。**只有最后一次** —— 与
  /// [initialize] 的幂等语义一致：`_initialized` 之后不再重试，也就没有
  /// 更新的结论。
  PushInitFailure? get lastFailure => _lastFailure;

  /// 把 [lastFailure] 折成一句给用户看的话。
  ///
  /// 三条分支的必要性见 [initialize] 的注释：这三种原因在界面上指向**完全
  /// 不同的动作**（去系统设置开权限 / 去 Xcode 查权利与描述文件 / 看日志），
  /// 说错比不说更糟。
  String _initFailureMessage() {
    if (!available) return '这个平台没有 FCM 实现，推送只能靠 App 运行时轮询';
    return switch (_lastFailure) {
      PushInitFailure.permissionDenied =>
        '通知权限被拒了。去「系统设置 → 通知」里把本 App 的通知打开',
      // macOS 上这是最常见的一条，而且**与权限无关** —— 权限早已允许，
      // 卡在 APNs 注册上。文案必须点明「不是权限」，否则用户会去系统设置
      // 里白翻（macOS 上甚至没有影响这条链路的开关）。
      PushInitFailure.apnsUnavailable => defaultTargetPlatform == TargetPlatform.macOS
          ? 'APNs 注册没成功：这份 macOS 构建缺推送权利或描述文件（不是通知权限的问题）。'
              '需要 App ID 钩上 Push Notifications，并在 macos/Runner 的两个 entitlements 里'
              '补 com.apple.developer.aps-environment 后重新构建'
          : 'Apple 推送注册没成功（APNs 还没拿到设备令牌）。先确认通知权限开着，再重新构建试试',
      PushInitFailure.firebaseConfig =>
        '这份构建里没有 Firebase 配置文件（google-services.json / GoogleService-Info.plist），FCM 用不了',
      PushInitFailure.unexpected => '初始化 FCM 时出错，看日志里那一行「推送：初始化 FCM 失败」',
      null => '这台设备拿不到 FCM token',
    };
  }

  StreamSubscription<String>? _tokenRefreshSub;

  /// 前台收到的推送流。**不在这里弹通知** —— 那是 `NotificationService`
  /// 的事；这里只把「有这么一封信」交出去。理由：前台弹通知要过
  /// `NotificationGate` 的基线闸门，否则推送和轮询会对同一封信各弹一次。
  Stream<PushMailEvent> get foreground => _foregroundController.stream;
  final StreamController<PushMailEvent> _foregroundController =
      StreamController<PushMailEvent>.broadcast();

  /// App **不在前台**时收到的推送流。与 [foreground] 共用同一套解析
  /// （[_decode] / [resolveProfileId]），只是交付时机不同 —— 前台那条由
  /// `Messaging#onMessage` 推来，这条由 `Messaging#onBackgroundMessage` 推来。
  ///
  /// 两件事值得说明：
  ///
  /// 1. **Apple 上它和 [foreground] 同 isolate**，所以这里可以直接看
  ///    库级状态、可以直接查库（`resolveProfileId` 正是要查库的）。
  ///    Android 上 `onBackgroundMessage` 落在另起的引擎里，那时
  ///    `_rawBackground.hasListener` 为假，事件根本不会进这条流。
  /// 2. **冷启动竞态**：iOS 的 `content-available` 推送可以把*没有在运行*
  ///    的 App 拉到后台启动 —— 那一刻 [pushServiceBackgroundEntry] 已经被
  ///    调用，而 `NotificationHost` 还没建出来。所以这一路上先看
  ///    [_pendingBackgroundData] 那条待取槽，订阅的一瞬间就把先到的那条取走。
  Stream<PushMailEvent> get background async* {
    final pending = _pendingBackgroundData;
    _pendingBackgroundData = null;
    if (pending != null) {
      final event = await _decode(pending);
      if (event != null) yield event;
    }
    yield* _rawBackground.stream
        .asyncMap(_decode)
        .where((event) => event != null)
        .cast<PushMailEvent>();
  }

  /// 把一个 FCM data 载荷解析成 [PushMailEvent]；认不出来返回 null。
  ///
  /// 公开出来只给测试用：后台那条路**没有**前台那种 UI 兜底（前台至少有
  /// 列表页），字段错一个就是「点了通知落到错的地方」，所以这层映射要被
  /// 单测钉住。
  @visibleForTesting
  Future<PushMailEvent?> debugDecode(Map<String, dynamic> data) => _decode(data);

  /// 挂上前台/点开推送的监听。必须在 [initialize] 成功之后调。
  Future<void> attachListeners({
    required void Function(PushMailEvent event) onOpen,
  }) async {
    if (!available || _fcmToken.isEmpty) return;
    try {
      final messaging = FirebaseMessaging.instance;

      // 前台与后台的**数据**消息都走这里。FCM 的 notification 载荷在后台
      // 由系统直接画通知；data 载荷只有 App 活着时才到得了我们手上。
      FirebaseMessaging.onMessage.listen((message) {
        _emit(message.data, onEvent: (event) => _foregroundController.add(event));
      });

      // App 不在前台时收到的推送。Apple 上这个 setter 只是赋一个静态字段
      // （不碰平台通道、不需要 Firebase 已配置），所以挂在哪儿都安全；
      // 真正的入口在 `main()` 里也注册了一次 —— 那是为了 iOS 被
      // `content-available` 拉到后台启动那一路，那会儿这里还没跑到。
      FirebaseMessaging.onBackgroundMessage(pushServiceBackgroundEntry);

      // 用户点了系统画出来的那条通知（App 在后台）。
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        _emit(message.data, onEvent: onOpen);
      });

      // App 被推送**冷启动**：点击事件不在上面两个回调里。
      //
      // 这一路上「把 instanceId 翻成 profileId」**必须查库**，不能靠
      // 任何内存缓存 —— 进程刚起来，缓存是空的，而那正是用户点通知的那
      // 一刻。翻不出来就只能打开 App 落在列表页，白点一下。
      final initial = await messaging.getInitialMessage();
      if (initial != null) {
        await _emit(initial.data, onEvent: onOpen);
      }

      // 退到后台时把 token 交回给 FCM，这样数据消息也能到达。
      await messaging.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: false,
        sound: false,
      );
    } catch (e) {
      debugPrint('推送：挂监听失败：$e');
    }
  }

  /// 解一条 FCM 的 data 载荷再交给 [onEvent]。
  ///
  /// 单独抽出来是为了让三个入口（前台 / 后台点开 / 冷启动点开）走**完全
  /// 同一条**解析路径 —— 尤其是冷启动那一条，它需要的 profileId 得现查库。
  Future<void> _emit(
    Map<String, dynamic> data, {
    required void Function(PushMailEvent event) onEvent,
  }) async {
    final event = await _decode(data);
    if (event != null) onEvent(event);
  }

  /// 把一个 FCM 的 data 载荷折成 [PushMailEvent]；认不出来返回 null。
  Future<PushMailEvent?> _decode(Map<String, dynamic> data) async {
    if (data['kind'] != 'new_mail') return null;
    final emailId = int.tryParse('${data['emailId']}') ?? 0;
    if (emailId <= 0) return null;
    final instanceId = data['instanceId']?.toString() ?? '';
    return PushMailEvent(
      profileId: await resolveProfileId(
        instanceId,
        data['mailboxEmail']?.toString() ?? '',
      ),
      emailId: emailId,
      mailboxEmail: data['mailboxEmail']?.toString() ?? '',
      sendEmail: data['sendEmail']?.toString() ?? '',
      sendName: data['sendName']?.toString() ?? '',
      subject: data['subject']?.toString() ?? '',
      code: data['code']?.toString() ?? '',
    );
  }

  /// `(instanceId, mailboxEmail)` → 本地 `profileId`。认不出来返回空串。
  ///
  /// ## 为什么不能靠内存里的映射
  ///
  /// App 被推送**冷启动**时（用户点了通知栏里那条），进程是刚起来的：
  /// 任何在 [syncAll] 里建的映射都还不存在。而那恰好是最需要它的一刻 ——
  /// 翻不出来就只是「打开 App 落到列表页」，用户点了却没到那封信上。
  ///
  /// ## 为什么不直接返回「唯一那个已登录实例」
  ///
  /// 用户完全可能给同一台服务器加两个账号（两个 profile 共用一个
  /// `instanceId`），那就得靠 `mailboxEmail` 分出是哪一个。这也是唯一的
  /// 可用判据：推送里的 `toEmail` 正是投递到的那个邮箱。
  ///
  /// 三层，从便宜到贵：
  /// 1. `instanceId` 对不上本机配的那个位 → 空串（这条推送不是我们的）；
  /// 2. 只有一个已登录 profile → 直接用它（绝大多数设备就是这个形状）；
  /// 3. 逐个 profile 比邮箱。
  Future<String> resolveProfileId(String instanceId, String mailboxEmail) async {
    if (!isConfigured || instanceId.isEmpty) return '';
    if (instanceId != this.instanceId) return '';

    final profiles = await _readProfiles();
    final loggedIn = profiles.where((p) => p.isLoggedIn).toList(growable: false);
    if (loggedIn.isEmpty) return '';
    if (loggedIn.length == 1) return loggedIn.first.id;

    final target = mailboxEmail.trim().toLowerCase();
    if (target.isEmpty) return '';

    for (final profile in loggedIn) {
      final mailboxes = await _readMailboxes(profile.id);
      for (final mailbox in mailboxes) {
        if (mailbox.email.trim().toLowerCase() == target) return profile.id;
      }
    }
    // 认不出来：返回空串而不是「随便挑一个」。上层会退化成「同步一轮」，
    // 那至少不会把用户送到一个错的实例上。
    return '';
  }

  // ---------------------------------------------------------------- 注册

  /// 保存用户在设置页填的三条值。
  ///
  /// ## 设备号为什么不在参数里
  ///
  /// 它必须以 `<实例位>-` 开头（见 [deviceIdMatchesInstance]），而那是
  /// **本类的内部不变量**，不该由界面负责维持 —— 曾经就是由界面负责的，
  /// 结果生成的是裸 UUID，每一次真实登记都 401（线上实测）。现在唯一
  /// 的写入口在这里：调用方给不出一个坏值。
  ///
  /// [deviceId] 仍然可选，只给测试和「迁移」用；传进来的值对不上新实例位
  /// 就会被重新掷一个。
  ///
  /// ## 换实例位时会先退订旧的
  ///
  /// 旧实例位那边的注册**只有这一刻还找得回来**（注销要同时拿得到旧的
  /// `instanceId`、旧的设备号和旧配对码，写完 prefs 之后前两样就没了）。
  /// 不退订的后果很具体：手机继续收到 A 实例的通知，而 `resolveProfileId`
  /// 在 `instanceId` 对不上时返回空串 —— 用户点开一条**不知道去哪**的通知。
  Future<PushSyncResult> configure({
    required String relayUrl,
    required String instanceId,
    required String pairingCode,
    String? deviceId,
  }) async {
    final nextRelayUrl = relayUrl.trim();
    final nextInstanceId = instanceId.trim();
    final oldInstanceId = _prefs.pushInstanceId;
    final oldDeviceId = _prefs.pushDeviceId;
    final oldRelayUrl = _prefs.pushRelayUrl;

    final switched = oldInstanceId.isNotEmpty && oldInstanceId != nextInstanceId;
    if (switched) {
      await _retireOldRegistration(oldRelayUrl, oldInstanceId, oldDeviceId);
    }

    await _prefs.setPushRelayUrl(nextRelayUrl);
    await _prefs.setPushInstanceId(nextInstanceId);

    // 设备号必须最后算，而且要在新 `instanceId` 落盘**之后** ——
    // `ensureDeviceId()` 是拿 prefs 里的当前实例位来判断的。
    // 它一条逻辑就覆盖了三种情况：空 → 现掷；裸 UUID → 补前缀；
    // 换实例位后前缀对不上 → 重掷（尾段留着会在新位上多出一条注册）。
    final supplied = deviceId?.trim() ?? '';
    if (deviceIdMatchesInstance(supplied, nextInstanceId)) {
      await _prefs.setPushDeviceId(supplied);
    }
    await ensureDeviceId();

    if (pairingCode.trim().isNotEmpty) {
      await _tokens.writePushToken(nextInstanceId, pairingCode.trim());
    }

    return PushSyncResult(
      ok: true,
      message: switched ? '已换到 $nextInstanceId，旧实例位的登记已退订' : '已保存',
    );
  }

  /// 尽力把旧实例位上的这台设备摘掉。
  ///
  /// **绝不抛、绝不阻塞保存**：旧配对码可能已经轮换过（那就 401），
  /// 也可能根本没配过推送。这里失败最多是留一条孤儿注册，而它比
  /// 「用户改不动配置」轻得多。
  Future<void> _retireOldRegistration(
    String relayUrl,
    String instanceId,
    String deviceId,
  ) async {
    if (relayUrl.isEmpty || deviceId.isEmpty) return;
    try {
      final code = await _tokens.readPushToken(instanceId);
      if (code == null) return;
      final removed = await (clientFor(relayUrl) ?? RelayClient(baseUrl: relayUrl)).unregister(
        instanceId: instanceId,
        deviceToken: code,
        deviceId: deviceId,
      );
      debugPrint('推送：换实例位前退订 $instanceId 上的 $removed 条');
    } on Object catch (e) {
      // 连 `AppException` 之外的都兜住：这是顺手做的事，不该有任何
      // 把保存配置搞失败的路径。
      debugPrint('推送：退订旧实例位失败（忽略）：$e');
    }
  }

  /// 把**所有**已登录实例的邮箱登记到中转端。
  ///
  /// 之所以一次全登记（而不是每个实例各自登记）：一个本地 profile 通常只对应
  /// 一个 `instanceId`，但两个 profile 指向同一台服务器时它们共用同一个位 ——
  /// 分开登记会把同一批邮箱重复上报。
  Future<PushSyncResult> syncAll({String reason = ''}) async {
    if (!available) return const PushSyncResult(ok: false, message: '这个平台不支持 FCM 推送');
    if (!enabled) return const PushSyncResult(ok: false, message: '后台推送开关是关着的');
    if (!isConfigured) {
      return const PushSyncResult(ok: false, message: '还没有填推送中转的三条配置');
    }

    final deviceToken = await _tokens.readPushToken(instanceId);
    if (deviceToken == null) {
      return const PushSyncResult(ok: false, message: '缺少配对码');
    }

    final client = _client();
    if (client == null) return const PushSyncResult(ok: false, message: '中转地址不可用');

    // **先修设备号再发请求**：老版本存下来的是裸 UUID，中转端会 401
    // （见 [deviceIdMatchesInstance] 的说明）。这里是唯一一处能自动治好
    // 它的地方 —— 启动时的登记（`NotificationHost._wirePush`）不会经过设置页。
    final deviceId = await ensureDeviceId();

    if (!await initialize()) {
      return PushSyncResult(ok: false, message: _initFailureMessage());
    }

    final profiles = await _readProfiles();
    final loggedIn = profiles.where((p) => p.isLoggedIn).toList(growable: false);
    if (loggedIn.isEmpty) {
      return const PushSyncResult(ok: false, message: '没有已登录的实例');
    }

    final registered = <String>[];
    final failures = <String>[];

    for (final profile in loggedIn) {
      final mailboxes = await _readMailboxes(profile.id);
      for (final mailbox in mailboxes) {
        final email = mailbox.email.trim().toLowerCase();
        if (email.isEmpty) continue;
        try {
          await client.register(
            instanceId: instanceId,
            deviceToken: deviceToken,
            deviceId: deviceId,
            mailboxEmail: email,
            fcmToken: _fcmToken,
            platform: _platformName(),
          );
          registered.add(email);
        } on AppException catch (e) {
          failures.add('$email：${e.userMessage}');
        }
      }
    }

    await _prefs.setPushMailboxes(registered);
    debugPrint('推送：登记 ${registered.length} 个邮箱${reason.isEmpty ? '' : '（$reason）'}');

    if (failures.isEmpty) {
      return PushSyncResult(ok: true, message: '已登记 ${registered.length} 个邮箱');
    }
    return PushSyncResult(
      ok: registered.isNotEmpty,
      message: '登记成功 ${registered.length} 个，失败 ${failures.length} 个：${failures.first}',
    );
  }

  /// 退订：把本机在中转端的注册全部删掉。
  ///
  /// 同样先 [ensureDeviceId]：**注销不校验前缀**（中转端按 `device_id`
  /// 精确匹配），拿一个裸 UUID 去删只会「删成功 0 条」，注册原样留着继续推。
  Future<PushSyncResult> unsubscribe() async {
    if (!isConfigured) return const PushSyncResult(ok: true, message: '本来就没登记');
    final deviceToken = await _tokens.readPushToken(instanceId);
    if (deviceToken == null) return const PushSyncResult(ok: true, message: '本来就没登记');

    try {
      final removed = await (clientFor(relayUrl) ?? RelayClient(baseUrl: relayUrl)).unregister(
        instanceId: instanceId,
        deviceToken: deviceToken,
        deviceId: await ensureDeviceId(),
      );
      await _prefs.setPushMailboxes(const <String>[]);
      return PushSyncResult(ok: true, message: '已退订 $removed 个邮箱');
    } on AppException catch (e) {
      return PushSyncResult(ok: false, message: e.userMessage);
    }
  }

  /// 诊断页 / 设置页用：中转端还记着这台设备的哪些邮箱。
  Future<List<String>> remoteMailboxes() async {
    if (!isConfigured) return const <String>[];
    final deviceToken = await _tokens.readPushToken(instanceId);
    if (deviceToken == null) return const <String>[];
    try {
      return await (clientFor(relayUrl) ?? RelayClient(baseUrl: relayUrl)).devices(
        instanceId: instanceId,
        deviceToken: deviceToken,
        deviceId: await ensureDeviceId(),
      );
    } on AppException {
      return const <String>[];
    }
  }

  /// 配对码（在密钥库里，所以是异步的）。
  ///
  /// 它**同时就是**实例后台要填的 webhook secret，所以设置页必须能把它
  /// 显示出来供复制 —— 用户拿不到它就没法把 webhook 配起来，而这一步
  /// 只能他自己在另一个网站做。
  Future<String?> pairingCode() async {
    if (!isConfigured) return null;
    return _tokens.readPushToken(instanceId);
  }

  /// 自检：拿配对码问中转端「实例后台该怎么填」。
  ///
  /// 之所以要做成一次**主动**的往返，而不是在本地拼一串字符串给用户看：
  /// 地址对不对是个只有中转端知道答案的问题（它知道自己的 `instanceId`
  /// 和路径规则），而用户填错的后果是**静默的** —— 实例那边只有真收到
  /// 外部来信时才会去打 webhook，打不通也只在自己日志里留一行。
  ///
  /// [webhookUrl] 传用户在实例后台里**已经填/准备填**的那个值，
  /// 让中转端顺手比一下路径；传空串就只验配对码。
  Future<RelayVerifyResult> verifyWebhook({String webhookUrl = ''}) async {
    final client = _client();
    if (client == null) {
      throw const NetworkException(detail: '还没有填中转地址和实例位');
    }
    final code = await _tokens.readPushToken(instanceId);
    if (code == null) {
      throw const ApiException(code: 401, message: '还没有配对码');
    }
    return client.verifyWebhook(
      instanceId: instanceId,
      webhookSecret: code,
      webhookUrl: webhookUrl,
    );
  }

  /// 「测试连接」：中转端活着吗、配了 FCM 吗。
  Future<RelayHealth> checkRelay(String url) async {
    final client = RelayClient(baseUrl: url);
    if (!client.isConfigured) throw const NetworkException(detail: '地址是空的');
    return client.health();
  }

  Future<void> dispose() async {
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
    await _foregroundController.close();
  }

  // ---------------------------------------------------------------- 平台

  static bool _detectAvailable() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// 构建里有没有 Firebase 的配置文件。
  ///
  /// 只在移动/桌面平台有意义（Web 上配置在 JS 里，本项目不做 Web）。
  /// **这是运行时的存在性检查**：`Firebase.initializeApp()` 在没有配置时
  /// 会抛，而我们希望在「用户还没建 Firebase 项目」这种最常见的状态下
  /// 静默降级，不是每台设备打一串异常。
  ///
  /// ⚠️ macOS 上**不能**用相对路径查 —— 这里曾经就是这么写的，结果是
  /// 它**永远返回 false**，Mac 上推送于是永远起不来。相对路径是相对
  /// **进程的 cwd** 的：`flutter run` 起时 cwd 是 `mail-app/`（真文件在
  /// `macos/Runner/` 里），双击 `.app` 起时 cwd 是 `/`，两种落点都找不到，
  /// 这个「保险起见的前置检查」反而成了拦路的那一个。
  ///
  /// 真正的落点是**包内的** `<app>.app/Contents/Resources/GoogleService-Info.plist`，
  /// 从 [Platform.resolvedExecutable] 往上退两级就能定位，与 cwd 无关。
  static bool _hasConfigFile() {
    if (kIsWeb) return false;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // Android/iOS 的配置在打包时进资源，运行时没有稳定路径可查，
        // 所以交给 `Firebase.initializeApp()` 自己抛，由调用方兜住。
        return true;
      }
      if (!Platform.isMacOS) return false;
      return _macosPlistCandidates.any((path) => File(path).existsSync());
    } catch (_) {
      // 探测本身出问题时按「有」处理 —— 让 `Firebase.initializeApp()` 去做
      // 唯一权威的判断，而不是在这里替它说「没有」。
      return true;
    }
  }

  /// macOS 上 `GoogleService-Info.plist` 的候选位置，**从最可信的往后排**。
  ///
  /// 第一条是发布与调试共用的真实落点（`Contents/Resources/`，与 cwd 无关）；
  /// 后面几条只是兜底 —— 万一某个工具链把 cwd 设在了工程根或 `macos/` 下。
  static Iterable<String> get _macosPlistCandidates sync* {
    // …/Contents/MacOS/mail_app → …/Contents/Resources/GoogleService-Info.plist
    // 理论上 `resolvedExecutable` 一定是绝对路径，但真取不到分隔符就跳过
    // 这一条（后面几条兜底），不让它抛。
    final exe = Platform.resolvedExecutable;
    final lastSlash = exe.lastIndexOf('/');
    if (lastSlash > 0) {
      final macosDir = exe.substring(0, lastSlash); // …/Contents/MacOS
      final slash = macosDir.lastIndexOf('/');
      if (slash > 0) {
        yield '${macosDir.substring(0, slash)}/Resources/GoogleService-Info.plist';
      }
    }
    yield 'macos/Runner/GoogleService-Info.plist';
    yield 'Runner/GoogleService-Info.plist';
    yield 'GoogleService-Info.plist';
  }

  static String _platformName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }
}

/// 一次登记/退订的结果。**不抛异常** —— 推送失败不该有把 App 弄崩的能力。
@immutable
class PushSyncResult {
  const PushSyncResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

/// [PushService.initialize] 没成功的原因。
///
/// 存在的理由只有一个：`getToken()` 把「权限被拒」「APNs 注册失败」「配置
/// 文件缺失」都收敛成同一个 `null`，而它们**该让用户做的事完全不同**。
/// 曾经这里只有一句「iOS 上通常是通知权限没有允许」，于是在 macOS 上把
/// 「缺 APNs 权利」一路指成了「去开通知权限」—— 用户去系统设置里翻一圈，
/// 那儿根本没有能修好它的开关。
///
/// 与 [PushInitFailure.apnsUnavailable] 对应的是
/// `firebase_messaging` 抛的 `apns-token-not-set`：Apple 平台上，插件的
/// `_APNSTokenCheck` 会在取 FCM token 前先要 APNs token，拿不到就抛这个。
enum PushInitFailure {
  /// 用户把通知权限拒了（`AuthorizationStatus.denied`）。
  permissionDenied,

  /// 权限是允许的，卡在 APNs 注册那一步。macOS 上几乎总是缺
  /// `com.apple.developer.aps-environment` 或带推送的描述文件；
  /// iOS 上多半是构建没带 APS 权利。
  apnsUnavailable,

  /// 这份构建里没有 Firebase 配置文件。
  firebaseConfig,

  /// 其它异常（网络、配置损坏、插件内部错误）—— 细节只在日志里。
  unexpected,
}
