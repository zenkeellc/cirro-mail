import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/breakpoints.dart';
import 'data/models/enums.dart';
import 'data/models/mail_ref.dart';
import 'data/models/profile.dart';
import 'features/compose/compose_draft.dart';
import 'features/compose/compose_entry.dart';
import 'features/compose/drafts_screen.dart';
import 'features/mail_detail/mail_detail_screen.dart';
import 'features/home/home_menu_screen.dart';
import 'features/mail_list/mail_list_screen.dart';
import 'features/onboarding/login_screen.dart';
import 'features/outbox/outbox_preview.dart';
import 'features/outbox/outbox_screen.dart';
import 'features/settings/attachment_cache_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/shell/app_shell.dart';
import 'features/startup/startup_failure_screen.dart';
import 'features/starred/starred_screen.dart';
import 'features/sync/sync_status_screen.dart';
import 'providers/core_providers.dart';
import 'providers/profile_providers.dart';

/// 路由路径常量。
///
/// 用字符串常量而不是 `GoRouteData` 代码生成：路由表只有十来个，
/// 而 `TypedGoRoute` 会把 `build_runner` 拖进每一次改动，得不偿失。
class Routes {
  const Routes._();

  /// 服务器设置（添加实例）的**旧地址**，现在是一个重定向到 `/settings`。
  ///
  /// 它曾经是一个整屏的独立页面（`ServerSetupScreen`，顶层路由、壳之外）——
  /// 新装（零实例）时 `redirect` 还会把人**整窗**钉在那儿：一级导航与设置页
  /// 的分类菜单全都不在，看着像另一个 App。表单现在并进设置页的「实例」
  /// 那一栏（`AddInstanceSection`，宽屏在右栏、窄屏是分类页），地址这一层
  /// 只留兼容：`/setup` 可能出现在旧文档 / 浏览历史里，落到 404 会让人以为
  /// 坏了。
  static const String setup = '/setup';
  static const String login = '/login';

  /// 主屏（一级导航 index 0 的根）：窄屏是 icon 网格，宽屏由侧栏承担。
  static const String home = '/home';

  static const String mail = '/mail';

  static const String starred = '/starred';
  static const String settings = '/settings';

  /// 这几条**曾经是独立整页**（AI / 推送 / 诊断 / 添加实例各一页），现在都
  /// 并进 `/settings` 自己的分类里（宽屏在右栏内嵌、窄屏是一页）。
  ///
  /// 常量留着与 [pushSetupGuide] 同一条理由：**深链不该断**。这几个地址可能
  /// 出现在用户的浏览历史、通知、或某份旧文档里，落到 404 会让人以为坏了 ——
  /// 路由表里它们此刻都是 `redirect: (…) => Routes.settings`。
  static const String diagnostics = '/settings/diagnostics';
  static const String pushSettings = '/settings/push';
  static const String aiSettings = '/settings/ai';

  /// 推送配置指引的**旧地址**，现在是一个重定向。
  ///
  /// 它曾经是一张独立的页面（一份清单 + 一个四选一身份选择器）。那一套
  /// 已经被 `/settings/push` 自己的七页向导取代 —— 指引与设置页讲的是
  /// 同一件事的两种讲法，分成两页的结果是两边都得维护、还谁也不全。
  ///
  /// 常量留着是因为**深链不该断**：`/settings/push/guide` 可能出现在用户
  /// 的历史记录、或某份旧文档里，落到 404 会让人以为是坏了。
  static const String pushSetupGuide = '/settings/push/guide';

  /// 附件缓存 / 草稿箱 / 发件箱：**邮件那一支里的另外几个根**。
  ///
  /// 它们曾经是「顶层路由」（与写邮件页一样，shell 之外），各自搭一个全屏
  /// `Scaffold`。改到分支里是为了两件事，两件在真机上立刻看得出来：
  ///
  /// 1. **外壳**。顶层路由是全屏的，从主屏点进草稿箱，左侧那条导航（宽屏）
  ///    与底部导航（窄屏）**整条消失**，页面像是一头扎进了另一个 App。
  ///    用户要的是「跟星标页一样」——星标在分支里，外壳一直在。
  /// 2. **返回**。分支内的详情（`/outbox/<id>`）是**同一个 Navigator 内的
  ///    push**，返回箭头与系统返回键天然可用；而顶层路由之间只能用 `go`
  ///    互相替换，压栈的语义根本不成立（这正是「发件箱点开一条之后回不去」
  ///    的成因）。
  ///
  /// 挂进**邮件那一支**（而不是各给一支）的原因在 `AppShell` 那侧：窄屏的
  /// 底部导航只有三项，而 `NavigationBar` 断言 `selectedIndex` 在项数之内
  /// —— 单独成支的页面在手机上会当场断言失败。挂在邮件这一支里，
  /// `/outbox` 的 `currentIndex` 就是 0（「邮件」高亮），既成立了断言，
  /// 也符合语义：这三个入口本来就从主屏菜单进。
  ///
  /// 代价是它们进了 `indexedStack` 之后不会被回收（访问过一次就一直活着）。
  /// 这是「跟星标一样」的同义词 —— 星标本来就是这样。规模也可控：发件箱是
  /// 一条 drift 队列流 + 一个 20s 的慢时钟，草稿箱是一条 drift 流，附件
  /// 缓存干脆只在 `initState` 里读一次。
  ///
  /// **写邮件页与同步页仍然留在顶层**，理由见 [compose] / [syncStatus]。
  static const String attachmentCache = '/attachment-cache';
  static const String drafts = '/drafts';
  static const String outbox = '/outbox';

  /// 发件箱里一条的预览（窄屏点开一整页；宽屏在右栏）。
  static String outboxDetailOf(int id) => '$outbox/$id';

  /// 宽屏分栏下左栏选中的那条（与 `/mail/<p>?sel=` 同一个语法）。
  ///
  /// 发件箱的 `id` 是本机自增主键，不像 `emailId` 那样跨实例重号，
  /// 所以不用再带一个 `profile`。`id <= 0` 表示「没选中」—— 那种情况
  /// 给的是不带参数的干净地址，而不是一个 `?sel=0`（后者会在地址栏里
  /// 留下一个看着像「选中了第 0 条」的尾巴）。
  static String outboxWith(int id) => id <= 0
      ? outbox
      : Uri(path: outbox, queryParameters: <String, String>{'sel': '$id'})
          .toString();

  /// 「添加实例」的**旧地址**，现在是一个重定向到 `/settings`。
  ///
  /// 它曾经是设置页里唯一一张真的表单页（挂着自己的 `Scaffold`，压在这一支
  /// 的 Navigator 上）：一进去设置分类栏就整条消失，只剩一张填地址的表单
  /// —— 而设置页里其余十来个分类都是「同一屏内换右栏」。表单现在并入
  /// 「实例」那一栏（`AddInstanceSection`），地址这一层只留兼容。
  static const String addInstance = '/settings/add-instance';

  static const String startupFailure = '/startup-failure';

  /// 收件箱列表里「只看未读」的 query 参数名。
  ///
  /// 与 `UnreadState.unread = 0` 那个**反直觉**的编码无关：URL 里写的是
  /// 「1 = 只看未读」，读的时候只需判它存不存在（见 `listQueryOf`）。
  static const String unreadParam = 'unread';

  /// 「钉在某个邮箱上」的 query 参数名（左侧菜单的下级菜单落点）。
  ///
  /// **这个参数「在不在」就是全部语义** —— 值本身只说明是哪一个邮箱，
  /// `0`（= `kAllMailboxes`，缺 `account:query` 权限那个实例的合并项）
  /// 是一个**合法值**，见 [parseAccountId]。
  static const String accountParam = 'account';

  /// 写邮件页。**「邮件」那一支里的一个根路由**（与 [drafts]、[outbox]
  /// 同级），不是顶层路由。
  ///
  /// 2026-11 从顶层搬进来，原因就是这一版的需求：撰写页要和外层的一级导航
  /// 一起存在（只占内容区、不再整窗盖住 App），并且要能被左侧「邮件撰写」
  /// 分类像切页面一样切来切去。分支根路由没有可 pop 的栈 —— 进入用 `go`、
  /// 离开用 `go(回去的地方)`，回去的地址记录在 [fromParam] 里。
  ///
  /// 它**不是**一个新的 shell 分支：分支的页面是 indexedStack 保活的，
  /// 而撰写页需要「离开就销毁、内容靠草稿行恢复」（见 `ComposeDraftSaver`）。
  static const String compose = '/compose';

  /// 进撰写页之前所在的地址。关页时 `go` 回这里；缺省（深链进来）回草稿箱。
  ///
  /// 写进地址而不是放 provider：切到另一封撰写页、或刷新/重启后再关页，
  /// 它都得还在；页面也不需要知道「我是不是被 push 上来的」。
  static const String fromParam = 'from';

  /// 同步状态页。**同样是顶层路由**，理由与 [compose] 一模一样：
  /// 它是「看一眼就走」的页面，而它下面挂着几条常驻的 drift 订阅
  /// （待同步清单、附件统计、在飞清单），挂进 shell 分支就永远不会被回收。
  static const String syncStatus = '/sync';

  /// 聚合视图在 URL 里用的占位 id —— 让「全部实例合并」也能住在
  /// `/mail/<id>` 这一支里（分支启动位置必须是具体路径，不能用空串）。
  static const String kAggregateNode = 'all';

  /// 全部实例合并的列表（主屏邮件组的根，也是冷启动的落点）。
  static const String mailAll = '$mail/$kAggregateNode';

  /// `/mail/<节点>?account=&folder=&sel=&unread=`。
  ///
  /// `sel` 是**分栏形态下当前选中的那封邮件**。用查询参数而不是再压一层路径，
  /// 是因为 `?sel=` 不改变页面的身份：go_router 的 `pageKey` 取的是路由
  /// **模式串**（`match.dart` 里 `ValueKey(newMatchedPath)`，查询参数不进这个
  /// 串），所以只改 `sel` 时 Navigator 是原地更新那一页 —— 不 push、不转场，
  /// 列表的 State 与滚动位置都保住。压成路径（`/mail/<p>/<e>`）会在同一个分支
  /// Navigator 上叠一张新页，列表被盖住，而且**同时存在两个 `MailListScreen`**
  /// （底下那个 `maintainState` 还活着），drift 订阅和首屏补拉都会翻倍。
  ///
  /// `节点` 是「这一屏是哪张列表」：实例 id 或 [kAggregateNode]。`folder` 与
  /// `unread` 是同一张列表的两个维度（收件箱 / 未读邮件 / 已发送共用
  /// `/mail/all` 这一段，靠它们区分，见 `HomeEntries._list`）—— 少带一个，
  /// 用户就会在点开一封、关掉右栏之后被挪到另一个入口上。
  ///
  /// `account` 是**左侧菜单下级菜单的落点**（「只看这一个邮箱」）。
  /// **写不写这个参数就是「钉不钉住」这条标志本身**，所以是 `accountId != null`
  /// 而不是 `> 0`：`0`（[kAllMailboxes]，缺 `account:query` 权限那个实例的
  /// 合并项）是一个正经的落点。一级入口（收件箱 / 未读 / 已发送）**永远不传
  /// `accountId`** —— 它们靠「不带这个参数」与下级菜单区分开，`pinnedMailboxOf`
  /// 与「筛选按钮在不在」都建在这条不变式上。
  static String mailOf(
    String profileId, {
    int? accountId,
    MailFolder? folder,
    int? selectedEmailId,
    bool unreadOnly = false,
  }) {
    final params = <String, String>{
      if (accountId != null) accountParam: '$accountId',
      if (folder != null && folder != MailFolder.receive) 'folder': folder.name,
      if (selectedEmailId != null && selectedEmailId > 0)
        'sel': '$selectedEmailId',
      if (unreadOnly) unreadParam: '1',
    };
    return Uri(
      path: '$mail/$profileId',
      queryParameters: params.isEmpty ? null : params,
    ).toString();
  }

  /// 读回 [accountParam]。
  ///
  /// 与 [mailOf] 的写出规则成对：**没写 / 空 / 不是数 / 负数 → null**（= 没钉住），
  /// `'0'` → 0（合法值，见 [mailOf] 的注释）。
  ///
  /// 单独一个方法而不是各处 `int.tryParse(...) ?? 0`：后者会把「没写」
  /// 也折成 0，于是**每次详情折返都开始写 `?account=0`**，那条「在不在」
  /// 的标志当场变成垃圾 —— 见 `_paneRedirectForDetail`。
  static int? parseAccountId(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final value = int.tryParse(raw);
    if (value == null || value < 0) return null;
    return value;
  }

  static String aliasOf(String? profileId) =>
      (profileId == null || profileId.isEmpty) ? kAggregateNode : profileId;

  /// 从 `/mail/<profileId>` 里拆出 profileId；聚合（`all`）返回 null。
  static String? parseProfileId(String? raw) =>
      (raw == null || raw.isEmpty || raw == kAggregateNode) ? null : raw;

  /// `/compose?profile=&account=&draft=&email=&mode=`。
  ///
  /// `mode` 取值是 [ComposeMode] 的 `name`；缺省（或空 id）就是「写一封新的」。
  /// `account` 是「从哪个邮箱进来」—— 写邮件页据此预选发件人
  /// （同一个实例下可能有多个邮箱）。`draft` 是「接着写哪条草稿」。
  static String composeOf({
    String? profileId,
    int? accountId,
    int? draftId,
    int? emailId,
    ComposeMode? mode,
  }) {
    final params = <String, String>{
      if (profileId != null && profileId.isNotEmpty) 'profile': profileId,
      if (accountId != null && accountId > 0) 'account': '$accountId',
      if (draftId != null && draftId > 0) 'draft': '$draftId',
      if (emailId != null && emailId > 0) 'email': '$emailId',
      if (mode != null && mode != ComposeMode.blank) 'mode': mode.name,
    };
    return Uri(
      path: compose,
      queryParameters: params.isEmpty ? null : params,
    ).toString();
  }
}

/// 底部导航 / 侧栏的分支下标。顺序即 `StatefulShellRoute.indexedStack`
/// 里 `branches` 的顺序，**不要单独改一处**。
///
/// 从四支变成三支：**聚合时间线那一支没有了**（`/aggregate` → 报废）。
/// 它的语义整体并进了 `/mail/all` —— 两者本来就是同一个 `MailListView`，
/// 真正的差别只有「有没有实例过滤条」，而那个过滤条跟收件箱的多选邮箱
/// 是同一件事（见 spec §1）。
///
/// **仍然是三支**：发件箱 / 草稿箱 / 附件缓存挂在**邮件那一支**里，不另开
/// 分支（理由见 [Routes.attachmentCache]）。所以这里没有它们的位置 ——
/// 窄屏底部导航只有三项，三者都落在「邮件」那一项上。
class ShellBranch {
  const ShellBranch._();

  /// 邮件：主屏菜单（`/home`）与各列表（`/mail/<节点>`，节点是实例 id 或
  /// `all`）同属这一支 —— 它们必须共用同一个 Navigator，不然从主屏点进
  /// 收件箱会丢掉「返回主屏」的那条路径。
  ///
  /// 发件箱 / 草稿箱 / 附件缓存也在这一支里（各自是一个根路由）。
  static const int mail = 0;
  static const int starred = 1;
  static const int settings = 2;
  static const int count = 3;
}

/// `mode` 查询参数 → [ComposeMode]。认不出来就是「写一封新的」。
ComposeMode composeModeOf(String? raw) {
  for (final mode in ComposeMode.values) {
    if (mode.name == raw) return mode;
  }
  return ComposeMode.blank;
}

/// 路由重算的触发源：实例列表 + 每个实例的登录状态。
///
/// 包成 `Listenable` 是因为 `GoRouter.refreshListenable` 只认它 ——
/// Riverpod 的 provider 变化不会自动让路由重算。
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    _sub = ref.listen<AsyncValue<List<Profile>>>(
      profilesProvider,
      (previous, next) {
        // 只在「路由该不该变」的结论改变时通知。列表页每次同步都会往
        // profiles 表写 `lastSyncAt`，不设这道闸的话每轮轮询都会重算路由。
        //
        // **「还没读出来」与「读出来是空表」必须算两个签名**：空表拼出来的
        // 串与初值（空串）逐字相同，早期版本因此漏掉了那条通知 ——
        // 新装（零实例）冷启动时 redirect 一次都没再跑，App 停在空的收件箱
        // 上；用户**点哪一下**（设置 / 底部导航）都会触发一次 redirect，
        // 然后整窗被那张「添加实例」页接走。现在这一跳会把用户送到设置页。
        final signature = next.hasValue
            ? _signature(next.value ?? const <Profile>[])
            : '<loading>';
        if (signature == _lastSignature) return;
        _lastSignature = signature;
        notifyListeners();
      },
      fireImmediately: true,
    );
  }

  late final ProviderSubscription<AsyncValue<List<Profile>>> _sub;
  String _lastSignature = '';

  static String _signature(List<Profile> profiles) => profiles
      .map((p) => '${p.id}:${p.userId}:${p.needsLogin}:${p.baseUrl}')
      .join('|');

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}

/// 全局唯一的路由器。
final Provider<GoRouter> routerProvider = Provider<GoRouter>(
  (ref) {
    final refresh = _AuthRefresh(ref);
    ref.onDispose(refresh.dispose);
    // 启动失败页要能「重试」，重试成功的标志就是 provider 被重建。
    final appKey = GlobalKey<NavigatorState>();

    final router = GoRouter(
      navigatorKey: appKey,
      initialLocation: Routes.mailAll,
      refreshListenable: refresh,
      debugLogDiagnostics: kDebugMode,
      redirect: (context, state) => _redirect(ref, context, state),
      routes: <RouteBase>[
        GoRoute(
          path: Routes.startupFailure,
          name: 'startupFailure',
          builder: (context, state) => const StartupFailureScreen(),
        ),
        GoRoute(
          // 旧地址：整屏的「服务器设置」页已经没有位置了（添加实例现在是
          // 设置页「实例」那一栏的表单，见 `AddInstanceSection`）。留着这条
          // 是为了深链不 404。
          path: Routes.setup,
          name: 'setup',
          redirect: (context, state) => Routes.settings,
        ),
        GoRoute(
          path: '${Routes.login}/:profileId',
          name: 'login',
          builder: (context, state) =>
              LoginScreen(profileId: state.pathParameters['profileId']!),
        ),
        // 同步状态页。与写邮件页同样是顶层 push（见 `Routes.syncStatus`）。
        GoRoute(
          path: Routes.syncStatus,
          name: 'syncStatus',
          builder: (context, state) => const SyncStatusScreen(),
        ),
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) =>
              AppShell(navigationShell: navigationShell),
          branches: <StatefulShellBranch>[
            // 0 —— 邮件：主屏菜单 + 各列表。
            //
            // 一个 `StatefulShellBranch` 里挂**两个根路由**（`/home` 与
            // `/mail/:profileId`）是完全合法的：branch 的 `routes` 就是那个
            // Navigator 的路由表，一个 Navigator 本来就可以有多条互不嵌套的
            // 根路径。这样做的收益是**地址一个都不用改** —— `/mail/all`
            // 仍是收件箱（spec §2.1 那张表钉的就是它），而窄屏的底部导航
            // 在两者之间切换时不会跨分支、不会重建 Navigator。
            StatefulShellBranch(
              initialLocation: Routes.mailAll,
              routes: <RouteBase>[
                // 主屏菜单。窄屏是 icon 网格；宽屏下侧栏本身就是菜单，
                // 这个页面到不了（见 `HomeMenuScreen` 的类注释）。
                GoRoute(
                  path: Routes.home,
                  name: 'home',
                  builder: (context, state) => const HomeMenuScreen(),
                ),
                // `/mail/<节点>`：节点是实例 id 或 `all`（全部实例合并）。
                // folder / unread 是 query 参数；勾选的邮箱集合走 prefs。
                //
                // `account` 是**左侧菜单下级菜单**的落点（钉住某个邮箱）。
                // 它不由路由重定向补默认值：**「没写」与「写了 0」是两回事**
                // （前者 = 实例级列表、后者 = 这个实例的合并邮箱），
                // 所以这里必须原样透传，见 `Routes.parseAccountId`。
                GoRoute(
                  path: '${Routes.mail}/:profileId',
                  name: 'mail',
                  builder: (context, state) => MailListScreen(
                    profileId: Routes.parseProfileId(
                      state.pathParameters['profileId'],
                    ),
                    accountId: Routes.parseAccountId(
                      state.uri.queryParameters[Routes.accountParam],
                    ),
                    folder: folderOf(state.uri.queryParameters['folder']),
                    unreadOnly:
                        state.uri.queryParameters[Routes.unreadParam] == '1',
                    // 分栏形态下选中的那一封。窄屏恒为 null —— 选中态只属于
                    // 分栏形态，窄屏照旧是「点一行 push 一整页」。
                    selected: _selectedOf(context, state),
                  ),
                  routes: <RouteBase>[
                    GoRoute(
                      path: ':emailId',
                      name: 'mailDetail',
                      // 宽屏下不另开一页：`/mail/<p>/<e>` → `/mail/<p>?sel=<e>`。
                      // 不折的话，通知深链会在列表页**上面**再叠一个列表页，
                      // 于是两份 drift 订阅、两次首屏补拉。
                      redirect: (context, state) =>
                          _paneRedirectForDetail(context, state),
                      builder: (context, state) => MailDetailScreen(
                        profileId: Routes.parseProfileId(
                              state.pathParameters['profileId'],
                            ) ??
                            (state.uri.queryParameters['profile'] ?? ''),
                        emailId: int.tryParse(
                              state.pathParameters['emailId'] ?? '',
                            ) ??
                            0,
                      ),
                    ),
                  ],
                ),
                // 发件箱。详情是**子路由**：窄屏点开一条就是同一个
                // Navigator 内的 push，返回箭头与系统返回键都成立。
                //
                // 宽屏分栏下选中的那条仍然走 `?sel=`（查询参数不进
                // `pageKey`，Navigator 原地更新那一页）：与 `/mail/<p>?sel=`
                // 同一套语义（见 [Routes.mailOf] 的注释）。
                GoRoute(
                  path: Routes.outbox,
                  name: 'outbox',
                  builder: (context, state) => OutboxScreen(
                    selectedId:
                        int.tryParse(state.uri.queryParameters['sel'] ?? '') ??
                            0,
                  ),
                  routes: <RouteBase>[
                    GoRoute(
                      path: ':entryId',
                      name: 'outboxEntry',
                      builder: (context, state) => OutboxEntryScreen(
                        entryId:
                            int.tryParse(state.pathParameters['entryId'] ?? '') ??
                                0,
                      ),
                    ),
                  ],
                ),
                // 草稿箱。**宽屏没有右栏**（草稿点开是进写邮件页继续编辑，
                // 不是预览），所以它没有 `sel` 那种选中态。
                GoRoute(
                  path: Routes.drafts,
                  name: 'drafts',
                  builder: (context, state) => const DraftsScreen(),
                ),
                // 写邮件页。**这一支里的根路由**（见 [Routes.compose]）：
                // 左侧一级导航一直在，它只占内容区。
                //
                // `key` 里带 `draft`：从左侧子项切到另一封撰写页时地址只有
                // 查询参数变化，go_router 的 pageKey（路由模式串）不变 ——
                // 不换 key 的话 State 会被复用，编辑器里还停着上一封的正文。
                // key 一变，State 重建、从草稿行重新装载。
                GoRoute(
                  path: Routes.compose,
                  name: 'compose',
                  builder: (context, state) {
                    final query = state.uri.queryParameters;
                    return ComposeEntry(
                      key: ValueKey<String>(
                        'compose:${query['draft'] ?? ''}:'
                        '${query['email'] ?? ''}:${query['mode'] ?? ''}',
                      ),
                      mode: composeModeOf(query['mode']),
                      profileId: query['profile'] ?? '',
                      accountId: int.tryParse(query['account'] ?? '') ?? 0,
                      draftId: int.tryParse(query['draft'] ?? '') ?? 0,
                      emailId: int.tryParse(query['email'] ?? '') ?? 0,
                      from: query[Routes.fromParam],
                    );
                  },
                ),
                // 附件缓存。
                GoRoute(
                  path: Routes.attachmentCache,
                  name: 'attachmentCache',
                  builder: (context, state) => const AttachmentCacheScreen(),
                ),
                // 扩展挂在**这一支里**的路由（`AppExtension.mailBranchRoutes`）。
                //
                // 为什么不并进末尾那处 `AppExtensionRegistry.routes()`：那里
                // 挂的是**顶层**路由（与 `/compose` 同形，渲染在壳外面）。
                // 从顶层页面 `push` 一个壳内地址，go_router 会在根 Navigator
                // 上再挂一个同 pageKey 的状态壳，Navigator 的重复 pageKey
                // 断言当场红屏（成因写在上面的 `Routes.outbox` 注释里，那边
                // 整段就是为这件事把三个页面从顶层搬进这一支的）。
                // 挂在这一支里的扩展页面与 `/mail/<节点>` 共用同一个
                // Navigator，`push` 详情页是正常的压栈。
                ...
                    AppExtensionRegistry.instance.mailBranchRoutes(),
              ],
            ),
            // 1 —— 星标。
            StatefulShellBranch(
              routes: <RouteBase>[
                GoRoute(
                  path: Routes.starred,
                  name: 'starred',
                  builder: (context, state) => StarredScreen(
                    selected:
                        _selectedOf(context, state, root: Routes.starred),
                  ),
                  routes: <RouteBase>[
                    GoRoute(
                      path: ':emailId',
                      name: 'starredDetail',
                      redirect: (context, state) =>
                          _paneRedirectForDetail(context, state),
                      builder: (context, state) => MailDetailScreen(
                        profileId: state.uri.queryParameters['profile'] ?? '',
                        emailId: int.tryParse(
                              state.pathParameters['emailId'] ?? '',
                            ) ??
                            0,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            // 3 —— 设置 / 诊断。
            StatefulShellBranch(
              routes: <RouteBase>[
                GoRoute(
                  path: Routes.settings,
                  name: 'settings',
                  builder: (context, state) => const SettingsScreen(),
                  routes: <RouteBase>[
                    // 这三条**曾经是三个独立整页**，现在都并进 `/settings`
                    // 自己的分类里（AI / 推送 / 诊断各是一个分类，宽屏在右栏
                    // 内嵌、窄屏是一页）。
                    //
                    // 路由留着是为了**深链不 404** —— 与 `pushSetupGuide`
                    // 同一条理由：这几个地址可能出现在用户的浏览历史、通知、
                    // 或某份旧文档里。它们现在一律重定向到 `/settings`。
                    GoRoute(
                      path: 'diagnostics',
                      name: 'diagnostics',
                      redirect: (context, state) => Routes.settings,
                    ),
                    GoRoute(
                      path: 'ai',
                      name: 'aiSettings',
                      redirect: (context, state) => Routes.settings,
                    ),
                    GoRoute(
                      path: 'push',
                      name: 'pushSettings',
                      // 旧的指引页地址（`/settings/push/guide`）留着，同样
                      // 只是重定向；它的目标以前是 `/settings/push`，现在
                      // 直接到 `/settings`，省一层没人看得见的跳转。
                      routes: <RouteBase>[
                        GoRoute(
                          path: 'guide',
                          name: 'pushSetupGuide',
                          redirect: (context, state) => Routes.settings,
                        ),
                      ],
                      redirect: (context, state) => Routes.settings,
                    ),
                    GoRoute(
                      // 旧地址：添加实例现在是「实例」那一栏**页内**的第二种
                      // 形态（`SettingsScreen._addingInstance`），不再压一条
                      // 路由。深链留着重定向到 `/settings`。
                      path: 'add-instance',
                      name: 'addInstance',
                      redirect: (context, state) => Routes.settings,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),

        // 扩展路由。**公开版这里是空的**（`main` 分支不注册任何扩展）——
        // 商业版/第三方模块在商业分支上把自己的路由挂进注册表，核心一行不用改。
        // 放在核心路由**之后**：扩展不能抢占核心路径。
        ...AppExtensionRegistry.instance.routes(),
      ],
      errorBuilder: (context, state) => _NotFoundScreen(uri: state.uri),
    );
    ref.onDispose(router.dispose);
    return router;
  },
  name: 'router',
);

/// 重定向：把「有没有实例」「登没登录」「地址还对不对」折算成该落在哪个页面，
/// 再把「打开的是哪一封」按当前宽度在两种形态之间折一次。
///
/// 后半句（[foldSelectionAcrossBreakpoints]）放在**最外层**而不是挂在各条列表
/// 路由上：窗口变宽变窄时 `AppShell` 会就地 `GoRouter.refresh()` 一次（见
/// `app_shell.dart` 的 `_BreakpointRouteSync`），而 refresh 走的就是这条最外层
/// 重定向 —— 挂在内层的话，宽窄切换时根本没有一次「导航」能让内层重定向跑起来。
///
/// 顺序是**先鉴权、后折叠**：`resolveRedirect` 返回的地址可能是一张完全不同的
/// 页面（登录页 / 设置页），那一刻折叠它没有意义。反过来，折叠出的新地址会被
/// go_router 再跑一轮重定向（它自己会递归），所以鉴权那一轮不会漏。
String? _redirect(Ref ref, BuildContext context, GoRouterState state) {
  final auth = resolveRedirect(
    healthy: ref.read(bootstrapProvider).isHealthy,
    async: ref.read(profilesProvider),
    location: state.matchedLocation,
    // 两条分支各用各的参数名：`/mail/:profileId` 与 `/login/:profileId`。
    profileIdParam: state.pathParameters['profileId'],
  );
  if (auth != null) return auth;
  return foldSelectionAcrossBreakpoints(
    panes: Breakpoints.panesOf(context),
    uri: state.uri,
  );
}

/// 窗口跨过断点时，把「当前打开的是哪一封」在两种形态之间折一次。
///
/// 两种形态（见 `Breakpoints`）：
///
/// - **分栏**（>= 1024）：选中态是 `?sel=`（`/mail/<节点>?sel=`、
///   `/starred?sel=`、`/outbox?sel=`），详情画在右栏里；
/// - **单栏**（< 1024）：详情是**一整页**（`/mail/<节点>/<e>`、`/starred/<e>`、
///   `/outbox/<e>`）。
///
/// 这条函数解决的是**窗口尺寸变化**这个用户报过的 bug：用户在分栏里点开一封
/// 邮件、甚至打开了正文下方的 AI 建议面板，然后把窗口拖窄 —— 以前地址还停在
/// `?sel=` 上，而单栏形态**根本没有右栏**，于是屏幕一下退回「这一屏的邮件
/// 列表」，用户明明选中的那封不见踪影（连 AI 面板一起）。反过来把窗口拖宽时，
/// 地址还是 `/mail/<节点>/<e>`，详情就退回成一张压着列表的整页。
///
/// 现在两个方向都由这里折：单栏 → 整页详情地址，分栏 → `?sel=`。**只看宽度，
/// 不看平台**，与 `Breakpoints` 同一条规矩。
///
/// 纯函数（只吃 `Uri` 与一个宽度判据），`pane_routes_test.dart` 里逐条钉住。
/// 返回 null = 不需要折（照常匹配）。
@visibleForTesting
String? foldSelectionAcrossBreakpoints({
  required bool panes,
  required Uri uri,
}) {
  final segments = uri.pathSegments;
  if (segments.isEmpty) return null;
  // `pathSegments` 里没有前导斜杠（`/mail/all` → `mail` / `all`），而路由常量
  // 都带斜杠；拼回第一段再比，免得两套写法各错一半。
  final root = '/${segments.first}';
  final query = uri.queryParameters;

  if (panes) {
    // ---- 整页详情 → 分栏选中 -------------------------------------------
    //
    // 与 `Routes.mailOf` / `paneSelectionOf` 的写法**逐字对齐**：参数只在非
    // 默认值时写出来，否则同一条列表会出现两个「看着不一样其实一样」的地址。
    if (segments.length == 3 && root == Routes.mail) {
      final emailId = _positive(segments[2]);
      if (emailId == null) return null;
      final node = segments[1];
      // 聚合节点（`/mail/all/<e>`）：实例只能从 `profile=` 补；补不到就画不出
      // 右栏（`_selectedOf` 同一个口径），照常整页显示。
      if (Routes.parseProfileId(node) == null) {
        final profileId = query['profile'] ?? '';
        if (profileId.isEmpty) return null;
        return paneSelectionOf(
          root: '${Routes.mail}/${Routes.kAggregateNode}',
          profileId: profileId,
          emailId: emailId,
          folder: folderOf(query['folder']),
          unreadOnly: _unreadOfUri(uri),
        );
      }
      return Routes.mailOf(
        node,
        accountId: Routes.parseAccountId(query[Routes.accountParam]),
        folder: folderOf(query['folder']),
        selectedEmailId: emailId,
        unreadOnly: _unreadOfUri(uri),
      );
    }
    if (segments.length == 2 && root == Routes.starred) {
      final emailId = _positive(segments[1]);
      if (emailId == null) return null;
      final profileId = query['profile'] ?? '';
      if (profileId.isEmpty) return null;
      // 星标这一支**不带 folder**（见 `paneSelectionOf` 的注释）。
      return paneSelectionOf(
        root: Routes.starred,
        profileId: profileId,
        emailId: emailId,
        unreadOnly: _unreadOfUri(uri),
      );
    }
    if (segments.length == 2 && root == Routes.outbox) {
      final id = _positive(segments[1]);
      if (id == null) return null;
      return Routes.outboxWith(id);
    }
    return null;
  }

  // ---- 分栏选中 → 整页详情 ---------------------------------------------
  if (segments.length == 2 && root == Routes.mail) {
    final emailId = _positive(query['sel'] ?? '');
    if (emailId == null) return null;
    final node = segments[1];
    // 聚合节点的 `sel` 必带 `profile=`（`paneSelectionOf` 写出来的就是那个
    // 形状）；缺了就折不出一整页详情，宁可停在列表上。
    final profileId = Routes.parseProfileId(node) ?? (query['profile'] ?? '');
    if (profileId.isEmpty) return null;
    return detailRouteOf(
      node: node,
      profileId: profileId,
      emailId: emailId,
      folder: folderOf(query['folder']),
      accountId: Routes.parseAccountId(query[Routes.accountParam]),
      unreadOnly: _unreadOfUri(uri),
    );
  }
  if (segments.length == 1 && root == Routes.starred) {
    final emailId = _positive(query['sel'] ?? '');
    if (emailId == null) return null;
    final profileId = query['profile'] ?? '';
    if (profileId.isEmpty) return null;
    return detailRouteOf(
      node: Routes.starred,
      profileId: profileId,
      emailId: emailId,
      folder: MailFolder.starred,
      unreadOnly: _unreadOfUri(uri),
    );
  }
  if (segments.length == 1 && root == Routes.outbox) {
    final id = _positive(query['sel'] ?? '');
    if (id == null) return null;
    return Routes.outboxDetailOf(id);
  }
  return null;
}

/// 地址里的「选中项 id」：没写 / 不是数 / 非正数都算「没选中」。
int? _positive(String? raw) {
  final value = int.tryParse(raw ?? '');
  if (value == null || value <= 0) return null;
  return value;
}

/// [resolveRedirect] 的输入之一 —— 实例列表还没读出来时要区别对待，
/// 所以直接把 `AsyncValue` 传进来（而不是只传 `.value`）。
///
/// 抽成独立函数（而不是留在 `_redirect` 闭包里）纯粹是为了可测：
/// 这段判断是整个导航的骨架，却没有任何别的手段能观察到它。
@visibleForTesting
String? resolveRedirect({
  required bool healthy,
  required AsyncValue<List<Profile>> async,
  required String location,
  required String? profileIdParam,
}) {
  if (!healthy) {
    return location == Routes.startupFailure ? null : Routes.startupFailure;
  }

  // 表还没读出来 —— 停在原地（shell 会显示加载态），否则冷启动会先闪一下
  // 设置页 / 服务器设置页，用户会以为实例丢了。
  if (async.isLoading && !async.hasValue) return null;
  final profiles = async.value ?? const <Profile>[];

  // 一个实例都没有（新装）→ 落在**设置页**，而不是那张占满整窗的服务器
  // 设置页：壳的一级导航与设置分类菜单都得在，用户在那里点「添加第一个
  // 实例」才开始加。这条同时是 `setup` 路由退役的原因 —— 那张表已经并进
  // 设置页的「实例」那一栏（`AddInstanceSection`）。
  //
  // **扩展的顶层页面例外**（`/account/login` 这类）：它们是**壳之外**的
  // 整屏页，不依赖任何邮件实例就能用 —— 恰恰相反，零实例时它们是最该到的
  // 那一页（Pro 的账号登录与「添加第一个邮件实例」是两件事，账号不该被
  // 邮件实例的有无卡住）。曾经没有这个例外：全新安装的 Pro 里点「账号 →
  // 登录」被这条重定向原样折回设置页，用户看到的是「按钮点了没反应」
  // （2026-11-10 真机复现）。判据只认**扩展注册的顶层路由**，核心自己的
  // 顶层页（登录页 / 同步页）仍按上面的规矩折回设置页。
  if (profiles.isEmpty) {
    if (location == Routes.settings) return null;
    if (_extensionOwnsTopLevelPath(location)) return null;
    return Routes.settings;
  }

  final anyLoggedIn = profiles.any((p) => p.isLoggedIn);

  // 有实例但一个都没登进去 → 落在第一个待登录实例的登录页。
  if (!anyLoggedIn) {
    final want = '${Routes.login}/${profiles.first.id}';
    return location == want ? null : want;
  }

  // 已经从别处登好了，别再停在登录页 —— 但要留一个例外：这个登录页对应的
  // 实例**确实还需要登录**（token 被判 401，或者还没登过），那它就该待在这儿。
  // 少了这个例外，「某个实例掉线后重新登录」会被立刻弹回聚合页，
  // 而用户想登的正是那一个。
  if (location.startsWith(Routes.login)) {
    final target = _find(profiles, profileIdParam);
    if (target != null && !target.isLoggedIn) return null;
    return Routes.mailAll;
  }
  if (location == Routes.setup) return Routes.settings;

  final id = Routes.parseProfileId(profileIdParam);
  if (id != null) {
    final target = _find(profiles, id);
    if (location.startsWith(Routes.mail) && target == null) {
      // `/mail/<id>` 里的实例已被删除 → 回全部实例合并的列表
      // （不然会是一条永远加载不出来的列表）。
      return Routes.mailAll;
    }
    // token 失效：这台实例已经做不了任何事，把它自己的登录页顶上来。
    // **只有路由确实指向这个实例时才会走到这里** —— 别的实例掉线
    // 不该把用户从正在读的信里拽出来。
    if (location.startsWith(Routes.mail) && target != null && target.needsLogin) {
      return '${Routes.login}/$id';
    }
  }
  return null;
}

Profile? _find(List<Profile> profiles, String? id) {
  if (id == null || id.isEmpty) return null;
  for (final profile in profiles) {
    if (profile.id == id) return profile;
  }
  return null;
}

/// 地址是不是**扩展注册的顶层路由**（`AppExtension.routes()`）。
///
/// 只给 [resolveRedirect] 里「一个实例都没有」那一条用：零实例时我们要把
/// 用户钉在设置页（那里才能添加实例），但扩展的顶层页是**整屏、壳之外**的，
/// 不依赖邮件实例 —— 折回去等于让按钮点击没反应。
///
/// 子路径一并放行（`/account/login?expired=1` 的 query 不进
/// `matchedLocation`，但扩展也可以自己往里挂 `:id` 这种子路由）：顶层注册的
/// 前缀就是那一整块「扩展自己管的面」。
///
/// 注册表是启动前定好、之后只读的全局单例（见 `AppExtensionRegistry`），
/// 所以这里直接读，不需要 `ref`。公开版注册表为空 → 恒为 false，行为与
/// 这个例外出现之前逐字相同。
bool _extensionOwnsTopLevelPath(String location) {
  final path = Uri.parse(location).path;
  if (path.isEmpty) return false;
  for (final route in AppExtensionRegistry.instance.routes()) {
    if (route is! GoRoute) continue;
    final prefix = route.path;
    if (prefix.isEmpty) continue;
    if (path == prefix || path.startsWith('$prefix/')) return true;
  }
  return false;
}

MailFolder folderOf(String? raw) {
  for (final folder in MailFolder.values) {
    if (folder.name == raw) return folder;
  }
  return MailFolder.receive;
}

/// 列表路由上的「当前选中邮件」。
///
/// 三个列表路由的实例参数名各不相同（`/mail/:profileId` 是路径段，
/// 聚合 / 星标只在 `profile=` 查询参数里），所以这里统一从 `sel` +
/// `profile` 里取；`/mail/<id>?sel=` 会先走路径段。
MailRef? _selectedOf(BuildContext context, GoRouterState state, {String? root}) {
  if (!Breakpoints.panesOf(context)) return null;
  final emailId = int.tryParse(state.uri.queryParameters['sel'] ?? '') ?? 0;
  final profileId = root == null
      ? Routes.parseProfileId(state.pathParameters['profileId']) ??
          state.uri.queryParameters['profile']
      : state.uri.queryParameters['profile'];
  return paneSelectionOfRoute(
    wide: true,
    profileId: profileId,
    emailId: emailId,
  );
}

/// 详情路由的宽屏折返：`/mail/<p>/<e>` → `/mail/<p>?sel=<e>`，
/// `/starred/<e>?profile=x` → `/starred?sel=<e>&profile=x`。
///
/// 真正的折法在 [foldSelectionAcrossBreakpoints]（那是窗口变宽变窄时也走同一条
/// 函数的地方）；这里保留一层只是为了**导航那一刻**就折掉：go_router 的 route
/// 级重定向在进入那条路由时跑，早于任何一帧布局，深链（通知、浏览器历史）落到
/// 整页详情地址时不会先闪一下那张整页再被折进右栏。
///
/// 返回 null 表示「照常匹配」—— 单栏全部走这条，行为与今天完全一致。
String? _paneRedirectForDetail(BuildContext context, GoRouterState state) =>
    foldSelectionAcrossBreakpoints(
      panes: Breakpoints.panesOf(context),
      uri: state.uri,
    );

/// 地址里「只看未读」（与 `HomeEntry._unreadOf` 同一口径）。
bool _unreadOfUri(Uri uri) {
  final raw = uri.queryParameters[Routes.unreadParam];
  return raw == '1' || raw == 'true';
}

/// 拼列表里一条 → 详情页的路由。
///
/// **路径段写「我当时在哪张列表上」，这封信真正属于哪个实例走 `profile=`。**
/// 两件事必须分开：聚合列表（`/mail/all`）里每一行来自不同实例，写进路径段的
/// 只能是列表自己的节点 —— 换成邮件的实例，侧栏的高亮判据（`HomeEntry.isOn`
/// 那套按段比对）就认不出「你还在收件箱里」，整列高亮会消失。
///
/// `folder` 与 `unreadOnly` 是「这张列表是哪一个入口」的另一半：收件箱 /
/// 未读邮件 / 已发送共用 `/mail/all` 这一段，少带一个，返回时就会落到另一个
/// 入口上（已发送点开一封会亮成收件箱）。两处的省略规则与 [Routes.mailOf]
/// 保持一致：`receive` 与 `false` 是默认值，不写出来。
///
/// `accountId` 是**左侧菜单下级菜单**那一屏的落点（见 [Routes.mailOf]）。
/// 漏了它，用户从「某个邮箱的收件箱」点开一封再返回，就会掉回实例级 ——
/// 于是筛选按钮重新冒出来、列表悄悄变宽，而用户完全看不出发生了什么。
String detailRouteOf({
  required String node,
  required String profileId,
  required int emailId,
  required MailFolder folder,
  int? accountId,
  bool unreadOnly = false,
}) => switch (folder) {
  // 星标是**另一支**（节点是 `/starred`，地址里没有实例），实例只能走
  // `profile=` —— 它本来就是这个路由上已有的查询参数，沿用同一个名字。
  MailFolder.starred => Uri(
      path: '${Routes.starred}/$emailId',
      queryParameters: <String, String>{
        'profile': profileId,
        if (unreadOnly) Routes.unreadParam: '1',
      },
    ).toString(),
  _ => _mailDetail(
      node: node,
      profileId: profileId,
      emailId: emailId,
      params: <String, String>{
        // 节点本身就是实例时，路径段已经说得清是哪一个，不必再写一遍。
        if (node == Routes.kAggregateNode) 'profile': profileId,
        if (accountId != null) Routes.accountParam: '$accountId',
        if (folder != MailFolder.receive) 'folder': folder.name,
        if (unreadOnly) Routes.unreadParam: '1',
      },
    ),
};

/// 详情地址里那一段 `/mail/<节点>/<emailId>`。
///
/// 单独抽出来是因为 `Uri(queryParameters: <String, String>{})` 会给出一个
/// 拖尾的 `?`（空 map 与 null 不是一回事）—— 与 [Routes.mailOf] 一样，
/// 没有参数就干脆不写这一节。
String _mailDetail({
  required String node,
  required String profileId,
  required int emailId,
  required Map<String, String> params,
}) => Uri(
  path: '${Routes.mail}/$node/$emailId',
  queryParameters: params.isEmpty ? null : params,
).toString();

/// 分栏形态下「聚合 / 星标」列表选中一封的地址。
///
/// 这两支的路径里没有实例（`/mail/all`、`/starred`），而 `emailId` 跨实例
/// 会重号，所以选中态必须带上 `profile` —— 它本来就是这两个详情路由上
/// 已有的查询参数，这里沿用同一个名字，不再造一个。
///
/// [folder] / [unreadOnly] 与 [Routes.mailOf] 同一个口径：**只有非默认值才
/// 写出来**。星标那一支**不要**传 `folder` —— 星标入口的 `HomeEntry.folder`
/// 是默认的 `receive`，地址里多一个 `folder=starred` 反而会让它自己失配。
String paneSelectionOf({
  required String root,
  required String profileId,
  required int emailId,
  MailFolder? folder,
  bool unreadOnly = false,
}) => Uri(
  path: root,
  queryParameters: <String, String>{
    'sel': '$emailId',
    'profile': profileId,
    if (folder != null && folder != MailFolder.receive) 'folder': folder.name,
    if (unreadOnly) Routes.unreadParam: '1',
  },
).toString();

/// 从列表页的查询参数里读出「当前选中的邮件」。
///
/// **窄屏恒为 null**：选中态只属于分栏形态，窄屏下这个 `sel` 不该存在
/// （真出现了也只可能是用户从宽窗口缩回来时留下的），不能让窄屏因此
/// 显示出什么额外的东西。抽成纯函数是为了可测 —— 这段判断没有别的手段
/// 能观察到它。
@visibleForTesting
MailRef? paneSelectionOfRoute({
  required bool wide,
  required String? profileId,
  required int emailId,
}) {
  if (!wide || emailId <= 0) return null;
  if (profileId == null || profileId.isEmpty) return null;
  return MailRef(profileId: profileId, emailId: emailId);
}

class _NotFoundScreen extends StatelessWidget {
  const _NotFoundScreen({required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('页面不存在')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('无法打开：$uri'),
            ),
            FilledButton(
              onPressed: () => context.go(Routes.mailAll),
              child: const Text('回到收件箱'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 地址是不是撰写页（`/compose`）。
///
/// 撰写页现在是「邮件」那一支里的根路由：窄屏要据它收起底部导航（那一页
/// 是整屏的）、外壳要据它不挂写邮件 FAB（页内已经有发送按钮）。
bool isComposeRoute(Uri uri) => uri.path == Routes.compose;

/// 撰写页地址里选中的草稿 id（没有 / 不是数 → 0）。
///
/// 左侧「邮件撰写」的子项靠它判高亮：`/compose` 这一条路径是**所有**撰写页
/// 共用的，不带 `draft` 就分不出开的是哪一页。
int composeDraftIdOf(Uri uri) =>
    int.tryParse(uri.queryParameters['draft'] ?? '') ?? 0;
