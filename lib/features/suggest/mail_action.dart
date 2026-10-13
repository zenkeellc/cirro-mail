import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// AI 建议能执行的动作。**池子只有这一份定义。**
///
/// 三处共用同一份：组 prompt 时列给模型的、解析器当白名单的、执行器真正做的。
/// spec §2.1 那句话在代码里就是这条约束 —— 模型可以挑、可以排序、可以选
/// `none` 拒绝，但**不能引入这里没有的东西**。理由很实在：动作要被执行，
/// 模型吐一句 App 里不存在的操作（「归档到项目文件夹」），点了要么什么都不
/// 发生、要么被猜成另一个动作去执行（把用户的信删了）。
enum MailAction {
  reply('reply'),
  forward('forward'),
  remind('remind'),
  delete('delete'),
  markRead('markRead'),
  markUnread('markUnread'),
  star('star'),
  unstar('unstar'),
  none('none');

  const MailAction(this.id);

  /// 模型看到的字、解析器认的字、日志里的字。**不要改** —— 改了模型就要重学。
  final String id;

  /// 反查。认不出来返回 null（解析器据此丢掉这一项，而不是猜一个）。
  ///
  /// 只看 trim 后的**精确**匹配：不做大小写折叠。模型写 `Reply` 时，
  /// 与其猜它的意思，不如让降级扫描那条 `\breply\b` 去文本里捞 ——
  /// 那条路捞出来的至少能让用户看见模型原本写了什么。
  static MailAction? byId(String raw) {
    final key = raw.trim();
    for (final action in values) {
      if (action.id == key) return action;
    }
    return null;
  }

  /// 这个动作是什么 —— **给读代码的人与单测看的一句人话，不进任何一份 prompt**。
  ///
  /// 给模型的动词语义表在 `ai_prompts.dart` 的 `_suggestActionLines` **那一份**。
  /// 两处都自称「给模型的语义」时，文案一定会漂移（同一个 `remind` 一边有
  /// 「用户自己挑时间」、另一边没有）。**prompt 只认 `ai_prompts.dart` 那一张表**
  /// （它是 prompt 的一部分，归 `ai/` 管），这里只留一句「这个动作是什么」。
  ///
  /// 行首仍然是 `- <id>：`，`test/mail_action_pool_test.dart` 靠它把
  /// 「每个动作都写了说明」这件事钉住。面板文案是 [labelOf]，走 l10n。
  String get promptLine => switch (this) {
        MailAction.reply => '- reply：直接回复发件人，用中文回信。',
        MailAction.forward => '- forward：转给别人。',
        MailAction.remind => '- remind：现在不用处理，但过一阵要回来看。',
        MailAction.delete => '- delete：可以删掉（广告、通知、已过期的验证码）。',
        MailAction.markRead => '- markRead：没什么要做的，标记成已读就行。',
        MailAction.markUnread => '- markUnread：现在处理不了，留成未读提醒自己回来看。',
        MailAction.star => '- star：先把星标加上，回头统一处理。',
        MailAction.unstar => '- unstar：已经处理完了，星标可以撤了。',
        MailAction.none => '- none：确实不需要用户做任何事（纯通知类的信）。',
      };
}

/// 按这封信**当前的状态**过滤后的池子（spec §2.3）。
///
/// 为什么先过滤再给模型：`markRead` 对一封已经读过的信、`star` 对一封已经
/// 加星的信，都是**空动作** —— 留在池子里模型有一定概率挑中，然后用户点一下
/// 什么都没发生。
///
/// **这个函数同时是解析器的白名单**：模型就算硬吐一个被过滤掉的 id，
/// 解析器也当没看见（`SuggestionParser.parse` 收的就是这个返回值）。
///
/// **它永远不会返回空列表**（见下面那段的理由），所以调用方不需要「空了怎么办」
/// 的分支。`test/mail_action_pool_test.dart` 用一个 16 种组合的穷举把它钉住了。
///
/// 顺序 = 给模型的候选顺序 = 兜底时的偏好顺序（越靠前的越「该做」）。
List<MailAction> suggestActionPool({
  required bool isUnread,
  required bool isStarred,
  required bool starEnabled,
  required bool hasBody,
}) {
  // 过滤表（spec §2.3）逐行对应：
  //   已读 → 去掉 markRead；未读 → 去掉 markUnread（布尔，恒有一条留下）
  //   已加星 → 去掉 star；没加星 → 去掉 unstar（同理）
  //   没有星标能力 → star / unstar 一起走
  //   正文一个字都没有 → reply / forward 一起走（写不出回信、也写不出附言）
  //
  // `none` / `remind` / `delete` 三条无条件在池子里。最坏情况（空正文 +
  // 无星标能力）剩下 none / remind / delete / 一条已读未读 —— 依然挑得动。
  return <MailAction>[
    if (hasBody) MailAction.reply,
    if (hasBody) MailAction.forward,
    MailAction.remind,
    MailAction.delete,
    if (isUnread) MailAction.markRead else MailAction.markUnread,
    if (starEnabled) ...[
      if (!isStarred) MailAction.star else MailAction.unstar,
    ],
    MailAction.none,
  ];
}

/// 面板上的名字。**走 l10n**（spec §10.2 给了中英两份）。
///
/// 与 [MailAction.promptLine] 分工明确：那一份是「这个动作是什么」的开发者
/// 说明，这一份是给人看的两三个字。合并成一份会让 prompt 里出现「答复」这种
/// 没有宾语的词，而「给模型的动词语义」是 `ai_prompts.dart` 那张表的事。
String labelOf(MailAction action, AppLocalizations l10n) => switch (action) {
      MailAction.reply => l10n.aiSuggestActionReply,
      MailAction.forward => l10n.aiSuggestActionForward,
      MailAction.remind => l10n.aiSuggestActionRemind,
      MailAction.delete => l10n.aiSuggestActionDelete,
      MailAction.markRead => l10n.aiSuggestActionMarkRead,
      MailAction.markUnread => l10n.aiSuggestActionMarkUnread,
      MailAction.star => l10n.aiSuggestActionStar,
      MailAction.unstar => l10n.aiSuggestActionUnstar,
      MailAction.none => l10n.aiSuggestActionNone,
    };

/// 面板上每个动作的图标。**与 [labelOf] 同一层**：都是界面的事。
///
/// `MailAction.id` / `promptLine` 才是协议（模型看到的字、解析器认的字），
/// 所以这个映射也**不是** `MailAction` 的字段 —— 图标是可以随便换的，
/// 换它不该动到枚举。
///
/// `star` / `unstar` 这一对**按信件当前状态画**，不是按动作名画：`star` 这个
/// 动作只在「这封信还没加星」时才在池子里（[suggestActionPool] 的过滤保证了
/// 这一点），所以它画**空心**；反之 `unstar` 画实心。与详情页顶栏那颗星、
/// 列表行菜单那一对**逐字同一个约定**（`mail_detail_screen.dart` /
/// `mail_row_menu.dart`）。
///
/// 返回 `IconData` 而不是直接返回 `Widget`：这一层不该知道尺寸与颜色 ——
/// 最推荐那张卡上的图标要用主色、其余的用中性色，那是面板的事。
///
/// **这是个 `switch` 表达式**，所以新增一个 `MailAction` 时这里编译不过，
/// 比「每个动作都有图标」的断言更强；`test/mail_action_pool_test.dart` 那条
/// 「每个动作的图标两两不同」钉的是它管不住的另一半。
IconData iconOf(MailAction action) => switch (action) {
      MailAction.reply => Icons.reply,
      // **不用 `Icons.forward`**：它和 `reply` 都是一支箭头，一排图标里形状
      // 分不开。`forward_to_inbox`（信封 + 箭头）语义更明确，代价是比别的
      // 图标重一点 —— 换来的是「不用读旁边的字就知道这是转发」。
      MailAction.forward => Icons.forward_to_inbox,
      MailAction.remind => Icons.alarm,
      MailAction.delete => Icons.delete_outline,
      MailAction.markRead => Icons.mark_email_read_outlined,
      MailAction.markUnread => Icons.mark_email_unread_outlined,
      // 见上面那段：这一对是**反的**，故意的。
      MailAction.star => Icons.star_border,
      MailAction.unstar => Icons.star,
      MailAction.none => Icons.done_all,
    };
