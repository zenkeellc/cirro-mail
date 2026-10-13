import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/profile.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/profile_providers.dart';
import '../../providers/sync_providers.dart';
import 'sync_stage.dart';
import 'sync_status_panel.dart';

/// 同步状态：实例级卡片 + 邮件级清单。
///
/// 从弹层升级成页面（spec §2.5 的「面板」）。升级的理由是内容变多了：
/// 原来只有几张实例卡片，现在还要放一份两档的邮件清单和一个手动补拉的状态。
/// 弹层的高度是屏幕的一半左右，一份长清单塞进去就只剩一条缝。
///
/// 两个 tab 的分法：
/// - **待同步**（默认）：`pendingBody` + `pendingAttachment`，含正在飞的那些
///   —— 「正在同步」在它下面，比单开一档更好用：用户关心的是「还有没有没完的」；
/// - **已同步**：最近若干封同步完的。
///
/// 实例卡片在**两个 tab 之上**（不随 tab 变）：它回答的是「同步还活着吗」，
/// 而这件事跟用户正看哪一档无关。
///
/// **顶层路由**（`/sync`），不在 shell 分支里 —— 与写邮件页同一条理由：
/// 它是「看一眼就走」的页面，放进分支就会永远保活，而它下面的清单是几条
/// 常驻的 drift 订阅。
class SyncStatusScreen extends ConsumerStatefulWidget {
  const SyncStatusScreen({super.key});

  @override
  ConsumerState<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends ConsumerState<SyncStatusScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  /// 「立即全部同步」正在跑。
  ///
  /// 不用 `manualSyncProvider` 的 `state != null` 代替它：那个状态是**逐封**
  /// 变化的（批量里每一封都会把它摆一次），中途会回到 null；用它当按钮的
  /// 禁用手据，按钮会在两封之间闪一下可点，连点就会插进第二批。
  bool _batchRunning = false;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 用 `syncCandidates` 而不是 `activeProfiles`：前者**含**被标了
    // 「需重登」的那些，而在这个页面上恰恰是它们最需要被看见
    // （`syncOverviewProvider` 用的是同一个集合，两边口径必须一致 ——
    // 否则要重登的实例有摘要却渲染不出卡片，用户根本不知道该点什么）。
    final profiles = ref.watch(syncCandidatesProvider);
    final overview =
        ref.watch(syncOverviewProvider).value ?? const <SyncOverview>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.syncStatusTitle),
        actions: <Widget>[
          TextButton.icon(
            onPressed: _batchRunning ? null : () => _syncAll(context),
            icon: _batchRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync, size: 18),
            label: Text(l10n.syncAllNow),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: <Widget>[
            Tab(text: l10n.syncStagePending),
            Tab(text: l10n.syncStageSynced),
          ],
        ),
      ),
      body: profiles.isEmpty
          ? Center(child: Text(l10n.noMailbox))
          : Column(
              children: <Widget>[
                // 实例卡片：一台实例一条，横向铺开（不套 Card，见
                // `SyncInstanceCard` 的注释）。列表本身可滚动 —— 实例多了
                // （或者窗口压扁了）不能把这部分撑破。
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView(
                    shrinkWrap: true,
                    children: <Widget>[
                      for (final profile in profiles)
                        if (_overviewOf(overview, profile.id) case final o?)
                          SyncInstanceCard(overview: o),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: <Widget>[
                      // 两个 tab 都是「全部实例的清单拼起来」：用户在这个页面
                      // 上问的是「还有哪些没同步好」，而不是「A 实例怎么样」。
                      // 实例的分别由每行左边那个色点和实例名来表达。
                      _MailStageList(profiles: profiles, synced: false),
                      _MailStageList(profiles: profiles, synced: true),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  SyncOverview? _overviewOf(List<SyncOverview> rows, String profileId) {
    for (final row in rows) {
      if (row.profileId == profileId) return row;
    }
    return null;
  }

  /// 「立即全部同步」。
  ///
  /// 走的是**逐封补齐**（`ManualSyncController.syncAll`），不是实例卡片上
  /// 那个 `refreshNow`。两者的区别见 `syncAll` 的注释：`refreshNow` →
  /// `syncOnce` 只做增量元数据 + 每轮 ≤20 封的正文回填，**从不下载附件**，
  /// 于是这个页面摆着一份「待同步」清单、按下按钮之后清单几乎没动 ——
  /// 这就是「点击同步不会执行这些邮件的同步」的那个问题。
  Future<void> _syncAll(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    // 按钮上立刻反映「在跑」：这一趟可能要几分钟（逐封、每封都会打请求）。
    setState(() => _batchRunning = true);
    try {
      final result =
          await ref.read(manualSyncProvider.notifier).syncAll();
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(content: Text(_batchSummary(l10n, result))),
      );
    } finally {
      if (mounted) setState(() => _batchRunning = false);
    }
  }

  /// 补完之后那句话。**空清单也要说** —— 按了按钮什么都没发生，用户第一个
  /// 念头是「坏了」，而实际结论是「已经全都同步好了」。
  String _batchSummary(AppLocalizations l10n, SyncBatchResult result) {
    if (result.maybeMore) return l10n.syncBatchMore(result.mails);
    // 「一封都没轮到」有两种截然不同的原因，不能合用一句话：真的没有待同步
    // （好消息）vs 这些实例现在收不了信（坏消息，而且用户需要去重登）。
    if (result.blocked) return l10n.syncBatchBlocked;
    if (result.empty) return l10n.syncBatchNothing;
    return l10n.syncBatchDone(result.bodyFilled, result.attachments);
  }
}

/// 邮件级清单。`synced` 为 false 时是「待同步」（含在飞的），为 true 时是
/// 「已同步」。
///
/// 两个 tab 共用这一个 widget：它们的差别只有「取哪一批」和「空态文案」，
/// 拆成两个类会把 `_SyncRow` 那一套重复一遍。
class _MailStageList extends ConsumerWidget {
  const _MailStageList({required this.profiles, required this.synced});

  final List<Profile> profiles;
  final bool synced;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (profiles.isEmpty) return const SizedBox.shrink();

    // 每一台实例一条流，拼起来。用 `ListView` 套若干个 `_ProfileSection`
    // 而不是把它们铺平成一个 `ListView.builder`：铺平需要在这里做一次
    // 「异步流 × N」的合并，而合并出来的顺序会在某一台实例更新时整段重排
    // （用户正看的那一行会跳走）。分段之后每段自己动，跳的范围小得多。
    return ListView(
      children: <Widget>[
        for (final profile in profiles)
          _ProfileSection(profile: profile, synced: synced),
      ],
    );
  }
}

class _ProfileSection extends ConsumerWidget {
  const _ProfileSection({required this.profile, required this.synced});

  final Profile profile;
  final bool synced;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    if (synced) {
      final rows = ref.watch(
        syncedMailsProvider((profileId: profile.id, limit: 100)),
      );
      return rows.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => ListTile(title: Text('$e')),
        data: (list) {
          // 已同步那一档**不另写 SQL**：`watchMailbox` 拿到的就是「这个实例
          // 全部邮箱的收信、按时间倒序」，与列表页要的一模一样。再写一条只会
          // 在两处留下会走散的口径。
          //
          // 附件是否齐这里**没法判**（那要另一条统计流），所以计数一律给 0
          // —— 只按「正文齐与否」筛。少数「正文齐、附件还在下」的信会在这里
          // 露一次脸，可接受的代价；反过来（每一行都确认一遍附件）要在这一档
          // 上再挂 N 条流。注意给 0 在这里是**对**的（0 个附件 = 没有附件要下），
          // 与待同步那一档里「统计还没到」的 null 不是一回事。
          final items = <SyncItem>[
            for (final row in list)
              if (syncStageOf(
                    row: row,
                    attachmentTotal: 0,
                    attachmentMissing: 0,
                  ) ==
                  SyncStage.synced)
                SyncItem(
                  row: row,
                  stage: SyncStage.synced,
                  attachmentTotal: 0,
                  attachmentMissing: 0,
                ),
          ];
          if (items.isEmpty) return _EmptyHint(text: l10n.syncPanelSyncedEmpty);
          return _Section(
            profile: profile,
            child: Column(
              children: <Widget>[
                for (final item in items)
                  _SyncRow(item: item, busy: false, onSync: null),
              ],
            ),
          );
        },
      );
    }

    final items = ref.watch(syncPendingProvider(profile.id));
    // 附件计数单独一条流（见 `syncAttachmentStatsProvider` 的注释）。
    final ids =
        items.value?.map((i) => i.row.emailId).toList() ?? const <int>[];
    final stats = ref
        .watch(syncAttachmentStatsProvider((profileId: profile.id, ids: ids)))
        .value;
    final busy = ref.watch(manualSyncProvider);

    return items.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => ListTile(title: Text('$e')),
      data: (list) {
        if (list.isEmpty) return _EmptyHint(text: l10n.syncPanelPendingEmpty);
        return _Section(
          profile: profile,
          child: Column(
            children: <Widget>[
              for (final item in list)
                _SyncRow(
                  // 附件计数来自另一条流，这里把它合进去并**重算阶段**：
                  // `syncPendingProvider` 那一条只知道「缺正文 / 缺附件」，
                  // 不知道缺几个。
                  //
                  // 但**统计还没到的时候（null）必须原样留着**：拿 0/0 去
                  // 重算，一封「正文齐、附件没下」的信会被算成「已同步」——
                  // 那一帧里它既被排进待同步清单、又显示已同步、连同步按钮
                  // 都消失。而 `ids` 一变 family 的 key 就变、又要重新
                  // loading 一次，所以这不是「首帧闪一下」，是每次列表变动
                  // 都会重演一遍。
                  item: switch (stats?[item.row.emailId]) {
                    null => item,
                    final stat => item.withCounts(
                      total: stat.total,
                      missing: stat.missing,
                      inFlight: item.stage == SyncStage.syncing,
                    ),
                  },
                  busy: busy == item.ref,
                  onSync: () =>
                      ref.read(manualSyncProvider.notifier).sync(item.ref),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 一台实例的那一段：一条小标题（实例名）+ 它的行。
class _Section extends StatelessWidget {
  const _Section({required this.profile, required this.child});

  final Profile profile;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            profile.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 一行 = 主题 + 阶段标签 + 「附件 1/3」 + 发件人 + 右侧按钮。
class _SyncRow extends StatelessWidget {
  const _SyncRow({
    required this.item,
    required this.busy,
    required this.onSync,
  });

  final SyncItem item;

  /// 这一封正被**手动**补拉（与它自己在不在飞是两件事：在飞也包括自动队列）。
  final bool busy;

  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final row = item.row;
    final action = item.stage.actionOf(inFlight: busy);

    return ListTile(
      dense: true,
      title: Text(
        row.subject.isEmpty ? l10n.noSubject : row.subject,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        <String>[
          _stageLabel(item.stage, l10n),
          if (item.attachmentTotal > 0)
            l10n.attachmentProgress(
              item.attachmentTotal - item.attachmentMissing,
              item.attachmentTotal,
            ),
          row.displaySender,
        ].where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall,
      ),
      trailing: switch (action) {
        SyncAction.none => null,
        SyncAction.syncing => const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SyncAction.sync => IconButton(
          tooltip: l10n.syncNowOne,
          icon: const Icon(Icons.sync, size: 20),
          onPressed: onSync,
        ),
      },
    );
  }

  /// 阶段标签。`synced` 也要给文案 —— 已同步那一档复用它。
  static String _stageLabel(SyncStage stage, AppLocalizations l10n) =>
      switch (stage) {
        SyncStage.synced => l10n.syncStageSynced,
        SyncStage.syncing => l10n.syncStageSyncing,
        SyncStage.pendingBody => l10n.syncStagePendingBody,
        SyncStage.pendingAttachment => l10n.syncStagePendingAttachment,
      };
}
