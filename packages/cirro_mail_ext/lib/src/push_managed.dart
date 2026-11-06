import 'package:flutter/foundation.dart';

/// **托管推送配置**：由扩展在运行时取回、解密后交给核心的三条值 + 订阅凭证。
///
/// 与 [PushDefaults]（编译进包里的常量）的区别是**什么时候到手**：那个在
/// 构建期就定下了，这个每次启动 / 订阅续期由下发方给，只活在内存里。所以：
///
/// - 核心**不把它写进 prefs / 钥匙串** —— 只有手填值才落盘；
/// - 它可能中途消失（订阅到期、退登、中转端判定凭证失效），核心因此每次
///   推送操作前问一次扩展（30 秒节流，见 `AppExtension.managedPushConfig`），
///   问到就用、问不到就回落手填值。
///
/// 三条值的语义与手填版完全一致（地址 / 实例位 / 设备配对码），只是来源
/// 不同。**设备配对码仍然是 `deviceCode`，不是 `webhookSecret`** —— 后者绝不
/// 从这条接缝进来（见 [PushDefaults] 的注释）。
@immutable
class ManagedPushConfig {
  const ManagedPushConfig({
    required this.relayUrl,
    required this.instanceId,
    required this.deviceCode,
    this.entitlement = '',
    this.expiresAt,
  });

  /// 中转端地址，形如 `https://push.example.com`（不带尾斜杠）。
  final String relayUrl;

  /// 中转端上的实例位 id，形如 `inst-<hex>`。
  final String instanceId;

  /// 该实例位的**设备配对码**（中转端的 `device_code`）。
  final String deviceCode;

  /// 订阅凭证，原样放进 `X-Push-Entitlement` 请求头（register / unregister /
  /// devices / events 四条）。空串 = 这条链路上不带这个头 —— 开源版的中转位
  /// 不校验它，行为因此与没有这条接缝时逐字相同。
  final String entitlement;

  /// 这份配置的到期时间（由下发方给出）。null = 不知道。
  ///
  /// 核心**不拿它做判定**：能不能用由中转端说了算（它验凭证里的 `exp`），
  /// 这里只是让扩展自己决定什么时候该重新取。
  final DateTime? expiresAt;

  /// 三条值齐了没有 —— 缺任何一条都等于「没有托管配置」，核心回落手填值。
  bool get usable =>
      relayUrl.trim().isNotEmpty &&
      instanceId.trim().isNotEmpty &&
      deviceCode.trim().isNotEmpty;
}

/// 核心「推送操作」的门面，交给扩展去画自己的设置页面板。
///
/// ## 为什么要有这层门面
///
/// 扩展需要「拨开关 / 登记 / 退订 / 查状态」这几件事，但它**不该**依赖核心的
/// `PushService`：那是核心内部实现，签名随核心演进。把这几件事收成一个
/// 只读 + 少量动作的接口之后，扩展只认 [PushFacade]，核心怎么改都行。
///
/// 实现由核心提供（`lib/features/notifications/push_facade.dart`）。扩展
/// 只需要**调**它，不需要**实现**它。
///
/// ## 每个方法都不抛
///
/// 与 `PushService` 同一条纪律：推送失败不该有把 App 弄崩的能力。动作类的
/// 失败通过 [PushActionResult] 回来，状态类读不到就按「没有」显示。
abstract class PushFacade {
  /// 用户有没有把「后台推送」这个开关打开。
  ///
  /// 与「配没配」是两件事：配置齐了也可以关着（省电、暂时不想收）。关着时
  /// 不该在启动时去登记。
  bool get enabled;

  /// 现在这台设备的样子：平台支不支持、配没配、设备号对不对、中转端记着
  /// 哪些邮箱。
  Future<PushStatus> status();

  /// 拨总开关。**开 = 顺手登记一次，关 = 顺手退订** —— 与核心自带向导里
  /// 那个开关的语义一致（关掉却还留着注册，用户会以为「我明明关了」）。
  Future<PushActionResult> setEnabled(bool value);

  /// 把本机所有已登录实例的邮箱登记到中转端。
  Future<PushActionResult> register();

  /// 退订这台设备在中转端的全部注册。
  Future<PushActionResult> unregister();

  /// 一次问清整条链路：中转可达、FCM 配了、凭证与地址都对。
  Future<PushActionResult> checkChain();

  /// 清掉**手填**的三条值：prefs 里的中转地址与实例位、钥匙串里这个实例位
  /// 的配对码（以及 prefs 里那份「已登记邮箱」的旧记录）。
  ///
  /// 托管配置接手、或者它失效时用：不清的话，回退到核心自带向导会把上一份
  /// 手填值当成「用户自己填的」原样显示出来。
  Future<void> clearManualConfig();
}

/// 这台设备当前的样子。**三件互相独立的事**分开报（与 `PushService` 的
/// 分层一致）：平台能不能用、配置齐不齐、中转端认不认。
@immutable
class PushStatus {
  const PushStatus({
    required this.available,
    required this.hasFirebaseConfig,
    required this.configured,
    required this.deviceIdValid,
    required this.deviceId,
    this.mailboxes = const <String>[],
  });

  /// 这个平台有没有 FCM 实现（Linux / Windows 没有，只能靠轮询）。
  final bool available;

  /// 这份构建里有没有 Firebase 配置文件。
  final bool hasFirebaseConfig;

  /// 三条值齐了没有（托管配置也算数）。
  final bool configured;

  /// 设备号有没有带对的实例位前缀 —— 对不上时中转端会 401。
  final bool deviceIdValid;

  /// 本机在中转端的设备号（不是秘密，就是本机生成的带前缀的那个值）。
  final String deviceId;

  /// 中转端最近一次回执里「这台设备登记了哪些邮箱」。
  final List<String> mailboxes;
}

/// 一次推送动作的结果。**不抛异常** —— 推送失败不该有把 App 弄崩的能力。
@immutable
class PushActionResult {
  const PushActionResult({
    required this.ok,
    required this.message,
    this.subscriptionRequired = false,
    this.chain,
  });

  final bool ok;

  /// 给用户看的一句话（已本地化或至少已是人话）。
  final String message;

  /// 中转端判定**订阅凭证失效**（`code=401` 且 `data.reason` 以
  /// `entitlement_` 开头）。
  ///
  /// 为 true 时扩展该做的事很具体：清掉托管配置（密文与内存缓存），把设置页
  /// 退回核心自带向导 —— 用户得自己填三条值才能继续收推送。
  final bool subscriptionRequired;

  /// [PushFacade.checkChain] 的明细；其它动作恒为 null。
  ///
  /// 分开给是为了让扩展能自己组织文案（哪一项没过、最近一次事件是什么时候），
  /// 不必去解析 [message] 那句人话。
  final PushChainCheck? chain;
}

/// 一次链路检查的完整结论。
///
/// 几项事实各自独立，**不要合成一个 bool**：「中转连不上」「中转端没配 FCM」
/// 「配对码不对」「地址路径不对」指向四种完全不同的修法，合成一句就变成了
/// 用户在四件事里瞎猜。
@immutable
class PushChainCheck {
  const PushChainCheck({
    required this.relayReachable,
    required this.fcmConfigured,
    required this.codeOk,
    required this.urlOk,
    required this.lastEventAt,
    required this.message,
  });

  /// 中转端的 `/health` 问通了。
  final bool relayReachable;

  /// 中转端配了 FCM 服务账号。**没配的话前面全对也投不出去**。
  final bool fcmConfigured;

  /// 送过去的设备配对码对不对。null = 这次没送 / 中转端没回。
  final bool? codeOk;

  /// 送过去的 webhook 地址路径对不对。null = 这次没送地址。
  final bool? urlOk;

  /// 中转端最近一次真的收到 webhook 的时间（ISO 串）。null = 从没收到过。
  ///
  /// 「静态检查全过」与「链路真的通」是两件事：全都对但从未收到过，说明
  /// 用户还没把配置存进实例后台（或者实例那边开关没开）。
  final String? lastEventAt;

  /// 折好的一句话。
  final String message;
}
