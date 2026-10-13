import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/table/table_html_codec.dart';
import 'package:mail_app/features/compose/table/table_model.dart';

void main() {
  test('encode：够用的最小形状（表格样式 + 单元格样式）', () {
    final html = TableHtmlCodec.encode(MailTableModel(cells: [['甲', '乙']]));
    expect(html, startsWith('<table style="border-collapse:collapse;width:100%">'));
    expect(html, contains('<td style='));
    expect(html, contains('>甲</td>'));
    expect(html, contains('>乙</td>'));
    expect(html, endsWith('</table>'));
  });

  test('encode：列宽写进单元格样式', () {
    final html = TableHtmlCodec.encode(
      MailTableModel(cells: [['甲']], widths: [200]),
    );
    expect(html, contains('width:200px'));
  });

  test('encode：表头行用 th 且加粗', () {
    final html = TableHtmlCodec.encode(
      MailTableModel(cells: [['表头'], ['值']], hasHeaderRow: true),
    );
    expect(html, contains('<th'));
    expect(html, contains('font-weight:700'));
    expect(html, contains('<td'));
  });

  test('encode：单元格里的尖括号被转义（不然 HTML 会被掰坏）', () {
    final html = TableHtmlCodec.encode(
      MailTableModel(cells: [['<b>x</b>']]),
    );
    expect(html, contains('&lt;b&gt;x&lt;/b&gt;'));
    expect(html, isNot(contains('<b>x</b>')));
  });

  test('encode/decode 往返：单元格文本与列宽都保住', () {
    final original = MailTableModel(
      cells: [['甲', '乙'], ['丙', '']],
      widths: [160, 80],
    );
    final back = TableHtmlCodec.decode(TableHtmlCodec.encode(original))!;
    expect(back.cells, original.cells);
    expect(back.widths, original.widths);
    expect(back.rowCount, 2);
    expect(back.columnCount, 2);
  });

  test('decode：空串 / 没有 table → null（调用方据此不插表格）', () {
    expect(TableHtmlCodec.decode(''), isNull);
    expect(TableHtmlCodec.decode('   '), isNull);
    expect(TableHtmlCodec.decode('<p>没有表格</p>'), isNull);
    expect(TableHtmlCodec.decode('<table></table>'), isNull);
  });

  test('decode：colspan 被忽略（网格要真能编辑，合并单元格是另一套模型）', () {
    final model = TableHtmlCodec.decode(
      '<table><tr><td colspan="3">甲</td><td>乙</td></tr></table>',
    )!;
    expect(model.rowCount, 1);
    expect(model.columnCount, 2);
    expect(model.cells[0], ['甲', '乙']);
  });

  test('decode：行列补齐成矩形', () {
    final model = TableHtmlCodec.decode(
      '<table><tr><td>甲</td><td>乙</td><td>丙</td></tr>'
      '<tr><td>丁</td></tr></table>',
    )!;
    expect(model.columnCount, 3);
    expect(model.cells[1], ['丁', '', '']);
  });

  test('decode：thead 行被认出来', () {
    final model = TableHtmlCodec.decode(
      '<table><tr><th>表头</th><th>头二</th></tr><tr><td>值</td><td>二</td></tr></table>',
    )!;
    expect(model.hasHeaderRow, isTrue);
    expect(model.cells[0], ['表头', '头二']);
  });
  test('decode：宽度从 width 属性也能读', () {
    final model = TableHtmlCodec.decode(
      '<table><tr><td width="180">甲</td></tr></table>',
    )!;
    expect(model.widths, [180]);
  });

  test('decode：单元格文本前后空白被去掉（表格里的换行缩进是格式化噪音）', () {
    final model = TableHtmlCodec.decode(
      '<table>\n  <tr>\n    <td>\n      甲\n    </td>\n  </tr>\n</table>',
    )!;
    expect(model.cells[0][0], '甲');
  });

  test('decode：垃圾 HTML 不抛', () {
    for (final bad in [
      '<table><tr>',
      '<table><td>x</td></table>',
      '<tr><td>游离</td></tr>',
      '<<table>>',
    ]) {
      expect(() => TableHtmlCodec.decode(bad), returnsNormally, reason: bad);
    }
  });

  test('decode：<br> 是语义换行，不是格式噪音，要保住', () {
    final model = TableHtmlCodec.decode(
      '<table><tr><td>a<br>b</td><td>c</td></tr></table>',
    )!;
    expect(model.cellAt(0, 0), 'a\nb');
    expect(model.cellAt(0, 1), 'c');
  });

  test('decode：块级元素边界补换行（<p>a</p><p>b</p> → a\\nb）', () {
    final model = TableHtmlCodec.decode(
      '<table><tr><td><p>a</p><p>b</p></td></tr></table>',
    )!;
    expect(model.cellAt(0, 0), 'a\nb');
  });

  test('decode：连续 <br><br> 不产生超过一个空行', () {
    final model = TableHtmlCodec.decode(
      '<table><tr><td>a<br><br>b</td></tr></table>',
    )!;
    // 连续换行被折叠：绝不出现两个及以上的空行（即 3 个连续 '\n'）。
    expect(model.cellAt(0, 0), isNot(contains('\n\n\n')));
    expect(model.cellAt(0, 0), contains('a'));
    expect(model.cellAt(0, 0), contains('b'));
  });

  test('decode：缩进换行仍是格式噪音，被 trim 掉', () {
    final model = TableHtmlCodec.decode(
      '<table><tr><td>\n      甲\n    </td></tr></table>',
    )!;
    expect(model.cellAt(0, 0), '甲');
  });

  test('decode：缩进换行里夹<br>只保留一个语义换行', () {
    final model = TableHtmlCodec.decode(
      '<table><tr><td>\n  甲<br>\n  乙\n</td></tr></table>',
    )!;
    expect(model.cellAt(0, 0), '甲\n乙');
  });

  test('decode：列宽取自实际保留的第一行（首行空 tr 被跳过）', () {
    final model = TableHtmlCodec.decode(
      '<table><tr></tr><tr><td style="width:300px">a</td>'
      '<td style="width:80px">b</td></tr></table>',
    )!;
    expect(model.widths, [300, 80]);
    expect(model.cells, [
      ['a', 'b'],
    ]);
  });

  group('_widthOf 边界', () {
    int widthOf(String style) => TableHtmlCodec.decode(
          '<table><tr><td style="$style">a</td></tr></table>',
        )!
            .widths[0];

    test('max-width / min-width / border-width 不应被当成 width（左边界）', () {
      expect(widthOf('max-width:500px'), 120);
      expect(widthOf('min-width:80px'), 120);
      expect(widthOf('border-width:2px'), 120);
    });

    test('% 单位不是 px，不取（模型只存 px）', () {
      expect(widthOf('width:50%'), 120);
    });

    test('极端宽度被夹掉，不取', () {
      expect(widthOf('width:99999999999999px'), 120);
      expect(widthOf('width:10001px'), 120);
      expect(widthOf('width:10000px'), 10000);
    });

    test('正常 px / 无单位宽度仍能读', () {
      expect(widthOf('width:300px'), 300);
      expect(widthOf('width:300'), 300);
    });
  });

  test('decode：嵌套表格的 tr 会被捞平（已知限制，钉住行为）', () {
    // `table.querySelectorAll('tr')` 是**后代**查询，子表格的 tr 也会被
    // 捞出来。于是外层行与内层行被拍平成同一个序列；这里把当前语义逐字
    // 钉住，免得以后改动时无声漂移。
    //
    // 说明：本模型不支持嵌套表格（网格要真能编辑），所以不打算「修」它，
    // 只保证不抛、输出确定。
    final model = TableHtmlCodec.decode(
      '<table><tr><td><table><tr><td>内</td></tr></table></td></tr></table>',
    )!;
    expect(model.rowCount, 2);
    expect(model.columnCount, 1);
    // 外层的 td.text 会把内层文字一并拼进来，内层的 tr 也被当成一行。
    expect(model.cells, [
      ['内'],
      ['内'],
    ]);
  });

  test('decode：空表语义不对称（<table></table> → null），钉住现状', () {
    // `<table></table>`（一行都没有）返回 null；而 encode([['']]) 出来的
    // 单空格子表再 decode 是非 null。这个不对称是现状，不为了对称改行为。
    expect(TableHtmlCodec.decode('<table></table>'), isNull);
    expect(
      TableHtmlCodec.decode(TableHtmlCodec.encode(MailTableModel(cells: [['']]))),
      isNotNull,
    );
  });
}
