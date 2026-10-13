import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

import '../html/mail_html_to_delta.dart';
import '../table/table_model.dart';
import 'slash_command.dart';

/// 斜杠菜单 / 「+」菜单里每个条目**能做的事**。
///
/// 为什么把「条目定义」和「界面」分开：同一份定义要给两个入口用（空行敲 `/`
/// 与底部常驻「+」，spec §3.5 明确要求），而两处的界面形态完全不同 —— 一个是
/// 跟着光标的浮层，一个是底部弹出面板。定义抽在这里，界面各自实现。
class SlashActionEntry {
  const SlashActionEntry({
    required this.item,
    required this.icon,
    required this.label,
  });

  final SlashItem item;
  final IconData icon;
  final String label;

  /// 部分条目要异步（插图、AI 起草要弹面板），所以一律是 Future。
  Future<void> Function(SlashContext context) get run => _runners[item]!;
}

/// 条目筛选：斜杠菜单与底部面板的**唯一**过滤出处。
///
/// 「两个入口、一份定义」里的后半句。早先这十来行只写在 `slash_menu.dart` 里，
/// 于是底部面板要过滤 AI 时只能在调用点手写一份 `where(...)` —— 加个新条件时
/// 两处必须同时改，漏一处就会出现「斜杠菜单里没有、底部面板里有」这种只在
/// 入口之间才看得出来不一致。
///
/// 两条判据都要走：
/// 1. [SlashCommand.filter] 的**关键字表**（英文缩写、中文近义词，如 `h1`、
///    标题、项目符号）；
/// 2. 条目自己的**标签**（`标题` 这两个字本身）。关键字表与标签是两处独立
///    维护的，用户直接敲标签时只靠关键字表会漏（`/标题` 能中，但 `/大标题`
///    只在标签里能中）。
List<SlashActionEntry> filterSlashEntries(String query, {bool allowAi = true}) {
  final allowed = SlashCommand.filter(query, allowAi: allowAi);
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return slashEntries.where((e) => allowed.contains(e.item)).toList();
  }
  return slashEntries.where((entry) {
    if (allowed.contains(entry.item)) return true;
    if (!allowAi && entry.item == SlashItem.aiDraft) return false;
    return entry.label.toLowerCase().contains(needle);
  }).toList();
}

/// 执行一次菜单条目时手头有的东西。
class SlashContext {
  const SlashContext({
    required this.controller,
    required this.focusNode,
    required this.onInsertTable,
    required this.onPickImage,
    required this.onAiDraft,
  });

  final q.QuillController controller;
  final FocusNode focusNode;

  /// 插入一张 n×m 的空表格。由页面实现（要建模型、要编码成 HTML）。
  final void Function(int rows, int columns) onInsertTable;

  /// 让用户选一张图并内联进来。由页面实现（额度在页面手里）。
  final Future<void> Function() onPickImage;

  /// 打开 AI 起草面板。
  final Future<void> Function() onAiDraft;
}

/// 一键回到「普通正文」：**块级属性与行内属性一起清**。
///
/// 为什么不能只清块级（早先 `SlashItem.paragraph` 就是这么做的）：用户从一个
/// **加粗的标题**上点「清除格式」，只清掉 `header` 的话那行字还是粗的 ——
/// 他点的是「清除格式」，不是「退回正文」。反过来的取舍是它会连**链接**一起
/// 清掉（链接也是行内属性）：这是「清除格式」这个词的通行含义，且链接有单独
/// 的按钮可以加回来。
///
/// 行内那一半的写法照上游 `QuillToolbarClearFormatButton`：把
/// [q.QuillController.getAllSelectionStyles] 里出现的属性逐个 `clone(…, null)`。
/// 不用一份写死的行内属性清单 —— 清单漏一项就会留一种清不掉的格式，而
/// `getAllSelectionStyles` 是从**实际文档**里读的。
void clearFormatting(q.QuillController controller) {
  for (final attr in const [
    q.Attribute.h1,
    q.Attribute.h2,
    q.Attribute.h3,
    q.Attribute.ul,
    q.Attribute.ol,
    q.Attribute.blockQuote,
    q.Attribute.codeBlock,
    q.Attribute.leftAlignment,
    q.Attribute.centerAlignment,
    q.Attribute.rightAlignment,
    q.Attribute.justifyAlignment,
  ]) {
    controller.formatSelection(q.Attribute.clone(attr, null));
  }
  final seen = <String>{};
  for (final style in controller.getAllSelectionStyles()) {
    for (final attr in style.attributes.values) {
      // 引用区的行尾标记（`mail-quote`）**不在**「格式」的范畴里：它只说
      // 「这行是从旧邮件里引用来的」，不是用户排版出来的。清掉它等于把
      // [ComposeQuote] 的边界抹平 —— 下一次润色就会把引用一起改写
      // （那正是用户报的那个 bug），而且现象很安静。跳过它。
      if (attr.key == MailHtmlToDelta.quoteAttribute) continue;
      // 同一个属性会在多个 style 里重复出现（`getAllSelectionStyles` 是
      // 逐段收集的），按 key 去重 —— 重复 `formatSelection` 只是白跑一遍。
      if (!seen.add(attr.key)) continue;
      controller.formatSelection(q.Attribute.clone(attr, null));
    }
  }
}

/// 条目 → 动作。**用 switch 而不是在枚举上挂字段**：动作需要 `BuildContext`
/// 之外的一堆依赖（额度、面板），放在枚举里会让 `slash_command.dart` 从
/// 纯逻辑变成必须 import flutter。
Future<void> _apply(SlashContext context, SlashItem item) async {
  final controller = context.controller;
  switch (item) {
    case SlashItem.paragraph:
      // 「正文」要把**所有**块级属性清掉 —— 用户从标题退回普通段落时，
      // 漏掉一个（比如 `code-block`）就会得到「标题清掉了但还是等宽字体」。
      controller.formatSelection(q.Attribute.clone(q.Attribute.h1, null));
      controller.formatSelection(q.Attribute.clone(q.Attribute.h2, null));
      controller.formatSelection(q.Attribute.clone(q.Attribute.h3, null));
      controller.formatSelection(q.Attribute.clone(q.Attribute.ul, null));
      controller.formatSelection(q.Attribute.clone(q.Attribute.ol, null));
      controller.formatSelection(q.Attribute.clone(q.Attribute.blockQuote, null));
      controller.formatSelection(q.Attribute.clone(q.Attribute.codeBlock, null));
      _focus(context);
    case SlashItem.heading1:
      controller.formatSelection(q.Attribute.h1);
      _focus(context);
    case SlashItem.heading2:
      controller.formatSelection(q.Attribute.h2);
      _focus(context);
    case SlashItem.heading3:
      controller.formatSelection(q.Attribute.h3);
      _focus(context);
    case SlashItem.bulletList:
      controller.formatSelection(q.Attribute.ul);
      _focus(context);
    case SlashItem.orderedList:
      controller.formatSelection(q.Attribute.ol);
      _focus(context);
    case SlashItem.quote:
      controller.formatSelection(q.Attribute.blockQuote);
      _focus(context);
    case SlashItem.codeBlock:
      controller.formatSelection(q.Attribute.codeBlock);
      _focus(context);
    case SlashItem.divider:
      // 分隔线在邮件安全子集里就是一条 `<hr>`。用一段只有 `<hr>` 的
      // 段落表达，导出时自然落成 `<hr>`（见 `delta_to_email_html`）。
      insertParagraphText(controller, '---');
      _focus(context);
    case SlashItem.table:
      context.onInsertTable(defaultTableRows, defaultTableColumns);
    case SlashItem.image:
      await context.onPickImage();
    case SlashItem.aiDraft:
      await context.onAiDraft();
  }
}

/// 把光标放回编辑器。**每次动作之后都要做** —— 点了菜单条目以后焦点在
/// 菜单上，不还回去的话用户接着敲字会发现「按了没反应」。
void _focus(SlashContext context) {
  context.focusNode.requestFocus();
}

/// 在当前行插入一段文字（会先把当前行的**块级属性**清掉）。
///
/// 为什么必须清：`replaceText` 只换**行内文字**，收尾那个 `\n` 上的块级
/// op（`header` / `list` / `code-block` / `blockquote`）会原样留着 ——
/// 在 `h1` 行插「分隔线」就会得到一条**仍带 `header:1` 的 `---`**（F-8）。
/// 导出端（`delta_to_html`）靠 `html == '---'` 认分隔线，属性残留让它落到
/// 未验证的分支，结构上有风险。
///
/// 清的范围要**含行尾那个 `\n`**：块级属性就挂在它上面，只选行内文字
/// （`[start, start+len)`）清不掉（`test/slash_actions_test.dart` 那组用例就是
/// 按这个范围钉的：只清行内文字时它们会红）。清完再 `replaceText` 写回
/// `$text\n`，新行的 `\n` 就是干净的。
///
/// **多行文本（签名/常用语）也走这一条**：`text` 里的 `\n` 会被 Quill 拆成
/// 多个段落，块级属性清干净之后新段落都是普通正文。清属性的范围由
/// `test/slash_actions_test.dart` 的「分隔线（F-8：插之前要先清掉当前行的
/// 块属性）」那一组钉着 —— 分隔线走的就是这条路径（`_apply` →
/// `insertParagraphText`），正文 / h1 行 / 列表行 / 代码块行四种起点各一条，
/// 与这里清的是同一段范围。
///
/// **多行那一半现在也有专门用例了**：`test/writing_snippets_test.dart` 的
/// 「插入到光标处」组 —— 空文档整段插、标题行、列表行三种起点各一条，
/// 走的都是这条路径。原先写的「单段那四种起点推不出多段也成立」已经不成立，
/// 多行那半支是**实测过**的，不再靠推导。
///
/// **这条函数真正的锋面：它替换的是「当前行整行的文字」**
/// （`replaceText(line.start, line.text.length, …)`），**不是「在光标处插一段」**。
/// 这里的「整行」是 `line.text`，而它是 `getPlainText(0, caret)` 在最后一个
/// `\n` 处切出来的 —— 也就是**光标之前**那半段，`replaceText` 覆盖的因此是
/// `[line.start, caret)`：直接拿它当「在光标处插一段」用，会吃掉**光标之前
/// 的字**。
/// `test/writing_snippets_test.dart` 里「光标在一行中间」那两条钉的就是这个
/// （修之前，写完一句话在行尾点「签名」，整句话都会没）。签名/常用语那条路径
/// 因此**先断行**再调用它（`snippet_insert.dart` 的 `_breakLineAtCaret`）。
void insertParagraphText(q.QuillController controller, String text) {
  final line = SlashCommand.currentLine(controller);
  final lineEnd = (line.start + line.text.length + 1).clamp(
    0,
    controller.document.length,
  );
  if (lineEnd > line.start) {
    controller.updateSelection(
      TextSelection(baseOffset: line.start, extentOffset: lineEnd),
      q.ChangeSource.local,
    );
    for (final attr in const [
      q.Attribute.h1,
      q.Attribute.h2,
      q.Attribute.h3,
      q.Attribute.ul,
      q.Attribute.ol,
      q.Attribute.blockQuote,
      q.Attribute.codeBlock,
    ]) {
      controller.formatSelection(q.Attribute.clone(attr, null));
    }
  }
  controller.replaceText(
    line.start,
    line.text.length,
    '$text\n',
    null,
  );
  controller.updateSelection(
    TextSelection.collapsed(offset: line.start + text.length + 1),
    q.ChangeSource.local,
  );
}

final Map<SlashItem, Future<void> Function(SlashContext)> _runners = {
  for (final item in SlashItem.values)
    item: (context) => _apply(context, item),
};

/// 每个条目的图标与文案。**中英混排**：文案跟着 l10n 走会拖进一个
/// `AppLocalizations` 依赖，而这一层是纯展示定义 —— 文案在调用方注入更好，
/// 但那样每个条目都要传一次。这里的取舍是**内置中文**，设置页与界面文案
/// 走 l10n（那才是用户会反复看到的地方）。
const List<SlashActionEntry> slashEntries = <SlashActionEntry>[
  SlashActionEntry(item: SlashItem.paragraph, icon: Icons.notes, label: '正文'),
  SlashActionEntry(item: SlashItem.heading1, icon: Icons.looks_one, label: '大标题'),
  SlashActionEntry(item: SlashItem.heading2, icon: Icons.looks_two, label: '标题'),
  SlashActionEntry(item: SlashItem.heading3, icon: Icons.looks_3, label: '小标题'),
  SlashActionEntry(
      item: SlashItem.bulletList, icon: Icons.format_list_bulleted, label: '项目符号'),
  SlashActionEntry(
      item: SlashItem.orderedList, icon: Icons.format_list_numbered, label: '编号列表'),
  SlashActionEntry(item: SlashItem.quote, icon: Icons.format_quote, label: '引用'),
  SlashActionEntry(item: SlashItem.codeBlock, icon: Icons.code, label: '代码块'),
  SlashActionEntry(item: SlashItem.divider, icon: Icons.horizontal_rule, label: '分隔线'),
  SlashActionEntry(
      item: SlashItem.table, icon: Icons.table_chart_outlined, label: '表格'),
  SlashActionEntry(item: SlashItem.image, icon: Icons.image_outlined, label: '图片'),
  SlashActionEntry(item: SlashItem.aiDraft, icon: Icons.auto_awesome, label: 'AI 起草'),
];

/// 新表格的默认尺寸。3×3 是「够用又不吓人」的甜点：2×2 常常不够，
/// 而让用户先选行列（像 Word 那样）在手机上很难点。
const int defaultTableRows = 3;
const int defaultTableColumns = 3;

MailTableModel emptyTable({
  int rows = defaultTableRows,
  int columns = defaultTableColumns,
}) =>
    MailTableModel(cells: [
      for (var r = 0; r < rows; r++) List<String>.filled(columns, ''),
    ]);
