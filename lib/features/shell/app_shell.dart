import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/breakpoints.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/profile_providers.dart';
import '../../providers/settings_providers.dart';
import '../../providers/sync_providers.dart';
import '../../router.dart' as app_router;
import '../compose/compose_action.dart';
import '../home/home_entries.dart';
import '../home/home_nav.dart';
import '../mail_list/mailbox_scope.dart';
import '../sync/sync_status_panel.dart';
import 'nav_sidebar.dart';
import 'sidebar_mailboxes.dart';

/// 已登录区域的外壳：手机底部导航 / 平板桌面左侧导航栏 + 一个内容区。
///
/// 用 `StatefulShellRoute.indexedStack` 而不是 `ShellRoute`：后者每次切换
/// 都会重建页面，列表滚动位置、展开状态全丢。indexedStack 让每个分支
/// 有自己的 Navigator，切回来时原样还在（列表滚到一半去看星标再回来，
/// 位置不动）。
///
/// 这里同时是 `syncControllerProvider` 的**首位观察者** —— 它是同步链路的
/// 生命周期入口，必须有人在已登录的这棵树上 watch 它，否则（Riverpod 3 的
/// 自动释放下）没有观察者的 provider 会被回收，轮询就停了。
///
/// ## 一级导航的两种形态
///
/// 判据是 [Breakpoints.isCompact]：
/// - **< 600** 手机：底部导航（3 项），内容区单栏，详情 / 写邮件全屏 push；
/// - **>= 600** 左栏 + 单栏内容区。
///
/// 左栏那一支里，600–1023 与 >= 1024 是**同一份侧栏、同一份内容**：
/// 侧栏在两种宽度下都列出 7 个入口，>= 1024 时内容区由各页自己再分成
/// 「列表栏 + 阅读区」。唯一到不了的是窄屏那张主屏 icon 网格
/// （`HomeMenuScreen`）—— 侧栏本身就是菜单，再出现一次就是同一件事说两遍。
///
/// 分栏那一段**没有走 `StatefulShellRoute.navigatorContainerBuilder`**
/// （虽然它拿得到三个分支各自的 Navigator，看起来正是为多栏留的口子）。
/// 那条路要求**三个分支全部**参与排版，等于重写 `indexedStack` 的保活语义
/// （切分支时另外两枝得 offstage 而不是进 `Row`）。实际做法是让各列表页
/// 自己在宽屏下渲染 `MailPanes`（列表栏 + 阅读区）—— 改动面小一个数量级。
/// 详见 `MailPanes` 的类注释与 `Routes.mailOf` 里对选中态的说明。
///
/// 选中态是路径上的查询参数 `?sel=` 而不是把详情压成路径：只改查询参数时
/// go_router 的 `pageKey`（取路由**模式串**）不变，Navigator 原地更新那一页，
/// 列表的 State 与滚动位置都保住。代价是「系统返回手势关不掉右栏」，
/// 由右栏自己的关闭按钮兜住。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 保持调度器存活（不要删掉这行）。
    ref.watch(syncControllerProvider);
    final compact = Breakpoints.isCompact(MediaQuery.sizeOf(context).width);
    final current = navigationShell.currentIndex;

    // 地址只在**外壳这一层**读一次，窄屏那支要拿它判详情页、判设置页，
    // 宽屏那支也要判设置页。见 `showsComposeFab` 的文档注释。
    final uri = GoRouterState.of(context).uri;

    if (compact) {
      // 手机上一旦进了详情页就收起底部导航。
      //
      // 两个理由，第二个才是关键：详情页有自己的返回箭头，底部导航在那儿
      // 只是多余的 80px；而底部导航是**一级导航**，停在那儿等于在说
      // 「你现在在收件箱这一层」——用户其实已经沉进一封信里了。
      final hideNav = isDetailRoute(uri);
      return Scaffold(
        body: navigationShell,
        // 写邮件入口：**每一屏都有，且只有这一颗**（宽窄各一支，见下面宽屏
        // 那一处）。页面上不再挂自己的 FAB —— 外壳的 Scaffold 是各页的祖先，
        // 它把 FAB 画在 body 最上层，页面上再挂一颗只会被盖住。
        //
        // 判据曾经是「这一屏有没有自带 FAB」（`pageOwnsComposeFab`），那要靠
        // 外壳读地址来判断，而地址在外壳这一层会慢一帧 —— 按钮于是时有时无。
        // 现在页面上没有别处会挂，这一颗就是共用那一颗；剩下的例外只有
        // **详情页**与**设置那一支**（见 `showsComposeFab`）—— 那是刻意不给，
        // 不是「谁挂」的问题。写邮件页 / 同步页是顶层路由，推上去整棵盖住
        // 外壳，这一颗自动不可见。
        floatingActionButton: showsComposeFab(uri, compact: true)
            ? const ComposeAction(fab: true)
            : null,
        bottomNavigationBar: hideNav
            ? null
            : NavigationBar(
                selectedIndex: current,
                onDestinationSelected: (index) => _onSelect(context, ref, index),
                destinations: <Widget>[
                  for (final item in _destinations(context, ref))
                    NavigationDestination(
                      icon: BadgedIcon(icon: item.icon, count: item.count),
                      selectedIcon:
                          BadgedIcon(icon: item.selectedIcon, count: item.count),
                      label: item.label,
                    ),
                ],
              ),
      );
    }

    return Scaffold(
      // 宽屏也挂（上一版只在窄屏挂了，于是宽屏的星标 / 发件箱 / 草稿箱 /
      // 附件缓存 / 详情页上一个浮动按钮都没有 —— 而 macOS 的默认窗口就是
      // 800×600，即默认启动就是宽屏）。与侧栏顶部那颗 `ComposeAction()`
      // **不是重复**：那颗是一级导航的一部分，这一颗跟着内容区走。
      //
      // 设置那一支**不挂**（见 `showsComposeFab`）：那儿侧栏那颗就在旁边，
      // 多这一颗是同一件事说两遍。宽屏的详情页也不挂 —— 它压在阅读区正文上。
      floatingActionButton: showsComposeFab(uri, compact: false)
          ? const ComposeAction(fab: true)
          : null,
      body: Row(
        children: <Widget>[
          // 地址取 `GoRouterState.of(context)` —— 这里解析到的是**外壳那一页**
          // （`AppShell` 就挂在那棵子树下，`GoRouterState.of` 从顶层 Navigator
          // 的注册表里查得到它），所以这一层**不随分支内的导航重建**。
          //
          // 这不影响侧栏高亮：它需要的 `uri` 是**整条地址**，而整条地址只有
          // 最外那一层 `GoRouterState` 上才有（`match.dart` 的 `buildState`
          // 里 `uri: matches.uri` —— 所有 match 共用同一个；被分支单独收窄的
          // 只有 `matchedLocation`）。外壳页那次 build 恰好就在整条地址刚变的
          // 时候发生，所以 `uri` 每次都是新的。
          _sidebar(context, ref, uri),
          Expanded(child: navigationShell),
        ],
      ),
    );
  }

  /// 宽屏侧栏。分组与 `HomeEntries` 的两个组一致：置顶的「星标 + 附件缓存」，
  /// 然后是邮件组（收件箱 + 它的邮箱子树）。设置不在组里 —— 它常驻在底部
  /// （`NavSidebar.footer`），滚动时不动。
  ///
  /// 每项的角标与 [HomeMenuScreen] 用的是**同一组 provider** —— 两个形态
  /// 说同一件事，数就不该有两个来源。
  ///
  /// [uri] 是**整条地址**（由调用方从外壳那一层的 `GoRouterState` 取），
  /// `HomeEntry.isSelectedBy` 就按它算高亮、按它判「已经在那一项上了」。
  Widget _sidebar(BuildContext context, WidgetRef ref, Uri uri) {
    final l10n = AppLocalizations.of(context);
    final unread = ref.watch(totalUnreadProvider);
    final outbox = ref.watch(outboxPendingCountProvider);
    final drafts = ref.watch(draftCountProvider);
    final profiles = ref.watch(activeProfilesProvider);

    // 收件箱那一项下面的邮箱下级菜单展不展开。
    //
    // 两个来源取**或**：用户的偏好，以及「当前地址正钉在某个邮箱上 / 正停在
    // 某台实例的实例级列表上」—— 后者必须展开，否则用户从别处（通知深链、
    // 上次退出时留下的地址、侧栏的实例行）回到某个邮箱的收件箱，侧栏里
    // **那一行本身看不见**，高亮也就无从谈起。
    final pinned = pinnedMailboxOf(uri);
    // 实例级落点（`/mail/<实例>`，不带 `account`）—— 侧栏的实例行点下去就是它。
    final instanceNode = instanceNodeOf(uri);
    final expanded = ref.watch(sidebarMailboxesExpandedProvider) ||
        pinned != null ||
        instanceNode != null;

    int? countOf(HomeEntry entry) => switch (entry.id) {
          'unread' => unread,
          'inbox' => unread,
          'outbox' => outbox,
          'drafts' => drafts == 0 ? null : drafts,
          _ => null,
        };

    NavSidebarItem itemOf(HomeEntry entry) => NavSidebarItem(
          icon: entry.icon,
          selectedIcon: entry.selectedIcon,
          label: homeEntryLabel(entry, l10n),
          // 一级「收件箱」在**钉住某个邮箱**或**停在某台实例的实例级列表**上
          // 时也算选中：那一刻用户看的就是收件箱（只不过是某一台/某一个
          // 邮箱的），而钉住那一行自己也会亮 —— 两级同时亮是对的，它们本来
          // 就是包含关系。
          //
          // 后半句是这一轮新加的：实例行现在会主动落到 `/mail/<实例>`，而
          // `HomeEntries.inbox.isSelectedBy('/mail/p1')` 是 **false**
          // （`home_entries_test.dart` 那条「钉在某个实例上的列表点开一封，
          // 三个 folder 入口都不亮」钉着这条），不补它的话点完实例行**整条
          // 一级导航会一个都不亮**。`HomeEntry.isSelectedBy` 本身不动 ——
          // 放宽它会让 `/mail/p2` 也点亮收件箱，那是另一回事。
          selected: entry.isSelectedBy(uri) ||
              (entry.id == 'inbox' && (pinned != null || instanceNode != null)),
          count: countOf(entry) ?? 0,
          // 发件箱 0 也显示（spec §2.4）：它的用途是「让你知道还有这么个地方」。
          alwaysShowCount: entry.id == 'outbox',
          // 收件箱那一项本身是下级菜单的组头：箭头是「这里还能展开」的唯一
          // 提示。一台实例都没登录时不给箭头 —— 展也展不出东西。
          //
          // 箭头是**一括**的：往「开」的方向拨时还要把每台实例的单独收起
          // 记录清掉（`expandAll`），否则「全部展开」之后上次单独收起的那台
          // 还是收起的，用户会以为这颗箭头坏了；往「关」的方向拨就只是那个
          // 一括开关翻成 false（单独收起的那份留着 —— 下次再展开回来时，
          // 用户上次手动收起的那台还该是收起的）。
          trailing: entry.id == 'inbox' && profiles.isNotEmpty
              ? IconButton(
                  tooltip: l10n.toggleMailboxList,
                  onPressed: () {
                    final notifier = ref.read(
                      sidebarMailboxesExpandedProvider.notifier,
                    );
                    if (ref.read(sidebarMailboxesExpandedProvider)) {
                      notifier.set(false);
                    } else {
                      notifier.set(true);
                      ref
                          .read(sidebarInstanceExpansionProvider.notifier)
                          .expandAll();
                    }
                  },
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 24,
                  ),
                  icon: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                  ),
                )
              : null,
          // `push: false`：侧栏本身就是一级导航，而且宽屏顶部条是
          // `PaneHeader`（**没有返回箭头**）—— 在这儿 push 会叠出一摞谁也
          // 退不回去的页面。判定与理由见 `openHomeEntry`。
          onTap: () => openHomeEntry(
            context,
            ref,
            entry,
            current: uri,
            push: false,
          ),
        );

    return NavSidebar(
      leading: const _SidebarHeader(),
      items: <NavSidebarGroup>[
        // 置顶组：星标 + 附件缓存。
        NavSidebarGroup(
          items: <Widget>[
            for (final entry in HomeEntries.topActions) itemOf(entry),
          ],
        ),
        // 邮件组：一封信的各条去向。邮箱下级菜单**紧跟在收件箱那一项后面**
        // （同一组里），不能另起一组：另起一组会被组间的留白劈开，看起来像
        // 两组不相干的东西。
        //
        // 两个组都直接照 `HomeEntries` 的组渲染 —— 原来这里是
        // 「遍历 `all`，按 id 跳过两个」，那种写法每加一个入口就得回来
        // 改一次过滤条件，而漏改的表现是「这一项在侧栏里悄悄没了」。
        NavSidebarGroup(
          items: <Widget>[
            for (final entry in HomeEntries.mailGroup) ...<Widget>[
              itemOf(entry),
              if (entry.id == 'inbox' && expanded && profiles.isNotEmpty)
                SidebarMailboxTree(
                  uri: uri,
                  masterExpanded:
                      ref.watch(sidebarMailboxesExpandedProvider),
                ),
            ],
          ],
        ),
      ],
      // 设置常驻在底部，不跟着列表滚（见 `NavSidebar.footer`）。
      footer: _settingsItem(context, ref, uri),
    );
  }

  /// 设置是**别的分支**，只能 `go`（与星标同理，见 `openHomeEntry`）。
  ///
  /// 高亮判据用 `startsWith` 而不是相等：`/settings/diagnostics`、
  /// `/settings/push` 都是从它里面 push 出去的，那时候侧栏该停在设置上。
  NavSidebarItem _settingsItem(BuildContext context, WidgetRef ref, Uri uri) {
    final l10n = AppLocalizations.of(context);
    return NavSidebarItem(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: l10n.settings,
      selected: uri.path.startsWith(app_router.Routes.settings),
      onTap: () {
        context.go(app_router.Routes.settings);
        ref.read(syncControllerProvider.notifier).setActiveProfile(null);
      },
    );
  }

  /// 窄屏底部导航项。角标全部来自**本地库**——服务端没有未读计数接口。
  ///
  /// 从四项变成三项：聚合没了（并进了邮件那一支），发件箱的角标也从
  /// 「设置」那一项挪到了主屏的发件箱入口上 —— 前者的问题是「不去设置就
  /// 永远不知道有封信没发出去」。
  List<_Destination> _destinations(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return <_Destination>[
      _Destination(
        label: l10n.mailTab,
        icon: Icons.mail_outline,
        selectedIcon: Icons.mail,
        count: ref.watch(totalUnreadProvider),
      ),
      _Destination(
        label: l10n.starred,
        icon: Icons.star_border,
        selectedIcon: Icons.star,
      ),
      _Destination(
        label: l10n.settings,
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
      ),
    ];
  }

  /// 统一用 `context.go` 切分支，而不是 `goBranch`。
  ///
  /// 理由：`goBranch` 只把你送回该分支**上次停留的位置**，而「点底部导航」
  /// 的语义是「去这个功能」，不是「回到上次那封邮件」。这里三个目标都是
  /// 各分支的根路径，分支内部已有的前进栈会被清掉，但各分支的 Navigator
  /// 状态（滚动位置等）仍由 indexedStack 保留。
  ///
  /// 邮件这一支的根是**主屏菜单**（而不是某个列表）：从星标切回来时该看到
  /// 菜单，而不是上次那封没读完的信。
  void _onSelect(BuildContext context, WidgetRef ref, int index) {
    switch (index) {
      case app_router.ShellBranch.mail:
        context.go(app_router.Routes.home);
        // 主屏可能有多个实例的邮件，不该把某一台标成「活跃」。
        ref.read(syncControllerProvider.notifier).setActiveProfile(null);
      case app_router.ShellBranch.starred:
        context.go(app_router.Routes.starred);
      case app_router.ShellBranch.settings:
        context.go(app_router.Routes.settings);
    }
  }
}

/// 侧栏顶部：标题 + 实例数 + 写邮件 + 同步状态按钮。
///
/// 这一格原来只放同步按钮（宽度也只够放一个按钮）。加宽之后它顺手承担
/// 「我现在在看哪几台实例」—— 主屏那张网格在宽屏下不存在，用户没有别的地方
/// 能看到这个信息。
///
/// 写邮件按钮放在这儿，与内容区那颗 FAB 是同一件事的两个入口（见
/// `ComposeAction`）：侧栏是宽屏的一级导航，FAB 跟着内容区走 —— 两颗都在
/// 是刻意的，不是重复（窄屏根本没有侧栏）。
class _SidebarHeader extends ConsumerWidget {
  const _SidebarHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final profiles = ref.watch(activeProfilesProvider);
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                l10n.appTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                l10n.instanceCount(profiles.length),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const ComposeAction(),
        const SyncStatusButton(),
        // 扩展的图标按钮。**排在最后**：写邮件与同步状态是核心的一级动作，
        // 位置固定；扩展进来的东西跟在它们后面，不挤走任何一个。
        // 空注册表（公开版）时这里什么都没有 —— 那一行与从前逐像素相同。
        ...AppExtensionRegistry.instance.shellActions(context),
      ],
    );
  }
}

@immutable
class _Destination {
  const _Destination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.count = 0,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// 0 表示不显示角标。
  final int count;
}

/// 当前是不是停在一封信的详情页上。
///
/// 手机上一旦进了详情就收起底部导航：详情页有自己的返回箭头，那 80px
/// 只是多余的；而底部导航是**一级导航**，停在那儿等于在说「你现在在收件箱
/// 这一层」—— 用户其实已经沉进一封信里了。
///
/// 判据是 URL 而不是 Navigator 深度。深度在详情和写邮件两种情况下都会加深，
/// 但写邮件是**流程**不是详情：用户可能刚起了个头又想跳去别的 tab，
/// 那时底部导航不该消失。
///
/// 只剩两条形状：`/mail/<实例或 all>/<emailId>` 与 `/starred/<emailId>`。
/// 两者都是「根 + 一个数字」，但 `/mail` 中间多一段。
///
/// 收 [Uri] 而不是 `BuildContext`：外壳的同一次 build 里，两个判据
/// （本函数与 [showsComposeFab]）都要从同一份地址出发，
/// 解析一次比 `GoRouterState.of` 查两遍干净。
bool isDetailRoute(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length < 2) return false;
  if (int.tryParse(segments.last) == null) return false;

  final root = '/${segments.first}';
  if (root == app_router.Routes.mail) return segments.length == 3;
  if (root == app_router.Routes.starred) return segments.length == 2;
  // 发件箱里的一条也是一封信的详情（`/outbox/<id>`）。漏掉这一条的表现是
  // 「进了详情页底部导航还在」，而它是**本机队列**的一条记录，在那儿放一个
  // 「你在邮件这一层」的一级导航是同一件错事。
  if (root == app_router.Routes.outbox) return segments.length == 2;
  return false;
}

/// 这一屏该不该有那颗写邮件浮动按钮。
///
/// 默认**有**（见 `ComposeAction`：「所有页面都该有一颗」是这个功能的全部
/// 意义）。只有两处例外，而且都不是「谁挂」的问题 —— 是**刻意不给**：
///
/// 1. **设置那一支**（含诊断 / 推送 / 加实例这些子页）。那儿是写邮件按钮最
///    多余的地方：页面右边整片留白，按钮浮在上面像放错了位置；而宽屏下侧栏
///    顶部那颗一模一样的图标就在旁边。窄屏收掉它也不缺入口 —— `ComposeAction`
///    那颗按钮按定义「每个非设置页都有」，退回邮件 / 星标那一支就在。
/// 2. **一封信的详情页，只限宽屏**。宽屏下右栏是阅读区，那颗按钮正好压在正文
///    右下角；而窄屏的详情页本来就没有右栏，按钮停在列表挪上来的那个位置，
///    是改动之前的行为，不顺手改。窄屏收起的是**底部导航**（同一份详情判据，
///    见 [isDetailRoute]），那才是一级导航不该赖在详情页上的那一条。
///
/// 判据全在地址上，不看 Navigator 深度：深度会把「写邮件」那种流程也算成
/// 「沉进去了」，而那正是不该收按钮的地方。
bool showsComposeFab(Uri uri, {required bool compact}) {
  if (!compact && isDetailRoute(uri)) return false;
  if (_isSettingsBranch(uri)) return false;
  return true;
}

/// 地址是不是落在设置那一支上（设置页本身或它的子页）。
///
/// 按**路径段**判而不是 `startsWith('/settings')`：后者会把 `/settingsFoo`
/// 这种同前缀的路径也算进来（本仓库没有这条路由，但这种判据迟早会咬人 ——
/// `HomeEntry.isSelectedBy` 里那条「前缀不能吞掉同前缀的别的路径」是同一回事）。
bool _isSettingsBranch(Uri uri) {
  final settings = app_router.Routes.settings;
  return uri.path == settings || uri.path.startsWith('$settings/');
}
