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
/// 登录邮箱。规则：全小写；丢掉 path 与尾斜杠（**整条 path**，不只是 `/api`
/// 那段 —— 同一 host 上不同 path 前缀视为同一实例：`https://host/mail` 与
/// `https://host/app` 会塌成同一个 key，因为同一个服务端换个挂载路径装的还是
/// 那套账号）；默认端口不写；没写协议按 https 补；**没有登录邮箱 → null**
/// （这种实例不参与漫游）。
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

/// 核心实现、注册进 `AppExtensionRegistry` 的配置快照读写口。
///
/// 核心知道「哪些设置算配置、怎么导出、怎么写回」；扩展知道「加密、传输、
/// 合并、密钥」。接口里没有任何网络 / 密钥 / 云端概念。
///
/// 四条硬约定：
///
/// ① 写回只写认得的 key，别的安静忽略（不抛、不丢别人的数据）；
/// ② 敏感项不走 [applyItems]，恢复走 [writeSecret]；
/// ③ 删除只走 [deleteItems]，且只覆盖 `sig:` / `phrases:` 两类 —— 别的设备删
/// 条目不该让本机实例 / 登录态消失；
/// ④ [changes] 会因 [applyItems] / [deleteItems] 自己写盘而触发，写回期间
/// 消费方要自己抑制回传。
abstract class RoamConfigHost {
  /// 导出本机可漫游条目。`includeSecrets=false` 时不返回任何 secret 项；
  /// true 时把实例 token / AI Key 一并读出（传哪些由消费方按授权集合过滤）。
  Future<List<RoamConfigItem>> exportItems({bool includeSecrets = false});

  /// 应用合并结果：只写给出的 key；未知 key 忽略（往前兼容）。
  Future<void> applyItems(List<RoamConfigItem> items);

  /// 删除本机条目。只对两类 key 生效：`sig:<email>`（删该邮箱签名）与
  /// `phrases:<email>`（清空该邮箱常用语）；其它 key（app.* / instance:* /
  /// secret.*）一律忽略 —— 实例与登录态不因别的设备删除而消失。
  Future<void> deleteItems(List<String> keys);

  /// 本机配置变更流（prefs 写入 / 实例增删改 / token 写入）。广播流，可多次订阅。
  Stream<void> get changes;

  /// 敏感项读：`secret.instance:<instanceKey>` / `secret.ai_key`。
  /// 认不出的 key、本机没有的实例 → null。
  Future<String?> readSecret(String key);

  /// 敏感项写。**空串 = 删掉**；本机没有这台实例、key 认不出 → 安静 no-op。
  Future<void> writeSecret(String key, String value);
}
