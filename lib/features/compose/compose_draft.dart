import '../../data/models/mail_row.dart';
import 'compose_html.dart';

/// 打开写邮件页的三种由头。
enum ComposeMode { blank, reply, forward }

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
      other.mail?.profileId == mail?.profileId &&
      other.mail?.emailId == mail?.emailId;

  @override
  int get hashCode => Object.hash(
        profileId,
        accountId,
        draftId,
        mode,
        mail?.profileId,
        mail?.emailId,
      );

  @override
  String toString() =>
      'ComposeArgs(${profileId ?? 'current'}, box#$accountId, draft#$draftId, '
      '${mode.name}, #${mail?.emailId ?? 0})';
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
  static ComposeDraft of(
    ComposeArgs args, {
    required String ossBase,
    required String wroteLabel,
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
          subject: replySubject(mail.subject),
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

  /// 回复主题的前缀判定。与 Web 端同样的四种写法都算「已经是回复」。
  static String replySubject(String original) {
    final subject = original.trim();
    if (subject.isEmpty) return 'Re: ';
    const prefixes = <String>['Re:', 'Re：', '回复：', '回复:'];
    return prefixes.any(subject.startsWith) ? subject : 'Re: $subject';
  }
}
