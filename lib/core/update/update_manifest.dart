import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../version/app_version.dart';

/// 版本清单（官网静态文件 `app-version.json`）的客户端模型与解析器。
///
/// 契约（由官网与客户端共同维护，改这里之前先对齐 `docs/app-update.md`）：
///
/// ```json
/// {
///   "schema": 1,
///   "updatedAt": "2026-11-02T00:00:00Z",
///   "channels": {
///     "public": {
///       "version": "0.1.0",
///       "buildNumber": 131,
///       "publishedAt": "2026-11-02T00:00:00Z",
///       "notes": "修了几个问题",
///       "releaseUrl": "https://cirro.zenkee.com/download",
///       "downloads": {
///         "macos": "https://.../CirroMail.dmg",
///         "linux": "https://.../CirroMail.AppImage",
///         "windows": null, "android": null, "ios": null
///       }
///     }
///   }
/// }
/// ```
///
/// ## 为什么解析器是「全有或全无」
///
/// 清单是一份**外部输入**（可能被 CDN 缓存成旧版、被部署者手改、被中间人
/// 换成错误页），所以这里不做「能读多少算多少」：`schema` 不认识、`channels`
/// 缺失、某个渠道的 `version` 不是非空字符串，一律抛
/// [UpdateManifestException]。半懂不懂的清单比没有清单更危险 —— 比如把
/// `version` 读成 null 之后「没有新版本」地静默通过，用户就永远收不到更新。
///
/// 反过来，**展示用**的字段（备注、下载地址、时间）坏掉不抛：那些字段丢了
/// 只是界面少一行，不该让整次检查失败。
class UpdateManifest {
  const UpdateManifest({
    required this.schema,
    required this.channels,
    this.updatedAt,
  });

  /// 清单格式版本。客户端只认 [supportedSchema]，其余一律当坏数据。
  final int schema;

  /// 渠道名 → 该渠道的最新版本。公开版是 `public`，商业版是 `pro`。
  final Map<String, UpdateRelease> channels;

  /// 清单生成时间（UTC）。纯诊断用，不参与比较。
  final DateTime? updatedAt;

  /// 这个客户端唯一认识的清单格式。
  static const int supportedSchema = 1;

  /// 渠道 [name] 的最新版本；清单里没有这个渠道时返回 null。
  UpdateRelease? releaseFor(String name) => channels[name];

  /// 解析清单字符串；任何结构性问题都抛 [UpdateManifestException]。
  ///
  /// 注意调用方**不能只看 HTTP 状态码**：官网是静态站，未知路径会回
  /// `200 + HTML`，那种响应走到这里就是 `jsonDecode` 失败 —— 正是
  /// [UpdateService] 要区分的「坏响应」。
  static UpdateManifest parse(String body) {
    final text = body.trim();
    if (text.isEmpty) {
      throw const UpdateManifestException('清单是空的');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      // 静态站的 200 + HTML 落在这里，不是「没有更新」。
      throw UpdateManifestException('清单不是合法 JSON：${error.message}');
    }
    if (decoded is! Map) {
      throw const UpdateManifestException('清单顶层不是对象');
    }

    final schema = decoded['schema'];
    if (schema is! int || schema != supportedSchema) {
      throw UpdateManifestException(
        '不认识的清单 schema：$schema（本版本只认 $supportedSchema）',
      );
    }

    final rawChannels = decoded['channels'];
    if (rawChannels is! Map) {
      throw const UpdateManifestException('清单缺少 channels 对象');
    }

    final channels = <String, UpdateRelease>{};
    rawChannels.forEach((key, value) {
      // 渠道名必须是字符串；空的键直接忽略（它不可能被任何构建选中）。
      if (key is! String || key.trim().isEmpty) return;
      channels[key] = _releaseFrom(value, channel: key);
    });
    if (channels.isEmpty) {
      throw const UpdateManifestException('清单里一个渠道都没有');
    }

    return UpdateManifest(
      schema: schema,
      channels: Map<String, UpdateRelease>.unmodifiable(channels),
      updatedAt: _dateOrNull(decoded['updatedAt']),
    );
  }

  /// 解析失败返回 null 的版本，给「不想处理异常」的调用方。
  ///
  /// 生产链路（[UpdateService]）用 [parse] —— 它要把「坏响应」翻译成一条
  /// 可展示的失败原因，而不是一个无言的 null。
  static UpdateManifest? tryParse(String body) {
    try {
      return parse(body);
    } on UpdateManifestException {
      return null;
    }
  }

  static UpdateRelease _releaseFrom(Object? raw, {required String channel}) {
    if (raw is! Map) {
      throw UpdateManifestException('渠道 $channel 的版本信息不是对象');
    }

    final version = raw['version'];
    if (version is! String || version.trim().isEmpty) {
      throw UpdateManifestException('渠道 $channel 缺少 version');
    }

    return UpdateRelease(
      version: version.trim(),
      // build 号缺失 / 写成字符串都按 0 收下：那个字段只影响「同版本名时谁更新」，
      // 缺了它界面还能正常显示与下载，不值得让整份清单作废。
      buildNumber: _intOr(raw['buildNumber'], 0),
      publishedAt: _dateOrNull(raw['publishedAt']),
      notes: _stringOr(raw['notes']),
      releaseUrl: _stringOr(raw['releaseUrl']),
      downloads: _downloadsOr(raw['downloads']),
    );
  }

  static int _intOr(Object? value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  static String _stringOr(Object? value) {
    if (value is! String) return '';
    return value.trim();
  }

  /// 时间字段坏了算「不知道」，不抛出：它只用于展示。
  static DateTime? _dateOrNull(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text)?.toUtc();
  }

  /// 下载地址表。非字符串 / 空串的条目忽略，未知平台键原样留着
  /// （选择时只读自己认识的那几个，留着不占什么）。
  static Map<String, String> _downloadsOr(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (key is! String) return;
      if (value is! String) return;
      final url = value.trim();
      if (url.isEmpty) return;
      out[key] = url;
    });
    return Map<String, String>.unmodifiable(out);
  }
}

/// 一个渠道的最新版本。
@immutable
class UpdateRelease {
  const UpdateRelease({
    required this.version,
    this.buildNumber = 0,
    this.publishedAt,
    this.notes = '',
    this.releaseUrl = '',
    this.downloads = const <String, String>{},
  });

  final String version;
  final int buildNumber;

  /// 发布时间（UTC），只用于展示。
  final DateTime? publishedAt;

  /// 更新说明。**原样展示**（清单是官网负责人写的，不走 l10n）。
  final String notes;

  /// 下载页 / 发布页。平台直链缺失时回退到它。
  final String releaseUrl;

  /// 平台键（`macos` / `linux` / `windows` / `android` / `ios`）→ 安装包直链。
  final Map<String, String> downloads;

  /// 与 [AppVersion.display] 同一个形状：`0.1.0+131`。
  String get display => buildNumber > 0 ? '$version+$buildNumber' : version;

  /// 这个发布版对应的 [AppVersion]，比较走它自己的 semver + build 号规则。
  AppVersion get asAppVersion => AppVersion(
        name: version,
        buildNumber: buildNumber,
      );

  /// 这个发布版是否比 [current] 新。
  ///
  /// **未知的当前版本一律返回 false**（不判断）：那说明这是个开发构建，
  /// 没有可信的基准，宁可静默也不要把「什么都没装」提示成「有新版本」。
  bool isNewerThan(AppVersion current) =>
      current.isKnown && asAppVersion.isNewerThan(current);

  /// 这台机器该用哪个下载地址：先找平台直链，缺失回退 [releaseUrl]，
  /// 都没有则返回 null（界面据此不显示「下载」按钮）。
  String? downloadUrlFor(TargetPlatform platform) =>
      selectDownloadUrl(this, platform);

  @override
  bool operator ==(Object other) =>
      other is UpdateRelease &&
      other.version == version &&
      other.buildNumber == buildNumber &&
      other.publishedAt == publishedAt &&
      other.notes == notes &&
      other.releaseUrl == releaseUrl &&
      mapEquals(other.downloads, downloads);

  @override
  int get hashCode => Object.hash(
        version,
        buildNumber,
        publishedAt,
        notes,
        releaseUrl,
        Object.hashAllUnordered(downloads.entries),
      );

  @override
  String toString() => 'UpdateRelease($display)';
}

/// 平台 → 清单里的下载键。Fuchsia 没有对应产物，返回 null。
///
/// 用 `TargetPlatform` 而不是 `Platform.isX`：这是纯函数，测试里可以直接喂
/// 平台（也能 `debugDefaultTargetPlatformOverride`），不碰 `dart:io`。
String? downloadPlatformKey(TargetPlatform platform) => switch (platform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => null,
    };

/// 选下载地址的纯函数（放顶层是为了单测能直接钉住「缺键回退」这条规则）。
String? selectDownloadUrl(UpdateRelease release, TargetPlatform platform) {
  final key = downloadPlatformKey(platform);
  final direct = key == null ? null : release.downloads[key];
  if (direct != null && direct.isNotEmpty) return direct;
  if (release.releaseUrl.isNotEmpty) return release.releaseUrl;
  return null;
}

/// 清单解析失败。
///
/// 单独一个类型（而不是 `FormatException`）是为了让 [UpdateService] 能把
/// 「清单坏了」与「网络坏了」分开：前者重试也不会好（除非官网修好），后者
/// 值得用户再点一次「重试」。
class UpdateManifestException implements Exception {
  const UpdateManifestException(this.message);

  final String message;

  @override
  String toString() => 'UpdateManifestException: $message';
}
