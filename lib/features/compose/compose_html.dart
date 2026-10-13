import 'package:flutter_quill/flutter_quill.dart' show Document;

import '../../core/util/time_utils.dart';
import '../../core/util/url_utils.dart';
import '../../data/models/mail_row.dart';
import '../mail_detail/html_body_view.dart' show sanitizeEmailHtml;
import 'compose_quote.dart';
import 'html/document_codec.dart';
import 'html/mail_html_to_delta.dart';

/// 写邮件页与邮件正文之间的转换。
///
/// 服务端只收 HTML（`content` 必须是非空字符串，见约束 13），而编辑器里的
/// 真相是一份 **Delta**，所以：
///
/// - **正文**：编辑器直接持 Delta；发送时才由 `DeltaToEmailHtml` 导出成
///   邮件安全 HTML。这里不再有「纯文本 → HTML」那条路。
/// - **回复 / 转发**：引用块的形状**逐字对齐 Web 端**
///   （`mail-vue/src/layout/write/index.vue` 的 `openReply` / `openForward`），
///   这样同一个收件人在 Web 端和 App 端看到的引用样式一致。产出的是
///   **Delta**（HTML → Delta 这一圈是为了形状只有一处定义，见 [replyQuote]）。
///
/// 引用原文走 [sanitizeEmailHtml]：转发的是一封**别人发来的** HTML，
/// 不净化就等于把 `<script>` 原样转给下一个收件人 —— 那是替攻击者转发。
abstract final class ComposeHtml {
  const ComposeHtml._();

  /// 回复/转发时要拼进正文的原文。
  ///
  /// 有 `content` 就用净化后的 HTML；没有（摘要行）就退回 `<pre>` 包纯文本
  /// —— 与 Web 端的 `formatImage(email.content) || '<pre>...'` 一致。
  static String originalBody(MailRow original, {required String ossBase}) {
    final raw = original.content ?? '';
    if (raw.trim().isNotEmpty) {
      // `{{domain}}` 是渲染时替换的占位符；拼进新邮件正文的这一份同样只替换
      // 这个副本，绝不写回本地缓存的 `content`。
      return sanitizeEmailHtml(
        UrlUtils.substituteDomainToken(raw, ossBase),
      ).html;
    }
    final text = (original.text ?? '').trim();
    if (text.isEmpty) return '';
    return '<pre style="font-family: inherit; word-break: break-word; '
        'white-space: pre-wrap; margin: 0">${escape(text)}</pre>';
  }

  /// 回复的引用块 —— **产出的是一份 Delta**，不是 HTML。
  ///
  /// 为什么绕一圈（HTML → Delta）而不是直接拼 Delta：引用块这个形状是
  /// **逐字对齐 Web 端** `mail-vue/src/layout/write/index.vue` 的（见
  /// [originalBody]），拆开重写等于把这份对齐关系丢掉。绕这一圈之后，
  /// 形状仍然只有一处定义，而编辑器拿到的是它认的东西。
  ///
  /// **净化仍然在拼进编辑器之前**（spec §3.6，这条不许松）：
  /// [originalBody] 里的 `sanitizeEmailHtml` 一步没少，`MailHtmlToDelta`
  /// 里还有第二道 `EmailHtmlSanitizer.toSafeSubset`。用户拿到的是**已经净化过**
  /// 的文档 —— 反过来「先放进编辑器、发送时再净化」的话，中间的每一次粘贴、
  /// 每一次 AI 改写、每一次落草稿都在碰一份没净化过的内容。
  ///
  /// ## 与 Web 端的**两处刻意分叉**
  ///
  /// 1. **多一条 `<hr>`**：引用块（含归属行）与用户要写的正文之间用一条横线
  ///    隔开。Web 端只有一条 `1px` 的左边框，在长回复里不够 —— 用户要的就是
  ///    一条能把两者分开的线。这条 `<hr>` 走的是本 App 既有的分隔线约定
  ///    （导出成 `<hr>`、导回来是一段 `---`，见 `delta_to_email_html.dart` 与
  ///    `_markDividers`），于是编辑器里也看得见它。
  /// 2. **引用区行尾带 `mail-quote` 标记**：见 [ComposeQuote] —— 「AI 只吃
  ///    用户自己写的那部分」靠它切边界。标记不进收件人的 HTML。
  ///
  /// 两处分叉都是「用户要的」压过「与 Web 端逐字一致」，改回去要在两处同时改。
  static String replyQuote(
    MailRow original, {
    required String ossBase,
    required String wroteLabel,
  }) {
    final when = TimeUtils.formatDetailTime(original.createTime);
    final name = original.name.isEmpty ? '' : '${escape(original.name)} ';
    // 地址也是**不可信输入**（发件人自己填的），`&lt;…&gt;` 是尖括号的实体
    // （与 Web 端的形状一致，不是字符串插值）。
    final address = escape(original.sendEmail);
    final header = '$when $name&lt$address&gt $wroteLabel';

    final buffer = StringBuffer()
      // 空的一行留给用户写回复 —— 光标落在引用块**上方**才符合直觉。
      ..write('<div><br></div>')
      // 分隔线紧跟在那个空行之后：用户写在这一行上面，引用全在它下面。
      ..write('<hr>')
      ..write('<div>$header</div>')
      ..write(
        '<blockquote style="margin: 0 0 0 0.8ex; '
        'border-left: 1px solid rgb(204,204,204); padding-left: 1ex;">',
      );
    buffer.write(originalBody(original, ossBase: ossBase));
    buffer.write('</blockquote>');
    return DocumentCodec.encode(
      Document.fromJson(
        ComposeQuote.markQuoted(MailHtmlToDelta.convert(buffer.toString())),
      ),
    );
  }

  /// 转发时的正文 —— 原文本身，同样是 Delta。
  ///
  /// **带与回复同样的那条分隔线**（用户裁定两条路一致），所以也带引用标记。
  /// 前导那个空行是**必要的**：[ComposeScreen._adoptInitialBody] 把光标放在
  /// offset 0，没有它光标就落在 `---` 那一行上，用户一敲字就把横线写成了
  /// `你好---`、线不见了。
  static String forwardBody(MailRow original, {required String ossBase}) =>
      DocumentCodec.encode(
        Document.fromJson(
          ComposeQuote.markQuoted(
            MailHtmlToDelta.convert(
              '<div><br></div><hr>'
              '${originalBody(original, ossBase: ossBase)}',
            ),
          ),
        ),
      );

  /// HTML 转义。引用块里拼进来的是**不可信输入**（发件人的名字与地址）。
  static String escape(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}
