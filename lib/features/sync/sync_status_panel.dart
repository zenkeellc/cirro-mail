import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/instance_colors.dart';
import '../../core/util/time_utils.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/sync_providers.dart';
import '../../router.dart';

/// 同步状态的**展示件**两样：
/// - [SyncStatusButton]：侧栏顶上 / 列表右上角那个按钮（图标表达状态，
///   点了**启动同步**、长按/右键打开同步页，见下）；
/// - [SyncInstanceCard]：一个实例的运行摘要卡片，由同步页使用。
///
/// 面板本身（原来那个 `showModalBottomSheet` 弹层）已经搬进
/// `sync_status_screen.dart` 成了正经页面 —— 它要装一份邮件级清单，
/// 弹层那个高度（屏幕的 75%，还要留出拖拽把手）装不下。
class SyncStatusButton extends ConsumerWidget {
  const SyncStatusButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final overview = ref.watch(syncOverviewProvider).value;
    // 「在忙」要把**逐封补齐**那一趟也算进来。
    //
    // 以前这里只看 `overview.any((o) => o.syncing)`，也就是调度器 `busy` ——
    // 而按下这个按钮之后真正把「待同步」清单变短的是 `ManualSyncController`
    // 那一趟逐封补拉（正文 + 附件），它跑的时候调度器是**空闲**的。于是
    // 最诡异的一幕出现了：按钮刚按下去时还在转（调度器那一轮），几分钟后
    // 转完、`busy` 变 false，而逐封补拉其实还在跑 —— 图标变成「已同步」，
    // 用户点了知道没完、再点一次却发现它又说「同步中」，来回跳。
    final manualBusy = ref.watch(manualSyncProvider) != null;
    final syncing = manualBusy || (overview?.any((o) => o.syncing) ?? false);
    final failed = overview?.any((o) => o.failCount > 0 || o.needsLogin) ?? false;

    final Widget glyph;
    final Color color;
    if (syncing) {
      glyph = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
      color = theme.colorScheme.primary;
    } else if (failed) {
      glyph = const Icon(Icons.cloud_off_outlined, size: 20);
      color = theme.colorScheme.error;
    } else {
      glyph = const Icon(Icons.cloud_done_outlined, size: 20);
      color = theme.colorScheme.onSurfaceVariant;
    }

    // 36×36 与原来那个 `_SyncingDot` 完全一致 —— 换掉之后侧栏顶部
    // 的视觉量级不该变，那会让整列菜单跟着挪位。
    return Tooltip(
      message: l10n.syncButtonHint,
      child: IconTheme(
        data: IconThemeData(color: color, size: 20),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          // **点它 = 启动同步**（没在同步时）/ **打开同步页**（正在同步时）。
          //
          // 这条语义改过一次：早先恒为 `push(syncStatus)`，于是「看到云朵
          // 想立刻收一次信」按下去只会跳走一整页，同步本身一动不动 ——
          // 与用户按这个按钮的动机（「马上同步一轮」）正相反。而下拉刷新
          // 那条快捷路径在窄屏的详情页/设置页上根本够不着。
          //
          // 正在同步时反过来：那一轮已经跑起来了，再按一次没有意义，
          // 用户这时候按它想看的正是「同步到哪儿了」，所以那一支进同步页。
          onTap: () => syncing
              ? context.push(Routes.syncStatus)
              : _syncNow(context, ref),
          // 同步页**只有这一个入口**（`Routes.syncStatus` 全项目就两处引用，
          // 另一处是它自己的路由表）。不给一条长按/右键的备用通路，
          // 「同步完了想看一眼同步页」就再也进不去了。
          onLongPress: () => context.push(Routes.syncStatus),
          onSecondaryTap: () => context.push(Routes.syncStatus),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(child: glyph),
          ),
        ),
      ),
    );
  }

  /// 空闲时按一下 = 立刻同步一轮。
  ///
  /// 成败都要说一句话：`refreshNow` 返回 false 意味着「这个实例现在没有
  /// 能跑的东西」（一个都没登录 / token 确实废了），静默什么都不做会被
  /// 当成「按钮坏了」。口径与 `SyncInstanceCard._syncNow` 完全一致。
  ///
  /// **只报「开没开起来」，不报「补完没有」**：这条路径是「推一轮」，
  /// 异步跑完不返回结果，所以这里给的是一句「已开始」。真正会把「待同步」
  /// 清单变短的那一趟是 `ManualSyncController.syncAll`，它在同步页上，
  /// 有自己的进度与收尾统计（见 `sync_status_screen.dart`）。
  Future<void> _syncNow(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ran = await ref.read(syncSchedulerProvider).refreshNow();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(ran ? l10n.syncStarted : l10n.syncNowFailed),
      ),
    );
  }
}

/// 一个实例的同步卡片。自带 1 秒时钟（「还有 N 秒」要走）。
///
/// 不套 `Card`：同步页里它是**一台实例一条、横向铺开**的，卡片投影叠在
/// 一列已经分了段的清单上只会把页面压得更闷。留在这份文件里而不是搬进
/// 同步页，是因为它带着一个 1s 的 `Timer` —— 搬一次就多一次写错 `dispose`
/// 的机会，而它对「弹层还是页面」这件事一无所知。
class SyncInstanceCard extends ConsumerStatefulWidget {
  const SyncInstanceCard({super.key, required this.overview});

  final SyncOverview overview;

  @override
  ConsumerState<SyncInstanceCard> createState() => _SyncInstanceCardState();
}

class _SyncInstanceCardState extends ConsumerState<SyncInstanceCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant SyncInstanceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有「等待中」那张卡需要一秒一跳的倒计时。同步中/已停止/要重登的
    // 卡片没有会变的数字，让它们每秒重建一次纯属浪费。
    if ((oldWidget.overview.nextRunAt == null) !=
        (widget.overview.nextRunAt == null)) {
      _syncTicker();
    }
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (widget.overview.nextRunAt == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final overview = widget.overview;
    final profile = ref.watch(profileByIdProvider(overview.profileId));

    final (String stateLabel, IconData stateIcon, Color stateColor) =
        _stateOf(overview, l10n, theme);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (profile != null)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: InstanceColors.of(profile.colorIndex),
                      shape: BoxShape.circle,
                    ),
                  ),
                Expanded(
                  child: Text(
                    profile?.displayName ?? overview.profileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Icon(stateIcon, size: 16, color: stateColor),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    stateLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: stateColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: <Widget>[
                _Metric(
                  icon: Icons.check_circle_outline,
                  text: l10n.syncedCount(overview.localCount),
                ),
                _Metric(
                  icon: Icons.cloud_download_outlined,
                  // 未知与 0 是两件事：0 是「同步完了」，未知是「还没算出来」。
                  text: overview.unsynced == null
                      ? l10n.unsyncedUnknown
                      : l10n.unsyncedCount(overview.unsynced!),
                  tooltip: overview.unsynced == null
                      ? l10n.unsyncedUnknownHint
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              overview.lastSuccessAt == null
                  ? l10n.syncNeverSucceeded
                  : l10n.syncLastSuccess(
                      TimeUtils.formatListTime(overview.lastSuccessAt),
                    ),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (overview.failCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  l10n.syncFailCount(overview.failCount),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            if (overview.lastError != null && overview.lastError!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  overview.lastError!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            // 「立即同步」按钮**永远显示**（只要这台实例该收信）。
            //
            // 之前只在 `!needsLogin && !stopped` 时显示 —— 而那恰恰是
            // 「点它没反应」的那个 bug 的另一半：真正需要用户按一下的情形
            // （循环已经停了、标记着需重登）反倒把按钮藏了起来。
            // 按下之后由 `SyncScheduler.refreshNow` 负责解释结果：
            // 建得起 runtime 就真跑一轮（并且把「需重登」标记验活后撤掉），
            // 建不起来就当场说清楚「还没登录 / 需要重登」。
            if (!overview.needsLogin)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _syncNow(context, ref, overview.profileId),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(l10n.syncNowOne),
                ),
              )
            else
              // 需要重登的实例：给的是**能解决问题**的按钮（去登录页），
              // 而不是一个必然失败的「立即同步」。
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => context.go(
                    '${Routes.login}/${overview.profileId}',
                  ),
                  icon: const Icon(Icons.login, size: 16),
                  label: Text(l10n.login),
                ),
              ),
          ],
        ),
    );
  }

  /// 面板上的「立即同步」。
  ///
  /// 关键是**把没有反应的原因说出来**：`refreshNow` 返回 false 意味着
  /// 「这个实例现在根本没有可跑的东西」（没登录、或 token 确实废了）。
  /// 先前那个按钮调的是同一个方法却 `?.requestNow()` 到一个 null ——
  /// 点了什么都不发生，用户只会以为「同步坏了」，而不是「我该重新登录了」。
  Future<void> _syncNow(
    BuildContext context,
    WidgetRef ref,
    String profileId,
  ) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ran = await ref
        .read(syncSchedulerProvider)
        .refreshNow(profileId: profileId);
    if (ran) return;
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.syncNowFailed)),
    );
  }

  /// 这一行左边那个状态词。四种互斥的形态，判据只看引擎快照。
  (String, IconData, Color) _stateOf(
    SyncOverview overview,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    if (overview.needsLogin) {
      return (
        l10n.sessionExpired,
        Icons.lock_outline,
        theme.colorScheme.error,
      );
    }
    if (overview.syncing) {
      return (
        l10n.syncStateSyncing,
        Icons.sync,
        theme.colorScheme.primary,
      );
    }
    if (overview.stopped) {
      return (
        l10n.syncStateStopped,
        Icons.pause_circle_outline,
        theme.colorScheme.outline,
      );
    }
    final seconds = overview.secondsToNextRun;
    return (
      seconds == null
          ? l10n.syncStateWaiting
          // 「等待中」的有用信息是「还要多久」，不是「在等」这件事本身。
          : '${l10n.syncStateWaiting} · ${l10n.syncNextIn(seconds)}',
      Icons.schedule,
      theme.colorScheme.onSurfaceVariant,
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.text, this.tooltip});

  final IconData icon;
  final String text;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(text, style: theme.textTheme.labelMedium),
      ],
    );
    if (tooltip == null) return row;
    return Tooltip(message: tooltip!, child: row);
  }
}
