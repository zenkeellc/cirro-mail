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
import 'features/onboarding/server_setup_screen.dart';
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

  static const String setup = '/setup';
  static const String login = '/login';

  /// 主屏（一级导航 index 0 的根）：窄屏是 icon 网格，宽屏由侧栏承担。
  static const String home = '/home';

  static const String mail = '/mail';

  static const String starred = '/starred';
  static const String settings = '/settings';

  /// 这三条**曾经是三个独立整页**（AI / 推送 / 诊断各一页），现在都并进
  /// `/settings` 自己的分类里（宽屏在右栏内嵌、窄屏是一页）。
  ///
  /// 常量留着与 [pushSetupGuide] 同一条理由：**深链不该断**。这几个地址可能
  /// 出现在用户的浏览历史、通知、或某份旧文档里，落到 404 会让人以为坏了 ——
  /// 路由表里它们此刻都是 `redirect: (…) => Routes.settings`。
  /// 只有 [addInstance] 还是一张真的表单页。
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

  /// 「添加实例」。单独一条路由而不是复用 [setup]：`redirect` 已经把
  /// `/setup` 钉死成「一个实例都没有时」的去处，已登录时从设置页再进
  /// `/setup` 会被弹回聚合页，第二个实例就加不上了。
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

  /// 写邮件页。**顶层路由，不在 shell 分支里**。
  ///
  /// 刻意不做成第五个底部导航项：`StatefulShellRoute` 用 indexedStack 保活
  /// 每个分支，写邮件页一旦成为分支，它就**永远不会被回收** ——
  /// `composeControllerProvider` 的自动释放（连同「离开即存草稿」这套兜底）
  /// 全都失效，用户切走再切回来会看到一份躺在内存里的旧状态。
  /// 而且分支根部没有可 pop 的东西，返回语义也就没了。
  static const String compose = '/compose';

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
        final signature = _signature(next.value ?? const <Profile>[]);
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
      redirect: (context, state) => _redirect(ref, state),
      routes: <RouteBase>[
        GoRoute(
          path: Routes.startupFailure,
          name: 'startupFailure',
          builder: (context, state) => const StartupFailureScreen(),
        ),
        GoRoute(
          path: Routes.setup,
          name: 'setup',
          builder: (context, state) => const ServerSetupScreen(),
        ),
        GoRoute(
          path: '${Routes.login}/:profileId',
          name: 'login',
          builder: (context, state) =>
              LoginScreen(profileId: state.pathParameters['profileId']!),
        ),
        // 写邮件是顶层 push，不挂在任何 shell 分支下（见 `Routes.compose`
        // 的注释：挂进分支就永远不会被回收，草稿落盘的兜底也失效）。
        GoRoute(
          path: Routes.compose,
          name: 'compose',
          builder: (context, state) {
            final query = state.uri.queryParameters;
            return ComposeEntry(
              mode: composeModeOf(query['mode']),
              profileId: query['profile'] ?? '',
              accountId: int.tryParse(query['account'] ?? '') ?? 0,
              draftId: int.tryParse(query['draft'] ?? '') ?? 0,
              emailId: int.tryParse(query['email'] ?? '') ?? 0,
            );
          },
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
                // 附件缓存。
                GoRoute(
                  path: Routes.attachmentCache,
                  name: 'attachmentCache',
                  builder: (context, state) => const AttachmentCacheScreen(),
                ),
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
                          _paneRedirectForDetail(context, state,
                              root: Routes.starred),
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
                      path: 'add-instance',
                      name: 'addInstance',
                      builder: (context, state) =>
                          const ServerSetupScreen(returnToCaller: true),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
      errorBuilder: (context, state) => _NotFoundScreen(uri: state.uri),
    );
    ref.onDispose(router.dispose);
    return router;
  },
  name: 'router',
);

/// 重定向：把「有没有实例」「登没登录」「地址还对不对」折算成该落在哪个页面。
String? _redirect(Ref ref, GoRouterState state) => resolveRedirect(
  healthy: ref.read(bootstrapProvider).isHealthy,
  async: ref.read(profilesProvider),
  location: state.matchedLocation,
  // 两条分支各用各的参数名：`/mail/:profileId` 与 `/login/:profileId`。
  profileIdParam: state.pathParameters['profileId'],
);

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
  // 「服务器设置」页，用户会以为实例丢了。
  if (async.isLoading && !async.hasValue) return null;
  final profiles = async.value ?? const <Profile>[];

  // 没有任何实例 → 只能去加一个。
  if (profiles.isEmpty) {
    return location == Routes.setup ? null : Routes.setup;
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
  if (location == Routes.setup) return Routes.mailAll;

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
/// 返回 null 表示「照常匹配」—— 窄屏全部走这条，行为与今天完全一致。
String? _paneRedirectForDetail(
  BuildContext context,
  GoRouterState state, {
  String? root,
}) {
  if (!Breakpoints.panesOf(context)) return null;
  final emailId = int.tryParse(state.pathParameters['emailId'] ?? '') ?? 0;
  if (emailId <= 0) return null;

  if (root != null) {
    final profileId = state.uri.queryParameters['profile'] ?? '';
    if (profileId.isEmpty) return null;
    return paneSelectionOf(
      root: root,
      profileId: profileId,
      emailId: emailId,
    );
  }

  final node = state.pathParameters['profileId'];
  // 聚合节点（`/mail/all/<e>`）：右栏能画，但**实例不在路径里** —— 用同一个
  // 详情的 `profile=` 查询参数补上（与 `_selectedOf` 的口径一致），缺了就画
  // 不出右栏，照常整页显示。
  if (Routes.parseProfileId(node) == null) {
    final profile = state.uri.queryParameters['profile'] ?? '';
    if (profile.isEmpty) return null;
    return paneSelectionOf(
      root: '${Routes.mail}/${Routes.kAggregateNode}',
      profileId: profile,
      emailId: emailId,
      folder: folderOf(state.uri.queryParameters['folder']),
      unreadOnly: _unreadOf(state),
    );
  }

  return Routes.mailOf(
    node!,
    accountId: Routes.parseAccountId(state.uri.queryParameters[Routes.accountParam]),
    folder: folderOf(state.uri.queryParameters['folder']),
    selectedEmailId: emailId,
    unreadOnly: _unreadOf(state),
  );
}

/// 地址里「只看未读」（与 `HomeEntry._unreadOf` 同一口径）。
bool _unreadOf(GoRouterState state) {
  final raw = state.uri.queryParameters[Routes.unreadParam];
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
