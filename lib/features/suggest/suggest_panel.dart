import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, KeyDownEvent, KeyRepeatEvent;

import '../../data/models/mail_row.dart';
import '../../l10n/app_localizations.dart';
import '../ai/ai_service.dart';
import '../ai/ai_stream_view.dart';
import 'mail_action.dart';
import 'suggest_session.dart';
import 'suggestion.dart';

/// 弹出建议面板，返回用户点的那一项（或 null = 用户关掉了）。
///
/// **面板只选不做**（spec §4.6）：它不认识 `EmailRepository`、不认识路由，
/// 产出就是一个 [SuggestionChoice]。执行由调用方（`MailActionRunner`）做。
///
/// 调用方拿到的那一份 `MailRow` **必须是补全正文之后重新读过的那一行** ——
/// 面板内部还会再走一遍 `ensureFull`（会话自己判 `hasFullBody`），而
/// `session.row` 才是补全之后的那一份。执行时用调用方重读的那一行 ——
/// 见 `SuggestFlow.open` 的第 2 步，那条路保证调用方手里已经是全文。
Future<SuggestionChoice?> showSuggestPanel(
  BuildContext context, {
  required MailRow row,
  required bool starEnabled,
  required Future<MailRow?> Function() refresh,
  required Future<AiStart> Function(String input, List<String> actionIds) launch,
}) =>
    showModalBottomSheet<SuggestionChoice>(
      context: context,
      // 与 `send_queue_sheet` / `attachment_sheet` 同一套（spec §4.1 第 1 段）。
      isScrollControlled: true,
      builder: (_) => SuggestPanel(
        row: row,
        starEnabled: starEnabled,
        refresh: refresh,
        launch: launch,
      ),
    );

/// 建议面板。**从点下去到出结果始终是同一个面板**（spec §4.1）—— 换框会让
/// 「分析完」看起来像又点了一次，而且取消按钮的位置会跳。
class SuggestPanel extends StatefulWidget {
  const SuggestPanel({
    super.key,
    required this.row,
    required this.starEnabled,
    required this.refresh,
    required this.launch,
  });

  final MailRow row;
  final bool starEnabled;
  final Future<MailRow?> Function() refresh;
  final Future<AiStart> Function(String input, List<String> actionIds) launch;

  @override
  State<SuggestPanel> createState() => _SuggestPanelState();
}

class _SuggestPanelState extends State<SuggestPanel> {
  late final SuggestSession _session = SuggestSession(
    row: widget.row,
    starEnabled: widget.starEnabled,
    refresh: widget.refresh,
    launch: widget.launch,
  );

  /// 面板根的焦点节点。回车只在这个节点**持有焦点**时才执行第一项 ——
  /// 焦点到了面板里的按钮上（Tab 之后）时不吃键，见 [_onKeyEvent]。
  late final FocusNode _topFocus = FocusNode();

  /// 面板正在关的动画里再 pop 一次会把底下的路由一起带走（比如详情页）。
  /// 长按回车（`KeyRepeatEvent`）会重复触发 —— 这个标志就是为它准备的，
  /// 两条 pop 的路（回车与点卡片）都从 [_pop] 走，才真的都盖得住。
  bool _closing = false;

  /// 桌面平台。与 `window_channel.dart` 那处 `_isDesktop` **逐字同口径**
  /// （`defaultTargetPlatform` 是 macOS / Windows / Linux）。
  ///
  /// 仓库里另外两处**略有出入、别拿它们对照**：`attachment_launcher.dart`
  /// 用 `!kIsWeb && (Platform.isMacOS || …)`（走 `dart:io`），
  /// `sync_providers.dart` 则显式先 `if (kIsWeb) return false`。
  ///
  /// 这一处故意**不抽公共函数**：那几处各自内联，抽一次要动好几个文件，而它
  /// 只是一句平台判断。真要抽的时候一起抽。
  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  void initState() {
    super.initState();
    // 面板一构造就走流程（点这颗按钮的人就是要这个）。
    _session.start();
  }

  /// 面板根的按键处理。**不是 `CallbackShortcuts`**（spec §2.1 原写的是它，
  /// 这里按 code review 改掉了）：`CallbackShortcuts` 对匹配到的键**一律返回
  /// `handled`**，事件在浮到 `WidgetsApp` 的默认快捷键之前就被吃掉 ——
  /// 焦点落在面板自己的按钮（「重新分析」/「重试」）上时按回车，会去执行第一项，
  /// 而不是按下那颗按钮。挂 `Focus.onKeyEvent` 才能**自己决定吃不吃**：
  /// 焦点还在面板根上时才 `handled`，到了按钮上就 `ignored`，让它继续上浮去
  /// 激活那颗按钮。
  ///
  /// `enter` 与 `numpadEnter` **都要认**（实测：小键盘回车是另一个键码，
  /// 只判 `enter` 时它一个字都不触发）。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    // 焦点已经不在面板根上（Tab 到了某颗按钮）：不吃这个键，让它上浮。
    // 这一条就是「回车不抢自己按钮的键」的落点。
    if (FocusManager.instance.primaryFocus != _topFocus) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _runTopPick();
    return KeyEventResult.handled;
  }

  /// 两条 pop 的路（回车与点卡片）都从这儿走：`_closing` 这道不变量才真的
  /// 盖住两种触发方式，而不是只挡住键盘那一条。
  void _pop(SuggestionChoice choice) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(choice);
  }

  /// 回车 = 执行**第一项**，与鼠标点第一张卡是**同一句话**（spec §2.2）。
  ///
  /// 于是删除照旧弹确认框（`MailActionRunner._delete` 里那道 `_confirm`）、
  /// 回复照旧打开写邮件页 —— 回车省掉的是「把鼠标移过去」，不是那次确认。
  ///
  /// 面板里没有可执行的东西时**什么都不做**：不能 pop 一个 `null` 出去把面板
  /// 白关掉（用户按一下回车，面板没了，什么也没发生）。
  void _runTopPick() {
    if (_closing) return;
    if (_session.stage.value != SuggestStage.done) return;
    final parsed = _session.parsed;
    if (parsed is! SuggestionParsed) return;
    // 与 `_choices` 读的是**同一份数据**，不另算一遍「哪一项是推荐」——
    // 「回车与点第一张卡是同一句话」在代码里就落在这里。
    final choices = parsed.suggestion.choices;
    if (choices.isEmpty) return;
    _pop(choices.first);
  }

  @override
  void dispose() {
    _topFocus.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: ConstrainedBox(
        // 最高 70% 屏高（与 `send_queue_sheet.dart` 同一套数字与理由）：
        // 候选变成卡片之后一屏放不下五张，撑爆会让面板被裁掉一截。
        // 这层限高滚动有自己的断言（`takeException()`）。
        //
        // **三种态一起包**：失败态要显示模型原文（`_rawText` 那个限高 160 的
        // 框），再叠上抬头一样会顶爆。
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Focus(
              focusNode: _topFocus,
              autofocus: true,
              // 回车执行第一项。挂在 `Focus.onKeyEvent` 而不是
              // `CallbackShortcuts`：后者对匹配的键一律 `handled`，会把焦点在
              // 「重新分析 / 重试」上的回车也吞掉 —— 见 `_onKeyEvent` 的注释。
              onKeyEvent: _onKeyEvent,
              child: ValueListenableBuilder<SuggestStage>(
                valueListenable: _session.stage,
                builder: (context, stage, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(l10n.aiSuggestPanelTitle,
                            style: theme.textTheme.titleMedium),
                        const Spacer(),
                        // 「重新分析」在**结果态**常驻（spec §4.5）；失败态里
                        // 那个「重试」是同一个动作、另一个位置。
                        if (stage == SuggestStage.done)
                          TextButton.icon(
                            key: const ValueKey('ai-suggest-again'),
                            onPressed: _session.restart,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: Text(l10n.aiSuggestReanalyze),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ..._header(context, l10n),
                    const SizedBox(height: 8),
                    ..._body(context, l10n, stage),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 抬头：**AI 看到了什么**（spec §4.2）。三个态都有，最多两行。
  ///
  /// 「主题、发件人」这几个字是固定的、**不进 `.arb`** —— 它们是代码定下的
  /// 字段名单（附件只给名字不给内容，是 §5.4 的策略，不是文案）。要本地化的
  /// 只有 `{chars}`（中英语序不同），它必须走占位参数。
  List<Widget> _header(BuildContext context, AppLocalizations l10n) {
    // 抬头**常驻**（spec §4.2）。唯一不画的时候是「这一段还没组装出来」——
    // 也就是补正文那一态（`_input` 要等 `_refresh()` 回来才算）。
    // **别在这里读 `_session.input`**：它带 `!`，那一态会直接抛。
    final input = _session.inputOrNull;
    if (input == null) return const <Widget>[];
    final theme = Theme.of(context);
    final extras = <String>[
      if (input.attachmentCount > 0)
        l10n.aiSuggestAttachments(input.attachmentCount),
      if (input.quotedDropped) l10n.aiSuggestQuotedDropped(input.originalChars),
      if (input.truncated) l10n.aiSuggestTruncated(input.bodyChars),
    ];
    return <Widget>[
      Text(
        l10n.aiSuggestReading(input.bodyChars),
        key: const ValueKey('ai-suggest-header'),
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      if (extras.isNotEmpty)
        Text(
          extras.join(' · '),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      const Divider(height: 16),
    ];
  }

  List<Widget> _body(
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
              Text(l10n.aiSuggestFetchingBody,
                  style: theme.textTheme.bodySmall),
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
        final parsed = _session.parsed;
        if (parsed is! SuggestionParsed) return const <Widget>[];
        return _choices(context, l10n, parsed.suggestion);

      case SuggestStage.failed:
        return <Widget>[
          // 两种失败长得不一样（spec §4.4）：
          // - 请求失败 → `AiStreamView` 已经画了那句话（`run.message` 非空）；
          // - 解析失败 → 面板显示**模型原文**，用户能自己读出来它想说什么。
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

  /// 动作列表（spec §4.1 那个「结果」框）。
  ///
  /// **`none` 单列时不打「最推荐」徽标**：那一条是兜底，把它标成最推荐是荒谬的。
  /// 判据写在这里而不是解析器里 —— 徽标是**界面的说法**，不该让解析器去决定
  /// 哪一项长得特别。
  List<Widget> _choices(
    BuildContext context,
    AppLocalizations l10n,
    Suggestion suggestion,
  ) {
    final theme = Theme.of(context);
    final lone = suggestion.choices.length == 1;
    return <Widget>[
      if (suggestion.summary.isNotEmpty) ...<Widget>[
        Text(suggestion.summary, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
      ],
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
          // 手机上画一个回车符号是纯噪音（那儿没有人有回车键）。
          showEnterHint: _isDesktop,
          onTap: () => _pop(suggestion.choices[i]),
        ),
      ],
    ];
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
    required this.showEnterHint,
    required this.onTap,
  });

  final SuggestionChoice choice;
  final String label;
  final IconData icon;

  /// 是不是「最推荐」那一张。用主色淡底 + 徽标把它挑出来。
  final bool top;
  final String topLabel;

  /// 桌面平台才画回车提示（spec §2.3）。
  final bool showEnterHint;

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
                          _TopBadge(
                            label: topLabel,
                            showEnterHint: showEnterHint,
                          ),
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

/// 「最推荐」徽标。桌面上在文字后面补一个回车符号（spec §2.3）。
///
/// 提示**挂在徽标里**，所以「`none` 单列时不打徽标」这条既有判据顺带管住了
/// 它 —— 「无需处理」旁边不会冒出「最推荐 ⏎」。测试单独钉了一条（桌面上跑），
/// 免得将来有人把提示挪出徽标时把这一条一起弄丢。
class _TopBadge extends StatelessWidget {
  const _TopBadge({required this.label, required this.showEnterHint});

  final String label;
  final bool showEnterHint;

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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (showEnterHint) ...<Widget>[
            const SizedBox(width: 3),
            Icon(
              Icons.keyboard_return,
              // 键名挂在 `Icon` 上 —— 测试按它找。
              key: const ValueKey('ai-suggest-enter-hint'),
              size: 12,
              color: scheme.onPrimaryContainer,
            ),
          ],
        ],
      ),
    );
  }
}
