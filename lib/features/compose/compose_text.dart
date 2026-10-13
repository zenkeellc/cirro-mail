import 'dart:convert';

/// 从 HTML 粗略还原纯文本（发送时的 `text` 字段、列表摘要都要）。
///
/// 放在这里而不是 `core/util` 之外：它与 `ComposeHtml` 是一对
/// （一个文本 → HTML，一个 HTML → 文本），拆开放会让两边各自漂移。
/// 服务端的 `text` 只用于摘要与检索，不需要精确，但**不能是标签汤** ——
/// 否则列表里显示的是 `<p>你好</p>`。
abstract final class PlainText {
  const PlainText._();

  static String fromHtml(String html) {
    if (html.isEmpty) return '';
    var text = html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(
          RegExp(r'</(p|div|tr|li|h[1-6]|blockquote)\s*>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]*>'), '');
    text = _entities(text);
    // 压掉块级标签转换行带来的空行堆积，但保留段落之间的单个空行。
    return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// 只处理我们自己会产出的那几个实体（见 `ComposeHtml.escape`）——
  /// 引用块里的发件人名字与地址是**不可信输入**，它们已经被转义过一次，
  /// 这里要还原回来，否则摘要里会出现 `&lt;` 这种东西。
  static String _entities(String text) => text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      // `&amp;` 必须**最后**解：反过来的话，字面的 `&amp;lt;` 会被
      // 解成 `&lt;` 再解成 `<`，把用户输入的文本改掉了。
      .replaceAll('&amp;', '&');
}

/// 收件人列表与草稿之间的序列化。
///
/// 草稿里存的是**裸地址数组**（`["a@b.com"]`），不是服务端那种
/// `[{"address":…,"name":…}]`。草稿是纯本地的，没必要模仿服务端形状 ——
/// 反过来说，服务端换了收件人编码方式时，本地草稿不该跟着一起坏掉。
String encodeRecipientAddresses(List<String> addresses) =>
    addresses.isEmpty ? '' : jsonEncode(addresses);

List<String> decodeRecipientAddresses(String? raw) {
  if (raw == null || raw.isEmpty) return const <String>[];
  final decoded = _tryDecode(raw);
  if (decoded is List) {
    return decoded
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
  // 坏数据（或跨版本写入的 `[{"address":…}]` 形状）当空处理，
  // 不让一条坏草稿把整个写邮件页打不开。
  return const <String>[];
}

Object? _tryDecode(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

/// 用户往收件人框里粘贴了一串逗号/分号/空白分隔的地址。
///
/// 常见于从别处复制一行 `a@x.com, b@y.com`。逐字符敲的话这是十几个动作，
/// 而用户的心智模型就是「粘进去」。
List<String> splitAddresses(String raw) => raw
    .split(RegExp(r'[,;，、\s]+'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList(growable: false);

/// 粗略判断一个字符串像不像邮箱。
///
/// 与服务端一致的**宽松**判定：有 `@`、`@` 两边非空、域名里有点且没空格。
/// 刻意不用正则去「严格校验」—— 邮件地址的合法形式比大多数人想象的多，
/// 严格校验最常见的后果是把合法地址挡在门外，而真正的拒绝权在服务端。
bool looksLikeEmail(String value) {
  final at = value.indexOf('@');
  if (at <= 0 || at == value.length - 1) return false;
  final domain = value.substring(at + 1);
  return !domain.contains(' ') && domain.contains('.');
}
