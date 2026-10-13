import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/mail_providers.dart';
import '../../providers/profile_providers.dart';
import 'compose_launcher.dart';

/// 写邮件入口。**外壳那一颗**（窄屏与宽屏各一支，都在 `AppShell` 里），
/// 以及宽屏侧栏顶部那颗按钮。
///
/// 从「页面各自挂」改成「外壳统一挂」是在这一轮：原来只有主屏网格与收件箱
/// 列表各有一颗，星标 / 发件箱 / 草稿箱 / 附件缓存 / 邮件详情上都没有。
///
/// ## 为什么只有外壳这一颗
///
/// 外壳的 `Scaffold` 是各页 `Scaffold` 的**祖先**，它把
/// `floatingActionButton` 画在 body 最上层 —— 页面上再挂一颗会被它盖住
/// （看不见，但代码照跑）。所以「页面上有按钮」这件事没有任何意义，
/// 判据函数 `pageOwnsComposeFab` 连同各页那颗一并删掉了。
///
/// 页面上再画一颗的**陷阱**（上一版踩过的）：外壳要靠地址判断「现在这一屏
/// 有没有自带 FAB」，而 `GoRouterState.of(context)` 在外壳那一层会慢一帧
/// （外壳可能看到新地址、却还在渲染旧分支），于是按钮时有时无。
/// 现在不做这个判断了。
///
/// 内容区那颗 FAB 有两处需要留意，但都不是「再挂一颗」能解决的：
/// - **宽屏分栏**（`MailPanes`，各列表页在 >= 1024 时走的那一支）：FAB 会压在
///   阅读区右下角。阅读区是滚动容器，被压住的是空白边距，可接受；
/// - **弹层**：附件面板 / 邮箱筛选面板是本页 `Scaffold` 的 `showModalBottomSheet`，
///   而 FAB 挂在**外壳**的 `Scaffold` 上 —— 模态层比它高一个 Navigator，
///   所以弹层打开时 FAB 照样压在弹层上面。这一条是「一颗覆盖所有页面」换来的，
///   记在这里。
///
/// 写邮件页与同步页是**顶层路由**（在外壳之上），推上去整棵盖住外壳，
/// 这一颗自动不可见 —— 所以 `/compose` 也不需要例外。
///
/// ## 两处刻意不给的地方
///
/// 判据是 `AppShell` 里的 `showsComposeFab`：设置那一支（含诊断 / 推送 /
/// 加实例子页），以及**宽屏的**详情页（右栏是阅读区，按钮正压在正文右下角）。
/// 两处都不是「谁挂」的问题，是「这一屏本来就不该有」。
///
/// ## 形状与图标
///
/// 圆形 + 加号，`CircleBorder` 显式给（M3 下三种尺寸的默认形状全是圆角方块，
/// 见 `fab: true` 那一支的注释）。侧栏那颗是同一个图标（`Icons.add`），
/// 与它是同一件事的两个入口。
///
/// ## 预选的发件箱从哪来
///
/// 收件箱那一屏原本那颗会按用户勾选的邮箱预选发件人。现在那一颗没了，
/// 信息由列表屏发布到 [composePreselectProvider]，这里读。
///
/// 发信被**明确**关掉时（站点配置 `send == 0`，或这台实例的账号没有
/// `email:send`）整个入口不出现：给一个点进去只写着「本实例不可发信」的
/// 按钮，比没有更差。`unknown`（还没探测完）按可用处理，与
/// [InstanceCapabilities.sendEnabled] 的约定一致 —— 冷启动就藏入口，
/// 用户会以为功能没了。一个实例都没有时同理（写邮件页连发件人都填不出来）。
class ComposeAction extends ConsumerWidget {
  const ComposeAction({super.key, this.fab = false});

  /// true 画成 `FloatingActionButton`（外壳用），
  /// false 画成 `IconButton`（宽屏侧栏顶部用）。
  final bool fab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 一个实例都没有时不出现：写邮件页要落到 `currentProfileProvider`，
    // 没有实例时它连发件人都填不出来。这与主屏把那些入口置灰是同一条判据。
    if (ref.watch(activeProfilesProvider).isEmpty) {
      return const SizedBox.shrink();
    }
    // 发信被**明确**关掉时也整个不出现。给一个点进去只写着「本实例不可发信」
    // 的按钮，比没有更差。
    if (!ref.watch(canSendProvider)) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);

    // 顶层 `push`（不是 `go`）：写邮件是**流程**不是「一个地方」，
    // 与 `Routes.compose` 的注释同一条理由 —— 用完就该被回收，连同
    // 「离开即存草稿」那套兜底。
    //
    // 地址怎么拼收在 [openNewCompose] 里，`Cmd+N` 走的是同一个函数：两处
    // 各拼一遍的话，「预选发件箱」迟早只在其中一处生效。
    void open() => openNewCompose(context, ref);

    if (fab) {
      // 圆形 + 一个加号。
      //
      // `shape: CircleBorder()` 是**显式**给的，不是靠默认值：Material 3 下
      // 三种 FAB（regular / small / large）的默认形状全是 `RoundedRectangleBorder`
      // —— `_FABDefaultsM3.shape` 那张表里没有一个圆（`.small` 是 40×40、
      // 圆角 12，看着像圆但不是）。只把图标换成加号、形状交默认，出来的会是
      // 一个圆角方块。也不通过 `floatingActionButtonTheme` 全局配：本仓库的
      // 主题（`core/theme/`）目前没动过 FAB 的形状，为这一颗按钮加一条全局
      // 规则，收益只有省下这一行。
      return FloatingActionButton(
        tooltip: l10n.compose,
        shape: const CircleBorder(),
        onPressed: open,
        child: const Icon(Icons.add),
      );
    }
    return IconButton(
      tooltip: l10n.compose,
      icon: const Icon(Icons.add),
      onPressed: open,
    );
  }
}
