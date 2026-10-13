import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:fwfh_cached_network_image/fwfh_cached_network_image.dart';
import 'package:fwfh_url_launcher/fwfh_url_launcher.dart';
import 'package:html/parser.dart' as html_parser;

import '../../core/theme/app_theme.dart';
import '../../core/util/url_utils.dart';
import '../compose/html/html_depth_guard.dart';

/// `package:html` 的 DOM 类型全部走 `dom` 前缀。
///
/// 必须加前缀：`package:flutter/material.dart` 也导出 `Element`（widget 的
/// `Element`），裸写 `Element` 会被解析成 Flutter 那个，然后
/// `element.localName` 这类调用就全成了「未定义」。
import 'package:html/dom.dart' as dom;

/// 邮件正文渲染。
///
/// 做三件事，每件都对应 worker 的一个已知行为：
/// 1. **替换 `{{domain}}`**：`email.content` 里内嵌图的地址是**字面量占位符**
///    （worker 的 `emailService.imgReplace` 写进去的），必须在这里换成
///    OSS 前缀。**只替换这一份渲染用的副本，绝不写回本地缓存的 `content`** ——
///    实例日后配了 `r2Domain` 时要能自动切到 CDN 前缀。
/// 2. **净化**：去掉 `<script>`/`<iframe>`/`<object>`/`<embed>`/`<link>`/`<meta>`
///    与 `on*` 事件属性、`javascript:` 链接。邮件是不可信输入。
/// 3. **补默认样式**：`fwfh_core` **不解析 `<style>` 标签**（它把 style/script
///    都当 `display:none` 丢掉），所以营销邮件里那套 CSS 全部失效，字号会退回
///    默认值。这里把 `mail-vue` 的 shadow-html 默认样式用
///    `customStylesBuilder` 补回去，并尽量把 `<body style="...">` 里能被支持的
///    几项（字号 / 行高 / 颜色）提到外层 —— 与 Web 端「把 body 的 style 注入
///    到容器」的做法对齐。
///
/// 已知的保真度上限（见计划的「风险 2」）：媒体查询、grid、`@font-face`
/// 一律不支持，复杂营销邮件会比 Web 端差。详情页的「用浏览器打开」是退路。
/// `display:flex` 是**半支持**：布局能出来、不再溢出，但 `justify-content:
/// center/flex-end` 会偏一点（原因见 `_MailWidgetFactory.buildFlex`）。
/// `float` 也不支持，被降级成 `inline-block`（原因见 `_customStyles`）——
/// 能排成一行、不再溢出，但没有真浮动的「后续内容绕排」。
class HtmlBodyView extends StatefulWidget {
  const HtmlBodyView({
    super.key,
    required this.html,
    required this.ossBase,
    this.onTapImage,
    this.shrinkWrap = false,
  });

  /// 原始 HTML（**未替换 `{{domain}}`**）。
  final String html;

  /// 附件/内嵌图前缀，来自 `Profile.ossBase` 或 `ConfigRepository`。
  final String ossBase;

  /// 点内嵌图（应用内预览）。
  final void Function(String url)? onTapImage;

  /// 是否按内容高度自适应（详情页 true；列表里的预览 false）。
  final bool shrinkWrap;

  @override
  State<HtmlBodyView> createState() => _HtmlBodyViewState();
}

class _HtmlBodyViewState extends State<HtmlBodyView> {
  late String _prepared;
  EmailBodyStyle _bodyStyle = const EmailBodyStyle();

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(HtmlBodyView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ossBase 变了也要重算：实例后来配了 r2Domain 时前缀要跟着换。
    if (oldWidget.html != widget.html || oldWidget.ossBase != widget.ossBase) {
      _prepare();
    }
  }

  void _prepare() {
    final substituted =
        UrlUtils.substituteDomainToken(widget.html, widget.ossBase);
    final parsed = sanitizeEmailHtml(substituted);
    _prepared = parsed.html;
    _bodyStyle = parsed.bodyStyle;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium ?? const TextStyle();
    final textStyle = base.copyWith(
      fontSize: _bodyStyle.fontSize ?? 14,
      height: _bodyStyle.lineHeight ?? 1.5,
      color: _bodyStyle.color ?? theme.colorScheme.onSurface,
    );

    final html = _prepared.trim();
    if (html.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          '（这封邮件没有正文）',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    return HtmlWidget(
      html,
      // 让相对地址（老实例里可能存的是 `/attachments/x.png`）能解析。
      baseUrl: Uri.tryParse(widget.ossBase),
      textStyle: textStyle,
      factoryBuilder: () => _MailWidgetFactory(),
      // 大正文（>10KB）交给 async build，避免一帧里构建上千个 widget 卡住。
      buildAsync: html.length > 20000,
      renderMode: RenderMode.column,
      customStylesBuilder: (element) => _customStyles(element, theme),
      onTapImage: widget.onTapImage == null
          ? null
          : (meta) {
              final url = meta.sources.isNotEmpty ? meta.sources.first.url : '';
              if (url.isNotEmpty) widget.onTapImage!(url);
            },
      onTapUrl: (url) => _onTapUrl(context, url),
    );
  }

  /// `style="... float: left ..."`。
  ///
  /// 只看**行内 style 属性**，不看 `customStylesBuilder` 自己发出去的声明 ——
  /// 后者是本函数拼的，拿来判「原本有没有 float」会自咬。
  static final _floatDeclaration =
      RegExp(r'\bfloat\s*:\s*(?:left|right)', caseSensitive: false);

  /// 把 Web 端 shadow-html 的默认样式翻译成 fwfh 认识的 CSS 声明。
  ///
  /// 只处理能生效的几项，**不写 fwfh 不支持的东西**（媒体查询、grid），
  /// 那些会被静默忽略 —— 写了也只是噪声。
  /// 唯一的例外是 `float`：它本身也不被支持，但会被改写成
  /// `inline-block` 顶上（见下）。
  static Map<String, String>? _customStyles(
    dom.Element element,
    ThemeData theme,
  ) {
    final styles = <String, String>{};
    switch (element.localName) {
      case 'img':
        // 对齐 Web 端 `img:not(table img){max-width:100%;height:auto!important}`
        // 里能生效的部分。`height:auto!important` 在 fwfh 里靠不指定高度实现。
        styles['max-width'] = '100%';
      case 'a':
        styles['color'] =
            '#${AppTheme.bodyLink.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
        styles['text-decoration'] = 'none';
      case 'p':
        // Web 端显式 `p{margin:0}` —— 很多营销邮件用空 <p> 控制行距。
        styles['margin'] = '0';
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
        styles['font-size'] = '18px';
        styles['font-weight'] = '700';
      case 'table':
        // 邮件里大量用 table 布局；fwfh 的默认表格边框在深色主题下很难看。
        styles['border-collapse'] = 'collapse';
    }

    final rawStyle = element.attributes['style'];
    if (rawStyle != null && _floatDeclaration.hasMatch(rawStyle)) {
      // `float` 不被支持，退化成**块级**（一人一行）。带 `height` 的窄条
      // （火山引擎页脚那种 `height:32px;padding-top:16px`）孩子堆起来比固定
      // 高度高，普通 `RenderFlex` 就在底部裁掉几个像素，调试态是黄黑斜条。
      // 补成 `inline-block` 至少把它们掰回文档流、排在一行里。
      //
      // 另一条 `vertical-align: middle` 不是审美要求，是绕 fwfh 的一个坑：
      // 默认的 `baseline` 会让 fwfh 把孩子当成 inline placeholder，走
      // `RenderImage.computeDryBaseline` 取基线，而 fwfh 自己的
      // `_RenderCssSizing` 在 dry baseline 里读了实参布局后的 `size` ——
      // 只要那个 float 里裹着 `<img>`（页脚 logo 就是），就撞
      // `renderBoxDoingDryBaseline == null` 断言、整封正文渲染失败。
      // `vertical-align` 非 baseline 时 fwfh 改走 `PlaceholderAlignment`
      // （见 `internal/ops/style_vertical_align.dart`），根本不取基线。
      // 顺带一提这跟混排位置也更准 —— 浏览器里 float 本来就是块级，不参与基线。
      styles['display'] = 'inline-block';
      styles['vertical-align'] = 'middle';
    }

    return styles.isEmpty ? null : styles;
  }

  Future<bool> _onTapUrl(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return true;
    // 只放行 http/https/mailto/tel，其他（file://、intent://、自定义 scheme）
    // 一律拦下 —— 邮件正文是不可信输入，不该让它去唤起任意 handler。
    const allowed = <String>{'http', 'https', 'mailto', 'tel'};
    if (!allowed.contains(uri.scheme)) {
      _toast(context, '已拦截不安全的链接：${uri.scheme}');
      return true;
    }
    return false; // 交给 UrlLauncherFactory 打开外部浏览器。
  }

  void _toast(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 正文用的 widget factory：图片走 `cached_network_image`（带磁盘缓存），
/// 链接走 `url_launcher`。两者都以 mixin 的形式挂在核心 factory 上。
///
/// 另外在这里给 `display:flex` 补一条「能收缩」—— 见 [buildFlex]。
class _MailWidgetFactory extends WidgetFactory
    with CachedNetworkImageFactory, UrlLauncherFactory {
  /// 横向 flex 的每个孩子包一层 `Flexible(fit: loose)`。
  ///
  /// ## 不补这一层会怎样
  ///
  /// `fwfh_core` 对 flex 的支持**只有 `display:flex` 本身**
  /// （`internal/ops/style_display_flex.dart`）：`flex-grow` / `flex-shrink` /
  /// `flex-basis` / `flex-wrap` 一个都不认（`internal/core_ops.dart` 里没有
  /// 这些常量，`getStyle('flex')` 在树上也取不到值 —— 不认识的声明会被丢掉），
  /// 孩子一律按**自然尺寸**排在一行里（`widgets/html_flex.dart` 的
  /// `_constraintsForNonFlexChild` 在横向时只给 `maxHeight`，主轴不限宽）。
  /// `_computeSizes` 里确实有一条补偿：**单个**孩子比容器还宽时会把它改成
  /// flex；但它只看孩子自己，不看**总宽**，所以两个孩子各 300px 撑在
  /// 400px 的容器里照样溢出。
  ///
  /// 于是任何「孩子总宽 > 容器宽」的行都会溢出，调试态就是那条黄黑斜条
  /// （`renderOverflowIndicator`，`RenderHtmlFlex.paint`）。
  /// 营销邮件里两栏 300px、600px 宽的按钮行遍地都是 —— 这就是
  /// 「有些邮件内容带斜条」的**唯一**来源，与表格、图片无关：表格在
  /// 宽度有限时会被 `tag_table.dart` 套上横向滚动，图片走
  /// `customStylesBuilder` 里的 `max-width:100%`，两者都不溢出。
  ///
  /// ## 为什么是 `loose` 而不是 `Expanded`/`tight`
  ///
  /// `tight` 会把**恰好放得下**的行也改成等宽（16px 的图标被撑成容器的一半）。
  /// `loose` 让份额成为上限：小图标仍是 16px，只有「按自然尺寸放不下」的
  /// 孩子才被压到份额以内折行。
  ///
  /// ## 已知代价（比浏览器差一点，但不会再溢出）
  ///
  /// Flutter 的 Flex 没有「只缩不伸」，孩子**会伸到均分到的份额**，所以
  /// `<div style="width:40px">图标</div><div>短文案</div>` 里那段文案会占满
  /// 半行。`justify-content` 是默认值或 `space-between` 时看不出来
  /// （文案左对齐、右侧那个仍顶到边），只有 `center` / `flex-end` 会整体
  /// 偏一点。要完全对齐浏览器得自己按 `flex-grow` 逐个算份额 —— 而
  /// `getStyle('flex')` 在树上取不到值（fwfh 会把不认识的属性丢掉），
  /// 不值得为这点差异去抠。
  @override
  Widget? buildFlex(
    BuildTree tree,
    List<Widget> children, {
    CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.center,
    required Axis direction,
    MainAxisAlignment mainAxisAlignment = MainAxisAlignment.start,
    double spacing = 0.0,
    TextBaseline textBaseline = TextBaseline.alphabetic,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    // 纵向 flex 不受影响：主轴是高度，没有「孩子太宽」这回事。
    final kids = direction == Axis.horizontal
        ? <Widget>[
            for (final child in children)
              Flexible(fit: FlexFit.loose, child: child),
          ]
        : children;
    return super.buildFlex(
      tree,
      kids,
      crossAxisAlignment: crossAxisAlignment,
      direction: direction,
      mainAxisAlignment: mainAxisAlignment,
      spacing: spacing,
      textBaseline: textBaseline,
      textDirection: textDirection,
    );
  }
}

/// 净化后的正文 + 从 `<body style>` 里抠出来的几项样式。
class SanitizedHtml {
  const SanitizedHtml(this.html, this.bodyStyle);

  final String html;
  final EmailBodyStyle bodyStyle;
}

/// 能生效的 body 样式（其余属性 fwfh 本来就不支持，不必假装提取）。
class EmailBodyStyle {
  const EmailBodyStyle({this.fontSize, this.lineHeight, this.color});

  final double? fontSize;
  final double? lineHeight;
  final Color? color;
}

/// 去掉危险标签与属性。
///
/// 用 `package:html` 而不是正则：正则在嵌套引号、大小写、注释里的标签上
/// 会漏，而这里处理的是**不可信输入**，漏一个就等于没做。
///
/// **解析前先过 [HtmlDepthGuard]**：`parseFragment` 是按深度递归的，深嵌套
/// 正文（实测 2 万层约 6.9 秒）会先卡死再爆栈。超限就直接返回转义纯文本，
/// 不解析。
SanitizedHtml sanitizeEmailHtml(String html) {
  if (html.trim().isEmpty) {
    return const SanitizedHtml('', EmailBodyStyle());
  }

  // 深度超限 → 不解析，直接给一段**转义过的纯文本**。
  // 为什么必须转义：这个字符串会被 `flutter_widget_from_html_core` 再解析
  // 一遍，返回裸文字等于把 DoS 换成 XSS（邮件里 `<img onerror=…>` 会借道复活）。
  // 这一步必须**早于任何 parseFragment** —— 深嵌套输入（实测 2 万层约 6.9s）
  // 正是解析本身卡住的地方。
  if (HtmlDepthGuard.exceedsLimit(html)) {
    return SanitizedHtml(
      HtmlDepthGuard.plainTextEscaped(html),
      _parseBodyStyle(_extractBodyStyle(html)), // _extractBodyStyle 是正则，不走解析
    );
  }

  // `<body>` 的样式要在解析**之前**抠出来：fragment 解析会直接忽略
  // `<body>` 标签（HTML5 的 in-body 插入模式），解析完就找不到了。
  final bodyStyle = _parseBodyStyle(_extractBodyStyle(html));

  // 去掉 html/body 外壳标签本身，保留内容 —— 对齐 Web 端的
  // `replace(/<\/?body[^>]*>/gi, '')`。
  final stripped = html
      .replaceAll(RegExp(r'</?body[^>]*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'</?html[^>]*>', caseSensitive: false), '');

  final fragment = html_parser.parseFragment(stripped);

  for (final element in fragment.querySelectorAll(
    'script, iframe, object, embed, link, meta, base, form',
  )) {
    element.remove();
  }

  for (final element in fragment.querySelectorAll('*')) {
    final doomed = <String>[];
    for (final entry in element.attributes.entries) {
      final name = entry.key.toString();
      // `on*` 事件属性：HTML 解析器不会执行它们，但把 `onclick="alert(1)"`
      // 原样留在 tree 里迟早有人踩到。
      if (name.toLowerCase().startsWith('on')) {
        doomed.add(name);
        continue;
      }
      // `javascript:` / `vbscript:` 链接。
      if (name == 'href' ||
          name == 'src' ||
          name == 'action' ||
          name == 'formaction') {
        final lower = entry.value.trim().toLowerCase();
        if (lower.startsWith('javascript:') || lower.startsWith('vbscript:')) {
          doomed.add(name);
        }
      }
    }
    if (doomed.isEmpty) continue;
    for (final name in doomed) {
      element.attributes.remove(name);
    }
  }

  // `outerHtml` 挂在 `Node` 的**私有** getter 上（`_outerHtml`），公开的只有
  // `Element` / `Document` / `DocumentFragment` 三处，所以文本与注释节点
  // 只能自己拼。
  final nodes = fragment.nodes.toList(growable: false);
  final out = StringBuffer();
  for (final node in nodes) {
    switch (node) {
      case dom.Element():
        out.write(node.outerHtml);
      case dom.Text():
        // 用 `data`（原文）而不是 `text`：`text` 是 `data` 的别名，
        // 但 `Text.data` 保留着 `&lt;` 这样的原始转义，拼回去才不会
        // 把一段文本变成真标签。
        out.write(node.data);
      case dom.Comment():
        // 注释里可能藏着条件注释（`<!--[if mso]>`）或索性是半个标签，
        // 丢掉最省事 —— 正文里没有一条注释值得为它冒解析风险。
        break;
      default:
        out.write(node.text ?? '');
    }
  }

  return SanitizedHtml(out.toString(), bodyStyle);
}

/// 从整篇 HTML 里找出 `<body ...>` 的 `style` 属性值。
String? _extractBodyStyle(String html) {
  final match = RegExp(
    r'<body\b[^>]*?\bstyle\s*=\s*"([^"]*)"',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html);
  if (match != null) return match.group(1);
  // 属性也可能是单引号。
  final single = RegExp(
    r"<body\b[^>]*?\bstyle\s*=\s*'([^']*)'",
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html);
  return single?.group(1);
}

/// 从 `<body style="...">` 里抠出 fwfh 支持得了的几项。
///
/// 不引 `csslib`：为了三个属性去处理它的 AST 不值得，而且声明里出现
/// fwfh 不认的值时抛异常反而更糟。
EmailBodyStyle _parseBodyStyle(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const EmailBodyStyle();
  final declarations = _parseDeclarations(raw);
  return EmailBodyStyle(
    fontSize: _px(declarations['font-size']),
    lineHeight: _number(declarations['line-height']),
    color: _color(declarations['color']),
  );
}

/// `font-size: 15px` → 15。带单位的百分比 / em 一律放弃（换算不可靠）。
double? _px(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^\s*([\d.]+)\s*px\s*$').firstMatch(value);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

double? _number(String? value) {
  if (value == null) return null;
  return double.tryParse(value.trim());
}

Color? _color(String? value) {
  if (value == null) return null;
  final text = value.trim().toLowerCase();
  if (text.startsWith('#')) {
    var hex = text.substring(1);
    if (hex.length == 3) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      return value == null ? null : Color(0xFF000000 | value);
    }
    return null;
  }
  final rgb = RegExp(r'^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)')
      .firstMatch(text);
  if (rgb != null) {
    return Color.fromARGB(
      255,
      int.parse(rgb.group(1)!),
      int.parse(rgb.group(2)!),
      int.parse(rgb.group(3)!),
    );
  }
  // 具名颜色交给 Theme（body 上的 color 本来就是少数派）。
  return null;
}

/// `style="a:b;c:d"` → `{a: b, c: d}`。
Map<String, String> _parseDeclarations(String raw) {
  final out = <String, String>{};
  for (final part in raw.split(';')) {
    final index = part.indexOf(':');
    if (index <= 0) continue;
    final key = part.substring(0, index).trim().toLowerCase();
    final value = part.substring(index + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    out[key] = value;
  }
  return out;
}
