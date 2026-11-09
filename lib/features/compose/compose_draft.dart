import '../../data/models/mail_row.dart';
import 'compose_html.dart';
import 'compose_text.dart';

/// 打开写邮件页的几种由头。
///
/// [replyAll] 是 [reply] 的多收件人版本：主题 / 引用块 / 线程（`SendKind.reply`）
/// 都与 [reply] 完全一致，差别只在预填的收件人集合（原发件人 + 原 To + 原 Cc，
/// 去掉自己，见 [ComposeDraftFactory.replyAllRecipients]）。**服务端的
/// `/email/send` 没有 cc/bcc 字段**，所以这里不引入「抄送」这种半真半假的分组
/// —— 全部落在 `receiveEmail` 里，语义就是「这些人都会收到」。
enum ComposeMode { blank, reply, replyAll, forward }

/// 写邮件页的入参。
///
/// 做成一个值对象（而不是一串散参数）是为了让它能当 Riverpod 的 family 维度
/// —— 同一个 `(实例, 模式, 原邮件)` 必须命中同一份状态，否则每次重建页面都会
/// 把用户写了一半的字丢掉。
class ComposeArgs {
  const ComposeArgs({
    this.profileId,
    this.accountId = 0,
    this.draftId = 0,
    this.mode = ComposeMode.blank,
    this.mail,
    this.freshPage = false,
  });

  /// 发信走哪个实例。null = 当前实例。
  ///
  /// 与 [mail] 的 `profileId` 是**两件事**：在聚合视图里回复一封来自实例 B 的
  /// 信时，用户可能已经把「当前实例」切成了 A —— 发信必须走 B。
  final String? profileId;

  /// 预选的发件邮箱（`account.accountId`）。0 = 用第一个可用邮箱。
  ///
  /// 从某个邮箱的收件箱点「写邮件」进来时要选中那一个：同一个实例下
  /// 有多个邮箱是很常见的，猜错了会让用户用错身份发信。
  final int accountId;

  /// 要接着写的草稿（0 = 没有指定）。
  ///
  /// 从草稿箱点进来时必须带上：不指定的话控制器会退化成「取这个实例最近
  /// 的一条草稿」，用户点了第 3 条却打开了第 1 条。
  final int draftId;

  final ComposeMode mode;

  /// 回复/转发的原邮件。
  final MailRow? mail;

  /// 这一页的草稿行是不是**本页刚建出来的空行**（地址里没有 `draft`，
  /// 由 `ComposeEntry._ensureDraft` 建好后把 id 递进来）。
  ///
  /// 控制器据此**跳过读回草稿**：那一行此刻是空的，读回来只会用空值盖掉
  /// `ComposeController.build()` 里已经算好的预填（主题 / 收件人 / 引用块），
  /// 还会把它标成「用户写过」—— 于是「一个字没敲就关掉 → 删掉这一行」的
  /// 规矩也跟着破。AI 建议那条路（先存草稿再带 `draft=` 打开）不置它，
  /// 照旧走恢复。
  final bool freshPage;

  /// 实际使用的实例：显式指定的优先，否则是原邮件所属的实例。
  String resolveProfileId(String? current) =>
      profileId ?? _mailProfileId ?? current ?? '';

  String? get _mailProfileId {
    final id = mail?.profileId;
    return (id == null || id.isEmpty) ? null : id;
  }

  bool get hasMailboxHint => accountId > 0;

  bool get hasDraftHint => draftId > 0;

  @override
  bool operator ==(Object other) =>
      other is ComposeArgs &&
      other.profileId == profileId &&
      other.accountId == accountId &&
      other.draftId == draftId &&
      other.mode == mode &&
      other.freshPage == freshPage &&
      other.mail?.profileId == mail?.profileId &&
      other.mail?.emailId == mail?.emailId;

  @override
  int get hashCode => Object.hash(
        profileId,
        accountId,
        draftId,
        mode,
        freshPage,
        mail?.profileId,
        mail?.emailId,
      );

  @override
  String toString() =>
      'ComposeArgs(${profileId ?? 'current'}, box#$accountId, draft#$draftId, '
      '${mode.name}, #${mail?.emailId ?? 0}'
      '${freshPage ? ', fresh' : ''})';
}

/// 打开写邮件页时要预填的东西。
class ComposeDraft {
  const ComposeDraft({
    this.recipients = const <String>[],
    this.subject = '',
    this.quoted = '',
  });

  const ComposeDraft.blank() : this();

  /// 预填的收件人（回复时是原发件人）。
  final List<String> recipients;

  final String subject;

  /// 正文的**初值**（一份 Delta JSON）。
  ///
  /// 回复 / 转发时它是带引用块的那一份；普通写信时是空串。
  ///
  /// 它现在是**正文的初值**，不是「发送时贴到后面的东西」——
  /// spec §3.6 之后引用块对用户可见可编辑，所以它必须从一开始就在正文里，
  /// 而不是藏在控制器里等发送。这个字段改名前叫 `quotedHtml`。
  final String quoted;

  bool get isEmpty => recipients.isEmpty && subject.isEmpty && quoted.isEmpty;
}

/// 由 [ComposeArgs] 推出预填内容的唯一入口。
///
/// 引用块与主题前缀全部落在 [ComposeHtml] 里 —— 那里是**逐字对齐 Web 端**
/// `mail-vue/src/layout/write/index.vue` 的地方。这里只负责决定「用哪一种」，
/// 再抄一份形状出来的话，两端口径迟早会分叉。
abstract final class ComposeDraftFactory {
  const ComposeDraftFactory._();

  /// [wroteLabel] 由调用方本地化（`wrote:` / `写道：`）——
  /// 这句在两种语言里语序不同，硬拼会出错。
  ///
  /// [replySubjectTemplate] 同理，是**本地化的主题模板**（`答复 {subject}` /
  /// `Re: {subject}`）：中文与英文不只是前缀不同、语序也不同，而拼主题这件
  /// 事必须和 [replySubject] 的归一化放在一起才幂等。
  static ComposeDraft of(
    ComposeArgs args, {
    required String ossBase,
    required String wroteLabel,
    required String Function(String subject) replySubjectTemplate,
  }) {
    final mail = args.mail;
    if (mail == null) return const ComposeDraft.blank();

    switch (args.mode) {
      case ComposeMode.blank:
        return const ComposeDraft.blank();

      case ComposeMode.reply:
        // 对齐 Web 端 `openReply`：收件人是原发件人、主题加 `Re: ` 前缀
        // （已经是回复的不重复加）、正文是带引用头的缩进原文。
        return ComposeDraft(
          recipients: mail.sendEmail.isEmpty
              ? const <String>[]
              : <String>[mail.sendEmail],
          subject: replySubject(mail.subject, replySubjectTemplate),
          quoted: ComposeHtml.replyQuote(
            mail,
            ossBase: ossBase,
            wroteLabel: wroteLabel,
          ),
        );

      case ComposeMode.replyAll:
        // 其余三样与 [ComposeMode.reply] 逐字一致（含线程），只有收件人不同。
        // 不把 reply 那一支抽成公共函数：两处都只有几行，而分开写让
        // 「只有收件人不一样」这件事一眼可见。
        return ComposeDraft(
          recipients: replyAllRecipients(mail),
          subject: replySubject(mail.subject, replySubjectTemplate),
          quoted: ComposeHtml.replyQuote(
            mail,
            ossBase: ossBase,
            wroteLabel: wroteLabel,
          ),
        );

      case ComposeMode.forward:
        // Web 端 `openForward`：**主题原样**、**不带引用头**，正文就是原文。
        // 看起来「少了点什么」，但这正是 Web 端的形状 —— 两端口径一致
        // 比我们自作主张加一段「---------- 转发消息 ----------」更重要。
        return ComposeDraft(
          subject: mail.subject,
          quoted: ComposeHtml.forwardBody(mail, ossBase: ossBase),
        );
    }
  }

  /// 回复 / 全部回复的主题：先剥掉已有前缀，再套**调用方给的本地化模板**。
  ///
  /// 为什么模板由调用方传（而不是在这里读 `AppLocalizations`）：这个类是一组
  /// 纯函数，`test/compose_reply_draft_test.dart` 与 `test/suggest_draft_test.dart`
  /// 都脱离 widget 直接调它；而「答复 xxx」与「Re: xxx」不只是前缀不同、
  /// 语序也不同，在这里硬拼两份字符串迟早分叉（与 [of] 的 `wroteLabel` 同一个
  /// 模式）。
  ///
  /// **必须幂等**：对同一封已经「答复 主题」的信再点一次答复，结果仍是
  /// 「答复 主题」。所以不是「已经是回复就原样返回」，而是**剥掉见过的所有
  /// 前缀再套一次模板** —— 否则我们的模板与 Web 端那套混用时，前缀会一层层
  /// 滚下去（「答复 Re: 答复：主题」）。
  ///
  /// 空主题也套模板：中文得到 `答复 `、英文得到 `Re: ` —— 与改造前
  /// （`Re: `）一致。
  static String replySubject(
    String original,
    String Function(String subject) template,
  ) {
    var subject = original.trim();
    var stripped = true;
    while (stripped && subject.isNotEmpty) {
      stripped = false;
      final lower = subject.toLowerCase();
      for (final prefix in _replyPrefixes) {
        final lowerPrefix = prefix.toLowerCase();
        if (lower.startsWith(lowerPrefix)) {
          subject = subject.substring(prefix.length).trim();
          stripped = true;
          break;
        }
        // 模板作用在**空主题**上留下的、只剩前缀本身的形态（`答复` / `Re:`）
        // 也算「已经是回复」：不认它的话，空主题答复两次会变成「答复 答复 」。
        if (lower == lowerPrefix.trim()) {
          subject = '';
          stripped = true;
          break;
        }
      }
    }
    return template(subject);
  }

  /// 认作「已经是回复」的前缀。
  ///
  /// 前四个是 Web 端（`mail-vue` 的 `openReply`）那套写法；最后三个是我们
  /// 自己的主题模板（`app_zh.arb` 的 `replySubject`）—— 漏掉它们的话，中文
  /// 界面里每答复一次就会再叠一层前缀。[`答复 `] 带空格，避免把
  /// 「答复期限是周五」这种正常主题截掉；带冒号的两种不受这个限制。
  ///
  /// 与语言无关：用户可能收到别人用别的语言写的「Re:」，也可能在中英之间
  /// 切换界面 —— 前缀表取并集，不在运行时按 locale 分。
  static const List<String> _replyPrefixes = <String>[
    'Re:',
    'Re：',
    '回复：',
    '回复:',
    '答复：',
    '答复:',
    '答复 ',
  ];

  /// 「全部回复」预填的收件人。
  ///
  /// 集合是：原发件人 + 原 To + 原 Cc，**去掉自己**（[MailRow.mailboxEmail]）
  /// 与重复项。三条判据都不是可省的：
  ///
  /// - **Bcc 必须排除**。密送收件人之所以是密送，就是因为别人不该知道他们也在
  ///   这一封里；把 `mail.bcc` 拼进来等于把原发件人的密送名单公开出去。
  /// - **去掉自己**：不回给自己是回复全部的基本礼节，而且很多服务端会把
  ///   「收件人里有自己」当成一次额外的投递（多一份未读，有时还会多算配额）。
  /// - **去重忽略大小写**：原发件人常常也在 To 里（`a@x.com` 与 `A@x.com`
  ///   是同一个邮箱），按原样拼会出现两个 chip，服务端收到两条一样的投递。
  ///
  /// 只认 [MailRow.mailboxEmail] 一个「自己」：一个用户在一个实例上可能有多个
  /// 邮箱，而这一行的收件信息只知道「这封信投到了哪个邮箱」。用当前发件邮箱
  /// 再兜一层在控制器里做（发件人这时才定得下来）。
  static List<String> replyAllRecipients(MailRow mail) {
    final own = mail.mailboxEmail.trim().toLowerCase();
    final seen = <String>{};
    final out = <String>[];

    void add(String raw) {
      final address = raw.trim();
      if (!looksLikeEmail(address)) return;
      final key = address.toLowerCase();
      if (key == own || !seen.add(key)) return;
      out.add(address);
    }

    add(mail.sendEmail);
    for (final r in mail.recipients) {
      add(r.address);
    }
    for (final r in mail.cc) {
      add(r.address);
    }
    return out;
  }
}
