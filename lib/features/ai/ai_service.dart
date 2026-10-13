import 'ai_client.dart';
import 'ai_prompts.dart';
import 'ai_provider.dart';
import 'ai_settings.dart';
import 'ai_settings_store.dart';

/// 一次 AI 调用的结果，或者「没法调用」的原因。
///
/// 之所以不用异常表示「没配 Key」：那是**预期内的正常状态**（开箱就没有），
/// 界面要拿它去显示一句「去设置里填 Key」，而不是弹一个错误框。
sealed class AiStart {
  const AiStart();
}

/// 开始了。[stream] 拿增量、[done] 拿完整结果。
class AiStarted extends AiStart {
  const AiStarted(this.stream);
  final AiStream stream;
}

/// 没开始。[reason] 是要显示给用户的一句话。
class AiNotStarted extends AiStart {
  const AiNotStarted(this.reason);
  final String reason;
}

/// 拉模型列表的结果。
///
/// **[AiModelsOk] 允许带空列表**：端点回了 200 但一条名字都抠不出来，那是
/// 「这个端点没有模型列表」，不是失败 —— 界面照着两种文案分开说。只有网络错、
/// 非 2xx、响应不可解析这几种才落到 [AiModelsFailed]。
sealed class AiModelsResult {
  const AiModelsResult();
}

class AiModelsOk extends AiModelsResult {
  const AiModelsOk(this.models);
  final List<String> models;
}

class AiModelsFailed extends AiModelsResult {
  const AiModelsFailed(this.message);
  final String message;
}

/// 「测试连接」的结果。
sealed class AiTestResult {
  const AiTestResult();
}

class AiTestOk extends AiTestResult {
  const AiTestOk(this.chars);

  /// 模型这次回了几个字。**只是给用户一个「确实通了」的实感** —— 成功判据是
  /// 「请求成功返回」，不是「字数 ≤ maxTokens」（不少模型不听话）。
  final int chars;
}

class AiTestFailed extends AiTestResult {
  const AiTestFailed(this.message);
  final String message;
}

/// 四项能力与底座之间的那一层：**组装 prompt、取 Key、记一次调用**。
///
/// 它没有网络、没有 widget，只有「把这几样东西串起来」的顺序 —— 而顺序恰恰
/// 是最容易出错的地方（先记次数还是先发请求？Key 读失败了怎么办？）。所以它
/// 全部可单测：注入假传输，断言「发出去的请求体里有该有的东西、没有不该有的
/// 东西」。
class AiService {
  // 计划原文的字段名是私有的 `_store`/`_usage`，而构造参数名必须是公开的
  // （测试按名字传参）—— 两者不能合并成 `this._store` 这个 initializing
  // formal，所以这里只有这两处与 lint 偏好不同（与 `AiSettingsStore` 同）。
  AiService({
    required AiSettingsStore store,
    required AiUsageCounter usage,
    AiClient? client,
  })
      // ignore: prefer_initializing_formals
      : _store = store,
        // ignore: prefer_initializing_formals
        _usage = usage,
        _client = client ?? AiClient();

  final AiSettingsStore _store;
  final AiUsageCounter _usage;
  final AiClient _client;

  /// 没配好时那句给人看的话。**四处引用共用同一句话**（`_start` 里两处：可用性
  /// 检查与钥匙串降级各一，四项能力都走它；`listModels` 与 `testConnection` 各
  /// 一处），改了文案不会有人漏掉。
  static const String notConfiguredMessage =
      '还没有配置 AI —— 去「设置 → AI」里填上服务商、接口地址与 API Key';

  /// 四项能力的**输出上限**（请求体里的 `max_tokens`）。
  ///
  /// 为什么统一给到 1 万，而不是「按任务给一个刚好的数」：
  ///
  /// - **预算是「上限」不是「用量」**：模型写完了就停（`finish_reason: "stop"`），
  ///   给多少都不会让它多写。预算真正决定的只有「会不会被砍断」—— 按任务给紧巴巴
  ///   的数（改写 1024、续写与标题 256、检查 512）省不下钱，代价却是频繁被砍断。
  /// - **实测代价有多大**：网关上的推理模型思考与正文共用这个预算，一次「润色」
  ///   的思考就要 300–1500 个 token。旧预算下十个真实样本里有**两成**的改写
  ///   正文一个字都没产生（思考吃光预算、`finish_reason: "length"`），用户看到的
  ///   就是「AI 没有返回内容，请重试」。
  ///
  /// 请求里同时带着 `thinking: {type: "disabled"}`（见 [AiProvider.body]）——
  /// 那是首选的那道锁，这个数只是**兜底**：不是所有端点都认那个字段，认不了的
  /// 照旧会思考，此时宽预算就是唯一的退路。
  static const int _maxOutputTokens = 10000;

  /// 「测试连接」那一次**探针**请求的输出上限。
  ///
  /// **刻意不跟 [_maxOutputTokens] 一起抬到 1 万**：探针要的是「快」，而它走
  /// 非流式 —— 端点不认 `thinking: {type: "disabled"}` 时给多大预算它就能思考
  /// 多久，用户点一下得干等着。给 256 而不是「越小越好」的理由见
  /// [testConnection] 的注释（推理模型要先花预算思考，太小时 `content` 必然是
  /// 空串）；而**通过判据本来就不要求可见文本**（只回思考也算通，见
  /// [AiProvider.isCompletionResponse]），所以这里不需要那么宽。
  static const int _probeMaxTokens = 256;

  /// 每日上限到了。**软上限**：只提示，调用照样发（spec §4.4）。
  bool overDailyLimit(AiSettings settings) =>
      !_usage.canCall(settings.dailyCallLimit);

  /// 今天已经调了几次（设置页显示用）。
  int get usedToday => _usage.usedToday;

  /// ① 选中即改（也是「整篇润色」走的那一条 —— 它只是选区等于全文）。
  Future<AiStart> rewrite({
    required String selection,
    required RewriteTone tone,
    String? extraInstruction,
  }) =>
      _start(
        maxTokens: _maxOutputTokens,
        build: (settings) => AiPrompts.rewrite(
          selection: selection,
          tone: tone,
          extraInstruction: extraInstruction,
        ),
        temperature: 0.4,
      );

  /// ② 要点成文。
  Future<AiStart> draft({
    required String points,
    required RewriteTone tone,
    required DraftLength length,
    String? subject,
    String? recipient,
  }) =>
      _start(
        maxTokens: _maxOutputTokens,
        build: (settings) => AiPrompts.draft(
          points: points,
          tone: tone,
          length: length,
          subject: subject,
          recipient: recipient,
        ),
      );

  /// ③ 行内续写。**输出很短**（prompt 明说一两句），但预算照样给
  /// [_maxOutputTokens] —— 见那里的注释：预算是上限不是用量，给少了只会让
  /// 思考把它吃光、连那一句都产不出来。真续多了由幽灵浮层自己封行数。
  Future<AiStart> continuation({
    required String context,
    String? subject,
  }) =>
      _start(
        maxTokens: _maxOutputTokens,
        build: (settings) => AiPrompts.continuation(
          context: context,
          subject: subject,
        ),
        temperature: 0.3,
      );

  /// ④a 标题生成。**只要一个**（`AiPrompts.subject`），[current] 是主题栏
  /// 里已有的字，有就带上当参考。
  Future<AiStart> subject({
    required String body,
    String? current,
  }) =>
      _start(
        maxTokens: _maxOutputTokens,
        build: (settings) => AiPrompts.subject(body: body, current: current),
      );

  /// ④b 发送前检查的**模型那一半**。本地那一半在 `preflight.dart`，
  /// 不需要 Key —— 所以「没配 Key」时这一项仍然可用（这是刻意的）。
  Future<AiStart> review({
    required String subject,
    required String body,
    required int attachmentCount,
  }) =>
      _start(
        maxTokens: _maxOutputTokens,
        build: (settings) => AiPrompts.preflightReview(
          subject: subject,
          body: body,
          attachmentCount: attachmentCount,
        ),
        temperature: 0.2,
      );

  /// ⑤ 回复建议。**温度比改写高一点**：三个候选要有区别，`0.7` 那张
  /// 「同一句话换个说法」的档在三个候选之间会挤得很近，用户看到的
  /// 是三条几乎一样的话。`0.9` 仍然在可控范围里（回复开头本身很短，
  /// 跑偏的代价小）。
  Future<AiStart> replySuggestions({
    required String incoming,
    int count = 3,
  }) =>
      _start(
        maxTokens: _maxOutputTokens,
        build: (settings) =>
            AiPrompts.replySuggestions(incoming: incoming, count: count),
        temperature: 0.9,
      );

  /// ⑥ AI 邮件建议（spec §3）。读一封别人发来的信，从**固定的动作池**里
  /// 挑出该做的事并排序。
  ///
  /// 温度 `0.3`：这一路的输出**要被程序解析并执行**，不是给人读的文本 ——
  /// 同一封信跑两次得到不同的动作列表，用户会以为界面在随机。低温度不够
  /// 保证确定性（模型本来就不可复现），但它把这个功能的「建议」属性压到
  /// 一个稳定的位置。
  ///
  /// [actionIds] 是**已按当前状态过滤过**的池子（`suggestActionPool`），
  /// 解析器后面会用同一份当白名单 —— 传进来的必须是同一个列表，否则会
  /// 出现「prompt 里说了、解析器不认」的漂移。
  Future<AiStart> suggest({
    required String input,
    required List<String> actionIds,
  }) =>
      _start(
        maxTokens: _maxOutputTokens,
        build: (settings) =>
            AiPrompts.suggest(input: input, actionIds: actionIds),
        temperature: 0.3,
        system: _suggestSystem,
      );

  /// 拉可用的模型列表。**不走每日计数** —— 它是配置动作、不生成内容。
  ///
  /// 门槛只有「地址 + Key」（[AiSettings.hasEndpoint]），**刻意不要模型名**：
  /// 这一项存在的意义就是**拿到**模型名。用 [AiSettings.isUsable] 去卡会让
  /// 设置页那颗亮着的「拉取」按钮点了只回一句「还没有配置 AI」—— 用户明明
  /// 刚填完地址和 Key。
  Future<AiModelsResult> listModels() async {
    final ready = await _ready(needModel: false);
    if (ready == null) return const AiModelsFailed(notConfiguredMessage);
    final (settings, key) = ready;
    final provider = settings.toProvider();
    try {
      final body = await _client.request(
        method: 'GET',
        // 非流式：不要 `accept: text/event-stream`。
        headers: provider.headers(key, sse: false),
        url: provider.modelsEndpoint,
      );
      return AiModelsOk(provider.parseModels(body));
    } catch (error) {
      return AiModelsFailed(_message(error, provider, key));
    }
  }

  /// 试一次真实生成（**不是**拉列表）。列表拉得到不代表模型名是对的 ——
  /// 有些端点对任何 `…/models` 都回一份全量列表，而用户点「测试连接」想知道
  /// 的恰恰是「这个名字能不能用」。
  ///
  /// 走**非流式**（`stream: false`）：只等一小段 JSON 回来，不必拆 SSE。
  ///
  /// `maxTokens` 给 [_probeMaxTokens] 而不是「越小越好」：**推理模型要先花预算
  /// 思考**，给 8 个 token 时它必然把预算全用在思考上、`content` 是空串
  /// （实测：8 / 16 / 32 一律截断）。给够之后才能拿到可见文本 —— 也就才能把
  /// 「连接正常，模型返回了 N 个字」里那个 N 说成一个真数字。
  ///
  /// 成功判据是**请求成功返回，且回来的是一份真从模型出来的回复** ——
  /// [AiProvider.isCompletionResponse]：外壳对得上、`content` 或思考有一项非空。
  ///
  /// 两条**刻意**的判断都在那个判据里，这里不重复：
  ///
  /// - 光有 HTTP 200 不算通过：地址填成 `…:1444`（少了 `/v1`）时，网关对不存在
  ///   的路径回自己的**首页 HTML**，200 一个字都解不出来。旧实现还给
  ///   `AiTestOk(0)`、界面写「返回了 0 个字」，把「一条都发不出去」说成「连接正常」。
  /// - 只回了思考也算通过：预算还是不够时 `content` 是空串、`reasoning_content`
  ///   里有真东西 —— 端点、Key、模型名三样都对，这正是用户点这颗按钮要问的。
  Future<AiTestResult> testConnection() async {
    final ready = await _ready();
    if (ready == null) return const AiTestFailed(notConfiguredMessage);
    final (settings, key) = ready;
    final provider = settings.toProvider();
    try {
      final body = await _client.request(
        method: 'POST',
        headers: provider.headers(key, sse: false),
        url: provider.endpoint,
        body: provider.body(
          const AiRequest(
            system: '你是一个连接测试探针。',
            prompt: 'ping',
            maxTokens: _probeMaxTokens,
          ),
          stream: false,
        ),
      );
      if (!provider.isCompletionResponse(body)) {
        return AiTestFailed('端点回了 HTTP 200，但响应里没有模型回复的内容'
            '（当前地址 ${provider.baseUrl} 可能少了 /v1）');
      }
      // 通没通**只看上面那一条**。字数只是「确实通了」的实感：思考回了、
      // `content` 空时它是 0，界面按 0 换一句不会让人误会的文案（见设置页）。
      final text = provider.textDelta(body);
      return AiTestOk(text == null ? 0 : text.runes.length);
    } catch (error) {
      return AiTestFailed(_message(error, provider, key));
    }
  }

  /// 还没配好就返回 null；否则返回（设置, Key）。判定顺序与 `_start` 一致：
  /// 先问配没配（不发网络）→ 再读 Key。
  ///
  /// [needModel] 是**这一项要不要模型名**：`listModels` 传 false（它就是要
  /// 去拿模型名的），其余都传默认的 true。两档判据分别在
  /// [AiSettings.hasEndpoint]（地址 + Key）与 [AiSettings.isUsable]（再加模型）。
  ///
  /// **`_start` 刻意保留自己那份内联副本，不要合并。** 它多两样这里没有的东西：
  /// 钥匙串读不出来时的那句专门提示（[AiSettingsStore.isKeychainDegraded]），
  /// 以及发请求前的 `_usage.record()`。折进 `_ready()` 会让这两样一起消失 ——
  /// 前者把「钥匙串坏了」错报成「没配过」，后者直接漏记一次调用。
  Future<(AiSettings, String)?> _ready({bool needModel = true}) async {
    final settings = await _store.load();
    final configured = needModel ? settings.isUsable : settings.hasEndpoint;
    if (!configured) return null;
    final key = await _store.readApiKey();
    return key == null ? null : (settings, key);
  }

  /// 把传输层的错压成一条给人看的、**已脱敏**的话。
  static String _message(Object error, AiProvider provider, String apiKey) {
    if (error is AiTransportException) {
      return provider.errorMessage(error.statusCode ?? 0, error.message,
          apiKey: apiKey);
    }
    if (error is AiCancelledException) return '已取消'; // 目前无人传 cancelToken，此支是留给未来调用方的
    return '请求失败';
  }

  /// 所有能力的公共前半段：读设置 → 读 Key → 组装 → 发请求。
  ///
  /// **顺序是刻意的**：
  /// 1. 先问「配没配」—— 没配就直接回 [AiNotStarted]，**一次网络都不发**，
  ///    界面也就不用等一个注定失败的往返；
  /// 2. 再读 Key —— 读不出来（钥匙串坏了）与「没配过」在**行为上一样**，
  ///    但要给不同的提示：前者要说「钥匙串读不出来，重启后请重新填」；
  /// 3. 发请求**之前**记一次调用 —— 记在之后的话，「请求发出去了但进程被杀」
  ///    这一次就不计数了，而钱是真花了；
  /// 4. `maxTokens` 与温度由各能力给，不放在 prompt 里。
  Future<AiStart> _start({
    required int maxTokens,
    required String Function(AiSettings settings) build,
    double temperature = 0.7,
    /// 这一路的 system。**默认值就是原来那句**，所以既有六条路一个字没变。
    /// 只有 [suggest] 传自己的那一句 —— 它要的是「只输出 JSON」，
    /// 而 `_system` 那句「不要任何寒暄与说明」对 JSON 不够（模型仍会包围栏）。
    String system = _system,
  }) async {
    final settings = await _store.load();
    if (!settings.isUsable) {
      return const AiNotStarted(notConfiguredMessage);
    }
    final key = await _store.readApiKey();
    if (key == null) {
      return AiNotStarted(
        _store.isKeychainDegraded
            ? '读不到 API Key（系统的密钥库不可用），重启应用后请重新填一次'
            : notConfiguredMessage,
      );
    }

    await _usage.record();
    return AiStarted(_client.stream(
      provider: settings.toProvider(),
      request: AiRequest(
        system: system,
        prompt: build(settings),
        maxTokens: maxTokens,
        temperature: temperature,
      ),
      apiKey: key,
    ));
  }

  /// 所有请求共用的 system。厂商差异（Anthropic 的 `system` 是顶层字段、
  /// OpenAI 是第一条 message）由 `AiProvider.body` 处理。
  static const String _system = '你是一个邮件写作助手，直接输出结果本身，不要任何寒暄与说明。';

  /// [suggest] 专属的 system（spec §3.5）。
  ///
  /// 为什么单给一句：`_system` 那句「直接输出结果本身，不要任何寒暄与说明」
  /// 挡得住「好的，这是改写后的版本：」，挡不住「把 JSON 包进 ```json 围栏」
  /// —— 后者是模型对「输出 JSON」这个要求的**默认反应**。解析器当然也剥围栏
  /// （`SuggestionParser._stripFences`），但先在这儿说一句能把那一层的命中率
  /// 降下来，两处都留着更稳。
  static const String _suggestSystem =
      '你是一个邮件助理。你只输出一个 JSON 对象，不输出任何其他文字、不要代码块围栏。';
}
