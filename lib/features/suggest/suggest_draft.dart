import '../../data/models/mail_row.dart';
import '../compose/compose_draft.dart' show ComposeDraftFactory;
import '../compose/compose_html.dart';
import '../compose/compose_text.dart' show encodeRecipientAddresses;
import '../compose/html/document_codec.dart';

/// 「答复 / 转发」点下去之后，往草稿表里写什么（spec §6.2）。
///
/// 四个字段就是 `LocalDao.saveDraft` 的那几个参数 —— 中间不经过任何 widget，
/// 于是这一份能脱离 Riverpod 单测（`test/suggest_draft_test.dart`）。
///
/// ## 为什么走草稿表这条通道
///
/// 写邮件页的正文初值只有两个来源：`ComposeDraftFactory`（由
/// `ComposeArgs.mail` 推）与 `_restoreDraft`（从草稿表读）。这条路**两边都用
/// 不上**前者（它拼不出 AI 草稿），所以要借后者 —— 先落一条草稿、
/// 再 `Routes.composeOf(draftId:)`，写邮件页自己会把它读回编辑器。一句新代码
/// 都不用加，而且用户在写邮件页里写了两句就退出时，那条草稿**本来就该在草稿
/// 箱里**（这正是 `_restoreDraft` 存在的理由）。
///
/// 代价是草稿箱里会多一条记录。这是**正确**的代价。
class SuggestDraft {
  const SuggestDraft({
    required this.recipientsJson,
    required this.subject,
    required this.content,
    required this.accountEmail,
  });

  /// 草稿表的 `recipients_json`。
  final String recipientsJson;

  final String subject;

  /// 正文的 Delta JSON（引用块 + AI 文本）。
  final String content;

  /// 用哪个邮箱发。原信的投递邮箱 —— 在聚合视图里不指定的话会挑到别的实例
  /// 的默认邮箱上去。
  final String accountEmail;

  /// 答复。
  static SuggestDraft reply({
    required MailRow row,
    required String aiText,
    required String ossBase,
    required String wroteLabel,
  }) =>
      SuggestDraft(
        // 收件人是**原发件人**；没有地址就留空（不猜一个出来）。
        recipientsJson:
            encodeRecipientAddresses(row.sendEmail.trim().isEmpty
                ? const <String>[]
                : <String>[row.sendEmail.trim()]),
        // 前缀规则复用 `ComposeDraftFactory` 那一份 —— 四种「已经是回复」的
        // 写法在那边已经定死了，这里抄一遍迟早分叉。
        subject: ComposeDraftFactory.replySubject(row.subject),
        content: replyBody(
          row: row,
          aiText: aiText,
          ossBase: ossBase,
          wroteLabel: wroteLabel,
        ),
        accountEmail: row.mailboxEmail,
      );

  /// 转发。
  static SuggestDraft forward({
    required MailRow row,
    required String note,
    required String ossBase,
  }) =>
      SuggestDraft(
        // **留空**：转发不替用户决定转给谁（spec §6.2 末段）。
        recipientsJson: '',
        // 主题原样 —— 与 Web 端的 `openForward` 一致。
        subject: row.subject,
        content: forwardBody(row: row, note: note, ossBase: ossBase),
        accountEmail: row.mailboxEmail,
      );

  /// 答复那一份正文的 Delta：**引用块在下面、AI 文本插在最上方**。
  ///
  /// `aiText` 全空白时**原样返回 `replyQuote` 的输出**，不做
  /// `encode(decode(x))` 那一圈 —— 那一圈只能保证「语义相同」，不保证
  /// 「逐字相同」，而「没有 AI 文本时引用块一个字没动」是这一条要钉住的契约。
  static String replyBody({
    required MailRow row,
    required String aiText,
    required String ossBase,
    required String wroteLabel,
  }) {
    final quote = ComposeHtml.replyQuote(
      row,
      ossBase: ossBase,
      wroteLabel: wroteLabel,
    );
    return _withAiText(quote, aiText);
  }

  /// 转发那一份正文的 Delta。同 [replyBody]，只是引用块换 `forwardBody`。
  static String forwardBody({
    required MailRow row,
    required String note,
    required String ossBase,
  }) {
    final quote = ComposeHtml.forwardBody(row, ossBase: ossBase);
    return _withAiText(quote, note);
  }

  /// 在引用块上方插一段**纯文本**。
  ///
  /// `DocumentCodec.decode` 返回的**就是** `quill.Document` —— 不要再套
  /// `Document.fromJson(...)`（那是编译错误，§0.2 第 1 条）。
  ///
  /// `doc.insert(0, …)` 就是「插在引用块上方」：探针实测新建的引用块文档里
  /// `ComposeQuote.userEnd` 恒为 `0`（引用块从第一个字符起），所以偏移 0
  /// 正是「用户区的最前面」。
  static String _withAiText(String quote, String aiText) {
    final block = _asPlainBlock(aiText);
    if (block.isEmpty) return quote;
    final doc = DocumentCodec.decode(quote);
    doc.insert(0, block);
    return DocumentCodec.encode(doc);
  }

  /// 把一段 AI 文本归一成「插进 Delta 的一段纯文本」。
  ///
  /// 四件事，缺一个都会在某个形状上出错：
  /// 1. `\r\n` / `\r` 统一成 `\n` —— Delta 认它当行终结符，别的字符会变成
  ///    看不见的行内字符；
  /// 2. 两端空白掐掉；
  /// 3. 连续空行压成**一个**空行 —— 模型偶尔会吐三四个连续换行，插进去就是
  ///    一大片空白；
  /// 4. **结尾恰好一个 `\n`**。少了它，用户最后那一行就没有自己的行终结符，
  ///    `ComposeQuote.userEnd`（= 第一条引用行的行首 - 1）会退到引用区那个
  ///    前导空行上 —— 于是「用户区」多含一个换行，用户那一段与分隔线之间
  ///    差一行。探针实测：插 `'你好，\n\n我确认一下时间。\n'`（14 字）之后
  ///    `userEnd == 14`，引用块的第一行从 15 开始。
  static String _asPlainBlock(String raw) {
    final normalized =
        raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (normalized.isEmpty) return '';
    final collapsed = normalized.replaceAll(RegExp(r'\n{2,}'), '\n\n');
    return '$collapsed\n';
  }
}
