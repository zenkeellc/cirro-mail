import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/sync_providers.dart';
import '../../router.dart';
import '../mail_list/mailbox_scope.dart';
import 'home_entries.dart';

/// 点一个主屏入口之后该做什么。
///
/// 抽成枚举 + 纯函数（而不是直接写在 `openHomeEntry` 里）是为了能脱离
/// `BuildContext` 测：下面那几条判断里，「已经在那一项上时退回列表」与
/// 「别的分支只能 go」都要靠当前地址算出来，而它们错了的表现是「点进去出不来」
/// 或者「叠出第二个列表页」—— 都不是跑一次就能看见的。
enum HomeNav {
  /// 什么都不做（已经在那一项的根上）。
  none,

  /// 退回这一项的根（此刻停在它的子路径上：详情页）。
  backToRoot,

  /// 换掉当前分支的栈。
  go,

  /// 在当前分支上压一层（用返回箭头回来）。
  push,
}

/// 算一次。
///
/// [push] 由**调用方**的形态决定：窄屏 icon 网格没有别的出口，必须 `push`
/// 才能有返回箭头；宽屏侧栏本身就是一级导航、顶部条又没有返回箭头，
/// 只能 `go`（否则会叠出一摞退不回去的页面）。见 `openHomeEntry`。
HomeNav homeNavFor(
  HomeEntry entry,
  Uri current, {
  required bool push,
}) {
  if (entry.isSelectedBy(current)) {
    // 停在子路径上（`/outbox/7`、`/mail/all/7`）= 用户点这一项的意思是
    // 「退回列表」；已经在根上就是「点当前项」，什么都不做。
    return current.path == Uri.parse(entry.location).path
        ? HomeNav.none
        : HomeNav.backToRoot;
  }
  if (!push) return HomeNav.go;
  // 别的**分支**只能 go：push 会把它叠在邮件这一支上（go_router 的
  // `_createNewMatchUntilIncompatible` 发现 shell 不匹配时会克隆整支），
  // 于是星标页出现在邮件这一支的 Navigator 里，底部导航却还停在「邮件」。
  return entry.id == 'starred' ? HomeNav.go : HomeNav.push;
}

/// 点侧栏/主屏里的**实例行**之后该做什么。
///
/// 与 [homeNavFor] 是同一种判断，但只认一条专属判据 [instanceNodeOf]：
/// 「地址是不是正停在这一台实例的实例级列表上」。
///
/// **为什么不复用 [homeNavFor]**：`HomeEntry` 讲的是那七个一级入口，
/// 实例行不是其中之一 —— 今天拿收件箱那一项去算，`inbox.isSelectedBy`
/// 对 `/mail/p1` 返回的是 false（它认的是聚合节点 `all`），于是
/// 「已经在上面了」这条会被判成「不在」，窄屏再点一下就叠出第二张列表页。
///
/// 两条分支各自都重要：
/// - 已经在**根**上（`/mail/p1`）→ `none`，什么都不做；
/// - 已经在**子路径**上（`/mail/p1/7` 详情页）→ `backToRoot`，退回列表
///   （与 [HomeNav.backToRoot] 同一语义：用 `go` 换掉这一支的栈，列表页
///   因为 `pageKey` 没变而原地留着，滚动位置不丢）。
HomeNav instanceNavFor(
  Uri current, {
  required String profileId,
  required bool push,
}) {
  if (instanceNodeOf(current) == profileId) {
    final root = Uri.parse(Routes.mailOf(profileId)).path;
    return current.path == root ? HomeNav.none : HomeNav.backToRoot;
  }
  return push ? HomeNav.push : HomeNav.go;
}

/// 点一个主屏入口之后落在哪儿。
///
/// **窄屏的 icon 网格与宽屏的侧栏共用这一份**：两处各写一遍的话，
/// 「侧栏点得进去、网格点不进去」这种不一致不会报错，只会安静地存在，
/// 而它恰恰是最难被发现的（谁也不会同时开着两种宽度对点一遍）。
///
/// 两个调用点对「怎么过去」的要求**不一样**，所以由调用方用 [push] 说清楚：
///
/// - **窄屏网格**（< 600）：只有这一处能进这几个页面，底部导航又只认三支，
///   所以必须 `push` —— 压上去之后 `AppBar` 会自动带返回箭头，系统返回键
///   也成立。用 `go` 的话这些页面就是「进得去、出不来」（这一轮要修的
///   第一件事就是它）。
/// - **宽屏侧栏**（>= 600）：它自己就是一级导航（与底部导航同一个地位），
///   而且宽屏的顶部条是 `PaneHeader`（**没有返回箭头**）。在那儿 `push`
///   会叠出一摞谁也退不回去的页面，连着点几项还会同时存在两个
///   `MailListScreen`（drift 订阅与首屏补拉都翻倍）。所以侧栏一律 `go`。
void openHomeEntry(
  BuildContext context,
  WidgetRef ref,
  HomeEntry entry, {
  required Uri current,
  required bool push,
}) {
  switch (homeNavFor(entry, current, push: push)) {
    case HomeNav.none:
      break;
    case HomeNav.backToRoot:
      // 用 `go` 而不是 `push`：把这一支的栈换成列表那一层，详情出栈，
      // 而列表页本身因为 `pageKey`（取路由**模式串**）没变而原地留着，
      // 滚动位置不丢。
      context.go(entry.location);
    case HomeNav.go:
      context.go(entry.location);
    case HomeNav.push:
      context.push(entry.location);
  }

  // 这些入口都是**跨实例**的（地址由 `HomeEntries._list` 拼出来，或干脆是
  // 本机队列），所以一律把「活跃实例」清掉：留着某一台会让「当前在看哪台
  // 实例」的结论落在它上面，写邮件那个入口也就跟着落到那一台的默认邮箱。
  ref.read(syncControllerProvider.notifier).setActiveProfile(null);
}
