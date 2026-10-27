import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/mail_row.dart';
import '../../l10n/app_localizations.dart';
import '../compose/compose_draft.dart';
import '../compose/compose_launcher.dart';
import '../suggest/mail_action.dart';
import '../suggest/mail_action_runner.dart';
import '../suggest/suggestion.dart';

/// 详情页正文的右键菜单：**在选区之上再加几项邮件动作**。
///
/// 形状与 `../compose/editor/editor_context_menu.dart` 是同一套：条目取
/// `state.contextMenuButtonItems`（框架按「有没有非折叠选区」算出来的
/// `复制` / `全选`），再往后拼自己的。**不自己拼那两个** —— 它们的
/// `enabled` 与回调都是框架的 `getSelectableButtonItems`
/// （`selectable_region.dart:302-340`）算的，自己拼会漏判。
///
/// ## ⚠️ `contextMenuAnchors` 只能读一次，且必须**最后**读
///
/// 那个 getter 读完就把 `_lastSecondaryTapDownPosition` 清空
/// （`selectable_region.dart:1602-1609`，注释写着 "Clear the state … after use
/// since a user may access contextMenuAnchors and receive invalid anchors"）。
/// 所以**不能**用 `AdaptiveTextSelectionToolbar.selectableRegion(…)` 再自己读一遍
/// anchors；`state.contextMenuButtonItems`（`:1702`）不碰它，先读条目、最后读
/// anchors 才安全。
///
/// 也因此这个函数**不能**在 `SelectionArea` 外面被复用成「工具条 + 菜单」两个
/// 调用点 —— 一个 `contextMenuBuilder` 只会被调一次，这是它的前提。
///
/// ## ⚠️ 动作要用 [actionContext]，**不能**用 [menuContext]
///
/// [menuContext] 是 `contextMenuBuilder` 收到的那个 context —— 它在菜单那条
/// **overlay entry** 里面。菜单一收，那棵子树就没了，于是
/// `MailActionRunner.execute` 里 `_delete` 的那句
/// `if (!ok || !context.mounted) return;` 会在**确认框点完之后**成立：
/// 弹窗照弹、用户点了「确定」、然后什么都没发生（实测：`closed=0`、
/// 库里那一行还在、连 SnackBar 都没有）。原因是 `await showDialog(...)`
/// 回来的那一刻，前面那句 `state.hideToolbar()` 已经把 entry 摘掉了。
///
/// [actionContext] 由调用方给**详情页自己那一层**的 context
/// （`mail_detail_screen.dart` 的 `_body` 把 `State.context` 传进来）——
/// 页面在它就在，菜单开合与它无关。
///
/// ## 为什么菜单里这几项，而不是把顶栏那颗 ⋯ 菜单搬过来
///
/// 用户说「刚选了一段字，顺手做点什么」。所以放的是**与这一封有关**的
/// 回复 / 全部回复 / 转发 / 删除，而不是「标为已读 / 星标」那一类 ——
/// 后者不依赖选区，顶栏那两颗按钮和 ⋯ 菜单里已经有了，右键里再来一遍只会
/// 让菜单变长。
///
/// **与列表页的右键是两回事，有意不复用**：列表页走
/// `mail_list_view.dart:159-167` → `MailRowMenu.show`（行操作），而且那一层
/// 不在任何 `SelectionArea` 底下。两个界面、两种语义。
///
/// ## 每一项都指向既有的执行处，一条新路径都不造
///
/// - 回复 / 全部回复 / 转发：与详情页顶栏那几颗按钮**同一个函数** ——
///   `openMailCompose`（`compose_launcher.dart`），而不是自己拼地址；
/// - 删除：`MailActionRunner.execute`（`suggest/mail_action_runner.dart:44`），
///   那是 spec 定下的「本规格新加动作的唯一执行处」。它管着三件在这一层重新
///   实现必错的事：确认框要说清是哪封信、**删之前先撤掉提醒排期**、异常统一
///   转成一条 SnackBar。
///
/// [onDeleted] **必须传**：内嵌形态要靠它清掉右栏选中
/// （`mail_detail_screen.dart` 的 `_afterDelete`），整页形态要靠它 pop。漏掉
/// 就是那个「转不完的圈」的 bug（`mail_detail_screen.dart:549-556` 记着）。
///
/// ## 为什么不画分隔线
///
/// `ContextMenuButtonType` 没有 divider 这一类，而 macOS 的工具条是一个固定
/// **222pt 宽**的 `Column`（`cupertino/desktop_text_selection_toolbar.dart:25`）。
/// 里面塞一个自绘的 `Divider` 会一眼看出是拼的。全部走
/// `ContextMenuButtonItem`，用平台默认的按钮外观。
Widget mailDetailContextMenu(
  BuildContext menuContext,
  BuildContext actionContext,
  WidgetRef ref,
  MailRow row,
  SelectableRegionState state, {
  VoidCallback? onDeleted,
}) {
  final l10n = AppLocalizations.of(menuContext);
  return AdaptiveTextSelectionToolbar.buttonItems(
    buttonItems: <ContextMenuButtonItem>[
      // 框架给的：`复制`（只有存在非折叠选区时才在）与 `全选`。
      ...state.contextMenuButtonItems,
      // 下面这四项目的 `onPressed` 里都会先收掉菜单。
      //
      // ## 收菜单要用 `state.hideToolbar()`，**不是 `Navigator.pop()`**
      //
      // 这个菜单（`AdaptiveTextSelectionToolbar` 在工具栏那一条分支上）是
      // **一个 overlay entry**，不是一条路由 —— 框架给自己的 `复制` 收尾用的
      // 也是 `hideToolbar()`（`selectable_region.dart:1706-1723`，macOS /
      // linux / windows 那一支），quill 那些按钮同理。
      // `Navigator.of(context).pop()` 在这一层会**沿着 GoRouter 的导航栈往上
      // 找**：详情页是**整页**时它 pop 掉的是详情页本身（菜单没收、页面先没了），
      // 是**内嵌**形态时更糟 —— 右栏不是一条路由，pop 掉的是**根路由**
      // （`go_router/src/delegate.dart:178` 那句
      // `You have popped the last page off of the stack`）。
      // `hideToolbar()` 只摘自己那两条 overlay entry，收手也把手柄一起收
      // （默认 `hideHandles = true`，与框架 `复制` 那一支逐字一致）。
      ContextMenuButtonItem(
        label: l10n.reply,
        onPressed: () {
          state.hideToolbar();
          openMailCompose(
            actionContext,
            mode: ComposeMode.reply,
            profileId: row.profileId,
            emailId: row.emailId,
          );
        },
      ),
      // 「全部回复」紧跟在「回复」之后：两者是同一件事的两个范围，用户刚选完
      // 一段原文接着点它时，手与视线都还在「回复」那一行 —— 排到「转发」后面
      // 等于每次都要多扫一行才找得到。
      //
      // 收件人由 [ComposeDraftFactory.replyAllRecipients] 预填（去掉自己、
      // 排除密送、去重），这里只负责把模式传下去。
      ContextMenuButtonItem(
        label: l10n.replyAll,
        onPressed: () {
          state.hideToolbar();
          openMailCompose(
            actionContext,
            mode: ComposeMode.replyAll,
            profileId: row.profileId,
            emailId: row.emailId,
          );
        },
      ),
      ContextMenuButtonItem(
        label: l10n.forward,
        onPressed: () {
          state.hideToolbar();
          openMailCompose(
            actionContext,
            mode: ComposeMode.forward,
            profileId: row.profileId,
            emailId: row.emailId,
          );
        },
      ),
      ContextMenuButtonItem(
        label: l10n.delete,
        onPressed: () {
          state.hideToolbar();
          MailActionRunner.execute(
            actionContext,
            ref,
            row: row,
            choice: const SuggestionChoice(action: MailAction.delete),
            onDeleted: onDeleted,
          );
        },
      ),
    ],
    // **最后**才读（见类注释第一段）。
    anchors: state.contextMenuAnchors,
  );
}
