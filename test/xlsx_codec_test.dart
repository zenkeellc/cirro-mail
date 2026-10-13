import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/codecs/ooxml.dart';
import 'package:mail_app/features/attachment/codecs/xlsx.dart';

import 'support/ooxml_fixture.dart';

/// 取某张表某个格子里的文本（没内容时是 null）。
String? _cellText(Sheet sheet, int row, int column) =>
    sheet.rows[row].cells[column]?.text;

void main() {
  group('表与顺序', () {
    test('两张表的名字与顺序按 workbook.xml 来', () {
      final result = XlsxCodec.parse(xlsx(<String, String>{
        '第一张': row(1, cell('A1', body: '<v>1</v>')),
        '第二张': row(1, cell('A1', body: '<v>2</v>')),
      }));

      expect(result.failureOrNull, isNull);
      final workbook = result.valueOrNull!;
      expect(workbook.sheets.map((s) => s.name), <String>['第一张', '第二张']);
      expect(_cellText(workbook.sheets[1], 0, 0), '2');
    });

    test('工作表路径听 rels 的，不是猜 worksheets/sheetN.xml', () {
      // 把第一张表的部件挪到别处，并让 rels 指过去。
      final bytes = buildPackage(<String, String>{
        '_rels/.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="xl/workbook.xml"/></Relationships>',
        'xl/workbook.xml': '<?xml version="1.0"?>'
            '<workbook xmlns="$sheetMain" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets><sheet name="Moved" sheetId="1" r:id="rId1"/></sheets>'
            '</workbook>',
        'xl/_rels/workbook.xml.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
            'Target="sheets/custom.xml"/></Relationships>',
        // 注意：**没有** `worksheets/sheet1.xml` —— 按约定猜一定读不到。
        'xl/sheets/custom.xml': '<?xml version="1.0"?>'
            '<worksheet xmlns="$sheetMain"><sheetData>'
            '${row(1, cell('A1', body: '<v>moved</v>'))}'
            '</sheetData></worksheet>',
      });

      final workbook = XlsxCodec.parse(bytes).valueOrNull!;
      expect(workbook.sheets.single.name, 'Moved');
      expect(_cellText(workbook.sheets.single, 0, 0), 'moved');
    });

    test('rels 里没有这条关系时退回约定路径', () {
      // fixture 生成的是标准形状；这里把 rels 拆掉，逼它走兜底。
      final bytes = buildPackage(<String, String>{
        '_rels/.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="xl/workbook.xml"/></Relationships>',
        'xl/workbook.xml': '<?xml version="1.0"?>'
            '<workbook xmlns="$sheetMain" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets><sheet name="Plain" sheetId="1" r:id="rId1"/></sheets>'
            '</workbook>',
        'xl/worksheets/sheet1.xml': '<?xml version="1.0"?>'
            '<worksheet xmlns="$sheetMain"><sheetData>'
            '${row(1, cell('A1', body: '<v>7</v>'))}'
            '</sheetData></worksheet>',
      });

      final workbook = XlsxCodec.parse(bytes).valueOrNull!;
      expect(_cellText(workbook.sheets.single, 0, 0), '7');
    });

    test('主部件位置听 _rels/.rels 的', () {
      // workbook.xml 挪到 `book/` 下，sheet 也相对它找。
      final bytes = buildPackage(<String, String>{
        '_rels/.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="book/workbook.xml"/></Relationships>',
        'book/workbook.xml': '<?xml version="1.0"?>'
            '<workbook xmlns="$sheetMain" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets>'
            '</workbook>',
        'book/_rels/workbook.xml.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
            'Target="sheets/sheet1.xml"/></Relationships>',
        'book/sheets/sheet1.xml': '<?xml version="1.0"?>'
            '<worksheet xmlns="$sheetMain"><sheetData>'
            '${row(1, cell('A1', body: '<v>9</v>'))}'
            '</sheetData></worksheet>',
      });

      final workbook = XlsxCodec.parse(bytes).valueOrNull!;
      expect(_cellText(workbook.sheets.single, 0, 0), '9');
    });
  });

  group('单元格取值', () {
    test('共享字符串', () {
      final workbook = XlsxCodec.parse(xlsx(
        <String, String>{
          'S': row(1, cell('A1', type: 's', body: '<v>0</v>')
              + cell('B1', type: 's', body: '<v>1</v>')),
        },
        sharedStrings: sharedString('你好') + sharedString('world'),
      )).valueOrNull!;

      final sheet = workbook.sheets.single;
      expect(_cellText(sheet, 0, 0), '你好');
      expect(_cellText(sheet, 0, 1), 'world');
    });

    test('共享字符串里富文本的每一片都接起来', () {
      final workbook = XlsxCodec.parse(xlsx(
        <String, String>{
          'S': row(1, cell('A1', type: 's', body: '<v>0</v>')),
        },
        // 只取第一个 `<t>` 的话会丢掉「世界」。
        sharedStrings: '<si><r><t>你好</t></r><r><t>世界</t></r></si>',
      )).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 0), '你好世界');
    });

    test('共享字符串下标越界时这一格当作空', () {
      final workbook = XlsxCodec.parse(xlsx(
        <String, String>{
          'S': row(1, cell('A1', type: 's', body: '<v>9</v>')),
        },
        sharedStrings: sharedString('only'),
      )).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 0), isNull);
    });

    test('inlineStr（富文本分片也接起来）', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': row(
          1,
          cell('A1', type: 'inlineStr', body: inlineString('直写'))
              + cell(
                  'B1',
                  type: 'inlineStr',
                  body: '<is><r><t>a</t></r><r><t>b</t></r></is>'),
        ),
      })).valueOrNull!;

      final sheet = workbook.sheets.single;
      expect(_cellText(sheet, 0, 0), '直写');
      expect(_cellText(sheet, 0, 1), 'ab');
    });

    test('布尔 t="b"', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': row(
          1,
          cell('A1', type: 'b', body: '<v>1</v>')
              + cell('B1', type: 'b', body: '<v>0</v>'),
        ),
      })).valueOrNull!;

      final sheet = workbook.sheets.single;
      expect(_cellText(sheet, 0, 0), 'TRUE');
      expect(_cellText(sheet, 0, 1), 'FALSE');
    });

    test('错误值原样显示，不藏起来', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': row(1, cell('A1', type: 'e', body: '<v>#DIV/0!</v>')),
      })).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 0), '#DIV/0!');
    });

    test('公式的字符串结果 t="str"', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': row(1, cell('A1', type: 'str', body: '<v>computed</v>')),
      })).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 0), 'computed');
    });

    test('普通数字：整数不带小数点，小数不拖尾零', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': row(
          1,
          cell('A1', body: '<v>42</v>')
              + cell('B1', body: '<v>1.50</v>')
              + cell('C1', body: '<v>-3.25</v>'),
        ),
      })).valueOrNull!;

      final sheet = workbook.sheets.single;
      expect(_cellText(sheet, 0, 0), '42');
      expect(_cellText(sheet, 0, 1), '1.5');
      expect(_cellText(sheet, 0, 2), '-3.25');
      expect(sheet.rows[0].cells[0]!.isNumber, isTrue);
    });

    test('没有 <v> 的格子当作空', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': row(1, cell('A1', body: '') + cell('B1', body: '<v>1</v>')),
      })).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 0), isNull);
      expect(_cellText(workbook.sheets.single, 0, 1), '1');
    });
  });

  group('列号与稀疏行', () {
    test('列字母换算：A / Z / AA / AB', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': row(
          1,
          cell('A1', body: '<v>1</v>')
              + cell('Z1', body: '<v>26</v>')
              + cell('AA1', body: '<v>27</v>')
              + cell('AB1', body: '<v>28</v>'),
        ),
      })).valueOrNull!;

      final sheet = workbook.sheets.single;
      expect(_cellText(sheet, 0, 0), '1');
      expect(_cellText(sheet, 0, 25), '26');
      expect(_cellText(sheet, 0, 26), '27');
      expect(_cellText(sheet, 0, 27), '28');
      expect(sheet.columns, 28);
    });

    test('小写列字母也认', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': row(1, cell('ab1', body: '<v>5</v>')),
      })).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 27), '5');
    });

    test('只有 Z 列有内容时，中间那些列是空的而不是把它挤到第 1 列', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': row(1, cell('C1', body: '<v>3</v>')),
      })).valueOrNull!;

      final sheet = workbook.sheets.single;
      expect(_cellText(sheet, 0, 0), isNull);
      expect(_cellText(sheet, 0, 2), '3');
      expect(sheet.columns, 3);
    });

    test('没有 r 的格子按出现顺序排', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': '<row><c><v>a</v></c><c><v>b</v></c></row>',
      })).valueOrNull!;

      final sheet = workbook.sheets.single;
      expect(_cellText(sheet, 0, 0), 'a');
      expect(_cellText(sheet, 0, 1), 'b');
    });

    test('行号从 r 来，缺了就按顺序数', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        // 第二行故意不写 `r`。
        'S': '${row(5, cell('A5', body: '<v>x</v>'))}<row><c><v>y</v></c></row>',
      })).valueOrNull!;

      final rows = workbook.sheets.single.rows;
      expect(rows[0].index, 5);
      expect(rows[1].index, 2);
    });
  });

  group('日期序列号', () {
    test('内建日期格式（numFmtId=14）的数字转成日期', () {
      final workbook = XlsxCodec.parse(xlsx(
        <String, String>{
          'S': row(1, cell('A1', style: '0', body: '<v>45778</v>')),
        },
        cellXfs: '<xf numFmtId="14"/>',
      )).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 0), '2025-05-01');
    });

    test('带时间的序列号带上时间', () {
      final workbook = XlsxCodec.parse(xlsx(
        <String, String>{
          'S': row(1, cell('A1', style: '0', body: '<v>45778.5</v>')),
        },
        cellXfs: '<xf numFmtId="22"/>',
      )).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 0), '2025-05-01 12:00');
    });

    test('自定义格式里的日期记号也认', () {
      final workbook = XlsxCodec.parse(xlsx(
        <String, String>{
          'S': row(1, cell('A1', style: '0', body: '<v>44197</v>')),
        },
        extraParts: <String, String>{
          'xl/styles.xml': '<?xml version="1.0"?><styleSheet xmlns="$sheetMain">'
              '<numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy&quot;年&quot;m&quot;月&quot;"/></numFmts>'
              '<cellXfs count="1"><xf numFmtId="164"/></cellXfs></styleSheet>',
        },
      )).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 0), '2021-01-01');
    });

    test('格式串里的日期记号在引号里就不算（`0"days"` 不是日期）', () {
      // 引号里的 `d` 是字面量。
      final workbook = XlsxCodec.parse(xlsx(
        <String, String>{
          'S': row(1, cell('A1', style: '0', body: '<v>5</v>')),
        },
        extraParts: <String, String>{
          'xl/styles.xml': '<?xml version="1.0"?><styleSheet xmlns="$sheetMain">'
              '<numFmts count="1"><numFmt numFmtId="164" formatCode="0&quot;days&quot;"/></numFmts>'
              '<cellXfs count="1"><xf numFmtId="164"/></cellXfs></styleSheet>',
        },
      )).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 0), '5');
    });

    test('加了日期样式但不是数字的格子不受影响', () {
      final workbook = XlsxCodec.parse(xlsx(
        <String, String>{
          'S': row(1, cell('A1', type: 's', style: '0', body: '<v>0</v>')),
        },
        sharedStrings: sharedString('不是日期'),
        cellXfs: '<xf numFmtId="14"/>',
      )).valueOrNull!;

      expect(_cellText(workbook.sheets.single, 0, 0), '不是日期');
    });

    test('序列号 60 是 1900-02-28 —— Excel 那个不存在的闰日钉在这里', () {
      // Excel 为兼容 Lotus 1-2-3 把 1900 当闰年，序列号 60 显示成
      // `1900-02-29`（一天都不存在）。我们按 1899-12-30 基准算，于是 60
      // 落在 02-28、61 才是 03-01。**这是已知偏差，不是 bug** ——
      // 谁要"修"它，得先看 xlsx.dart 里那段类注释。
      expect(XlsxCodec.formatSerial(60), '1900-02-28');
      expect(XlsxCodec.formatSerial(61), '1900-03-01');
      expect(XlsxCodec.formatSerial(1), '1899-12-31');
    });
  });

  group('上限与截断', () {
    test('行数撞上限：表还在，标了 truncated', () {
      final rows = StringBuffer();
      for (var i = 1; i <= XlsxCodec.maxRows + 10; i++) {
        rows.write(row(i, cell('A$i', body: '<v>$i</v>')));
      }
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': rows.toString(),
      })).valueOrNull!;

      final sheet = workbook.sheets.single;
      expect(sheet.rows.length, XlsxCodec.maxRows);
      expect(sheet.truncated, isTrue);
      // 被裁的是**尾部**，前面的都还在。
      expect(_cellText(sheet, 0, 0), '1');
    });

    test('正好等于上限不算截断', () {
      final rows = StringBuffer();
      for (var i = 1; i <= XlsxCodec.maxRows; i++) {
        rows.write(row(i, cell('A$i', body: '<v>$i</v>')));
      }
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': rows.toString(),
      })).valueOrNull!;

      expect(workbook.sheets.single.rows.length, XlsxCodec.maxRows);
      expect(workbook.sheets.single.truncated, isFalse);
    });

    test('列数撞上限：宽度撑到上限，标了截断', () {
      // `CW` 是第 101 列（1 起），正好越过 100 的上限。
      final workbook = XlsxCodec.parse(xlsx(<String, String>{
        'S': row(1, cell('CW1', body: '<v>far</v>')),
      })).valueOrNull!;

      final sheet = workbook.sheets.single;
      expect(sheet.truncated, isTrue);
      expect(sheet.columns, XlsxCodec.maxColumns);
      // 越界那一格确实没进来。
      expect(_cellText(sheet, 0, XlsxCodec.maxColumns - 1), isNull);
    });

    test('表数撞上限：只解前 maxSheets 张，workbook 标了截断', () {
      final sheets = <String, String>{};
      for (var i = 0; i < XlsxCodec.maxSheets + 3; i++) {
        sheets['S$i'] = row(1, cell('A1', body: '<v>$i</v>'));
      }
      final workbook = XlsxCodec.parse(xlsx(sheets)).valueOrNull!;

      expect(workbook.sheets.length, XlsxCodec.maxSheets);
      expect(workbook.truncated, isTrue);
      expect(workbook.sheets.first.name, 'S0');
    });

    test('某一张表的部件读不出来，别的照显示', () {
      // rels 把第二张表指到一个不存在的部件上。
      final bytes = buildPackage(<String, String>{
        '_rels/.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="xl/workbook.xml"/></Relationships>',
        'xl/workbook.xml': '<?xml version="1.0"?>'
            '<workbook xmlns="$sheetMain" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets>'
            '<sheet name="OK" sheetId="1" r:id="rId1"/>'
            '<sheet name="Broken" sheetId="2" r:id="rId2"/>'
            '</sheets></workbook>',
        'xl/_rels/workbook.xml.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
            'Target="worksheets/sheet1.xml"/>'
            '<Relationship Id="rId2" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
            'Target="worksheets/gone.xml"/>'
            '</Relationships>',
        'xl/worksheets/sheet1.xml': '<?xml version="1.0"?>'
            '<worksheet xmlns="$sheetMain"><sheetData>'
            '${row(1, cell('A1', body: '<v>1</v>'))}'
            '</sheetData></worksheet>',
      });

      final workbook = XlsxCodec.parse(bytes).valueOrNull!;
      expect(workbook.sheets.map((s) => s.name), <String>['OK']);
      expect(workbook.truncated, isTrue);
    });

    test('没有 sheetData 的表是空的，不是错误', () {
      final workbook = XlsxCodec.parse(xlsx(<String, String>{'S': ''}))
          .valueOrNull!;
      final sheet = workbook.sheets.single;
      expect(sheet.isEmpty, isTrue);
      expect(sheet.columns, 0);
    });
  });

  group('坏输入', () {
    test('不是 zip → notAPackage', () {
      final result = XlsxCodec.parse('not an xlsx'.codeUnits);
      expect(result.valueOrNull, isNull);
      expect(result.failureOrNull, ParseFailure.notAPackage);
    });

    test('是 zip 但没有 workbook.xml → missingPart', () {
      final result = XlsxCodec.parse(
        buildPackage(<String, String>{'hello.txt': 'nope'}),
      );
      expect(result.failureOrNull, ParseFailure.missingPart);
    });

    test('workbook.xml 不是合法 XML → malformed', () {
      final result = XlsxCodec.parse(buildPackage(<String, String>{
        'xl/workbook.xml': '<workbook><not closed',
      }));
      expect(result.failureOrNull, ParseFailure.malformed);
    });

    test('workbook.xml 里没有 <sheets> → missingPart', () {
      final result = XlsxCodec.parse(buildPackage(<String, String>{
        '_rels/.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="xl/workbook.xml"/></Relationships>',
        'xl/workbook.xml': '<?xml version="1.0"?>'
            '<workbook xmlns="$sheetMain"></workbook>',
      }));
      expect(result.failureOrNull, ParseFailure.missingPart);
    });

    test('有 <sheets> 但一张也读不出来 → missingPart，不是一张空工作簿', () {
      final bytes = buildPackage(<String, String>{
        '_rels/.rels': '<?xml version="1.0"?>'
            '<Relationships xmlns="$officeRels">'
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="xl/workbook.xml"/></Relationships>',
        'xl/workbook.xml': '<?xml version="1.0"?>'
            '<workbook xmlns="$sheetMain" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets><sheet name="Gone" sheetId="1" r:id="rId1"/></sheets>'
            '</workbook>',
      });
      expect(XlsxCodec.parse(bytes).failureOrNull, ParseFailure.missingPart);
    });

    test('zip 本身坏掉 → malformed，不是抛穿', () {
      final broken = <int>[0x50, 0x4B, 0x03, 0x04, ...List<int>.filled(64, 0x41)];
      expect(XlsxCodec.parse(broken).failureOrNull, ParseFailure.malformed);
    });
  });
}
