import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_provider.dart';

void main() {
  const req = AiRequest(system: 'S', prompt: 'P', maxTokens: 64);

  test('默认地址常量被钉死（全新安装用的就是它）', () {
    expect(AiProvider.openaiDefaultBase, 'https://api.openai.com/v1');
    expect(AiProvider.anthropicDefaultBase, 'https://api.anthropic.com');
  });

  group('端点：地址一律当 base，路径由格式拼', () {
    test('OpenAI 兼容', () {
      const p = AiProvider(
        format: AiApiFormat.openai,
        model: 'm',
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(p.endpoint, 'https://api.openai.com/v1/chat/completions');
      expect(p.modelsEndpoint, 'https://api.openai.com/v1/models');
    });

    test('Anthropic', () {
      const p = AiProvider(
        format: AiApiFormat.anthropic,
        model: 'm',
        baseUrl: 'https://api.anthropic.com',
      );
      expect(p.endpoint, 'https://api.anthropic.com/v1/messages');
      expect(p.modelsEndpoint, 'https://api.anthropic.com/v1/models');
    });

    test('末尾斜杠被收掉（否则会拼出 //）', () {
      const p = AiProvider(
        format: AiApiFormat.openai,
        model: 'm',
        baseUrl: 'https://x.dev/v1/',
      );
      expect(p.endpoint, 'https://x.dev/v1/chat/completions');
    });

    test('Anthropic 的 base 已经带 /v1 → 去重，不再拼成 /v1/v1', () {
      const withV1 = AiProvider(
        format: AiApiFormat.anthropic,
        model: 'm',
        baseUrl: 'https://api.anthropic.com/v1',
      );
      expect(withV1.endpoint, 'https://api.anthropic.com/v1/messages');
      expect(withV1.modelsEndpoint, 'https://api.anthropic.com/v1/models');
    });

    test('Anthropic 的 base 带 /v1 又带末尾斜杠 → 先收斜杠再去重', () {
      const p = AiProvider(
        format: AiApiFormat.anthropic,
        model: 'm',
        baseUrl: 'https://api.anthropic.com/v1/',
      );
      expect(p.endpoint, 'https://api.anthropic.com/v1/messages');
      expect(p.modelsEndpoint, 'https://api.anthropic.com/v1/models');
    });

    test('OpenAI 格式不去 /v1 —— 它拼的是 /chat/completions', () {
      const p = AiProvider(
        format: AiApiFormat.openai,
        model: 'm',
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(p.endpoint.startsWith('https://api.openai.com/v1/'), isTrue);
    });

    test('中转地址原样打（用户填什么 host 就是什么）', () {
      const p = AiProvider(
        format: AiApiFormat.openai,
        model: 'm',
        baseUrl: 'https://proxy.example.com/llm',
      );
      expect(p.endpoint, 'https://proxy.example.com/llm/chat/completions');
    });

    test('New API：站点根地址被补上 /v1', () {
      const p = AiProvider(
        format: AiApiFormat.newapi,
        model: 'm',
        baseUrl: 'https://api.example.net:1444',
      );
      expect(p.endpoint, 'https://api.example.net:1444/v1/chat/completions');
      expect(p.modelsEndpoint, 'https://api.example.net:1444/v1/models');
    });

    test('New API：带了 /v1 就不再补一层（两种写法同一个地址）', () {
      const bare = AiProvider(
        format: AiApiFormat.newapi,
        model: 'm',
        baseUrl: 'https://api.example.net:1444',
      );
      const withV1 = AiProvider(
        format: AiApiFormat.newapi,
        model: 'm',
        baseUrl: 'https://api.example.net:1444/v1',
      );
      expect(withV1.endpoint, bare.endpoint);
      expect(withV1.modelsEndpoint, bare.modelsEndpoint);
    });

    test('New API：末尾斜杠与 /v1 的大小写都认', () {
      const p = AiProvider(
        format: AiApiFormat.newapi,
        model: 'm',
        baseUrl: 'https://gw.example.com/v1/',
      );
      expect(p.endpoint, 'https://gw.example.com/v1/chat/completions');
      const upper = AiProvider(
        format: AiApiFormat.newapi,
        model: 'm',
        baseUrl: 'https://gw.example.com/V1',
      );
      expect(upper.endpoint, 'https://gw.example.com/V1/chat/completions');
    });
  });

  group('请求头', () {
    test('Anthropic 用 x-api-key + anthropic-version，不用 Bearer', () {
      final h = const AiProvider(
        format: AiApiFormat.anthropic,
        model: 'm',
        baseUrl: 'https://x',
      ).headers('k');
      expect(h['x-api-key'], 'k');
      expect(h['anthropic-version'], '2023-06-01');
      expect(h.containsKey('authorization'), isFalse);
    });

    test('OpenAI 兼容用 Bearer', () {
      final h = const AiProvider(
        format: AiApiFormat.openai,
        model: 'm',
        baseUrl: 'https://x',
      ).headers('k');
      expect(h['authorization'], 'Bearer k');
      expect(h.containsKey('x-api-key'), isFalse);
    });

    test('sse: false 时不要 accept: text/event-stream（非流式请求）', () {
      final on = const AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      ).headers('k');
      expect(on['accept'], 'text/event-stream');

      final off = const AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      ).headers('k', sse: false);
      expect(off.containsKey('accept'), isFalse);
      expect(off['content-type'], 'application/json');
    });

    test('New API 与 OpenAI 同一支：Bearer，且没有 anthropic-version', () {
      final h = const AiProvider(
        format: AiApiFormat.newapi,
        model: 'm',
        baseUrl: 'https://gw.example.com',
      ).headers('k');
      expect(h['authorization'], 'Bearer k');
      expect(h.containsKey('x-api-key'), isFalse);
      expect(h.containsKey('anthropic-version'), isFalse);
    });
  });

  group('请求体', () {
    test('Anthropic 的 system 在顶层，不在 messages 里', () {
      final b = const AiProvider(
        format: AiApiFormat.anthropic, model: 'm', baseUrl: 'https://x',
      ).body(req);
      expect(b['system'], 'S');
      expect((b['messages'] as List).length, 1);
      expect(b['stream'], isTrue);
      expect(b['max_tokens'], 64);
    });

    test('OpenAI 兼容的 system 是第一条 message', () {
      final b = const AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      ).body(req);
      final messages = b['messages'] as List;
      expect(messages.length, 2);
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], 'S');
      expect(messages.last['role'], 'user');
    });

    test('stream: false 时请求体里也是 false（连接测试用）', () {
      final a = const AiProvider(
        format: AiApiFormat.anthropic, model: 'm', baseUrl: 'https://x',
      ).body(req, stream: false);
      expect(a['stream'], isFalse);
      final o = const AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      ).body(req, stream: false);
      expect(o['stream'], isFalse);
    });

    test('默认不发「让模型思考」—— OpenAPI 兼容档带上 thinking: disabled', () {
      // 「润色一个字都没回」的根因就是思考吃光了 max_tokens（见 AiRequest.thinking）。
      // `req` 不带 thinking，取默认的 false → 必须发出这个字段。
      final o = const AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      ).body(req);
      expect(o['thinking'], {'type': 'disabled'});
      // New API 档与 OpenAI 共用同一支，也带上。
      final n = const AiProvider(
        format: AiApiFormat.newapi, model: 'm', baseUrl: 'https://x',
      ).body(req);
      expect(n['thinking'], {'type': 'disabled'});
    });

    test('要求思考时才不发这个字段（= 让端点用它自己的默认行为）', () {
      const withThinking =
          AiRequest(system: 'S', prompt: 'P', maxTokens: 64, thinking: true);
      final o = const AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      ).body(withThinking);
      expect(o.containsKey('thinking'), isFalse);
    });

    test('Anthropic 档不发 thinking —— 它没有这个开关，发了只会让端点困惑', () {
      final a = const AiProvider(
        format: AiApiFormat.anthropic, model: 'm', baseUrl: 'https://x',
      ).body(req);
      expect(a.containsKey('thinking'), isFalse);
    });
  });

  group('流增量', () {
    test('Anthropic 流：content_block_delta → text', () {
      const p = AiProvider(
        format: AiApiFormat.anthropic, model: 'm', baseUrl: 'https://x',
      );
      expect(
        p.textDelta(
            '{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}'),
        '你好',
      );
      expect(p.textDelta('{"type":"message_start"}'), isNull);
    });

    test('OpenAI 兼容流：choices[0].delta.content', () {
      const p = AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      );
      expect(p.textDelta('{"choices":[{"delta":{"content":"你好"}}]}'), '你好');
    });

    test('非流式降级：message.content 也能取到', () {
      const p = AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      );
      expect(p.textDelta('{"choices":[{"message":{"content":"整段"}}]}'), '整段');
    });

    test('非流式降级：Anthropic 的 content[].text 也能取到', () {
      const p = AiProvider(
        format: AiApiFormat.anthropic, model: 'm', baseUrl: 'https://x',
      );
      expect(
        p.textDelta('{"content":[{"type":"text","text":"整段"}]}'),
        '整段',
      );
      // 多块要拼起来；非 text 块（例如未来的 tool_use）忽略。
      expect(
        p.textDelta(
            '{"content":[{"type":"text","text":"你"},{"type":"text","text":"好"}]}'),
        '你好',
      );
      // 一个字符都抠不出来 → null（不是空串）—— 调用方靠 null 区分「认不出」。
      expect(p.textDelta('{"content":[]}'), isNull);
    });

    test('垃圾输入一律返回 null，不抛', () {
      for (final f in AiApiFormat.values) {
        final p = AiProvider(format: f, model: 'm', baseUrl: 'https://x');
        expect(p.textDelta(''), isNull, reason: '$f');
        expect(p.textDelta('[DONE]'), isNull, reason: '$f');
        expect(p.textDelta('not json'), isNull, reason: '$f');
        expect(p.textDelta('[1,2,3]'), isNull, reason: '$f');
        expect(p.textDelta('{"type":"ping"}'), isNull, reason: '$f');
      }
    });
  });

  group('响应外壳：这次打的到底是不是模型接口', () {
    const openai = AiProvider(
      format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
    );
    const anthropic = AiProvider(
      format: AiApiFormat.anthropic, model: 'm', baseUrl: 'https://x',
    );

    test('OpenAI 兼容：content 有字才算', () {
      expect(openai.isCompletionResponse('{"choices":[{"message":{"content":"pong"}}]}'), isTrue);
      expect(openai.isCompletionResponse('{"choices":[{"delta":{"content":"po"}}]}'), isTrue);
    });

    test('推理模型：content 空、只有 reasoning_content → **算通**', () {
      // 实测形状（`max_tokens: 8` 打推理模型就是这个）：content 是空串，
      // 思考在 reasoning_content 里。端点、Key、模型名三样都对 —— 这正是
      // 「测试连接」要回答的，判失败会把配得好好的端点说成配错了。
      expect(
        openai.isCompletionResponse(
            '{"choices":[{"finish_reason":"length","message":'
            '{"role":"assistant","content":"","reasoning_content":"The user just said…"}}]}'),
        isTrue,
      );
      // 别的中转叫别的名字，一并认（宽一点只是通过判据，不参与取正文）。
      expect(
        openai.isCompletionResponse('{"choices":[{"message":{"reasoning":"嗯…"}}]}'),
        isTrue,
      );
    });

    test('content 空、思考也空 / 字段缺失 → 不算通', () {
      expect(openai.isCompletionResponse('{"choices":[{"message":{"role":"assistant","content":""}}]}'), isFalse);
      expect(openai.isCompletionResponse('{"choices":[{"message":{"role":"assistant"}}]}'), isFalse);
      expect(openai.isCompletionResponse('{"choices":[{"message":{"content":"   ","reasoning_content":""}}]}'), isFalse);
      expect(openai.isCompletionResponse('{"choices":[{"message":{"content":"","reasoning":""}}]}'), isFalse);
      // 错误壳：就算里面出现 message 字段也不算模型回复。
      expect(openai.isCompletionResponse('{"error":{"message":"bad"}}'), isFalse);
    });

    test('网关首页 / 空响应 / 半截 JSON 都不是', () {
      // New API 系网关对不带 /v1 的路径回的就是这个：HTTP 200 + 首页 HTML。
      expect(
        openai.isCompletionResponse(
            '<!doctype html><html lang="en"><head><title>New API</title></head></html>'),
        isFalse,
      );
      expect(openai.isCompletionResponse(''), isFalse);
      expect(openai.isCompletionResponse('[DONE]'), isFalse);
      expect(openai.isCompletionResponse('{"choices":[]}'), isFalse);
      expect(openai.isCompletionResponse('{"choices":[{"index":0}]}'), isFalse);
    });

    test('Anthropic：content[] 里有 text 或 thinking 块才算', () {
      expect(anthropic.isCompletionResponse('{"type":"message","content":[{"type":"text","text":"hi"}]}'), isTrue);
      // 只回了 thinking 块 —— 与 OpenAI 那边「思考也算内容」同一条。
      expect(
        anthropic.isCompletionResponse(
            '{"type":"message","content":[{"type":"thinking","thinking":"让我想想…"}]}'),
        isTrue,
      );
      // 裸字符串块（少数端点）。
      expect(anthropic.isCompletionResponse('{"content":["hi"]}'), isTrue);
      // 空块 / 只有 tool_use 的结构化参数 / 错误壳。
      expect(anthropic.isCompletionResponse('{"type":"message","content":[]}'), isFalse);
      expect(anthropic.isCompletionResponse('{"content":[{"type":"text","text":""}]}'), isFalse);
      expect(anthropic.isCompletionResponse('{"content":[{"type":"tool_use","partial_json":"{}"}]}'), isFalse);
      expect(anthropic.isCompletionResponse('{"type":"error","error":{}}'), isFalse);
      expect(anthropic.isCompletionResponse('<html>'), isFalse);
    });

    test('New API 档与 OpenAI 同一支', () {
      const p = AiProvider(
        format: AiApiFormat.newapi, model: 'm', baseUrl: 'https://x',
      );
      expect(
        p.isCompletionResponse('{"choices":[{"message":{"content":"","reasoning_content":"嗯"}}]}'),
        isTrue,
      );
      expect(p.isCompletionResponse('<html>'), isFalse);
    });
  });

  group('这次撞上长度上限了吗（isTruncated）', () {
    const openai = AiProvider(
      format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
    );
    const anthropic = AiProvider(
      format: AiApiFormat.anthropic, model: 'm', baseUrl: 'https://x',
    );

    test('OpenAI 兼容：choices[].finish_reason == "length"', () {
      expect(openai.isTruncated('{"choices":[{"delta":{},"finish_reason":"length"}]}'), isTrue);
      expect(openai.isTruncated('{"choices":[{"delta":{},"finish_reason":"stop"}]}'), isFalse);
      // 收尾帧常是空壳，但正常结束也不该误报。
      expect(openai.isTruncated('{"choices":[{"delta":{"content":"好"},"finish_reason":null}]}'), isFalse);
    });

    test('增量帧不带 finish_reason、收尾空壳帧才带 —— 两种都认', () {
      // 常见的形状是「增量帧没有 finish_reason、收尾那一帧才写」，所以调用方
      // 按「出现过」而不是「最后一帧写着」来判（见 AiClient 的逐帧判定）。
      expect(openai.isTruncated('{"choices":[{"delta":{"content":"半截"}}]}'), isFalse);
      expect(openai.isTruncated('{"choices":[{"delta":{},"finish_reason":"length"}]}'), isTrue);
    });

    test('Anthropic：stop_reason == "max_tokens"，顶层与 delta 里都认', () {
      // 非流式 / message_start：顶层。
      expect(anthropic.isTruncated('{"type":"message","stop_reason":"max_tokens"}'), isTrue);
      // 流式的 message_delta：**在 delta 里**。只认顶层会让流式下的截断一次都
      // 报不出来 —— 而流式正是四件能力走的路径。
      expect(anthropic.isTruncated('{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}'), isTrue);
      expect(anthropic.isTruncated('{"type":"message_delta","delta":{"stop_reason":"end_turn"}}'), isFalse);
    });

    test('垃圾输入一律 false，不抛', () {
      expect(openai.isTruncated(''), isFalse);
      expect(openai.isTruncated('[DONE]'), isFalse);
      expect(openai.isTruncated('not json'), isFalse);
      expect(openai.isTruncated('[1,2,3]'), isFalse);
      expect(openai.isTruncated('{"choices":"nope"}'), isFalse);
      expect(openai.isTruncated('{"choices":[1,2]}'), isFalse);
    });
  });

  group('列模型解析', () {
    const p = AiProvider(
      format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
    );

    test('data[].id —— OpenAI / Anthropic / 大多数中转', () {
      expect(
        p.parseModels('{"object":"list","data":['
            '{"id":"gpt-4o","object":"model"},{"id":"gpt-4o-mini"}]}'),
        ['gpt-4o', 'gpt-4o-mini'],
      );
    });

    test('data[] 是裸字符串 —— 少数端点', () {
      expect(p.parseModels('{"data":["a","b"]}'), ['a', 'b']);
    });

    test('models[].name 兜底', () {
      expect(
        p.parseModels('{"models":[{"name":"models/gemini-pro"}]}'),
        ['models/gemini-pro'],
      );
    });

    test('{"model":…} 也认（宽松兜底）', () {
      expect(p.parseModels('{"data":[{"model":"m"}]}'), ['m']);
    });

    test('去重、去空白、丢掉解析不出来的元素', () {
      expect(
        p.parseModels('{"data":[{"id":"a"},{"id":" a "},{"id":""},{"nope":1},"b",42]}'),
        ['a', 'b'],
      );
    });

    test('一条都抠不出来 → 空列表，不抛', () {
      expect(p.parseModels('{"nope":true}'), isEmpty);
      expect(p.parseModels('这不是 JSON'), isEmpty);
      expect(p.parseModels(''), isEmpty);
      expect(p.parseModels('[1,2,3]'), isEmpty);
    });

    test('多于 500 条时截到 500（病态响应不该让选择器卡死）', () {
      final many = '{"data":[${List.generate(900, (i) => '{"id":"m$i"}').join(',')}]}';
      expect(p.parseModels(many).length, 500);
    });
  });

  group('错误脱敏（原有行为不变）', () {
    const anthropic = AiProvider(
      format: AiApiFormat.anthropic, model: 'm', baseUrl: 'https://x',
    );

    test('厂商的 error.message 优先', () {
      expect(
        anthropic.errorMessage(
            401, '{"type":"error","error":{"message":"invalid x-api-key"}}'),
        'invalid x-api-key',
      );
      expect(anthropic.errorMessage(500, 'boom'), 'HTTP 500');
      expect(anthropic.errorMessage(429, '{"message":"rate limited"}'),
          'rate limited');
    });

    test('OpenAI 401 回显的 Key 被抹掉', () {
      const p = AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      );
      const body = '{"error":{"message":"Incorrect API key provided: '
          'sk-live-abc123. You can find your API key at..."}}';
      final msg = p.errorMessage(401, body, apiKey: 'sk-live-abc123');
      expect(msg.contains('sk-live-abc123'), isFalse);
      expect(msg, contains('***'));
    });

    test('Anthropic 401 回显的 Key 也被抹掉', () {
      const body = '{"type":"error","error":{"message":"invalid x-api-key: sk-ant-xyz"}}';
      final msg = anthropic.errorMessage(401, body, apiKey: 'sk-ant-xyz');
      expect(msg.contains('sk-ant-xyz'), isFalse);
    });

    test('不知道 Key 形状时按形状兜底（sk-/Bearer/api_key）', () {
      const p = AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      );
      final msg = p.errorMessage(
        401,
        '{"error":{"message":"bad key: sk-ant-abcdef123456, header Bearer zz-987654321, api_key=topsecret99"}}',
      );
      expect(msg.contains('sk-ant-abcdef123456'), isFalse);
      expect(msg.contains('zz-987654321'), isFalse);
      expect(msg.contains('topsecret99'), isFalse);
    });

    test('headers 的返回值含 Key 是设计（绝不能整体打日志）', () {
      final h = const AiProvider(
        format: AiApiFormat.openai, model: 'm', baseUrl: 'https://x',
      ).headers('sk-secret');
      expect(h.toString().contains('sk-secret'), isTrue);
    });
  });

  group('Key 校验', () {
    test('空 / 带空白都拦下', () {
      expect(AiProvider.validateApiKey(null), 'emptyKey');
      expect(AiProvider.validateApiKey('   '), 'emptyKey');
      expect(AiProvider.validateApiKey('sk a'), 'whitespaceInKey');
      expect(AiProvider.validateApiKey('sk-a\n'), 'whitespaceInKey');
      expect(AiProvider.validateApiKey('sk-abc'), isNull);
    });
  });
}
