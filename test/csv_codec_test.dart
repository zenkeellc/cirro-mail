import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/codecs/csv.dart';

/// 一行的显示（把 `\n` 写成可见的，失败信息才看得懂）。
String _row(List<String> cells) => cells.map((c) => '[${c.replaceAll('\n', '\\n')}]').join();

void main() {
  group('基本切分', () {
    test('逗号分隔，第一行是表头', () {
      final doc = CsvCodec.parse('a,b,c\n1,2,3\n');
      expect(doc.header, <String>['a', 'b', 'c']);
      expect(doc.body, <List<String>>[
        <String>['1', '2', '3'],
      ]);
      expect(doc.columns, 3);
      expect(doc.delimiter, ',');
      expect(doc.truncated, isFalse);
    });

    test('没有结尾换行也要收最后一行', () {
      final doc = CsvCodec.parse('a,b\n1,2');
      expect(doc.rows.length, 2);
      expect(_row(doc.rows.last), _row(<String>['1', '2']));
    });

    test('单个值、没有逗号也是一份表', () {
      final doc = CsvCodec.parse('name\nalice\n');
      expect(doc.rows, <List<String>>[
        <String>['name'],
        <String>['alice'],
      ]);
      expect(doc.columns, 1);
    });

    test('空文件 → 没有行', () {
      final doc = CsvCodec.parse('');
      expect(doc.isEmpty, isTrue);
      expect(doc.body, isEmpty);
    });

    test('只有表头', () {
      final doc = CsvCodec.parse('a,b\n');
      expect(doc.header, <String>['a', 'b']);
      expect(doc.body, isEmpty);
    });

    test('空字段留着，不并掉', () {
      final doc = CsvCodec.parse('a,,c\n');
      expect(doc.header, <String>['a', '', 'c']);
    });
  });

  group('换行', () {
    test('CRLF 与 LF 都给同一份结果', () {
      final crlf = CsvCodec.parse('a,b\r\n1,2\r\n');
      final lf = CsvCodec.parse('a,b\n1,2\n');
      expect(crlf.rows, lf.rows);
    });

    test('单个 CR（老 Mac）也算换行', () {
      final doc = CsvCodec.parse('a,b\r1,2\r');
      expect(doc.rows, <List<String>>[
        <String>['a', 'b'],
        <String>['1', '2'],
      ]);
    });

    test('末尾多个换行不多出空行', () {
      final doc = CsvCodec.parse('a,b\n1,2\n\n\n');
      expect(doc.rows.length, 2);
    });

    test('中间的整行空行跳过', () {
      final doc = CsvCodec.parse('a,b\n\n1,2\n');
      expect(doc.rows.length, 2);
    });

    test('但用户明写的空字段（""）要留着 —— 与空行意义不同', () {
      final doc = CsvCodec.parse('a,b\n"",""\n');
      expect(doc.rows.length, 2);
      expect(_row(doc.rows[1]), _row(<String>['', '']));
    });
  });

  group('引号', () {
    test('字段内的逗号不切', () {
      final doc = CsvCodec.parse('a,b\n"x,y",2\n');
      expect(_row(doc.body.first), _row(<String>['x,y', '2']));
    });

    test('字段内的换行不切行', () {
      final doc = CsvCodec.parse('a,b\n"line1\nline2",2\n');
      expect(doc.rows.length, 2);
      expect(doc.body.first.first, 'line1\nline2');
    });

    test('字段内的 CRLF 原样保留', () {
      final doc = CsvCodec.parse('a,b\n"l1\r\nl2",2\n');
      expect(doc.body.first.first, 'l1\r\nl2');
    });

    test('"" 是一个字面引号', () {
      final doc = CsvCodec.parse('a\n"say ""hi"""\n');
      expect(doc.body.first.first, 'say "hi"');
    });

    test('整个字段就是一个引号', () {
      final doc = CsvCodec.parse('a\n""""\n');
      expect(doc.body.first.first, '"');
    });

    test('引号里出现别的分隔符也不切', () {
      final doc = CsvCodec.parse('a;b\n"x;y";2\n');
      expect(_row(doc.body.first), _row(<String>['x;y', '2']));
    });

    test('字段中间的引号当普通字符（不报错、也不开引用）', () {
      // `a"b` 这种在现实文件里到处都有（英寸、残缺的转义）。报错对用户
      // 没有任何帮助 —— 他改不了发件人的文件。
      final doc = CsvCodec.parse('a,b\nx"y,2\n');
      expect(_row(doc.body.first), _row(<String>['x"y', '2']));
    });

    test('引号开在字段中间时，后面的分隔符照切', () {
      final doc = CsvCodec.parse('a,b,c\nx"q,r\n');
      expect(_row(doc.body.first), _row(<String>['x"q', 'r']));
    });
  });

  group('BOM 与分隔符嗅探', () {
    test('开头的 UTF-8 BOM 不会跑进第一个字段', () {
      // 有些导出工具会在文件头写 BOM，解码后就是 `﻿`。
      final doc = CsvCodec.parse('﻿a,b\n1,2\n');
      expect(doc.header, <String>['a', 'b']);
      expect(doc.header.first.codeUnitAt(0) != 0xFEFF, isTrue);
    });

    test('分号分隔', () {
      final doc = CsvCodec.parse('a;b;c\n1;2;3\n');
      expect(doc.delimiter, ';');
      expect(doc.header, <String>['a', 'b', 'c']);
    });

    test('制表符分隔', () {
      final doc = CsvCodec.parse('a\tb\tc\n1\t2\t3\n');
      expect(doc.delimiter, '\t');
      expect(doc.header, <String>['a', 'b', 'c']);
      // 底部说明上不能是一块空白。
      expect(doc.delimiterLabel, 'Tab');
    });

    test('竖线分隔', () {
      final doc = CsvCodec.parse('a|b|c\n1|2|3\n');
      expect(doc.delimiter, '|');
      expect(doc.header, <String>['a', 'b', 'c']);
    });

    test('分号表里混着逗号 —— 认分号，不数出现次数', () {
      // 正文里的逗号（地址、千分位）比真正的分隔符还多。按「谁出现得多」
      // 数会选错；按「谁切出来的列数每行一样」数不会。
      final doc = CsvCodec.parse(
        'name;address;amount\n'
        'a;1,000 号,b 座;1,234\n'
        'b;2,000 号,c 座;5,678\n'
        'c;3,000 号,d 座;9,012\n',
      );
      expect(doc.delimiter, ';');
      expect(doc.columns, 3);
    });

    test('逗号表里引号包着分号 —— 认逗号（引号内的不算）', () {
      final doc = CsvCodec.parse('a,b\n"x;y;z;w;v",2\n');
      expect(doc.delimiter, ',');
      expect(doc.columns, 2);
    });

    test('只有一个候选切出多列时才选它', () {
      final doc = CsvCodec.parse('only\tone\ncell\n');
      expect(doc.delimiter, '\t');
    });

    test('所有候选都切不出多列 → 退回逗号', () {
      final doc = CsvCodec.parse('plain text\nsecond line\n');
      expect(doc.delimiter, ',');
      expect(doc.columns, 1);
    });

    test('显式指定分隔符就不嗅探', () {
      final doc = CsvCodec.parse('a;b;c\n', delimiter: ';');
      expect(doc.header, <String>['a', 'b', 'c']);
    });

    test('嗅探只看前若干行 —— 后面的噪声不参与', () {
      final lines = <String>['a,b,c'];
      for (var i = 0; i < 50; i++) {
        lines.add('1,2,3');
      }
      // 第 30 行之后塞一个「全用分号」的段落；正常表还是逗号。
      final noisy = <String>[...lines, 'a;b;c;d;e;f;g;h;i;j'];
      expect(CsvCodec.parse(noisy.join('\n')).delimiter, ',');
    });
  });

  group('行尾不齐', () {
    test('少字段的那行就少，不补空（补了是伪造数据）', () {
      final doc = CsvCodec.parse('a,b,c\n1,2\n1,2,3\n');
      expect(doc.rows[1].length, 2);
      // 但最宽那一行告诉视图该留几列。
      expect(doc.columns, 3);
    });

    test('多字段的那行就多', () {
      final doc = CsvCodec.parse('a,b\n1,2,3\n');
      expect(doc.rows[1].length, 3);
      expect(doc.columns, 3);
    });
  });

  group('上限', () {
    test('超过 5000 行截断并标记', () {
      final buf = StringBuffer('h\n');
      for (var i = 0; i < CsvCodec.maxRows + 100; i++) {
        buf.writeln('r$i');
      }
      final doc = CsvCodec.parse(buf.toString());
      expect(doc.rows.length, CsvCodec.maxRows);
      expect(doc.truncated, isTrue);
    });

    test('正好 5000 行、末尾有换行 —— 一个字节都没丢，不报截断', () {
      final buf = StringBuffer('h\n');
      for (var i = 1; i < CsvCodec.maxRows; i++) {
        buf.writeln('r$i');
      }
      final doc = CsvCodec.parse(buf.toString());
      expect(doc.rows.length, CsvCodec.maxRows);
      expect(doc.truncated, isFalse);
    });

    test('超过 100 列截断并标记', () {
      final header = List<String>.generate(CsvCodec.maxColumns + 20, (i) => 'c$i').join(',');
      final doc = CsvCodec.parse('$header\n');
      expect(doc.header.length, CsvCodec.maxColumns);
      expect(doc.truncated, isTrue);
    });

    test('正好 100 列不报截断', () {
      final header = List<String>.generate(CsvCodec.maxColumns, (i) => 'c$i').join(',');
      final doc = CsvCodec.parse('$header\n');
      expect(doc.header.length, CsvCodec.maxColumns);
      expect(doc.truncated, isFalse);
    });

    test('超列时这一行剩下的分隔符不会误开新行', () {
      // 认列数超限之后若直接 break，剩下的逗号会被当成下一行的开头。
      final header = List<String>.generate(150, (i) => 'c$i').join(',');
      final doc = CsvCodec.parse('$header\n1,2\n');
      expect(doc.rows.length, 2);
      expect(_row(doc.rows[1]), _row(<String>['1', '2']));
    });

    test('截断的行数真的是上限那一行，不是少一行', () {
      final buf = StringBuffer();
      for (var i = 0; i < 6000; i++) {
        buf.writeln('row$i,x');
      }
      final doc = CsvCodec.parse(buf.toString());
      expect(doc.rows.length, CsvCodec.maxRows);
      expect(doc.rows.last.first, 'row${CsvCodec.maxRows - 1}');
    });
  });

  group('大输入不爆炸', () {
    test('5000 × 100 解析在几百毫秒内', () {
      final buf = StringBuffer();
      for (var r = 0; r < CsvCodec.maxRows; r++) {
        buf.writeln(List<String>.generate(100, (c) => 'r$r.c$c').join(','));
      }
      final sw = Stopwatch()..start();
      final doc = CsvCodec.parse(buf.toString());
      sw.stop();
      expect(doc.rows.length, CsvCodec.maxRows);
      expect(doc.columns, 100);
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });
  });
}
