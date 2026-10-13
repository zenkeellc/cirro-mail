import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import 'compose_controller.dart';
import 'compose_text.dart';

/// 回车该收下什么。返回 null = 「别动补全，走原来的提交流程」。
///
/// 三条判据的顺序是有意的：
/// 1. 输入框里**已经是一个完整地址** → 收下它。粘贴一行地址再回车是最常见的
///    用法，这时候用户没在看建议条，抢着把第一条建议塞进去是替用户做主。
/// 2. 输入框里是半截（或空的）而建议条里有东西 → 收下**第一条**。
///    这是「回车录入补全地址」那条路：敲 `zh` 回车得到 `zhang@…`。
///    没有高亮选择那一套 —— 建议条是横排 chips 不是下拉浮层（见类注释），
///    再加一层选中态只会把状态机撑大。
/// 3. 都不是 → null，交给 `_commit()`：它会照旧报「地址不合法」。
///
/// 做成顶层纯函数（而不是 `_RecipientFieldState` 的方法）是为了能脱离
/// widget 测：这段判断错了的表现是「回车之后地址凭空变了一个」，而它没有
/// 别的手段能观察到。
@visibleForTesting
String? suggestionForCommit(
  String typed,
  List<({String address, String name})> suggestions,
) {
  if (looksLikeEmail(typed.trim())) return null;
  return suggestions.isEmpty ? null : suggestions.first.address;
}

/// 收件人输入：已确认的地址做成 chip，正在输入的那个在一行文本框里。
///
/// 为什么不用 `RawAutocomplete`：它管的是「一个控件 + 一个下拉」，而这里
/// 需要的是**多值 + 自由输入**（用户完全可以不理补全直接敲一个没见过的
/// 地址），两者的状态机不一样。自己管更短，也更好测。
class RecipientField extends ConsumerStatefulWidget {
  const RecipientField({super.key, required this.controller});

  final ComposeController controller;

  @override
  ConsumerState<RecipientField> createState() => _RecipientFieldState();
}

class _RecipientFieldState extends ConsumerState<RecipientField> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _showSuggestions = false;

  ComposeController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // 失焦时把输入框里那一截收下 —— 用户敲完地址直接点主题是很常见的，
      // 不这么做的话那个地址会在发送时被静默丢掉（或者更糟：被当成主题的
      // 一部分看着像已经写上了）。
      if (!_focus.hasFocus) _commit();
      setState(() => _showSuggestions = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final rejected = _c.commitRecipientInput();
    if (_text.text.isNotEmpty) _text.clear();
    if (rejected.isNotEmpty && mounted) {
      // 收不下的地址必须说出来，不能让用户以为写上了。
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.composeBadRecipient(rejected.first))),
      );
    }
  }

  /// 逗号、分号、空格、回车都当作「这个地址写完了」——
  /// 用户从别处复制一行地址粘进来是最常见的输入方式。
  ///
  /// **回车是唯一一个会先看建议条的**（见 [suggestionForCommit]）：点建议
  /// 要用鼠标，而「敲两下键盘就补全」是同一件事的键盘版本。
  ///
  /// `recipients` / `suggestions` 由 build 传进来而不是在这里读
  /// `controller.state`：`Notifier.state` 是 protected 成员，从控件里读会被
  /// lint 拦下（而且那样读到的也不参与刷新）。
  KeyEventResult _onKey(
    FocusNode node,
    KeyEvent event,
    List<String> recipients,
    List<({String address, String name})> suggestions,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _commitOrSuggestion(suggestions);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.comma ||
        event.logicalKey == LogicalKeyboardKey.semicolon) {
      _commit();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        _text.text.isEmpty) {
      // 输入框已经空了再按退格 → 删掉最后一个 chip。这是这类控件的通用手势。
      if (recipients.isNotEmpty) _c.removeRecipient(recipients.last);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 回车：能补全就补全，否则按原样提交。
  void _commitOrSuggestion(List<({String address, String name})> suggestions) {
    final picked = suggestionForCommit(_text.text, suggestions);
    if (picked == null) {
      _commit();
      return;
    }
    _pickSuggestion(picked);
  }

  /// 收下一个地址（点建议条的那一枚，或回车补全）。
  ///
  /// 走 [_c.addRecipient] 而不是 `setRecipients([...state.recipients, address])`：
  /// 后者拼的是 build 那一刻的快照，而这个动作发生在**当前**状态上 ——
  /// 输入框里刚被收下的那个地址会因此被丢掉（`build` 在两次提交之间未必重跑）。
  void _pickSuggestion(String address) {
    _c.addRecipient(address);
    _c.setRecipientInput('');
    _text.clear();
    // 焦点留在输入框：连点两个收件人是常态，每点一次都要重新点回输入框
    // 才是真的难用。
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 没上 `ConsumerWidget` 而是直接 `ref.watch`：这个控件**渲染用的**就是
    // state 里的收件人，所以必须 watch（`_c.state` 那种读法只适合事件回调里
    // 顺手取一次快照，用在这里会永远不刷新）。
    final state = ref.watch(composeControllerProvider(_c.args));
    final suggestions = state.recipientSuggestions
        .where((s) =>
            !state.effectiveRecipients
                .any((e) => e.toLowerCase() == s.address.toLowerCase()))
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(l10n.composeTo),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 0,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    for (final address in state.recipients)
                      InputChip(
                        label: Text(address),
                        onDeleted: () => _c.removeRecipient(address),
                        deleteButtonTooltipMessage: l10n.composeRemoveRecipient,
                      ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 180),
                      child: Focus(
                        onKeyEvent: (node, event) =>
                            _onKey(node, event, state.recipients, suggestions),
                        child: TextField(
                          controller: _text,
                          focusNode: _focus,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: state.recipients.isEmpty
                                ? l10n.composeRecipientsHint
                                : null,
                          ),
                          onChanged: _c.setRecipientInput,
                          // 桌面端：粘贴一行逗号分隔的地址后立刻拆开；
                          // 半截地址则看一眼建议条（与回车同一条路）。
                          onSubmitted: (_) => _commitOrSuggestion(suggestions),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_showSuggestions && suggestions.isNotEmpty)
          // 包进 `TextFieldTapRegion`：默认的 `groupId` 就是 `EditableText`，
          // 与上面那个 `TextField` 同组，于是点建议条算「点在输入框内」。
          //
          // **这是点得动的关键**：macOS 属桌面平台，`EditableText` 的
          // `_EditableTextTapOutsideAction` 在 **pointer-down** 就 `unfocus()`
          // （不等抬手），`_focus` 的监听随即把 `_showSuggestions` 置 false ——
          // 建议条在指针抬起之前就从树上摘掉了，`ActionChip` 的 `onTap`
          // 永远不会触发。只补 `onLongPress`/`onSecondaryTap` 之类都救不了，
          // 因为节点已经不在了。
          TextFieldTapRegion(
            child: _SuggestionBar(
              label: l10n.composeRecentRecipients,
              suggestions: suggestions,
              onPick: _pickSuggestion,
            ),
          ),
      ],
    );
  }
}

/// 最近联系人。横着排一行，点一下就加。
///
/// 不做「边打字边过滤的下拉浮层」：那个浮层会盖住主题与正文，
/// 而在写邮件这个场景里，用户想看的恰恰是下面那些内容。
class _SuggestionBar extends StatelessWidget {
  const _SuggestionBar({
    required this.label,
    required this.suggestions,
    required this.onPick,
  });

  final String label;
  final List<({String address, String name})> suggestions;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: <Widget>[
          Center(
            child: Text(
              label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          const SizedBox(width: 8),
          for (final item in suggestions)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                avatar: const Icon(Icons.history, size: 16),
                label: Text(
                  item.name.isEmpty
                      ? item.address
                      : '${item.name} · ${item.address}',
                ),
                onPressed: () => onPick(item.address),
              ),
            ),
        ],
      ),
    );
  }
}

/// 把收件人列表拼成一行只读文本（列表页/发件箱展示用）。
String describeRecipients(List<String> recipients) =>
    recipients.where(looksLikeEmail).join(', ');
