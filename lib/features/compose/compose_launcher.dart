import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../router.dart';
import 'compose_draft.dart';
import 'compose_preselect.dart';

/// 「打开写邮件页」的**唯一**实现（两条路各一个函数）。
///
/// 为什么要收口：`Cmd/Ctrl+N` 必须和外壳那颗 FAB 开出**同一个**地址（含
/// [composePreselectProvider] 预选的发件箱），`Cmd/Ctrl+R` 必须和详情页那颗
/// 回形箭头开出同一个地址。各写一遍的话，「预选发件箱」这个行为迟早只在
/// 其中一处生效 —— 症状是「点 FAB 从对的邮箱发，按快捷键从默认邮箱发」，
/// 而这两个入口从代码上看不出任何联系。
///
/// 两条路都走**顶层 `push`**（不是 `go`）：写邮件是**流程**不是「一个地方」，
/// 用完就该被回收，连同「离开即存草稿」那套兜底。理由与
/// `Routes.compose` 的注释同源。

/// 写一封新的（FAB / 侧栏那颗 / `Cmd+N`）。
///
/// 预选的发件箱由 [openNewComposeWith] 决定 —— 这个重载只是它的
/// 「读一遍 provider」版本。
void openNewCompose(BuildContext context, WidgetRef ref) =>
    openNewComposeWith(context, ref.read(composePreselectProvider));

/// [preselect] 为 null = 「说不清从哪个邮箱发」→ 地址里不带 `profile` /
/// `account`，写邮件页落到当前实例的默认邮箱（`ComposeArgs.resolveProfileId`）。
///
/// [kAllMailboxes]（0）是合并项，同样不写进地址：`ComposeArgs.hasMailboxHint`
/// 只认 > 0，给 0 与不给是同一件事，但地址会多一个看着像「选中了第 0 个邮箱」
/// 的尾巴。
void openNewComposeWith(BuildContext context, ComposePreselect? preselect) {
  context.push(
    Routes.composeOf(
      profileId: preselect?.profileId,
      accountId: preselect == null || preselect.accountId == 0
          ? null
          : preselect.accountId,
    ),
  );
}

/// 回复 / 转发某一封（详情页那颗图标 / `Cmd+R` / `Cmd+Shift+F`）。
///
/// **[profileId] 用邮件自己那一行的实例，不是「当前实例」**：聚合视图里
/// 回复一封来自实例 B 的信时，用户可能已经把当前实例切成了 A —— 发信必须
/// 走 B（`row.profileId`）。调用方负责把空串退回它自己那个实例 id。
///
/// **不落草稿**：与 AI 建议面板那条（`MailActionRunner._openCompose` 先
/// `saveDraft` 再 push）是**两条不同的路** —— 那个差异的原委写在原处（AI 那条
/// 要把模型生成的草稿正文带进去，落库是它的产物）。把两条合成一条会顺手改掉
/// 其中一边的行为，所以这里只拼地址。
void openMailCompose(
  BuildContext context, {
  required ComposeMode mode,
  required String profileId,
  required int emailId,
}) {
  context.push(
    Routes.composeOf(profileId: profileId, emailId: emailId, mode: mode),
  );
}
