import 'dart:convert';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';

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

  @override
  Future<void> writeSecret(String key, String value) async {}
}
