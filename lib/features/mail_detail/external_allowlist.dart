/// 外联资源的**域名白名单**匹配规则。
///
/// 用户可以在「设置 → 安全」或读信页的资源 Banner 里把某个域名（或它的
/// 通配写法）加进白名单；命中白名单的资源**不再被默认拦截**，打开邮件就
/// 直接加载（商业版仍然会走它自己的代理改写）。
///
/// ## 语法
///
/// - 精确域名：`cdn.example.com` 只匹配它自己（**不包括**子域名）；
/// - 通配符 `*`：匹配任意长度（含空串、含 `.`）的字符。
///   `*.example.com` 匹配 `a.example.com`、`a.b.example.com`，但**不匹配**
///   `example.com` —— 根域名要单独加一条。`img*.example.com` 同理只匹配
///   形如 `img1.example.com` 的前缀。
/// - 大小写不敏感。
/// - 必须是带点的域名（或 IP 字面量）；单 label 的写法（`localhost`）不接受。
/// - 粘贴整条 URL（`https://cdn.example.com/a.png`）也行，只取其中的 host；
///   端口、路径、query、fragment 一律丢掉。
/// - 以 `.` 开头的写法（`.example.com`）按 `*.example.com` 处理 —— 这是
///   用户从别的工具带过来的习惯写法。
///
/// ## 为什么宁严勿宽
///
/// 白名单是**安全边界**（放行会让收件人的 IP 直接暴露给发件人的服务器），
/// 所以不认识的输入一律判无效，而不是猜用户想匹配什么：中文/空格/`?` 等
/// 字符直接拒绝，单独一个 `*`（等于全部放行）也拒绝。
///
/// 匹配只看 **host**，与 URL 里的路径无关 —— 这正是「域名白名单」的含义。
library;

/// 把用户输入的一行「域名 / 通配域名 / URL」规范化成白名单 pattern。
///
/// 返回 null 表示这行输入不可用（空行、含非法字符、只有通配符没有固定
/// 字符）。调用方据此提示「这个域名不合法」，不要静默放行。
String? normalizeDomainPattern(String raw) {
  var text = raw.trim().toLowerCase();
  if (text.isEmpty) return null;

  // 粘贴整条 URL 也行：只保留 host 那一段。这里不交给 `Uri.parse` ——
  // 带 `*` 的通配写法（`https://*.example.com/a`）会被它判成非法 host。
  final schemeEnd = text.indexOf('://');
  if (schemeEnd >= 0) {
    text = text.substring(schemeEnd + 3);
  } else if (text.startsWith('//')) {
    text = text.substring(2);
  }
  // 端口、路径、query、fragment 都不属于「域名」，出现就丢掉。
  final cut = text.indexOf(RegExp(r'[/:?#]'));
  if (cut >= 0) text = text.substring(0, cut);

  // 结尾的点（FQDN 写法 `example.com.`）不算差异。
  while (text.endsWith('.')) {
    text = text.substring(0, text.length - 1);
  }
  if (text.isEmpty) return null;

  // `.example.com` 是 `*.example.com` 的另一种写法。
  if (text.startsWith('.')) text = '*$text';

  // 只允许域名里会出现的字符 + 通配符。中文域名请用 punycode（`xn--`）。
  if (!RegExp(r'^[a-z0-9.*_-]+$').hasMatch(text)) return null;

  // 至少要有固定字符：单独一个 `*` / `*.*` 等于「全部都放行」，
  // 那不是「域名白名单」，是误操作。
  if (text.replaceAll('*', '').replaceAll('.', '').isEmpty) return null;

  // 必须是带点的域名（或 IP 字面量）。单 label（`localhost`、被截断的
  // `://x`）不可能是邮件里的外联 host，收下只会误导用户。
  if (!text.contains('.')) return null;

  // 连续点（`a..b`）不合法。
  if (text.contains('..')) return null;

  return text;
}

/// 单个 host 是否命中单个 pattern（pattern 会先过一遍规范化）。
///
/// 供测试与一次性判断用；页面里的批量匹配请用 [DomainAllowList] ——
/// 它把正则只编译一次。
bool hostMatchesDomainPattern(String host, String pattern) {
  final normalized = normalizeDomainPattern(pattern);
  if (normalized == null) return false;
  final target = host.trim().toLowerCase();
  if (target.isEmpty) return false;
  return _patternRegExp(normalized).hasMatch(target);
}

/// host 是否命中其中任意一条 pattern。
bool hostMatchesAnyDomainPattern(String host, Iterable<String> patterns) {
  final target = host.trim().toLowerCase();
  if (target.isEmpty) return false;
  for (final pattern in patterns) {
    if (hostMatchesDomainPattern(target, pattern)) return true;
  }
  return false;
}

/// 一份**已编译**的域名白名单。
///
/// 规范化 + 正则编译都在构造时做一次；之后每个资源只跑几次 `hasMatch`。
/// 读信页一个 build 会逐图问策略，把这个开销摊到每条 URL 上不值得。
class DomainAllowList {
  DomainAllowList([Iterable<String> patterns = const <String>[]]) {
    for (final raw in patterns) {
      final pattern = normalizeDomainPattern(raw);
      if (pattern == null || _patterns.contains(pattern)) continue;
      _patterns.add(pattern);
      _matchers.add(_patternRegExp(pattern));
    }
  }

  final List<String> _patterns = <String>[];
  final List<RegExp> _matchers = <RegExp>[];

  /// 规范化后的 pattern，按加入顺序去重。
  List<String> get patterns => List<String>.unmodifiable(_patterns);

  bool get isEmpty => _patterns.isEmpty;

  int get length => _patterns.length;

  /// 这批 pattern 里有没有能命中 [host] 的。
  bool allows(String host) {
    final target = host.trim().toLowerCase();
    if (target.isEmpty) return false;
    for (final matcher in _matchers) {
      if (matcher.hasMatch(target)) return true;
    }
    return false;
  }
}

/// pattern → 锚定的正则：`*` 换成 `.*`，其余字符按字面量转义。
RegExp _patternRegExp(String pattern) {
  final escaped = pattern
      .replaceAllMapped(
        RegExp(r'[.*+?^${}()|\[\]\\]'),
        (match) => '\\${match[0]}',
      )
      .replaceAll(r'\*', '.*');
  return RegExp('^$escaped\$', caseSensitive: false);
}
