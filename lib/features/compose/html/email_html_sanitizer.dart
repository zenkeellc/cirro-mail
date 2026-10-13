import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'html_depth_guard.dart';

/// 把**不可信 HTML**（剪贴板、别人发来的邮件）收拾成可以安全放进编辑器的形状。
///
/// 与读信页的 `sanitizeEmailHtml` 是同一类东西，但这边只需要「安全 + 干净」，
/// 不需要配合渲染器的 CSS 子集 —— 编辑器认的属性比读信页多。
///
/// 三类危险，逐条挡：
/// 1. **可执行内容** —— `<script>`/`<iframe>`/`on*` 属性；
/// 2. **协议走私** —— `href`/`src` 等 URL 载体只放行白名单里的 scheme
///    （`http(s):`/`mailto:`/`tel:`/`cid:`，图片来源另加光栅 `data:`）；
/// 3. **静默的样式污染** —— `class`/`id` 与字体色号。这些不会执行，但会把
///    「从 Word 粘来的黑字」带进邮件，在深色模式下就是黑底黑字。
abstract final class EmailHtmlSanitizer {
  const EmailHtmlSanitizer._();

  /// 连标签带内容一起删掉的元素。
  ///
  /// `template`/`math` 也在内：`template` 的内容不会渲染，但把
  /// `<script>` 塞进去是「解析器不管、DOM 里还在」的经典藏法；`math`
  /// 与已列的 `svg` 一样，是能挂事件处理器的外来命名空间根。
  static const List<String> _dropWithContent = <String>[
    'script', 'style', 'iframe', 'object', 'embed', 'link', 'meta', 'base',
    'form', 'input', 'button', 'textarea', 'select', 'noscript', 'svg',
    'template', 'math',
  ];

  /// 标签保留、但清掉所有属性的元素（属性在这里没有意义，只会夹带东西）。
  static const List<String> _stripAllAttributes = <String>[
    'html', 'body', 'head', 'center', 'font',
  ];

  /// 普通元素上允许保留的 `style` 属性白名单。
  ///
  /// `padding-left` 是段落缩进（`indent`）在 HTML 里的**唯一**载体：上游
  /// `parseStyleAttribute` 只认 `padding-left` / `padding-right`（映射到
  /// `indent`，16px = 1 级），没有别的写法。不放它就等于「编辑器里能缩进、
  /// 发出去也有缩进，但从别处粘回来就没了」。
  ///
  /// `text-align` 是段落对齐的载体（列表那一组不重要 —— 对齐落在段落上）。
  ///
  /// `color` / `background-color` / `font-size` 是批 B 加进来的
  /// （spec §3.2 明确改了原稿的「不做颜色」）。三个都是**值形状锚定**的
  /// —— 光认属性名不认值，`color:expression(...)` 那种老 IE 写法就进来了。
  ///
  /// 这几条只对**非单元格**元素生效；表格那两档见
  /// [_allowedTableStyleProps] / [_allowedTableCellStyleProps]。
  static const List<String> _allowedStyleProps = <String>[
    'text-align',
    'padding-left', // 批 A：段落缩进
    'color',
    'background-color',
    'font-size',
  ];

  /// `<table>` 额外允许的属性。
  ///
  /// 表格的骨架就靠这两条：`border-collapse:collapse` 决定有没有双线框，
  /// `width:100%` 决定铺不铺满。它们只对 `<table>` 有意义 —— 落在
  /// [_allowedStyleProps] 那一档会被整条削掉，`TableHtmlCodec.encode` 生成的
  /// 表格因此散架（单元格样式还在，但没有塌陷边框与整表宽度）。
  static const List<String> _allowedTableStyleProps = <String>[
    'border-collapse', 'width',
  ];

  /// 单元格额外允许的属性 —— 表格要能表达列宽与边框，否则粘进来就散架。
  static const List<String> _allowedTableCellStyleProps = <String>[
    'text-align', 'width', 'border', 'border-collapse', 'padding',
  ];

  /// 允许的属性 → 值必须完整匹配的形状。
  ///
  /// 用**值形状**白名单而不是「危险字符」黑名单：黑名单永远差一条，
  /// `url(`/`expression(`/`@import`/`behavior`/`-moz-binding` 逐个列是列不完的。
  /// 锚定到整串（`^...$`）之后，值里塞不进任何别的东西。
  static final Map<String, RegExp> _styleValuePatterns = <String, RegExp>{
    'text-align': RegExp(r'^(?:left|right|center|justify)$'),
    // **锚定到整串**，且只认 `px`：`em`/`rem`/`%`/`pt` 上游也能换算，但
    // 它们没有对应的 UI，放行只会让「同一个缩进有两种来源」。三个数字是
    // 上游 `parseToIndent` 夹取上限 5 级（80px）的余量。
    'padding-left': RegExp(r'^\d{1,3}px$'),
    // 只认小写六位十六进制。**不做转换**（`red` / `rgb()` 都不收）：
    // 转换等于自己实现一套 CSS 颜色解析，而导入端有一套夹取、
    // 导出端有一套生成，三边都做转换就一定有一边漏。
    'color': RegExp(r'^#[0-9a-f]{6}$'),
    'background-color': RegExp(r'^#[0-9a-f]{6}$'),
    // 1-3 位 px、不以 0 开头。上界 999px 而不是 100px：
    // 邮件里大标题用 22px 是有的，但 `1200px` 那种一定不是人写的。
    'font-size': RegExp(r'^[1-9]\d{0,2}px$'),
    'border-collapse': RegExp(r'^(?:collapse|separate)$'),
    'width': RegExp(r'^\d{1,4}(?:px|%)?$'),
    'padding': RegExp(r'^\d{1,3}(?:px|%)?(?:\s+\d{1,3}(?:px|%)?){0,3}$'),
    'border': RegExp(
      r'^\d{1,2}px\s+(?:solid|dashed|dotted)\s+'
      r'(?:#[0-9a-f]{3,8}|[a-z]{3,20}|rgb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\))$',
    ),
    'border-width': RegExp(r'^\d{1,2}px(?:\s+\d{1,2}px){0,3}$'),
    'border-style': RegExp(r'^(?:solid|dashed|dotted|none)$'),
    'border-color': RegExp(r'^(?:#[0-9a-f]{3,8}|[a-z]{3,20})$'),
  };

  /// 链接可以用的 scheme（`<a href>`）。
  static const Set<String> _allowedLinkSchemes = <String>{
    'http:', 'https:', 'mailto:', 'tel:', 'cid:',
  };

  /// 图片来源可以用的 scheme。
  static const Set<String> _allowedSrcSchemes = <String>{
    'http:', 'https:', 'cid:',
  };

  /// 内联图（`<img src="data:...">`）允许的**精确前缀**。
  ///
  /// 必须精确到分号，只认这几种光栅格式 —— 写 `data:image` 当判据会把
  /// `data:image/svg+xml`（SVG 能执行 JS）一起放行，那就是一个 XSS 洞。
  /// SVG 不是「粘贴进来的图片」，是「一段可执行的标记」。
  static const List<String> _allowedImageDataPrefixes = <String>[
    'data:image/png;',
    'data:image/jpeg;',
    'data:image/jpg;',
    'data:image/gif;',
    'data:image/webp;',
  ];

  /// 除 `href`/`src` 外还**带 URL** 的属性（与读信页 `sanitizeEmailHtml`
  /// 的载体集合对齐）。这些没有下游约定，非法就整个删掉。
  static const Set<String> _extraUrlCarriers = <String>{
    'action', 'formaction', 'xlink:href', 'poster', 'background', 'data',
  };

  /// 净化入口：不可信 HTML 一律走这里。
  ///
  /// **深度预检在最前面**：本方法（以及 [stripUnsafe] / [normalizeStyles]）都要
  /// 经过 `package:html` 的解析与递归序列化，深嵌套输入会先卡住几十秒再抛
  /// `StackOverflowError`。预检放在解析之前，超限就**降级成纯文本**
  /// （[HtmlDepthGuard.plainTextEscaped]，非递归），至少把内容还给用户而不是崩掉整页。
  /// 详见 [html_depth_guard.dart] 的类注释与 [HtmlDepthGuard.maxSafeDepth]。
  ///
  /// 预检只对**原始输入**做**一次**（`_stripUnsafe` / `_normalizeStyles` 不再
  /// 各自守卫）。这一点很关键：`_stripUnsafe` 的返回值是**解析并序列化之后**的
  /// HTML，`package:html` 补出的隐式 `<tbody>` / `<ul>` 会把深度抬到约 2 倍 ——
  /// 若在中间再守卫一次，一个输入深度 900（放行）的嵌套表格就会在第二道守卫处
  /// 数出 1200 层而被降级，整张表格丢光。见 email_html_sanitizer_test.dart 的
  /// 「嵌套表格不会被『解析后反而更深』误降级」。
  ///
  /// 正常输入（深度远低于 [HtmlDepthGuard.maxSafeDepth]）的输出**逐字节不变**：
  /// 预检只读字符串、只在超限时改变返回值，两条路径之间没有任何共用状态。
  static String toSafeSubset(String html) {
    if (html.trim().isEmpty) return '';
    if (HtmlDepthGuard.exceedsLimit(html)) return _degradeToPlainText(html);
    return _normalizeStyles(_stripUnsafe(html));
  }

  /// 删掉可执行内容与危险协议。
  ///
  /// 与 [toSafeSubset] 一样带深度预检（守的是**原始输入**）—— 它是 public API，
  /// 调用方可能绕过 [toSafeSubset] 直接用它。
  static String stripUnsafe(String html) {
    if (html.trim().isEmpty) return '';
    if (HtmlDepthGuard.exceedsLimit(html)) return _degradeToPlainText(html);
    return _stripUnsafe(html);
  }

  /// 去掉 `class`/`id`，把 `style` 压成白名单里那几项。
  ///
  /// **这个方法不负责安全。** 它只做「去 class/id + style 压白名单」，
  /// 不会删 `<script>`/`<iframe>`、不会清 `on*`、不会过滤危险协议 ——
  /// 对**不可信输入**直接调它等于什么都没做。
  ///
  /// 需要处理不可信 HTML 时**一律用 [toSafeSubset]**（它是 stripUnsafe + 本方法）。
  /// 本方法单独暴露只为了给已经净化过的内容做二次规整。
  ///
  /// 深度预检（守的是**原始输入**）与其余入口口径一致：它也是对外的 public API。
  static String normalizeStyles(String html) {
    if (html.trim().isEmpty) return '';
    if (HtmlDepthGuard.exceedsLimit(html)) return _degradeToPlainText(html);
    return _normalizeStyles(html);
  }

  /// [stripUnsafe] 的方法体（无深度守卫：守卫由 public 入口做一次）。
  static String _stripUnsafe(String html) {
    final dom.Document document = html_parser.parse(html);

    // 先删元素，再清属性 —— 顺序不能反：删元素时属性还在，攻击者没法靠
    // 「先把属性挪走」躲过第一步。
    for (final tag in _dropWithContent) {
      for (final element in document.querySelectorAll(tag).toList()) {
        element.remove();
      }
    }
    for (final tag in _stripAllAttributes) {
      for (final element in document.querySelectorAll(tag).toList()) {
        element.attributes.clear();
      }
    }

    for (final element in document.querySelectorAll('*')) {
      final isImageElement = element.localName?.toLowerCase() == 'img';
      // 先快照 key 的列表再改 —— 边遍历边删会抛并发修改。
      // `attributes` 的 key 类型是 `Object`（字符串名或 `AttributeName`），
      // 不要试图把它塞进 `Map<AttributeName, String>`，运行时会炸。
      for (final key in element.attributes.keys.toList()) {
        final name = key.toString().toLowerCase();
        final value = element.attributes[key] ?? '';
        if (name.startsWith('on')) {
          element.attributes.remove(key);
        } else if (name == 'href' || name == 'src') {
          // 只有 `img` 的 `src` 是「图片源」，额外享受光栅 `data:` 前缀；
          // 其余 `src` 仍按「源」这一类的 scheme 白名单判定。
          final isImageSource = isImageElement && name == 'src';
          // 顺序：先规范化（清控制字符）再判断放行、并把规范化后的值写回。
          // 判断用同一个值，不存在「判定看的是 A、落地写的是 B」的缝隙。
          final cleaned = _cleanUrlForStorage(value);
          if (!_isAllowedUrl(cleaned, isImageSource: isImageSource)) {
            // 现状约定：`href`/`src` 不合法时替换成 `'#'`（下游
            // `MailHtmlToDelta` 就是这么处理 `'#'` 的）。
            element.attributes[key] = '#';
          } else if (cleaned != value) {
            element.attributes[key] = cleaned;
          }
        } else if (name == 'srcset') {
          // `srcset` 是逗号分隔的「URL + 描述符」列表，逐条判定；
          // 只要有一条不合法，整个属性删掉。
          if (!_isAllowedSrcset(value)) {
            element.attributes.remove(key);
          }
        } else if (_extraUrlCarriers.contains(name)) {
          // 这些载体没有 `'#'` 这种下游约定，改成 `'#'` 反而会造出一个
          // 会发请求的 `src` —— 非法就直接整个属性删掉。
          if (!_isAllowedUrl(value, isImageSource: _isSourceCarrier(name))) {
            element.attributes.remove(key);
          }
        }
      }
    }
    return _unwrapBody(document);
  }

  /// [normalizeStyles] 的方法体（无深度守卫：守卫由 public 入口做一次）。
  static String _normalizeStyles(String html) {
    final dom.Document document = html_parser.parse(html);
    for (final element in document.querySelectorAll('*')) {
      element.attributes.remove('class');
      element.attributes.remove('id');
      final style = element.attributes['style'];
      if (style == null) continue;
      final allowed = _stylePropsFor(element);
      final kept = _filterStyle(style, allowed);
      if (kept.isEmpty) {
        element.attributes.remove('style');
      } else {
        element.attributes['style'] = kept;
      }
    }
    return _unwrapBody(document);
  }

  /// 元素该用哪一档 `style` 白名单。
  ///
  /// 三档：单元格（最宽，列宽/边框/内边距）、`<table>`（塌陷边框 + 整表宽度）、
  /// 其余（只有 `text-align`）。注意 `<table>` 的 `width` 必须落在这一档：
  /// 表格本体的列宽由各单元格自己的 `width` 表达，`<table>` 上的 `width` 是
  /// 「整表铺满比例」，两者语义不同，不能混。
  static List<String> _stylePropsFor(dom.Element element) {
    final tag = element.localName?.toLowerCase();
    if (tag == 'td' || tag == 'th') return _allowedTableCellStyleProps;
    if (tag == 'table') return _allowedTableStyleProps;
    return _allowedStyleProps;
  }

  /// URL 载体的规范化：trim，去掉**所有空白与控制字符**。
  ///
  /// 控制字符必须单独去掉：Dart 的 `\s` 不匹配 `\u0000`，`java\u0000script:`
  /// 这种 NUL 走私会被「方案名里夹了个看不见的字符」绕过。
  ///
  /// 顺序是**先规范化再判断是否放行**。浏览器对 URL 里的 NUL 是替换成 U+FFFD
  /// （而不是删除），所以「删除」是我们自己的规范化，方向必须先做：
  /// `mail\0to:` 剥离后是白名单里的 `mailto:` → 放行；反过来先判断再规范化，
  /// 就会把一个合法链接当未知 scheme 误杀。判断与写回都用这个函数的输出，
  /// 保证「判定看到的值」和「最后落地的值」是同一个。
  static String _cleanUrlForStorage(String value) => value
      .trim()
      .replaceAll(RegExp(r'[\s\u0000-\u001F\u007F]'), '');

  /// `href`/`src` 等 URL 载体是否允许。
  ///
  /// 白名单而不是黑名单：只放行明确的几种 scheme（外加光栅 `data:` 前缀），
  /// 其余（`javascript:`/`vbscript:`/`file:`/`blob:`/`data:image/svg+xml`
  /// /`data:application/xhtml+xml`…）一律拒绝。
  ///
  /// [isImageSource] 为真时用的是「图片源」白名单 —— 只有 `img` 的 `src`
  /// 才会命中（见调用点），所以 `data:` 前缀只对图片放开。
  static bool _isAllowedUrl(String value, {required bool isImageSource}) {
    // 归一化与「写回时用的规范化」是同一个函数，判断与落地不会走偏。
    final normalized = _cleanUrlForStorage(value).toLowerCase();
    if (normalized.isEmpty) return false;
    // 锚点 / 根相对 / 查询串。
    if (normalized.startsWith('#') ||
        normalized.startsWith('/') ||
        normalized.startsWith('?')) {
      return true;
    }
    final colon = normalized.indexOf(':');
    // 没有 `:` → 相对路径（`a.png`、`../b/c.png`）。
    if (colon < 0) return true;
    // `:` 之前含 `/` → 那不是 scheme（`a/b:c`）。
    if (normalized.substring(0, colon).contains('/')) return true;
    if (isImageSource) {
      // 精确到分号的光栅 `data:` 前缀；`data:image/svg+xml` 不在内。
      for (final prefix in _allowedImageDataPrefixes) {
        if (normalized.startsWith(prefix)) return true;
      }
    }
    final scheme = '${normalized.substring(0, colon)}:';
    final allowed = isImageSource ? _allowedSrcSchemes : _allowedLinkSchemes;
    return allowed.contains(scheme);
  }

  /// `srcset="a.png 1x, b.png 2x"` → 逐条判定 `srcset` 里的每个 URL。
  ///
  /// `srcset` 的每一项形如 `url descriptor`，取第一段空白前的部分当 URL；
  /// 任一项不合法就整体拒绝（调用方会删掉整个 `srcset`）。
  static bool _isAllowedSrcset(String value) {
    final entries = value.split(',');
    for (final entry in entries) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) continue;
      final url = trimmed.split(RegExp(r'\s')).first;
      if (!_isAllowedUrl(url, isImageSource: true)) return false;
    }
    return true;
  }

  /// 该载体是不是「图片源」类（享受光栅 `data:` 前缀）。
  ///
  /// 目前只有 `poster`/`background`/`data` 这几项算图片源；`action`/
  /// `formaction` 是表单动作，绝不接受 `data:`。
  static bool _isSourceCarrier(String name) =>
      name == 'poster' || name == 'background' || name == 'data';

  /// `color:red;text-align:center` + 白名单 → `text-align:center`。
  ///
  /// 属性名与值都 trim；值是**双重匹配**：先看属性名在允许集里，再看值完整
  /// 匹配 `_styleValuePatterns` 里对应的形状（`^...$` 锚定）—— 只认名字不认
  /// 值，就会把 `width:url(javascript:alert(1))` 这种原样放过去。
  ///
  /// 值里若出现 `}`/`<`/`>` 说明有人在试探 `style` 外的注入，整条丢掉
  /// （`<style>` 已被删，这里是第二道）。
  static String _filterStyle(String style, List<String> allowed) {
    final kept = <String>[];
    for (final declaration in style.split(';')) {
      final colon = declaration.indexOf(':');
      if (colon <= 0) continue;
      final property = declaration.substring(0, colon).trim().toLowerCase();
      final value = declaration.substring(colon + 1).trim();
      if (property.isEmpty || value.isEmpty) continue;
      if (!allowed.contains(property)) continue;
      if (value.contains('}') || value.contains('<') || value.contains('>')) {
        continue;
      }
      final pattern = _styleValuePatterns[property];
      if (pattern == null || !pattern.hasMatch(value.toLowerCase())) {
        continue;
      }
      kept.add('$property:$value');
    }
    return kept.join(';');
  }

  /// `parse()` 总会补出 `<html><head><body>`；交回给调用方时只保留 body 内部。
  static String _unwrapBody(dom.Document document) {
    final body = document.body;
    if (body != null) return body.innerHtml;
    return document.documentElement?.innerHtml ?? '';
  }

  /// 深度超限时的降级输出：**转义过的纯文本**，块边界落成换行。
  ///
  /// 直接委托给 [HtmlDepthGuard.plainTextEscaped]（转义逻辑只有一份）。为什么
  /// 要转义：返回值会被另一个会解析 HTML 的下游再解析一遍 —— 写侧是
  /// `MailHtmlToDelta`，读侧是 `mail_detail/html_body_view.dart` 的
  /// `sanitizeEmailHtml`（它把降级串交给 `flutter_widget_from_html_core`）。若
  /// 返回裸文字，邮件里的 `<img onerror=…>`、`<script>` 会**借降级路径复活执行**
  /// —— 深嵌套本来是拒绝服务，改成 XSS 就是把事办反了。转义后不可能再被解析成
  /// 标签，两个调用方都安全。
  static String _degradeToPlainText(String html) =>
      HtmlDepthGuard.plainTextEscaped(html);
}
