import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../compose/html/html_depth_guard.dart';

/// 邮件正文里的**外联资源**：不在实例自家 OSS 域上、需要客户端发网络请求的
/// 东西（图片、背景图、外链样式表、脚本、媒体、字体……）。
///
/// 这个文件只做两件事：
/// 1. 在读信页渲染**之前**把正文里能联网的资源列出来，供安全 Banner 展示；
/// 2. 提供一份**默认拒绝**的加载策略 —— 凡外联、未启用，就一律不加载。
///
/// 扫描（[scanExternalResources]）与加载策略（[ExternalResourcePolicy]）是分开
/// 的，这一点很重要：**拦截不依赖扫描是否完整**。扫描只负责「告诉用户有什么」，
/// 渲染层用 [ExternalResourcePolicy] 逐 URL 判「能不能加载」。哪怕这里漏了一种
/// 写法，也不会因为漏扫而放行。
///
/// 自家 OSS 的判定只看 host（`ossBase` 解析出来的 host）。`{{domain}}` 内嵌图
/// 在渲染前已经被换成了自家前缀，不属于外联，保持自动加载。
enum ExternalResourceKind {
  /// `<img src>`。
  image,

  /// 行内 `style="background:url(...)"`、`background` 属性、`<style>` 里的图片。
  cssImage,

  /// `<link rel=stylesheet>` 与 CSS `@import`。
  stylesheet,

  /// `<script src>`。
  script,

  /// `<video>/<audio>/<source>/<track>` 与视频封面。
  media,

  /// `<iframe src>`。
  frame,

  /// `@font-face` 的字体文件。
  font,
}

/// 一个去重后的外联资源。
class ExternalResource {
  const ExternalResource({
    required this.url,
    required this.host,
    required this.kind,
    this.count = 1,
    this.label,
    this.trackingPixel = false,
  });

  /// 规范化后的绝对地址（http/https，去掉 fragment）。
  final String url;

  /// 展示用的域名（小写，不含端口）。
  final String host;

  final ExternalResourceKind kind;

  /// 正文里引用它的次数。
  final int count;

  /// `<img alt>` 之类的可读标签，可能为空。
  final String? label;

  /// 是否像追踪像素：外链 `<img>`，且宽高都读得到、都 ≤ 2。
  ///
  /// 1×1 的透明图不会显示任何东西，唯一用途就是「邮件被打开时通知发件人」。
  /// 读不到尺寸的图片不猜（正常小图标不计入），宁可漏报也不误报。
  final bool trackingPixel;

  /// 这一类资源是否有可能被「启用」。
  ///
  /// 样式表 / 脚本 / 框架是**永远不加载**的：渲染器没有 JS 执行环境，
  /// fwfh 也不支持外链 CSS。它们出现在 Banner 里只是让用户知道这封邮件想
  /// 加载什么，不该给一个点了没反应的启用按钮。
  bool get canEnable =>
      kind == ExternalResourceKind.image ||
      kind == ExternalResourceKind.cssImage ||
      kind == ExternalResourceKind.media ||
      kind == ExternalResourceKind.font;

  ExternalResource copyWith({int? count, bool? trackingPixel}) =>
      ExternalResource(
        url: url,
        host: host,
        kind: kind,
        count: count ?? this.count,
        label: label,
        trackingPixel: trackingPixel ?? this.trackingPixel,
      );
}

/// 扫描结果。顺序是正文里的首次出现顺序（用户从上往下读时能对上）。
class ExternalResourceScan {
  const ExternalResourceScan(this.resources);

  static const ExternalResourceScan empty =
      ExternalResourceScan(<ExternalResource>[]);

  final List<ExternalResource> resources;

  bool get isEmpty => resources.isEmpty;

  Iterable<ExternalResource> get loadable =>
      resources.where((r) => r.canEnable);

  int get loadableCount => loadable.length;

  int get domains => resources.map((r) => r.host).toSet().length;

  /// 疑似追踪像素的外链图片（1×1 / 2×2）。见 [ExternalResource.trackingPixel]。
  List<ExternalResource> get trackingPixels =>
      resources.where((r) => r.trackingPixel).toList(growable: false);

  bool get hasTrackingPixels => resources.any((r) => r.trackingPixel);

  int get trackingPixelCount =>
      resources.where((r) => r.trackingPixel).length;
}

/// 扫描正文里的外联资源。
///
/// **必须在净化之前调用**：`sanitizeEmailHtml` 会把 `<script>`、
/// `<link rel=stylesheet>` 等删掉，之后再扫就看不到它们了。
///
/// 输入是不可信 HTML，因此这里与净化器共用同一道深度预检：超深正文不解析，
/// 返回空扫描（此时正文本身也会被降级成纯文本，不会联网）。
ExternalResourceScan scanExternalResources(
  String html, {
  required String ossBase,
}) {
  if (html.trim().isEmpty) return ExternalResourceScan.empty;
  if (HtmlDepthGuard.exceedsLimit(html)) return ExternalResourceScan.empty;

  // 与 `sanitizeEmailHtml` 一致：`<html>/<body>` 外壳会被 fragment 解析忽略，
  // 先去掉避免影响判断。
  final stripped = html
      .replaceAll(RegExp(r'</?body[^>]*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'</?html[^>]*>', caseSensitive: false), '');
  final fragment = html_parser.parseFragment(stripped);

  final baseUri = Uri.tryParse(ossBase.trim());
  final base = baseUri != null && baseUri.hasScheme ? baseUri : null;
  final ownHost = base?.host.toLowerCase() ?? '';

  final found = <String, ExternalResource>{};

  void add(
    String? raw,
    ExternalResourceKind kind, {
    String? label,
    bool trackingPixel = false,
  }) {
    final resolved = _resolve(raw, base);
    if (resolved == null) return;
    if (ownHost.isNotEmpty && resolved.$2.host.toLowerCase() == ownHost) return;

    final key = resolved.$1;
    final existing = found[key];
    if (existing != null) {
      // 同一 URL 第二次出现时也把「追踪像素」的信息合进来：先出现的是不带
      // 尺寸的写法、后面才带 1×1 的情况同样要提醒。
      found[key] = existing.copyWith(
        count: existing.count + 1,
        trackingPixel: existing.trackingPixel || trackingPixel,
      );
      return;
    }
    found[key] = ExternalResource(
      url: key,
      host: resolved.$2.host.toLowerCase(),
      kind: kind,
      label: label,
      trackingPixel: trackingPixel,
    );
  }

  for (final element in fragment.querySelectorAll('*')) {
    final tag = (element.localName ?? '').toLowerCase();

    // 行内 style / background 属性对任何元素都可能带图。
    final style = element.attributes['style'];
    if (style != null && style.isNotEmpty) {
      _scanCss(style, (url, kind) => add(url, kind));
    }
    final background = element.attributes['background'];
    if (background != null) add(background, ExternalResourceKind.cssImage);

    switch (tag) {
      case 'img':
        add(
          element.attributes['src'],
          ExternalResourceKind.image,
          label: element.attributes['alt'],
          trackingPixel: _isTrackingPixel(element),
        );
      // `srcset` 不收集：fwfh 根本不读它，不渲染就没有风险。
      case 'link':
        final rel = (element.attributes['rel'] ?? '').toLowerCase();
        if (rel.split(RegExp(r'\s+')).contains('stylesheet')) {
          add(element.attributes['href'], ExternalResourceKind.stylesheet);
        }
      case 'script':
        add(element.attributes['src'], ExternalResourceKind.script);
      case 'video':
        add(element.attributes['src'], ExternalResourceKind.media);
        add(element.attributes['poster'], ExternalResourceKind.media);
      case 'audio':
      case 'source':
      case 'track':
        add(element.attributes['src'], ExternalResourceKind.media);
      case 'iframe':
      case 'frame':
        add(element.attributes['src'], ExternalResourceKind.frame);
      case 'style':
        _scanCss(element.text, (url, kind) => add(url, kind));
    }
  }

  return ExternalResourceScan(List<ExternalResource>.unmodifiable(found.values));
}

/// 外联资源的加载策略。**默认拒绝**。
///
/// - `enabled`：用户显式启用的资源（规范化 URL）；
/// - `blocked`：用户显式屏蔽的资源 —— 仅用于「自动加载」模式下的单项屏蔽；
/// - `blockAll`：「全部屏蔽」时置位，优先于 `autoLoad`；
/// - `autoLoad`：Pro 的「自动加载外部图片（经代理）」设置；
/// - `rewriteUrl`：扩展提供的地址改写（Pro 的云端代理）。只对外联资源调用。
class ExternalResourcePolicy {
  ExternalResourcePolicy({
    required this.ossBase,
    this.autoLoad = false,
    this.rewriteUrl,
    Set<String>? enabled,
    Set<String>? blocked,
    this.blockAll = false,
  })  : enabled = enabled ?? <String>{},
        blocked = blocked ?? <String>{};

  final String ossBase;
  final bool autoLoad;
  final String? Function(String url)? rewriteUrl;
  final Set<String> enabled;
  final Set<String> blocked;
  final bool blockAll;

  /// 规范化后的地址；解析不了就返回原串（只用于相等比较）。
  String normalize(String url) {
    final resolved = _resolve(url, _baseUri);
    return resolved?.$1 ?? url;
  }

  /// 是否是自己实例的资源（或根本不是网络地址）。
  bool isExternal(String url) {
    final resolved = _resolve(url, _baseUri);
    if (resolved == null) return false;
    final host = resolved.$2.host.toLowerCase();
    if (host.isEmpty) return false;
    final ownHost = _baseUri?.host.toLowerCase() ?? '';
    return ownHost.isEmpty || host != ownHost;
  }

  bool isBlocked(String url) {
    if (!isExternal(url)) return false;
    final key = normalize(url);
    // 用户逐项「显示」优先于任何全局开关。
    if (enabled.contains(key)) return false;
    if (blocked.contains(key)) return true;
    if (blockAll) return true;
    if (autoLoad) return false;
    return true;
  }

  bool isLoaded(String url) => isExternal(url) && !isBlocked(url);

  /// 实际加载地址。外联资源才交给扩展改写（Pro 的代理）。
  String loadUrl(String url) {
    if (!isExternal(url)) return url;
    final key = normalize(url);
    final rewritten = rewriteUrl?.call(key);
    return rewritten == null || rewritten.isEmpty ? key : rewritten;
  }

  String hostOf(String url) {
    final resolved = _resolve(url, _baseUri);
    return resolved?.$2.host.toLowerCase() ?? '';
  }

  Uri? get _baseUri {
    final uri = Uri.tryParse(ossBase.trim());
    return uri != null && uri.hasScheme ? uri : null;
  }
}

/// 解析并规范化一个 URL。返回 `(绝对地址, Uri)`；不是 http(s) 的返回 null。
///
/// fragment 一定去掉：`#x` 不影响资源本体，留着会让同一张图在去重/启用集合里
/// 出现两份。
(String, Uri)? _resolve(String? raw, Uri? base) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null) return null;

  final absolute =
      parsed.hasScheme ? parsed : base?.resolveUri(parsed) ?? parsed;
  final scheme = absolute.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (absolute.host.isEmpty) return null;

  final normalized = absolute.removeFragment();
  return (normalized.toString(), normalized);
}

/// 1×1 / 2×2 的外链图片 —— 典型的追踪像素。
///
/// 尺寸来源只认 `width` / `height` 属性与**行内** `style` 里的 px 值；不解析
/// `<style>` 里的类选择器（那需要真 CSS 引擎，而且追踪像素几乎都写在行内）。
/// 两个方向都必须读得到才判定，避免把「宽 1px 的装饰线」误当成追踪器。
bool _isTrackingPixel(dom.Element element) {
  final width = _dimension(element, 'width');
  final height = _dimension(element, 'height');
  return width != null && height != null && width <= 2 && height <= 2;
}

/// 读一个方向上的尺寸（px）。小数、`px` 后缀都接受；百分比/`auto` 等返回 null。
double? _dimension(dom.Element element, String name) {
  final fromAttr = _pxValue(element.attributes[name]);
  if (fromAttr != null) return fromAttr;

  final style = element.attributes['style'];
  if (style == null || style.isEmpty) return null;
  final match = RegExp(
    '(?:^|;)\\s*${RegExp.escape(name)}\\s*:\\s*([0-9]*\\.?[0-9]+)\\s*(?:px)?\\s*(?=;|!|\$)',
    caseSensitive: false,
  ).firstMatch(style);
  return _pxValue(match?.group(1));
}

double? _pxValue(String? raw) {
  if (raw == null) return null;
  final match = RegExp(
    r'^\s*([0-9]*\.?[0-9]+)\s*(?:px)?\s*$',
    caseSensitive: false,
  ).firstMatch(raw);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

/// 从一段 CSS 文本里抠出 `url(...)` / `@import`。
///
/// 不走 `csslib`：这里只需要「有没有外联地址」，让第三方解析器处理不可信 CSS
/// 反而多一层风险。正则只用于**提取字符串**，提取出来的地址随后还会经过
/// [_resolve] 的协议/host 校验，不会被当成 HTML/JS 执行。
void _scanCss(
  String css,
  void Function(String url, ExternalResourceKind kind) add,
) {
  // @import "x.css" / @import url("x.css") —— 都是外联样式表。
  final importPattern = RegExp(
    r'''@import\s+(?:url\(\s*)?["']([^"']+)["']''',
    caseSensitive: false,
  );
  final imports = <({int start, int end})>[];
  for (final match in importPattern.allMatches(css)) {
    final url = match.group(1);
    if (url != null) {
      add(url, ExternalResourceKind.stylesheet);
      imports.add((start: match.start, end: match.end));
    }
  }

  // @font-face { src: url(...) } —— 字体文件单独标一类。
  final fontSpans = <({int start, int end})>[];
  final fontFace = RegExp(r'@font-face\s*\{', caseSensitive: false);
  for (final match in fontFace.allMatches(css)) {
    var end = css.indexOf('}', match.end);
    if (end < 0) end = css.length;
    fontSpans.add((start: match.start, end: end));
  }

  final urlPattern = RegExp(
    r'''url\(\s*(?:"([^"]*)"|'([^']*)'|([^)'"\s]+))\s*\)''',
    caseSensitive: false,
  );
  for (final match in urlPattern.allMatches(css)) {
    // @import url(...) 已经在上面按样式表记过了。
    if (imports.any((s) => match.start >= s.start && match.start < s.end)) {
      continue;
    }
    final raw = match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
    if (raw.trim().isEmpty) continue;
    final isFont =
        fontSpans.any((s) => match.start >= s.start && match.start < s.end);
    add(raw, isFont ? ExternalResourceKind.font : ExternalResourceKind.cssImage);
  }
}
