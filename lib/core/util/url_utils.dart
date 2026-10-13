/// OSS / 附件 URL 解析。全应用唯一入口 —— 组件里不要再手拼 URL。
///
/// 背景（读 worker 源码得出）：
/// - 附件行里 `key` 形如 `attachments/<sha256><ext>`，可能已经是完整 URL。
/// - `GET /api/oss/<key>` 免鉴权，且 `r2Service.storageType()` 会按配置分发到 KV / R2 / S3，
///   是唯一「存储类型无关」的下载路径。
/// - `GET /attachments/<key去掉前缀>` 只读 **KV**（`kvObjService.toObjResp`），
///   存储后端是 R2/S3 时会 404，所以**不要用它**。
/// - `email.content` 里的内嵌图是字面量占位符 `{{domain}}`，由客户端在渲染时替换。
class UrlUtils {
  const UrlUtils._();

  static const String _ossApiSegment = '/api/oss/';

  /// 把 `websiteConfig.r2Domain` 规范化成「带协议、带结尾斜杠」的前缀。
  ///
  /// 对齐 worker 的 `domainUtils.toOssDomain`（无协议时补 `https://`），
  /// 但**多一步**：`r2Domain` 为空/null 时返回 null，由调用方决定兜底，
  /// 而不是像 Web 端那样替换成 `/` —— 那会生成 `//attachments/x.png`
  /// 这种协议相对 URL，被 worker 的前缀判断漏掉，最终落到 SPA 资源上（Web 端的 bug）。
  static String? normalizeR2Domain(String? r2Domain) {
    final raw = r2Domain?.trim() ?? '';
    if (raw.isEmpty) return null;
    var value = raw;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    if (!value.endsWith('/')) value = '$value/';
    return value;
  }

  /// 计算附件/内嵌图的前缀。
  ///
  /// - `r2Domain` 有效 → `https://<r2Domain>/`
  /// - 否则 → `https://<userApi>/api/oss/`（`userApi` 是用户填的、含 `/api` 后缀的地址）
  static String ossBase({required String userApi, String? r2Domain}) {
    final normalized = normalizeR2Domain(r2Domain);
    if (normalized != null) return normalized;
    return '${hostRoot(userApi)}$_ossApiSegment';
  }

  /// 从用户填的 API 地址取出站点根，去掉结尾的 `/api`。
  ///
  /// `https://mail.example.com/api` → `https://mail.example.com`
  /// `https://mail.example.com/api/` → `https://mail.example.com`
  /// `https://mail.example.com` → `https://mail.example.com`
  static String hostRoot(String userApi) {
    var value = userApi.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.endsWith('/api')) {
      value = value.substring(0, value.length - '/api'.length);
    }
    return value;
  }

  /// 规范化用户填写的 API 地址：补 `https://`、去结尾斜杠、补上 `/api`。
  static String normalizeApiBase(String input) {
    var value = input.trim();
    if (value.isEmpty) return value;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (!value.endsWith('/api')) value = '$value/api';
    return value;
  }

  /// 附件 key → 可下载 URL。
  ///
  /// - 已是 `https://` 开头 → 原样返回（部分历史数据的 key 直接存了完整地址）
  /// - `ossBase` 已带 `/api/oss/` → 直接拼 key
  /// - 否则（r2Domain 形态）→ 直接拼 key
  static String resolveKey(String key, String ossBase) {
    if (key.isEmpty) return '';
    if (key.startsWith('http://') || key.startsWith('https://')) return key;
    final base = ossBase.endsWith('/') ? ossBase : '$ossBase/';
    return '$base$key';
  }

  /// 渲染正文时替换 `{{domain}}` 占位符（worker 的 `emailService.imgReplace` 写入的）。
  ///
  /// **必须在渲染时替换，不要写回本地缓存的 content** ——
  /// 实例日后配置了 r2Domain 时要能自动切到 CDN 前缀。
  static String substituteDomainToken(String html, String ossBase) {
    if (html.isEmpty || !html.contains('{{domain}}')) return html;
    final base = ossBase.endsWith('/') ? ossBase : '$ossBase/';
    return html.replaceAll('{{domain}}', base);
  }

  /// 是否是内嵌图（`{{domain}}` 已被替换后的形态）。
  static bool isAbsoluteHttp(String url) =>
      url.startsWith('http://') || url.startsWith('https://');
}
