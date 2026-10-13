import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/table/table_html_codec.dart';
import 'package:mail_app/features/compose/table/table_model.dart';

void main() {
  MailTableModel twoByTwo() =>
      MailTableModel(cells: [['甲', '乙'], ['丙', '丁']]);

  test('构造：行数列数、默认列宽', () {
    final t = twoByTwo();
    expect(t.rowCount, 2);
    expect(t.columnCount, 2);
    expect(t.widths, [120, 120]);
    expect(t.cellAt(0, 1), '乙');
    expect(t.hasHeaderRow, isFalse);
  });

  test('构造会把入参复制一份（改原数组不影响模型）', () {
    final source = [['甲']];
    final t = MailTableModel(cells: source);
    source[0][0] = '改了';
    expect(t.cellAt(0, 0), '甲');
  });

  test('cellAt 越界返回空串，不抛', () {
    final t = twoByTwo();
    expect(t.cellAt(5, 5), '');
    expect(t.cellAt(-1, 0), '');
  });

  test('withCell 改一个格子，其余不动', () {
    final t = twoByTwo().withCell(1, 0, '戊');
    expect(t.cellAt(1, 0), '戊');
    expect(t.cellAt(0, 0), '甲');
  });

  test('withCell 越界 → 原样返回', () {
    final t = twoByTwo();
    expect(t.withCell(9, 9, 'x').cells, t.cells);
  });

  test('insertRow：在指定行之前插入一行空串', () {
    final t = twoByTwo().insertRow(1);
    expect(t.rowCount, 3);
    expect(t.cells[1], ['', '']);
    expect(t.cellAt(2, 0), '丙');
  });

  test('insertRow(rowCount) 追加到末尾', () {
    final t = twoByTwo().insertRow(2);
    expect(t.rowCount, 3);
    expect(t.cellAt(2, 0), '');
    expect(t.cells.last, ['', '']);
  });

  test('removeRow：删中间一行，后面的行往前补', () {
    final t = MailTableModel(cells: [['甲'], ['乙'], ['丙']]).removeRow(1);
    expect(t.rowCount, 2);
    expect(t.cellAt(0, 0), '甲');
    expect(t.cellAt(1, 0), '丙');
  });

  test('removeRow：最后一行不许删', () {
    final t = MailTableModel(cells: [['只']]);
    expect(t.removeRow(0).rowCount, 1);
  });

  test('insertColumn：所有行都插，列宽也插', () {
    final t = twoByTwo().insertColumn(1);
    expect(t.columnCount, 3);
    expect(t.widths, [120, 120, 120]);
    expect(t.cells[0], ['甲', '', '乙']);
    expect(t.cells[1], ['丙', '', '丁']);
  });

  test('removeColumn：所有行都删，列宽也删', () {
    final t = twoByTwo().removeColumn(0);
    expect(t.columnCount, 1);
    expect(t.widths, [120]);
    expect(t.cells[0], ['乙']);
  });

  test('removeColumn：最后一列不许删', () {
    final t = MailTableModel(cells: [['只']]);
    expect(t.removeColumn(0).columnCount, 1);
  });

  test('withWidth：改列宽，低于下限被拉起', () {
    final t = twoByTwo().withWidth(0, 300);
    expect(t.widths[0], 300);
    expect(t.widths[1], 120);
    expect(twoByTwo().withWidth(0, 1).widths[0], 40);
  });

  test('widths 长度永远等于 columnCount', () {
    var t = twoByTwo().insertColumn(0).removeRow(0).insertRow(0);
    expect(t.widths.length, t.columnCount);
    t = t.removeColumn(1);
    expect(t.widths.length, t.columnCount);
  });

  test('isEmpty：全是空串才算空', () {
    expect(MailTableModel(cells: [['', '  '], ['', '']]).isEmpty, isTrue);
    expect(MailTableModel(cells: [['', 'x']]).isEmpty, isFalse);
  });

  test('copyWith 保留未指定的字段', () {
    final t = twoByTwo().copyWith(hasHeaderRow: true);
    expect(t.hasHeaderRow, isTrue);
    expect(t.rowCount, 2);
  });

  test('锯齿 cells：构造补齐成矩形，行数列数按最长行', () {
    final t = MailTableModel(cells: [
      ['a', 'b'],
      ['c'],
    ]);
    expect(t.columnCount, 2);
    expect(t.rowCount, 2);
    expect(t.cells[1], ['c', '']);
    expect(t.cellAt(1, 1), '');
    expect(t.widths, [120, 120]);
  });

  test('锯齿 cells：cellAt 越界不抛（旧实现用首行长度判界会 RangeError）', () {
    final t = MailTableModel(cells: [
      ['a', 'b'],
      ['c'],
    ]);
    expect(() => t.cellAt(1, 1), returnsNormally);
    expect(() => t.cellAt(1, 5), returnsNormally);
  });

  test('锯齿 cells：withCell 生效且不抛', () {
    final t = MailTableModel(cells: [
      ['a', 'b'],
      ['c'],
    ]).withCell(1, 1, 'x');
    expect(t.cellAt(1, 1), 'x');
    expect(t.cells[1], ['c', 'x']);
    expect(t.cellAt(0, 1), 'b');
  });

  test('锯齿 cells：insertColumn / removeColumn 不越界', () {
    final t = MailTableModel(cells: [
      ['a', 'b'],
      ['c'],
    ]);
    final inserted = t.insertColumn(1);
    expect(inserted.columnCount, 3);
    expect(inserted.cells[1], ['c', '', '']);
    final removed = t.removeColumn(0);
    expect(removed.columnCount, 1);
    // 第 1 行原本是补齐后的 ['c','']，删掉第 0 列只剩补齐出来的空串。
    expect(removed.cells[1], ['']);
  });

  test('锯齿 cells：编码出的行列数正确（不丢也不多）', () {
    final t = MailTableModel(cells: [
      ['a', 'b'],
      ['c'],
    ]);
    final html = TableHtmlCodec.encode(t);
    expect(RegExp(r'<tr>').allMatches(html).length, 2);
    expect(RegExp(r'<td ').allMatches(html).length, 4);
    // 补出来的空格子编码成空内容，而不是抛异常。
    final back = TableHtmlCodec.decode(html)!;
    expect(back.columnCount, 2);
    expect(back.cells[1], ['c', '']);
  });
}
