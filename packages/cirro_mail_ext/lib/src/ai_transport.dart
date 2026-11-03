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
  const AiChannelState({required this.usable, required this.detail});

  /// 这一次能不能调用。
  final bool usable;

  /// 一句给人看的话（失败时就是失败原因）。空串表示「没有要补充的」。
  final String detail;
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
