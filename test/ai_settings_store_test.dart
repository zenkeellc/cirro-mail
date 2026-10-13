// 下面这个 import 是为了替换 `FlutterSecureStoragePlatform.instance`（制造
// 「钥匙串坏了」的降级场景）。平台接口是 `flutter_secure_storage` 的**传递**
// 依赖，它自己的库只 re-export 了枚举、没导出这个基类，所以只能直接 import。
// 计划里没打算动 pubspec（依赖多了会牵动解析），这里就用一行 ignore 说明。
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/ai/ai_settings_store.dart';

/// 一个**读写都失败**的密钥库 —— 对应「Linux 没装 libsecret」「macOS 钥匙串
/// 被锁」「插件没注册」这几种真会发生的降级情形。
class _BrokenKeychain extends FlutterSecureStoragePlatform {
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async =>
      throw PlatformException(code: '-34018', message: 'errSecMissingEntitlement');

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async =>
      throw PlatformException(code: '-34018', message: 'errSecMissingEntitlement');

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async =>
      throw PlatformException(code: '-34018', message: 'errSecMissingEntitlement');

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      false;

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      const <String, String>{};

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {}
}

/// 装上假钥匙串，返回那张内存表（用来反过来断言「写进去了什么」）。
Map<String, String> fakeKeychain([Map<String, String> initial = const {}]) {
  final data = Map<String, String>.of(initial);
  FlutterSecureStorage.setMockInitialValues(data);
  return data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fakeKey = 'sk-ant-0123456789abcdef';

  setUp(() {
    fakeKeychain();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<PrefsStore> prefs() async =>
      PrefsStore(await SharedPreferences.getInstance());

  group('AiSettingsCodec', () {
    test('往返：非默认值一个不丢', () {
      const s = AiSettings(
        apiFormat: AiApiFormat.anthropic,
        model: 'claude-x',
        baseUrl: 'https://proxy.example.com/v1',
        inlineContinuationEnabled: true,
        preflightEnabled: false,
        subjectSuggestEnabled: false,
        polishEnabled: false,
        dailyCallLimit: 42,
        mailSuggestEnabled: false,
      );
      final back = AiSettingsCodec.decode(jsonEncode(AiSettingsCodec.encode(s)));
      expect(back.apiFormat, AiApiFormat.anthropic);
      expect(back.model, 'claude-x');
      expect(back.baseUrl, 'https://proxy.example.com/v1');
      expect(back.inlineContinuationEnabled, isTrue);
      expect(back.preflightEnabled, isFalse);
      expect(back.subjectSuggestEnabled, isFalse);
      expect(back.polishEnabled, isFalse);
      expect(back.dailyCallLimit, 42);
      expect(back.mailSuggestEnabled, isFalse);
    });

    test('老配置里没有 polish 键 → 润色入口默认开（不是被这个缺失关掉）', () {
      // `polish` 是后加的键。老配置里它不存在，`_bool(null)` 给 null —— 必须
      // 退回默认的「开」，否则升级一次就把润色入口静悄悄关了。
      final s = AiSettingsCodec.decode(jsonEncode(<String, dynamic>{
        'apiFormat': 'openai',
        'model': 'm',
        'subjectSuggest': false, // 有这个、没 polish，模拟真实老配置
      }));
      expect(s.polishEnabled, isTrue);
      expect(s.subjectSuggestEnabled, isFalse, reason: '已有的键照旧读');
    });

    test('老配置里没有 suggest 键 → AI 建议入口默认开（不是被这个缺失关掉）', () {
      final decoded = AiSettingsCodec.decode(<String, dynamic>{
        'apiFormat': 'openai',
        'model': 'm',
        'subjectSuggest': false,
      });
      expect(decoded.mailSuggestEnabled, isTrue);
      expect(decoded.subjectSuggestEnabled, isFalse);
    });

    test('suggest 明确写成 false 时要真的关掉', () {
      final decoded = AiSettingsCodec.decode(<String, dynamic>{
        'apiFormat': 'openai',
        'model': 'm',
        'suggest': false,
      });
      expect(decoded.mailSuggestEnabled, isFalse);
    });

    test('encode 的输出是纯 JSON 值，不是字符串再套一层', () {
      final map = AiSettingsCodec.encode(const AiSettings());
      expect(map['apiFormat'], isA<String>());
      expect(jsonDecode(jsonEncode(map)), isA<Map<String, dynamic>>());
    });

    test('没存过 → 默认值', () {
      expect(AiSettingsCodec.decode(null), const AiSettings());
    });

    test('存进去的不是 JSON → 当没配过（不抛）', () {
      expect(AiSettingsCodec.decode('这不是 JSON'), const AiSettings());
      expect(AiSettingsCodec.decode(''), const AiSettings());
      expect(AiSettingsCodec.decode('   '), const AiSettings());
    });

    test('JSON 结构不对 → 默认值（数组、数字、字符串 JSON）', () {
      expect(AiSettingsCodec.decode('[1,2,3]'), const AiSettings());
      expect(AiSettingsCodec.decode('42'), const AiSettings());
      expect(AiSettingsCodec.decode('"abc"'), const AiSettings());
      expect(AiSettingsCodec.decode(jsonEncode(<String, dynamic>{})),
          const AiSettings());
    });

    test('未知格式名 → 回退到 openai', () {
      final s = AiSettingsCodec.decode(jsonEncode(<String, dynamic>{
        'apiFormat': 'gemini',
        'baseUrl': 'https://x',
        'model': 'm',
      }));
      expect(s.apiFormat, AiApiFormat.openai);
    });

    test('newapi 这个格式名读得回来（不是「未知格式」那条路）', () {
      final s = AiSettingsCodec.decode(jsonEncode(<String, dynamic>{
        'apiFormat': 'newapi',
        'baseUrl': 'https://api.example.net:1444',
        'model': 'gpt-4o-mini',
      }));
      expect(s.apiFormat, AiApiFormat.newapi);
      expect(s.baseUrl, 'https://api.example.net:1444');
    });

    test('字段类型不对 → 只有那一个退回默认，其余照旧', () {
      final s = AiSettingsCodec.decode(jsonEncode(<String, dynamic>{
        'apiFormat': 'anthropic',
        'baseUrl': 'https://x',
        'model': 'claude-x',
        'preflight': 'yes', // 该是 bool
        'dailyCallLimit': '200', // 该是 int
        'inlineContinuation': true,
      }));
      expect(s.apiFormat, AiApiFormat.anthropic);
      expect(s.model, 'claude-x');
      expect(s.preflightEnabled, isTrue, reason: '退回默认值 = 开');
      expect(s.dailyCallLimit, 200, reason: '退回默认值');
      expect(s.inlineContinuationEnabled, isTrue);
    });

    test('多余的键被忽略（向前兼容：新版本写的键，旧版本读不炸）', () {
      final s = AiSettingsCodec.decode(jsonEncode(<String, dynamic>{
        'apiFormat': 'openai',
        'model': 'm',
        'futureSetting': <String, dynamic>{'nested': true},
      }));
      expect(s.apiFormat, AiApiFormat.openai);
      expect(s.model, 'm');
    });

    test('新格式但 model / baseUrl 空或纯空白 → 退回默认（空模型 + 默认地址）', () {
      final s = AiSettingsCodec.decode(jsonEncode(<String, dynamic>{
        'apiFormat': 'anthropic',
        'model': '   ', // 只有空白
        'baseUrl': '', // 空串
      }));
      expect(s.apiFormat, AiApiFormat.anthropic);
      expect(s.model, isEmpty, reason: '拿不出可用模型名时退回默认的空模型');
      expect(s.baseUrl, AiSettings.openaiDefaultBase,
          reason: '拿不出可用地址时退回默认地址');
      expect(s.isUsable, isFalse, reason: '模型空、没地址就不可用');
    });

    test('两边键都在 → 新格式胜出：vendor 被忽略，model / baseUrl 按新格式读', () {
      final s = AiSettingsCodec.decode(jsonEncode(<String, dynamic>{
        'vendor': 'anthropic',
        'apiFormat': 'openai',
        'model': 'gpt-4o',
        'baseUrl': 'https://new.example.com/v1',
      }));
      expect(s.apiFormat, AiApiFormat.openai);
      expect(s.model, 'gpt-4o', reason: '有 apiFormat 就是新格式，model 照读');
      expect(s.baseUrl, 'https://new.example.com/v1');
    });

    group('老配置（含 vendor 键的那种）→ 三个模型键忽略，偏好键照旧读', () {
      test('vendor / model / baseUrl 一律不算数：地址回默认、模型清空', () {
        final s = AiSettingsCodec.decode(jsonEncode(<String, dynamic>{
          'vendor': 'anthropic',
          'model': 'claude-fable-5-1',
          'baseUrl': 'https://old.example.com/v1/chat/completions',
        }));
        expect(s.apiFormat, AiApiFormat.openai);
        expect(s.baseUrl, AiSettings.openaiDefaultBase,
            reason: '宁可给一个能用的默认地址，也不要留一个空地址让用户无从下手');
        expect(s.model, isEmpty,
            reason: '老模型名是绑在老厂商上的，切到 openai 格式后拿它去打只会 404');
      });

      test('偏好键照旧读得回来（它们与端点无关）', () {
        final s = AiSettingsCodec.decode(jsonEncode(<String, dynamic>{
          'vendor': 'deepseek',
          'inlineContinuation': true,
          'preflight': false,
          'subjectSuggest': false,
          'polish': false,
          'dailyCallLimit': 7,
        }));
        expect(s.inlineContinuationEnabled, isTrue);
        expect(s.preflightEnabled, isFalse);
        expect(s.subjectSuggestEnabled, isFalse);
        expect(s.polishEnabled, isFalse);
        expect(s.dailyCallLimit, 7);
      });
    });

    test('JSON 里就算手写了 apiKey/hasApiKey 也不算数', () {
      final s = AiSettingsCodec.decode(jsonEncode(<String, dynamic>{
        'apiFormat': 'openai',
        'model': 'm',
        'apiKey': fakeKey,
        'hasApiKey': true,
      }));
      expect(s.hasApiKey, isFalse, reason: '有没有 Key 只有钥匙串说了算');
    });

    test('编码结果里没有 Key —— 这个类型根本装不下它', () {
      const s = AiSettings(hasApiKey: true, model: 'm');
      final json = jsonEncode(AiSettingsCodec.encode(s));
      expect(json.contains('key'), isFalse);
      expect(json, isNot(contains('sk-')));
      expect(s.toString(), isNot(contains(fakeKey)));
    });
  });

  group('AiApiKeyStore', () {
    test('没写过 → null', () async {
      expect(await AiApiKeyStore().read(), isNull);
    });

    test('写进去能读回来，首尾空白被去掉', () async {
      final store = AiApiKeyStore();
      await store.write('  $fakeKey\n');
      expect(await store.read(), fakeKey);
    });

    test('Key 落在钥匙串里，不在别处', () async {
      final chain = fakeKeychain();
      await AiApiKeyStore(storage: const FlutterSecureStorage()).write(fakeKey);
      expect(chain[AiApiKeyStore.storageKey], fakeKey);
      expect(chain.length, 1, reason: '写一次只该产生一条记录');
    });

    test('写空串 = 删除（用户把输入框清空再保存）', () async {
      final chain = fakeKeychain({AiApiKeyStore.storageKey: fakeKey});
      await AiApiKeyStore(storage: const FlutterSecureStorage()).write('   ');
      expect(chain.containsKey(AiApiKeyStore.storageKey), isFalse);
    });

    test('delete 之后读回 null', () async {
      final store = AiApiKeyStore();
      await store.write(fakeKey);
      await store.delete();
      expect(await store.read(), isNull);
    });

    test('钥匙串里是空白串 → 当作没配', () async {
      fakeKeychain({AiApiKeyStore.storageKey: '   '});
      expect(await AiApiKeyStore(storage: const FlutterSecureStorage()).read(),
          isNull);
    });

    test('读失败 → 返回 null 且标记降级（不抛到调用方）', () async {
      FlutterSecureStoragePlatform.instance = _BrokenKeychain();
      final store = AiApiKeyStore();
      expect(await store.read(), isNull);
      expect(store.isDegraded, isTrue);
    });

    test('写失败 → 不抛，并标记降级', () async {
      FlutterSecureStoragePlatform.instance = _BrokenKeychain();
      final store = AiApiKeyStore();
      await store.write(fakeKey);
      expect(store.isDegraded, isTrue);
    });

    test('降级之后写成功一次就恢复（钥匙串只是暂时被锁）', () async {
      FlutterSecureStoragePlatform.instance = _BrokenKeychain();
      final store = AiApiKeyStore();
      await store.write(fakeKey);
      expect(store.isDegraded, isTrue);

      fakeKeychain();
      await store.write(fakeKey);
      expect(store.isDegraded, isFalse);
      expect(await store.read(), fakeKey);
    });

    test('toString 里没有 Key（诊断日志会打它）', () async {
      final store = AiApiKeyStore();
      await store.write(fakeKey);
      expect(store.toString(), isNot(contains(fakeKey)));
      expect(store.toString(), isNot(contains('sk-')));
    });
  });

  group('AiSettingsStore', () {
    test('没配过 → 默认设置 + 没有 Key', () async {
      final store = AiSettingsStore(prefs: await prefs());
      final s = await store.load();
      expect(s, const AiSettings());
      expect(s.hasApiKey, isFalse);
      expect(s.isUsable, isFalse);
    });

    test('两个半区都存了 → 合成一个完整设置', () async {
      final store = AiSettingsStore(prefs: await prefs());
      await store.save(const AiSettings(
        apiFormat: AiApiFormat.openai,
        model: 'gpt-4o',
        preflightEnabled: false,
      ));
      await store.setApiKey(fakeKey);

      final loaded = await store.load();
      expect(loaded.apiFormat, AiApiFormat.openai);
      expect(loaded.model, 'gpt-4o');
      expect(loaded.preflightEnabled, isFalse);
      expect(loaded.hasApiKey, isTrue);
      expect(loaded.isUsable, isTrue);
    });

    test('save 不碰钥匙串：改设置不会把 Key 写没，也不会写进去', () async {
      final chain = fakeKeychain();
      final store = AiSettingsStore(prefs: await prefs());
      await store.save(const AiSettings(apiFormat: AiApiFormat.anthropic));
      expect(chain, isEmpty);
      expect((await store.load()).hasApiKey, isFalse);
    });

    test('save 之后 prefs 里也搜不到任何 Key 的样子', () async {
      final p = await prefs();
      final store = AiSettingsStore(prefs: p);
      await store.save(
          const AiSettings(apiFormat: AiApiFormat.openai, model: 'gpt-4o'));
      await store.setApiKey(fakeKey);
      // 设置那一格是唯一该被写的东西，且它里面没有 Key。
      expect(p.aiSettingsJson, isNotNull);
      expect(p.aiSettingsJson, isNot(contains('sk-')));
    });

    test('清 Key：hasApiKey 立刻变回 false，其余设置留着', () async {
      final store = AiSettingsStore(prefs: await prefs());
      await store.save(const AiSettings(apiFormat: AiApiFormat.anthropic));
      await store.setApiKey(fakeKey);
      expect((await store.load()).hasApiKey, isTrue);

      await store.setApiKey('');
      final loaded = await store.load();
      expect(loaded.hasApiKey, isFalse);
      expect(loaded.apiFormat, AiApiFormat.anthropic,
          reason: '清 Key 不该把设置一起清掉');
    });

    test('钥匙串整个坏了 → 当作没配 Key，但设置照样读得出来', () async {
      final store = AiSettingsStore(prefs: await prefs());
      // 用非默认档（anthropic）：若这里用默认的 openai，编码/解码全坏掉时
      // 下面那条断言也照样过 —— 等于没测。
      await store.save(const AiSettings(apiFormat: AiApiFormat.anthropic));
      FlutterSecureStoragePlatform.instance = _BrokenKeychain();

      final loaded = await store.load();
      expect(loaded.apiFormat, AiApiFormat.anthropic);
      expect(loaded.hasApiKey, isFalse);
      expect(store.isKeychainDegraded, isTrue);
    });

    test('readApiKey 拿得到原值（发请求要用它）', () async {
      final store = AiSettingsStore(prefs: await prefs());
      await store.setApiKey(fakeKey);
      expect(await store.readApiKey(), fakeKey);
    });
  });

  group('AiUsageCounter（每日软上限）', () {
    /// 一个可以拨的钟 —— 跨天这件事不能靠真的等到明天。
    DateTime at(int day, {int hour = 10}) => DateTime(2026, 10, day, hour);

    test('没记过 → 0，且允许调用', () async {
      final c = AiUsageCounter(prefs: await prefs(), clock: () => at(10));
      expect(c.usedToday, 0);
      expect(c.canCall(5), isTrue);
    });

    test('记几次就是几次', () async {
      final c = AiUsageCounter(prefs: await prefs(), clock: () => at(10));
      await c.record();
      await c.record();
      await c.record();
      expect(c.usedToday, 3);
    });

    test('到上限就不再允许（软上限：只是提示的依据）', () async {
      final c = AiUsageCounter(prefs: await prefs(), clock: () => at(10));
      for (var i = 0; i < 5; i++) {
        await c.record();
      }
      expect(c.canCall(5), isFalse);
      expect(c.canCall(6), isTrue);
    });

    test('上限传 0 或负数 = 不限', () async {
      final c = AiUsageCounter(prefs: await prefs(), clock: () => at(10));
      for (var i = 0; i < 300; i++) {
        await c.record();
      }
      expect(c.canCall(0), isTrue);
      expect(c.canCall(-1), isTrue);
    });

    test('跨天自动归零（读的时候就判定，不靠定时器）', () async {
      var now = at(10);
      final p = await prefs();
      final c = AiUsageCounter(prefs: p, clock: () => now);
      await c.record();
      await c.record();
      expect(c.usedToday, 2);

      now = at(11, hour: 1);
      expect(c.usedToday, 0);

      await c.record();
      expect(c.usedToday, 1);
      expect(p.aiUsage, '2026-10-11:1');
    });

    test('存的是「日期:次数」这一行短串', () async {
      final p = await prefs();
      final c = AiUsageCounter(prefs: p, clock: () => at(10));
      await c.record();
      expect(p.aiUsage, '2026-10-10:1');
    });

    test('存坏了（没有冒号 / 次数不是数字）→ 当作 0，不抛', () async {
      final p = await prefs();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cm_ai_usage': '2026-10-10',
      });
      expect(AiUsageCounter(prefs: await prefs(), clock: () => at(10)).usedToday,
          0);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cm_ai_usage': '2026-10-10:abc',
      });
      expect(AiUsageCounter(prefs: await prefs(), clock: () => at(10)).usedToday,
          0);
      expect(p.aiUsage, isNull);
    });
  });
}
