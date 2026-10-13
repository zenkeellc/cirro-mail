import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/codecs/doc_model.dart';
import 'package:mail_app/features/attachment/codecs/ooxml.dart';
import 'package:mail_app/features/attachment/codecs/pptx.dart';

import 'support/ooxml_fixture.dart';

/// 一页里的纯文本，按块拼起来 —— 断言顺序时用。
List<String> _texts(List<DocBlock> blocks) => blocks
    .whereType<DocParagraphBlock>()
    .map((b) => b.paragraph.text)
    .where((t) => t.isNotEmpty)
    .toList(growable: false);

void main() {
  group('页序与页数', () {
    test('每页的文字都抽得到，顺序按 sldIdLst', () {
      final result = PptxCodec.parse(pptx(<String>[
        slideShape(<String>['first page']),
        slideShape(<String>['second page']),
        slideShape(<String>['third page']),
      ]));

      expect(result.failureOrNull, isNull);
      final presentation = result.valueOrNull!;
      expect(presentation.slides.length, 3);
      expect(_texts(presentation.slides[0].blocks), <String>['first page']);
      expect(_texts(presentation.slides[2].blocks), <String>['third page']);
      // 页序是 1 起的**位置**，不是文件名里的编号。
      expect(presentation.slides.map((s) => s.index), <int>[1, 2, 3]);
    });

    test('页序听 sldIdLst 的：拖过顺序的文件名与位置对不上', () {
      // 第 1 页指向 `slide2.xml`、第 2 页指向 `slide1.xml` —— 这正是
      // 用户在 PowerPoint 里把第一页拖到最后面之后文件的样子。
      final bytes = buildPackage(<String, String>{
        '_rels/.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="ppt/presentation.xml"/></Relationships>',
        'ppt/presentation.xml': '<?xml version="1.0"?>'
            '<p:presentation xmlns:p="$presentationMain" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<p:sldIdLst>'
            '<p:sldId id="257" r:id="rId2"/>'
            '<p:sldId id="256" r:id="rId1"/>'
            '</p:sldIdLst></p:presentation>',
        'ppt/_rels/presentation.xml.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" '
            'Target="slides/slide1.xml"/>'
            '<Relationship Id="rId2" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" '
            'Target="slides/slide2.xml"/>'
            '</Relationships>',
        'ppt/slides/slide1.xml': '<?xml version="1.0"?>'
            '<p:sld xmlns:p="$presentationMain" xmlns:a="$drawingMain">'
            '<p:cSld>${slideShape(<String>['I was first'])}</p:cSld></p:sld>',
        'ppt/slides/slide2.xml': '<?xml version="1.0"?>'
            '<p:sld xmlns:p="$presentationMain" xmlns:a="$drawingMain">'
            '<p:cSld>${slideShape(<String>['I am first now'])}</p:cSld></p:sld>',
      });

      final presentation = PptxCodec.parse(bytes).valueOrNull!;
      expect(_texts(presentation.slides[0].blocks), <String>['I am first now']);
      expect(_texts(presentation.slides[1].blocks), <String>['I was first']);
    });

    test('主部件位置听 _rels/.rels 的', () {
      final bytes = buildPackage(<String, String>{
        '_rels/.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="deck/presentation.xml"/></Relationships>',
        'deck/presentation.xml': '<?xml version="1.0"?>'
            '<p:presentation xmlns:p="$presentationMain" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst>'
            '</p:presentation>',
        'deck/_rels/presentation.xml.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" '
            'Target="slides/slide1.xml"/></Relationships>',
        'deck/slides/slide1.xml': '<?xml version="1.0"?>'
            '<p:sld xmlns:p="$presentationMain" xmlns:a="$drawingMain">'
            '<p:cSld>${slideShape(<String>['moved'])}</p:cSld></p:sld>',
      });

      final presentation = PptxCodec.parse(bytes).valueOrNull!;
      expect(_texts(presentation.slides.single.blocks), <String>['moved']);
    });

    test('rels 缺一条时退回约定路径', () {
      final bytes = buildPackage(<String, String>{
        '_rels/.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="ppt/presentation.xml"/></Relationships>',
        'ppt/presentation.xml': '<?xml version="1.0"?>'
            '<p:presentation xmlns:p="$presentationMain" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<p:sldIdLst><p:sldId id="256" r:id="rIdUnknown"/></p:sldIdLst>'
            '</p:presentation>',
        'ppt/slides/slide1.xml': '<?xml version="1.0"?>'
            '<p:sld xmlns:p="$presentationMain" xmlns:a="$drawingMain">'
            '<p:cSld>${slideShape(<String>['guess me'])}</p:cSld></p:sld>',
      });

      final presentation = PptxCodec.parse(bytes).valueOrNull!;
      expect(_texts(presentation.slides.single.blocks), <String>['guess me']);
    });
  });

  group('形状与文字', () {
    test('标题占位符认出来', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideShape(<String>['季度汇报'], placeholder: 'title') +
            slideBody('<a:p><a:r><a:t>正文一</a:t></a:r></a:p>'),
      ])).valueOrNull!;

      expect(presentation.slides.single.title, '季度汇报');
    });

    test('ctrTitle 也算标题', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideShape(<String>['居中标题'], placeholder: 'ctrTitle'),
      ])).valueOrNull!;

      expect(presentation.slides.single.title, '居中标题');
    });

    test('没有占位符的文本框当普通正文', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideShape(<String>['浮动文字']),
      ])).valueOrNull!;

      expect(presentation.slides.single.title, isNull);
      expect(_texts(presentation.slides.single.blocks), <String>['浮动文字']);
    });

    test('一个形状里的多段按顺序留下来', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideShape(<String>['a', 'b', 'c']),
      ])).valueOrNull!;

      expect(_texts(presentation.slides.single.blocks), <String>['a', 'b', 'c']);
    });

    test('多个形状之间也是文档顺序', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideShape(<String>['one']) +
            slideShape(<String>['two']) +
            slideShape(<String>['three']),
      ])).valueOrNull!;

      expect(
        _texts(presentation.slides.single.blocks),
        <String>['one', 'two', 'three'],
      );
    });

    test('组合里的形状摊平，文字不丢', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideGroup(<String>[
          slideShape(<String>['in group A']),
          slideShape(<String>['in group B']),
        ]),
      ])).valueOrNull!;

      expect(
        _texts(presentation.slides.single.blocks),
        <String>['in group A', 'in group B'],
      );
    });

    test('显式项目符号认出来并按 lvl 缩进', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideBullets(<String>['顶层'], level: 0) +
            slideBullets(<String>['子项'], level: 2),
      ])).valueOrNull!;

      final paragraphs = presentation.slides.single.blocks
          .whereType<DocParagraphBlock>()
          .map((b) => b.paragraph)
          .toList(growable: false);
      expect(paragraphs[0].style, DocBlockStyle.bullet);
      expect(paragraphs[0].level, 0);
      expect(paragraphs[1].level, 2);
    });

    test('没有 buChar 的段落不硬当成项目符号', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideBody('<a:p><a:r><a:t>光秃秃一行</a:t></a:r></a:p>'),
      ])).valueOrNull!;

      final paragraph = presentation.slides.single.blocks
          .whereType<DocParagraphBlock>()
          .single
          .paragraph;
      expect(paragraph.style, DocBlockStyle.body);
    });

    test('行内加粗斜体下划线删除线各自认出来', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideBody(
          slideRun('B', bold: true) +
              slideRun('I', italic: true) +
              slideRun('U', underline: true) +
              slideRun('S', strike: true) +
              slideRun('plain'),
        ),
      ])).valueOrNull!;

      final runs = presentation.slides.single.blocks
          .whereType<DocParagraphBlock>()
          .map((b) => b.paragraph)
          .expand((p) => p.runs)
          .toList(growable: false);
      expect(runs[0].bold, isTrue);
      expect(runs[1].italic, isTrue);
      expect(runs[2].underline, isTrue);
      expect(runs[3].strike, isTrue);
      expect(runs[4].isPlain, isTrue);
    });

    test('a:br 是换行', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideBody('<a:p><a:r><a:t>x</a:t></a:r><a:br/><a:r><a:t>y</a:t></a:r></a:p>'),
      ])).valueOrNull!;

      expect(_texts(presentation.slides.single.blocks), <String>['x\ny']);
    });

    test('图片占一个位，不是静默跳过', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slidePicture + slideShape(<String>['after pic']),
      ])).valueOrNull!;

      final blocks = presentation.slides.single.blocks;
      expect(blocks.whereType<DocPlaceholderBlock>().single.label, '[图片]');
      expect(_texts(blocks), <String>['after pic']);
    });
  });

  group('表格', () {
    test('graphicFrame 里的表格抽出来', () {
      final presentation = PptxCodec.parse(pptx(<String>[
        slideTable(<List<String>>[
          <String>['姓名', '分数'],
          <String>['alice', '90'],
        ]),
      ])).valueOrNull!;

      final table = presentation.slides.single.blocks
          .whereType<DocTableBlock>()
          .single
          .table;
      expect(table.rows.length, 2);
      expect(table.rows[0].cells[1].text, '分数');
      expect(table.rows[1].cells[0].text, 'alice');
    });
  });

  group('上限与坏输入', () {
    test('页数撞上限：只解前 maxSlides 页并标记截断', () {
      final slides = <String>[
        for (var i = 0; i < PptxCodec.maxSlides + 5; i++)
          slideShape(<String>['page $i']),
      ];
      final presentation = PptxCodec.parse(pptx(slides)).valueOrNull!;

      expect(presentation.slides.length, PptxCodec.maxSlides);
      expect(presentation.truncated, isTrue);
      expect(_texts(presentation.slides.first.blocks), <String>['page 0']);
    });

    test('正好等于上限不算截断', () {
      final slides = <String>[
        for (var i = 0; i < PptxCodec.maxSlides; i++)
          slideShape(<String>['page $i']),
      ];
      final presentation = PptxCodec.parse(pptx(slides)).valueOrNull!;

      expect(presentation.slides.length, PptxCodec.maxSlides);
      expect(presentation.truncated, isFalse);
    });

    test('某一页的部件读不出来，别的照显示', () {
      final bytes = buildPackage(<String, String>{
        '_rels/.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="ppt/presentation.xml"/></Relationships>',
        'ppt/presentation.xml': '<?xml version="1.0"?>'
            '<p:presentation xmlns:p="$presentationMain" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<p:sldIdLst>'
            '<p:sldId id="256" r:id="rId1"/>'
            '<p:sldId id="257" r:id="rId2"/>'
            '</p:sldIdLst></p:presentation>',
        'ppt/_rels/presentation.xml.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" '
            'Target="slides/slide1.xml"/>'
            '<Relationship Id="rId2" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" '
            'Target="slides/gone.xml"/>'
            '</Relationships>',
        'ppt/slides/slide1.xml': '<?xml version="1.0"?>'
            '<p:sld xmlns:p="$presentationMain" xmlns:a="$drawingMain">'
            '<p:cSld>${slideShape(<String>['survivor'])}</p:cSld></p:sld>',
      });

      final presentation = PptxCodec.parse(bytes).valueOrNull!;
      expect(_texts(presentation.slides.single.blocks), <String>['survivor']);
      expect(presentation.truncated, isTrue);
    });

    test('不是 zip → notAPackage', () {
      expect(
        PptxCodec.parse('not a pptx'.codeUnits).failureOrNull,
        ParseFailure.notAPackage,
      );
    });

    test('是 zip 但没有 presentation.xml → missingPart', () {
      expect(
        PptxCodec.parse(buildPackage(<String, String>{'hi.txt': 'x'}))
            .failureOrNull,
        ParseFailure.missingPart,
      );
    });

    test('presentation.xml 不是合法 XML → malformed', () {
      expect(
        PptxCodec.parse(buildPackage(<String, String>{
          'ppt/presentation.xml': '<p:presentation><not closed',
        })).failureOrNull,
        ParseFailure.malformed,
      );
    });

    test('没有 sldIdLst → missingPart', () {
      expect(
        PptxCodec.parse(buildPackage(<String, String>{
          '_rels/.rels': '<?xml version="1.0"?>'
              '<Relationships xmlns="$officeRels">'
              '<Relationship Id="rId1" '
              'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
              'Target="ppt/presentation.xml"/></Relationships>',
          'ppt/presentation.xml': '<?xml version="1.0"?>'
              '<p:presentation xmlns:p="$presentationMain"/>',
        })).failureOrNull,
        ParseFailure.missingPart,
      );
    });

    test('有 sldIdLst 但一页也读不出来 → missingPart', () {
      expect(
        PptxCodec.parse(buildPackage(<String, String>{
          '_rels/.rels': '<?xml version="1.0"?>'
              '<Relationships xmlns="$officeRels">'
              '<Relationship Id="rId1" '
              'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
              'Target="ppt/presentation.xml"/></Relationships>',
          'ppt/presentation.xml': '<?xml version="1.0"?>'
              '<p:presentation xmlns:p="$presentationMain" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst>'
              '</p:presentation>',
        })).failureOrNull,
        ParseFailure.missingPart,
      );
    });
  });
}
