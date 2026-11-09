import 'package:flutter/material.dart';

import '../../data/models/mail_row.dart';
import '../../l10n/app_localizations.dart';
import '../ai/ai_service.dart';
import '../ai/ai_stream_view.dart';
import 'mail_action.dart';
import 'suggest_session.dart';
import 'suggestion.dart';

/// 两列布局的门槛：**面板自身宽度** >= 720 才分两列（spec §2.1）。
///
/// 用的是面板的宽度而不是窗口宽度：宽屏的阅读区可以被用户拖得很窄，那时候
/// 两列会把左栏（摘要）挤成一条竖线。判据与 `Breakpoints` 同一条规矩 ——
/// 只看宽度，不看平台。
const double _twoColumnMinWidth = 720;

/// 右列（建议操作）的固定宽度（spec §2.1）。
const double _actionsColumnWidth = 320;

/// AI 建议的**整页形态**：`Navigator.push` 一个全屏页，返回用户点的那一项
/// （或 null = 用户返回/关掉了）。
///
/// 窄屏（`Breakpoints.compact`）的入口走这一条，宽屏走详情页里停靠的
/// [SuggestView]（见 `mail_detail_screen.dart`）。**页面先 pop、调用方再执行**
/// （spec §2.2）：这样回复/转发的写邮件页压在上层，删除的 `onDeleted` 收尾也
/// 仍由原调用方负责。
///
/// 内容与停靠面板**同一份**（[SuggestView] `isPage: true` 时单列 + 区块标题），
/// 不另写一套 —— 两套内容必然在「失败态画什么」这类细节上分叉。
Future<SuggestionChoice?> showSuggestPage(
  BuildContext context, {
  required MailRow row,
  required bool starEnabled,
  required Future<MailRow?> Function() refresh,
  required Future<AiStart> Function(String input, List<String> actionIds) launch,
  String? sourceLabel,
}) {
  return Navigator.of(context).push<SuggestionChoice>(
    MaterialPageRoute<SuggestionChoice>(
      builder: (pageContext) => Scaffold(
        appBar: AppBar(
          title: Text(AppLocalizations.of(pageContext).aiSuggestPanelTitle),
          // 整页形态的标题在 AppBar 上，署名就跟着它（设计稿 §5.3 / §9.6：
          // 「抬头标题行右侧」）。停靠形态由 [SuggestView._topRow] 画同一颗。
          actions: <Widget>[
            if (sourceLabel != null)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(child: AiSourceChip(label: sourceLabel)),
              ),
          ],
        ),
        body: SuggestView(
          row: row,
          starEnabled: starEnabled,
          refresh: refresh,
          launch: launch,
          // AppBar 已经写了标题，正文里不再重复一遍。
          showTitle: false,
          isPage: true,
          // **先 pop 再执行**（spec §2.2）：pop 的返回值就是调用方拿到的
          // `SuggestionChoice`，执行仍由 `SuggestFlow.open` 负责。
          onPick: (choice) => Navigator.of(pageContext).pop(choice),
        ),
      ),
    ),
  );
}

/// AI 建议的**共享视图**：整页形态与停靠面板用的是同一套内容与状态机。
///
/// 它**只选不做**（spec §4.6）：不认识 `EmailRepository`、不认识路由，产出
/// 就是一个通过 [onPick] 交出去的 [SuggestionChoice]。
///
/// 布局由 [isPage] 与自身宽度决定（spec §2）：
/// - 停靠面板且宽度 >= 720 → 两列：左摘要/要点（弹性），右动作列表（固定
///   320 宽），两列各自滚动；
/// - 其余（停靠面板窄了、或整页）→ 单列，整块可滚动。
///
/// 状态机整个交给 [SuggestSession]（补正文 → 分析 → 解析），本类只监听
/// `stage` 决定画哪一块。**从点下去到出结果始终是同一个视图** —— 换框会让
/// 「分析完成」看起来像又点了一次。
class SuggestView extends StatefulWidget {
  const SuggestView({
    super.key,
    required this.row,
    required this.starEnabled,
    required this.refresh,
    required this.launch,
    required this.onPick,
    this.showTitle = true,
    this.onClose,
    this.isPage = false,
    this.sourceLabel,
  });

  final MailRow row;
  final bool starEnabled;
  final Future<MailRow?> Function() refresh;
  final Future<AiStart> Function(String input, List<String> actionIds) launch;

  /// 用户点了某一项建议。停靠面板里由详情页收起面板并交给执行器；整页里
  /// 由 [showSuggestPage] 先 pop 掉这一页。
  final ValueChanged<SuggestionChoice> onPick;

  /// 抬头那一行要不要写标题。整页形态由 `AppBar` 写，所以传 false。
  final bool showTitle;

  /// 关闭按钮（停靠面板的 ×）。null = 不画 —— 整页形态用返回箭头，
  /// 关闭面板不改变选中的邮件（spec §2.1），所以这个回调只管「收起」。
  final VoidCallback? onClose;

  /// 是不是整页形态。只影响布局与区块标题：整页永远单列，但显示
  /// 「摘要 / 建议操作」两个区块标题（spec §1.2、§2.2）。
  final bool isPage;

  /// 输出处的来源署名（设计稿 §5.3 / §7.5 / 接缝 S5）。
  ///
  /// 只在**停靠面板**里由这里画：整页形态的标题在 `AppBar` 上，那颗 chip 由
  /// [showSuggestPage] 画，画两处会重复。null（公开版 / BYOK）→ 抬头与从前
  /// 逐像素相同。
  final String? sourceLabel;

  @override
  State<SuggestView> createState() => _SuggestViewState();
}

class _SuggestViewState extends State<SuggestView> {
  late final SuggestSession _session = SuggestSession(
    row: widget.row,
    starEnabled: widget.starEnabled,
    refresh: widget.refresh,
    launch: widget.launch,
  );

  /// 一次视图只交出一项。整页形态里重复交出去会**连着 pop 两次**（第一次
  /// 是自己的页，第二次会把宿主页一起带走）；停靠面板里则是把同一个动作
  /// 执行两遍。点下第一项之后其余的点击一律忽略。
  bool _picked = false;

  @override
  void initState() {
    super.initState();
    // 视图一挂上就走流程（点这颗按钮的人就是要这个）。
    _session.start();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  void _pick(SuggestionChoice choice) {
    if (_picked) return;
    _picked = true;
    widget.onPick(choice);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 门槛看**面板自己的宽度**（spec §2.1），不看窗口宽度。
        final twoColumns =
            !widget.isPage && constraints.maxWidth >= _twoColumnMinWidth;
        return SafeArea(
          child: Padding(
            // 头部只留一行（标题 + 信息 / 重新分析 / 关闭），不再单独占一行
            // 「已阅读：…」——停靠面板的高度是抢正文来的，2026-11-09 起把那段
            // 信息收进标题旁那颗 ⓘ 的 tooltip（spec §2.1）。
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            // 视图唯一的状态监听点：面板据此决定画哪一块（spec §2.4）。
            child: ValueListenableBuilder<SuggestStage>(
              valueListenable: _session.stage,
              builder: (context, stage, _) {
                final topRow = _topRow(context, l10n, stage);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (topRow != null) ...<Widget>[
                      topRow,
                      const SizedBox(height: 6),
                    ],
                    // 两种形态都是「抬头固定、内容区自己滚」：停靠面板高度被
                    // 父级夹在 240–420 之间（详情页定的），整页则是整屏，
                    // 靠 Expanded 把剩余高度交给滚动区。
                    Expanded(
                      child: twoColumns
                          ? _twoColumns(context, l10n, stage)
                          : _singleColumn(context, l10n, stage),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// 头部只留**一行**：标题（停靠面板有、整页交给 AppBar）、AI 看到了什么
  /// （ⓘ tooltip）、重新分析（结果态常驻，spec §4.5）、关闭（停靠面板的 ×）。
  ///
  /// 2026-11-09 精简：原来标题下面还有一行「已阅读：主题、发件人、正文 N 字」
  /// 和一条分隔线，把停靠面板（高度只有阅读区的 45%）的正文区压掉一截。
  /// 它的价值只是「解释建议为什么可能跑偏」，改成 ⓘ 的 tooltip 后**高度归零**，
  /// 想知道的用户悬停/长按仍能看到（截断、剥引用、附件数也都在里面）。
  Widget? _topRow(
    BuildContext context,
    AppLocalizations l10n,
    SuggestStage stage,
  ) {
    final showAgain = stage == SuggestStage.done;
    final showClose = widget.onClose != null;
    // ⓘ 要等 `SuggestInput` 组装完才有内容（补正文那一态还没有）。
    final hasInfo = _session.inputOrNull != null;
    if (!widget.showTitle && !showAgain && !showClose && !hasInfo) {
      return null;
    }
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        // 有标题时让它吃掉剩余宽度（长标题先省略号），没标题时用一个
        // `Spacer` 把右边那几颗按钮顶到行尾。
        if (widget.showTitle)
          Expanded(
            child: Text(
              l10n.aiSuggestPanelTitle,
              style: theme.textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          const Spacer(),
        // 署名紧跟在标题后面（`Spacer` 之后、图标之前）。**done 态也保留**：
        // 结果态渲染的是两列内容、不经过 `AiStreamView`，抬头是唯一跨阶段
        // 都在的位置。
        if (widget.showTitle && widget.sourceLabel != null) ...<Widget>[
          const SizedBox(width: 8),
          AiSourceChip(label: widget.sourceLabel!),
        ],
        if (hasInfo) _infoIcon(context, l10n),
        // 失败态里那个「重试」是同一个动作、另一个位置（结果区里）。
        if (showAgain)
          IconButton(
            key: const ValueKey('ai-suggest-again'),
            onPressed: _session.restart,
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: l10n.aiSuggestReanalyze,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
          ),
        if (showClose)
          IconButton(
            key: const ValueKey('ai-suggest-close'),
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, size: 18),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
          ),
      ],
    );
  }

  /// 「AI 看到了什么」的 ⓘ。**不占高度**，内容与原抬头那两行逐字一致。
  ///
  /// 「主题、发件人」这几个字是固定的、**不进 `.arb`** —— 它们是代码定下的
  /// 字段名单（附件只给名字不给内容，是 spec §5.4 的策略，不是文案）。要本地化
  /// 的只有 `{chars}`（中英语序不同），它必须走占位参数。
  Widget _infoIcon(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final input = _session.inputOrNull;
    if (input == null) return const SizedBox.shrink();
    final extras = <String>[
      if (input.attachmentCount > 0)
        l10n.aiSuggestAttachments(input.attachmentCount),
      if (input.quotedDropped) l10n.aiSuggestQuotedDropped(input.originalChars),
      // 截断文案说的是**原文多少字**（不是喂进去多少字）：2026-11-09 起
      // 长信取的是「开头 + 结尾」，只报「前 N 字」已经不成立了。
      if (input.truncated) l10n.aiSuggestTruncated(input.originalChars),
    ];
    final message = <String>[
      l10n.aiSuggestReading(input.bodyChars),
      if (extras.isNotEmpty) extras.join(' · '),
    ].join('\n');
    return Tooltip(
      message: message,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(
          Icons.info_outline,
          key: const ValueKey('ai-suggest-info'),
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 两列

  /// 停靠面板的宽形态（spec §2.1）：左列摘要/要点、右列动作卡片，各滚各的。
  ///
  /// 非 `done` 的那些态**全部落在左列**（转圈、流式内容、失败提示 + 重试），
  /// 右列只在 `done` 时画动作卡片 —— 与 spec §2.4「左列承担摘要/流式/失败
  /// 提示，右列只在 done 时画动作卡片」逐字一致。
  Widget _twoColumns(
    BuildContext context,
    AppLocalizations l10n,
    SuggestStage stage,
  ) {
    final List<Widget> left;
    final List<Widget> right;
    final parsed = _session.parsed;
    if (stage == SuggestStage.done && parsed is SuggestionParsed) {
      left = _summaryChildren(context, l10n, parsed.suggestion, withLabel: true);
      right = _actionsChildren(context, l10n, parsed.suggestion, withLabel: true);
    } else {
      left = _statusChildren(context, l10n, stage);
      right = const <Widget>[];
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: _scrollPane(
            padding: const EdgeInsets.only(right: 8),
            children: left,
          ),
        ),
        const VerticalDivider(width: 17),
        SizedBox(
          width: _actionsColumnWidth,
          child: _scrollPane(
            padding: const EdgeInsets.only(left: 4),
            children: right,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 单列

  /// 单列形态：停靠面板的窄形态，以及整页形态。
  ///
  /// 停靠面板窄了时保持旧观感（摘要段落 → 卡片，不加区块标题，spec §1.2
  /// 「单列布局保持现状」）；整页形态加上两个区块标题（`isPage`）。
  Widget _singleColumn(
    BuildContext context,
    AppLocalizations l10n,
    SuggestStage stage,
  ) {
    final parsed = _session.parsed;
    if (stage == SuggestStage.done && parsed is SuggestionParsed) {
      // 停靠面板的窄形态：摘要占左边（可滚动），动作收成**右侧一条图标栏**
      // （图标 + tooltip）—— 原来动作卡片跟在摘要下面，七项时用户要先滚过
      // 一大段摘要才看得到按钮，而停靠面板本来就只有阅读区 45% 的高度。
      // 整页形态（手机）仍用卡片：触屏没有 hover，tooltip 不是好的唯一入口。
      if (!widget.isPage) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: _scrollPane(
                padding: const EdgeInsets.only(right: 8),
                children: _summaryChildren(
                  context,
                  l10n,
                  parsed.suggestion,
                  withLabel: false,
                ),
              ),
            ),
            SizedBox(
              width: 44,
              child: _actionRail(context, l10n, parsed.suggestion),
            ),
          ],
        );
      }
      final summary = _summaryChildren(
        context,
        l10n,
        parsed.suggestion,
        withLabel: true,
      );
      final actions = _actionsChildren(
        context,
        l10n,
        parsed.suggestion,
        withLabel: true,
      );
      return _scrollPane(
        children: <Widget>[
          ...summary,
          if (summary.isNotEmpty) const SizedBox(height: 8),
          ...actions,
        ],
      );
    }
    return _scrollPane(children: _statusChildren(context, l10n, stage));
  }

  /// 停靠面板窄形态的**动作图标栏**（2026-11-09）。
  ///
  /// 每一项是一颗 40×40 的圆形按钮，`tooltip` 里给「动作名 + 模型给的理由」；
  /// 「最推荐」那一项用主色淡底 + tooltip 前缀标出来（与卡片版的徽标同一个
  /// 判据，`none` 单列时不标）。七项以上由这一栏自己滚 —— 它不会把摘要区
  /// 挤没，也不会撑破停靠面板的固定高度。
  Widget _actionRail(
    BuildContext context,
    AppLocalizations l10n,
    Suggestion suggestion,
  ) {
    final lone = suggestion.choices.length == 1;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < suggestion.choices.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 6),
            _RailButton(
              choice: suggestion.choices[i],
              label: labelOf(suggestion.choices[i].action, l10n),
              icon: iconOf(suggestion.choices[i].action),
              top: i == 0 &&
                  !(lone && suggestion.choices[i].action == MailAction.none),
              topLabel: l10n.aiSuggestTopPick,
              onTap: () => _pick(suggestion.choices[i]),
            ),
          ],
        ],
      ),
    );
  }

  /// 一块可滚的内容。外层一定是 `Expanded`（高度有界），所以这里给
  /// `SingleChildScrollView` 不会出现「无界高度」的断言。
  Widget _scrollPane({
    required List<Widget> children,
    EdgeInsetsGeometry? padding,
  }) {
    return SingleChildScrollView(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  // -------------------------------------------------------------- 内容块

  /// 非 `done` 态的内容：补正文 / 分析中 / 失败。与旧面板逐字一致。
  List<Widget> _statusChildren(
    BuildContext context,
    AppLocalizations l10n,
    SuggestStage stage,
  ) {
    final theme = Theme.of(context);
    switch (stage) {
      case SuggestStage.fetching:
        // `ensureFull` 没有进度回调，所以就是一句静态的话 + 转圈，
        // **不假装有百分比**（spec §8.4 末段）。
        return <Widget>[
          Row(
            children: <Widget>[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.aiSuggestFetchingBody,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ];

      case SuggestStage.analyzing:
        // 复用 `AiStreamView`：流式内容 + 停止按钮 + 出错提示条
        // （spec §4.3）。「停止 = 取消」，半截内容留着。
        return <Widget>[
          AiStreamView(
            run: _session.run,
            placeholder: l10n.aiSuggestAnalyzing,
          ),
        ];

      case SuggestStage.done:
        // `done` 由 `_twoColumns` / `_singleColumn` 单独装配（摘要与动作可能
        // 分居两列），不会走到这里。
        return const <Widget>[];

      case SuggestStage.failed:
        return _failureChildren(context, l10n);
    }
  }

  /// 失败态（spec §4.4）。两种失败长得不一样：
  /// - 请求失败 → `AiStreamView` 已经画了那句话（`run.message` 非空）；
  /// - 解析失败 → 显示**模型原文**，用户能自己读出来它想说什么。
  ///
  /// 两种都给「重试」（整个 `AiRun` 重跑，含 `ensureFull`）。
  List<Widget> _failureChildren(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    return <Widget>[
      if (_session.run.message.value.isEmpty)
        _rawText(context, l10n)
      else
        AiStreamView(
          run: _session.run,
          placeholder: l10n.aiSuggestAnalyzing,
        ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('ai-suggest-retry'),
          onPressed: _session.restart,
          icon: const Icon(Icons.refresh, size: 16),
          label: Text(l10n.aiSuggestRetry),
        ),
      ),
    ];
  }

  /// 解析失败时的**模型原文**（spec §4.4）：`SelectableText`，限高滚动。
  ///
  /// 给原文是刻意的 —— 用户可能读出来模型用了一段自然语言而不是 JSON，
  /// 那比一句「解析失败」有用。
  Widget _rawText(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final parsed = _session.parsed;
    final raw =
        parsed is SuggestionUnreadable ? parsed.raw : _session.run.text.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          l10n.aiSuggestParseFailed,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.error),
        ),
        const SizedBox(height: 6),
        Container(
          constraints: const BoxConstraints(maxHeight: 160),
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              raw,
              key: const ValueKey('ai-suggest-raw'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }

  /// 摘要区：概述段 + 关键要点。**空的就不画**（旧模型/旧网关的 `points`
  /// 为空列表时，这里与旧面板逐字相同）。
  List<Widget> _summaryChildren(
    BuildContext context,
    AppLocalizations l10n,
    Suggestion suggestion, {
    required bool withLabel,
  }) {
    final theme = Theme.of(context);
    final hasSummary = suggestion.summary.isNotEmpty;
    final hasPoints = suggestion.points.isNotEmpty;
    if (!hasSummary && !hasPoints) return const <Widget>[];
    return <Widget>[
      if (withLabel)
        _sectionLabel(
          context,
          l10n.aiSuggestSummaryTitle,
          const ValueKey('ai-suggest-summary-title'),
        ),
      if (hasSummary)
        Text(
          suggestion.summary,
          key: const ValueKey('ai-suggest-summary'),
          style: theme.textTheme.bodyMedium,
        ),
      if (hasPoints) ..._pointRows(context, suggestion.points),
    ];
  }

  /// 要点：小圆点 + 一句。`points` 是「关键事实/请求/时间点」，
  /// 不是正文的复述（spec §3.1）。
  List<Widget> _pointRows(BuildContext context, List<String> points) {
    final theme = Theme.of(context);
    return <Widget>[
      for (var i = 0; i < points.length; i++)
        Padding(
          // 第一条与概述之间留 8，其余 4：一眼能分出「这是一组」。
          padding: EdgeInsets.only(top: i == 0 ? 8 : 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  points[i],
                  key: ValueKey<String>('ai-suggest-point-$i'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
    ];
  }

  /// 动作列表（spec §4.1 那个「结果」框）。
  ///
  /// **`none` 单列时不打「最推荐」徽标**：那一条是兜底，把它标成最推荐是荒谬的。
  /// 判据写在这里而不是解析器里 —— 徽标是**界面的说法**，不该让解析器去决定
  /// 哪一项长得特别。
  List<Widget> _actionsChildren(
    BuildContext context,
    AppLocalizations l10n,
    Suggestion suggestion, {
    required bool withLabel,
  }) {
    final lone = suggestion.choices.length == 1;
    return <Widget>[
      if (withLabel)
        _sectionLabel(
          context,
          l10n.aiSuggestActionsTitle,
          const ValueKey('ai-suggest-actions-title'),
        ),
      for (var i = 0; i < suggestion.choices.length; i++) ...<Widget>[
        // 卡片之间留 8：卡片自己只有内边距，贴在一起就分不出是两张。
        if (i > 0) const SizedBox(height: 8),
        _ChoiceTile(
          choice: suggestion.choices[i],
          label: labelOf(suggestion.choices[i].action, l10n),
          icon: iconOf(suggestion.choices[i].action),
          top: i == 0 &&
              !(lone && suggestion.choices[i].action == MailAction.none),
          topLabel: l10n.aiSuggestTopPick,
          onTap: () => _pick(suggestion.choices[i]),
        ),
      ],
    ];
  }

  /// 区块标题（spec §1.2）。只在两列或整页时画；停靠面板的单列保持旧观感。
  Widget _sectionLabel(
    BuildContext context,
    String text,
    Key key,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        key: key,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 一项建议：**卡片行**（spec §1.2）。整卡可点 —— 那个「点一下直接办」的
/// 承诺就是这一层，所以它得长得像按钮，而不是像一段说明文字。
///
/// `Material` 在 `InkWell` **外面**：底色与圆角由 `Material` 给，`InkWell`
/// 的水波纹靠 `Clip.antiAlias` 裁在圆角里（不裁的话四角会溢出）。
/// `InkWell` 仍是卡片键（`ai-suggest-choice-<id>`）的宿主 —— 测试点的是它。
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.choice,
    required this.label,
    required this.icon,
    required this.top,
    required this.topLabel,
    required this.onTap,
  });

  final SuggestionChoice choice;
  final String label;
  final IconData icon;

  /// 是不是「最推荐」那一张。用主色淡底 + 徽标把它挑出来。
  final bool top;
  final String topLabel;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 0.35 / 0.6 这两档与 `app_theme.dart` 里那几处 `withValues(alpha:)` 同
    // 一个口径：一眼能看出「这条不一样」，又不至于把正文压得读不清。
    final cardColor = top
        ? scheme.primaryContainer.withValues(alpha: 0.35)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.6);
    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey<String>('ai-suggest-choice-${choice.action.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 图标底：这一行的锚点。徽标排在标题**之后**而不是之前，
              // 就是因为行首已经是图标了，徽标再压最前面会把图标挤到第二顺位。
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      top ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color:
                      top ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        // `Flexible` + 徽标同排：标题长起来时先挤标题，
                        // 而不是把徽标顶出卡片。
                        Flexible(
                          child: Text(
                            label,
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (top) ...<Widget>[
                          const SizedBox(width: 6),
                          _TopBadge(label: topLabel),
                        ],
                      ],
                    ),
                    if (choice.reason.isNotEmpty)
                      Text(
                        choice.reason,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「最推荐」徽标。
///
/// 2026-11-09 起**不再带回车提示**（spec §2.1 末条）：停靠面板在阅读场景里
/// 不抢焦点、不接管回车 —— 画一个回车符号反而是在暗示「按回车就行」。
class _TopBadge extends StatelessWidget {
  const _TopBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      // 键名不变：`test/suggest_panel_test.dart` 那条「徽标只有一个、挂在
      // 第一项上」照旧找它。
      key: const ValueKey('ai-suggest-top'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 窄形态动作栏里的一颗**图标按钮**（2026-11-09）。
///
/// 为什么不用 `IconButton`：这里要圆形底、40×40 的固定热区，还要把
/// 「动作名 + 理由」塞进 tooltip；`IconButton` 的默认尺寸与内边距会撑高整栏。
/// 键名与卡片版**逐字一致**（`ai-suggest-choice-<id>`）：测试与「点第一项」
/// 的判断都只认这一个，不该因为布局变了换一套键。
class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.choice,
    required this.label,
    required this.icon,
    required this.top,
    required this.topLabel,
    required this.onTap,
  });

  final SuggestionChoice choice;
  final String label;
  final IconData icon;

  /// 是不是「最推荐」那一项。与卡片版同一条判据（`none` 单列时不标）。
  final bool top;
  final String topLabel;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = top
        ? scheme.primaryContainer.withValues(alpha: 0.55)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.7);
    final foreground =
        top ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    // tooltip 是这颗按钮**唯一的说明**（窄形态不再有卡片上的标题行）。
    // 有理由就换行附上 —— 模型给的 reason 正是「为什么建议做这一件」。
    final message = <String>[
      if (top) '$topLabel · $label' else label,
      if (choice.reason.trim().isNotEmpty) choice.reason.trim(),
    ].join('\n');
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 300),
      child: Material(
        color: background,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey<String>('ai-suggest-choice-${choice.action.id}'),
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: foreground),
          ),
        ),
      ),
    );
  }
}
