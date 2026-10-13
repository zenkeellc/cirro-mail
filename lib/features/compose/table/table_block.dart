import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'table_html_codec.dart';
import 'table_model.dart';

/// 表格块要跟外界说的话。
///
/// 表格自己无法把自己换回文档里（它拿不到 `documentOffset` 之外的信息），
/// 所以把「换回去」做成回调，由 [MailTableEmbedBuilder] 提供 —— 于是网格控件
/// 本身可以在测试里单独驱动，不需要真编辑器。
class TableBlockCallbacks {
  const TableBlockCallbacks({
    required this.onChanged,
    this.onHtmlChanged,
    this.onRequestImageInCell,
  });

  /// 表格**结构**变了（插/删行、插/删列、切表头）。回调给新模型，由上层
  /// 整表重编码写回 —— 这是结构编辑，用户明确要求动结构，有损可以接受。
  final void Function(MailTableModel next) onChanged;

  /// 表格**文字**变了。带上「定点替换后的新 HTML」与「新模型」两份东西：
  /// 上层应当优先用 [onHtmlChanged] 里的 HTML 写回（它保住了没碰过的格子），
  /// 只在没有这个回调时才退回 [onChanged] 的整表重编码。
  ///
  /// 为什么文本编辑不能走整表重编码：模型是 `TableHtmlCodec.decode` 出来的，
  /// 那次解码是**有损**的（丢 `<br>`、拍平 colspan、trim 首尾空格、吞空 `<tr>`、
  /// 把嵌套表格的文字抹进外层格子）。拿它整表 encode 回去，就会把用户**没碰过**
  /// 的格子一起按有损结果重写（F-2）。文本编辑只该动被编辑的那一格。
  final void Function(String html, MailTableModel next)? onHtmlChanged;

  /// 单元格里想让用户插一张图（可选，本轮不实现，先留出接口位置）。
  final Future<String?> Function()? onRequestImageInCell;
}

/// `x-email-table` 的块控件：一个能编辑的网格 + 行列操作。
class MailTableBlock extends StatefulWidget {
  const MailTableBlock({
    super.key,
    required this.table,
    required this.callbacks,
    this.rawHtml,
    this.readOnly = false,
  });

  final MailTableModel table;
  final TableBlockCallbacks callbacks;

  /// 这一块**加载时拿到的原始 HTML**。文本编辑时用它做定点替换（见
  /// [editTableCellText]），于是没碰过的格子逐字保真。为 null 时退回整表
  /// 重编码（旧行为）。
  final String? rawHtml;

  final bool readOnly;

  @override
  State<MailTableBlock> createState() => _MailTableBlockState();
}


class _MailTableBlockState extends State<MailTableBlock> {
  /// 选中的格子，形如 `"1,0"`。选中态决定出现哪一组操作按钮。
  String? _active;

  MailTableModel get _table => widget.table;

  void _emit(MailTableModel next) => widget.callbacks.onChanged(next);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.readOnly && _active != null) _rowActions(theme),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const FixedColumnWidth(140),
              border: TableBorder.all(color: theme.dividerColor, width: 1),
              children: [
                for (var r = 0; r < _table.rowCount; r++)
                  TableRow(
                    children: [
                      for (var c = 0; c < _table.columnCount; c++)
                        _cell(context, r, c),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, int row, int column) {
    final key = '$row,$column';
    final isHeader = _table.hasHeaderRow && row == 0;
    final selected = _active == key;
    return Container(
      key: ValueKey('table-cell-$key'),
      // 颜色永远不是 null（未选中时是 `Colors.transparent`）。
      //
      // `Container(color: null)` 与 `Container(color: 有颜色)` 生成的子树
      // **形状不同**：前者没有 `ColoredBox` 那一层，后者有。于是「点一下格子、
      // 选中态一变」就等于在格子和它的孩子之间**插进一层** —— Flutter 无法
      // 就地更新，只能把孩子整棵重建，`_CellEditor` 的 State（连同平台的文本
      // 输入连接）一起重来。
      //
      // 后果是「点了格子，光标却不在格子里」：那次点击的 `onTap` 正是把
      // `_active` 改成这个格子的东西，它一改，被点中的 `TextField` 就被重建掉
      // 了。探针实测：颜色恒为一个值 → 点得进去（`hasFocus=true`）；在
      // null / 非 null 之间切 → 点不进去（`hasFocus=false`）。
      //
      // 顺带一提，`Column` 那两个孩子在 `_active` 一变时也会错位（第 0 个槽位
      // 从 `SingleChildScrollView` 变成操作栏的 `Padding`）。实测它的影响被
      // `Table`/`TableRow`/`Text` 的 element 复用吃掉了，但**顺序仍然脆**：
      // 操作栏一旦不再是无状态小 widget，这里就会以同样的方式咬回来。所以
      // 新增/调整这两个孩子时，先想一遍「它们换位置时 evict 的是谁」。
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: _CellEditor(
        // key **只含行列，不含内容**。这是 F-1 的关键：早先 key 里塞了
        // `_table.cellAt(...)`，内容一变 key 就变 → element 被销毁重建 →
        // 旧 `TextField` 的平台文本输入连接被关掉，「下一次按键」全被吞
        // （逐键 `updateEditingValue` 实测：`a b c` 只留下 `a`）。
        // Flutter 官方也点名过：不要把模型数据放进 widget 的 key。
        // 内容的外部变化改由 [_CellEditorState.didUpdateWidget] 同步。
        key: ValueKey('table-cell-content-$key'),
        initial: _table.cellAt(row, column),
        bold: isHeader,
        readOnly: widget.readOnly,
        // 选中态由**单元格自己的点击**驱动，不在外面套 GestureDetector ——
        // `TextField` 会赢下点击手势，外面那层的 onTap 根本不会触发。
        onTap: widget.readOnly ? null : () => setState(() => _active = key),
        onChanged: (value) {
          if (value == _table.cellAt(row, column)) return;
          final next = _table.withCell(row, column, value);
          // **文本编辑走定点替换**：只改被编辑的那一格，没碰过的格子逐字保真。
          // 拿不到原始 HTML（或它已经不含表格）时退回整表重编码。
          final raw = widget.rawHtml;
          final html = raw == null
              ? null
              : editTableCellText(raw, row, column, value);
          if (html != null && html != raw) {
            widget.callbacks.onHtmlChanged?.call(html, next);
            if (widget.callbacks.onHtmlChanged == null) _emit(next);
            return;
          }
          _emit(next);
        },
      ),
    );
  }

  Widget _rowActions(ThemeData theme) {
    final parts = _active!.split(',');
    final row = int.parse(parts[0]);
    final column = int.parse(parts[1]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 4,
        children: [
          _action('上方插行', () => _emit(_table.insertRow(row))),
          _action('下方插行', () => _emit(_table.insertRow(row + 1))),
          _action(
            '删本行',
            _table.rowCount <= 1 ? null : () => _emit(_table.removeRow(row)),
          ),
          _action('左侧插列', () => _emit(_table.insertColumn(column))),
          _action('右侧插列', () => _emit(_table.insertColumn(column + 1))),
          _action(
            '删本列',
            _table.columnCount <= 1 ? null : () => _emit(_table.removeColumn(column)),
          ),
          _action(
            _table.hasHeaderRow ? '取消表头' : '首行当表头',
            () => _emit(_table.copyWith(hasHeaderRow: !_table.hasHeaderRow)),
          ),
        ],
      ),
    );
  }

  Widget _action(String label, VoidCallback? onPressed) => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );
}

/// 单元格里的极简编辑器。
///
/// 这里**不**用 `q.QuillEditor` —— 它的最小形态也要 `ScrollController` 与
/// `FocusNode`，一格一套在稍大的表上就会明显吃资源。单元格本轮只做纯文本，
/// 与 `MailTableModel` 的形状一致（模型里单元格就是字符串）。
class _CellEditor extends StatefulWidget {
  const _CellEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    this.onTap,
    this.bold = false,
    this.readOnly = false,
  });

  final String initial;
  final ValueChanged<String> onChanged;
  final VoidCallback? onTap;
  final bool bold;
  final bool readOnly;

  @override
  State<_CellEditor> createState() => _CellEditorState();
}

class _CellEditorState extends State<_CellEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  /// 我上一次**发出去**的文本（`onChanged` 给出去的那个）。
  ///
  /// 用来区分两种 `widget.initial` 变化：
  /// - 等于它 → 是我自己打字引起的回流，**别动 controller**（动了就是跟 IME
  ///   抢，光标会跳、拼音会断）；
  /// - 不等于它 → 是**外部**改动（结构操作、写回导致的模型重建），此时才
  ///   adopt：把文本换掉、光标放到末尾。
  String _lastEmitted = '';

  @override
  void initState() {
    super.initState();
    _lastEmitted = widget.initial;
  }

  @override
  void didUpdateWidget(_CellEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // key 现在稳定了，外部改动不会重建 element，得在这里手动 adopt。
    if (widget.initial != _lastEmitted && widget.initial != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.initial,
        selection: TextSelection.collapsed(offset: widget.initial.length),
      );
      _lastEmitted = widget.initial;
    }
  }

  void _onChanged(String value) {
    _lastEmitted = value;
    widget.onChanged(value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _controller,
        readOnly: widget.readOnly,
        maxLines: null,
        // 单元格里按回车**不该**换行（换行会让表长得没法看），也不该提交 ——
        // 把换行吞掉，用户的回车交回给外层（在表格后新起一段）。
        textInputAction: TextInputAction.next,
        style: TextStyle(
          fontWeight: widget.bold ? FontWeight.w700 : FontWeight.w400,
          fontSize: 14,
        ),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onTap: widget.onTap,
        onChanged: _onChanged,
        onSubmitted: _onChanged,
      );
}

/// 在一段表格 HTML 里**定点替换**某个单元格的文本，其余部分逐字保留。
///
/// 为什么要它：`TableHtmlCodec.decode` 是有损的（丢 `<br>`、拍平 colspan、
/// trim 首尾空格、吞空 `<tr>`、把嵌套表格的文字抹进外层格子）。用户只改一个
/// 格子时，绝不能拿「有损解码的模型」整表重编码写回 —— 那会顺手改掉他**没碰**
/// 的格子（F-2）。这里是「文本编辑」那条路：只把目标格子的内容换掉。
///
/// 定位方式：用 `package:html` 解析，**递归遍历、遇到嵌套 `<table>` 不下钻**
/// 按文档序数到第 `row` 行里的第 `column` 个 `td`/`th`。
/// 注意**不能**用 `querySelectorAll('td')` —— 它会把内层表格的格子也数进来。
///
/// 返回 null 表示「做不了定点替换」（不是表格 HTML、下标越界），调用方退回
/// 整表重编码；返回原串表示「值没变」。
@visibleForTesting
String? editTableCellText(String html, int row, int column, String value) {
  dom.Element? table;
  try {
    final fragment = html_parser.parseFragment(html);
    for (final node in fragment.nodes) {
      if (node is dom.Element && node.localName?.toLowerCase() == 'table') {
        table = node;
        break;
      }
    }
  } on Object {
    return null;
  }
  final tableEl = table;
  if (tableEl == null) return null;

  // 收集顶层行 —— 只在 table/thead/tbody/tfoot/tr 这几层里走，不下钻进内层表。
  dom.Element? target;
  var r = 0;
  for (final rowEl in _topLevelRows(tableEl)) {
    if (r == row) {
      final cells = rowEl.children.where((c) {
        final tag = c.localName?.toLowerCase();
        return tag == 'td' || tag == 'th';
      }).toList();
      if (column >= 0 && column < cells.length) target = cells[column];
      break;
    }
    r++;
  }
  if (target == null) return null;

  // 换了文本之后**没有子元素**：`<br>`/内嵌标签一并清掉，只留纯文本，
  // 序列化时由 DOM 负责转义（`a < b` → `a &lt; b`）。
  if (target.nodes.length == 1 &&
      target.nodes.single is dom.Text &&
      (target.nodes.single as dom.Text).text == value) {
    return html; // 值没变，别白写一遍
  }
  target.nodes
    ..clear()
    ..add(dom.Text(value));

  // 还原成「那段原始 HTML 中的 table 子树」—— 用 table 自己的 outerHtml，
  // 而不是整个 fragment，避免把 fragment 之外/解析器补的节点带进来。
  final newTable = tableEl.outerHtml;
  final start = _indexOfTable(html);
  if (start < 0) return null;
  final end = start + _tableSourceLength(html, start);
  return html.substring(0, start) + newTable + html.substring(end);
}

/// 顶层 `<tr>`（在 table/thead/tbody/tfoot 里），遇到**内层 `<table>` 不下钻**。
Iterable<dom.Element> _topLevelRows(dom.Element table) {
  final rows = <dom.Element>[];
  void walk(dom.Element el) {
    for (final child in el.children) {
      final tag = child.localName?.toLowerCase();
      if (tag == 'tr') {
        rows.add(child);
      } else if (tag == 'thead' || tag == 'tbody' || tag == 'tfoot') {
        walk(child);
      }
      // 其余（含内层 <table>）一概不下钻。
    }
  }

  walk(table);
  return rows;
}

/// 原始 HTML 里第一个 `<table` 的位置。
int _indexOfTable(String html) {
  final match = RegExp(r'<table\b', caseSensitive: false).firstMatch(html);
  return match?.start ?? -1;
}

/// 原始 HTML 里那段 table 的**源码长度**（含配对 `</table>`）。
///
/// 用一层标签计数来找收尾：`<table>` 与 `</table>` 各自计一次（注释/CDATA
/// 在邮件正文里不存在，不处理）。找不到收尾就取到串尾。
int _tableSourceLength(String html, int start) {
  final tagRe = RegExp(r'</?table\b[^>]*>', caseSensitive: false);
  var depth = 0;
  for (final m in tagRe.allMatches(html, start)) {
    if (m.group(0)!.startsWith('</')) {
      depth--;
    } else {
      depth++;
    }
    if (depth == 0) return m.end - start;
  }
  return html.length - start;
}


/// `x-email-table` 的嵌入构建器：把块里的 HTML 解成模型、渲染网格，
/// 网格一变就把新 HTML **写回文档**。
class MailTableEmbedBuilder extends q.EmbedBuilder {
  const MailTableEmbedBuilder({
    required this.controller,
    required this.callbacks,
    this.focusParent,
  });

  final q.QuillController controller;
  final TableBlockCallbacks callbacks;

  /// 表格里那些输入框挂在**哪个焦点节点**下面。
  ///
  /// 传 `null`（默认）时就走控件树的形状 —— 单元格输入框是正文编辑器的后代。
  /// 那会带来「两根光标」：`FocusNode.hasFocus` 带了「主焦点是我的后代也算」
  /// 这一条，于是点进单元格之后正文的 `hasFocus` **仍然是 true**，正文那根
  /// 光标（光标落在表格那一行时它跟表格一样高）与单元格的光标同时画在屏幕上。
  ///
  /// 传一个正文编辑器**之外**的节点（`MailQuillEditor._embedFocusHost`）就
  /// 把两者在焦点树上拆成兄弟，正文的 `hasFocus` 随之变 false、光标不再画。
  /// 完整推导见 `MailQuillEditor` 里那个字段的注释。
  ///
  /// 只在真的挂着编辑器时才有意义；单测里直接 `build` 出来渲染时留空即可。
  final FocusNode? focusParent;

  @override
  String get key => tableEmbedType;

  /// **不要**让表格走「独占一行、撑满宽度」那条路（`expanded = true`，
  /// `EmbedBuilder` 的默认值）。
  ///
  /// 为什么：`expanded: true` 时 flutter_quill 把嵌入交给 `EmbedProxy`，
  /// 而 `RenderEmbedProxy` 的光标高度就是**控件的整个高度** ——
  /// `getFullHeightForCaret(...) => size.height`、`preferredLineHeight =>
  /// size.height`（`proxy.dart:110,128`）。光标落在表格那一行时，正文那根
  /// 光标就变成一条**跟表格一样高**的竖条贴在表格左侧，正是用户报的
  /// 「表格左侧有个跟表格高度一样的光标」。
  ///
  /// 取 `false` 时嵌入画在 `RichText` 里（`text_line.dart:155` 走另一条路），
  /// 光标高度回到正常的行高。探针实测（2 列 / 6 列两种表）：光标矩形从
  /// `0,0,2,82`（82 = 表格高）变成 `0,66,2,84`（18 = 行高），没有异常。
  ///
  /// 代价：表格宽度回到**内容宽度**（不再撑满正文区），超宽的表格仍由
  /// [MailTableBlock] 自带的横向滚动承担。
  @override
  bool get expanded => false;

  /// 纯文本摘要里表格的位置。
  @override
  String toPlainText(q.Embed node) => '[表格]';

  @override
  Widget build(BuildContext context, q.EmbedContext embedContext) {
    final raw = embedContext.node.value.data;
    final html = raw is String ? raw : '';
    final model = TableHtmlCodec.decode(html) ??
        MailTableModel(cells: [
          ['', ''],
        ]);
    final block = MailTableBlock(
      table: model,
      // 把**原始 HTML** 传下去：文本编辑要靠它做定点替换，保住没碰过的格子。
      rawHtml: html,
      callbacks: TableBlockCallbacks(
        // 结构编辑：整表重编码可接受（用户明确要求改结构）。代价是 colspan /
        // 嵌套表格会在这一步丢失 —— 这是「结构编辑」与「文本编辑」分开的取舍。
        onChanged: (next) => _writeBack(embedContext, TableHtmlCodec.encode(next)),
        // 文本编辑：写回的是定点替换后的 HTML，没碰过的格子逐字保真。
        onHtmlChanged: (nextHtml, _) => _writeBack(embedContext, nextHtml),
        onRequestImageInCell: callbacks.onRequestImageInCell,
      ),
    );
    final parent = focusParent;
    if (parent == null) return block;
    // 见 [focusParent]。`canRequestFocus: false` + `skipTraversal: true`：
    // 这一层只是焦点树上的挂点，不参与到聚焦与 Tab 遍历里。
    return Focus(
      parentNode: parent,
      canRequestFocus: false,
      skipTraversal: true,
      child: block,
    );
  }

  /// 把新表格 HTML 写回文档。
  ///
  /// 三件事必须同时做对，否则文档会坏掉（§0.2 第 6 条）：
  /// 1. 替换的是**嵌入那一个字符**（长度 1），不是整块的 HTML；
  /// 2. 换上去的仍是 `CustomBlockEmbed` 而不是裸 Map —— 裸 Map 走的是
  ///    `Embeddable` 的解析路径，行为与注册的 builder 对不上；
  /// 3. 光标落到嵌入之后 —— 落到嵌入里（offset 不变）会让编辑器认为
  ///    光标嵌在一个不可编辑的对象内部。
  void _writeBack(q.EmbedContext embedContext, String encoded) {
    final offset = embedContext.node.documentOffset;
    controller.replaceText(
      offset,
      1,
      q.BlockEmbed(tableEmbedType, encoded),
      TextSelection.collapsed(offset: offset + 1),
    );
  }
}

/// 表格块在 Delta 里的类型名。**只此一处定义** —— 导入端（`mail_html_to_delta`）、
/// 导出端（`delta_to_email_html`）与这里的注册都必须用同一个串。
const String tableEmbedType = 'x-email-table';
