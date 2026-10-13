import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/window_channel.dart';
import '../../data/models/mail_ref.dart';
import '../../providers/core_providers.dart';
import '../../router.dart';
import '../compose/compose_draft.dart';
import '../compose/compose_launcher.dart';
import '../suggest/mail_action.dart';
import '../suggest/mail_action_runner.dart';
import '../suggest/suggestion.dart';
import 'mail_intents.dart';

/// 从当前地址解出「用户正在看的那一封」。
///
/// ## 为什么从地址解，而不是新加一个全局「列表选中态」
///
/// 宽屏分栏的选中态今天就在**地址**里（`?sel=<emailId>&profile=<pid>`，
/// 见 `Routes.mailOf` 的注释），窄屏详情页在**路径段**里。再造一份全局状态
/// 就有两个真相：切分支、点通知深链、浏览器/系统返回之后它们会漂，而症状
/// 是「快捷键删掉了另一封」—— 最难查的那一类。
///
/// ## 五种语法
///
/// | 地址 | 场景 |
/// |---|---|
/// | `/mail/<p>/<e>` | 窄屏实例列表的详情 |
/// | `/mail/<all\|节点>/<e>?profile=<p>` | 窄屏聚合详情的详情 |
/// | `/starred/<e>?profile=<p>` | 窄屏星标详情 |
/// | `/mail/<p>?sel=<e>` | 宽屏收件箱的右栏 |
/// | `/starred?sel=<e>&profile=<p>` | 宽屏星标的右栏 |
///
/// **不按窗口宽度判**（与 `router.dart:_selectedOf` 的 `wide: true` 不同）：
/// 快捷键要的是「屏幕上正看着哪一封」，窄屏详情页同样满足这一条 ——
/// 在窄屏按 `Cmd+D` 删掉正打开的那封信是完全合理的。`?sel=` 在窄屏解不出
/// 右栏，但那条地址在窄屏根本不会出现（`_paneRedirect` 只在宽屏折返）。
///
/// 解不出就返回 null，调用方**静默不做**：快捷键按下去没反应是常态
/// （在设置页按 `Cmd+D` 什么也不该发生），弹一句「请先选一封」反而更吵。
MailRef? currentMailRef(Uri uri) {
  final profileParam = uri.queryParameters['profile'] ?? '';
  final segments = uri.pathSegments;

  // `/mail/<node>/<emailId>`（三段）与 `/starred/<emailId>`（两段）。
  // 用模式匹配而不是按 `length` 判：`/mail/p1` 那种列表地址必须是「落不下去、
  // 继续看 `?sel=`」，而不是被当成详情。
  final (root, emailIdAt) = switch (segments) {
    ['mail', _, _] => ('mail', 2),
    ['starred', _] => ('starred', 1),
    _ => (null, 0),
  };

  if (root != null) {
    final emailId = int.tryParse(segments[emailIdAt]) ?? 0;
    if (emailId > 0) {
      // `/mail/all` 那种聚合节点在路径段里**不是实例** —— `parseProfileId`
      // 对 `all` 返回 null，于是要靠 `?profile=` 补。星标路由的路径里压根
      // 没有实例那一段，直接取查询参数。
      final profileId = root == 'mail'
          ? Routes.parseProfileId(segments[1]) ?? profileParam
          : profileParam;
      if (profileId.isNotEmpty) {
        return MailRef(profileId: profileId, emailId: emailId);
      }
    }
    // 落到这里说明「路径段那条不够用」（列表地址 / 缺实例参数）——把 `?sel=`
    // 那一路走完再放弃。
  }

  final selected = int.tryParse(uri.queryParameters['sel'] ?? '') ?? 0;
  if (selected <= 0) return null;
  // `?sel=` 那一路的实例：收件箱看路径段（`/mail/p1?sel=`），星标看查询参数。
  final profileId = (segments.length > 1
          ? Routes.parseProfileId(segments[1])
          : null) ??
      profileParam;
  if (profileId.isEmpty) return null;
  return MailRef(profileId: profileId, emailId: selected);
}

/// 宿主层的快捷键接线柱。**整个 app 只有这一层**。
///
/// 形状是 `Shortcuts > Actions > child`：**`Actions` 必须在里面**。
/// `Actions.maybeFind` 是从 primaryFocus 的 context 往上找，
/// `Actions` 挂外层而 `Shortcuts` 挂内层时，内层解出的 intent 找不到 Action，
/// 表现是「按了没反应」——探针 P3 实测过这个反例。
///
/// ## 它为什么摆在 `MaterialApp.builder` 那一层
///
/// **这一层是整棵焦点树上最外面的一层 `Shortcuts`** —— 探针实测过：在
/// `builder` 里绑上 `Cmd+C`，它会先于框架的剪贴板命中（`hijacked=1`,
/// `copied=[]`）。也就是说**按键表是全权的**：我们占了什么键，框架与 quill
/// 就再也收不到它。
///
/// 这有两层意思：
///
/// 1. **这是个好位置**：「页面层的 `Shortcuts` 盖得住它」这条仍然成立顺理成章
///    （页面在更里面），但「框架盖得住它」**不**成立 —— 所以
///    `mailShortcutsFor` 那座表里一个编辑键都不能有。
///    `test/mail_shortcuts_keymap_test.dart` 里那条「不截剪贴板与撤销」的用例
///    是它的防线，`test/mail_shortcuts_clipboard_test.dart` 是端到端的验证。
/// 2. **这也意味着它不能乱扩张**：将来往表里加键（比如裸字母 `j`/`k`）时，
///    必须清楚它是在**全局**抢占 —— 文本输入框、quill、对话框全在内。
///
/// Esc 那个特例值得单独说：`MailShortcutHost` **不绑** Esc。写邮件页自己那层
/// 绑（页面比它近，赢），其余页面让 Esc 落到框架的 `escape → DismissIntent`
/// 与 quill 上 —— 那两处各有用处（关对话框 / 收起选区工具栏），抢占只会更糟。
///
/// ## 为什么地址从 provider 读，而不是 `GoRouterState.of(context)`
///
/// `ShortcutManager.handleKeypress` 传进来的 context 是
/// **primaryFocus 的 context**（`shortcuts.dart:922`）—— 它在被推入那一页的
/// **里面**。拿它 `GoRouterState.of` 解析到的是当前页，恰好也对，但那是个
/// 巧合：焦点在别处（比如某个 `OverlayPortal`、或者壳层的 FAB 上）时就不成立。
/// 路由器是全局唯一的（`routerProvider`，对话框那一类弹层不会换掉它），
/// 从它身上读地址每次都对。
class MailShortcutHost extends ConsumerWidget {
  const MailShortcutHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 用主题里的 `platform` 而不是 `defaultTargetPlatform`：桌面上可以
    // 跑 web 构建，那时两者的答案不一样，而用户看到的「Command 键」是前者。
    final platform = Theme.of(context).platform;
    return Shortcuts(
      shortcuts: mailShortcutsFor(platform),
      child: Actions(
        actions: <Type, Action<Intent>>{
          NewMailIntent: _NewMailAction(ref),
          ReplyMailIntent: _MailComposeAction(ref, ComposeMode.reply),
          ForwardMailIntent: _MailComposeAction(ref, ComposeMode.forward),
          DeleteMailIntent: _DeleteCurrentMailAction(ref),
          OpenSettingsIntent: _OpenSettingsAction(ref),
          HideWindowIntent: _HideWindowAction(),
          // `SendMailIntent` **故意不在这里**：它要拿写邮件页的控制器，
          // 而这一层拿不到。挂在这儿的表现是「Cmd+Enter 按了没反应」。
        },
        child: child,
      ),
    );
  }
}

/// 当前地址（从全局唯一那个路由器上读）。
Uri _currentUri(WidgetRef ref) =>
    ref.read(routerProvider).routerDelegate.currentConfiguration.uri;

/// 新建。
///
/// ## 为什么不是 `CallbackAction`
///
/// `CallbackAction` 走的是 `Action.invoke(intent)` —— **拿不到 context**
/// （`actions.dart:356` 那条 `switch`：只有 `ContextAction` 才收
/// `invoke(intent, context)`）。于是它只能闭包捕获 `MailShortcutHost.build`
/// 那个 context，而那一层在 `InheritedGoRouter` **外面**（`builder` 的输出是
/// `Router` 的祖先）：`context.push` 当场抛 `No GoRouter found in context`。
/// 实测过，这条用例就是这个反例。
///
/// 写成 `ContextAction` 拿到的才是 `primaryFocus.context` —— 它在被推入的
/// 那一页**里面**，也就在 `InheritedGoRouter` 里面。
class _NewMailAction extends ContextAction<NewMailIntent> {
  _NewMailAction(this.ref);

  final WidgetRef ref;

  @override
  void invoke(NewMailIntent intent, [BuildContext? context]) {
    if (context == null) return;
    // 与外壳那颗 FAB 走**同一个** [openNewCompose]：「预选发件箱」只有一份
    // 实现（`composePreselectProvider`），各拼一遍迟早只在其中一处生效。
    openNewCompose(context, ref);
  }
}

/// 回复 / 转发「当前那一封」。两个动作共用一个 Action 类，靠 [mode] 区分。
class _MailComposeAction extends ContextAction<Intent> {
  _MailComposeAction(this.ref, this.mode);

  final WidgetRef ref;
  final ComposeMode mode;

  @override
  void invoke(Intent intent, [BuildContext? context]) {
    // `context` 可能是 null（`Actions.invoke` 有一条不带 context 的调用路径）——
    // 直接返回，不做任何事：宁可没反应，也不要拿一个空 context 去 push。
    if (context == null) return;
    final target = currentMailRef(_currentUri(ref));
    if (target == null) return; // 列表页没选任何一封：静默不做（见 currentMailRef）
    openMailCompose(
      context,
      mode: mode,
      profileId: target.profileId,
      emailId: target.emailId,
    );
  }
}

/// 删除「当前那一封」。
///
/// ## 为什么绕一层 `MailActionRunner`
///
/// 那是 spec 定下的「本规格新加动作的**唯一执行处**」
/// （`mail_action_runner.dart:34`）。它里面有三件在这一层重新实现必错的事：
/// 确认框要说清**是哪封信**（`aiSuggestDeleteConfirm(displaySubject)`）、
/// **删之前先撤掉提醒排期**（不撤的话用户删了信还会在周五被提醒一次那封
/// 已经不存在的邮件）、以及异常统一转成一条 SnackBar。自己再写一遍就正好是
/// 那段注释里警告过的「两处各自实现一遍收尾」。
///
/// ## 为什么用 `_currentUri` 那个地址**取一带**，而不是复用外面的
///
/// `invoke` 里要 `await`（确认框 + 删库），而 `currentMailRef` 读的是
/// **异步之后**的地址 —— 用户在对话框里等着的这段时间里地址不该变，但真变了
/// （通知深链推进来一页）也不该拿旧的行去删新的一封。所以地址**只读一次**、
/// 行也只查一次。
class _DeleteCurrentMailAction extends ContextAction<DeleteMailIntent> {
  _DeleteCurrentMailAction(this.ref);

  final WidgetRef ref;

  @override
  Future<void> invoke(DeleteMailIntent intent, [BuildContext? context]) async {
    if (context == null) return;
    final target = currentMailRef(_currentUri(ref));
    if (target == null) return;

    // 行要从本地库现查：`MailActionRunner` 要的是一整个 `MailRow`（它要用
    // `displaySubject` 问用户「删除「XX」？」、要 `profileId`/`emailId` 拼
    // `MailRef`），而快捷键这一路手里只有一个 `MailRef`。
    final row = await ref
        .read(databaseProvider)
        .mailDao
        .find(target.profileId, target.emailId);
    // 查不到 = 这一封还没同步下来（或者刚被别处删了）。静默不做 ——
    // 另一种选择是弹一个「这封信还没同步好」，而用户按快捷键时并不想听解释。
    if (row == null) return;
    // `await` 之后 context 可能已经失效（这一层是长驻的，但那个 context 属于
    // 被推入的那一页，中间用户可能已经返回）。查一下而不是赌。
    if (!context.mounted) return;

    await MailActionRunner.execute(
      context,
      ref,
      row: row,
      choice: const SuggestionChoice(action: MailAction.delete),
      // **不给 `onDeleted`**：那个回调是「内嵌详情页要把右栏选中清掉」用的，
      // 而快捷键这一路没有宿主视图。删完之后列表会自己变空态 ——
      // `mailDetailProvider` 推出 null，`MailPanes` 落进 `selected == null`
      // 那一支（与手动点 ⋯ 菜单删掉同一封的表现完全一致）。
    );
  }
}

/// 打开设置页（`Cmd/Ctrl+,`）。
///
/// ## 为什么用 `ref.read(routerProvider).go`，而不是 `context.go`
///
/// 与 [_NewMailAction] 那条正好相反：`context.go` / `context.push` 靠的是
/// `InheritedGoRouter`，而 `Action.invoke(intent, context)` 拿到的 context 是
/// **primaryFocus 的 context** —— 焦点落在对话框、`OverlayPortal`、或者说
/// 某个还没有路由的启动页上时，那条链上就没有 `InheritedGoRouter`，当场抛
/// `No GoRouter found in context`。设置页是一个**全局的去处**（跟焦点在哪儿
/// 没关系），从 `routerProvider` 上读是唯一在哪儿都对的做法
/// —— [_currentUri] 读地址用的是同一个理由。
///
/// 写成 `ContextAction`（而不是 `CallbackAction`）与 [_NewMailAction] 保持
/// 一致，将来要加「已经在设置页就不重复跳」这类判断时不必换基类。
class _OpenSettingsAction extends ContextAction<OpenSettingsIntent> {
  _OpenSettingsAction(this.ref);

  final WidgetRef ref;

  @override
  void invoke(OpenSettingsIntent intent, [BuildContext? context]) {
    // 用 `go` 不用 `push`：设置页是外壳 `StatefulShellBranch` 的一格
    // （`router.dart:503`，与侧栏那颗齿轮**同一格**），`push` 会把它叠成
    // 一层盖住侧栏的空白页 —— 侧栏那颗齿轮现在就是 `go`。
    ref.read(routerProvider).go(Routes.settings);
  }
}

/// 把主窗口藏起来（`Cmd/Ctrl+W`）。
///
/// 语义是「藏起来」（与点窗口的关闭按钮同一件事），**不是退出** —— 详见
/// [WindowChannel.hide] 与 `mail_intents.dart` 里 [HideWindowIntent] 的注释。
///
/// 这一条用 `CallbackAction` 就行：它不需要 context，也不需要 intent 里的
/// 任何东西 —— 调完之后窗口就没了，本来也没有「在哪个页面按的」这回事。
/// 用 `ContextAction` 反而要处理 `context == null` 那一支。
class _HideWindowAction extends CallbackAction<HideWindowIntent> {
  _HideWindowAction() : super(onInvoke: _invoke);

  static Object? _invoke(HideWindowIntent intent) {
    // `WindowChannel.hide` 自己是不抛的（非桌面平台 / 旧构建都是静默空操作），
    // 这里不 `await`：`unawaited` 之外没有必要 —— 按键处理不关心那次 IPC
    // 什么时候回来。
    unawaited(WindowChannel.hide());
    return null;
  }
}
