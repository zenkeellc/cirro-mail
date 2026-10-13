import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;

/// 斜杠菜单能插入的东西。**一份定义两处用**（空行敲 `/` 与底部「+」入口），
/// spec §3.5 要求的地方。
enum SlashItem {
  paragraph,
  heading1,
  heading2,
  heading3,
  bulletList,
  orderedList,
  quote,
  codeBlock,
  divider,
  table,
  image,
  aiDraft,
}

/// 空行行首敲 `/` 的检测结果。
class SlashTrigger {
  const SlashTrigger({required this.query, required this.start});

  /// `/` 之后已经敲进来的字 —— 菜单按它过滤。
  final String query;

  /// `/` 在文档里的偏移。清掉触发器时删的是 `[start, start + 1 + query.length)`。
  final int start;
}

/// 斜杠菜单的**判定逻辑**。与 UI 完全分开，于是「什么时候该弹、什么时候不该弹」
/// 这种很容易出错又很难手测的规则可以单测。
abstract final class SlashCommand {
  const SlashCommand._();

  /// 最多认这么多字符。再长就当作普通文本（用户在写 `/usr/local/bin`）。
  static const int maxQueryLength = 20;

  /// 当前状态该不该弹斜杠菜单；该弹的话查什么。
  ///
  /// 五条规则，缺一不可：
  /// 1. 选区**必须折叠** —— 选着一段字时敲 `/` 不该弹菜单；
  /// 2. 当前行不含**嵌入**（含就返回 null）—— 嵌入独占一行的不变量由插入侧
  ///    保证，而「一行里既有文字又有嵌入」这种形状本身就渲染不正常（嵌入被
  ///    当作 `￼` 混在文字里），它的行文本是 `ab￼…` 这样的拼接串，`/` 的
  ///    「行首」判据会被这种拼接糊弄过去，于是误弹。别在坏形状上弹菜单；
  /// 3. `/` 必须是**当前行开头**（前面最多只有空白）——
  ///    `A/B`、`http://`、`/usr/bin` 就此不会误触发；
  /// 4. `/` 与光标之间不能有空白 —— 敲了空格就说明是在写路径或日期；
  /// 5. 查询串不能过长（见 [maxQueryLength]）。
  static SlashTrigger? detect(q.QuillController controller) {
    final selection = controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;

    final line = currentLine(controller);
    // 嵌入渲染成 `￼`。含它 = 这一行不是纯文字行，规则 2。
    if (line.text.contains('￼')) return null;
    final trimmed = line.text.trimLeft();
    if (!trimmed.startsWith('/')) return null;

    final query = trimmed.substring(1);
    if (query.contains(RegExp(r'\s'))) return null;
    if (query.length > maxQueryLength) return null;

    return SlashTrigger(
      query: query,
      start: line.start + (line.text.length - trimmed.length),
    );
  }

  /// 光标所在行的内容与它的起点偏移。
  ///
  /// 说明：flutter_quill 没有直接给「当前行」的公开 API，`getPlainText(index,len)`
  /// 的第二个参数是**长度**不是终点（`document.dart:301`），所以这里统一用
  /// 「取光标前的全部文本、找最后一个 `\n`」这个笨办法 —— 它跟那份实现无关，
  /// 不会因为上游改了 `queryChild` 的语义而错。
  static ({String text, int start}) currentLine(q.QuillController controller) {
    final cursor = controller.selection.extentOffset.clamp(
      0,
      controller.document.length,
    );
    final before = controller.document.getPlainText(0, cursor);
    final breakAt = before.lastIndexOf('\n');
    return (text: before.substring(breakAt + 1), start: breakAt + 1);
  }

  /// 当前行是不是空的（连空白都没有）—— 空行是「可以弹菜单」的状态。
  static bool isOnEmptyLine(q.QuillController controller) =>
      currentLine(controller).text.trim().isEmpty;

  /// 按 [query] 过滤。空 query 全给（这是「敲了 `/` 就出菜单」的手感）。
  static List<SlashItem> filter(String query, {bool allowAi = true}) {
    final items = allowAi
        ? SlashItem.values
        : SlashItem.values.where((e) => e != SlashItem.aiDraft).toList();
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return items;
    return items
        .where((item) => _keywords(item).any((k) => k.contains(q)))
        .toList();
  }

  /// 每个条目的匹配关键字（中英各一组 —— 用户可能用中文输入法敲 `/biaoti`）。
  static List<String> _keywords(SlashItem item) {
    switch (item) {
      case SlashItem.paragraph:
        return ['p', 'text', 'body', '正文', '文本', '段落'];
      case SlashItem.heading1:
        return ['h1', 'heading1', 'title', '标题', '大标题'];
      case SlashItem.heading2:
        return ['h2', 'heading2', '标题2', '副标题'];
      case SlashItem.heading3:
        return ['h3', 'heading3', '标题3', '小标题'];
      case SlashItem.bulletList:
        return ['ul', 'bullet', 'list', '无序', '列表', '项目符号'];
      case SlashItem.orderedList:
        return ['ol', 'ordered', 'number', '有序', '编号'];
      case SlashItem.quote:
        return ['quote', 'blockquote', '引用'];
      case SlashItem.codeBlock:
        return ['code', 'pre', '代码'];
      case SlashItem.divider:
        return ['hr', 'divider', 'line', '分隔', '分割'];
      case SlashItem.table:
        return ['table', 'grid', '表格'];
      case SlashItem.image:
        return ['img', 'image', 'picture', '图片', '照片'];
      case SlashItem.aiDraft:
        return ['ai', 'draft', 'write', '起草', '生成', '智能'];
    }
  }

  /// 删掉 `/query` 这段（[trigger] 的 `[start, start + 1 + query.length)`），
  /// 光标落到 `/` 原来的位置。
  ///
  /// **所有**菜单项落地前都要先走这一步（包括图片 / 表格 / AI 起草）——
  /// 否则用户会看到 `/表格` 跟着新插入的表格一起留在文档里。
  static void clearTrigger(q.QuillController controller, SlashTrigger trigger) {
    final start = trigger.start.clamp(0, controller.document.length);
    final length =
        (1 + trigger.query.length).clamp(0, controller.document.length - start);
    if (length <= 0) {
      controller.updateSelection(
        TextSelection.collapsed(offset: start),
        q.ChangeSource.local,
      );
      return;
    }
    controller.replaceText(
      start,
      length,
      '',
      TextSelection.collapsed(offset: start),
    );
  }
}
