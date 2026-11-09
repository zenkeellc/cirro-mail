import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../router.dart';
import 'compose_draft.dart';
import 'compose_preselect.dart';

/// 「打开写邮件页」的**唯一**实现（三条路各一个函数）。
///
/// 为什么要收口：`Cmd/Ctrl+N` 必须和外壳那颗 FAB 开出**同一个**地址（含
/// [composePreselectProvider] 预选的发件箱），`Cmd/Ctrl+R` 必须和详情页那颗
/// 回形箭头开出同一个地址。各写一遍的话，「预选发件箱」这个行为迟早只在
/// 其中一处生效 —— 症状是「点 FAB 从对的邮箱发，按快捷键从默认邮箱发」，
/// 而这两个入口从代码上看不出任何联系。
///
/// ## 为什么是 `go` 而不是 `push`（2026-11）
///
/// 撰写页从**顶层路由**搬进了「邮件」那一支里的一个根路由（与 `/drafts`、
/// `/outbox` 同级）：它要出现在外壳里、只占内容区、并且能被左侧菜单像切页面
/// 一样切来切去。分支根路由没有可 pop 的栈，所以进入统一 `go`、离开统一
/// `go(回去的地方)`。
///
/// 「回去的地方」写进地址的 `from` 参数（[Routes.fromParam]），而不是塞在
/// provider 里：切到另一个撰写页、或刷新/重启后再关页，`from` 都还在；
/// 页面自己也不需要知道「我是不是被 push 上来的」。
///
/// 页间切换（已经在撰写页、又点了另一封）**沿用原来的 `from`** —— 否则
/// 「A → 切到 B → 关掉 B」会回到 A 这个已经不存在的撰写页地址。
String composeReturnOf(BuildContext context) {
  final uri = GoRouterState.of(context).uri;
  if (uri.path == Routes.compose) {
    final kept = uri.queryParameters[Routes.fromParam];
    if (kept != null && kept.isNotEmpty) return kept;
  }
  return uri.toString();
}

/// 去撰写页。地址上补 `from`（已有则沿用），然后 `go`。
void openComposeAt(BuildContext context, String location) {
  final target = Uri.parse(location);
  final params = <String, String>{
    ...target.queryParameters,
    Routes.fromParam: composeReturnOf(context),
  };
  context.go(target.replace(queryParameters: params).toString());
}

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
  openComposeAt(
    context,
    Routes.composeOf(
      profileId: preselect?.profileId,
      accountId: preselect == null || preselect.accountId == 0
          ? null
          : preselect.accountId,
    ),
  );
}

/// 打开一封**已经存在**的草稿（左侧「邮件撰写」的子项 / 草稿箱里点开）。
///
/// 与「写新的」是同一个入口形状：地址里带 `draft`，`ComposeEntry` 据此装载
/// 草稿内容并补上「打开中」标记。
void openComposeDraft(
  BuildContext context, {
  required int draftId,
  String? profileId,
}) {
  if (draftId <= 0) return;
  openComposeAt(
    context,
    Routes.composeOf(profileId: profileId, draftId: draftId),
  );
}

/// 回复 / 转发某一封（详情页那颗图标 / `Cmd+R` / `Cmd+Shift+F`）。
///
/// **[profileId] 用邮件自己那一行的实例，不是「当前实例」**：聚合视图里
/// 回复一封来自实例 B 的信时，用户可能已经把当前实例切成了 A —— 发信必须
/// 走 B（`row.profileId`）。调用方负责把空串退回它自己那个实例 id。
///
/// **不落草稿**：与 AI 建议面板那条（`MailActionRunner._openCompose` 先
/// `saveDraft` 再打开）是**两条不同的路** —— 那个差异的原委写在原处（AI 那条
/// 要把模型生成的草稿正文带进去，落库是它的产物）。把两条合成一条会顺手改掉
/// 其中一边的行为，所以这里只拼地址。
void openMailCompose(
  BuildContext context, {
  required ComposeMode mode,
  required String profileId,
  required int emailId,
}) {
  openComposeAt(
    context,
    Routes.composeOf(profileId: profileId, emailId: emailId, mode: mode),
  );
}
