import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/codecs/doc_model.dart';
import 'package:mail_app/features/attachment/codecs/docx.dart';
import 'package:mail_app/features/attachment/codecs/ooxml.dart';

import 'support/ooxml_fixture.dart';

/// 找一个段落里的纯文本。
DocParagraph? _firstParagraph(List<DocBlock> blocks) {
  for (final block in blocks) {
    if (block is DocParagraphBlock) return block.paragraph;
  }
  return null;
}

List<DocParagraph> _paragraphs(List<DocBlock> blocks) => blocks
    .whereType<DocParagraphBlock>()
    .map((b) => b.paragraph)
    .toList(growable: false);

void main() {
  group('包与主部件', () {
    test('正常的小 docx 能解出正文', () {
      final result = DocxCodec.parse(
        docx('<w:p><w:r><w:t>hello</w:t></w:r></w:p>'),
      );
      expect(result.failureOrNull, isNull);
      final blocks = result.valueOrNull!;
      expect(blocks.length, 1);
      expect(_paragraphs(blocks).first.text, 'hello');
    });

    test('主部件的位置听 rels 的，不是猜 word/document.xml', () {
      // 有些工具重新打包后会把主部件放到别处 —— 那条 rels 就是为它写的。
      final result = DocxCodec.parse(
        docx(
          '<w:p><w:r><w:t>moved</w:t></w:r></w:p>',
          mainPart: 'word/main.xml',
        ),
      );
      expect(result.failureOrNull, isNull);
      expect(_paragraphs(result.valueOrNull!).first.text, 'moved');
    });

    test('没有 rels 时退回约定路径', () {
      final bytes = buildPackage(<String, String>{
        'word/document.xml': '<?xml version="1.0"?>'
            '<w:document xmlns:w="$wordMain"><w:body>'
            '<w:p><w:r><w:t>fallback</w:t></w:r></w:p>'
            '</w:body></w:document>',
      });
      final result = DocxCodec.parse(bytes);
      expect(_paragraphs(result.valueOrNull!).first.text, 'fallback');
    });
  });

  group('坏输入', () {
    test('不是 zip → notAPackage', () {
      final result = DocxCodec.parse('this is not a docx'.codeUnits);
      expect(result.valueOrNull, isNull);
      expect(result.failureOrNull, ParseFailure.notAPackage);
    });

    test('空字节 → notAPackage', () {
      expect(DocxCodec.parse(<int>[]).failureOrNull, ParseFailure.notAPackage);
    });

    test('是个 zip 但没有 document.xml → missingPart', () {
      final bytes = buildPackage(<String, String>{
        'hello.txt': 'not a document',
      });
      expect(DocxCodec.parse(bytes).failureOrNull, ParseFailure.missingPart);
    });

    test('document.xml 不是合法 XML → malformed', () {
      final bytes = buildPackage(<String, String>{
        'word/document.xml': '<w:document><not closed',
      });
      expect(DocxCodec.parse(bytes).failureOrNull, ParseFailure.malformed);
    });

    test('zip 本身坏掉 → malformed，不是抛穿', () {
      // 头四个字节看着像 zip，后面全是垃圾。
      final broken = <int>[0x50, 0x4B, 0x03, 0x04, ...List<int>.filled(64, 0x41)];
      expect(DocxCodec.parse(broken).failureOrNull, ParseFailure.malformed);
    });

    test('解压输出超过头部声明的大小 → malformed（解压炸弹那一档）', () {
      // 把 `word/document.xml` 的**声明**大小改小 —— archive 4.5 的
      // `decodeLimited` 会因此在解到一半时抛。
      final bytes = docx('<w:p><w:r><w:t>${'x' * 20000}</w:t></w:r></w:p>');
      final patched = _shrinkDeclaredSize(bytes, 'word/document.xml', 16);
      final result = DocxCodec.parse(patched);
      expect(result.valueOrNull, isNull);
      expect(result.failureOrNull, ParseFailure.malformed);
    });
  });

  group('段落与行内样式', () {
    test('标题级别从 pStyle 认出来', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
        '<w:r><w:t>一</w:t></w:r></w:p>'
        '<w:p><w:pPr><w:pStyle w:val="Heading3"/></w:pPr>'
        '<w:r><w:t>三</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>正文</w:t></w:r></w:p>',
      )).valueOrNull!;

      final paragraphs = _paragraphs(blocks);
      expect(paragraphs[0].style, DocBlockStyle.heading);
      expect(paragraphs[0].level, 1);
      expect(paragraphs[1].level, 3);
      expect(paragraphs[2].style, DocBlockStyle.body);
    });

    test('Title 当一级标题', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr>'
        '<w:r><w:t>T</w:t></w:r></w:p>',
      )).valueOrNull!;
      expect(_paragraphs(blocks).first.level, 1);
    });

    test('粗体 / 斜体 / 下划线 / 删除线各自认出来', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p>'
        '<w:r><w:rPr><w:b/></w:rPr><w:t>B</w:t></w:r>'
        '<w:r><w:rPr><w:i/></w:rPr><w:t>I</w:t></w:r>'
        '<w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>U</w:t></w:r>'
        '<w:r><w:rPr><w:strike/></w:rPr><w:t>S</w:t></w:r>'
        '<w:r><w:t>plain</w:t></w:r>'
        '</w:p>',
      )).valueOrNull!;

      final runs = _firstParagraph(blocks)!.runs;
      expect(runs[0].bold, isTrue);
      expect(runs[1].italic, isTrue);
      expect(runs[2].underline, isTrue);
      expect(runs[3].strike, isTrue);
      expect(runs[4].isPlain, isTrue);
    });

    test('`w:b w:val="0"` 是**取消**加粗，不是加粗', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>x</w:t></w:r></w:p>',
      )).valueOrNull!;
      expect(_firstParagraph(blocks)!.runs.first.bold, isFalse);
    });

    test('`w:u w:val="none"` 不算下划线', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:r><w:rPr><w:u w:val="none"/></w:rPr><w:t>x</w:t></w:r></w:p>',
      )).valueOrNull!;
      expect(_firstParagraph(blocks)!.runs.first.underline, isFalse);
    });

    test('上标下标', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p>'
        '<w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:t>2</w:t></w:r>'
        '<w:r><w:rPr><w:vertAlign w:val="subscript"/></w:rPr><w:t>n</w:t></w:r>'
        '</w:p>',
      )).valueOrNull!;
      final runs = _firstParagraph(blocks)!.runs;
      expect(runs[0].script, DocScript.superscript);
      expect(runs[1].script, DocScript.subscript);
    });

    test('br 是换行、tab 是制表符', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:r><w:t>a</w:t><w:br/><w:t>b</w:t><w:tab/><w:t>c</w:t></w:r></w:p>',
      )).valueOrNull!;
      expect(_firstParagraph(blocks)!.text, 'a\nb\tc');
    });

    test('超链接里的文字留得住', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:hyperlink r:id="rId9" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<w:r><w:t>link text</w:t></w:r></w:hyperlink></w:p>',
      )).valueOrNull!;
      expect(_firstParagraph(blocks)!.text, 'link text');
    });

    test('sdt 包装的内容也读得到', () {
      final blocks = DocxCodec.parse(docx(
        '<w:sdt><w:sdtContent>'
        '<w:p><w:r><w:t>in sdt</w:t></w:r></w:p>'
        '</w:sdtContent></w:sdt>',
      )).valueOrNull!;
      expect(_paragraphs(blocks).first.text, 'in sdt');
    });

    test('图片位置留一个占位，不是静默跳过', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:r><w:drawing/></w:r><w:r><w:t>after</w:t></w:r></w:p>',
      )).valueOrNull!;
      final paragraph = _firstParagraph(blocks)!;
      expect(paragraph.text, '[图片]after');
    });

    test('空段落留着，不丢', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:r><w:t>a</w:t></w:r></w:p><w:p/><w:p><w:r><w:t>b</w:t></w:r></w:p>',
      )).valueOrNull!;
      final paragraphs = _paragraphs(blocks);
      expect(paragraphs.length, 3);
      expect(paragraphs[1].isEmpty, isTrue);
    });
  });

  group('列表', () {
    test('numPr 当项目符号，并按 ilvl 缩进', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr>'
        '<w:r><w:t>first</w:t></w:r></w:p>'
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="2"/></w:numPr></w:pPr>'
        '<w:r><w:t>deep</w:t></w:r></w:p>',
      )).valueOrNull!;
      final paragraphs = _paragraphs(blocks);
      expect(paragraphs[0].style, DocBlockStyle.bullet);
      expect(paragraphs[0].level, 0);
      expect(paragraphs[1].level, 2);
    });

    test('列表层级有上限，不会缩到屏幕外面去', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="99"/></w:numPr></w:pPr>'
        '<w:r><w:t>x</w:t></w:r></w:p>',
      )).valueOrNull!;
      expect(_firstParagraph(blocks)!.level, 8);
    });

    test('对齐方式读得出来', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>x</w:t></w:r></w:p>',
      )).valueOrNull!;
      expect(_firstParagraph(blocks)!.align, 'center');
    });

    test('引用样式', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:pPr><w:pStyle w:val="Quote"/></w:pPr><w:r><w:t>q</w:t></w:r></w:p>',
      )).valueOrNull!;
      expect(_firstParagraph(blocks)!.style, DocBlockStyle.quote);
    });
  });

  group('表格', () {
    test('行列与文字', () {
      final blocks = DocxCodec.parse(docx(
        '<w:tbl>'
        '<w:tr><w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc></w:tr>'
        '<w:tr><w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>d</w:t></w:r></w:p></w:tc></w:tr>'
        '</w:tbl>',
      )).valueOrNull!;

      final table = blocks.whereType<DocTableBlock>().single.table;
      expect(table.rows.length, 2);
      expect(table.rows[0].cells[1].text, 'b');
      expect(table.rows[1].cells[0].text, 'c');
      expect(table.columns, 2);
    });

    test('gridSpan 跨列', () {
      final blocks = DocxCodec.parse(docx(
        '<w:tbl><w:tr>'
        '<w:tc><w:tcPr><w:gridSpan w:val="3"/></w:tcPr>'
        '<w:p><w:r><w:t>wide</w:t></w:r></w:p></w:tc>'
        '</w:tr></w:tbl>',
      )).valueOrNull!;
      final table = blocks.whereType<DocTableBlock>().single.table;
      expect(table.rows[0].cells[0].colSpan, 3);
      expect(table.columns, 3);
    });

    test('空表格不出现', () {
      final blocks = DocxCodec.parse(docx('<w:tbl></w:tbl>')).valueOrNull!;
      expect(blocks.whereType<DocTableBlock>(), isEmpty);
    });

    test('表格与段落的先后顺序保住', () {
      final blocks = DocxCodec.parse(docx(
        '<w:p><w:r><w:t>before</w:t></w:r></w:p>'
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
        '<w:p><w:r><w:t>after</w:t></w:r></w:p>',
      )).valueOrNull!;
      expect(blocks.length, 3);
      expect(blocks[0], isA<DocParagraphBlock>());
      expect(blocks[1], isA<DocTableBlock>());
      expect(blocks[2], isA<DocParagraphBlock>());
    });
  });
}

/// 把 zip 里某个条目**本地头**声明的未压缩大小改小。
///
/// 用来构造「声明与实际对不上」的那一档：`archive` 的 `decodeLimited`
/// 按声明大小限制输出，于是解到一半会抛 `ArchiveException`。
/// 本地头里的两个大小各在**偏移 22**（未压缩）与 18（压缩），名字跟在
/// 「30 字节定长 + 名字长度 + 扩展区长度」之后 —— 先按名字定位到这一条，
/// 再改。中央目录里那一份也要改（见 [_shrinkCentral]）。
List<int> _shrinkDeclaredSize(List<int> zip, String name, int fakeSize) {
  final out = List<int>.from(zip);
  final needle = name.codeUnits;
  for (var i = 0; i + 30 < out.length; i++) {
    if (out[i] != 0x50 || out[i + 1] != 0x4B || out[i + 2] != 0x03) continue;
    final nameLength = out[i + 26] | (out[i + 27] << 8);
    final start = i + 30;
    if (start + nameLength > out.length) continue;
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (out[start + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (!match) continue;
    out[i + 22] = fakeSize & 0xFF;
    out[i + 23] = (fakeSize >> 8) & 0xFF;
    out[i + 24] = (fakeSize >> 16) & 0xFF;
    out[i + 25] = (fakeSize >> 24) & 0xFF;
    _shrinkCentral(out, name, fakeSize);
    return out;
  }
  throw StateError('fixture: 没找到 $name 的本地头');
}

void _shrinkCentral(List<int> out, String name, int fakeSize) {
  final needle = name.codeUnits;
  for (var i = 0; i + 46 < out.length; i++) {
    if (out[i] != 0x50 || out[i + 1] != 0x4B || out[i + 2] != 0x01) continue;
    final nameLength = out[i + 28] | (out[i + 29] << 8);
    final start = i + 46;
    if (start + nameLength > out.length) continue;
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (out[start + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (!match) continue;
    out[i + 24] = fakeSize & 0xFF;
    out[i + 25] = (fakeSize >> 8) & 0xFF;
    out[i + 26] = (fakeSize >> 16) & 0xFF;
    out[i + 27] = (fakeSize >> 24) & 0xFF;
    return;
  }
}
