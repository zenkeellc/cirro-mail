import 'dart:convert';

/// 各模型的 `fromJson` 都走这里，保证「多一个字段 / 少一个字段」不会让整条数据解析失败。
/// 遇到缺失字段一律给安全默认值 —— 这是「尽力兼容不同版本实例」的第一道防线。
class JsonUtils {
  const JsonUtils._();

  static String string(Map json, String key, [String fallback = '']) =>
      json[key]?.toString() ?? fallback;

  /// 空串也视作「没有」（服务端大量字段默认是 `''`，UI 上等同缺失）。
  static String? stringOrNull(Map json, String key) {
    final value = json[key];
    if (value == null) return null;
    final text = value.toString();
    return text.isEmpty ? null : text;
  }

  static int intValue(Map json, String key, [int fallback = 0]) {
    final value = json[key];
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is bool) return value ? 1 : 0;
    return int.tryParse(value.toString()) ?? fallback;
  }

  static int? intOrNull(Map json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }

  static List<Map<String, dynamic>> mapList(Map json, String key) {
    final value = json[key];
    if (value is! List) return const <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
  }

  static List<String> stringList(Map json, String key) {
    final value = json[key];
    if (value is! List) return const <String>[];
    return value.map((e) => e.toString()).toList(growable: false);
  }

  /// 退信原因 `message` 可能是 JSON 字符串（`{"message":"..."}`）也可能是纯文本
  /// （域名权限被拒这类走的是 `emailValues.message`，不是 JSON）。
  static String? bounceMessage(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    if (!text.startsWith('{')) return text;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['message'] != null) {
        return decoded['message'].toString();
      }
    } catch (_) {
      // 不是合法 JSON 就原样返回。
    }
    return text;
  }
}
