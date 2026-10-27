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
    required this.selected,
    required this.boxes,
    required this.byProfile,
  });

  final Profile profile;
  final Uri uri;
  final bool push;
  final bool masterExpanded;

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
    // - 整组的开关变了（它决定这一台展不展开）；
    // - 邮箱列表本身变了（权限补齐、新建邮箱之后多出来一行）。
    //
    // 不这么做的话，drift 每次因写入而重建整棵树都会重跑一遍 ensure ——
    // 它内部有 TTL 与在飞去重兜着（不会真的重复发请求），但那些判断本身
    // 是要读库的，白白多一遍。
    if (oldWidget.profile.id != widget.profile.id ||
        oldWidget.masterExpanded != widget.masterExpanded ||
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
      if (!instanceMailboxesExpanded(
        master: widget.masterExpanded,
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
      collapsed: ref.watch(sidebarInstanceExpansionProvider),
      profileId: profile.id,
    );
    final pinned = pinnedMailboxOf(widget.uri);

    // 用户把这一台从「收起」拨到「展开」时**补探一次**总数。
    //
    // 为什么需要：挂载时它如果是收起的（prefs 里留着
    // `cm_sidebar_collapsed_instances`），`_scheduleProbe` 那一帧会直接
    // return；而展开态是 provider 状态、不改变任何 widget 入参，所以
    // `didUpdateWidget` 也不会被触发。不补的话，这一台各邮箱的浅色总数
    // 要等下一次重启 / 树重建才出现（未读徽章走本地库，不受影响）。
    //
    // 旧实现在这条路上是「碰巧」能探的：地址落到这台实例时 `forced` 翻转
    // 会触发 `didUpdateWidget` —— 那条路径随 `forced` 一起删掉了。
    ref.listen<bool>(
      sidebarInstanceExpansionProvider.select(
        (collapsed) => instanceMailboxesExpanded(
          master: widget.masterExpanded,
          collapsed: collapsed,
          profileId: profile.id,
        ),
      ),
      (previous, next) {
        if (next && previous != true) _scheduleProbe();
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _InstanceSidebarRow(
          profile: profile,
          selected: widget.selected,
          expanded: expanded,
          onTap: () => _openInstance(context, ref, profile),
          onToggle: () => ref
              .read(sidebarInstanceExpansionProvider.notifier)
              .toggle(profile.id),
        ),
        if (expanded)
          for (final box in widget.boxes)
            _MailboxSidebarRow(
              box: box,
              colorIndex: profile.colorIndex,
              label: mailboxLabelOf(
                box,
                widget.byProfile,
                allMailboxesLabel: l10n.allMailboxes,
              ),
              selected: pinned ==
                  (profileId: box.profileId, accountId: box.accountId),
              onTap: () => _open(context, ref, box, pinned),
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

/// 下级菜单里的一行：图标（实例色）+ 标签 + 浅色总数 + 红色未读徽章 +（可选）箭头。
///
/// **实例行与邮箱行共用这一个控件**（[emphasized] 区分），几何差别全在下面
/// 这几处常量里：实例行更浅的缩进（16 vs 36）、高一点（36 vs 30）、图标大
/// 一号（18 vs 16）。两条线各写一份的代价是这些数要抄第二遍，而
/// `sidebar_mailboxes_test.dart` 里那几条用例钉的正是这些几何。
///
/// 两种行的视觉分工（原来只有字重一项，用户反馈「实例名与它下面的邮箱太像」）：
/// - 实例行 = **组头**：标签用正文色 + `w700`，图标 18；
/// - 邮箱行 = **组内的一项**：标签退到 `onSurfaceVariant` + `w400`，图标 16，
///   并且比实例行多缩进 20（标签起点差 18）—— 层级先靠缩进和颜色说，
///   字重只是第三重。
///
/// **原来行首是实例色圆点，现在是图标**：圆点与末位的未读数、以及一级项那些
/// 图标放在一起，只是一颗说不出是什么的点；换成图标之后这一行与「收件箱 /
/// 已发送」是同一套视觉语言。实例色没丢 —— 它是图标的颜色。
class SidebarMailboxRow extends StatefulWidget {
  const SidebarMailboxRow({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    this.icon = Icons.alternate_email,
    this.total,
    this.unread = 0,
    this.trailing,
    this.emphasized = false,
  });

  final String label;

  /// 实例色标（`InstanceColors.of(profile.colorIndex)`）—— 染在图标的颜色上。
  final Color color;

  /// 地址高亮跟着**当前钉住的那个邮箱**走（`pinnedMailboxOf`），不是跟着
  /// 用户点过谁。否则从详情页按返回之后，侧栏会停在一个已经不在的落点上。
  final bool selected;

  final VoidCallback onTap;

  /// 行首的图标。合并项（[kAllMailboxes]）传 `Icons.all_inbox` 之类的
  /// 「一组邮箱」的图标 —— 它与一个具体邮箱不是一回事。
  final IconData icon;

  /// 名字后面紧跟的**浅色总数**（服务端说这口邮箱里有多少封）。
  ///
  /// `null` 有且只有一种含义：**不知道**（还没探过），或者这一行是合并项
  /// （「全部邮箱」没有「这一口邮箱的总数」可言）。两种情况都整段不画。
  /// 不会出现「知道但是 0」—— 0 与未知在文案上一样是噪声，见
  /// [formatMailboxTotal]。
  final int? total;

  /// 行最右边那颗**红色徽章**里的未读数。0 不画（红色只留给「有未读」）。
  final int unread;

  /// 徽章之后再放一样东西。实例行用它放展开箭头。
  final Widget? trailing;

  /// 实例行（分组标题）那一行：更靠左、更高、图标更大、字更重、颜色更实。
  ///
  /// 这是它与子行之间的视觉分工，见类注释。**不要**把它降级成「只是字重
  /// 不同」——那正是这次要修的那个「两种行太像」。
  final bool emphasized;

  @override
  State<SidebarMailboxRow> createState() => _SidebarMailboxRowState();
}

class _SidebarMailboxRowState extends State<SidebarMailboxRow> {
  bool _hovered = false;

  /// 行首图标与标签之间那道间隔。
  ///
  /// 图标是 16 / 18 宽：写死一个数的话，「全部邮箱」这一行（`all_inbox`）会
  /// 比它下面那些邮箱行多缩进几 px —— 同一个组里两种缩进，看着像没对齐。
  static const double _iconGap = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final selected = widget.selected;
    final emphasized = widget.emphasized;
    // 组头用正文色（onSurface），组内项退到 onSurfaceVariant：两种行的
    // 「实 / 虚」差别在扫视时比字重更早被看见。
    final foreground = selected
        ? scheme.onSecondaryContainer
        : (emphasized ? scheme.onSurface : scheme.onSurfaceVariant);
    final totalText = formatMailboxTotal(widget.total);
    final unread = widget.unread;
    final iconSize = emphasized ? 18.0 : 16.0;
    // 选中态：**组头的底色比组内项淡一档**。钉住某个邮箱时两行会同时选中
    // （实例行亮是因为「你看的这一封属于这台」），如果两块一样深、字重也
    // 一样，层级就只剩缩进在说 —— 这正是本次要修的那个「两种行太像」。
    final background = selected
        ? (emphasized
            ? scheme.secondaryContainer.withValues(alpha: 0.55)
            : scheme.secondaryContainer)
        : (_hovered
            ? scheme.onSurfaceVariant.withValues(alpha: 0.08)
            : Colors.transparent);

    final labelArea = Row(
      children: <Widget>[
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: foreground,
              fontWeight:
                  selected || emphasized ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
        if (totalText != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
              totalText,
              maxLines: 1,
              // 浅色：比标签再淡一档，扫视时先看到名字与红色徽章，总数
              // 是第二眼的信息。选中状态下同样按前景色淡化（而不是写死
              // onSurfaceVariant），否则选中行里那截数字会与底色糊在一起。
              style: theme.textTheme.labelSmall?.copyWith(
                color: foreground.withValues(alpha: 0.55),
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
      ],
    );

    // 读屏：`3` 与 `12` 两颗数字挨着念是念不出「这是未读、那是总数」的。
    // 合并成一句（`mailboxCountsLabel` / `unreadCount`），并把可视的那几个
    // `Text` 从语义树里摘掉。箭头（[trailing]）在语义区之外，不受影响。
    final countsLabel = _countsSemantics(l10n, unread);
    final labelSemantics = countsLabel == null
        ? labelArea
        : Semantics(
            label: '${widget.label}, $countsLabel',
            excludeSemantics: true,
            child: labelArea,
          );

    return Padding(
      // 组头比组内项少缩进 20（标签起点差 18：图标也小一号）。实例行标签的
      // x 与一级项（`NavSidebarItem`）的标签对齐（都是 52），邮箱行再往里
      // 退一层（70）—— 这是层级的主要来源，不能像原来那样两种行从同一个
      // x 开始。
      padding: emphasized
          ? const EdgeInsets.fromLTRB(16, 1, 8, 1)
          : const EdgeInsets.fromLTRB(36, 0, 8, 0),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: emphasized ? 36 : 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                // 图标用**实例色**（选中时改用前景色）：「一眼认出来自哪台
                // 实例」的信息在这一格上。
                SizedBox(
                  width: iconSize,
                  height: iconSize,
                  child: Icon(
                    widget.icon,
                    size: iconSize,
                    color: selected ? foreground : widget.color,
                  ),
                ),
                const SizedBox(width: _iconGap),
                Expanded(child: labelSemantics),
                // 红色徽章钉在最右（[trailing] 之前）：未读数是这一行唯一
                // 需要「跳出来」的信息，让它永远落在同一列上。
                if (unread > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    // 上面那句合并语义已经把它念过一遍了。
                    child: ExcludeSemantics(
                      child: SidebarUnreadBadge(count: unread),
                    ),
                  ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 这一行右侧数字的读屏文案。`null` = 这一行没有数字可说。
  String? _countsSemantics(AppLocalizations l10n, int unread) {
    final total = widget.total;
    if (total == null) {
      return unread > 0 ? l10n.unreadCount(unread) : null;
    }
    // 可视层在这一格什么都不画（总数 0 + 未读 0）时也别让读屏念一句
    // 「共 0 封，其中 0 封未读」—— 几十个空邮箱会变成一串 0。
    if (total <= 0 && unread <= 0) return null;
    return l10n.mailboxCountsLabel(unread, total);
  }
}

/// 实例行：**一台实例的合计**（总数走名字后面那截浅色文字，未读走最右徽章）。
///
/// 与 [_MailboxSidebarRow] 分成两个类而不是一个带开关的：两者读的是**不同
/// 口径**的两对数（分子：`watchUnreadByProfile` 走实例分组聚合、
/// `watchUnreadByMailbox` 走逐邮箱分组；分母：`all:type:0` 那一行、某个邮箱
/// 那一行）。共用一个 widget 就得在里面按 `accountId` 分叉，而「合并项」
/// 这个早退规则完全不适用实例行 —— 那个分叉迟早会把两套口径混起来。
///
/// 拆成独立的 `ConsumerWidget` 还有一个理由：数字变了只重建这一行，
/// 不牵动 [_ProfileGroup] 那棵子树（那是 `didUpdateWidget` 里总数探测的宿主）。
class _InstanceSidebarRow extends ConsumerWidget {
  const _InstanceSidebarRow({
    required this.profile,
    required this.selected,
    required this.expanded,
    required this.onTap,
    required this.onToggle,
  });

  final Profile profile;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return SidebarMailboxRow(
      emphasized: true,
      icon: Icons.dns_outlined,
      color: InstanceColors.of(profile.colorIndex),
      label: profile.displayName,
      selected: selected,
      onTap: onTap,
      total: ref.watch(instanceTotalProvider(profile.id)),
      unread: ref.watch(profileUnreadProvider(profile.id)),
      trailing: IconButton(
        // `IconButton` 而不是 `GestureDetector`：它天然在手势竞技场里
        // 赢过外层那个 `HitTestBehavior.opaque` 的 `GestureDetector`
        // （`NavSidebarItem.trailing` 就是这么做的），点箭头不会顺带
        // 触发导航。
        tooltip: l10n.toggleInstanceMailboxList,
        onPressed: onToggle,
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 24, height: 24),
        icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
      ),
    );
  }
}

/// 邮箱行：**某一个邮箱**的未读与总数。
///
/// **合并项**（`accountId == kAllMailboxes`，缺 `account:query` 权限时那一行
/// 「全部邮箱」）两侧都不画：那个「邮箱」的计数没有意义 —— 实例行已经把这
/// 台实例的合计说了一遍（与 `MailboxUnreadLabel` 的早退一致）。
class _MailboxSidebarRow extends ConsumerWidget {
  const _MailboxSidebarRow({
    required this.box,
    required this.colorIndex,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final MailboxFilter box;
  final int colorIndex;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final merged = box.accountId == kAllMailboxes;
    final key = (profileId: box.profileId, accountId: box.accountId);
    final unread = merged ? 0 : ref.watch(mailboxUnreadProvider(key));
    final total = merged ? null : ref.watch(mailboxTotalProvider(key));
    return SidebarMailboxRow(
      label: label,
      icon: merged ? Icons.all_inbox : Icons.mail_outline,
      color: InstanceColors.of(colorIndex),
      selected: selected,
      onTap: onTap,
      total: total,
      unread: unread,
    );
  }
}
