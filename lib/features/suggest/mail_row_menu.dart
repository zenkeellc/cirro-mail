import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/mail_row.dart';
// 同一目录的 `features/suggest/` 那几份（`mail_action.dart` 等）排在
// `../../` 之后 —— 与 `mail_detail_screen.dart` 的排法一致（字典序里
// `../../x` 在 `../x` 之前）。
import '../../l10n/app_localizations.dart';
import '../../providers/ai_providers.dart';
import '../ai/ai_settings.dart';
import 'mail_action.dart';
import 'mail_action_runner.dart';
import 'suggest_flow.dart';
import 'suggestion.dart';

/// 列表行菜单里能做的事（spec §8.1）。
///
/// **刻意比整份动作池小**：菜单是用户已经选定「就要处理这一行」之后按的，
/// 「答复 / 转发 / 稍后提醒」那些要么去详情页，要么进 AI 面板 —— 塞进一个
/// 长按菜单只会让最常用的「标记已读 / 删除」被挤到看不见。
enum _RowAction { toggleRead, toggleStar, suggest, delete }

/// 列表行菜单：长按与右键两个入口的**唯一定义**（spec §8.1）。
///
/// 两个入口调同一个 [show]，`at == null` 走底部弹窗、否则走 [showMenu] ——
/// 两处各写一遍的话，桌面能用的那几项和触屏能用的那几项迟早不一样。
abstract final class MailRowMenu {
  const MailRowMenu._();

  /// 弹出菜单并执行用户选的那一项。
  ///
  /// [at] 为空 = 长按（没有坐标）；有值 = 右键（`onSecondaryTapUp` 给的
  /// `globalPosition`，`showMenu` 要它来定位）。
  ///
  /// [batch] 非空且不止一封时，菜单变成**对这一批**的操作（「标记已读（已选
  /// 3 封）」这种），语义见 [_runBatch]。右键一行时会传当前多选出来的那一批。
  static Future<void> show(
    BuildContext context,
    WidgetRef ref,
    MailRow row, {
    Offset? at,
    VoidCallback? onDeleted,
    List<MailRow>? batch,
  }) async {
    // spec §8.3 那三个条件由 `SuggestFlow.visible` 一处判（D5）。
    //
    // **必须 `await .future` 而不是读 `.value`**：`.value` 在冷启动那几帧是
    // `null`（`AsyncLoading`），于是「AI 建议」这一项会**偶尔不出现**。
    // `.future` 的定义就是「**等第一个不是 AsyncLoading 的状态**」，所以它
    // 不是在赌一帧 —— 设置读到之前菜单**不会**弹出来（`.value` 那版则会
    // 弹出并少一项）。代价是菜单的弹出时刻跟着设置加载走（读 prefs +
    // 钥匙串，毫秒级），换来的是「有 Key 就一定有这一项」。
    //
    // 与服务端 `SyncScheduler` 那边同一个取舍：宁可晚一点，也不要一个
    // 时灵时不灵的入口。
    //
    // 读不着（钥匙串出错之类，`.future` 会抛）就当「没配」：`settings` 为
    // null 时 `SuggestFlow.visible` 的 ② 那一支会把它挡住 —— 与详情页那颗
    // 图标读到 `null` 时同一个口径（那边没有 `.future`，是「还没读到就不画」）。
    AiSettings? settings;
    try {
      settings = await ref.read(aiSettingsProvider.future);
    } catch (_) {
      settings = null;
    }
    // 等设置读出来这段时间里，那一行可能已经被移出树了（列表刷新、切文件夹）。
    if (!context.mounted) return;

    final rows = (batch != null && batch.length > 1) ? batch : const <MailRow>[];
    final actions = <_RowAction>[
      _RowAction.toggleRead,
      _RowAction.toggleStar,
      // 多选时不出现：对**一批**信问「怎么处理」没有意义，模型给的是一个
      // 单封的建议，套到 5 封上多半是错的。
      if (rows.isEmpty && SuggestFlow.visible(row, settings)) _RowAction.suggest,
      _RowAction.delete,
    ];

    final picked = at == null
        ? await _sheet(context, row, actions, rows)
        : await _popup(context, row, actions, at, rows);
    if (picked == null || !context.mounted) return;

    if (rows.isNotEmpty) {
      await _runBatch(context, ref, rows, picked);
      return;
    }
    await _run(context, ref, row, picked, onDeleted: onDeleted);
  }

  // ------------------------------------------------------------ 两个形态

  /// 长按：底部弹窗。
  static Future<_RowAction?> _sheet(
    BuildContext context,
    MailRow row,
    List<_RowAction> actions,
    List<MailRow> batch,
  ) =>
      showModalBottomSheet<_RowAction>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final action in actions)
                ListTile(
                  key: ValueKey<String>(_key(action)),
                  leading: Icon(_icon(action, _leadRow(action, row, batch))),
                  title: Text(_label(sheetContext, action,
                      _leadRow(action, row, batch), batch.length)),
                  onTap: () => Navigator.of(sheetContext).pop(action),
                ),
            ],
          ),
        ),
      );

  /// 右键：`showMenu` 定位在指针处。
  ///
  /// `RelativeRect` 是 `showMenu` 要的形状 —— 它自己算「放不下时往哪边翻」，
  /// 传一个零尺寸的矩形在指针位置上就够了。
  ///
  /// **坐标必须减掉 Overlay 的原点**：`showMenu` 的 `position` 是相对**它要
  /// 落到的那个 Overlay** 的，而 [at] 是从 `onSecondaryTapUp` 拿到的**全局**
  /// 坐标。两者只在「Overlay 原点恰好在窗口左上角」时才相等 —— 宽屏下外壳
  /// 左侧有一条 232px 的一级导航，分支 Overlay 的原点因此偏在 x=232，少减
  /// 这一下菜单会整体右移 232（用户报的就是这个偏移）。
  ///
  /// 两边都取**根** Overlay：`rootOverlay` 与 `useRootNavigator` 是同一个
  /// Navigator 的 Overlay，坐标空间必然一致；根 Overlay 浮在整棵外壳之上，
  /// 也符合右键菜单「压住一切」的语义。`globalToLocal` 在原点本来就是 (0,0)
  /// 时是恒等变换，所以这一步对窄屏是无害的。
  static Future<_RowAction?> _popup(
    BuildContext context,
    MailRow row,
    List<_RowAction> actions,
    Offset at,
    List<MailRow> batch,
  ) {
    final overlay = Overlay.of(context, rootOverlay: true)
        .context
        .findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(at);
    return showMenu<_RowAction>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromRect(
        Rect.fromPoints(local, local),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<_RowAction>>[
        for (final action in actions)
          PopupMenuItem<_RowAction>(
            key: ValueKey<String>(_key(action)),
            value: action,
            child: Row(
              children: <Widget>[
                Icon(_icon(action, _leadRow(action, row, batch)), size: 18),
                const SizedBox(width: 12),
                Text(_label(context, action, _leadRow(action, row, batch),
                    batch.length)),
              ],
            ),
          ),
      ],
    );
  }

  // ------------------------------------------------------------ 三个小表

  /// 两个入口用**同一套 key**（`test/mail_row_menu_test.dart` 按它找）。
  static String _key(_RowAction action) => switch (action) {
        _RowAction.toggleRead => 'row-menu-read',
        _RowAction.toggleStar => 'row-menu-star',
        _RowAction.suggest => 'row-menu-suggest',
        _RowAction.delete => 'row-menu-delete',
      };

  static IconData _icon(_RowAction action, MailRow row) => switch (action) {
        _RowAction.toggleRead => row.isUnread
            ? Icons.mark_email_read_outlined
            : Icons.mark_email_unread_outlined,
        // 与详情页顶栏那颗星同一个约定（`mail_detail_screen.dart`）：
        // **已加星画实心**、未加星画空心。反过来就是图标和旁边的文字对不上。
        _RowAction.toggleStar => row.isStarred ? Icons.star : Icons.star_border,
        _RowAction.suggest => Icons.auto_awesome_outlined,
        _RowAction.delete => Icons.delete_outline,
      };

  /// 文案用**既有的那几个键**，不用 AI 面板那套 `aiSuggestAction*`：
  /// 这个菜单是普通行菜单，措辞该与详情页那个 ⋯ 菜单一致（「标记已读」
  /// 而不是「标记已读」在 AI 语境下的变体）。`labelOf` 只服务面板。
  ///
  /// [batchCount] > 1 时套一层「（已选 N 封）」—— 用户得看得出这一下会动到
  /// 多少封，否则右键一行的菜单长得和平时一样，点下去却删了一批。
  static String _label(
    BuildContext context,
    _RowAction action,
    MailRow lead,
    int batchCount,
  ) {
    final l10n = AppLocalizations.of(context);
    final base = switch (action) {
      _RowAction.toggleRead => lead.isUnread ? l10n.markRead : l10n.markUnread,
      _RowAction.toggleStar => lead.isStarred ? l10n.unstar : l10n.star,
      _RowAction.suggest => l10n.aiSuggest,
      _RowAction.delete => l10n.delete,
    };
    if (batchCount <= 1) return base;
    return l10n.selectionActionWithCount(base, batchCount);
  }

  /// 一批邮件显示的「代表行」。
  ///
  /// 图标与文案都是**按这一行的状态**画的（「标记已读」还是「标记未读」），
  /// 而多选时这一批的状态不一定一致。目标状态的口径与 [_runBatch] 定的一致：
  /// **全已读 → 标记未读，否则 → 标记已读**。
  static MailRow _leadRow(_RowAction action, MailRow row, List<MailRow> batch) {
    if (batch.isEmpty) return row;
    return switch (action) {
      _RowAction.toggleRead =>
        batch.every((r) => !r.isUnread) ? batch.first : _firstWhere(batch, (r) => r.isUnread),
      _RowAction.toggleStar =>
        batch.every((r) => r.isStarred) ? batch.first : _firstWhere(batch, (r) => !r.isStarred),
      _ => batch.first,
    };
  }

  static MailRow _firstWhere(List<MailRow> rows, bool Function(MailRow) test) =>
      rows.firstWhere(test, orElse: () => rows.first);

  // ------------------------------------------------------------ 执行

  /// 前三项收口到 `MailActionRunner.execute`（D4 那个唯一执行处）；
  /// 「AI 建议」不是一次动作，而是一个入口。
  static Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    MailRow row,
    _RowAction action, {
    VoidCallback? onDeleted,
  }) async {
    final choice = switch (action) {
      // `read` 是**目标**状态 —— 未读的那封点「标记已读」，给 `markRead`。
      // （这一点被写反过一次，见 `mail_detail_screen.dart:505` 那段注释。）
      _RowAction.toggleRead => SuggestionChoice(
          action: row.isUnread ? MailAction.markRead : MailAction.markUnread,
        ),
      _RowAction.toggleStar => SuggestionChoice(
          action: row.isStarred ? MailAction.unstar : MailAction.star,
        ),
      _RowAction.delete => const SuggestionChoice(action: MailAction.delete),
      // 不是一次动作 —— 下面单独走入口。
      _RowAction.suggest => null,
    };

    if (choice == null) {
      // **`onDeleted` 要跟着走**：模型建议「删除」、用户点了它，收尾与从菜单
      // 直接删是同一件事（内嵌详情页要把选中清掉）。
      await SuggestFlow.open(context, ref, row: row, onDeleted: onDeleted);
      return;
    }
    await MailActionRunner.execute(
      context,
      ref,
      row: row,
      choice: choice,
      onDeleted: onDeleted,
    );
  }

  /// 对**一批**邮件执行动作。
  ///
  /// 收口到 `MailActionRunner.executeBatch`（唯一执行处，与单封那条对称）——
  /// 这里只负责把「菜单项」翻成「动作」。
  static Future<void> _runBatch(
    BuildContext context,
    WidgetRef ref,
    List<MailRow> rows,
    _RowAction action,
  ) async {
    switch (action) {
      case _RowAction.toggleRead:
        // **全已读才标未读** —— 只要还有一封没读，点它的意思就是「都标已读」。
        // 与 `_leadRow` 画文案的口径同一套。
        final allRead = rows.every((r) => !r.isUnread);
        await MailActionRunner.executeBatch(
          context,
          ref,
          rows: rows,
          action: allRead ? MailAction.markUnread : MailAction.markRead,
        );
      case _RowAction.toggleStar:
        final allStarred = rows.every((r) => r.isStarred);
        await MailActionRunner.executeBatch(
          context,
          ref,
          rows: rows,
          action: allStarred ? MailAction.unstar : MailAction.star,
        );
      case _RowAction.delete:
        await MailActionRunner.executeBatch(
          context,
          ref,
          rows: rows,
          action: MailAction.delete,
        );
      case _RowAction.suggest:
        // 多选时 `show` 根本不会把这一项放进菜单（见上面 `rows.isEmpty`）。
        return;
    }
  }
}
