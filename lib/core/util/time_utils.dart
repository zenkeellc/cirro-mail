/// 时间字段解析。
///
/// worker 的 `create_time` 是 SQLite `CURRENT_TIMESTAMP`，
/// 形态为 `YYYY-MM-DD HH:mm:ss` 的 **UTC**，**不带时区标识**。
/// Dart 的 `DateTime.parse` 对无时区后缀的字符串按**本地时间**处理，
/// 直接 parse 会产生时区偏移错误 —— 必须显式补 `Z`。
class TimeUtils {
  const TimeUtils._();

  /// 解析服务端时间字符串为 UTC [DateTime]。
  static DateTime? parseServerTime(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    if (text.isEmpty) return null;

    // 已经带时区信息（Z 或 ±HH:MM）就按原意解析。
    if (text.endsWith('Z') || _hasZoneOffset(text)) {
      return DateTime.tryParse(text)?.toUtc();
    }

    final normalized = text.contains('T') ? text : text.replaceFirst(' ', 'T');
    return DateTime.tryParse('${normalized}Z')?.toUtc();
  }

  /// 服务端时间 → 本地时间。
  static DateTime? toLocal(Object? raw) => parseServerTime(raw)?.toLocal();

  /// 展示成 `MM-dd HH:mm`（同年）或 `yyyy-MM-dd HH:mm`。
  static String formatListTime(DateTime? utc, {DateTime? now}) {
    if (utc == null) return '';
    final local = utc.toLocal();
    final current = (now ?? DateTime.now()).toLocal();
    if (local.year == current.year) {
      return '${_two(local.month)}-${_two(local.day)} '
          '${_two(local.hour)}:${_two(local.minute)}';
    }
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  /// 详情页用的完整时间。
  static String formatDetailTime(DateTime? utc) {
    if (utc == null) return '';
    final local = utc.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  /// 相对时间。列表里被时间戳占的地方更小。
  static String fromNow(DateTime? utc, {DateTime? now}) {
    if (utc == null) return '';
    final current = now ?? DateTime.now().toUtc();
    final diff = current.difference(utc);
    if (diff.isNegative) return formatListTime(utc, now: now);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return formatListTime(utc, now: now);
  }

  /// 本地缓存里的时间戳是否已过期。
  static bool isStale(DateTime? lastSync, Duration ttl) {
    if (lastSync == null) return true;
    return DateTime.now().toUtc().difference(lastSync) > ttl;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static bool _hasZoneOffset(String text) {
    // 形如 +08:00 / +0800 / -05:00，且出现在末尾。
    final tail = text.length >= 6 ? text.substring(text.length - 6) : text;
    return RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(tail);
  }
}
