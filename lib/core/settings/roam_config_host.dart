import 'dart:convert';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';

import '../../data/models/profile.dart';
import '../../features/ai/ai_settings_store.dart';
import '../db/database.dart';
import '../storage/prefs_store.dart';
import '../storage/token_store.dart';

/// 核心侧的配置快照读写口：把本机设置读成条目、把条目写回同一批存储、写盘后
/// 让 [changes] 响一声。没有网络 / 加密 / 云端概念（见 `docs/config-snapshot.md`）。
class RoamConfigHostImpl implements RoamConfigHost {
  RoamConfigHostImpl({
    required this.prefs,
    required this.tokens,
    required this.db,
    AiApiKeyStore? aiKeys,
  }) : aiKeys = aiKeys ?? AiApiKeyStore();

  final PrefsStore prefs;
  final TokenStore tokens;
  final AppDatabase db;
  final AiApiKeyStore aiKeys;

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
    for (final profile in profiles) {
      final instanceKey =
          roamInstanceKey(baseUrl: profile.baseUrl, email: profile.email);
      // 没有登录邮箱 / 地址坏掉：缺一个就没有跨设备身份，硬编 key 只会在别的
      // 设备上凭空造出一条假条目。
      if (instanceKey == null) continue;
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
      if (!includeSecrets) continue;
      final token = await tokens.read(profile.id);
      if (token == null || token.isEmpty) continue;
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
  Future<void> applyItems(List<RoamConfigItem> items) async {}

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
      await tokens.write(profile.id, value);
    }
    prefs.notifyChanged();
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
