import 'package:html/dom.dart' as dom;

/// 邮件正文 `<style>` 样式表 → 每个元素最终生效的 `display`。
///
/// ## 为什么需要它
///
/// 正文渲染器是 `flutter_widget_from_html_core`，它**不解析 `<style>`**
/// （只把 `<style>` 标签本身按 `display:none` 丢掉）。于是营销邮件里那套
/// 「手机版 / 桌面版二选一」的规则全部失效：同一段头部内容在邮件里写了
/// 两遍，靠 `.m7{display:none}` 藏掉手机版，浏览器只画一份，我们两份都画
/// —— 用户看到「Apple Apple」「iPad mini iPad mini」（真实案例见
/// `test/html_body_view_style_cascade_test.dart`）。
///
/// 这里补的是一层**只算 `display` 的最小级联**：解析 `<style>`，按浏览器
/// 的规则算出每个元素最终 `display`，由 `html_body_view.dart` 通过
/// `customStylesBuilder` 喂给 fwfh。v1 刻意只做 `display`：颜色、字号、
/// 边距等留给后续版本，免得一次引入大片视觉回归。能「多画 / 重画 / 叠画」
/// 的只有 display，先把它修掉。
///
/// ## 已知上限（刻意接受，不在这里做）
///
/// 1. **媒体查询按固定「桌面视口」求值**：宽 800 逻辑 px、`screen`、
///    `prefers-color-scheme: light`。窄窗口（<481px）本来也渲染不出手机版
///    布局（fwfh 不支持媒体查询重排），保持桌面版是正确降级。
/// 2. **只认 `display` 一条声明**，其它属性原样忽略。
/// 3. **样式表的 `!important` 压不过行内 `style`**：fwfh 的
///    `core_build_tree.dart` 先 `addAll` custom styles 再 `addAll` 行内
///    style，行内永远后到。这等价于浏览器里「行内非 important > 样式表
///    非 important」，但「样式表 `!important` > 行内」这一条做不到。绝大多数
///    邮件不依赖它；真撞上了只影响布局细节，不会重新画出重复内容。
/// 4. 带伪类（`:hover` / `:focus` / `:link` / `::before` …）、属性选择器、
///    `+` / `~` 兄弟组合子的选择器**整条跳过**：静态渲染没有对应状态/语义，
///    强行当成「命中」只会误藏内容。
/// 5. 不认识的媒体特性（`min-resolution`、`orientation`、范围语法 …）→
///    该 `@media` 块**不应用**。宁可不应用，也不误藏内容。
///
/// ## 安全与性能
///
/// 邮件是不可信输入：解析全程手工、不引依赖、不抛异常（解析是迭代的，
/// 只有 `@media` 与选择器匹配两处递归，深度都有上限）。`parse` 每封邮件
/// 一次；`displayFor` 每个元素一次，所以规则在 parse 阶段就被过滤成
/// 「只含 display 的规则」并按 class / id / tag 建倒排索引，匹配时先查索引、
/// 再比「右端复合选择器」的便宜条件，最后才走祖先链。
class EmailCss {
  /// 空样式表：没命中任何规则。常用作默认值。
  const EmailCss.empty()
      : _rules = const <_Rule>[],
        _freeRules = const <int>[],
        _byClass = const <String, List<int>>{},
        _byId = const <String, List<int>>{},
        _byTag = const <String, List<int>>{},
        _visited = const <int>[0],
        _classCache = const <dom.Element, Set<String>>{};

  /// 字段顺序与声明顺序一致，调用点见 [_build]。
  const EmailCss._(
    this._rules,
    this._freeRules,
    this._byClass,
    this._byId,
    this._byTag,
    this._visited,
    this._classCache,
  );

  /// 解析整篇 HTML 里所有 `<style>` 块。**绝不抛异常**（不可信输入）。
  ///
  /// 注意：这里解析的是**净化前**的 HTML 文本（`_prepare` 里与
  /// `scanExternalResources` 用同一份副本）。净化本身不动 `<style>`，两边等价。
  factory EmailCss.parse(String html) {
    try {
      final rules = <_Rule>[];
      for (final match in _styleBlockPattern.allMatches(html)) {
        var css = match.group(1) ?? '';
        if (css.length > _maxStyleBlockLength) {
          // 单块样式表过长时截断：继续解析只会在 UI 线程上白烧时间。
          css = css.substring(0, _maxStyleBlockLength);
        }
        css = _stripComments(css)
            .replaceAll('<!--', '')
            .replaceAll('-->', '');
        if (css.trim().isEmpty) continue;
        _SheetParser(rules).parse(css, 0);
        if (rules.length >= _maxRules) break;
      }
      if (rules.isEmpty) return const EmailCss.empty();
      return EmailCss._build(rules);
    } catch (_) {
      // 兜底：任何意外（空指针、越界）都退化成「没有样式表」。
      // 少藏点内容比让整封正文渲染失败好得多。
      return const EmailCss.empty();
    }
  }

  /// 规则按「只含 display」过滤后的顺序表；**列表下标就是文档顺序**，
  /// 级联里「后者胜」直接比下标（多条 `<style>` 块的先后也保持不变）。
  final List<_Rule> _rules;

  /// 右端复合选择器里既没 class / id、也没标签的规则（`*`、空选择器除外）。
  final List<int> _freeRules;

  /// 右端复合选择器要求某个 class 的规则（一个 class 一批）。
  final Map<String, List<int>> _byClass;

  /// 右端复合选择器要求某个 id 的规则。
  final Map<String, List<int>> _byId;

  /// 右端复合选择器要求某个标签的规则。
  final Map<String, List<int>> _byTag;

  /// 每规则的「本次调用是否已评估」戳。`_visited[0]` 是当前戳，一是省掉
  /// 每个元素重新分配一个 Set，二是避免同一规则因多个 class 命中被算两遍。
  final List<int> _visited;

  /// `element.className` 拆成集合的缓存。祖先会被大量孩子反复匹配，缓存能
  /// 省掉成吨的 `split` 分配；有上限，防长期停留时无限长。
  final Map<dom.Element, Set<String>> _classCache;

  /// 该元素命中样式表时的最终 `display`（`none` / `block` / …）；没命中返回 null。
  ///
  /// 返回值可以直接塞进 `customStylesBuilder` 返回的 map。
  String? displayFor(dom.Element element) {
    if (_rules.isEmpty) return null;

    if (_classCache.length > _maxClassCacheEntries) _classCache.clear();
    final visited = _visited;
    final stamp = ++visited[0];
    final budget = _MatchBudget(_matchBudgetPerElement);

    var bestIndex = -1;
    var bestIds = 0;
    var bestClasses = 0;
    var bestTags = 0;

    void consider(int index) {
      final slot = index + 1;
      if (visited[slot] == stamp) return;
      visited[slot] = stamp;

      final rule = _rules[index];
      _Selector? matched;
      for (final selector in rule.selectors) {
        if (matched != null && selector.specificity <= matched.specificity) {
          // 同一规则里已经有一条更高权重的选择器命中，display 相同，
          // 不必再拿它去和祖先链较劲。
          continue;
        }
        if (!selector.matches(element, _classCache, budget)) continue;
        matched = selector;
      }
      if (matched == null) return;

      if (bestIndex >= 0) {
        final current = _rules[bestIndex];
        final bool better;
        if (rule.important != current.important) {
          better = rule.important;
        } else if (matched.ids != bestIds) {
          better = matched.ids > bestIds;
        } else if (matched.classes != bestClasses) {
          better = matched.classes > bestClasses;
        } else if (matched.tags != bestTags) {
          better = matched.tags > bestTags;
        } else {
          better = index > bestIndex;
        }
        if (!better) return;
      }

      bestIndex = index;
      bestIds = matched.ids;
      bestClasses = matched.classes;
      bestTags = matched.tags;
    }

    // 候选规则：先便宜的索引，再 free（`*`、纯标签规则兜底在别的索引里，
    // 这里 free 只放「右端什么条件都没有」的规则）。
    for (final index in _freeRules) {
      consider(index);
    }
    final tag = element.localName;
    if (tag != null) {
      final byTag = _byTag[tag];
      if (byTag != null) {
        for (final index in byTag) {
          consider(index);
        }
      }
    }
    final id = element.attributes['id'];
    if (id != null) {
      final byId = _byId[id];
      if (byId != null) {
        for (final index in byId) {
          consider(index);
        }
      }
    }
    final classes = _classesOf(element);
    if (classes.isNotEmpty) {
      for (final name in classes) {
        final byClass = _byClass[name];
        if (byClass == null) continue;
        for (final index in byClass) {
          consider(index);
        }
      }
    }

    return bestIndex < 0 ? null : _rules[bestIndex].display;
  }

  Set<String> _classesOf(dom.Element element) =>
      _classCache.putIfAbsent(element, () => _splitClasses(element));

  static EmailCss _build(List<_Rule> rules) {
    final freeRules = <int>{};
    final byClass = <String, Set<int>>{};
    final byId = <String, Set<int>>{};
    final byTag = <String, Set<int>>{};

    for (var index = 0; index < rules.length; index++) {
      for (final selector in rules[index].selectors) {
        // 只看右端复合选择器：它要求的条件是可索引的（必须命中才可能匹配），
        // 祖先链上的条件留给匹配阶段。这是「先比便宜条件」的由来。
        final right = selector.compounds.last;
        if (right.id != null) {
          byId.putIfAbsent(right.id!, () => <int>{}).add(index);
        } else if (right.classes.isNotEmpty) {
          for (final name in right.classes) {
            byClass.putIfAbsent(name, () => <int>{}).add(index);
          }
        } else if (right.tag != null) {
          byTag.putIfAbsent(right.tag!, () => <int>{}).add(index);
        } else {
          freeRules.add(index);
        }
      }
    }

    final visited = List<int>.filled(rules.length + 1, -1)..[0] = 0;
    return EmailCss._(
      List<_Rule>.unmodifiable(rules),
      List<int>.unmodifiable(freeRules),
      _freeze(byClass),
      _freeze(byId),
      _freeze(byTag),
      visited,
      <dom.Element, Set<String>>{},
    );
  }

  static Map<String, List<int>> _freeze(Map<String, Set<int>> source) =>
      <String, List<int>>{
        for (final entry in source.entries)
          entry.key: List<int>.unmodifiable(entry.value),
      };
}

// ---------------------------------------------------------------------------
// 上限：宁可少应用几条规则，也不要让一封恶意邮件在 UI 线程上把 App 卡死。
// ---------------------------------------------------------------------------

/// 固定「桌面视口」宽度（逻辑 px）。Apple 那类邮件在 481px 以上走桌面版。
const double _desktopViewportWidth = 800;

/// 固定「设备宽度」。桌面浏览器里 device-width 就是窗口宽。
const double _desktopDeviceWidth = 800;

/// `@media` 递归深度上限。正常邮件最多两层，超过就是病态输入。
const int _maxMediaDepth = 4;

/// 单条选择器的复合选择器个数上限（防止病态 `* * * * …` 选择器）。
const int _maxSelectorCompounds = 16;

/// 规则的硬上限。100KB 正文的真实邮件通常只有几百到几千条。
const int _maxRules = 12000;

/// 单个 `<style>` 块的处理长度上限。
const int _maxStyleBlockLength = 512 * 1024;

/// 每个元素匹配时允许的「复合选择器求值」次数（父选择器链最坏是指数级）。
/// 超了就直接当不命中 —— 宁可不藏，不误藏。
const int _matchBudgetPerElement = 4000;

/// class 缓存条目上限，防长生命周期 state 里无限增长。
const int _maxClassCacheEntries = 30000;

final RegExp _styleBlockPattern = RegExp(
  r'<style\b[^>]*>([\s\S]*?)</style\s*>',
  caseSensitive: false,
);

final RegExp _importantPattern = RegExp(r'!\s*important\s*$', caseSensitive: false);
final RegExp _whitespacePattern = RegExp(r'\s+');
final RegExp _pixelValuePattern = RegExp(r'^([0-9]*\.?[0-9]+)\s*(px|em|rem)?$');
final RegExp _notPrefixPattern = RegExp(r'^not\b\s*');
final RegExp _onlyPrefixPattern = RegExp(r'^only\b\s*');

// ---------------------------------------------------------------------------
// 规则的内部表示
// ---------------------------------------------------------------------------

class _Rule {
  const _Rule({
    required this.display,
    required this.important,
    required this.selectors,
  });

  final String display;
  final bool important;
  final List<_Selector> selectors;
}

class _Selector {
  const _Selector({
    required this.compounds,
    required this.combinators,
    required this.ids,
    required this.classes,
    required this.tags,
  });

  /// 从左到右的复合选择器（`div.a > span.b` → `[div.a, span.b]`）。
  final List<_Compound> compounds;

  /// `combinators[i]` 描述 `compounds[i]` 与 `compounds[i+1]` 的关系：
  /// true = 子代（`>`），false = 后代（空格）。`+` / `~` 在选择器解析阶段
  /// 就被整条丢掉了，不会出现在这里。
  final List<bool> combinators;

  final int ids;
  final int classes;
  final int tags;

  /// 具体度打包成一个可比较的整数。CSS 的 (a,b,c) 三元组里 a/b/c 各自
  /// 实际不会超过几百，用 10 位足够，比较时一次 `int` 比较完成。
  int get specificity => (ids << 20) | (classes << 10) | tags;

  bool matches(
    dom.Element element,
    Map<dom.Element, Set<String>> classCache,
    _MatchBudget budget,
  ) {
    if (budget.exhausted) return false;
    return _matchesFrom(this, compounds.length - 1, element, classCache, budget);
  }
}

/// `compounds[0..index]` 是否能在 `element`（位于第 index 位）处整体匹配。
///
/// 从右往左走：祖先链遍历是迭代的，只有复合选择器个数这一维递归，
/// 深度由 `_maxSelectorCompounds` 兜住，不会随 HTML 深度爆栈。
bool _matchesFrom(
  _Selector selector,
  int index,
  dom.Element element,
  Map<dom.Element, Set<String>> classCache,
  _MatchBudget budget,
) {
  if (budget.consume()) return false;
  if (!selector.compounds[index].matches(element, classCache)) return false;
  if (index == 0) return true;

  if (selector.combinators[index - 1]) {
    // `Element.parent` 已经是「父元素或 null」，不需要再判 Node 类型。
    final parent = element.parent;
    if (parent == null) return false;
    return _matchesFrom(selector, index - 1, parent, classCache, budget);
  }

  for (var node = element.parent; node != null; node = node.parent) {
    if (_matchesFrom(selector, index - 1, node, classCache, budget)) {
      return true;
    }
  }
  return false;
}

class _Compound {
  const _Compound({this.tag, this.id, this.classes = const <String>[]});

  /// 标签名（小写）；null 表示没写标签（即 `*` 或从 `.class` / `#id` 开头）。
  final String? tag;

  /// id；null 表示没写。
  final String? id;

  /// 要求的 class（`div.a.b` → `[a, b]`），大小写敏感。
  final List<String> classes;

  bool matches(dom.Element element, Map<dom.Element, Set<String>> classCache) {
    if (tag != null && element.localName != tag) return false;
    if (id != null && element.attributes['id'] != id) return false;
    if (classes.isEmpty) return true;
    final actual = classCache.putIfAbsent(element, () => _splitClasses(element));
    for (final name in classes) {
      if (!actual.contains(name)) return false;
    }
    return true;
  }
}

/// 每次 `displayFor` 一次，限制父选择器链的组合爆炸。
class _MatchBudget {
  _MatchBudget(this._remaining);

  int _remaining;

  bool get exhausted => _remaining <= 0;

  /// 返回 true 表示预算已耗尽、这次求值应放弃。
  bool consume() {
    if (_remaining <= 0) return true;
    _remaining--;
    return false;
  }
}

// ---------------------------------------------------------------------------
// CSS 文本解析（手工、迭代、对坏输入宽容）
// ---------------------------------------------------------------------------

class _SheetParser {
  _SheetParser(this.rules);

  final List<_Rule> rules;

  /// 解析一段 CSS 文本。`depth` 是 `@media` 嵌套层数，顶层为 0。
  void parse(String css, int depth) {
    var i = 0;
    final length = css.length;
    while (i < length) {
      if (rules.length >= _maxRules) return;
      final c = css.codeUnitAt(i);
      if (_isSpace(c)) {
        i++;
        continue;
      }
      // 游离的 `}`：非法，但直接跳过比抛异常好。
      if (c == 0x7D /* } */) {
        i++;
        continue;
      }
      if (c == 0x40 /* @ */) {
        i = _parseAtRule(css, i, depth);
        continue;
      }
      i = _parseRule(css, i);
    }
  }

  /// 解析 `@media { … }` / `@import …;` / `@font-face { … }` 这类 at 规则。
  /// 返回下一个待扫描位置。
  int _parseAtRule(String css, int start, int depth) {
    var i = start + 1;
    final nameStart = i;
    while (i < css.length && _isIdentChar(css.codeUnitAt(i))) {
      i++;
    }
    final name = css.substring(nameStart, i).toLowerCase();

    // 找 prelude 的结束：`{`（带块）或 `;`（无块语句）。
    final preludeStart = i;
    var parens = 0;
    var quote = 0;
    while (i < css.length) {
      final c = css.codeUnitAt(i);
      if (quote != 0) {
        if (c == 0x5C) {
          i += 2;
          continue;
        }
        if (c == quote) quote = 0;
        i++;
        continue;
      }
      if (c == 0x22 || c == 0x27) {
        quote = c;
        i++;
        continue;
      }
      if (c == 0x28) {
        parens++;
      } else if (c == 0x29) {
        if (parens > 0) parens--;
      } else if (parens == 0 && c == 0x7B /* { */) {
        break;
      } else if (parens == 0 && c == 0x3B /* ; */) {
        return i + 1;
      } else if (parens == 0 && c == 0x7D /* } */) {
        // 没有块的 at 规则却先撞到外层 `}`，把位置留在 `}` 上让外层处理。
        return i;
      }
      i++;
    }
    if (i >= css.length) return css.length;

    final end = _findBlockEnd(css, i);
    if (name == 'media' && depth < _maxMediaDepth) {
      final prelude = css.substring(preludeStart, i);
      if (_evalMediaQueryList(prelude)) {
        final innerEnd = end < css.length ? end : css.length;
        if (innerEnd > i + 1) {
          parse(css.substring(i + 1, innerEnd), depth + 1);
        }
      }
    }
    // 其它 at 规则（@font-face、@keyframes、@import 块 …）整块跳过：
    // 我们只关心 display，它们里面没有会命中普通元素的 display 规则。
    return end < css.length ? end + 1 : css.length;
  }

  /// 解析普通规则 `selectors { declarations }`。
  int _parseRule(String css, int start) {
    var i = start;
    var parens = 0;
    var brackets = 0;
    var quote = 0;
    while (i < css.length) {
      final c = css.codeUnitAt(i);
      if (quote != 0) {
        if (c == 0x5C) {
          i += 2;
          continue;
        }
        if (c == quote) quote = 0;
        i++;
        continue;
      }
      if (c == 0x22 || c == 0x27) {
        quote = c;
        i++;
        continue;
      }
      if (c == 0x28) {
        parens++;
      } else if (c == 0x29) {
        if (parens > 0) parens--;
      } else if (c == 0x5B /* [ */) {
        brackets++;
      } else if (c == 0x5D /* ] */) {
        if (brackets > 0) brackets--;
      } else if (parens == 0 && brackets == 0) {
        if (c == 0x7B) break; // 选择器部分结束
        if (c == 0x3B /* ; */) return i + 1; // 没有块，非法规则
        if (c == 0x7D /* } */) return i + 1; // 撞到外层结束
      }
      i++;
    }
    if (i >= css.length) return css.length;

    final prelude = css.substring(start, i);
    final end = _findBlockEnd(css, i);
    final declarations = css.substring(i + 1, end < css.length ? end : css.length);
    final declaration = _parseDisplay(declarations);
    if (declaration != null) {
      final selectors = _parseSelectorList(prelude);
      if (selectors.isNotEmpty) {
        rules.add(_Rule(
          display: declaration.display,
          important: declaration.important,
          selectors: selectors,
        ));
      }
    }
    return end < css.length ? end + 1 : css.length;
  }
}

class _DisplayDeclaration {
  const _DisplayDeclaration(this.display, this.important);

  final String display;
  final bool important;
}

/// 从声明块里抠出 `display`。
///
/// 同一块里重复声明时按浏览器规则：`!important` 压普通；同权重后者胜。
/// 值原样保留（去掉 `!important`、小写化、折白），交给 fwfh 的 CSS 解析器
/// 判断认不认识 —— 不认识的 display 值会被静默忽略，正是我们要的宽容行为。
_DisplayDeclaration? _parseDisplay(String block) {
  String? normal;
  String? important;
  for (final part in _splitTopLevel(block, 0x3B /* ; */)) {
    final colon = _indexOfTopLevel(part, 0x3A /* : */);
    if (colon <= 0) continue;
    if (part.substring(0, colon).trim().toLowerCase() != 'display') continue;
    var value = part.substring(colon + 1).trim();
    if (value.isEmpty) continue;
    final marker = _importantPattern.firstMatch(value);
    final isImportant = marker != null;
    if (marker != null) value = value.substring(0, marker.start).trim();
    value = value.toLowerCase().replaceAll(_whitespacePattern, ' ').trim();
    if (value.isEmpty) continue;
    if (isImportant) {
      important = value;
    } else {
      normal = value;
    }
  }
  final display = important ?? normal;
  return display == null ? null : _DisplayDeclaration(display, important != null);
}

/// 把选择器组拆成单条选择器并逐条解析。任何一条认不出就丢那一条，
/// 不影响同组里的其它选择器（`.a:hover, .b{}` 里的 `.b` 仍然生效）。
List<_Selector> _parseSelectorList(String prelude) {
  final out = <_Selector>[];
  for (final part in _splitTopLevel(prelude, 0x2C /* , */)) {
    final selector = _parseSelector(part.trim());
    if (selector != null) out.add(selector);
  }
  return out;
}

_Selector? _parseSelector(String source) {
  if (source.isEmpty) return null;

  final compounds = <_Compound>[];
  final combinators = <bool>[];
  var ids = 0;
  var classes = 0;
  var tags = 0;

  var i = 0;
  var pendingChild = false;
  var sawSpace = false;

  while (true) {
    final beforeSpace = i;
    while (i < source.length && _isSpace(source.codeUnitAt(i))) {
      i++;
    }
    if (i != beforeSpace) sawSpace = true;
    if (i >= source.length) break;

    final c = source.codeUnitAt(i);
    if (c == 0x3E /* > */) {
      // 连续组合子（`.a > > .b`）或选择器以组合子开头都是非法的。
      if (compounds.isEmpty || pendingChild) return null;
      pendingChild = true;
      sawSpace = false;
      i++;
      continue;
    }
    if (c == 0x2B /* + */ || c == 0x7E /* ~ */) {
      // 相邻兄弟 / 通用兄弟：静态渲染没有这套语义，整条跳过。
      return null;
    }

    if (compounds.isNotEmpty) {
      if (!pendingChild && !sawSpace) return null;
      combinators.add(pendingChild);
    }

    final parsed = _parseCompound(source, i);
    if (parsed == null) return null;
    compounds.add(parsed.compound);
    if (parsed.compound.id != null) ids++;
    classes += parsed.compound.classes.length;
    if (parsed.compound.tag != null) tags++;
    i = parsed.end;
    pendingChild = false;
    sawSpace = false;

    if (compounds.length > _maxSelectorCompounds) return null;
  }

  if (compounds.isEmpty || pendingChild) return null;
  return _Selector(
    compounds: List<_Compound>.unmodifiable(compounds),
    combinators: List<bool>.unmodifiable(combinators),
    ids: ids,
    classes: classes,
    tags: tags,
  );
}

class _ParsedCompound {
  const _ParsedCompound(this.compound, this.end);

  final _Compound compound;
  final int end;
}

/// 解析一个复合选择器：`tag`、`.class`、`#id` 及其任意组合。
///
/// 遇到伪类（`:`）、属性选择器（`[`）、函数（`(`）一律返回 null —— 调用方
/// 丢掉整条选择器。
_ParsedCompound? _parseCompound(String source, int start) {
  var i = start;
  String? tag;
  String? id;
  var universal = false;
  final classes = <String>[];
  final length = source.length;

  if (i < length) {
    final c = source.codeUnitAt(i);
    if (c == 0x2A /* * */) {
      universal = true;
      i++;
    } else if (_isIdentStart(c)) {
      final begin = i;
      i = _readIdent(source, i);
      tag = source.substring(begin, i).toLowerCase();
    }
  }

  while (i < length) {
    final c = source.codeUnitAt(i);
    if (c == 0x2E /* . */) {
      final begin = ++i;
      i = _readIdent(source, i);
      if (i == begin) return null;
      classes.add(source.substring(begin, i));
      continue;
    }
    if (c == 0x23 /* # */) {
      final begin = ++i;
      i = _readIdent(source, i);
      if (i == begin) return null;
      id = source.substring(begin, i);
      continue;
    }
    if (c == 0x3A /* : */ || c == 0x5B /* [ */ || c == 0x28 /* ( */) {
      return null;
    }
    if (c == 0x26 /* & */) return null;
    break;
  }

  if (!universal && tag == null && id == null && classes.isEmpty) return null;
  return _ParsedCompound(
    _Compound(
      tag: tag,
      id: id,
      classes: classes.isEmpty ? const <String>[] : List<String>.unmodifiable(classes),
    ),
    i,
  );
}

// ---------------------------------------------------------------------------
// 媒体查询求值：固定桌面视口
// ---------------------------------------------------------------------------

/// 求值一个 `@media` 的 prelude（逗号分隔 = OR）。
///
/// 返回 false 表示整块不应用。不认识的媒体特性按「不命中」处理。
bool _evalMediaQueryList(String prelude) {
  for (final query in _splitTopLevel(prelude, 0x2C /* , */)) {
    final text = query.trim();
    if (text.isEmpty) continue;
    if (_evalMediaQuery(text)) return true;
  }
  return false;
}

bool _evalMediaQuery(String raw) {
  var source = raw.trim().toLowerCase();
  if (source.isEmpty) return false;

  var negate = false;
  final notMatch = _notPrefixPattern.firstMatch(source);
  if (notMatch != null) {
    negate = true;
    source = source.substring(notMatch.end);
  } else {
    final onlyMatch = _onlyPrefixPattern.firstMatch(source);
    if (onlyMatch != null) source = source.substring(onlyMatch.end);
  }

  final parts = _splitMediaAnd(source);
  if (parts.isEmpty) return false;

  var matched = true;
  var sawType = false;
  for (final rawPart in parts) {
    final part = rawPart.trim();
    if (part.isEmpty) return false;
    if (part.startsWith('(')) {
      if (!part.endsWith(')')) return false;
      final result = _evalMediaFeature(part.substring(1, part.length - 1));
      if (result == _MediaFeatureResult.unsupported) {
        // 宁可不应用这个块，也不根据猜测去藏内容。
        return false;
      }
      matched = matched && result == _MediaFeatureResult.match;
      continue;
    }
    // 媒体类型：只认 screen / all，其它（print、tv …）都不命中。
    if (sawType) return false;
    sawType = true;
    matched = matched && (part == 'screen' || part == 'all');
  }
  return negate ? !matched : matched;
}

enum _MediaFeatureResult { match, noMatch, unsupported }

_MediaFeatureResult _evalMediaFeature(String raw) {
  final inner = raw.trim();
  final colon = inner.indexOf(':');
  if (colon <= 0) return _MediaFeatureResult.unsupported; // 只写名字的 feature 不认识
  final name = inner.substring(0, colon).trim();
  final value = inner.substring(colon + 1).trim();

  switch (name) {
    case 'min-width':
    case 'max-width':
      final px = _parsePixelValue(value);
      if (px == null) return _MediaFeatureResult.unsupported;
      final hit = name == 'min-width'
          ? _desktopViewportWidth >= px
          : _desktopViewportWidth <= px;
      return hit ? _MediaFeatureResult.match : _MediaFeatureResult.noMatch;

    case 'min-device-width':
    case 'max-device-width':
      final px = _parsePixelValue(value);
      if (px == null) return _MediaFeatureResult.unsupported;
      final hit = name == 'min-device-width'
          ? _desktopDeviceWidth >= px
          : _desktopDeviceWidth <= px;
      return hit ? _MediaFeatureResult.match : _MediaFeatureResult.noMatch;

    case 'prefers-color-scheme':
      // 固定浅色（App 有深色主题，但邮件正文的画布是主题决定的，若按深色
      // 求值会藏掉只给浅色画的元素 —— 这一版按浅色算，见文件头「已知上限」）。
      return value == 'light'
          ? _MediaFeatureResult.match
          : _MediaFeatureResult.noMatch;

    default:
      return _MediaFeatureResult.unsupported;
  }
}

/// `(min-width: 480px)` → 480。`em` / `rem` 按 16px 折算；其它单位（`vw`、
/// `%`）当作不认识 —— 这个特性就按「不支持」处理。
double? _parsePixelValue(String raw) {
  final match = _pixelValuePattern.firstMatch(raw.trim());
  if (match == null) return null;
  final number = double.tryParse(match.group(1)!);
  if (number == null) return null;
  switch (match.group(2)) {
    case 'px':
      return number;
    case 'em':
    case 'rem':
      return number * 16;
    default:
      return number == 0 ? 0 : null;
  }
}

/// 按 `and` 拆媒体查询的各段（只在括号外拆）。
List<String> _splitMediaAnd(String source) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var parens = 0;
  var i = 0;
  while (i < source.length) {
    final c = source.codeUnitAt(i);
    if (c == 0x28 /* ( */) parens++;
    if (c == 0x29 /* ) */ && parens > 0) parens--;
    if (parens == 0 && c == 0x20 /* space */ && buffer.isNotEmpty) {
      // 形如 "… and (…)"：and 前后都必须有分隔。
      if (source.startsWith('and', i + 1)) {
        final after = i + 4;
        if (after >= source.length || _isSpace(source.codeUnitAt(after))) {
          parts.add(buffer.toString());
          buffer.clear();
          i = after;
          while (i < source.length && _isSpace(source.codeUnitAt(i))) {
            i++;
          }
          continue;
        }
      }
    }
    buffer.writeCharCode(c);
    i++;
  }
  parts.add(buffer.toString());
  return parts;
}

// ---------------------------------------------------------------------------
// 文本小工具
// ---------------------------------------------------------------------------

/// 去掉 `/* … */` 注释（字符串里的不算）。未闭合的注释吞到末尾 —— 坏输入
/// 下宁可少解析几条规则，也不要把注释内容当成选择器/声明。
String _stripComments(String css) {
  if (!css.contains('/*')) return css;
  final out = StringBuffer();
  var i = 0;
  var quote = 0;
  while (i < css.length) {
    final c = css.codeUnitAt(i);
    if (quote != 0) {
      out.writeCharCode(c);
      if (c == 0x5C && i + 1 < css.length) {
        out.writeCharCode(css.codeUnitAt(i + 1));
        i += 2;
        continue;
      }
      if (c == quote) quote = 0;
      i++;
      continue;
    }
    if (c == 0x22 || c == 0x27) {
      quote = c;
      out.writeCharCode(c);
      i++;
      continue;
    }
    if (c == 0x2F /* / */ &&
        i + 1 < css.length &&
        css.codeUnitAt(i + 1) == 0x2A /* * */) {
      final end = css.indexOf('*/', i + 2);
      if (end < 0) break;
      out.write(' ');
      i = end + 2;
      continue;
    }
    out.writeCharCode(c);
    i++;
  }
  return out.toString();
}

/// 按顶层（括号 / 方括号 / 引号之外）的 `separator` 切分。
List<String> _splitTopLevel(String source, int separator) {
  final out = <String>[];
  var start = 0;
  var parens = 0;
  var brackets = 0;
  var quote = 0;
  var i = 0;
  while (i < source.length) {
    final c = source.codeUnitAt(i);
    if (quote != 0) {
      if (c == 0x5C) {
        i += 2;
        continue;
      }
      if (c == quote) quote = 0;
      i++;
      continue;
    }
    if (c == 0x22 || c == 0x27) {
      quote = c;
      i++;
      continue;
    }
    if (c == 0x28) {
      parens++;
    } else if (c == 0x29) {
      if (parens > 0) parens--;
    } else if (c == 0x5B) {
      brackets++;
    } else if (c == 0x5D) {
      if (brackets > 0) brackets--;
    } else if (c == separator && parens == 0 && brackets == 0) {
      out.add(source.substring(start, i));
      start = i + 1;
    }
    i++;
  }
  out.add(source.substring(start));
  return out;
}

/// 第一个顶层（括号 / 方括号 / 引号之外）的 [target] 下标；没有返回 -1。
int _indexOfTopLevel(String source, int target) {
  var parens = 0;
  var brackets = 0;
  var quote = 0;
  var i = 0;
  while (i < source.length) {
    final c = source.codeUnitAt(i);
    if (quote != 0) {
      if (c == 0x5C) {
        i += 2;
        continue;
      }
      if (c == quote) quote = 0;
      i++;
      continue;
    }
    if (c == 0x22 || c == 0x27) {
      quote = c;
      i++;
      continue;
    }
    if (c == 0x28) {
      parens++;
    } else if (c == 0x29) {
      if (parens > 0) parens--;
    } else if (c == 0x5B) {
      brackets++;
    } else if (c == 0x5D) {
      if (brackets > 0) brackets--;
    } else if (c == target && parens == 0 && brackets == 0) {
      return i;
    }
    i++;
  }
  return -1;
}

/// 找到 `{`（下标 [openBrace]）对应的 `}`；未闭合返回字符串长度。
int _findBlockEnd(String css, int openBrace) {
  var depth = 0;
  var quote = 0;
  var i = openBrace;
  while (i < css.length) {
    final c = css.codeUnitAt(i);
    if (quote != 0) {
      if (c == 0x5C) {
        i += 2;
        continue;
      }
      if (c == quote) quote = 0;
      i++;
      continue;
    }
    if (c == 0x22 || c == 0x27) {
      quote = c;
    } else if (c == 0x7B) {
      depth++;
    } else if (c == 0x7D) {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return css.length;
}

/// 元素的 class 集合（按空白切分；大小写敏感，与 HTML 标准一致）。
Set<String> _splitClasses(dom.Element element) {
  final raw = element.attributes['class'];
  if (raw == null || raw.isEmpty) return const <String>{};
  final out = <String>{};
  for (final part in raw.split(_whitespacePattern)) {
    if (part.isNotEmpty) out.add(part);
  }
  return out;
}

bool _isSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D;

bool _isHexDigit(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x46) ||
    (c >= 0x61 && c <= 0x66);

bool _isIdentStart(int c) =>
    c == 0x2D /* - */ ||
    c == 0x5F /* _ */ ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c >= 0x80;

bool _isIdentChar(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39);

/// 读一个 CSS 标识符（支持 `\` 转义，不真正反转义 —— 邮件里几乎不会用到，
/// 不反转义只会导致该条选择器匹配不上，不会误藏）。
int _readIdent(String source, int start) {
  var i = start;
  while (i < source.length) {
    final c = source.codeUnitAt(i);
    if (c == 0x5C /* \ */) {
      i++;
      if (i >= source.length) break;
      // 十六进制转义最多 6 位；否则就是「转义一个字符」。
      var hex = 0;
      while (i < source.length && hex < 6 && _isHexDigit(source.codeUnitAt(i))) {
        i++;
        hex++;
      }
      if (hex == 0) i++;
      continue;
    }
    if (!_isIdentChar(c)) break;
    i++;
  }
  return i;
}
