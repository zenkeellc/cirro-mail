import 'dart:convert';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/profile.dart';
import '../../features/ai/ai_settings_store.dart';
import '../../features/compose/writing_snippets.dart';
import '../db/database.dart';
import '../storage/prefs_store.dart';
import '../storage/token_store.dart';
import '../theme/instance_colors.dart';
import '../util/url_utils.dart';

/// 核心侧的配置快照读写口：把本机设置读成条目、把条目写回同一批存储、写盘后
/// 让 [changes] 响一声。没有网络 / 加密 / 云端概念（见 `docs/config-snapshot.md`）。
class RoamConfigHostImpl implements RoamConfigHost {
  RoamConfigHostImpl({
    required this.prefs,
    required this.tokens,
    required this.db,
    AiApiKeyStore? aiKeys,
    Uuid? uuid,
  })  : aiKeys = aiKeys ?? AiApiKeyStore(),
        _uuid = uuid ?? const Uuid();

  final PrefsStore prefs;
  final TokenStore tokens;
  final AppDatabase db;
  final AiApiKeyStore aiKeys;

  /// 只在 `_applyInstance` 里给新实例发本机 id 用；测试可注入固定种子的假
  /// `Uuid` 让断言好写。
  final Uuid _uuid;

  /// 就是 `PrefsStore` 那一条（实例 / token 的写入口也已汇进同一个 signal）。
  @override
  Stream<void> get changes => prefs.changes;

  @override
  Future<List<RoamConfigItem>> exportItems({bool includeSecrets = false}) async {
    final items = <RoamConfigItem>[
      const RoamConfigItem(
        key: 'app.schema',
        group: 'meta',
        secret: false,
        data: <String, Object?>{'v': 1},
      ),
      _appearanceItem(),
      _composeItem(),
      ..._signatureItems(),
      ..._phraseItems(),
      _readingItem(),
      _aiItem(),
    ];
    final profiles = await db.profileDao.allProfiles();
    // 同一台实例在本机可能被登记成多条 profile（同 host 同邮箱、只是挂载 path
    // 不同 → `roamInstanceKey` 相同）。**按 key 去重、先到先得**：消费方按
    // key 建 map，重复条目只会被静默丢掉一条 —— 等于让迭代顺序决定别人的备注名
    // / 色标取哪条，还白传一份 token。`instance:` 与 `secret.instance:` 共用
    // 这个去重后的 key，所以一台实例至多一条配置 + 一条 token。
    final firstByInstance = <String, Profile>{};
    for (final profile in profiles) {
      final instanceKey =
          roamInstanceKey(baseUrl: profile.baseUrl, email: profile.email);
      // 没有登录邮箱 / 地址坏掉：缺一个就没有跨设备身份，硬编 key 只会在别的
      // 设备上凭空造出一条假条目。
      if (instanceKey == null) continue;
      firstByInstance.putIfAbsent(instanceKey, () => profile);
    }
    // token 也按去重后的 key 收：先去的那条可能恰好是「需要重新登录」的，
    // 只要同实例还有一条留着 token 就不该让别的设备丢登录态。
    final tokensByInstance = <String, String>{};
    if (includeSecrets) {
      for (final profile in profiles) {
        final instanceKey =
            roamInstanceKey(baseUrl: profile.baseUrl, email: profile.email);
        if (instanceKey == null ||
            !firstByInstance.containsKey(instanceKey) ||
            tokensByInstance.containsKey(instanceKey)) {
          continue;
        }
        final token = await tokens.read(profile.id);
        if (token != null && token.isNotEmpty) {
          tokensByInstance[instanceKey] = token;
        }
      }
    }
    for (final entry in firstByInstance.entries) {
      final instanceKey = entry.key;
      final profile = entry.value;
      items.add(RoamConfigItem(
        key: 'instance:$instanceKey',
        group: 'instances',
        secret: false,
        data: <String, Object?>{
          'baseUrl': profile.baseUrl,
          'name': profile.name,
          'email': profile.email,
          'colorIndex': profile.colorIndex,
          'sort': profile.sort,
        },
      ));
      final token = tokensByInstance[instanceKey];
      if (token == null) continue;
      items.add(RoamConfigItem(
        key: 'secret.instance:$instanceKey',
        group: 'secrets',
        secret: true,
        data: <String, Object?>{'value': token},
      ));
    }
    if (includeSecrets) {
      final apiKey = await aiKeys.read();
      if (apiKey != null && apiKey.isNotEmpty) {
        items.add(RoamConfigItem(
          key: 'secret.ai_key',
          group: 'secrets',
          secret: true,
          data: <String, Object?>{'value': apiKey},
        ));
      }
    }
    return items;
  }

  RoamConfigItem _appearanceItem() => RoamConfigItem(
        key: 'app.appearance',
        group: 'appearance',
        secret: false,
        data: <String, Object?>{
          'themeMode': prefs.themeMode,
          'themePackId': prefs.themePackId,
          'locale': prefs.localeCode,
        },
      );

  RoamConfigItem _composeItem() => RoamConfigItem(
        key: 'app.compose',
        group: 'compose',
        secret: false,
        data: <String, Object?>{'sendDelaySeconds': prefs.sendDelay.inSeconds},
      );

  Iterable<RoamConfigItem> _signatureItems() sync* {
    for (final entry in prefs.signatures.entries) {
      yield RoamConfigItem(
        key: 'sig:${entry.key}',
        group: 'compose',
        secret: false,
        data: <String, Object?>{'text': entry.value},
      );
    }
  }

  Iterable<RoamConfigItem> _phraseItems() sync* {
    for (final entry in prefs.phrases.entries) {
      yield RoamConfigItem(
        key: 'phrases:${entry.key}',
        group: 'compose',
        secret: false,
        data: <String, Object?>{
          'items': <Object?>[for (final snippet in entry.value) snippet.toJson()],
        },
      );
    }
  }

  RoamConfigItem _readingItem() => RoamConfigItem(
        key: 'app.reading',
        group: 'reading',
        secret: false,
        data: <String, Object?>{
          'pollSeconds': prefs.pollInterval.inSeconds,
          'prefetchFull': prefs.prefetchFull,
          'notifyEnabled': prefs.notifyEnabled,
          'notifyBanner': prefs.notifyBanner,
          'quietTrackingPixels': prefs.quietTrackingPixels,
          'externalAllowedHosts': prefs.externalAllowedHosts,
        },
      );

  /// **原样搬 `cm_ai_settings` 那份 JSON**（不经过 `AiSettingsCodec.encode`）：
  /// 新版本加的字段在旧设备上也能原样回传。
  RoamConfigItem _aiItem() {
    Object? settings;
    final raw = prefs.aiSettingsJson;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          settings = <String, Object?>{
            for (final entry in decoded.entries)
              if (entry.key is String) entry.key as String: entry.value,
          };
        }
      } catch (_) {
        // 坏 JSON：当作没配过（与 `AiSettingsCodec.decode` 同口径）。
      }
    }
    return RoamConfigItem(
      key: 'app.ai',
      group: 'ai',
      secret: false,
      data: <String, Object?>{
        'settings': settings ?? <String, Object?>{},
        'source': prefs.aiSourceCode,
      },
    );
  }

  @override
  Future<void> applyItems(List<RoamConfigItem> items) async {
    for (final item in items) {
      try {
        await _applyOne(item);
      } catch (e) {
        // 单条写不进去不该让整份快照失败（类型不对 / JSON 编不出来就跳过）。
        debugPrint('配置条目 ${item.key} 写回失败（已跳过）：$e');
      }
    }
  }

  Future<void> _applyOne(RoamConfigItem item) async {
    final key = item.key;
    // 敏感项永远不经过这里：恢复实例登录态要用户逐个授权，走 writeSecret。
    if (item.secret || key.startsWith('secret.')) return;
    if (key == 'app.appearance') {
      final mode = item.data['themeMode'];
      if (mode is String &&
          const <String>{'system', 'light', 'dark'}.contains(mode)) {
        await prefs.setThemeMode(mode);
      }
      if (item.data.containsKey('themePackId')) {
        final pack = item.data['themePackId'];
        await prefs.setThemePackId(pack is String && pack.isNotEmpty ? pack : null);
      }
      if (item.data.containsKey('locale')) {
        final locale = item.data['locale'];
        await prefs
            .setLocaleCode(locale is String && locale.isNotEmpty ? locale : null);
      }
      return;
    }
    if (key == 'app.compose') {
      final seconds = _int(item.data['sendDelaySeconds']);
      if (seconds != null) await prefs.setSendDelay(Duration(seconds: seconds));
      return;
    }
    if (key.startsWith('sig:')) {
      final email = key.substring('sig:'.length);
      final text = item.data['text'];
      if (email.isEmpty || text is! String) return;
      await prefs.setSignature(email, text);
      return;
    }
    if (key.startsWith('phrases:')) {
      final email = key.substring('phrases:'.length);
      final raw = item.data['items'];
      if (email.isEmpty || raw is! List) return;
      final snippets = <WritingSnippet>[];
      for (final entry in raw) {
        final snippet = WritingSnippet.fromJson(entry);
        if (snippet != null) snippets.add(snippet);
      }
      // **一条都没解出来、而对方明明带了条目**：不是「用户删光了」，是格式
      // 对不上（对方版本换过结构 / 数据坏掉）。这时写空组等于替用户清掉本机
      // 那一组常用语，而且没有任何提示 —— 与 spec §7.3「单条解不出来跳过、
      // 本地保留」同一条精神。原样留着本地，等对方修好或用户自己重试。
      if (snippets.isEmpty && raw.isNotEmpty) return;
      await prefs.setPhrases(email, snippets);
      return;
    }
    if (key == 'app.reading') {
      final poll = _int(item.data['pollSeconds']);
      if (poll != null) await prefs.setPollInterval(Duration(seconds: poll));
      final prefetch = _bool(item.data['prefetchFull']);
      if (prefetch != null) await prefs.setPrefetchFull(prefetch);
      final notify = _bool(item.data['notifyEnabled']);
      if (notify != null) await prefs.setNotifyEnabled(notify);
      final banner = _bool(item.data['notifyBanner']);
      if (banner != null) await prefs.setNotifyBanner(banner);
      final quiet = _bool(item.data['quietTrackingPixels']);
      if (quiet != null) await prefs.setQuietTrackingPixels(quiet);
      final hosts = item.data['externalAllowedHosts'];
      if (hosts is List) await prefs.setExternalAllowedHosts(hosts.whereType<String>());
      return;
    }
    if (key == 'app.ai') {
      final settings = item.data['settings'];
      if (settings is Map) {
        await prefs.setAiSettingsJson(jsonEncode(<String, Object?>{
          for (final entry in settings.entries)
            if (entry.key is String) entry.key as String: entry.value,
        }));
      }
      if (item.data.containsKey('source')) {
        final source = item.data['source'];
        await prefs
            .setAiSourceCode(source is String && source.isNotEmpty ? source : null);
      }
      return;
    }
    if (key.startsWith('instance:')) {
      await _applyInstance(key.substring('instance:'.length), item.data);
      return;
    }
    // app.schema / 扩展自己的条目（免打扰、外联代理…）/ 未来版本的条目：
    // 核心不解释。不抛、不写 —— 数据由消费方自己保管。
  }

  static int? _int(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return null;
  }

  static bool? _bool(Object? raw) => raw is bool ? raw : null;

  /// 实例写回：按 `instanceKey` 去重，绝不用对方给的 id（跨设备的 `profiles.id`
  /// 是两套 UUID，拿对方的写本机会把 `token_<id>` 弄拧）。已存在 → 只改展示
  /// 字段（备注名 / 色标 / 排序），不碰 `userId` / `userName` / `serverTitle` /
  /// `ossBase` / `needsLogin`：那几样是登录与探测的产物。也不删本机多出来的
  /// 实例 —— 别的设备没导出不等于本机该删。
  Future<void> _applyInstance(String instanceKey, Map<String, Object?> data) async {
    final baseUrl = data['baseUrl'];
    final email = data['email'];
    if (baseUrl is! String || email is! String) return;
    final normalizedBase = UrlUtils.normalizeApiBase(baseUrl);
    // key 与 data 必须自洽：对不上说明这条是脏数据（或对方版本算 key 的规则
    // 变了），照 data 硬建会凭空多出一台谁也没登记过的实例。
    final wanted = roamInstanceKey(baseUrl: normalizedBase, email: email);
    if (wanted == null || wanted != instanceKey) return;
    final existing = await db.profileDao.allProfiles();
    Profile? match;
    for (final profile in existing) {
      if (roamInstanceKey(baseUrl: profile.baseUrl, email: profile.email) ==
          wanted) {
        match = profile;
        break;
      }
    }
    final name = data['name'];
    final colorIndex = _int(data['colorIndex']);
    final sort = _int(data['sort']);
    if (match != null) {
      await db.profileDao.updateProfileFields(
        match.id,
        name: name is String ? name : null,
        colorIndex: colorIndex,
        sort: sort,
      );
      prefs.notifyChanged();
      return;
    }
    await db.profileDao.upsertProfile(Profile(
      id: _uuid.v4(),
      baseUrl: normalizedBase,
      name: name is String ? name : '',
      email: email,
      sort: sort ?? existing.length,
      colorIndex: colorIndex ??
          InstanceColors.nextIndex(existing.map((profile) => profile.colorIndex)),
      needsLogin: true, // 恢复出来的实例没有 token：先落「需要登录」
      ossBase: UrlUtils.ossBase(userApi: normalizedBase),
      createdAt: DateTime.now().toUtc(),
    ));
    prefs.notifyChanged();
  }

  @override
  Future<void> deleteItems(List<String> keys) async {}

  @override
  Future<String?> readSecret(String key) async => null;

  static const String _instanceSecretPrefix = 'secret.instance:';

  @override
  Future<void> writeSecret(String key, String value) async {
    if (key == 'secret.ai_key') {
      await aiKeys.write(value); // 空串 = 删（`AiApiKeyStore.write` 的语义）
      prefs.notifyChanged();
      return;
    }
    final instanceKey = _instanceKeyFromSecret(key);
    if (instanceKey == null) return;
    final profile = await _profileFor(instanceKey);
    // 本机没有这台实例：不写、不新建 —— 否则一次失误就能在这台机器上凭空
    // 多出一条别人的登录态。
    if (profile == null) return;
    if (value.isEmpty) {
      await tokens.delete(profile.id);
    } else {
      // `TokenStore.write` 自己会 notify（同一 signal），这里不再补一枪：
      // 一次写盘只该让消费方醒一次，否则漫游会重复上传同一份快照。
      await tokens.write(profile.id, value);
    }
  }

  static String? _instanceKeyFromSecret(String key) {
    if (!key.startsWith(_instanceSecretPrefix)) return null;
    final instanceKey = key.substring(_instanceSecretPrefix.length);
    return instanceKey.isEmpty ? null : instanceKey;
  }

  Future<Profile?> _profileFor(String instanceKey) async {
    for (final profile in await db.profileDao.allProfiles()) {
      if (roamInstanceKey(baseUrl: profile.baseUrl, email: profile.email) ==
          instanceKey) {
        return profile;
      }
    }
    return null;
  }
}
