import 'dart:convert';

/// 服务端把 `recipient` / `cc` / `bcc` 存成 **JSON 字符串**：
///   recipient = '[{"address":"a@b.com","name":""}]'
///
/// 历史数据里可能是 null、空串、`[]`，甚至是坏 JSON，
/// 所以解析必须容错 —— 一条坏数据不能让整个列表崩掉。
class Recipient {
  const Recipient({this.address = '', this.name = ''});

  final String address;
  final String name;

  factory Recipient.fromJson(Object? json) {
    if (json is Map) {
      return Recipient(
        address: json['address']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
      );
    }
    if (json is String) return Recipient(address: json);
    return const Recipient();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'address': address,
        'name': name,
      };

  static List<Recipient> listFromJson(Object? json) {
    if (json == null) return const <Recipient>[];
    Object? decoded = json;
    if (json is String) {
      final text = json.trim();
      if (text.isEmpty || text == '[]') return const <Recipient>[];
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        // 退化成单个地址，比整条丢掉好。
        return <Recipient>[Recipient(address: text)];
      }
    }
    if (decoded is List) {
      return decoded
          .map(Recipient.fromJson)
          .where((r) => r.address.isNotEmpty)
          .toList(growable: false);
    }
    if (decoded is Map) {
      final single = Recipient.fromJson(decoded);
      return single.address.isEmpty ? const <Recipient>[] : <Recipient>[single];
    }
    return const <Recipient>[];
  }

  /// 显示用：`名称 <地址>`，没有名称就只显示地址。
  String get display => name.isEmpty ? address : '$name <$address>';

  static String joinDisplay(List<Recipient> list) =>
      list.map((r) => r.address).where((a) => a.isNotEmpty).join(', ');

  @override
  bool operator ==(Object other) =>
      other is Recipient && other.address == address && other.name == name;

  @override
  int get hashCode => Object.hash(address, name);

  @override
  String toString() => display;
}
