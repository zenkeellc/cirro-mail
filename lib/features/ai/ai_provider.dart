import 'dart:convert';

/// 端点的**协议格式**。三档，不是「一个基类 + 三个实现」—— 它们的差别只在
/// 「地址怎么拼、请求头怎么写、流里哪一段是文本」，用数据描述比继承更省事、
/// 也更好测。
///
/// **刻意不按厂商分档。** 以前这里有 openai / deepseek / custom 三档，但它们的
/// 请求体与鉴权完全一样，差别只有终点地址 —— 于是「换个中转」要选一个叫
/// Custom 的档，而它其实就等于 OpenAI 兼容协议。现在地址是用户填的字段，
/// 格式只剩「协议」这一个维度。
///
/// [newapi] 这一档是**唯一的例外**，它不是第四种协议（请求头、请求体、流形状
/// 与 [openai] 完全一样，代码里也共用同一支），差的是**地址怎么归一**：
/// New API / One API 系网关在同一台主机上挂两套命名空间，而**不以 `/v1` 开头
/// 的路径一律回 HTTP 200 + 它自己的前端首页 HTML**（`router/web-router.go`
/// 的 `NoRoute`）。地址填成站点根地址时，[openai] 那一档会拼出
/// `/chat/completions` 打到首页上 —— 一次「看起来成功、一个字都解不出来」的
/// 请求。这一档把两种写法都拼成同一个正确地址，用户从网关后台复制哪个都对。
enum AiApiFormat { openai, anthropic, newapi }

/// 一次生成请求。
class AiRequest {
  const AiRequest({
    required this.system,
    required this.prompt,
    this.maxTokens = 1024,
    this.temperature = 0.7,
    this.thinking = false,
  });

  /// 系统提示（厂商一律走各自的「system 通道」，不混进 user 消息）。
  final String system;

  /// 用户提示。
  final String prompt;

  final int maxTokens;
  final double temperature;

  /// 要不要**让模型先思考**。默认 false。
  ///
  /// 为什么默认关：思考与正文**共用同一个 `max_tokens` 预算**（OpenAI 兼容的
  /// 推理模型如此），邮件这一路的四件事都不需要它 —— 一次「润色」的正文往往只有
  /// 几十个字，思考却动辄几百上千个 token。实测在 `deepseek-v4-1-flash` 上，
  /// 预算 1024 时约有两成的改写**正文一个字都没产生**（思考把预算吃光、
  /// `finish_reason: "length"`），用户看到的就是「AI 没有返回内容，请重试」。
  /// 关掉之后思考是 0 token，预算全留给正文。
  ///
  /// 只有 OpenAI 兼容那一档会把它翻成请求体里的字段（见 [AiProvider.body]）；
  /// Anthropic 那一档没有对应的开关，发了只会让端点困惑，所以不发。
  final bool thinking;
}

/// 端点协议适配：**纯函数**。真正的 HTTP 在 `ai_client.dart`，这里只管
/// 「拼请求」和「解流」—— 于是两件事都能脱离网络单测。
class AiProvider {
  const AiProvider({
    required this.format,
    required this.model,
    required this.baseUrl,
  });

  final AiApiFormat format;
  final String model;

  /// 用户填的**接口地址（base）**，不含 `/chat/completions` 这类路径 ——
  /// 路径由 [format] 决定。空串是调用方的错（`AiSettings.isUsable` 拦过一道）。
  final String baseUrl;

  static const String openaiDefaultBase = 'https://api.openai.com/v1';
  static const String anthropicDefaultBase = 'https://api.anthropic.com';

  /// New API / One API 网关**没有普适的官方地址**（自建的自有主机名），所以
  /// 这一档不给默认值 —— 切到它时地址保留原样，由用户填自己的网关。
  static const String newapiDefaultBase = '';

  /// Anthropic 的官方与多数中转给的地址两种写法都有（带 /v1 与不带）。
  /// base 已经以 `/v1` 结尾时就别再拼一层 —— `/v1/v1/messages` 不可能是
  /// 任何人的本意。**OpenAI 格式不做这个去重**：它拼的是 `/chat/completions`，
  /// base 必须含 `/v1`。
  ///
  /// [AiApiFormat.newapi] 反过来**必须**补上 `/v1`：网关的 relay 路由只有
  /// `/v1/...` 这一组，而其他的路径不返回 404、回的是前端首页（HTTP 200 +
  /// HTML）—— 少一个 `/v1` 换来的是一次看不出错的失败。用户从网关后台复制的
  /// 地址带不带 `/v1` 两种都有，这里替他统一。
  String get _baseForPath {
    final base = _trimTrailingSlash(baseUrl.trim());
    if (format == AiApiFormat.anthropic && base.endsWith('/v1')) {
      return base.substring(0, base.length - 3);
    }
    if (format == AiApiFormat.newapi && !base.toLowerCase().endsWith('/v1')) {
      return '$base/v1';
    }
    return base;
  }

  /// 生成请求要打的地址。
  String get endpoint => switch (format) {
        AiApiFormat.openai || AiApiFormat.newapi =>
          '$_baseForPath/chat/completions',
        AiApiFormat.anthropic => '$_baseForPath/v1/messages',
      };

  /// 列模型要打的地址。
  ///
  /// New API 的 `/v1/models` 是**按 TokenAuth 过滤过的**：回的是这个令牌所在
  /// 分组（或它自己的模型白名单）里的模型，不是网关的全量列表。对着它猜「怎么
  /// 少那么多」是白费劲，所以界面文案（`aiModelsEmpty`）只承诺「这个端点没有
  /// 列表」，不承诺「列表是全的」。
  String get modelsEndpoint => switch (format) {
        AiApiFormat.openai || AiApiFormat.newapi => '$_baseForPath/models',
        AiApiFormat.anthropic => '$_baseForPath/v1/models',
      };

  /// 请求头。**API Key 只在 [apiKey] 参数里出现**，不缓存、不写日志。
  ///
  /// ⚠️ 返回的 map **自带密钥**（`x-api-key` / `authorization` 的值就是它）：
  /// 它是唯一该带 key 的地方，正因如此**绝不能整体 `debugPrint` / 序列化**，
  /// 否则 key 会随 `Map.toString()` 漏出去。要记请求时只记 `url` 与 `body`。
  ///
  /// [sse] 为 false 时不要 `accept: text/event-stream` —— 列模型与连接测试
  /// 走的是非流式请求，声明要事件流只会让端点困惑。
  Map<String, String> headers(String apiKey, {bool sse = true}) {
    final common = <String, String>{
      'content-type': 'application/json',
      if (sse) 'accept': 'text/event-stream',
    };
    return switch (format) {
      AiApiFormat.anthropic => {
          ...common,
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
      AiApiFormat.openai || AiApiFormat.newapi => {
          ...common,
          'authorization': 'Bearer $apiKey',
        },
    };
  }

  /// 请求体。Anthropic 的 `system` 是顶层字段；OpenAI 兼容的是一条第 `system` 角色。
  ///
  /// [stream] 为 false 用于「测试连接」那一次极短的非流式请求。
  Map<String, dynamic> body(AiRequest request, {bool stream = true}) {
    return switch (format) {
      AiApiFormat.anthropic => {
          'model': model,
          'max_tokens': request.maxTokens,
          'temperature': request.temperature,
          'stream': stream,
          'system': request.system,
          'messages': [
            {'role': 'user', 'content': request.prompt},
          ],
        },
      AiApiFormat.openai || AiApiFormat.newapi => {
          'model': model,
          'max_tokens': request.maxTokens,
          'temperature': request.temperature,
          'stream': stream,
          // **不让模型先思考**（见 [AiRequest.thinking]）。字段名与取值都照
          // DeepSeek 系的约定写死 —— 用户实际接的就是这一类网关，而它是**唯一
          // 实测有效**的那个开关（`reasoning_effort` / `enable_thinking` /
          // `reasoning.enabled` 在同一台网关上都不生效，实测过）。
          //
          // 不认识这个字段的端点（OpenAI 官方、多数中转）会**忽略**它再照常回
          // 答，代价也只是多传一个键 —— 比「两成调用一个字都回不来」划算。
          //
          // 这是本项目里**唯一**一处厂商特有字段，所以刻意只写在这一档的
          // `body()` 里（三档之间那一组「协议差异」的映射关系没有变）。
          if (!request.thinking) 'thinking': {'type': 'disabled'},
          'messages': [
            {'role': 'system', 'content': request.system},
            {'role': 'user', 'content': request.prompt},
          ],
        },
    };
  }

  /// 这次响应是不是**撞上了长度上限**（而不是模型自己写完了）。
  ///
  /// 与 [textDelta] 同一条取向：**不抛异常**，认不出来就是 false。
  ///
  /// 为什么值得单独认这一条：撞上限时的表现有两种，而它们**都不该**被当成
  /// 「这次没回内容」——
  ///
  /// - `content` 是空串（预算被思考吃光，推理模型很容易如此）：界面上是
  ///   「一个字都没拿到」。这是**可解释**的失败，该告诉用户「截断了」而不是
  ///   一句无从下手的「请重试」；
  /// - `content` 只有半截：用户看到的是一句没写完的话，界面上却什么都不说。
  ///
  /// 各家的叫法：OpenAI 兼容的在 `choices[0].finish_reason == "length"`，
  /// Anthropic 的在 `stop_reason == "max_tokens"` —— 非流式在顶层，流式的
  /// `message_delta` 事件里在 `delta.stop_reason`（**两处都要认**，只认顶层会
  /// 让流式下的截断一次都报不出来）。
  bool isTruncated(String payload) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty || trimmed == '[DONE]') return false;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return false;
    }
    if (decoded is! Map) return false;

    if (decoded['stop_reason'] == 'max_tokens') return true;
    final delta = decoded['delta'];
    if (delta is Map && delta['stop_reason'] == 'max_tokens') return true;
    final choices = decoded['choices'];
    if (choices is! List) return false;
    for (final choice in choices) {
      if (choice is Map && choice['finish_reason'] == 'length') return true;
    }
    return false;
  }

  /// 从一条 SSE 事件的载荷里抠出**这次的文本增量**。抠不出来返回 null
  /// （可能是 `[DONE]`、心跳、或厂商加的新壳）。
  ///
  /// 两档格式的壳（实测自各自文档/真实响应）：
  /// - Anthropic：`{"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}`，
  ///   以及非流式的整段回答（顶层 `content[]`，见下）
  /// - OpenAI 兼容：`{"choices":[{"delta":{"content":"…"}}]}`，
  ///   以及非流式的 `choices[0].message.content`
  ///
  /// 两档都得认非流式那一支：SSE 之外，「测试连接」发的就是非流式请求，
  /// 只认流式壳会把成功连接的返回值抠成 null（界面上显示成「返回了 0 个字」）。
  ///
  /// 刻意**不抛异常**：多一个没见过的字段不该让整次生成失败，最坏是少几个字；
  /// 而抛异常会让「已经流出来的半截回答」一起丢掉。
  String? textDelta(String payload) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty || trimmed == '[DONE]') return null;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;

    switch (format) {
      case AiApiFormat.anthropic:
        if (decoded['type'] == 'content_block_delta') {
          final delta = decoded['delta'];
          if (delta is Map && delta['type'] == 'text_delta') {
            final text = delta['text'];
            if (text is String) return text;
          }
        }
        // 非流式降级：整段回答在顶层的 `content[]`（每块 `{"type":"text","text":"…"}`）。
        // 「测试连接」发的就是非流式请求，走的是这一支；而 SSE 事件里没有顶层
        // `content`（那里的块叫 `content_block`），所以这一支在流式路径上不会误伤。
        final content = decoded['content'];
        if (content is List) {
          final text = content
              .whereType<Map>()
              .where((b) => b['type'] == 'text' || b['type'] == null)
              .map((b) => b['text'])
              .whereType<String>()
              .join();
          if (text.isNotEmpty) return text;
        }
        return null;
      case AiApiFormat.openai || AiApiFormat.newapi:
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty) return null;
        final first = choices.first;
        if (first is! Map) return null;
        final delta = first['delta'];
        if (delta is Map) {
          final content = delta['content'];
          if (content is String && content.isNotEmpty) return content;
        }
        // 有些兼容端点把整段回答放在 message.content（非流式降级）。
        final message = first['message'];
        if (message is Map) {
          final content = message['content'];
          if (content is String && content.isNotEmpty) return content;
        }
        return null;
    }
  }

  /// 这次响应**看起来是不是一份真的从模型回来的回复**（而不是网关的前端首页、
  /// 反代的错误页、或任何不该出现在这个地址上的东西）。这是「测试连接」的通过
  /// 判据，**判据是「有没有真内容」，不是「有没有可见文本」**。
  ///
  /// 为什么非得有这一条：回不出可见文本有**两种完全不同的原因**，而它们一个是
  /// 「配错了」、一个是「配对了」——
  ///
  /// 1. **打到的不是接口** —— New API 系网关对不以 `/v1` 开头的路径回自己的首页
  ///    HTML（HTTP 200），`textDelta` 一个字都抠不出来；
  /// 2. **打到了接口，但模型只回了思考** —— 推理模型（DeepSeek 这一路的
  ///    `reasoning_content`）在预算不够时正是如此：实测 `max_tokens: 8` 时
  ///    `content` 是空串、`reasoning_content` 里却有实打实的一段思考。
  ///
  /// 第 2 种**算通过**：思考也是这次模型真跑出来的内容，说明端点、Key、模型名
  /// 三样都对 —— 而「测试连接」要回答的就是这个。反过来把[textDelta]（它认的
  /// 是 `content`，因为**思考不该流进邮件里**）当成通过判据，会把一个配得完全
  /// 正确的推理端点判成失败。
  ///
  /// 于是判据是「**外壳对得上，且 content 或思考有一项非空**」。首页 HTML、空响应、
  /// 光有 `[DONE]`、错误壳、半截 JSON 全都落空。
  bool isCompletionResponse(String payload) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty || trimmed == '[DONE]') return false;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return false;
    }
    if (decoded is! Map) return false;

    return switch (format) {
      AiApiFormat.anthropic => _anthropicHasContent(decoded),
      AiApiFormat.openai || AiApiFormat.newapi => _openaiHasContent(decoded),
    };
  }

  /// OpenAI 兼容：`choices[0]` 的 `message` / `delta` 里，`content` 与 [reasoningKeys]
  /// 至少一项有非空文本。
  static bool _openaiHasContent(Map decoded) {
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return false;
    final first = choices.first;
    if (first is! Map) return false;
    // 非流式的整段回答在 `message`，流式增量在 `delta`；两处都认（网关对
    // `stream: false` 的请求回的就是 `message`）。
    for (final holder in <Object?>[first['message'], first['delta']]) {
      if (holder is! Map) continue;
      if (_nonEmptyText(holder['content'])) return true;
      for (final key in _reasoningKeys) {
        if (_nonEmptyText(holder[key])) return true;
      }
    }
    return false;
  }

  /// Anthropic：顶层 `content[]` 里有没有**任何**一块带文本。可见的 `text` 块与
  /// thinking / redacted_thinking 块都算 —— 与 OpenAI 那边「思考也算内容」同一条。
  static bool _anthropicHasContent(Map decoded) {
    if (decoded['type'] == 'error') return false;
    final content = decoded['content'];
    if (content is! List) return false;
    for (final block in content) {
      // 少数端点给裸字符串块。
      if (_nonEmptyText(block)) return true;
      if (block is! Map) continue;
      // `partial_json` 只属于 tool_use 块（结构化参数），不算内容。
      for (final key in <String>['text', 'thinking']) {
        if (_nonEmptyText(block[key])) return true;
      }
    }
    return false;
  }

  /// 不同中转让推理内容的名字不一样。这里**宁可宽**：多认一个没见过的字段最多
  /// 是把一次「其实没回东西」当通过，少认一个却会把通了的说成没通 —— 两种代价
  /// 不对等。它们**只是通过判据**，不参与 [textDelta] 取正文（思考不该进邮件）。
  static const List<String> _reasoningKeys = <String>[
    'reasoning_content',
    'reasoning',
    'thinking',
  ];

  /// 这个字段是不是一段非空文本。
  static bool _nonEmptyText(Object? value) =>
      value is String && value.trim().isNotEmpty;

  /// 从列模型响应里抠出模型名。**刻意不抛异常**（与 [textDelta] 同一条原则：
  /// 一个不认识的壳不该让整件事失败）。认不出返回**空列表** —— 由上层翻译成
  /// 「这个端点没有模型列表」，而不是当成错误。
  ///
  /// 认这些形状（按出现顺序试）：
  /// - `{"data":[{"id":"gpt-4o"},…]}` —— OpenAI / Anthropic / 大多数中转；
  /// - `{"data":["gpt-4o",…]}` —— 少数端点给裸字符串；
  /// - `{"models":[{"name":"models/gemini-pro"}]}` —— 宽松兜底。
  ///
  /// 去重、去空白、丢掉解析不出来的元素；**不排序** —— 端点给的顺序通常有意
  /// 义（新模型在前）。上限 [_maxModels]。一条都没有就是空列表。
  List<String> parseModels(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const <String>[];
    }
    if (decoded is! Map) return const <String>[];
    final raw = decoded['data'] ?? decoded['models'];
    if (raw is! List) return const <String>[];

    final seen = <String>{};
    final out = <String>[];
    for (final item in raw) {
      final name = _modelName(item);
      if (name == null) continue;
      if (!seen.add(name)) continue;
      out.add(name);
      if (out.length >= _maxModels) break;
    }
    return out;
  }

  /// 一个列表元素里的模型名。`{"id":…}` 优先（OpenAI 形状），退到 `{"name":…}`。
  static String? _modelName(Object? item) {
    if (item is String) {
      final trimmed = item.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    if (item is Map) {
      for (final key in const ['id', 'name', 'model']) {
        final value = item[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    }
    return null;
  }

  /// 一个病态的响应（几万条）不该让选择器卡死。
  static const int _maxModels = 500;

  /// 从非流式（或流中途报错）的响应体里提炼一条**给人看**的错误。
  /// 厂商的错误外壳五花八门，宁可退到「HTTP 401」这种粗糙信息，也不要
  /// 把整个 JSON 倒在界面上。
  ///
  /// **脱敏是本方法的契约的一部分**：OpenAI 的 401 响应体里**就是**把用户
  /// 提交的 key 原样回显（`Incorrect API key provided: sk-...`），Anthropic 的
  /// 是 `invalid x-api-key: sk-ant-...`。这条字符串会进异常 message、再进
  /// `toString()`、crash reporter、日志序列化 —— 所以出这个方法前必须先把
  /// 密钥抹掉。见 [redactSecrets]。
  ///
  /// [apiKey] 是**调用方已知的那个 key**（`AiClient` 手上有），用于按值精确
  /// 替换；拿不到（或不方便传）时传 null，仍会走形状兜底。
  String errorMessage(int statusCode, String body, {String? apiKey}) {
    final raw = _rawMessage(statusCode, body);
    return redactSecrets(raw, apiKey: apiKey);
  }

  /// 抠出厂商写的原文（不含脱敏）。
  String _rawMessage(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          final message = error['message'];
          if (message is String && message.isNotEmpty) return message;
        }
        final message = decoded['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } on FormatException {
      // 落到下面。
    }
    return 'HTTP $statusCode';
  }

  /// 把 [text] 里任何可能是**密钥**的片段换成 `***`。两层：
  ///
  /// 1. **按值精确替换**：调用方知道的 [apiKey] 直接 `replaceAll` 掉 —— 这是
  ///    最可靠的一层（不依赖形状猜测）。key 为空或过短时跳过：太短的值会在
  ///    正常文案里到处误伤（例如 key 恰好是 `key` 或 `a`）。
  ///    阈值取 8：短于 8 的串基本不可能是真密钥，而误替换的代价更高。
  /// 2. **形状兜底**：不依赖「我们知道 key」—— 覆盖厂商会在别处回显的情况：
  ///    `sk-`/`sk-ant-` 开头的一串、`Bearer <token>`、`api_key=<token>`。
  ///
  /// 这一层是**有意宽进**的：宁可把一句正常的错误文案多打几个星号，也不能
  /// 让一次密钥泄漏出去。`***` 只是标记，本身不含任何原文。
  static String redactSecrets(String text, {String? apiKey}) {
    var out = text;
    if (apiKey != null && apiKey.length >= _minRedactableKeyLength) {
      out = out.replaceAll(apiKey, '***');
    }
    // sk-… / sk-ant-… 整串换掉（前缀与密钥体一起，避免残留长度线索）。
    out = out.replaceAll(_skShape, '***');
    // `Bearer <token>` 保留 `Bearer `，只换 token —— 文案仍看得懂。
    out = out.replaceAllMapped(_bearerShape, (m) => '${m[1]}***');
    // `api_key=…` / `api-key: …` 同理，保留字段名。
    out = out.replaceAllMapped(_apiKeyShape, (m) => '${m[1]}***');
    return out;
  }

  /// 短于这个长度的「已知 key」不做按值替换：误伤正常文案的代价高于收益。
  static const int _minRedactableKeyLength = 8;

  /// `sk-` / `sk-ant-` 开头的一串（字母、数字、`-`、`_`）。
  static final RegExp _skShape = RegExp(r'sk-[A-Za-z0-9_\-]{6,}');

  /// `Bearer <token>`：分组 1 是 `Bearer ` 前缀本身。
  static final RegExp _bearerShape =
      RegExp(r'(Bearer\s+)[A-Za-z0-9_\-\.]{6,}', caseSensitive: false);

  /// `api_key=` / `api-key: ` / `api key =`（引号也算分隔符）：分组 1 是字段名。
  static final RegExp _apiKeyShape =
      RegExp(r'''(api[_-]?key['"\s:=]+)[A-Za-z0-9_\-\.]{4,}''', caseSensitive: false);


  /// 允许没带 key 的高风险场景：Key 里含空格/换行说明是复制错了，
  /// 提前拦下来比发出去等 401 更省用户的事（也避免把畸形串写进日志）。
  static String? validateApiKey(String? key) {
    if (key == null || key.trim().isEmpty) return 'emptyKey';
    if (key.contains(RegExp(r'\s'))) return 'whitespaceInKey';
    return null;
  }

  /// 收掉末尾的 `/`，否则会拼出 `//`。
  static String _trimTrailingSlash(String raw) =>
      raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
}
