import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../../core/util/time_utils.dart';
import '../../data/models/mail_attachment.dart';
import '../../data/models/mail_row.dart';
import '../compose/html/html_depth_guard.dart';
import '../attachment/attachment_kind.dart' show formatAttachmentSize;

/// 喂给模型的那一段，以及抬头那几行要用的计数（spec §5.1）。
///
/// 抬头**如实注明 AI 看到了什么**：用户看到「正文 3,214 字」而自己那封信
/// 明显更长时，就知道为什么建议跑偏了 —— 而不是直接判定这个功能是噪音。
class SuggestInput {
  const SuggestInput({
    required this.text,
    required this.bodyChars,
    required this.originalChars,
    required this.attachmentCount,
    required this.quotedDropped,
    required this.truncated,
  });

  /// 完整一段（抬头 + 分隔线 + 正文），直接发给模型。
  final String text;

  /// 正文**实际**给了多少字。
  final int bodyChars;

  /// 正文原本多少字（剥完引用、截断**之前**）。
  final int originalChars;

  final int attachmentCount;

  /// 引用链是不是被剥掉了（抬头据此多写一句）。
  final bool quotedDropped;

  /// 是不是撞了 [build] 的上限。
  final bool truncated;

  /// 有没有正文。false 时 `reply` / `forward` 要从动作池里去掉（§2.3 末行）
  /// —— 写不出回信，也写不出附言。
  bool get hasBody => bodyChars > 0;

  /// 组装一段（spec §5）。**纯函数**。
  ///
  /// 刻意不要 `ossBase`：这一路的输出是纯文本，附件只给名字与大小，没有任何
  /// 一处要把相对路径拼成绝对 URL。
  static SuggestInput build(MailRow row, {int maxChars = 8000}) {
    final plain = _plainBody(row);

    // 剥引用是「不减信息」的操作：留在正文里的那一轮已经包含 `Re:` 链上的一切
    // 必要上下文（对方引用它是因为要指着它说话）。剥掉的是「更早的、已经被
    // 引用过一次的同一批字」。
    final stripped = _stripQuoted(row, plain);
    final full = stripped.text;
    final truncated = full.length > maxChars;
    final body = truncated ? full.substring(0, maxChars) : full;

    final header = <String>[
      '主题：${row.subject.trim()}',
      '发件人：${_senderOf(row)}',
      if (row.isSend) '收件人：${_recipientsOf(row)}',
      '时间：${TimeUtils.formatDetailTime(row.createTime)}',
      if (row.attList.isNotEmpty)
        '附件（${row.attList.length}）：'
            '${row.attList.map(_attachmentLine).join('、')}',
      '当前状态：${_stateOf(row)}',
    ];

    final text = StringBuffer()
      ..writeln(header.join('\n'))
      ..writeln('─────────────────────────');
    if (truncated) {
      // **截断必须告诉模型，不能偷偷截**：不说的话模型会把「信里没提」当成
      // 「信里没有」—— 那正是它给出错误建议最常见的来源。
      text.writeln('（来信正文过长，已截断：原文 ${full.length} 字，'
          '你看到的是前 $maxChars 字）');
    }
    text.write(body);

    return SuggestInput(
      text: text.toString(),
      bodyChars: body.length,
      originalChars: full.length,
      attachmentCount: row.attList.length,
      quotedDropped: stripped.dropped,
      truncated: truncated,
    );
  }

  /// 正文取哪一份：`content` 优先（有结构可剥），否则退到 `text`。
  static String _plainBody(MailRow row) {
    final content = row.content?.trim() ?? '';
    if (content.isNotEmpty) return content;
    return row.text?.trim() ?? '';
  }

  static String _senderOf(MailRow row) {
    final name = row.name.trim();
    final address = row.sendEmail.trim();
    if (name.isEmpty) return address;
    if (address.isEmpty) return name;
    return '$name <$address>';
  }

  static String _recipientsOf(MailRow row) {
    // 收件方向的 `recipients` 是抄送那一类，自己发出去的信才要看它。
    if (row.recipients.isNotEmpty) {
      return row.recipients.map((r) => r.display).join('、');
    }
    return row.toName.trim().isEmpty ? row.toEmail : row.toName;
  }

  static String _attachmentLine(MailAttachment attachment) {
    final size = formatAttachmentSize(attachment.size);
    final name = attachment.displayName;
    return size.isEmpty ? name : '$name（$size）';
  }

  static String _stateOf(MailRow row) {
    // 这一行是**给模型看的**（不是抬头文案）：它解释「为什么池子里没有
    // markRead / star」—— 模型看到状态是「已读 · 已加星标」就不会去提
    // 那两件已经做完的事。
    final parts = <String>[
      if (row.isSend) '已发送' else if (row.isUnread) '未读' else '已读',
      if (row.isStarred) '已加星标',
    ];
    return parts.join(' · ');
  }
}

/// 剥引用的结果。`dropped` 只表示「真的切掉了东西」，不是「找到了引用」——
/// 整封都是引用时正文空，但 `dropped` 仍然是 true（抬头要如实说）。
typedef _Stripped = ({String text, bool dropped});

/// 剥引用链：**先找结构，再找文本**，两条都不命中就不剥（spec §5.2）。
///
/// 结构那支**一定要把它的结果转交给文本那支**，哪怕没找到任何引用标记：
/// `<style>` / `<script>` 这类标签在纯文本化时会被整棵跳过，可它们的源码
/// 留在一行 ASCII 里，照样能被归属行判据认成 `On …` 那类形状 —— 直接拿
/// 原文去跑文本那支，正文会被「第一条假归属行」从头切掉。先过一遍结构那支，
/// 拿它吐出来的**无标签**文本再找归属行，假命中就没有了。
_Stripped _stripQuoted(MailRow row, String body) {
  if (body.isEmpty) return (text: '', dropped: false);

  // **深度预检在这里。** `_stripByDom` 会走 `package:html` 的解析与递归序列化，
  // 而 `content` 是**收到的邮件正文**、完全不可信：实测 4 千层嵌套 248ms、
  // 1.2 万层 2.1s 之后抛 `StackOverflowError` —— 那是 `Error` 不是
  // `Exception`，`_stripByDom` 里那个 `try/catch` 接不住，于是一次点击把
  // 整个分析流程连人带面板一起带走。
  //
  // 仓库里另外三个解析不可信 HTML 的地方（`email_html_sanitizer.dart` 的三个
  // 公开入口、`mail_html_to_delta.dart` 的 `convert`）都是同一道守卫、同一个
  // 阈值。这里补的是第四个 —— 它一直在漏。
  final content = row.content?.trim() ?? '';
  if (content.isEmpty) return _stripByAttribution(body);

  if (HtmlDepthGuard.exceedsLimit(body)) {
    // 降级路径自己**绝不能**递归（否则等于没降级），所以借 `plainText` 那台
    // 非递归 O(n) 扫描器，再把归属行那一支接上。
    return _stripByAttribution(_deepFallback(body));
  }

  final viaDom = _stripByDom(body);
  if (viaDom.dropped) return viaDom;
  return _stripByAttribution(viaDom.text);
}

/// 深度超限时的降级：非递归地剥标签，然后接文本那一支找死板的归属行。
///
/// 借 [HtmlDepthGuard.plainText] 的扫描器（非递归、O(n)），但**补一件它不做
/// 的事**：它不跳 `<script>` / `<style>` 的内容（`_htmlToPlainText` 靠
/// `_skippedTags` 跳，它没有），会把 JS / CSS 的源码当正文一起喂给模型。
///
/// 所以先把这两段从**原串**里整块删掉（见 [_rawTextBlock]，纯 `indexOf`/正则，
/// 不进解析器），再交给 `plainText`。**不做 trim**：留着原样的行交给
/// `_isAttribution`（`On … wrote:` 那类判据要的是原样），该收的时候
/// `_stripByAttribution` 自己会收。
String _deepFallback(String html) =>
    HtmlDepthGuard.plainText(html.replaceAll(_rawTextBlock, '\n'));

/// `<script>` / `<style>` 整段（**含内容**）—— 只在这条降级路上用。
///
/// `[^>]{0,200}` 而不是 `[^>]*`，上界是**性能**要的：`<script` 连写十万遍
/// （一个 `>` 都没有）时，`*` 会在每个起点一路扫到串尾，整条正则退化成平方级；
/// 长度超过 200 的开标签本来就不可能，直接判失败。`[\s\S]*?` 是惰性的，配
/// `|$` 兜住「没闭合」那种 —— 删到串尾，与 HTML 解析器的处理一致。
final RegExp _rawTextBlock = RegExp(
  r'<(script|style)\b[^>]{0,200}>[\s\S]*?(?:</\1\s*>|$)',
  caseSensitive: false,
);

/// 结构那一支：`content` 非空时用 `package:html` 走一遍 DOM。
///
/// **Web 端包裹类要先找、`<blockquote>` 后找。** 两者常常同时存在，而包裹类
/// 是**外面的**那一层：先找 `<blockquote>` 的话，它前面那句归属行
/// （`2026 年 10 月 1 日 张三 写道：`）会留在正文里。
_Stripped _stripByDom(String html) {
  // `parseFragment` 的返回类型是**非空**的 `DocumentFragment`，所以这里不能声明
  // 成可空的再去判 `null` —— `unnecessary_null_comparison` 会把那个分支标成死代码。
  // 声明成 `final` + 在 `try` 里赋值：catch 那一支必然 return，所以到达下面时
  // 它一定已经赋过值（Dart 的确定赋值分析认这个形状）。
  final DocumentFragment fragment;
  try {
    fragment = html_parser.parseFragment(html);
  } catch (_) {
    // 解析器对畸形输入很宽容，真抛了也不该让整条建议链断掉 —— 退到文本那一支。
    return (text: '', dropped: false);
  }

  final mark = fragment.querySelector('.gmail_quote') ??
      fragment.querySelector('#divRplyFwdMsg') ??
      fragment.querySelector('[class*=yahoo_quoted]') ??
      fragment.querySelector('blockquote');
  if (mark == null) {
    // 没有引用结构：仍然是**文本那一支**的输入（先剥标签、再找死板的归属行）。
    return (text: _htmlToPlainText(fragment), dropped: false);
  }

  _cutFrom(fragment, mark);
  // `dropped` 按**「找到过引用结构」**判，不按「字数变少了」判：整封都是引用时
  // 切完是空串，而「切完整段」也是空串 —— 用长度比会把「真的剥掉了一整封信的
  // 引用」报成 `false`，抬头于是漏掉那一句。
  return (text: _htmlToPlainText(fragment), dropped: true);
}

/// 文本那一支：按行找第一条归属行，从那一行起截掉。
_Stripped _stripByAttribution(String body) {
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (_isAttribution(lines[i])) {
      return (text: lines.take(i).join('\n').trim(), dropped: true);
    }
  }
  return _asIs(body);
}

_Stripped _asIs(String text) => (text: text.trim(), dropped: false);

/// 归属行的死板形状（spec §5.2 第 2 条）。**不含正则的「任意」**：
/// 这四种是 Web 端与桌面端邮件客户端用得最多的开头，写宽了会误伤正文里
/// 引用别人话时写的「张三写道：」。
bool _isAttribution(String line) {
  final text = line.trim();
  if (text.isEmpty) return false;
  if (text.startsWith('-----原始邮件-----')) return true;
  if (RegExp(r'-{2,}\s*Original Message\s*-{2,}', caseSensitive: false)
      .hasMatch(text)) {
    return true;
  }
  // `在 2026年10月1日 10:04 张三 写道：` —— 中文客户端的形状。
  if (text.startsWith('在 ') && text.endsWith('写道：')) return true;
  // `On Oct 1, 2026, at 10:04, Zhang <z@x.com> wrote:` —— 英文客户端的形状。
  if (text.startsWith('On ') && text.toLowerCase().endsWith('wrote:')) {
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// DOM 摘取
// ---------------------------------------------------------------------------

/// 把「[mark] 及其之后的一切」从 fragment 里摘掉，祖先自己**不删**。
///
/// 为什么不是「爬到顶层再一次性切掉」：实测 `<div><p>这一轮</p><div>`
/// `<blockquote>旧</blockquote></div></div>` 这种形状里，blockquote 的顶层
/// 祖先就是那个把正文包住的 div —— 一刀切下去正文也没了（读出来是空串）。
/// 正确的语义是「沿着祖先链，每一层都把它后面的兄弟摘掉，自己留着」。
///
/// **`mark` 自己要删** —— 它本身就是引用块。文档注释说「[mark] 及其之后的
/// 一切」，`mark` 的那点文本正在「一切」里：留着它只会让正文多出一段旧信。
/// 往上爬的那些祖先才要留（它们夹着正文）。所以循环每转一圈都摘兄弟、但只有
/// 第一圈摘自己。
void _cutFrom(DocumentFragment fragment, Node mark) {
  var node = mark;
  var isMark = true;
  while (true) {
    final parent = node.parent;
    // `DocumentFragment` 的 `nodes.first.parent` 是 **null**，所以两个条件
    // 都要认：null 与「就是 fragment 本人」。
    final isTop = parent == null || identical(parent, fragment);
    final siblings = isTop ? fragment.nodes : parent.nodes;
    final list = List<Node>.of(siblings);
    final index = list.indexWhere((n) => identical(n, node));
    if (index < 0) {
      if (isMark) node.remove();
      return;
    }
    for (var i = index + 1; i < list.length; i++) {
      list[i].remove();
    }
    if (isMark) node.remove();
    if (isTop) return;
    node = parent;
    isMark = false;
  }
}

/// fragment → 纯文本。
///
/// **块级标签之间补一个 `\n`**：邮件 HTML 几乎全是 `<p>` / `<div>` / `<br>`，
/// 不补的话「第一段」「第二段」会粘成一句话，模型读到的是一串没有段落的字。
/// `script` / `style` 整棵子树跳过 —— 它们的内容是代码，不是正文。
String _htmlToPlainText(Node root) {
  final buffer = StringBuffer();
  _writePlain(root, buffer);
  return buffer
      .toString()
      .replaceAll(RegExp(r'\n{2,}'), '\n')
      .trim();
}

const Set<String> _skippedTags = <String>{
  'script', 'style', 'head', 'title', 'meta', 'noscript', 'link', 'iframe',
};

/// 这些标签**自己算一个块**：进出内容时各要一个换行。
const Set<String> _blockTags = <String>{
  'p', 'div', 'blockquote', 'li', 'tr', 'table', 'section', 'article',
  'header', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre', 'ul', 'ol',
  'body', 'td', 'th',
};

void _writePlain(Node node, StringBuffer out) {
  if (node is Text) {
    out.write(node.text);
    return;
  }
  if (node is! Element) {
    for (final child in node.nodes) {
      _writePlain(child, out);
    }
    return;
  }
  final name = node.localName ?? '';
  if (_skippedTags.contains(name)) return;
  final isBlock = _blockTags.contains(name);
  if (isBlock) out.write('\n');
  for (final child in node.nodes) {
    _writePlain(child, out);
  }
  // `<br>` 自己没有内容，进出各写一个换行会变成两个空行 —— 只需要一个。
  if (name == 'br') {
    out.write('\n');
    return;
  }
  if (isBlock) out.write('\n');
}
