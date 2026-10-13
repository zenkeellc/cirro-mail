import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/breakpoints.dart';
import '../../data/models/enums.dart';
import '../../data/models/instance_capabilities.dart';
import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../data/models/mailbox_account.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/mail_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/sync_providers.dart';
import '../../router.dart';
import '../compose/compose_preselect.dart';
import '../sync/sync_status_panel.dart';
import 'mail_list_column.dart';
import 'mail_list_view.dart';
import 'mail_panes.dart';
import 'mail_selection.dart';
import 'mail_selection_pane.dart';
import 'mailbox_filter.dart';
import 'mailbox_filter_button.dart';
import 'mailbox_scope.dart';

/// 邮件列表：收件箱 / 未读邮件 / 已发送（含 `/mail/all` 的全部实例合并）。
///
/// 这一页是改动之后**唯一**的邮件列表实现 —— 聚合页被并进来了，两者本来就是
/// 同一个 `MailListView`。
///
/// 状态分两处：
/// - **URL**：`folder`、`unread`、`account`、（分栏下）`sel` —— 前进后退与
///   通知深链要用；
/// - **prefs**：勾选的邮箱集合 —— 它是用户的偏好，不是「去哪」，
///   而窄屏把整个集合塞进 URL 又长又难读（spec §5 明确不做）。
///
/// `/mail/<实例>` 与 `/mail/all` 的差别只有一条：前者把勾选集合**再收窄到
/// 那一个实例**。收窄之后一个都不剩时退回该实例的合并项 —— 否则
/// `MailListQuery` 的空集合语义是「全部实例」，用户点某个实例反而会看到
/// 全部实例的信，正好反了。
///
/// ## 两种形态
///
/// - **实例级**（地址里没有 `account`）：收窄到实例，头上有「已选 x 个邮箱」
///   那颗按钮，勾选走全局 prefs；
/// - **钉住某个邮箱**（地址里有 `account`，左侧菜单的下级菜单落点）：只看这
///   一个邮箱，**完全不看 prefs**，头上一行静态地址、没有筛选按钮
///   （见 [pinnedMailboxOf]）。
class MailListScreen extends ConsumerStatefulWidget {
  const MailListScreen({
    super.key,
    this.profileId,
    this.accountId,
    this.folder = MailFolder.receive,
    this.unreadOnly = false,
    this.selected,
  });

  /// null = 全部实例合并（`/mail/all`）。
  final String? profileId;

  /// 非 null = 钉在这一个邮箱上（左侧菜单下级菜单的落点）。
  ///
  /// **`0`（[kAllMailboxes]）是一个合法值**，表示「这个实例的全部邮箱」，
  /// 不是「没指名」—— 所以判据是 `!= null` 而不是 `> 0`，见 [pinnedMailboxOf]。
  final int? accountId;

  final MailFolder folder;

  /// 只看未读（主屏「未读邮件」入口）。
  final bool unreadOnly;

  /// 分栏形态下右栏打开的那封（URL 里的 `sel`）。窄屏恒为 null。
  final MailRef? selected;

  @override
  ConsumerState<MailListScreen> createState() => _MailListScreenState();
}

class _MailListScreenState extends ConsumerState<MailListScreen> {
  /// 这一屏在 `composePreselectProvider` 里的身份（见 `publish` 的 `owner`）：
  /// **必须每屏一个唯一对象**，否则两条列表屏会互相覆盖。
  final Object _preselectOwner = Object();

  /// 这一屏**走后**要留下的说法。与 [_preselectOwner] 成对：`clear(owner)`
  /// 只在「最后说话的还是我」时才生效，所以两者必须指同一次会话。
  ///
  /// 为什么不在 `deactivate` 里现取 notifier：`dispose` 里 `ref` 已经不能用了
  /// （riverpod 3 会抛「Using "ref" when a widget is about to or has been
  /// unmounted」），而 `initState` 里 `ref.read` 是合法的 —— 所以在这里先
  /// 拿着，收回时只用这个已经拿到的对象。
  late final ComposePreselectController _preselect =
      ref.read(composePreselectProvider.notifier);

  @override
  void initState() {
    super.initState();
    _syncIncludeSent();
  }

  @override
  void didUpdateWidget(MailListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.folder != widget.folder) _syncIncludeSent();
  }

  @override
  void deactivate() {
    super.deactivate();
    // 这一屏被摘下来了（页面 pop / 实例被删 / 整棵树重建）：让外壳那颗 FAB
    // 的预选失效，免得离开了收件箱还带着它的邮箱进写邮件页。
    //
    // **放在 `deactivate` 而不是 `dispose`**：`dispose` 里 `ref` 已经不能用了
    // （见上面 [_preselect] 的注释），这儿还能取到 notifier。`deactivate` 在
    // 这两种情况下的语义：
    // - 页面真的被摘下来 → 它跑，`dispose` 紧跟；
    // - `IndexedStack` 切 offstage → **不跑**（那只是标记变了，元素原地不动）。
    //   这正是我们要的：切分支时那一支还活着，回来接着用它的预选。
    //
    // 两处改动都**推迟到帧后**：`deactivate` 可能正跑在 build 阶段 ——
    // go_router 换掉这一支的页面栈，就是同一帧里「摘旧的、挂新的」；窄屏从
    // 主屏网格 push 一页时，旧路由也在同一帧里被摘下去。那种时刻改 provider
    // 会踢到树根上的 `UncontrolledProviderScope`，riverpod 当场抛
    // 「Tried to modify a provider while the widget tree was building」
    // （就是用户从侧栏点「草稿箱」时看到的那条）。
    //
    // 所以：**同步**把 notifier 拿到手（此刻 `ref` 还能用），**值**等帧后再写。
    // 不用 `mounted` 兜底 —— 帧后这个元素多半已经 unmount 了，而这里要做的
    // 恰恰是「它走了，把它留下的说法收掉」，跳过就没人收了。谁先谁后由
    // [_preselectOwner] 那个令牌兜着（见 [ComposePreselectController.clear]）。
    final preselect = _preselect;
    final leavingSent = widget.folder == MailFolder.send;
    final sync = leavingSent ? ref.read(syncControllerProvider.notifier) : null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      preselect.clear(_preselectOwner);

      // 离开「已发送」时把发件方向的轮询关掉：那条路径要拉列表首页比对
      // 游标，比收件方向的 `/email/latest` 贵得多。
      sync?.setIncludeSent(false);
    });
  }

  void _syncIncludeSent() {
    final include = widget.folder == MailFolder.send;
    // 在 build 期间改 provider 会触发「build 中修改 provider」的断言，
    // 推迟到帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(syncControllerProvider.notifier).setIncludeSent(include);
    });
  }

  /// 把「URL 里的 folder / unread / 实例 / 钉住的邮箱」与「prefs 里的勾选集合」
  /// 合成一个查询。
  ///
  /// [selection] 由调用方传进来（`ref.watch` 过的那个）：写邮件要用的预选值
  /// 也从它算，两处必须看同一个快照。
  MailListQuery _queryFor(MailboxSelection selection) {
    final profileId = widget.profileId;
    final pinned = widget.accountId;

    // 钉住时**完全不看 prefs**：这一屏的意义就是「只看这一个邮箱」，
    // 而 prefs 是跨实例的全局偏好 —— 拿它去收窄，用户点某个邮箱之后会看到
    // 另一个邮箱的信（甚至另一台实例的）。见 `pinnedMailboxOf`。
    if (profileId != null && pinned != null) {
      return MailListQuery(
        mailboxes: <MailboxFilter>[
          MailboxFilter(profileId: profileId, accountId: pinned),
        ],
        folder: widget.folder,
        unreadOnly: widget.unreadOnly,
      );
    }

    final boxes = profileId == null
        ? selection.selected
        : selection.selected
            .where((box) => box.profileId == profileId)
            .toList(growable: false);

    return MailListQuery(
      // 收窄之后一个都不剩：退回该实例的合并项，而不是让空集合变成
      // 「全部实例」—— 那正好是用户想避免的事。
      mailboxes: boxes.isNotEmpty || profileId == null
          ? boxes
          : <MailboxFilter>[
              MailboxFilter(profileId: profileId, accountId: kAllMailboxes),
            ],
      folder: widget.folder,
      unreadOnly: widget.unreadOnly,
    );
  }

  /// 这一屏是不是「钉在某个邮箱上」的。
  bool get _pinned => widget.profileId != null && widget.accountId != null;

  @override
  Widget build(BuildContext context) {
    final id = widget.profileId;
    // `/mail/<id>` 的实例已被删掉时 redirect 会兜住；这里只是避免一帧空指针。
    final profile = id == null ? null : ref.watch(profileByIdProvider(id));
    if (id != null && profile == null) {
      return const Scaffold(body: SizedBox.shrink());
    }

    final selection = ref.watch(mailboxFilterSelectionProvider);
    final query = _queryFor(selection);
    final mailboxes = ref.watch(mailboxesProvider(id ?? '')).value ??
        const <MailboxAccount>[];
    final caps = id == null
        ? const InstanceCapabilities()
        : ref.watch(capabilitiesProvider(id)).value ??
            const InstanceCapabilities();

    // 这一屏把它「说得清从哪个邮箱发」的结论发布给外壳那颗写邮件 FAB
    // （这一屏自己的那颗已经删掉了 —— 外壳会把它盖住）。写入放在帧后：
    // build 期间改 provider 会触发断言。
    _publishComposePreselect(selection);

    final l10n = AppLocalizations.of(context);
    final emptyHint = switch (widget.folder) {
      MailFolder.send => '还没有发出的邮件',
      _ when widget.unreadOnly => '没有未读邮件',
      _ => l10n.emptyList,
    };

    final header = _ListHeader(
      title: _title(l10n),
      // 钉住时给一行静态地址（说不出「已选几个」，也**不该**有那颗按钮）；
      // 否则给那颗「已选 x 个邮箱」按钮 —— 它替掉了标题下原来那行小字。
      below: _pinned
          ? _PinnedMailboxLabel(
              label: _pinnedLabel(query, mailboxes),
            )
          : MailboxFilterHeaderButton(count: query.mailboxes.length),
    );
    // 列表右上角**只有一个**同步按钮（spec §2.5）：侧栏顶部那个、以及旁边
    // 那个 ↻ 都删掉了。筛选入口搬到了标题下面（见上面的 `below`）。
    //
    // 它自己的语义见 `SyncStatusButton`：空闲时点它 = 当场同步一轮
    // （与下拉刷新是同一件事的两条路径），同步中时点它才进同步页。
    final actions = <Widget>[const SyncStatusButton()];
    final denied = caps.hasAccountQuery == ProbeState.denied;

    // 这一屏是不是正在多选，以及那一批的统计。
    //
    // 判据与 `MailListView` 里画复选框的那条**同一处**（`selectionAppliesTo`）
    // —— 右栏显示一批的统计、左栏却一个复选框都没有，是这类界面里最典型的
    // 对不上。scope 由查询反推，见 `selectionScopeForQuery`。
    final scope = selectionScopeForQuery(
      query,
      listNode: Routes.aliasOf(widget.profileId),
    );
    // 发件箱不接多选：那一屏是「我发出去的信」的台账，没有「一批一起处理」
    // 的语义（服务端连「移到文件夹」都没有），而底部操作栏会在窄屏上白白占
    // 掉一条位置。收件箱 / 未读 / 星标都接。
    final multiSelect = widget.folder != MailFolder.send;
    final selecting = multiSelect &&
        selectionAppliesTo(ref.watch(mailSelectionProvider), scope);
    final stats = selecting
        ? ref.watch(selectedRowsProvider(query))
        : const SelectedMails();

    if (Breakpoints.panesOf(context)) {
      return Scaffold(
        body: MailPanes(
          selected: widget.selected,
          onClosed: _clearSelection,
          // 多选时右栏换成这一批的统计与常用处理（需求 1）。
          pane: selecting ? MailSelectionPane(stats: stats) : null,
          list: MailListColumn(
            query: query,
            listNode: Routes.aliasOf(widget.profileId),
            header: header,
            headerActions: actions,
            emptyHint: emptyHint,
            hintBanner: denied ? const _AccountPermHint() : null,
            // 分栏形态下左栏要高亮「右栏正开着的那一封」（需求一：整行淡底色
            // + 最左那条竖条）。漏掉这一句，左栏每一行的 `selected` 都恒为
            // false，选中态永远不出现 —— 而它**不报错**，只是点了没反应。
            selected: widget.selected,
            onOpen: _open,
            // 接上多选（复选框、长按、Shift/Ctrl、右键批量）。
            multiSelect: multiSelect,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        // 标题 + 36 高的那颗按钮（`_ListHeader` 是两行）—— 默认的 56 会把它
        // 裁掉。
        toolbarHeight: _kListHeaderToolbarHeight,
        title: header,
        actions: actions,
      ),
      body: Column(
        children: <Widget>[
          // 缺 `account:query` 权限不是错误（自建实例的默认角色就没有），
          // 只是一条常驻说明 —— 功能仍然可用，只是看不到其他邮箱。
          if (denied) const _AccountPermHint(),
          Expanded(
            child: MailListView(
              query: query,
              listNode: Routes.aliasOf(widget.profileId),
              emptyHint: emptyHint,
              selected: widget.selected,
              // 这一屏自己拼详情地址（它知道 `folder` / `unread` / 节点，
              // 见 [_open]），不用 `MailListView` 那条兜底。
              onOpen: _open,
              multiSelect: multiSelect,
            ),
          ),
        ],
      ),
    );
  }

  /// 把这一屏的「写邮件从哪个邮箱发」发布给外壳那颗 FAB。
  ///
  /// 判据搬到了 [composePreselectOf]（可脱离 `BuildContext` 测）——
  /// 这里只负责**什么时候说**与**什么时候收回**：
  ///
  /// - **说什么**：收件方向、非「只看未读」（[composePreselectCanSpeak]）
  ///   才有话说；已发送 / 未读邮件那两屏说不清「从哪个邮箱发」，
  ///   与改造前那一颗 FAB 的判据一致。
  /// - **什么时候说**：这一页在自己这一支里是**栈顶**时才说
  ///   （`ModalRoute.isCurrent`）。压在它下面的那一页（比如列表上面顶着一封
  ///   详情）不该替用户说话。
  ///
  /// 刻意**不看** `TickerMode`：被 `IndexedStack` 藏起来的那一支本来就不会
  /// 重建（切分支只换 offstage 标记），所以拿它当开关只会帮倒忙 ——
  /// 藏起来的那一屏一旦因为收到新邮件而重建，就会把可见那一屏刚发布的结论
  /// 抹掉。
  ///
  /// 写入放在帧后：build 期间改 provider 会触发断言。
  void _publishComposePreselect(MailboxSelection selection) {
    final canSpeak = composePreselectCanSpeak(widget.folder, widget.unreadOnly);
    final value = canSpeak
        ? composePreselectOf(
            selection: selection,
            profileId: widget.profileId,
            // 钉住时预选那个邮箱，**压过** prefs 推出来的结论 —— 用户明明
            // 正看着 a@x.com 的收件箱，写信却从 b@x.com 发是错的。
            pinnedAccountId: widget.accountId,
          )
        : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      ref
          .read(composePreselectProvider.notifier)
          .publish(_preselectOwner, value);
    });
  }

  String _title(AppLocalizations l10n) => switch (widget.folder) {
        MailFolder.send => l10n.sent,
        MailFolder.starred => l10n.starred,
        _ when widget.unreadOnly => l10n.unreadMail,
        _ => l10n.inbox,
      };

  /// 标题下面那一行：**这一屏在看哪一个邮箱**。
  ///
  /// 只在钉住时还用它 —— 实例级那一屏的同一行已经被 [MailboxFilterHeaderButton]
  /// 那颗按钮替掉了（它把结论写在脸上，还顺手当入口）。
  ///
  /// **不能 `ref.watch`**：本方法是在 `build` 里当参数直接调的，而
  /// `profileByIdProvider` 会随实例表变化重建 —— 在那个位置 watch 会让这一页
  /// 在一次 build 里被标成依赖、下次实例表一变就整页重建，而这里要的只是
  /// 「当前这一帧显示什么名字」，`read` 就够了。
  String _pinnedLabel(MailListQuery query, List<MailboxAccount> mailboxes) {
    final l10n = AppLocalizations.of(context);
    // 钉住的查询恒是「一个邮箱」。取不到（理论上到不了）时给一句总的。
    if (query.mailboxes.isEmpty) return l10n.allMailboxes;
    final box = query.mailboxes.first;
    if (box.accountId == kAllMailboxes) {
      final profile = ref.read(profileByIdProvider(box.profileId));
      return '${profile?.displayName ?? box.profileId} · ${l10n.allMailboxes}';
    }
    // 邮箱在 Web 端被删了、本地表还没同步到时**不自动跳回**实例级
    // （那会把用户从一条合法深链里弹出去），只在这里退化显示原始 id。
    return mailboxes.byId(box.accountId)?.email ?? '${box.accountId}';
  }

  /// 点开一行：改地址，不 push。
  ///
  /// 两个形态走同一条：路径段写「这一屏的节点」（`all` 或实例），这封邮件
  /// 真正属于谁走 `profile=`，`folder` / `unread` / **`account`** 原样带上 ——
  /// 见 [detailRouteOf] 的注释。窄屏（<1024）由路由的 redirect 决定是不是
  /// 折成右栏；到不了那一步时就是 push 一整页详情。
  void _open(MailRow row) {
    context.go(
      detailRouteOf(
        node: Routes.aliasOf(widget.profileId),
        profileId: row.profileId,
        emailId: row.emailId,
        folder: widget.folder,
        unreadOnly: widget.unreadOnly,
        // 漏了它，用户在「某个邮箱的收件箱」里点开一封再返回就会掉回实例级：
        // 筛选按钮重新冒出来、列表悄悄变宽，而用户看不出发生了什么。
        accountId: widget.accountId,
      ),
    );
  }

  /// 关掉右栏：回到「这一屏的列表」。
  ///
  /// 聚合节点（`/mail/all`）以前折不出 `?sel=`，所以这里对 null 直接返回；
  /// 现在聚合列表在宽屏下**也有右栏**（见 `_paneRedirectForDetail`），那行
  /// 会让关闭按钮点了没反应，一并收进 `Routes.mailOf`。
  ///
  /// `accountId` 同样不能漏：它是「钉住」这条标志本身，漏了就是 R2 那个
  /// 「关掉右栏之后筛选按钮又冒出来、列表变宽」。
  void _clearSelection() {
    context.go(
      Routes.mailOf(
        Routes.aliasOf(widget.profileId),
        accountId: widget.accountId,
        folder: widget.folder,
        unreadOnly: widget.unreadOnly,
      ),
    );
  }
}

/// 窄屏 `AppBar` 的高度。
///
/// 默认的 56 装不下「标题 + 36 高的筛选按钮」两行，会把按钮裁掉一截
/// （`AppBar` 不给 `title` 撑高自己）。72 = 标题行 24 + 按钮 36 + 上下各 6。
const double _kListHeaderToolbarHeight = 72;

/// 列表头：标题 + 标题下面那一样东西。
///
/// 下面那一格是个 [Widget] 而不是 `String`：实例级形态放的是那颗
/// 「已选 x 个邮箱」按钮（它同时是筛选入口与状态回显），钉住的形态放的才是
/// 一行静态文本。做成两种形态共用一个参数，是为了让两种形态的**高度与
/// 内边距**天然一致 —— 分成两个 widget 的话，切换形态时列表头会跳一下。
class _ListHeader extends StatelessWidget {
  const _ListHeader({required this.title, required this.below});

  final String title;
  final Widget below;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        // 按钮高 36，比原来那行 labelSmall 高一些；给一个下限让两种形态
        // 在切换时不会跳。
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Align(alignment: Alignment.centerLeft, child: below),
        ),
      ],
    );
  }
}

/// 钉住某个邮箱时，标题下面那一行静态地址。
///
/// 与那颗按钮同一个高度（36），于是从「实例级」切到「钉住」时列表头不会跳。
class _PinnedMailboxLabel extends StatelessWidget {
  const _PinnedMailboxLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: label,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 缺 `account:query` 权限时的提示条。
class _AccountPermHint extends StatelessWidget {
  const _AccountPermHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline, size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              AppLocalizations.of(context).needAccountPerm,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
