/// 表格的纯数据模型。
///
/// 与 UI、与 HTML 都无关 —— 这两个方向的转换各有一个专门的编解码器
/// （`table_html_codec.dart`），所以模型本身可以单独测。
class MailTableModel {
  /// 注意：入参 `cells` 会**补齐成矩形**（列数取所有行的最大长度，短行用空串
  /// 填），空 `cells` 则是 0 列。进入模型后 `cells` 永远是矩形。
  ///
  /// 为什么要在这里补：`copyWith(cells: 锯齿)` 是公开路径，而 `cellAt` /
  /// `withCell` / `insertColumn` / `removeColumn` 都以「每行等长」为前提，
  /// 短行会让它们索引越界（`RangeError`）。与其在四个方法里各加一层防御，
  /// 不如在构造这一步把不变量钉死 —— 下游自动正确。
  MailTableModel({
    required List<List<String>> cells,
    List<int>? widths,
    this.hasHeaderRow = false,
  })  : cells = _rectangularize(cells),
        widths = List<int>.generate(
          _maxColumns(cells),
          (c) => (widths != null && c < widths.length && widths[c] > 0)
              ? widths[c]
              : _defaultWidth,
        );

  /// 每行每列的纯文本。行数 >= 1、列数 >= 1 由构造保证。矩形不变量见构造函数。
  final List<List<String>> cells;

  /// 每列宽度（像素）。长度永远与 [columnCount] 一致。
  final List<int> widths;

  /// 首行是否当表头（渲染成 `<th>`，加粗）。
  final bool hasHeaderRow;

  static const int _defaultWidth = 120;
  static const int _minWidth = 40;

  /// 每行补齐到最长行的长度。空 `cells` → 0 列。
  static List<List<String>> _rectangularize(List<List<String>> cells) {
    final columns = _maxColumns(cells);
    return List<List<String>>.generate(cells.length, (r) {
      final row = List<String>.from(cells[r]);
      while (row.length < columns) {
        row.add('');
      }
      return row;
    });
  }

  static int _maxColumns(List<List<String>> cells) {
    var max = 0;
    for (final row in cells) {
      if (row.length > max) max = row.length;
    }
    return max;
  }

  int get rowCount => cells.length;
  int get columnCount => cells.isEmpty ? 0 : cells.first.length;

  String cellAt(int row, int column) =>
      (row >= 0 && row < rowCount && column >= 0 && column < columnCount)
          ? cells[row][column]
          : '';

  MailTableModel copyWith({
    List<List<String>>? cells,
    List<int>? widths,
    bool? hasHeaderRow,
  }) =>
      MailTableModel(
        cells: cells ?? this.cells,
        widths: widths ?? this.widths,
        hasHeaderRow: hasHeaderRow ?? this.hasHeaderRow,
      );

  MailTableModel withCell(int row, int column, String value) {
    if (row < 0 || row >= rowCount || column < 0 || column >= columnCount) {
      return this;
    }
    final next = cells.map(List<String>.from).toList();
    next[row][column] = value;
    return copyWith(cells: next);
  }

  /// 在某行**之前**插入一行（`at == rowCount` 即追加到末尾）。
  MailTableModel insertRow(int at) {
    final index = at.clamp(0, rowCount);
    final next = cells.map(List<String>.from).toList()
      ..insert(index, List<String>.filled(columnCount, ''));
    return copyWith(cells: next);
  }

  /// 删掉一行。**最后一行不许删** —— 空表格没有意义，UI 上那个按钮也该置灰。
  MailTableModel removeRow(int at) {
    if (rowCount <= 1 || at < 0 || at >= rowCount) return this;
    final next = cells.map(List<String>.from).toList()..removeAt(at);
    return copyWith(cells: next);
  }

  MailTableModel insertColumn(int at) {
    final index = at.clamp(0, columnCount);
    final next =
        cells.map((row) => List<String>.from(row)..insert(index, '')).toList();
    final nextWidths = List<int>.from(widths)..insert(index, _defaultWidth);
    return copyWith(cells: next, widths: nextWidths);
  }

  /// 删掉一列。最后一列同样不许删。
  MailTableModel removeColumn(int at) {
    if (columnCount <= 1 || at < 0 || at >= columnCount) return this;
    final next =
        cells.map((row) => List<String>.from(row)..removeAt(at)).toList();
    final nextWidths = List<int>.from(widths)..removeAt(at);
    return copyWith(cells: next, widths: nextWidths);
  }

  MailTableModel withWidth(int column, int width) {
    if (column < 0 || column >= columnCount) return this;
    final next = List<int>.from(widths);
    next[column] = width < _minWidth ? _minWidth : width;
    return copyWith(widths: next);
  }

  /// 全是空单元格 —— 表格块**不表示**这种状态（等于没有表格）。
  bool get isEmpty =>
      cells.every((row) => row.every((cell) => cell.trim().isEmpty));
}
