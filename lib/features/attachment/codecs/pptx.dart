import 'package:xml/xml.dart';

import 'doc_model.dart';
import 'ooxml.dart';

/// 一页幻灯片。
class Slide {
  const Slide({required this.index, required this.blocks, this.title});

  /// 1 起的页序 —— **这张幻灯片在演示文稿里的位置**，不是文件名里的编号。
  /// 用户翻到第 3 页时说「第 3 页」，指的就是它。
  final int index;

  final List<DocBlock> blocks;

  /// 标题占位符里的文字（取不到就 null）。给页签用。
  final String? title;

  /// 这一页**没有可读的内容**：一个字的正文都没有、没有表格。
  ///
  /// 判据不是 `blocks.isEmpty`：占位符（`[图片]`）也是一条 block，而一页
  /// 只有图的幻灯片说「这一页没有文字」是不对的 —— 那页有东西，只是我们
  /// 画不出图。空段落同理：`p:txBody` 里常常带一个空 `<a:p>`。
  bool get isEmpty => !blocks.any(
        (block) => switch (block) {
          DocParagraphBlock(paragraph: final p) => !p.isEmpty,
          DocTableBlock() => true,
          DocPlaceholderBlock() => true,
        },
      );
}

class Presentation {
  const Presentation({required this.slides, required this.truncated});

  final List<Slide> slides;

  /// 有幻灯片没读出来（超过 [PptxCodec.maxSlides]，或者那几个部件坏了）。
  final bool truncated;
}

/// `.pptx` → [Presentation]。
///
/// ## 这是「能读内容」，不是「能看幻灯片」
///
/// 一份 pptx 的**观感**全在版式里：每个形状有绝对坐标、层级、主题字体、
/// 配色、动画。要做成「像 PowerPoint 那样」就是把 DrawingML 的渲染器写一遍，
/// 那是另一个量级的工程。所以这里只抽文字，按**形状在 XML 里的先后顺序**
/// 排下来，每页一张纯文本卡片（见 `pptx_viewer_screen.dart`）。
///
/// 这个取舍是**刻意**的：一页幻灯片上真正有信息量的就是那几个字，
/// 而位置信息在预览里（手机屏幕上、缩放到看不清的字号）几乎不增加可读性。
///
/// 顺带一提，按文档顺序抽文字**不用**按位置排序：PowerPoint 写文件时
/// 就是按用户添加形状的顺序写的，而标题/正文占位符总是排在最前 ——
/// 这正好是阅读顺序。按坐标排序反而会把精心排版的版式打散。
///
/// **明确不做**：版式与坐标、图片、图表、动画与切换、备注页、主题配色、
/// 文本框的自动缩放、SmartArt。界面会说清楚。
///
/// 纯函数：吃字节，吐模型，不 import `dart:io`、不 import widget。
abstract final class PptxCodec {
  const PptxCodec._();

  static const String _a =
      'http://schemas.openxmlformats.org/drawingml/2006/main';
  static const String _p =
      'http://schemas.openxmlformats.org/presentationml/2006/main';
  static const String _r =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

  /// 最多解多少页。一场演示通常几十页，而一屏只看得到一页。
  static const int maxSlides = 100;

  /// 一页里最多留多少个形状 —— 防止某页塞了几千个文本框把渲染卡死。
  static const int maxShapesPerSlide = 200;

  /// 一页里最多留多少级文本框嵌套。
  static const int maxGroupDepth = 8;

  static ParseResult<Presentation> parse(List<int> bytes) {
    final opened = Ooxml.open(bytes);
    if (opened is ParseFailed<OoxmlPackage>) {
      return ParseFailed<Presentation>(opened.reason, opened.detail);
    }
    final package = (opened as ParseOk<OoxmlPackage>).value;

    final path = package.relationshipTarget('_rels/.rels',
            typeSuffix: '/officeDocument') ??
        'ppt/presentation.xml';

    final doc = package.xml(path);
    if (doc is ParseFailed<XmlDocument>) {
      return ParseFailed<Presentation>(doc.reason, doc.detail);
    }
    final root = (doc as ParseOk<XmlDocument>).value.rootElement;

    final lst = _first(root, 'sldIdLst', _p);
    if (lst == null) {
      return ParseResult.fail(ParseFailure.missingPart, 'p:sldIdLst');
    }

    final dir = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '';
    // rels 里给出的已经是**包内绝对路径**（[_resolveFrom] 已经拼过基准目录），
    // 退回约定路径那一支才是相对的 —— 两种都由 [_slidePath] 归一。
    final relsPath = dir.isEmpty
        ? '_rels/presentation.xml.rels'
        : '$dir/_rels/${path.split('/').last}.rels';
    final targets = _relationshipMap(package, relsPath, dir);

    final slides = <Slide>[];
    var truncated = false;
    var sequence = 0;
    for (final node in lst.childElements) {
      if (node.name.local != 'sldId') continue;
      sequence++;
      if (slides.length >= maxSlides) {
        truncated = true;
        break;
      }
      final relId = node.getAttribute('id', namespaceUri: _r) ??
          node.getAttribute('id');
      final target = (relId == null ? null : targets[relId]) ??
          'slides/slide$sequence.xml';
      final slidePath = _slidePath(dir, target, targets.containsKey(relId));

      final slideDoc = package.xml(slidePath).valueOrNull;
      // 一页读不出来不该让整场演示报废：跳过它，别的照显示。
      if (slideDoc == null) {
        truncated = true;
        continue;
      }
      // **页序按 sldIdLst 数，不按文件名** —— 用户拖过顺序之后
      // `slide1.xml` 完全可能是第 5 页。
      slides.add(_slide(sequence, slideDoc));
    }

    if (slides.isEmpty) {
      return ParseResult.fail(ParseFailure.missingPart, 'slides');
    }
    return ParseResult.ok(Presentation(slides: slides, truncated: truncated));
  }

  // -------------------------------------------------------------- 单页

  static Slide _slide(int index, XmlDocument document) {
    final blocks = <DocBlock>[];
    String? title;

    final tree = _first(document.rootElement, 'cSld', _p) ?? document.rootElement;
    var shapes = 0;

    void walk(XmlElement parent, int depth) {
      for (final node in parent.childElements) {
        if (shapes >= maxShapesPerSlide) return;
        switch (node.name.local) {
          case 'sp':
            shapes++;
            final shape = _shape(node);
            if (shape == null) continue;
            if (title == null && shape.isTitle) title = shape.titleText;
            blocks.addAll(shape.blocks);
          case 'graphicFrame':
            shapes++;
            final table = _graphicFrame(node);
            if (table != null) blocks.add(DocTableBlock(table));
          case 'pic':
          case 'contentPart':
            // 「明确不做」的那一档：留一个占位，不静默跳过。
            shapes++;
            blocks.add(const DocPlaceholderBlock('[图片]'));
          case 'grpSp':
            // 组合里的形状坐标是相对组合的，但我们只抽文字，
            // 所以直接摊平，顺序照旧。
            if (depth < maxGroupDepth) walk(node, depth + 1);
          case 'spTree':
            walk(node, depth);
        }
      }
    }

    final treeChildren = _first(tree, 'spTree', _p);
    walk(treeChildren ?? tree, 0);

    return Slide(index: index, blocks: blocks, title: title);
  }

  /// 一个 `p:sp` → 段落（可能不止一段）。
  static _Shape? _shape(XmlElement sp) {
    final body = _first(sp, 'txBody', _p);
    if (body == null) return null;

    final isTitle = _placeholderType(sp) == 'title' ||
        _placeholderType(sp) == 'ctrTitle';

    final blocks = <DocBlock>[];
    String? title;
    for (final p in body.childElements) {
      if (p.name.local != 'p') continue;
      final paragraph = _paragraph(p, isTitle: isTitle);
      if (isTitle && title == null && !paragraph.isEmpty) {
        title = paragraph.text;
      }
      // 空段落留着：幻灯片里的空行是排版的一部分。
      blocks.add(DocParagraphBlock(paragraph));
    }
    if (blocks.isEmpty) return null;
    return _Shape(blocks: blocks, isTitle: isTitle, titleText: title);
  }

  /// 一个 `a:p` → [DocParagraph]。
  static DocParagraph _paragraph(XmlElement p, {required bool isTitle}) {
    final pPr = _first(p, 'pPr', _a);
    var style = isTitle ? DocBlockStyle.heading : DocBlockStyle.body;
    var level = 0;

    if (!isTitle && pPr != null) {
      // 项目符号是**显式**写在 `a:pPr` 里的（`a:buChar` / `a:buAutoNum`）——
      // 只认它，不去猜「正文占位符里默认都是符号」：那种猜测会把用户
      // 手动去掉符号的那几行又加回来。
      final bullet = _first(pPr, 'buChar', _a) ?? _first(pPr, 'buAutoNum', _a);
      if (bullet != null) {
        style = DocBlockStyle.bullet;
        level = (int.tryParse(pPr.getAttribute('lvl') ?? '') ?? 0).clamp(0, 8);
      }
    }

    final runs = <DocRun>[];
    for (final node in p.childElements) {
      switch (node.name.local) {
        case 'r':
          final text = _runText(node);
          if (text.isEmpty) continue;
          runs.add(_styledRun(text, _first(node, 'rPr', _a)));
        case 'br':
          runs.add(const DocRun('\n'));
        case 'fld':
          // 页码 / 日期那类域：里面的 `a:t` 是上一次算出来的缓存值，
          // 照显示就行（这也正是 PowerPoint 自己显示的）。
          final text = _runText(node);
          if (text.isNotEmpty) runs.add(_styledRun(text, _first(node, 'rPr', _a)));
      }
    }

    return DocParagraph(runs: runs, style: style, level: level);
  }

  /// 一个 `a:r` / `a:fld` 里的文字（`a:t` 直接子元素）。
  static String _runText(XmlElement run) {
    for (final child in run.childElements) {
      if (child.name.local == 't') return child.innerText;
    }
    return '';
  }

  static DocRun _styledRun(String text, XmlElement? rPr) {
    if (rPr == null) return DocRun(text);
    return DocRun(
      text,
      bold: _flag(rPr.getAttribute('b')),
      italic: _flag(rPr.getAttribute('i')),
      // `u` 不是布尔：`sng` / `dbl` / `heavy` 都是「有下划线」，`none` 是「没有」。
      underline: (rPr.getAttribute('u') ?? 'none') != 'none',
      strike: rPr.getAttribute('strike') == 'sngStrike',
    );
  }

  /// DrawingML 里的布尔是 `"1"` / `"true"` / `"0"` / `"false"`，缺省是 false。
  static bool _flag(String? value) =>
      value == '1' || value == 'true' || value == 'on';

  /// 占位符类型：`p:nvSpPr/p:nvPr/p:ph@type`。缺省（有 `p:ph` 但没有 `type`）
  /// 按规范是 `body`。
  static String? _placeholderType(XmlElement sp) {
    final nvSpPr = _first(sp, 'nvSpPr', _p);
    final nvPr = nvSpPr == null ? null : _first(nvSpPr, 'nvPr', _p);
    final ph = nvPr == null ? null : _first(nvPr, 'ph', _p);
    if (ph == null) return null;
    return ph.getAttribute('type') ?? 'body';
  }

  /// `p:graphicFrame` —— 里面装的是表（`a:tbl`）或图表（`a:graphicData` 别的）。
  static DocTable? _graphicFrame(XmlElement frame) {
    final tbl = _descendant(frame, 'tbl', _a);
    if (tbl == null) return null;

    final rows = <DocTableRow>[];
    for (final tr in tbl.childElements) {
      if (tr.name.local != 'tr') continue;
      final cells = <DocCell>[];
      for (final tc in tr.childElements) {
        if (tc.name.local != 'tc') continue;
        // 单元格里的文字在 `a:txBody/a:p`，和普通形状同一套读法。
        final paragraphs = <DocParagraph>[];
        final body = _first(tc, 'txBody', _a);
        final holder = body ?? tc;
        for (final p in holder.childElements) {
          if (p.name.local == 'p') paragraphs.add(_paragraph(p, isTitle: false));
        }
        // 跨列：`a:tc@gridSpan`，和 docx 那边一样要认。
        final span = int.tryParse(tc.getAttribute('gridSpan') ?? '') ?? 1;
        cells.add(DocCell(paragraphs: paragraphs, colSpan: span.clamp(1, 64)));
      }
      if (cells.isNotEmpty) rows.add(DocTableRow(cells));
    }
    final table = DocTable(rows);
    return table.isEmpty ? null : table;
  }

  // -------------------------------------------------------------- 小工具

  /// 在整棵子树里找第一个匹配的元素。
  static XmlElement? _descendant(
    XmlElement parent,
    String local,
    String namespace,
  ) {
    for (final node in parent.descendantElements) {
      if (node.name.local == local && node.name.namespaceUri == namespace) {
        return node;
      }
    }
    for (final node in parent.descendantElements) {
      if (node.name.local == local) return node;
    }
    return null;
  }

  /// 找直接子元素，命名空间优先、退而只按 local 名（同 `docx.dart` 的理由）。
  static XmlElement? _first(XmlElement parent, String local, String namespace) {
    for (final child in parent.childElements) {
      if (child.name.local == local && child.name.namespaceUri == namespace) {
        return child;
      }
    }
    for (final child in parent.childElements) {
      if (child.name.local == local) return child;
    }
    return null;
  }

  /// `presentation.xml` 那一层的 rels：`rId` → 包内绝对路径。
  static Map<String, String> _relationshipMap(
    OoxmlPackage package,
    String relsPath,
    String baseDir,
  ) {
    final document = package.xml(relsPath).valueOrNull;
    if (document == null) return const <String, String>{};
    final out = <String, String>{};
    for (final rel in document.rootElement.childElements) {
      if (rel.name.local != 'Relationship') continue;
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id == null || target == null) continue;
      out[id] = _resolveFrom(baseDir, target);
    }
    return out;
  }

  /// 幻灯片部件的路径。
  ///
  /// [fromRels] 表示 [target] 是 rels 里查到的（已经拼过基准目录的绝对路径），
  /// 否则是约定路径（相对 `presentation.xml` 所在目录）。
  /// **分得开很重要**：把已经拼过一次的绝对路径再拼一遍会得到
  /// `ppt/ppt/slides/slide1.xml` —— 那个路径读不到，而读不到只是「少一页」，
  /// 不会报错，于是表现成一场空演示文稿。
  static String _slidePath(String dir, String target, bool fromRels) {
    if (fromRels || dir.isEmpty) return target;
    return '$dir/$target';
  }

  static String _resolveFrom(String baseDir, String target) {
    if (target.startsWith('/')) return target.replaceAll(RegExp(r'^/+'), '');
    final stack = baseDir.isEmpty ? <String>[] : baseDir.split('/');
    for (final segment in target.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (stack.isNotEmpty) stack.removeLast();
        continue;
      }
      stack.add(segment);
    }
    return stack.join('/');
  }
}

/// 一个形状抽出来的东西。
class _Shape {
  const _Shape({
    required this.blocks,
    required this.isTitle,
    this.titleText,
  });

  final List<DocBlock> blocks;
  final bool isTitle;
  final String? titleText;
}
