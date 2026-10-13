import 'ai_provider.dart';

/// 用户的 AI 配置。**API Key 不在这个对象里** —— 它单独走 secure storage，
/// 这个对象只带「有没有配过 Key」这个布尔，于是它可以用 `==` 比较、可以进
/// Riverpod 状态、可以被打进诊断日志而不泄漏任何东西。
///
/// 「端点」由三样东西描述：**地址（base）+ 协议格式 + 模型名**。地址是主字段，
/// 不再是「只对自定义厂商有意义」的可选值 —— 换中转、换自建推理服务都只是改它。
class AiSettings {
  const AiSettings({
    this.apiFormat = AiApiFormat.openai,
    this.model = '',
    this.baseUrl = openaiDefaultBase,
    this.hasApiKey = false,
    this.inlineContinuationEnabled = false,
    this.preflightEnabled = true,
    this.subjectSuggestEnabled = true,
    this.polishEnabled = true,
    this.mailSuggestEnabled = true,
    this.dailyCallLimit = 200,
  });

  final AiApiFormat apiFormat;
  final String model;

  /// 接口地址（base），不含 `/chat/completions` 这类路径 —— 路径由 [apiFormat] 拼。
  final String baseUrl;

  final bool hasApiKey;

  /// 行内续写默认**关**：它每次停笔都花钱，且误触有代价（spec §4.3③）。
  final bool inlineContinuationEnabled;

  /// 发送前检查默认**开**：它里面那条「声明了附件却没附件」是纯本地检查，
  /// 零成本、价值最高（spec §4.3④）。
  final bool preflightEnabled;

  /// 主题栏那颗内联的「起标题」图标要不要出现。默认开 —— 它是**点一下才花钱**
  /// 的动作，不像行内续写那样每次停笔都调用。
  final bool subjectSuggestEnabled;

  /// 右上角那颗「润色全文」要不要出现。默认开，理由同上。
  ///
  /// 与 [subjectSuggestEnabled] **拆成两个开关**（而不是共用一个「AI 助手」）：
  /// 两件事的花费与误点代价完全不同 —— 起标题只改主题栏、一键就能改回来；
  /// 润色换掉的是整篇正文。
  final bool polishEnabled;

  /// 列表行菜单与详情页顶栏那个「AI 建议」入口开不开（spec §8.3 第 3 条）。
  ///
  /// 默认**开**：它不花钱（用户真点了面板才会调模型），而「读一封邮件时有人
  /// 告诉你该做什么」正是这个功能的价值所在。关掉它的人通常是觉得列表菜单
  /// 里多一项碍事，不是想省调用。
  final bool mailSuggestEnabled;

  /// 每次调用都花用户自己的 token，给一个软上限（只提示，不硬拦）。
  final int dailyCallLimit;

  static const String openaiDefaultBase = AiProvider.openaiDefaultBase;
  static const String anthropicDefaultBase = AiProvider.anthropicDefaultBase;

  /// New API 是**空串**：自建网关没有普适地址，给一个假地址比不给更糟。
  static const String newapiDefaultBase = AiProvider.newapiDefaultBase;

  /// 切格式时该填的默认地址（地址为空、或正好等于另一格式的默认值时用）。
  static String defaultBaseFor(AiApiFormat format) => switch (format) {
        AiApiFormat.openai => openaiDefaultBase,
        AiApiFormat.anthropic => anthropicDefaultBase,
        // 空串是「这一档没有默认地址」的表示，调用方（`_baseAfterFormatSwitch`）
        // 据此**一个字都不动** —— 让用户填自己的网关，而不是把地址清空。
        AiApiFormat.newapi => newapiDefaultBase,
      };

  /// 能不能用：有 Key、有地址、有模型。以前那条「只有自定义厂商才要地址」的
  /// 特判没有了 —— 地址现在是所有人都要填的。
  bool get isUsable =>
      hasApiKey && baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  /// 能不能**问端点要东西**：有 Key、有地址。**刻意不含模型名** —— 「拉取模型
  /// 列表」那件事本来就是用来**拿到**模型名的，把 [isUsable] 第三条也摁上去
  /// 等于锁上门再让用户找钥匙：界面上按钮明明亮着（它只认地址 + Key），请求却
  /// 在 `AiService` 里被拦下，回一句「还没有配置 AI」。
  bool get hasEndpoint => hasApiKey && baseUrl.trim().isNotEmpty;

  AiProvider toProvider() =>
      AiProvider(format: apiFormat, model: model.trim(), baseUrl: baseUrl.trim());

  AiSettings copyWith({
    AiApiFormat? apiFormat,
    String? model,
    String? baseUrl,
    bool? hasApiKey,
    bool? inlineContinuationEnabled,
    bool? preflightEnabled,
    bool? subjectSuggestEnabled,
    bool? polishEnabled,
    bool? mailSuggestEnabled,
    int? dailyCallLimit,
  }) =>
      AiSettings(
        apiFormat: apiFormat ?? this.apiFormat,
        model: model ?? this.model,
        baseUrl: baseUrl ?? this.baseUrl,
        hasApiKey: hasApiKey ?? this.hasApiKey,
        inlineContinuationEnabled:
            inlineContinuationEnabled ?? this.inlineContinuationEnabled,
        preflightEnabled: preflightEnabled ?? this.preflightEnabled,
        subjectSuggestEnabled: subjectSuggestEnabled ?? this.subjectSuggestEnabled,
        polishEnabled: polishEnabled ?? this.polishEnabled,
        mailSuggestEnabled: mailSuggestEnabled ?? this.mailSuggestEnabled,
        dailyCallLimit: dailyCallLimit ?? this.dailyCallLimit,
      );

  @override
  bool operator ==(Object other) =>
      other is AiSettings &&
      other.apiFormat == apiFormat &&
      other.model == model &&
      other.baseUrl == baseUrl &&
      other.hasApiKey == hasApiKey &&
      other.inlineContinuationEnabled == inlineContinuationEnabled &&
      other.preflightEnabled == preflightEnabled &&
      other.subjectSuggestEnabled == subjectSuggestEnabled &&
      other.polishEnabled == polishEnabled &&
      other.mailSuggestEnabled == mailSuggestEnabled &&
      other.dailyCallLimit == dailyCallLimit;

  @override
  int get hashCode => Object.hash(
      apiFormat,
      model,
      baseUrl,
      hasApiKey,
      inlineContinuationEnabled,
      preflightEnabled,
      subjectSuggestEnabled,
      polishEnabled,
      mailSuggestEnabled,
      dailyCallLimit);

  /// 诊断用：**绝不能**包含 Key（这个对象里本来就没有，注释在这里把约定钉死）。
  @override
  String toString() =>
      'AiSettings(${apiFormat.name}, model=$model, baseUrl=$baseUrl, '
      'hasKey=$hasApiKey, inline=$inlineContinuationEnabled, '
      'preflight=$preflightEnabled, subject=$subjectSuggestEnabled, '
      'polish=$polishEnabled, '
      'suggest=$mailSuggestEnabled)';
}
