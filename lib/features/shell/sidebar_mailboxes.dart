import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/instance_colors.dart';
import '../../data/models/mailbox_account.dart';
import '../../data/models/profile.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/mail_providers.dart';
import '../../providers/mailbox_totals_probe.dart';
import '../../providers/profile_providers.dart';
import '../../providers/settings_providers.dart';
import '../../providers/sync_providers.dart';
import '../../router.dart';
import '../home/home_nav.dart';
import '../mail_list/mailbox_filter.dart';
import '../mail_list/mailbox_scope.dart';
import 'nav_sidebar.dart';
import 'sidebar_counts.dart';

/// 「收件箱」下面那一组：按实例分组的邮箱下级菜单。
///
/// **宽屏侧栏与窄屏主屏网格共用这一份** —— 与 `HomeEntries` 顶上那段注释
/// 讲的是同一件事：两个形态各写一遍，加一台实例只改一处，另一处那条就悄悄
/// 没有，而且没人会发现（谁也不会同时开着两种宽度对点一遍）。
///
/// 它列出的是「每个实例的每一个邮箱」，规则与筛选面板**一模一样** ——
/// 都走 [boxesOfProfile]，所以缺 `account:query` 权限的实例在两边都退化成一个
/// 「全部邮箱」合并项，而不是在这边整体消失。
///
/// 点一行 = 去 `Routes.mailOf(profileId, accountId: …)`，也就是**钉住**这个
/// 邮箱（见 [pinnedMailboxOf]）。刻意**不**写 `PrefsStore.mailboxFilter`：
/// 那是跨实例的全局偏好，写邮件页的预选与别的列表都会读到它，点一下侧栏就
/// 把它改掉等于顺手改了一个与这次点击无关的设置，而且没有撤销。
///
/// **订阅数**：每一行右侧那一格是 `mailboxUnreadProvider` +
/// `mailboxTotalProvider` 的两个订阅，于是展开时有 N 个邮箱就有 2N 条。收起时
/// 整棵子树**根本不构建**（调用方 `if (expanded)`），所以只有展开时才有这个开销。
///
/// 底下已经是**一条**按邮箱分组的 `groupBy` 查询（`MailDao.watchUnreadByMailbox`，
/// 与 `watchUnreadByProfile` 同款），写一次库只重建一次 —— 那 N 个订阅共享它，
/// 不是 N 条查询。原来这里是每个邮箱一条 `Future`，而且算完就不再失效：
/// 读掉一封信之后侧栏的数字会一直停在旧的。
class SidebarMailboxTree extends ConsumerWidget {
  const SidebarMailboxTree({
    super.key,
    required this.uri,
    this.push = false,
    this.masterExpanded = true,
  });

  /// **整条当前地址**。高亮（哪一行是钉住的）与「点的是不是已经在看的那一个」
  /// 都从它算。
  ///
  /// 由调用方传进来而不是自己 `GoRouterState.of(context)`：两个形态各自
  /// 拿地址的方式不同（外壳那一层已经读好了整条 `uri`；窄屏主屏那一页也要
  /// 用它算 `openHomeEntry` 的 `current`），在这里再查一遍等于同一份结论
  /// 有两个来路 —— 而它们必须**是同一个**，否则「高亮的那一行」和「点一下
  /// 会发生什么」可能建在两个不同的地址上。
  final Uri uri;

  /// 窄屏主屏网格传 `true`（那一屏没有别的出口，压上去才有返回箭头），
  /// 宽屏侧栏一律 `false`（它自己就是一级导航，`push` 会叠出一摞退不回去的
  /// 页面）—— 与 `openHomeEntry` 的 `push` 参数同一个道理。
  final bool push;

  /// 一括开关（`sidebarMailboxesExpandedProvider`）：整棵子树展不展开。
  ///
  /// 由调用方传进来而不是自己 `watch`，只有一个理由：**窄屏这一屏上没有
  /// 那颗箭头**（那是侧栏「收件箱」那一项右侧的 `IconButton`），所以窄屏
  /// 必须无视它 —— 否则用户上次在宽屏上把整组收起来，切到窄屏会发现
  /// 「某个邮箱的收件箱」这条路径**根本走不通**（窄屏除了这一组没有别的
  /// 入口）。
  ///
  /// 宽屏传 `ref.watch(sidebarMailboxesExpandedProvider)`，窄屏用默认的
  /// `true`。默认值取 `true` 而不是 `false`，是为了让「忘了传」时退化到
  /// 「看得见」而不是「整组消失」。
  final bool masterExpanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(activeProfilesProvider);
    // 一台实例都没登录：整组不渲染。上面那个展开箭头由调用方一起藏掉
    // （一个什么都展不开的箭头比没有箭头更糟）。
    if (profiles.isEmpty) return const SizedBox.shrink();

    final byProfile = ref.watch(allMailboxesByProfileProvider);
    final pinned = pinnedMailboxOf(uri);
    // 地址停在哪台实例的实例级列表上（`/mail/<实例>`，不带 `account`）。
    final node = instanceNodeOf(uri);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final profile in profiles)
          _ProfileGroup(
            profile: profile,
            uri: uri,
            push: push,
            masterExpanded: masterExpanded,
            // forced：地址正落在这台实例上（实例级列表，或它的某个邮箱，
            // 或它们的详情页）。两条判据取或 —— 一条认「就在这台实例上」，
            // 一条认「钉在它的某个邮箱上」。
            forced: node == profile.id || pinned?.profileId == profile.id,
            selected: node == profile.id || pinned?.profileId == profile.id,
            boxes: boxesOfProfile(
              profile.id,
              byProfile[profile.id] ?? const <MailboxAccount>[],
            ),
            byProfile: byProfile,
          ),
      ],
    );
  }
}

/// 一台实例：**可点的实例行** + 它下面那组邮箱。
///
/// 拆成一个自己的 `ConsumerStatefulWidget`（而不是接着用那个 `for` 循环里
/// 的裸 widget）有两点理由：
///
/// - **展开态是每台一份的**（`sidebarInstanceExpansionProvider` 里那个
///   「收起了哪些」的集合）。放在一个 widget 里，那一台的重建不会牵动别台。
/// - 后面接总数探测时，触发点自然是这个 state 的 `initState` /
///   `didUpdateWidget`（分组在屏幕上是常驻的，不会因为 drift 写入引起的
///   重建而重复跑 `initState`）。
class _ProfileGroup extends ConsumerStatefulWidget {
  const _ProfileGroup({
    required this.profile,
    required this.uri,
    required this.push,
    required this.masterExpanded,
    required this.forced,
    required this.selected,
    required this.boxes,
    required this.byProfile,
  });

  final Profile profile;
  final Uri uri;
  final bool push;
  final bool masterExpanded;

  /// 地址落在这一台上（见 [instanceMailboxesExpanded]）。
  final bool forced;

  /// 实例行与它下面的子行要不要高亮。
  final bool selected;

  final List<MailboxFilter> boxes;
  final Map<String, List<MailboxAccount>> byProfile;

  @override
  ConsumerState<_ProfileGroup> createState() => _ProfileGroupState();
}

class _ProfileGroupState extends ConsumerState<_ProfileGroup> {
  @override
  void initState() {
    super.initState();
    _scheduleProbe();
  }

  @override
  void didUpdateWidget(_ProfileGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只在这几样**真的**变了时才重新触发：
    // - 实例换了（同一个 State 被复用到另一台上，理论上不该发生，但真发生时
    //   不重探就是「这一台的数字一直是上一台的」）；
    // - 整组的开关变了，或者地址落点变了（两者都会改变「这一台展不展开」）；
    // - 邮箱列表本身变了（权限补齐、新建邮箱之后多出来一行）。
    //
    // 不这么做的话，drift 每次因写入而重建整棵树都会重跑一遍 ensure ——
    // 它内部有 TTL 与在飞去重兜着（不会真的重复发请求），但那些判断本身
    // 是要读库的，白白多一遍。
    if (oldWidget.profile.id != widget.profile.id ||
        oldWidget.masterExpanded != widget.masterExpanded ||
        oldWidget.forced != widget.forced ||
        !_sameBoxes(oldWidget.boxes, widget.boxes)) {
      _scheduleProbe();
    }
  }

  static bool _sameBoxes(List<MailboxFilter> a, List<MailboxFilter> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 帧后触发总数探测（只探**展开着的**这一台）。
  ///
  /// `initState` / `didUpdateWidget` 而不是 `build`：本仓库踩过两次
  /// 「build 期间改 provider」的断言（`mail_list_screen.dart` 两处注释）。
  /// 探测本身会写库，写库会让 `watchSyncStatesOfProfile` 重发、又重建这棵
  /// 树 —— 在 build 里做就是「重建时改状态」，那是同一个坑的另一种形状。
  ///
  /// 展开态在这一刻**重新读一次**（不是拿 build 里那个局部变量）：回调跑在
  /// 帧后，而这一帧里用户可能刚点了箭头。探测内部另有 TTL 与在飞去重，
  /// 所以「刚好收了又刚好展开」这种边角最多是多跑一遍判空，不会多发请求。
  void _scheduleProbe() {
    final profile = widget.profile;
    final boxes = widget.boxes;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 收起时不探：那些数字没人看得见，而探测是有代价的真请求。
      // `widget.forced` 与 `instanceMailboxesExpanded` 是同一条判据的
      // 两个来路，这里直接读展开态（而不是只看 forced）。
      if (!instanceMailboxesExpanded(
        master: widget.masterExpanded,
        forced: widget.forced,
        collapsed: ref.read(sidebarInstanceExpansionProvider),
        profileId: profile.id,
      )) {
        return;
      }
      ref.read(mailboxTotalsProbeProvider).ensure(profile: profile, boxes: boxes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final profile = widget.profile;
    final expanded = instanceMailboxesExpanded(
      master: widget.masterExpanded,
      forced: widget.forced,
      collapsed: ref.watch(sidebarInstanceExpansionProvider),
      profileId: profile.id,
    );
    final pinned = pinnedMailboxOf(widget.uri);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SidebarMailboxRow(
          // 实例名原来只是一行灰字（点不动）—— 现在与子行同一套控件，
          // 于是缩进 / 高度 / 圆角全都自动对齐，几何不会走两个样。
          emphasized: true,
          icon: Icons.dns_outlined,
          color: InstanceColors.of(profile.colorIndex),
          label: profile.displayName,
          selected: widget.selected,
          onTap: () => _openInstance(context, ref, profile),
          counts: SidebarInstanceCounts(profileId: profile.id),
          trailing: IconButton(
            // `IconButton` 而不是 `GestureDetector`：它天然在手势竞技场里
            // 赢过外层那个 `HitTestBehavior.opaque` 的 `GestureDetector`
            // （`NavSidebarItem.trailing` 就是这么做的），点箭头不会顺带
            // 触发导航。
            tooltip: l10n.toggleInstanceMailboxList,
            onPressed: () => ref
                .read(sidebarInstanceExpansionProvider.notifier)
                .toggle(profile.id),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          ),
        ),
        if (expanded)
          for (final box in widget.boxes)
            SidebarMailboxRow(
              label: mailboxLabelOf(
                box,
                widget.byProfile,
                allMailboxesLabel: l10n.allMailboxes,
              ),
              icon: box.accountId == kAllMailboxes
                  ? Icons.all_inbox
                  : Icons.mail_outline,
              color: InstanceColors.of(profile.colorIndex),
              selected: pinned ==
                  (profileId: box.profileId, accountId: box.accountId),
              onTap: () => _open(context, ref, box, pinned),
              counts: SidebarMailboxCounts(box: box),
            ),
      ],
    );
  }

  /// 去这一台实例的**实例级列表**（`/mail/<实例>`，不带 `account`）。
  ///
  /// 不带 `account` 是这一行的全部语义：「这台实例的所有收件箱」。
  /// 带上某一个邮箱就退化成子行那一件事了（见 [pinnedMailboxOf]）。
  ///
  /// 「已经在上面了」走 [instanceNavFor]（纯函数，可测）：已经在根上什么都
  /// 不做、停在详情页则退回列表。少了这一步，窄屏 `push` 会再叠一张一模一样
  /// 的列表页，用户眼里就是「点了没反应」。
  void _openInstance(BuildContext context, WidgetRef ref, Profile profile) {
    switch (instanceNavFor(
      widget.uri,
      profileId: profile.id,
      push: widget.push,
    )) {
      case HomeNav.none:
        // 已经在实例级列表的根上 —— 什么都不做，但**不 return**：
        // 下面那句 setActiveProfile 仍然该跑（点当前项 = 「我就要看这台」）。
        break;
      case HomeNav.backToRoot:
      case HomeNav.go:
        context.go(Routes.mailOf(profile.id));
      case HomeNav.push:
        context.push(Routes.mailOf(profile.id));
    }
    // 与邮箱行一致：让它优先同步、并马上拉一轮。
    ref.read(syncControllerProvider.notifier).setActiveProfile(profile.id);
  }

  /// 去这一个邮箱的收件箱。
  ///
  /// 目的地固定是**收件方向、不带未读筛选**（`folder=receive`）：这一组的
  /// 语义就是「某个邮箱的收件箱」，把别的屏的 folder 带过来会让「点侧栏
  /// 去某个邮箱」落在一个用户没预期的地方（比如「已发送」）。
  void _open(
    BuildContext context,
    WidgetRef ref,
    MailboxFilter box,
    ({String profileId, int accountId})? pinned,
  ) {
    final target = Routes.mailOf(box.profileId, accountId: box.accountId);
    if (widget.push) {
      // 已经钉在同一个邮箱上：`push` 会再叠一张一模一样的列表页，
      // 而它在用户眼里就是「点了没反应」（返回一次还在原地）。
      if (pinned == (profileId: box.profileId, accountId: box.accountId)) return;
      context.push(target);
    } else {
      context.go(target);
    }
    // 钉住等于「在看这一台实例」：让它优先同步、并马上拉一轮。
    ref.read(syncControllerProvider.notifier).setActiveProfile(box.profileId);
  }
}

/// 下级菜单里的一行：图标（实例色）+ 标签 +（右侧）数量 +（可选）箭头。
///
/// 高 32、比一级项（40）矮一档：层级靠「更窄的行 + 缩进 + 图标」表达，
/// 高度也一样矮下去才看得出它是二级。
///
/// **原来这里是实例色圆点，现在换成邮箱图标**：圆点与末位的未读数、以及
/// 一级项那些图标放在一起，只是一颗说不出是什么的点；换成图标之后这一行
/// 与「收件箱 / 已发送」是同一套视觉语言。实例色没丢 —— 它是图标的颜色。
///
/// **实例行也用它**（[emphasized] = true）。另写一个「实例行」的兄弟类看着
/// 更直白，代价是 `_iconSize` / `_iconGap` / 左缩进 24 / 内边距 10 / 高度 32 /
/// `AnimatedContainer` 时长这一整套常量要抄第二遍 —— 而
/// `sidebar_mailboxes_test.dart` 里那条几何用例钉的正是「两种行的标签从同一个
/// x 开始」。抄一遍的那一刻，那条用例就只在抄写时对了。
class SidebarMailboxRow extends StatefulWidget {
  const SidebarMailboxRow({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    this.icon = Icons.alternate_email,
    this.counts,
    this.trailing,
    this.emphasized = false,
  });

  final String label;

  /// 实例色标（`InstanceColors.of(profile.colorIndex)`）—— 现在染在图标的
  /// 颜色上，不再是单独一颗圆点。
  final Color color;

  /// 地址高亮跟着**当前钉住的那个邮箱**走（`pinnedMailboxOf`），不是跟着
  /// 用户点过谁。否则从详情页按返回之后，侧栏会停在一个已经不在的落点上。
  final bool selected;

  final VoidCallback onTap;

  /// 行首的图标。合并项（[kAllMailboxes]）传 `Icons.all_inbox` 之类的
  /// 「一组邮箱」的图标 —— 它与一个具体邮箱不是一回事（见 [build]）。
  final IconData icon;

  /// 右侧那一格（未读 / 总数那一对，或实例行的合计）。合并项
  /// （`accountId == kAllMailboxes`）传 `null` —— 「这个邮箱的计数」对合并项
  /// 没有意义；实例行的合计则另有一条口径（见 `SidebarMailboxTree`）。
  ///
  /// 原来叫 `unread`：那一格现在装的不只是未读（`3/12` 是两件事），
  /// 名字留着会让调用方以为它是个数。
  final Widget? counts;

  /// [counts] 之后再放一样东西。实例行用它放展开箭头。
  ///
  /// 与 [counts] 分开传而不是挤进同一格：实例行**两样都有**（合计 + 箭头），
  /// 塞在一个槽里就得让调用方自己拼一行 `Row`。`NavSidebarItem.trailing`
  /// 是同一种设计。
  final Widget? trailing;

  /// 实例行（分组标题）那一行：字重与字色都重一档。
  ///
  /// 这是它与子行之间**唯一的**视觉差别 —— 缩进、高度、圆角全部共用，
  /// 所以「这一行是标题」只能靠字重说（子行里也有选中/未选中的字重变化，
  /// 但那是 `w600/w400`，这里是 `w600` 打底）。
  final bool emphasized;

  @override
  State<SidebarMailboxRow> createState() => _SidebarMailboxRowState();
}

class _SidebarMailboxRowState extends State<SidebarMailboxRow> {
  bool _hovered = false;

  /// 行首图标与标签之间那道间隔。
  ///
  /// 图标是 16 宽、圆点时是 8：写死 `SizedBox(width: 10)` 的话，「全部邮箱」
  /// 这一行（`all_inbox`）会比它下面那些邮箱行多缩进 8px —— 同一个组里
  /// 两种缩进，看着像没对齐。
  static const double _iconSize = 16;
  static const double _iconGap = 8;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selected;
    final background = selected
        ? scheme.secondaryContainer
        : (_hovered
            ? scheme.onSurfaceVariant.withValues(alpha: 0.08)
            : Colors.transparent);
    final foreground = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    return Padding(
      // 左边多缩进 16（一级项是 8）：二级靠缩进与一级拉开层次。
      padding: const EdgeInsets.fromLTRB(24, 1, 8, 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                // 图标用**实例色**（选中时改用前景色）：圆点原来的那份
                // 「一眼认出来自哪台实例」的信息全在这一格上。
                SizedBox(
                  width: _iconSize,
                  height: _iconSize,
                  child: Icon(
                    widget.icon,
                    size: _iconSize,
                    color: selected ? foreground : widget.color,
                  ),
                ),
                const SizedBox(width: _iconGap),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: foreground,
                          fontWeight: selected || widget.emphasized
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                  ),
                ),
                if (widget.counts != null) widget.counts!,
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 下级菜单一行右侧那一格：**未读 / 总数**（`3/12`）。
///
/// 复用一级项那颗 [SidebarCountPill]，于是两条线上的数字长得一模一样 ——
/// 另写一份的话，同一个未读数在侧栏上下两处会不一样大。
///
/// **两处不显示**：
/// - 合并项（`accountId == kAllMailboxes`）——「这个实例的全部邮箱」没有
///   「这一个邮箱的未读数」可言（与 `MailboxUnreadLabel` 的早退一致）；
/// - 整格都为空 —— 未读 0 且总数未知/为 0。`SidebarCountPill` 自己**不做
///   抑制**（发件箱那个「0 也要显示」的例外由调用方用 `alwaysShowCount`
///   表达，见 `NavSidebarItem`），所以这里的门必须自己把住：几十个邮箱每个
///   都挂一个灰色的 `0` 会满屏噪声。
///
/// 文案（五个分支）在 [formatMailboxCounts]，纯函数、单独可测。
///
/// 读屏那一层要说人话：`3/12` 这种纯符号是读不出来的（`Semantics` 用
/// `mailboxCountsLabel`；总数未知时退回现成的 `unreadCount`）。
class SidebarMailboxCounts extends ConsumerWidget {
  const SidebarMailboxCounts({super.key, required this.box});

  final MailboxFilter box;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (box.accountId == kAllMailboxes) return const SizedBox.shrink();

    final unread = ref.watch(
      mailboxUnreadProvider(
        (profileId: box.profileId, accountId: box.accountId),
      ),
    );
    final total = ref.watch(
      mailboxTotalProvider(
        (profileId: box.profileId, accountId: box.accountId),
      ),
    );
    final l10n = AppLocalizations.of(context);
    final text = formatMailboxCounts(
      unread: unread,
      total: total,
      unknown: l10n.mailboxCountUnknown,
    );
    if (text == null) return const SizedBox.shrink();

    return Semantics(
      label: total == null
          ? l10n.unreadCount(unread)
          : l10n.mailboxCountsLabel(unread, total),
      // 里面的 `Text` 已经是符号了，别让读屏把它再念一遍（`3/12` 会被读成
      // 「三斜杠十二」）。`excludeSemantics` 让上面那句 label 成为唯一来路。
      excludeSemantics: true,
      child: SidebarCountPill(
        text: text,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 实例行右侧那一格：**这一台实例的合计**（未读 / 总数）。
///
/// 与 [SidebarMailboxCounts] 分成两个类而不是一个带开关的：
/// 两者读的是**不同口径**的两对数（分子：`watchUnreadByProfile` 走实例分组
/// 聚合、`watchUnreadByMailbox` 走逐邮箱分组；分母：`all:type:0` 那一行、
/// 某个邮箱那一行）。共用一个 widget 就得在里面按 `accountId` 分叉，而
/// 「合并项」这个早退规则完全不适用实例行 —— 那个分叉迟早会把两套口径混起来。
///
/// 合计**不显示 `0`**（未读 0 且总数为 0 时整格为空），与子行同一套抑制。
class SidebarInstanceCounts extends ConsumerWidget {
  const SidebarInstanceCounts({super.key, required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(profileUnreadProvider(profileId));
    final total = ref.watch(instanceTotalProvider(profileId));
    final l10n = AppLocalizations.of(context);
    final text = formatMailboxCounts(
      unread: unread,
      total: total,
      unknown: l10n.mailboxCountUnknown,
    );
    if (text == null) return const SizedBox.shrink();

    return Semantics(
      label: total == null
          ? l10n.unreadCount(unread)
          : l10n.mailboxCountsLabel(unread, total),
      excludeSemantics: true,
      child: SidebarCountPill(
        text: text,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
