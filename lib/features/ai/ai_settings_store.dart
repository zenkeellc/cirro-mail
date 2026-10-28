import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/storage/prefs_store.dart';
import '../../core/storage/secure_storage.dart';
import 'ai_provider.dart';
import 'ai_settings.dart';

/// `AiSettings` ⇄ JSON。
///
/// 单独拎出来是因为**解码这条路要能容忍垃圾**：这份 JSON 会跟着用户升级
/// 版本走，中间可能有人手改过 prefs、也可能是旧版本写的、或者写了一半被
/// 打断。任何一处不对就退回默认值，**绝不抛异常** —— 设置读不出来不该让
/// 写信页打不开。
///
/// 这个对象里**没有 Key**（见 `AiSettings` 的注释），所以编码结果里也就
/// 不可能有 —— 这是「Key 绝不进 prefs」这条规矩在类型上的落点。
abstract final class AiSettingsCodec {
  const AiSettingsCodec._();

  static Map<String, dynamic> encode(AiSettings s) => <String, dynamic>{
        'apiFormat': s.apiFormat.name,
        'baseUrl': s.baseUrl,
        'model': s.model,
        'inlineContinuation': s.inlineContinuationEnabled,
        'preflight': s.preflightEnabled,
        'subjectSuggest': s.subjectSuggestEnabled,
        'polish': s.polishEnabled,
        'suggest': s.mailSuggestEnabled,
        'dailyCallLimit': s.dailyCallLimit,
      };

  static AiSettings decode(Object? raw) {
    if (raw == null) return const AiSettings();
    Object? value = raw;
    if (raw is String) {
      if (raw.trim().isEmpty) return const AiSettings();
      try {
        value = jsonDecode(raw);
      } catch (_) {
        // 存进去的不是 JSON（手改过 / 写坏了）—— 当没配过。
        return const AiSettings();
      }
    }
    if (value is! Map) return const AiSettings();
    final map = value;

    // **老配置（含 `vendor` 键的那种）在这里被有意丢弃** —— `model` 与
    // `baseUrl` 连读都不读：
    //
    // - 老的模型名是绑在老厂商上的（`claude-fable-5-1` 只对 Anthropic 有意义），
    //   换到 openai 格式后拿它去打 OpenAI 只会 404。与其留一个「看起来配好了、
    //   一点就报错」的假配置，不如让它空着、由设置页引导重填。
    // - 老的 baseUrl 是「自定义厂商的完整接口地址（含 /chat/completions）」，
    //   语义与现在不同（现在要的是 base）；而缺地址会让整页看起来无从下手，
    //   所以退回**能用的默认地址**而不是空串。
    //
    // 但**偏好**键照旧读：`inlineContinuation` / `preflight` /
    // `subjectSuggest` / `polish` / `dailyCallLimit` 与端点无关，因为换了端点
    // 就重置等于把用户的设置无故清掉。
    //
    // 判据是**有没有 `apiFormat` 这个键**：它是新格式才有的。带 `vendor` 的
    // 旧 JSON 里那三个键语义都与现在不同（见上），不能按新语义读。
    final defaults = const AiSettings();
    // 新格式才有的键。带 `vendor` 的旧 JSON 里 model / baseUrl 语义都已不同
    // （见上），不能按新语义读 —— 整条降级规则都压在这个判据上，所以提出来
    // 只写一次。
    final isNewFormat = map.containsKey('apiFormat');
    return AiSettings(
      apiFormat: _format(map['apiFormat'], defaults.apiFormat),
      // 老配置的模型名不读（见上面那段注释）。
      model: isNewFormat ? (_string(map['model']) ?? defaults.model) : defaults.model,
      baseUrl:
          isNewFormat ? (_string(map['baseUrl']) ?? defaults.baseUrl) : defaults.baseUrl,
      inlineContinuationEnabled:
          _bool(map['inlineContinuation']) ?? defaults.inlineContinuationEnabled,
      preflightEnabled: _bool(map['preflight']) ?? defaults.preflightEnabled,
      subjectSuggestEnabled:
          _bool(map['subjectSuggest']) ?? defaults.subjectSuggestEnabled,
      // `polish` 是后加的键：老配置里没有它，`_bool(null)` 给 null，退回默认
      // （开）—— 不能因为「这个键不存在」就把润色入口关掉。
      polishEnabled: _bool(map['polish']) ?? defaults.polishEnabled,
      // `suggest` 与 `polish` 同一条规矩：后加的键在**老配置**上不能把功能
      // 关掉。少了 `?? defaults.mailSuggestEnabled` 这一半，所有升级上来的
      // 用户都会看不到那个入口，而且没有任何报错。
      mailSuggestEnabled:
          _bool(map['suggest']) ?? defaults.mailSuggestEnabled,
      dailyCallLimit: _int(map['dailyCallLimit']) ?? defaults.dailyCallLimit,
      // 有没有 Key 只有钥匙串知道，prefs 里就算写了也不算数。
    );
  }

  static AiApiFormat _format(Object? raw, AiApiFormat fallback) {
    if (raw is! String) return fallback;
    for (final f in AiApiFormat.values) {
      if (f.name == raw) return f;
    }
    return fallback;
  }

  static String? _string(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static bool? _bool(Object? raw) => raw is bool ? raw : null;

  static int? _int(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return null;
  }
}

/// API Key 的存取 —— **只走系统密钥库**，与 token 共用
/// [resolveSecureStorage] 选出来的那套（macOS 上优先 data protection 钥匙串，
/// 缺 entitlement 的构建自动退回老钥匙串，见 `core/storage/secure_storage.dart`）。
///
/// 三条不能破的规矩：
/// 1. **不进 prefs**：Key 落 prefs 就是明文落盘（各平台 prefs 都不加密），
///    这条在测试里被盯着 —— 写完之后整个 prefs 里搜不到那串 Key；
/// 2. **不进日志、不进异常**：所有失败分支只打平台异常自己的 `message`，
///    绝不把值或整个对象打出去（`toString` 也只给长度）；
/// 3. **失败降级**：Linux 没装 libsecret、钥匙串被锁、插件没注册都会抛，
///    这时当作「没配 Key」——表现为 AI 入口变灰，而不是写信页崩掉。
class AiApiKeyStore {
  AiApiKeyStore({FlutterSecureStorage? storage}) : _injectedStorage = storage;

  final FlutterSecureStorage? _injectedStorage;

  /// 与 `TokenStore` 共用一次探测结果；同样的懒解析 —— 构造不碰平台通道。
  late final Future<FlutterSecureStorage> _storageFuture = _openStorage();

  Future<FlutterSecureStorage> _openStorage() async {
    final injected = _injectedStorage;
    return injected ?? await resolveSecureStorage();
  }

  /// 密钥库里的 key 名。与 `token_` / `push_` 并列，用 `ai_` 前缀。
  static const String storageKey = 'ai_api_key';

  bool _degraded = false;

  /// 读写时抛过平台异常。UI 据此提示「本次运行可用，重启要重填」。
  bool get isDegraded => _degraded;

  /// 读 Key。没有就是不配过 —— 空串与只有空白的都当没配。
  Future<String?> read() async {
    try {
      final storage = await _storageFuture;
      final value = await storage.read(key: storageKey);
      final trimmed = value?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } catch (e) {
      // 捕得比 PlatformException 宽：插件没注册时抛的是
      // `MissingPluginException`，它**不是** PlatformException。
      _degraded = true;
      // 只打异常本身 —— 异常消息里不含存进去的值。
      debugPrint('AiApiKeyStore.read 失败（当作未配置）：$e');
      return null;
    }
  }

  /// 写 Key。**空串等于删除**（用户把输入框清空再保存，语义就是清掉）。
  Future<void> write(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await delete();
      return;
    }
    try {
      final storage = await _storageFuture;
      await storage.write(key: storageKey, value: trimmed);
      _degraded = false;
    } catch (e) {
      _degraded = true;
      debugPrint('AiApiKeyStore.write 失败（本次运行仍可用）：$e');
    }
  }

  Future<void> delete() async {
    try {
      final storage = await _storageFuture;
      await storage.delete(key: storageKey);
      _degraded = false;
    } catch (e) {
      _degraded = true;
      debugPrint('AiApiKeyStore.delete 失败：$e');
    }
  }

  /// **只给长度**，一个字符也不给。
  @override
  String toString() => 'AiApiKeyStore(degraded=$_degraded)';
}

/// `AiSettings` 的落盘与读回。
///
/// **分两处存**（这是本类的全部意义）：
/// - 格式 / 模型 / Base URL / 四个开关 / 每日上限 → `PrefsStore`（明文，
///   因为要能同步读、也不怕看）；
/// - API Key → [AiApiKeyStore]，系统密钥库。
///
/// 于是「有没有配 Key」这件事在启动时**要问一次钥匙串**，而其余设置同步可读。
/// 两者合成一个 [AiSettings] 返回给上层。
///
/// 写的时候**只写非敏感部分** —— `save()` 里没有 Key 这个概念，传进来的
/// `AiSettings` 里也没有。
class AiSettingsStore {
  // 计划原文的字段名是私有的 `_prefs`，而构造参数名必须是公开的 `prefs`
  // （测试按名字传参）—— 两者不能合并成 `this._prefs` 这个 initializing
  // formal，所以这里只有这一处与 lint 偏好不同。
  AiSettingsStore({required PrefsStore prefs, AiApiKeyStore? keys})
      // ignore: prefer_initializing_formals
      : _prefs = prefs,
        _keys = keys ?? AiApiKeyStore();

  final PrefsStore _prefs;
  final AiApiKeyStore _keys;

  /// 密钥库不可用（读 Key 失败）。UI 据此提示「重启要重填」。
  bool get isKeychainDegraded => _keys.isDegraded;

  /// 读设置：prefs 那半 + 钥匙串那半。
  Future<AiSettings> load() async {
    final stored = AiSettingsCodec.decode(_prefs.aiSettingsJson);
    final key = await _keys.read();
    return stored.copyWith(hasApiKey: key != null);
  }

  /// 写设置。**只落非敏感部分**。
  Future<void> save(AiSettings settings) async {
    await _prefs.setAiSettingsJson(
      jsonEncode(AiSettingsCodec.encode(settings)),
    );
  }

  /// 当前 Key（发请求时用）。**调用方用完即弃，不许写进任何日志或状态**。
  Future<String?> readApiKey() => _keys.read();

  /// 设 Key。空串 = 清掉（见 [AiApiKeyStore.write]）。
  Future<void> setApiKey(String key) => _keys.write(key);
}

/// 每日调用计数（软上限，超了只提示，不硬拦 —— spec §4.4）。
///
/// 存的是 `日期:次数` 这样一行短串。跨天自动归零：**读的时候就判定**，
/// 不靠定时器 —— 一台笔记本合着盖子过了午夜，醒来时定时器一个都没跑过。
class AiUsageCounter {
  // 同 `AiSettingsStore`：字段私有、参数公开，不能合并成 initializing formal。
  AiUsageCounter({required PrefsStore prefs, DateTime Function()? clock})
      // ignore: prefer_initializing_formals
      : _prefs = prefs,
        _now = clock ?? DateTime.now;

  final PrefsStore _prefs;
  final DateTime Function() _now;

  static String _dayOf(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// 今天已经调了几次。
  int get usedToday {
    final raw = _prefs.aiUsage;
    if (raw == null || raw.isEmpty) return 0;
    final at = raw.indexOf(':');
    if (at <= 0) return 0;
    if (raw.substring(0, at) != _dayOf(_now())) return 0;
    return int.tryParse(raw.substring(at + 1)) ?? 0;
  }

  /// 还允许调用吗。[limit] 传 0 或负数表示不限。
  bool canCall(int limit) => limit <= 0 || usedToday < limit;

  /// 记一次调用。跨天了就从 1 开始。
  Future<void> record() async {
    final next = usedToday + 1;
    await _prefs.setAiUsage('${_dayOf(_now())}:$next');
  }
}
