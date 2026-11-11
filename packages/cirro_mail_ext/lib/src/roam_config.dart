import 'package:flutter/foundation.dart';

/// 一条可漫游的配置条目：核心产出、核心消费；扩展只管加密与传输。
///
/// `data` 不做强类型解码 —— **认不出的字段原样留着**，旧版本不能因为多了
/// 一个字段就把整条丢掉。
@immutable
class RoamConfigItem {
  const RoamConfigItem({
    required this.key,
    required this.group,
    required this.data,
    this.secret = false,
  });

  /// `app.<名>` / `sig:<email>` / `phrases:<email>` / `instance:<instanceKey>` /
  /// `secret.<同 key>`。
  final String key;

  /// appearance / compose / reading / ai / instances / secrets / meta。
  final String group;

  /// true = 敏感项（实例登录态、AI Key）：默认不同步，要用户逐个授权。
  final bool secret;

  final Map<String, Object?> data;

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'group': group,
        'secret': secret,
        'data': data,
      };

  /// 坏数据给 null、不抛 —— 一条坏条目不该毁掉整份快照。
  static RoamConfigItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    if (key is! String || key.trim().isEmpty) return null;
    final data = raw['data'];
    if (data is! Map) return null;
    final group = raw['group'];
    return RoamConfigItem(
      key: key,
      group: group is String && group.trim().isNotEmpty ? group : 'meta',
      secret: raw['secret'] == true,
      data: <String, Object?>{
        for (final entry in data.entries)
          if (entry.key is String) entry.key as String: entry.value,
      },
    );
  }

  @override
  String toString() => 'RoamConfigItem($key, $group, secret=$secret)';
}

/// 实例的跨设备稳定身份：`<scheme>://<host[:port]>|<email>`。
///
/// 本机 `profiles.id` 是 UUID，换设备就换；能对上「同一台实例」的只有地址 +
/// 登录邮箱。规则：全小写；丢掉 `/api` 与尾斜杠；默认端口不写；没写协议按
/// https 补；**没有登录邮箱 → null**（这种实例不参与漫游）。
String? roamInstanceKey({required String baseUrl, required String email}) {
  final mail = email.trim().toLowerCase();
  if (mail.isEmpty) return null;
  final raw = baseUrl.trim();
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final defaultPort = scheme == 'https' ? 443 : 80;
  final port = uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';
  return '$scheme://${uri.host.toLowerCase()}$port|$mail';
}
