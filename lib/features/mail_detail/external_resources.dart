import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../compose/html/html_depth_guard.dart';
import 'external_allowlist.dart';

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

  /// 是否像追踪像素（1×1 / 2×2 的透明图）。
  ///
  /// 尺寸按 CSS 层叠取值：**行内 style > `<style>` 里的 class/id/标签 >
  /// HTML 属性**。两个方向都读得到时要求都 ≤ 2；只读得到一个方向时，只要它
  /// ≤ 2 也算（`<img height="1">` 是常见的追踪图写法）。两个方向都读不到时
  /// 不猜 —— 那会把所有图片都算成可疑。
  ///
  /// 注意：**这不影响拦截**。所有外联资源都按 URL 默认拦截，尺寸只决定
  /// 「要不要额外提醒用户这可能是在追踪」。
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

/// 同一个域名下的一组外联资源。Banner 按域名分组展示时用它。
///
/// 组内顺序 = 正文里的首次出现顺序；组与组之间也按**域名首次出现**的顺序
/// 排 —— 用户从上往下读邮件时，列表与正文对得上。
class ExternalResourceDomainGroup {
  const ExternalResourceDomainGroup(this.host, this.resources);

  final String host;
  final List<ExternalResource> resources;

  /// 组内去重后的资源条数（与 [ExternalResource.count] 不是一回事：
  /// 后者是同一个 URL 在正文里被引用的次数）。
  int get count => resources.length;

  /// 组内所有资源被引用的总次数。
  int get references =>
      resources.fold<int>(0, (sum, resource) => sum + resource.count);

  bool get hasTrackingPixels => resources.any((r) => r.trackingPixel);
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

  /// 按域名分组，域名按其首次出现顺序排列。
  ///
  /// 扫描结果本身**不去重域名**（同一域名下的多张图是不同资源），
  /// Banner 需要一个「域名 → 资源列表」的视图，就在这里算一次。
  List<ExternalResourceDomainGroup> get byDomain =>
      groupExternalResourcesByDomain(resources);

  /// 疑似追踪像素的外链图片（1×1 / 2×2）。见 [ExternalResource.trackingPixel]。
  List<ExternalResource> get trackingPixels =>
      resources.where((r) => r.trackingPixel).toList(growable: false);

  bool get hasTrackingPixels => resources.any((r) => r.trackingPixel);

  int get trackingPixelCount =>
      resources.where((r) => r.trackingPixel).length;
}

/// 把一组资源按域名分组；域名按**首次出现**顺序，组内保持原顺序。
///
/// 单独抽成函数是因为 Banner 手里只有 `List<ExternalResource>`（它不重新
/// 扫描正文），而扫描结果那边的 [ExternalResourceScan.byDomain] 也要用同一
/// 份逻辑 —— 分组规则只该有一份。
List<ExternalResourceDomainGroup> groupExternalResourcesByDomain(
  Iterable<ExternalResource> resources,
) {
  final order = <String>[];
  final buckets = <String, List<ExternalResource>>{};
  for (final resource in resources) {
    final bucket = buckets[resource.host];
    if (bucket == null) {
      order.add(resource.host);
      buckets[resource.host] = <ExternalResource>[resource];
    } else {
      bucket.add(resource);
    }
  }
  return <ExternalResourceDomainGroup>[
    for (final host in order)
      ExternalResourceDomainGroup(
        host,
        List<ExternalResource>.unmodifiable(buckets[host]!),
      ),
  ];
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

  final allElements = fragment.querySelectorAll('*');

  // 先把 `<style>` 里的规则解析出来：`<img class="pixel">` 这类把 1×1 写在
  // 样式表里的写法，只靠属性是看不到的。
  final styleRules = <dom.Element, List<_CssRule>>{};
  for (final element in allElements) {
    if ((element.localName ?? '').toLowerCase() == 'style') {
      styleRules[element] = _parseCssRules(element.text);
    }
  }
  final cssRules =
      styleRules.values.expand((rules) => rules).toList(growable: false);

  // 每个元素的层叠结果与尺寸只算一次：把样式表里的背景图升级成追踪像素时
  // 也要读同一份结果。
  final cssCache = <dom.Element, Map<String, String>>{};
  final sizeCache = <dom.Element, (double?, double?)>{};
  final selectorCache = <String, _ParsedSelector?>{};
  Map<String, String> cssOf(dom.Element element) => cssCache.putIfAbsent(
        element,
        () => cssRules.isEmpty
            ? const <String, String>{}
            : _computeCssDeclarations(element, cssRules, selectorCache),
      );
  (double?, double?) sizeOf(dom.Element element) => sizeCache.putIfAbsent(
        element,
        () => _elementSize(element, cssOf(element)),
      );

  for (final element in allElements) {
    final tag = (element.localName ?? '').toLowerCase();
    final style = element.attributes['style'];
    final background = element.attributes['background'];

    // 尺寸只为「可能是追踪像素」的元素算：图片、带背景的元素。逐个元素都
    // 跑一遍样式表匹配的话，上千个元素 × 上百条规则会明显拖慢读信页。
    final needsSize = tag == 'img' ||
        background != null ||
        (style != null &&
            (style.contains('background') || style.contains('url(')));
    final size = needsSize ? sizeOf(element) : null;
    final tiny =
        size != null && _looksLikeTrackingPixel(size.$1, size.$2);

    // 行内 style / background 属性对任何元素都可能带图；如果这个元素本身
    // 就是 1×1 尺寸，背景图同样可能是追踪像素（1×1 透明 GIF 当背景）。
    if (style != null && style.isNotEmpty) {
      _scanCss(style, (url, kind) => add(url, kind, trackingPixel: tiny));
    }
    if (background != null) {
      add(background, ExternalResourceKind.cssImage, trackingPixel: tiny);
    }

    switch (tag) {
      case 'img':
        add(
          element.attributes['src'],
          ExternalResourceKind.image,
          label: element.attributes['alt'],
          trackingPixel: tiny,
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
        _upgradeCssBackgrounds(
          styleRules[element] ?? const <_CssRule>[],
          allElements,
          sizeOf,
          selectorCache,
          add,
        );
    }
  }

  return ExternalResourceScan(List<ExternalResource>.unmodifiable(found.values));
}

/// 外联资源的加载策略。**默认拒绝**。
///
/// 判定顺序（先命中先返回）：
///
/// 1. `enabled`：用户逐项点过「启用」的 URL → 放行；
/// 2. `blocked`：用户逐项点过「屏蔽」的 URL → 拦截（单个 URL 的显式否决
///    优先于域名白名单 —— 用户对这一次点击的意图最明确）；
/// 3. `allowedHosts`：**域名白名单**（支持 `*`，见
///    `external_allowlist.dart`）命中的 host → 放行。白名单是用户的长期
///    信任设置，语义就是「这些域名的资源不过滤」，所以它优先于下面两个
///    一次性开关；
/// 4. `blockAll`：「全部屏蔽」时置位，优先于 `autoLoad`；
/// 5. `autoLoad`：Pro 的「自动加载外部图片（经代理）」设置；
/// 6. 其余一律拦截。
///
/// - `rewriteUrl`：扩展提供的地址改写（Pro 的云端代理）。只对外联资源调用。
class ExternalResourcePolicy {
  ExternalResourcePolicy({
    required this.ossBase,
    this.autoLoad = false,
    this.rewriteUrl,
    Set<String>? enabled,
    Set<String>? blocked,
    this.blockAll = false,
    Iterable<String> allowedHosts = const <String>[],
  })  : enabled = enabled ?? <String>{},
        blocked = blocked ?? <String>{},
        allowList = DomainAllowList(allowedHosts);

  final String ossBase;
  final bool autoLoad;
  final String? Function(String url)? rewriteUrl;
  final Set<String> enabled;
  final Set<String> blocked;
  final bool blockAll;

  /// 域名白名单（已规范化 + 编译好的正则）。
  final DomainAllowList allowList;

  /// 白名单里的 pattern（规范化后的字符串），给 UI 展示用。
  List<String> get allowedHosts => allowList.patterns;

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

  /// 这个 host 是否在白名单里。
  ///
  /// 只做域名匹配，不问它是不是外联 —— Banner 已经按域名分组，拿着 host
  /// 直接用；传进来的 host 是空的就返回 false。
  bool isHostAllowed(String host) => allowList.allows(host);

  /// 这个外联资源是否被白名单放行。
  bool isAllowListed(String url) {
    if (allowList.isEmpty) return false;
    return isHostAllowed(hostOf(url));
  }

  bool isBlocked(String url) {
    if (!isExternal(url)) return false;
    final key = normalize(url);
    // 用户逐项「显示」优先于任何全局开关。
    if (enabled.contains(key)) return false;
    if (blocked.contains(key)) return true;
    // 域名白名单：长期信任设置，语义就是「不过滤」。
    if (isAllowListed(url)) return false;
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

/// 1×1 / 2×2 的图片 —— 典型的追踪像素。
///
/// 尺寸来源按 CSS 的层叠顺序取值：行内 style > 样式表（class/id/标签）>
/// HTML 属性。两个方向都读得到时要求都 ≤ 2；只读得到一个方向时，只要它 ≤ 2
/// 也当作「疑似追踪像素」—— 这是为了覆盖 `<img src="..." height="1">` 这种
/// 只写一个方向的追踪图。完全不写尺寸的外链图不判定（那会把所有图片都算成
/// 可疑），但它们仍然会被默认策略拦截。
bool _looksLikeTrackingPixel(double? width, double? height) {
  if (width != null && height != null) return width <= 2 && height <= 2;
  if (width != null) return width <= 2;
  if (height != null) return height <= 2;
  return false;
}

/// 元素的有效尺寸（width/height，单位 px）。读不到（百分比/auto/em）返回 null。
(double?, double?) _elementSize(
  dom.Element element,
  Map<String, String> css,
) {
  final inline = _parseDeclarations(element.attributes['style'] ?? '');
  double? side(String name) {
    final fromInline = _cssLength(inline[name]);
    if (fromInline != null) return fromInline;
    final fromCss = _cssLength(css[name]);
    if (fromCss != null) return fromCss;
    return _pxValue(element.attributes[name]);
  }

  return (side('width'), side('height'));
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

/// CSS 长度：只认 `Npx` 与 `0`。百分比、`auto`、`em` 等一律返回 null ——
/// 猜它们会让「1×1 判定」变得不可靠。`!important` 先剥掉。
double? _cssLength(String? raw) {
  if (raw == null) return null;
  final text = raw
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s*!important\s*$'), '');
  final match = RegExp(r'^(-?[0-9]*\.?[0-9]+)\s*px$').firstMatch(text);
  if (match != null) return double.tryParse(match.group(1)!);
  return text == '0' ? 0 : null;
}

/// 样式表里的背景图升级为追踪像素。
///
/// 触发条件（满足其一）：
/// 1. 规则自己声明了 1×1 尺寸（`.p{width:1px;height:1px;background:url(...)}`）；
/// 2. 规则命中的某个元素，按层叠结果算出来的尺寸像追踪像素。
///
/// 这是「`<style>` 里设置的 1×1 背景图」那条漏检的补丁：扫描器不是 CSS
/// 引擎，但对追踪像素这种**简单、静态**的写法足够了。
void _upgradeCssBackgrounds(
  List<_CssRule> rules,
  List<dom.Element> elements,
  (double?, double?) Function(dom.Element) sizeOf,
  Map<String, _ParsedSelector?> selectorCache,
  void Function(
    String? raw,
    ExternalResourceKind kind, {
    String? label,
    bool trackingPixel,
  }) add,
) {
  for (final rule in rules) {
    final urls = _backgroundUrls(rule.declarations);
    if (urls.isEmpty) continue;

    var tiny = _looksLikeTrackingPixel(
      _cssLength(rule.declarations['width']),
      _cssLength(rule.declarations['height']),
    );
    if (!tiny) {
      for (final element in elements) {
        if (!_ruleMatches(rule, element, selectorCache)) continue;
        final size = sizeOf(element);
        if (_looksLikeTrackingPixel(size.$1, size.$2)) {
          tiny = true;
          break;
        }
      }
    }

    for (final url in urls) {
      add(url, ExternalResourceKind.cssImage, trackingPixel: tiny);
    }
  }
}

// ---- 轻量 CSS 解析 ----
//
// 只为一件事服务：把 `<style>` 里 class/id/标签上的 width/height 与
// background 读出来，补上「1×1 写在样式表里」的漏检。它不是通用 CSS 引擎：
// 伪类、属性选择器、兄弟选择器一律跳过（宁可漏报，不误报）；媒体查询里的
// 规则会被当作生效处理（追踪像素不会藏在 media query 里）。

/// 一条已解析的 CSS 规则。
class _CssRule {
  _CssRule(this.selectors, this.declarations, this.order);

  final List<String> selectors;
  final Map<String, String> declarations;

  /// 源码里的顺序，用于同优先级时「后写的赢」。
  final int order;
}

/// 解析 `<style>` 文本。只取「选择器 { 声明 }」形式，`@font-face` / `@media`
/// 这类 at-rule 本身跳过。
List<_CssRule> _parseCssRules(String css) {
  if (css.trim().isEmpty) return const <_CssRule>[];
  // 上限只是防御：正常邮件的 `<style>` 远小于这个规模；超过时宁可不做 CSS
  // 尺寸推断，也不要让读信页为了解析样式卡住。
  if (css.length > 128 * 1024) return const <_CssRule>[];
  final source = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final rules = <_CssRule>[];
  final pattern = RegExp(r'([^{}]+)\{([^{}]*)\}');
  for (final match in pattern.allMatches(source)) {
    final selectorText = (match.group(1) ?? '').trim();
    if (selectorText.isEmpty || selectorText.startsWith('@')) continue;
    final declarations = _parseDeclarations(match.group(2) ?? '');
    if (declarations.isEmpty) continue;
    final selectors = selectorText
        .split(',')
        .map((selector) => selector.trim())
        .where((selector) => selector.isNotEmpty)
        .toList(growable: false);
    if (selectors.isEmpty) continue;
    rules.add(_CssRule(selectors, declarations, rules.length));
    if (rules.length >= 512) break;
  }
  return rules;
}

/// 解析一段声明文本。`;` 只在括号外、引号外才分割 —— 否则
/// `url(data:image/png;base64,...)` 会被切成两半。
Map<String, String> _parseDeclarations(String text) {
  final parts = <String>[];
  final current = StringBuffer();
  var depth = 0;
  var quote = '';
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quote.isNotEmpty) {
      current.write(ch);
      if (ch == quote) quote = '';
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      current.write(ch);
      continue;
    }
    if (ch == '(') {
      depth++;
      current.write(ch);
      continue;
    }
    if (ch == ')') {
      if (depth > 0) depth--;
      current.write(ch);
      continue;
    }
    if (ch == ';' && depth == 0) {
      parts.add(current.toString());
      current.clear();
      continue;
    }
    current.write(ch);
  }
  if (current.isNotEmpty) parts.add(current.toString());

  final result = <String, String>{};
  for (final part in parts) {
    final colon = part.indexOf(':');
    if (colon <= 0) continue;
    final name = part.substring(0, colon).trim().toLowerCase();
    final value = part
        .substring(colon + 1)
        .trim()
        .replaceAll(RegExp(r'\s*!important\s*$', caseSensitive: false), '');
    if (name.isEmpty || value.isEmpty) continue;
    result[name] = value;
  }
  return result;
}

/// 按层叠算出一个元素最终生效的 CSS 声明（不含行内 style，行内单独覆盖）。
Map<String, String> _computeCssDeclarations(
  dom.Element element,
  List<_CssRule> rules,
  Map<String, _ParsedSelector?> selectorCache,
) {
  final best = <String, ({int specificity, int order, String value})>{};
  for (final rule in rules) {
    var specificity = -1;
    for (final selector in rule.selectors) {
      final matched =
          _selectorSpecificity(element, selector, selectorCache);
      if (matched != null && matched > specificity) specificity = matched;
    }
    if (specificity < 0) continue;

    for (final entry in rule.declarations.entries) {
      final current = best[entry.key];
      final wins = current == null ||
          specificity > current.specificity ||
          (specificity == current.specificity && rule.order >= current.order);
      if (wins) {
        best[entry.key] = (
          specificity: specificity,
          order: rule.order,
          value: entry.value,
        );
      }
    }
  }
  return <String, String>{
    for (final entry in best.entries) entry.key: entry.value.value,
  };
}

bool _ruleMatches(
  _CssRule rule,
  dom.Element element,
  Map<String, _ParsedSelector?> selectorCache,
) =>
    rule.selectors.any(
      (selector) => _selectorSpecificity(element, selector, selectorCache) != null,
    );

/// 预解析后的选择器：拆好的复合选择器、组合符与特异度。
///
/// 预解析是为了性能：一个元素要跟样式表里的每条规则比，选择器字符串不能
/// 每次都重新跑正则。解析失败的（伪类/属性/兄弟选择器等）为 null，直接跳过。
class _ParsedSelector {
  _ParsedSelector(this.compounds, this.combinators, this.score);

  final List<String> compounds;
  final List<String> combinators;
  final int score;
}

/// 选择器匹配 + 特异度；不支持的选择器返回 null（= 不匹配）。
int? _selectorSpecificity(
  dom.Element element,
  String selector,
  Map<String, _ParsedSelector?> cache,
) {
  final parsed = cache.putIfAbsent(selector, () => _parseSelector(selector));
  if (parsed == null) return null;
  return _matchesParsed(element, parsed) ? parsed.score : null;
}

_ParsedSelector? _parseSelector(String selector) {
  final trimmed = selector.trim();
  if (trimmed.isEmpty) return null;
  // 伪类、属性选择器、兄弟选择器不做部分匹配 —— 跳过它们比误判安全。
  if (trimmed.contains(':') ||
      trimmed.contains('[') ||
      trimmed.contains('+') ||
      trimmed.contains('~')) {
    return null;
  }

  final parts = trimmed
      .replaceAll(RegExp(r'\s*>\s*'), ' > ')
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return null;

  final compounds = <String>[];
  final combinators = <String>[];
  var pending = ' ';
  for (final part in parts) {
    if (part == '>') {
      pending = '>';
      continue;
    }
    if (compounds.isNotEmpty) combinators.add(pending);
    compounds.add(part);
    pending = ' ';
  }
  if (compounds.isEmpty || combinators.length != compounds.length - 1) {
    return null;
  }

  var score = 0;
  for (final compound in compounds) {
    score += _compoundSpecificity(compound);
  }
  return _ParsedSelector(compounds, combinators, score);
}

bool _matchesParsed(dom.Element element, _ParsedSelector selector) {
  final compounds = selector.compounds;
  final combinators = selector.combinators;

  bool matchAt(dom.Node? node, int index) {
    if (node is! dom.Element) return false;
    if (!_compoundMatches(node, compounds[index])) return false;
    if (index == 0) return true;
    if (combinators[index - 1] == '>') {
      return matchAt(node.parent, index - 1);
    }
    for (var ancestor = node.parent;
        ancestor != null;
        ancestor = ancestor.parent) {
      if (matchAt(ancestor, index - 1)) return true;
    }
    return false;
  }

  return matchAt(element, compounds.length - 1);
}

/// 复合选择器（`tag`、`.cls`、`#id`、`tag.cls`、`tag#id.cls`、`*`）。
bool _compoundMatches(dom.Element element, String compound) {
  final match = RegExp(
    r'^([a-zA-Z][a-zA-Z0-9-]*|\*)?((?:[.#][A-Za-z0-9_-]+)*)$',
  ).firstMatch(compound);
  if (match == null) return false;

  final tag = match.group(1);
  if (tag != null && tag != '*') {
    final actual = (element.localName ?? '').toLowerCase();
    if (actual != tag.toLowerCase()) return false;
  }

  var rest = match.group(2) ?? '';
  final classes = (element.attributes['class'] ?? '')
      .split(RegExp(r'\s+'))
      .where((name) => name.isNotEmpty)
      .toSet();
  final id = element.attributes['id'];

  while (rest.isNotEmpty) {
    final kind = rest[0];
    final nameMatch = RegExp(r'^[A-Za-z0-9_-]+').firstMatch(rest.substring(1));
    if (nameMatch == null) return false;
    final name = nameMatch.group(0)!;
    if (kind == '.') {
      if (!classes.contains(name)) return false;
    } else if (kind == '#') {
      if (id != name) return false;
    } else {
      return false;
    }
    rest = rest.substring(1 + name.length);
  }
  return true;
}

int _compoundSpecificity(String compound) {
  var score = 0;
  if (!compound.startsWith('.') && !compound.startsWith('#')) score += 1;
  for (var i = 0; i < compound.length; i++) {
    final ch = compound[i];
    if (ch == '#') {
      score += 10000;
    } else if (ch == '.') {
      score += 100;
    }
  }
  return score;
}

/// 从声明里取背景图 URL（只看 `background` / `background-image`）。
List<String> _backgroundUrls(Map<String, String> declarations) {
  final urls = <String>[];
  final pattern = RegExp(
    r"""url\(\s*(?:"([^"]*)"|'([^']*)'|([^)'"\s]+))\s*\)""",
    caseSensitive: false,
  );
  for (final property in const <String>['background', 'background-image']) {
    final value = declarations[property];
    if (value == null) continue;
    for (final match in pattern.allMatches(value)) {
      final raw = match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
      if (raw.trim().isNotEmpty) urls.add(raw);
    }
  }
  return urls;
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
