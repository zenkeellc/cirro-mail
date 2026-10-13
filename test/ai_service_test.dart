import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/ai/ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假传输：把最后一次请求原封不动记下来，再回一段固定文本。
class RecordingTransport implements AiTransport {
  RecordingTransport({this.chunk});

  String? chunk;
  String? lastUrl;
  Map<String, String>? lastHeaders;
  Map<String, dynamic>? lastBody;
  String? lastMethod;
  String requestResponse = '{}';
  Object? requestError;

  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async {
    lastUrl = url;
    lastHeaders = headers;
    lastBody = body;
    if (chunk != null) onChunk(chunk!);
  }

  @override
  Future<String> request({
    required String method,
    required String url,
    required Map<String, String> headers,
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  }) async {
    lastMethod = method;
    lastUrl = url;
    lastHeaders = headers;
    lastBody = body;
    if (requestError != null) throw requestError!;
    return requestResponse;
  }
}

const fakeKey = 'sk-test-0123456789';

String openaiChunk(String text) =>
    'data: {"choices":[{"delta":{"content":"$text"}}]}\n\n';

/// 装上假钥匙串，返回那张内存表（用来反过来断言「写进去了什么」）。
///
/// 从 `ai_settings_store_test.dart` 照抄 —— harness 里用它往内存钥匙串里
/// 预置（或不预置）那把 Key。
Map<String, String> fakeKeychain([Map<String, String> initial = const {}]) {
  final data = Map<String, String>.of(initial);
  FlutterSecureStorage.setMockInitialValues(data);
  return data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingTransport transport;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    transport = RecordingTransport();
  });

  /// 这一条用例共享的那个传输（`setUp` 里建、既有断言都盯着它）。
  ///
  /// 单独拎成转发函数，是因为 `_service` 里那个同名参数会**遮蔽**外面这个：
  /// 不转发的话，`_service()`（不传 transport 的既有调用点）就会另造一个，
  /// 而用例仍去断言外面这个 —— 请求发出去的那一刻，`lastBody` 还是 null。
  RecordingTransport sharedTransport() => transport;

  Future<PrefsStore> prefs() async =>
      PrefsStore(await SharedPreferences.getInstance());

  /// 建一个已经配好的 service。[configured] 为 false 时不写 Key。
  ///
  /// [transport] 不传时自己造一个（记在局部、不落回顶层那个）；要断言「发出去
  /// 的请求体」的用例自己传一个进来，就与顶层那个共享的传输解耦了。
  ///
  /// **[settings] 这个参数与计划里的 `_service` 不同，是刻意留着的**：文件里
  /// 大量既有用例（Anthropic 通道、每日上限、拉列表）靠它换设置，去掉就没法
  /// 编译。保留同一个名字与默认值，既有调用点一个字不用改。
  // 名字按计划就叫 `_service`（局部函数），lint 不认这种命名 —— 计划原文如此。
  // ignore: no_leading_underscores_for_local_identifiers
  Future<AiService> _service({
    RecordingTransport? transport,
    bool configured = true,
    AiSettings settings = const AiSettings(
      apiFormat: AiApiFormat.openai,
      model: 'gpt-4o-mini',
    ),
    DateTime Function()? clock,
  }) async {
    final t = transport ?? sharedTransport();
    final p = await prefs();
    // Key 走内存钥匙串：`fakeKeychain` 装好 mock、再让 `AiSettingsStore` 用它
    // 默认的 `defaultSecureStorage()` 去读 —— 与既有用例「Key 只在请求头里」
    // 等断言同一套机制。（计划里的 `AiApiKeyStore(storage: fakeKeychain(...))`
    // 形状对不上真实 API：那是 `FlutterSecureStorage?`，不是 `Map`。）
    fakeKeychain(
      configured
          ? <String, String>{AiApiKeyStore.storageKey: fakeKey}
          : <String, String>{},
    );
    final store = AiSettingsStore(prefs: p);
    await store.save(settings);
    return AiService(
      store: store,
      usage: AiUsageCounter(prefs: p, clock: clock),
      client: AiClient(transport: t),
    );
  }

  group('没配 Key 时的降级', () {
    test('一次网络都不发，只给一句该去哪配', () async {
      final ai = await _service(configured: false);
      final start = await ai.rewrite(selection: '原文', tone: RewriteTone.polish);
      expect(start, isA<AiNotStarted>());
      expect((start as AiNotStarted).reason, contains('设置'));
      expect(transport.lastBody, isNull, reason: '没配 Key 就不该发请求');
    });

    test('地址是空的也算没配好', () async {
      // **为什么用假 store 而不是走真实的一个：** `AiSettingsStore.save()`
      // 落盘要过 `AiSettingsCodec`，而 codec **有意**把空/空白地址兜成默认
      // 地址（spec §2.3「宁可给一个能用的默认地址，也不要留一个空地址让用户
      // 无从下手」）。于是经由真实 store 保存 `baseUrl: ''` 再读回来是
      // `https://api.openai.com/v1` —— **根本到不了空地址那一支**。要测的是
      // `AiService` 自己那道 `isUsable` 闸（而不是 codec），就得绕过持久化。
      // 下一个人别以为这个假 store 是多余的：它测的是这里唯一能测到的方式。
      final ai = AiService(
        store: _EmptyAddressStore(),
        usage: AiUsageCounter(prefs: await prefs()),
        client: AiClient(transport: transport),
      );
      expect(await ai.subject(body: '正文'), isA<AiNotStarted>());
      expect(transport.lastBody, isNull, reason: '地址没填就不该发请求');
    });

    test('没配 Key 时不计数 —— 没花钱的事不该占额度', () async {
      final ai = await _service(configured: false);
      await ai.rewrite(selection: 'x', tone: RewriteTone.polish);
      expect(ai.usedToday, 0);
    });
  });

  group('每次都发得出去，并且内容对得上', () {
    test('四项能力的输出上限统一给一万（预算是上限不是用量）', () async {
      // 旧实现按任务给紧巴巴的数（改写 1024、续写与标题 256、检查 512）——
      // 省不下钱，代价却是频繁被截断：网关上的推理模型思考与正文共用这个预算，
      // 一次「润色」的思考就要 300–1500 个 token，正文常常一个字都产不出来。
      final ai = await _service();
      Future<num?> tokensOf(Future<AiStart> Function() call) async {
        await call();
        return transport.lastBody!['max_tokens'] as num?;
      }

      expect(await tokensOf(() => ai.rewrite(selection: '原文', tone: RewriteTone.polish)), 10000);
      expect(
        await tokensOf(() => ai.draft(
              points: '要点',
              tone: RewriteTone.formal,
              length: DraftLength.short,
            )),
        10000,
      );
      expect(await tokensOf(() => ai.continuation(context: '写到这儿，')), 10000);
      expect(await tokensOf(() => ai.subject(body: '正文')), 10000);
      expect(
        await tokensOf(() => ai.review(
              subject: '主题',
              body: '正文',
              attachmentCount: 0,
            )),
        10000,
      );
    });

    test('改写：请求体里带上原文与语气要求', () async {
      final ai = await _service();
      final start = await ai.rewrite(
        selection: '我们明天开会',
        tone: RewriteTone.formal,
      );
      expect(start, isA<AiStarted>());
      final prompt = (transport.lastBody!['messages'] as List).last
          as Map<String, dynamic>;
      expect(prompt['content'], contains('我们明天开会'));
      expect(prompt['content'], contains(RewriteTone.formal.instruction));
      expect(transport.lastUrl, 'https://api.openai.com/v1/chat/completions');
    });

    test('要点成文：带上要点、语气、篇幅，以及可选的收件人与主题', () async {
      final ai = await _service();
      await ai.draft(
        points: '一：周五前交付\n二：预算不变',
        tone: RewriteTone.friendly,
        length: DraftLength.short,
        subject: '进度同步',
        recipient: '张工',
      );
      final content =
          ((transport.lastBody!['messages'] as List).last as Map)['content']
              as String;
      expect(content, contains('周五前交付'));
      expect(content, contains(RewriteTone.friendly.instruction));
      expect(content, contains(DraftLength.short.instruction));
      expect(content, contains('进度同步'));
      expect(content, contains('张工'));
    });

    test('续写：预算也走统一的输出上限（预算是上限不是用量）', () async {
      final ai = await _service();
      await ai.continuation(context: '前面写到这儿，');
      // 续写本身只该吐一两句，但**预算照样给足**：网关上的推理模型思考与正文
      // 共用这个预算，给紧（旧值 256）时思考吃光预算、连那一句都产不出来
      // —— 用户看到的是「AI 没有返回内容，请重试」。真写多了由幽灵浮层
      // 自己封行数（`_GhostBubble` 的 maxLines）。
      expect(transport.lastBody!['max_tokens'], 10000);
      expect(
        ((transport.lastBody!['messages'] as List).last as Map)['content'],
        contains('前面写到这儿，'),
      );
    });

    test('标题生成：只要一个，且不问「几个候选」', () async {
      final ai = await _service();
      await ai.subject(body: '正文内容');
      final content =
          ((transport.lastBody!['messages'] as List).last as Map)['content']
              as String;
      expect(content, contains('正文内容'));
      // 以前这里写的是「起 N 个候选」；候选面板拆掉之后一句话就够，
      // prompt 里不该再出现「个候选」这种要求。
      expect(content, isNot(contains('个候选')));
    });

    test('标题生成：已有一个主题时，把它当参考带进 prompt', () async {
      final ai = await _service();
      await ai.subject(body: '正文内容', current: '关于周四评审');
      final content =
          ((transport.lastBody!['messages'] as List).last as Map)['content']
              as String;
      expect(content, contains('关于周四评审'), reason: '已有主题要进 prompt 当参考');
    });

    test('标题生成：主题为空或纯空白 → 不带那一段', () async {
      final ai = await _service();
      await ai.subject(body: '正文内容', current: '   ');
      final content =
          ((transport.lastBody!['messages'] as List).last as Map)['content']
              as String;
      expect(content, isNot(contains('已经写了一个主题')));
    });

    test('标题生成：抠出第一行、清掉「主题：」前缀与引号', () {
      expect(AiPrompts.subjectLineIn('周四评审顺延'), '周四评审顺延');
      expect(AiPrompts.subjectLineIn('主题：周四评审顺延'), '周四评审顺延');
      expect(AiPrompts.subjectLineIn('标题: 周四评审顺延\n第二行'), '周四评审顺延');
      expect(AiPrompts.subjectLineIn('Subject: Meeting moved'), 'Meeting moved');
      expect(AiPrompts.subjectLineIn('「周四评审顺延」'), '周四评审顺延');
      expect(AiPrompts.subjectLineIn('- 周四评审顺延'), '周四评审顺延');
      // 一行都没捞到 → null（调用方据此什么都不做，而不是往主题栏填个空）。
      expect(AiPrompts.subjectLineIn('  \n \n'), isNull);
      expect(AiPrompts.subjectLineIn('主题：'), isNull);
    });

    test('发送前检查：把主题、附件数、正文都交给模型', () async {
      final ai = await _service();
      await ai.review(subject: '周报', body: '详见附件', attachmentCount: 2);
      final content =
          ((transport.lastBody!['messages'] as List).last as Map)['content']
              as String;
      expect(content, contains('周报'));
      expect(content, contains('详见附件'));
      expect(content, contains('2'));
    });

    test('system 走厂商各自的通道，不混进 user 消息', () async {
      final ai = await _service();
      await ai.subject(body: 'x');
      final messages = transport.lastBody!['messages'] as List;
      expect((messages.first as Map)['role'], 'system');
      expect((messages.last as Map)['content'], isNot(contains('邮件写作助手，直接输出')));
    });

    test('Anthropic：system 是顶层字段，Key 走 x-api-key 头', () async {
      final ai = await _service(
        settings: const AiSettings(
          apiFormat: AiApiFormat.anthropic,
          model: 'claude-x',
          baseUrl: AiSettings.anthropicDefaultBase,
        ),
      );
      await ai.rewrite(selection: 'x', tone: RewriteTone.polish);
      expect(transport.lastBody!['system'], contains('邮件写作助手'));
      expect(transport.lastHeaders!['x-api-key'], fakeKey);
      expect(transport.lastHeaders!.containsKey('authorization'), isFalse);
    });
  });

  group('Key 与额度', () {
    test('Key 只在请求头里，请求体里搜不到', () async {
      final ai = await _service();
      await ai.rewrite(selection: 'x', tone: RewriteTone.polish);
      expect(transport.lastHeaders!['authorization'], 'Bearer $fakeKey');
      expect(transport.lastBody.toString(), isNot(contains(fakeKey)));
      expect(transport.lastBody.toString(), isNot(contains('sk-')));
    });

    test('每发一次记一次', () async {
      final ai = await _service();
      await ai.subject(body: 'a');
      await ai.subject(body: 'b');
      await ai.subject(body: 'c');
      expect(ai.usedToday, 3);
    });

    test('超了每日上限：还能调用，但会告诉界面超了（软上限）', () async {
      final ai = await _service(
        settings: const AiSettings(
          apiFormat: AiApiFormat.openai,
          model: 'gpt-4o-mini',
          dailyCallLimit: 2,
        ),
      );
      await ai.subject(body: 'a');
      await ai.subject(body: 'b');
      expect(ai.overDailyLimit(const AiSettings(dailyCallLimit: 2)), isTrue);
      // 软上限：提示归提示，调用照发 —— 拦住用户比多花几分钱更糟。
      expect(await ai.subject(body: 'c'), isA<AiStarted>());
    });

    test('上限 0 = 不限，永远不喊超', () async {
      final ai = await _service(
        settings: const AiSettings(
          apiFormat: AiApiFormat.openai,
          model: 'gpt-4o-mini',
          dailyCallLimit: 0,
        ),
      );
      for (var i = 0; i < 5; i++) {
        await ai.subject(body: 'x');
      }
      expect(ai.overDailyLimit(const AiSettings(dailyCallLimit: 0)), isFalse);
    });

    test('跨天之后额度回满', () async {
      var now = DateTime(2026, 10, 10, 23);
      final ai = await _service(
        settings: const AiSettings(
          apiFormat: AiApiFormat.openai,
          model: 'gpt-4o-mini',
          dailyCallLimit: 1,
        ),
        clock: () => now,
      );
      await ai.subject(body: 'a');
      expect(ai.overDailyLimit(const AiSettings(dailyCallLimit: 1)), isTrue);

      now = DateTime(2026, 10, 11, 0, 5);
      expect(ai.usedToday, 0);
      expect(ai.overDailyLimit(const AiSettings(dailyCallLimit: 1)), isFalse);
    });
  });

  group('端到端能拿回文本', () {
    test('拿得到流里的文本，done 给出完整结果', () async {
      transport.chunk = '${openaiChunk('你好')}${openaiChunk('世界')}'
          'data: [DONE]\n\n';
      final ai = await _service();
      final start = await ai.rewrite(
        selection: 'x',
        tone: RewriteTone.polish,
      ) as AiStarted;

      final seen = <String>[];
      start.stream.text.listen(seen.add);
      expect(await start.stream.done, '你好世界');
      expect(seen.join(), '你好世界');
    });

    test('厂商报错 → done 抛出给人看的话（界面据此提示，而不是当成成功）',
        () async {
      final p = await prefs();
      final store = AiSettingsStore(prefs: p);
      await store.save(const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: 'gpt-4o-mini',
      ));
      await store.setApiKey(fakeKey);
      final failing = AiService(
        store: store,
        usage: AiUsageCounter(prefs: p),
        client: AiClient(transport: _FailingTransport()),
      );

      final bad = await failing.rewrite(selection: 'x', tone: RewriteTone.polish)
          as AiStarted;
      await expectLater(bad.stream.done, throwsA(isA<AiTransportException>()));
      // 顺带确认报错文案是被厂商适配层压过的那一句，而不是整段 JSON，
      // 更不是 Key。
      try {
        await bad.stream.done;
      } on AiTransportException catch (e) {
        expect(e.statusCode, 401);
        expect(e.message, isNot(contains('sk-')));
      }
    });
  });

  group('parseLines（模型吐的「每行一条」清洗）', () {
    test('只剥真正的序号，句子开头的数字要保住', () {
      // L-1：原正则 `^[-*\d.、)\s]+` 把开头的数字一起吃了。
      expect(AiPrompts.parseLines('50% 的人会误解这句话'), ['50% 的人会误解这句话']);
      expect(AiPrompts.parseLines('3.14 是圆周率'), ['3.14 是圆周率']);
      expect(AiPrompts.parseLines('2024. 年份写法'), ['2024. 年份写法']);
    });

    test('真正的序号仍被剥掉（-、*、1.、1、、(1)）', () {
      expect(AiPrompts.parseLines('- 第一条'), ['第一条']);
      expect(AiPrompts.parseLines('* 第二条'), ['第二条']);
      expect(AiPrompts.parseLines('1. 第三条'), ['第三条']);
      expect(AiPrompts.parseLines('1、第四条'), ['第四条']);
      expect(AiPrompts.parseLines('(1) 第五条'), ['第五条']);
      expect(AiPrompts.parseLines('2) 第六条'), ['第六条']);
    });

    test('空行与「没有问题」被丢掉', () {
      expect(AiPrompts.parseLines('没有问题'), isEmpty);
      expect(AiPrompts.parseLines('\n\n'), isEmpty);
    });
  });

  group('列模型', () {
    test('成功：GET 到 modelsEndpoint，带 Bearer，非流式头', () async {
      final p = await prefs();
      final store = AiSettingsStore(prefs: p);
      await store.save(const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.openai.com/v1',
      ));
      await store.setApiKey(fakeKey);
      transport.requestResponse = '{"data":[{"id":"gpt-4o"},{"id":"gpt-4o-mini"}]}';
      final ai = AiService(
        store: store,
        usage: AiUsageCounter(prefs: p),
        client: AiClient(transport: transport),
      );

      final result = await ai.listModels();
      expect(result, isA<AiModelsOk>());
      expect((result as AiModelsOk).models, ['gpt-4o', 'gpt-4o-mini']);
      expect(transport.lastMethod, 'GET');
      expect(transport.lastUrl, 'https://api.openai.com/v1/models');
      expect(transport.lastHeaders!['authorization'], 'Bearer $fakeKey');
      expect(transport.lastHeaders!.containsKey('accept'), isFalse,
          reason: '非流式请求不该声明 accept: text/event-stream');
    });

    test('Anthropic 格式打到 /v1/models，用 x-api-key', () async {
      final p = await prefs();
      final store = AiSettingsStore(prefs: p);
      await store.save(const AiSettings(
        apiFormat: AiApiFormat.anthropic,
        model: 'claude-x',
        baseUrl: 'https://api.anthropic.com',
      ));
      await store.setApiKey(fakeKey);
      transport.requestResponse = '{"data":[{"id":"claude-x"}]}';
      final ai = AiService(
        store: store, usage: AiUsageCounter(prefs: p),
        client: AiClient(transport: transport),
      );

      await ai.listModels();
      expect(transport.lastUrl, 'https://api.anthropic.com/v1/models');
      expect(transport.lastHeaders!['x-api-key'], fakeKey);
    });

    test('端点回 200 但一条模型名都没有 → 空列表的成功（不是失败）', () async {
      final ai = await _service();
      transport.requestResponse = '{"nope":true}';
      final result = await ai.listModels();
      expect(result, isA<AiModelsOk>());
      expect((result as AiModelsOk).models, isEmpty);
    });

    test('HTTP 404 → 失败，文案是脱敏后的厂商原文', () async {
      final ai = await _service();
      transport.requestError = const AiTransportException(
        '{"error":{"message":"no models endpoint"}}',
        statusCode: 404,
      );
      final result = await ai.listModels();
      expect(result, isA<AiModelsFailed>());
      expect((result as AiModelsFailed).message, 'no models endpoint');
    });

    test('失败文案里的 Key 被抹掉', () async {
      final ai = await _service();
      transport.requestError = AiTransportException(
        '{"error":{"message":"bad key: $fakeKey"}}',
        statusCode: 401,
      );
      final result = await ai.listModels();
      expect((result as AiModelsFailed).message.contains(fakeKey), isFalse);
      expect(result.message, contains('***'));
    });

    test('不是 AiTransportException 的错 → 一句笼统的话，不倒原始对象', () async {
      final ai = await _service();
      transport.requestError = Exception('boom');
      final result = await ai.listModels();
      expect(result, isA<AiModelsFailed>());
      expect((result as AiModelsFailed).message, '请求失败');
    });

    test('没配好 → 一次网络都不发，给一句去设置页的话', () async {
      final ai = await _service(configured: false);
      final result = await ai.listModels();
      expect(result, isA<AiModelsFailed>());
      expect((result as AiModelsFailed).message, contains('设置'));
      expect(transport.lastUrl, isNull);
    });

    test('不计入每日用量（它是配置动作，不生成内容）', () async {
      final ai = await _service();
      transport.requestResponse = '{"data":[{"id":"m"}]}';
      await ai.listModels();
      expect(ai.usedToday, 0);
    });

    test('**还没有模型名**照样发得出去 —— 这一项就是去拿模型名的', () async {
      // 门槛只有「地址 + Key」（`AiSettings.hasEndpoint`）。用 `isUsable` 卡的话
      // 设置页那颗亮着的「拉取」点了只回「还没有配置 AI」—— 用户刚填完地址和 Key。
      final ai = await _service(settings: const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: '',
        baseUrl: 'https://api.openai.com/v1',
      ));
      transport.requestResponse = '{"data":[{"id":"gpt-4o"}]}';
      final result = await ai.listModels();
      expect(result, isA<AiModelsOk>());
      expect((result as AiModelsOk).models, ['gpt-4o']);
      expect(transport.lastUrl, 'https://api.openai.com/v1/models');
    });

    test('地址空 / 没 Key 仍然拦住（「不要模型名」不等于「什么都不要」）', () async {
      final ai = AiService(
        store: _EmptyAddressStore(),
        usage: AiUsageCounter(prefs: await prefs()),
        client: AiClient(transport: transport),
      );
      final result = await ai.listModels();
      expect(result, isA<AiModelsFailed>());
      expect(transport.lastUrl, isNull, reason: '地址没填就不该发请求');
    });
  });

  group('测试连接', () {
    test('成功：走真实生成，stream: false，maxTokens 够模型把话说完', () async {
      final ai = await _service();
      transport.requestResponse = '{"choices":[{"message":{"content":"pong"}}]}';
      final result = await ai.testConnection();
      expect(result, isA<AiTestOk>());
      expect((result as AiTestOk).chars, 4);
      expect(transport.lastMethod, 'POST');
      expect(transport.lastUrl, 'https://api.openai.com/v1/chat/completions');
      expect(transport.lastBody!['stream'], isFalse);
      // **不是「越小越好」**：推理模型先思考再答、两者共用这个预算，给 8 个
      // token 时思考就吃光了，`content` 必然空（实测 8/16/32/64 全截断，128 才
      // 稳定出可见文本）。掉到那一支不算失败，但界面上就只剩「没回可见文本」
      // 那句 —— 256 让「返回了 N 个字」里的 N 稳定是个真数字。
      expect(transport.lastBody!['max_tokens'], 256);
      expect(transport.lastBody!['model'], 'gpt-4o-mini');
    });

    test('Anthropic 非流式的 content[].text 也认（chars 就是那段文本的长度）', () async {
      final ai = await _service(settings: const AiSettings(
        apiFormat: AiApiFormat.anthropic,
        model: 'claude-x',
        baseUrl: 'https://api.anthropic.com',
      ));
      transport.requestResponse =
          '{"content":[{"type":"text","text":"pong"}]}';
      final result = await ai.testConnection();
      expect(result, isA<AiTestOk>());
      // 改前这里只能是 0（textDelta 不认识 Anthropic 的非流式壳），界面上会
      // 显示「连接正常，模型返回了 0 个字」—— 成功横幅读起来像失败。
      expect((result as AiTestOk).chars, 4);
    });

    test('200 但不是接口响应（地址少了 /v1）→ 失败，而不是「返回了 0 个字」', () async {
      // 真机上踩到的那一次：地址填成 `https://api.example.net:1444`（少了
      // `/v1`），而那个中转站是个带前端的网关 —— 它对不存在的路径回自己的
      // **首页 HTML**，HTTP 200、`content-type: text/html`。于是 textDelta
      // 抠不出文本，旧实现给出 `AiTestOk(chars: 0)`，界面上写着「连接正常，
      // 模型返回了 0 个字」，而真实生成一条都发不出去。
      //
      // spec §6.5 早就把判据写死了：「成功判据是请求成功返回」指的是**接口**
      // 成功返回，不是「有个 200」。回不出文本就说明打到的不是接口。
      final ai = await _service(
        settings: const AiSettings(
          apiFormat: AiApiFormat.openai,
          model: 'gpt-4o-mini',
          baseUrl: 'https://api.example.net:1444',
        ),
      );
      transport.requestResponse =
          '<!doctype html><html lang="en"><head><title>New API</title></head></html>';
      final result = await ai.testConnection();
      expect(result, isA<AiTestFailed>());
      // 文案要能指路：只说「请求失败」用户还是不知道少了 `/v1`。
      expect((result as AiTestFailed).message, contains('/v1'));
    });

    test('200 但零字节 → 同样的失败（不许把空响应当成通了）', () async {
      final ai = await _service();
      transport.requestResponse = '';
      final result = await ai.testConnection();
      expect(result, isA<AiTestFailed>());
      expect((result as AiTestFailed).message, contains('/v1'));
    });

    test('推理模型：content 空、只有 reasoning_content → 通，chars 为 0', () async {
      // 实测形状：`max_tokens: 8` 打 `deepseek-v4-1-flash`（推理模型）必然如此。
      // 思考也算这次模型真跑出来的内容 —— 端点、Key、模型名三样都对。
      final ai = await _service();
      transport.requestResponse = '{"choices":[{"message":'
          '{"role":"assistant","content":"","reasoning_content":"The user just said ping…"}}]}';
      final result = await ai.testConnection();
      expect(result, isA<AiTestOk>());
      expect((result as AiTestOk).chars, 0);
    });

    test('Anthropic 只回了 thinking 块、没有 text 块 → 同样算通', () async {
      final ai = await _service(settings: const AiSettings(
        apiFormat: AiApiFormat.anthropic,
        model: 'claude-x',
        baseUrl: 'https://api.anthropic.com',
      ));
      transport.requestResponse =
          '{"id":"msg_1","type":"message","role":"assistant",'
          '"content":[{"type":"thinking","thinking":"让我想想…"}],"stop_reason":"max_tokens"}';
      expect(await ai.testConnection(), isA<AiTestOk>());
    });

    test('content 与思考都是空的 → 失败（没真回内容）', () async {
      final ai = await _service();
      transport.requestResponse = '{"choices":[{"message":{"role":"assistant","content":""}}]}';
      expect(await ai.testConnection(), isA<AiTestFailed>());
    });

    test('模型名不对 → 失败的原文透出来（列表拉得到不代表名字对）', () async {
      final ai = await _service();
      transport.requestError = const AiTransportException(
        '{"error":{"message":"The model `nope` does not exist"}}',
        statusCode: 404,
      );
      final result = await ai.testConnection();
      expect(result, isA<AiTestFailed>());
      expect((result as AiTestFailed).message, contains('does not exist'));
    });

    test('没配好（少了模型名）→ 一次网络都不发', () async {
      final ai = await _service(settings: const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: '',
        baseUrl: 'https://api.openai.com/v1',
      ));
      final result = await ai.testConnection();
      expect(result, isA<AiTestFailed>());
      expect(transport.lastUrl, isNull);
    });

    test('不计入每日用量', () async {
      final ai = await _service();
      transport.requestResponse = '{"choices":[{"message":{"content":"pong"}}]}';
      await ai.testConnection();
      expect(ai.usedToday, 0);
    });
  });

  group('AI 建议（⑥）', () {
    test('suggest 把动作池与来信正文发出去，走自己的 system', () async {
      final transport = RecordingTransport();
      final service = await _service(transport: transport);
      final start = await service.suggest(
        input: '主题：上线时间\n正文：会议时间定了吗？',
        actionIds: const <String>['reply', 'none'],
      );
      expect(start, isA<AiStarted>());
      // 自己的 system（不是那句「邮件写作助手」）
      final messages = (transport.lastBody!['messages'] as List).cast<Map>();
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], contains('只输出一个 JSON 对象'));
      expect(messages.first['content'], isNot(contains('邮件写作助手')));
      // 正文与池子都在 user 那一句里
      expect(messages.last['content'], contains('会议时间定了吗？'));
      expect(messages.last['content'], contains('- none：'));
      // **温度 0.3**：这一路的输出要被程序解析并执行，不是给人读的文本。
      // 没有这条断言的话，`temperature: 0.3` 被删掉（退回 `_start` 的默认
      // 0.7）时一条用例都不会红 —— 而那正是这条链路唯一的非功能性约束。
      expect(transport.lastBody!['temperature'], 0.3);
    });

    test('既有五条路的 system 一个字没变（_start 的默认值仍在）', () async {
      final transport = RecordingTransport();
      final service = await _service(transport: transport);
      await service.replySuggestions(incoming: '来信正文');
      final messages = (transport.lastBody!['messages'] as List).cast<Map>();
      expect(messages.first['content'], '你是一个邮件写作助手，直接输出结果本身，不要任何寒暄与说明。');
    });

    test('suggest 也吃每日上限（与新能力一致）', () async {
      final transport = RecordingTransport();
      final service = await _service(transport: transport, clock: () => DateTime(2026, 10, 11));
      final before = service.usedToday;
      await service.suggest(input: '正文', actionIds: const <String>['none']);
      expect(service.usedToday, before + 1);
    });
  });
}

/// 一发请求就报 401。
class _FailingTransport implements AiTransport {
  @override
  Future<void> send({
    required String url,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required void Function(String chunk) onChunk,
    required CancelToken cancelToken,
  }) async =>
      throw AiTransportException('{"error":"invalid key"}', statusCode: 401);

  @override
  Future<String> request({
    required String method,
    required String url,
    required Map<String, String> headers,
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  }) async =>
      throw AiTransportException('{"error":"invalid key"}', statusCode: 401);
}

/// 只回答「地址是空的」那个 store —— 见「地址是空的也算没配好」那条用例里的
/// 注释：真实 store 落盘要过 codec，而 codec 会把空地址兜成默认地址，所以
/// 只有绕过持久化才测得到 `AiService` 自己那道 `isUsable` 闸。
///
/// `noSuchMethod` 兜住其余成员（`AiService` 只用到 `load` / `readApiKey` /
/// `isKeychainDegraded`）—— 与 Task 8 里 `_FakeAiService` 是同一个套路。
class _EmptyAddressStore implements AiSettingsStore {
  @override
  Future<AiSettings> load() async => const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: 'my-model',
        baseUrl: '', // 用户把地址栏清空了
        hasApiKey: true,
      );

  @override
  Future<String?> readApiKey() async => fakeKey;

  @override
  bool get isKeychainDegraded => false;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('这条用例只走 ${invocation.memberName}');
}
