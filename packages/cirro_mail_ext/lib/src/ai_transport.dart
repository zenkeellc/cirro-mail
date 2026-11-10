/// 一键 AI 能力的**托管通道**接缝。
///
/// 核心的 AI（改写 / 成文 / 续写 / 标题 / 检查 / 回复建议 / 邮件建议）默认走
/// 用户自己填的端点与 Key（BYOK）。扩展可以实现 [AiTransport]，让这七项能力
/// 改走**扩展自己的通道**——核心只把「要做什么」翻译成 [AiCall] 交出去，拿回
/// 一段文本增量，其余（认证、计费、余额、重试）全部留在实现方。
///
/// ## 核心只认文本
///
/// [AiTransport.run] **只向核心暴露文本增量**。实现方自己的元事件（余额、
/// 结算、诊断、错误码）在它的内部消化掉；失败一律转成
/// [AiTransportException]，[AiTransportException.message] 是**给人看的一句
/// 话**，由实现方用用户当前的语言给，核心原样显示 —— 公开仓库的 ARB 里因此
/// 永远不需要出现实现方那边的概念（订阅、积分……）。
///
/// ## 空注册表 = 公开版既有行为
///
/// 核心只在 `AppExtension.aiTransport` 非 null 时才走这条路。公开版没有实现
/// 方，于是 `AiService` 仍然走 BYOK 那一条，设置页也不会多出「通道」那一行。
/// 这是「可选的商业功能」那条规矩在 AI 上的落点，`ai_transport_gate_test.dart`
/// 钉着它。
///
/// ## 这一步刻意不做的
///
/// - **不给取消方法**：核心的 [Stream] 订阅被取消就是取消（实现方在
///   `StreamController.onCancel` 里收尾即可）。多一个 `cancel()` 参数会让
///   「用户点了停止」有两条语义不同的路径。
/// - **不给流式以外的形状**：所有七项能力在核心眼里都是「吐文本」，非流式
///   实现自己包一个单事件流即可 —— 核心不需要知道两种形态的差别。
/// - **不暴露认证 / 计费 / 余额**：那是实现方的内部状态。设置页要显示什么，
///   由实现方自己的 `settingsSections` 一栏负责；核心的「通道」行只显示
///   [AiTransport.channelLabel] 与 [AiChannelState.detail]。
library;

import 'package:flutter/widgets.dart' show BuildContext;

/// 一次托管调用：**任务 id + 已翻译好的入参**。
///
/// [task] 是稳定字符串码（`rewrite` / `draft` / `continuation` / `subject` /
/// `review` / `reply_suggestions` / `suggest`），[input] 的字段名与类型由核心
/// 侧 `ai_task.dart` 按任务逐字给出（与服务端 Schema 一一对应）。实现方**只该
/// 转手**，不要在中间改名或补字段 —— 那正是「两边各写一份、然后漂移」的起点。
class AiCall {
  const AiCall({required this.task, required this.input});

  /// 任务 id（稳定码，不是给人看的名字）。
  final String task;

  /// 这个任务的入参。值的类型只会有 `String` / `int` / `List<String>`。
  final Map<String, Object?> input;
}

/// 通道状态的语气。核心据它选语义色与图标，**不参与**任何可用性判断。
///
/// 为什么要有它：核心只拿得到 [AiChannelState.usable] 这个布尔，而「额度快
/// 用完」与「订阅已到期」都是 `usable == false` —— 前者该是琥珀、后者该是红。
/// 语气由实现方给（它才知道是哪种不可用），核心只做映射；文字与图标始终同时
/// 出现，颜色不是唯一的信息载体。
enum AiChannelTone { neutral, positive, warning, critical }

/// 通道卡上的一个动作：一句文案 + 点下去做什么。
///
/// 抽成对象而不是「核心自己按状态 switch」的理由：动作的文案与落点都是商业
/// 实现方的（去订阅 / 续订 / 重新登录），公开仓库既不该写这些字，也不该知道
/// 「该导航到哪一页」。核心只负责画一颗按钮、调 [onTap]、把返回的那句话原样
/// 弹出来 —— 只有实现方知道刚才发生了什么、该说哪一句。
///
/// ## [onTap] 必须拿到 `BuildContext`
///
/// 动作的落点通常是**应用内**的页面（登录页 / 账号页 / 收银台弹层），这些都要
/// 一个真实的 `BuildContext` 才能 `Navigator.push` / `showDialog`。早期签名是
/// `Future<String?> Function()`（无参），实现方拿不到 context，就只剩两条烂路：
/// 打开外部浏览器，或者让核心替它记住一个全局 context —— 前者把应用内流程降级
/// 成网页兜底，后者是持有过期的 BuildContext。核心现在把点击那一帧的
/// `BuildContext` 直接交给实现方（由按钮所在 widget 传入），实现方自己决定
/// 推页面、弹层还是开浏览器。
class AiChannelAction {
  const AiChannelAction({required this.label, required this.onTap});

  /// 按钮上的字（实现方给，用用户当前的语言）。
  final String label;

  /// 点下去做什么。返回**要原样弹给用户的一句话**（null = 不弹）。
  ///
  /// [BuildContext] 是触发点击那颗按钮的 widget 的 context：还在树上、属于
  /// 当前 `Navigator`。实现方只在 `onTap` 内部使用它，**不要**把它存下来。
  final Future<String?> Function(BuildContext context) onTap;
}

/// 通道眼下的可用性与一句给人看的话。
///
/// [usable] 是**这一次**能不能调用的判断（没激活、到期、余额不足、离线……
/// 都由实现方自己翻译成 false）。[detail] 是跟着显示的那句话：
///
/// - `usable == true` 时通常是状态摘要（例如余额、到期日），可以是空串；
/// - `usable == false` 时应当是**一句能照着办的话**（「设备授权失效，请重新
///   激活」），核心把它原样显示在提示里，不再拼任何文案。
///
/// 核心**不缓存**它：每次要判断就调一次 [AiTransport.state]，实现方自己决定
/// 缓存与刷新策略。
class AiChannelState {
  const AiChannelState({
    required this.usable,
    required this.detail,
    this.tone = AiChannelTone.neutral,
    this.action,
    this.chipLabel,
  });

  /// 这一次能不能调用。
  final bool usable;

  /// 一句给人看的话（失败时就是失败原因）。空串表示「没有要补充的」。
  final String detail;

  /// 状态语气：只用来选语义色，不参与「能不能用」的判断。
  ///
  /// 缺省 [AiChannelTone.neutral] —— 老实现方不改代码也编得过，外观与今天
  /// 一致（核心此前只有「可用 / 不可用」两档颜色）。
  final AiChannelTone tone;

  /// 这张卡上的动作；null = 当前状态没有动作可给。
  ///
  /// 挂在 state 上而不是 transport 上：可用性变了动作也该跟着变
  /// （到期 → 续订，授权失效 → 重新登录，额度耗尽 → 续订）。
  ///
  /// **不要在这里提供「改用自带 Key / 自己的 AI」这类切换动作**：来源选择
  /// 归核心的「AI 来源」单选（立即生效、落盘在核心 prefs），实现方再放一颗
  /// 切换按钮就成了第二个语义不同的开关（还要靠重启才生效）。
  final AiChannelAction? action;

  /// 状态胶囊上的**短标签**（例如「积分用完」「已到期」「N 天后到期」）。
  ///
  /// null = 核心只用两档通用词（可用 / 暂不可用）。给具体原因的文字只能由
  /// 实现方写 —— 它才知道这次不可用是额度、到期还是设备被吊销；核心按
  /// [tone] 上色、按这一句说事，两处永远一致。
  final String? chipLabel;
}

/// 托管通道的一次失败。
///
/// [code] 是**稳定字符串码**，给程序判断用（`unauthorized`、
/// `insufficient_credits`、`rate_limited`、`upstream_error`……由实现方与它的
/// 服务端约定）；[message] 是**给人看的一句话**，由实现方给，核心原样显示。
///
/// ## toString 刻意不带 message
///
/// [message] 可能含实现方从服务端原样带下来的文字；任何字符串化
/// （`debugPrint('$e')`、日志、crash reporter）都会走 `toString`。与其赌那层
/// 文字里没有敏感信息，不如让 `toString` 只留 [code] —— 要显示文案的地方显式
/// 取 [message]。
///
/// [code] 只给程序看，**不该**出现在给用户的文案里（用户看不懂
/// `insufficient_credits`）。
class AiTransportException implements Exception {
  const AiTransportException(this.code, this.message);

  /// 稳定错误码。
  final String code;

  /// 给人看的一句话（核心原样显示）。
  final String message;

  @override
  String toString() => 'AiTransportException($code)';
}

/// 一项 AI 能力的托管实现。
///
/// 实现方只依赖 `cirro_mail_ext`，不依赖核心 App —— 由
/// `AppExtension.aiTransport` 挂进注册表，核心按需取用。同一个进程里**至多
/// 一个**实现生效（注册表按注册顺序取第一个非 null）。
abstract class AiTransport {
  /// 设置页「通道」那一行显示的名字。
  ///
  /// **由实现方给**：公开仓库不写任何产品名/商业文案，核心只负责把它原样
  /// 显示出来。可以是产品名，也可以是这一档的名字 —— 是实现方的营销口径，
  /// 不是核心的。
  String get channelLabel;

  /// AI 输出处的**来源署名**（例如「订阅通道」）。null = 不署名。
  ///
  /// 必须是**同步 getter**：面板抬头在 `build` 里要立刻拿到它，不能等
  /// [state]（那是网络/读盘）。公开版（没有实现方）恒为 null，于是所有
  /// 面板逐像素不变 —— 这条接缝在空注册表下等于不存在。
  ///
  /// 只在**托管通道**生效：BYOK 是用户自己的端点，「署名」在那里等于给公开
  /// 版加商业概念，越界了。
  String? get sourceLabel => null;

  /// 眼下的可用性与一句给人看的话。核心在每次调用前问它一次。
  ///
  /// **不要抛异常**：不可用是正常状态，用 `AiChannelState(usable: false,
  /// detail: …)` 表达。核心对抛出来的异常只会兜底成一句通用提示。
  Future<AiChannelState> state();

  /// 跑一次调用，**只吐文本增量**。
  ///
  /// - 每个元素是**新增**的一段文本（核心负责拼接），不是整段结果；
  /// - 没有内容可吐时要正常关闭流，**不要**吐空串（核心会忽略空串）；
  /// - 失败：流开始前就失败可以直接抛 [AiTransportException]（核心把它变成
  ///   「没开始」的提示）；开始之后失败则往流上 `addError` 一个
  ///   [AiTransportException]（核心把它变成这次生成的错误文案）；
  /// - 取消：监听者 `cancel()` 订阅就是用户点了停止，实现方应当停掉上游请求
  ///   并正常收尾（**不要**把取消当成错误上报）。
  Stream<String> run(AiCall call);
}
