import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/avatar_colors.dart';
import '../../l10n/app_localizations.dart';
import 'compose_controller.dart';
import 'compose_field_row.dart';
import 'compose_text.dart';
import 'recipient_selection.dart';

/// 回车该收下什么。返回 null = 「别动补全，走原来的提交流程」。
///
/// 三条判据的顺序是有意的：
/// 1. 输入框里**已经是一个完整地址** → 收下它。粘贴一行地址再回车是最常见的
///    用法，这时候用户没在看下拉，抢着把第一条建议塞进去是替用户做主。
/// 2. 输入框里是半截（或空的）而补全列表里有东西 → 收下**第一条**。
///    这是「回车录入补全地址」那条路：敲 `zh` 回车得到 `zhang@…`。
///    下拉里还有一层键盘高亮（见 `_RecipientFieldState._onKey`），选中哪一条
///    由那一层决定；这个函数只回答「该不该动补全」。
/// 3. 都不是 → null，交给 `_commit()`：它会照旧报「地址不合法」。
///
/// 做成顶层纯函数（而不是 State 的方法）是为了能脱离 widget 测：这段判断错了
/// 的表现是「回车之后地址凭空变了一个」，而它没有别的手段能观察到。
@visibleForTesting
String? suggestionForCommit(
  String typed,
  List<({String address, String name})> suggestions,
) {
  if (looksLikeEmail(typed.trim())) return null;
  return suggestions.isEmpty ? null : suggestions.first.address;
}

/// 收件人输入：已确认的地址做成 chip，正在输入的那个和 chips 在**同一行流式
/// 排布**（Wrap），聚焦时下方弹出自动补全下拉。
///
/// 为什么不用 `RawAutocomplete`：它管的是「一个控件 + 一个下拉」，而这里需要
/// 的是**多值 + 自由输入**（用户完全可以不理补全直接敲一个没见过的地址），
/// 两者的状态机不一样。自己管更短，也更好测。
///
/// ## 三个容易踩的坑（都写在具体位置，这里给一张地图）
///
/// 1. **下拉不能是「输入框外的另一棵树」**：macOS 属桌面平台，`EditableText`
///    的 tap-outside 在 **pointer-down** 就 unfocus（不等抬手）。所以下拉
///    必须包在 `TextFieldTapRegion` 里（与输入框同组），否则行上的点击还没
///    抬手、焦点就已经丢了、面板已经被收掉，`onTap` 永远不触发。
/// 2. **下拉行不能抢焦点**：焦点一旦离开输入框，↑/↓/Tab/Esc 就全没了。行上
///    的 `InkWell` 因此 `canRequestFocus: false`（默认 true，点一下就会把焦点
///    从输入框搬走，键盘流随即失效）。
/// 3. **`OverlayPortalController.show/hide` 不能在 build 期间调**（框架里有
///    断言）。收/放统一由 `_syncOverlay` 排到帧后，见那里的注释。
class RecipientField extends ConsumerStatefulWidget {
  const RecipientField({super.key, required this.controller});

  final ComposeController controller;

  @override
  ConsumerState<RecipientField> createState() => _RecipientFieldState();
}

class _RecipientFieldState extends ConsumerState<RecipientField> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'recipient-input');

  /// 下拉浮层的锚点：贴在输入区（chips + 输入框）整个内容块的下沿。
  final LayerLink _link = LayerLink();
  final OverlayPortalController _panel = OverlayPortalController(
    debugLabel: 'recipient-suggestions',
  );

  /// 下拉内部的滚动控制器。**必须自己持有一个**：不传的话
  /// `SingleChildScrollView` 会去抢 `PrimaryScrollController`，而写邮件页正文
  /// 那边也挂着一个 —— `flutter test` 里会直接抛
  /// `The PrimaryScrollController is attached to more than one ScrollPosition`。
  final ScrollController _panelScroll = ScrollController();

  /// 高亮行的 key：键盘走位之后靠它把那一行 `ensureVisible` 进视口。
  ///
  /// 列表是**一口气建完**的（`SingleChildScrollView` + `Column`），高亮行恒在
  /// 树里，所以不需要按「行高 × 下标」估滚动偏移（估算在大字号下必偏）。
  final GlobalKey _highlightKey = GlobalKey();

  /// chip 的多选状态（纯逻辑在 `recipient_selection.dart`，这里只负责接线）。
  final RecipientSelection _selection = RecipientSelection();

  /// 下拉里当前高亮的行下标。0 = 刚打开时第一行就是亮的，回车 / ↓ 都在它上面。
  int _highlight = 0;

  /// 上一次渲染的补全列表指纹。列表一变（打字过滤、选走一条）就把高亮复位到
  /// 第一行 —— 不复位的话高亮可能停在一个已经不存在的下标上。
  String _suggestionsSignature = '';

  /// 用户按 Esc 关掉过下拉。**只抑制到下一次输入/重新聚焦为止**：
  /// 不抑制的话，只要焦点还在、补全还有内容，下一帧它就自己又冒出来
  /// （面板的可见性是「推导」出来的，不是一次性动作）。
  bool _panelSuppressed = false;

  /// 上一次「面板该不该开」的结论。避免每帧都排一个帧后回调。
  bool _overlayDesired = false;

  /// 输入框里那个地址不合法（提交时控制器拒收）。输入一变就清。
  bool _showInvalid = false;

  /// 下拉的宽度（= 输入区可用宽度，封顶 [kRecipientSuggestionMaxWidth]）。
  ///
  /// 在 `LayoutBuilder` 里量出来写进来：follower 的 child 是按 overlay 那层的
  /// 约束布局的，宽度只能在「面板自己」这边夹。
  double _panelWidth = 320;

  ComposeController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _panelScroll.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    if (_focus.hasFocus) {
      // 重新聚焦 = 用户又要挑人了：Esc 关掉那一次到此为止。
      setState(() => _panelSuppressed = false);
      return;
    }
    // 失焦时把输入框里那一截收下 —— 用户敲完地址直接点主题是很常见的，
    // 不这么做的话那个地址会在发送时被静默丢掉（或者更糟：被当成主题的
    // 一部分看着像已经写上了）。
    _commit();
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------ 提交

  /// 把输入框里那一截提交成收件人（回车、逗号、失焦时调）。
  ///
  /// 收不下的地址必须说出来，不能让用户以为写上了：一条 SnackBar（原有行为）
  /// 加一行常驻的内联红字。后者是为了「连续敲几个地址」的场景 —— SnackBar
  /// 会自己消失，而那一行会一直留着，直到用户改了输入。
  void _commit() {
    final rejected = _c.commitRecipientInput();
    final hadText = _text.text.isNotEmpty;
    if (hadText) _text.value = const TextEditingValue();
    // `commitRecipientInput` 只清了 state 里的那半截，补全列表还是上一次查询的
    // 结果；再走一次空查询，面板就能接着摆「最近联系人」（多选第二个收件人）。
    if (hadText) _c.setRecipientInput('');
    if (!mounted) return;
    setState(() {
      // 只有**真的提交了东西**才清 chip 选择：输入框空着时失焦是常事（切窗口、
      // 点正文），把它当成「用户转移到别处了」而丢掉选择，会让「选三枚、再点
      // 复制」在桌面平台上变成复制空串 —— 操作条自己就在失焦热区里。
      if (hadText) _selection.clear();
      _showInvalid = rejected.isNotEmpty;
    });
    if (rejected.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.of(context).composeBadRecipient(rejected.first),
        ),
      ),
    );
  }

  /// 回车：能补全就补全，否则按原样提交。
  ///
  /// 面板开着时用**高亮那一行**（用户已经把光标挪过去了）；面板被 Esc 关掉时
  /// 把补全当空处理 —— 用户刚说了「别替我选」，回车不该再替他选。
  void _commitOrSuggestion(List<({String address, String name})> suggestions) {
    final open = _panelWanted(suggestions);
    final source = open
        ? suggestions
        : const <({String address, String name})>[];
    final picked = suggestionForCommit(_text.text, source);
    if (picked == null) {
      _commit();
      return;
    }
    _pickSuggestion(source[_highlightFor(source)].address);
  }

  /// 收下一个地址（下拉里选的那一枚，或回车补全）。
  ///
  /// 走 `_c.addRecipient` 而不是 `setRecipients([...state.recipients, address])`：
  /// 后者拼的是 build 那一刻的快照，而这个动作发生在**当前**状态上 ——
  /// 输入框里刚被收下的那个地址会因此被丢掉（`build` 在两次提交之间未必重跑）。
  void _pickSuggestion(String address) {
    _c.addRecipient(address);
    _text.value = const TextEditingValue();
    _c.setRecipientInput('');
    setState(() {
      _selection.clear();
      _showInvalid = false;
      _panelSuppressed = false;
    });
    // 焦点留在输入框：连着挑几个收件人是常态（下拉也留着，见类注释）。
    _focus.requestFocus();
  }

  // ------------------------------------------------------------ 输入变化

  /// 文本变化：同步给控制器、拆粘贴串、清掉选择态。
  ///
  /// 拆地址放在**这里**而不是按键里，是因为「粘贴」根本不产生按键事件；而
  /// `,` 这种字符在不同键盘/输入法下有时也不走按键。相比起来，文本变化是所有
  /// 输入路径的必经之地。
  void _onChanged(String raw) {
    // 中文输入法组字期间（composing）不拆：拼音里本来就有空格，而且这时改写
    // controller 的文本会把候选框顶掉（composing range 一乱，刚敲的字就丢了）。
    final composing = _text.value.composing.isValid;
    var remainder = raw;
    var accepted = const <String>[];
    if (!composing) {
      final split = splitRecipientInput(raw);
      accepted = split.accepted;
      remainder = split.remainder;
    }
    if (accepted.isNotEmpty) {
      // 先收地址、再改输入框：反过来的话 `setRecipientInput(remainder)` 会把
      // 已经收下的那截也算成「待提交内容」，回车时又被提交一次。
      _c.addRecipients(accepted);
      _text.value = TextEditingValue(
        text: remainder,
        selection: TextSelection.collapsed(offset: remainder.length),
      );
    }
    _c.setRecipientInput(remainder);
    setState(() {
      // 打字 = 用户要接着输入，chips 的选择态让位（与文本选择的心智一致）。
      _selection.clear();
      _showInvalid = false;
      _panelSuppressed = false;
      _highlight = 0;
    });
  }

  /// 输入框被点：等同于点空白 —— 清掉 chip 选择，光标回到输入框里。
  void _onInputTap() {
    if (_selection.isEmpty) return;
    setState(() => _selection.clear());
  }

  /// 点整行（label / 右侧空白）：聚焦输入并清空选择。
  void _tapRow() {
    _focus.requestFocus();
    if (_selection.isNotEmpty) setState(() => _selection.clear());
  }

  // ------------------------------------------------------------ chip 手势

  void _onChipTap(int index) {
    final keyboard = HardwareKeyboard.instance;
    setState(() {
      if (keyboard.isShiftPressed) {
        _selection.extendTo(index);
      } else if (keyboard.isMetaPressed || keyboard.isControlPressed) {
        _selection.toggle(index);
      } else {
        _selection.selectSingle(index);
      }
    });
    // 选完把焦点请回输入框：键盘是连着用的（←/→ 扩缩、退格删除）。
    // 不这么做的话，点第二枚 chip 时第一枚的选择就停在「焦点不在」的状态里。
    _focus.requestFocus();
  }

  void _removeChip(String address) {
    _c.removeRecipient(address);
    setState(_selection.clear);
  }

  void _removeSelected(List<String> recipients) {
    final addresses = _selection.addressesFrom(recipients);
    setState(_selection.clear);
    if (addresses.isEmpty) return;
    _c.removeRecipients(addresses);
  }

  Future<void> _copySelected(List<String> recipients) async {
    final addresses = _selection.addressesFrom(recipients);
    if (addresses.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: addresses.join(', ')));
    if (!mounted) return;
    // 说的是「已复制」而不是「复制地址」：操作条上那颗按钮就叫后者，
    // 把按钮文案当结果提示冒出来，看着像按钮弹了个对话框。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).copied)),
    );
  }

  // -------------------------------------------------------------- 键盘

  KeyEventResult _onKey(
    FocusNode node,
    KeyEvent event,
    List<String> recipients,
    List<({String address, String name})> suggestions,
  ) {
    // 抬起事件不用管；按下与**按住重复**（方向键连发）都要处理。
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final hasText = _text.text.isNotEmpty;
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isMetaPressed || keyboard.isControlPressed;

    // ① 下拉开着时 ↑/↓/Tab/Esc 归下拉 —— 与输入框里有没有字**无关**：
    //    边打字边挑补全正是这个下拉的主用法（这时输入框里必然有字）。
    //    这也解释了需求里「输入框有字时方向键交还 TextField」为什么只对
    //    ←/→ 成立：↑/↓ 在单行输入框里本来就没有文本语义。
    if (_panelWanted(suggestions)) {
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveHighlight(1, suggestions);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveHighlight(-1, suggestions);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab) {
        _pickHighlighted(suggestions);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        // 第一级 Esc：只关下拉。**必须在这里吃掉事件**，否则它会继续冒泡到
        // 页面那层 `Shortcuts`，直接把写邮件页关了 —— 用户想取消的只是补全。
        setState(() => _panelSuppressed = true);
        return KeyEventResult.handled;
      }
    }

    // ② 第二级 Esc：清空 chip 选择。选择也没有时才交回页面（= 关页）。
    if (key == LogicalKeyboardKey.escape) {
      if (_selection.isEmpty) return KeyEventResult.ignored;
      setState(_selection.clear);
      return KeyEventResult.handled;
    }

    // ③ 打字的中途只认「收下这个地址」：逗号 / 分号（半角）。
    //    其余按键一律交还 TextField —— chip 多选不能抢走文本编辑的手势。
    if (hasText) {
      if (key == LogicalKeyboardKey.comma ||
          key == LogicalKeyboardKey.semicolon) {
        // 组字期间的逗号可能是候选词的一部分，不能当成地址分隔符。
        if (_text.value.composing.isValid) return KeyEventResult.ignored;
        _commit();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // ④ 输入框空着：方向键 / 退格 / 删除 / ⌘A / ⌘C 属于 chip 选择。
    if (key == LogicalKeyboardKey.comma ||
        key == LogicalKeyboardKey.semicolon) {
      // 空输入时逗号没有语义，交给 TextField 原样插入。
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.backspace) {
      if (_selection.isEmpty) {
        if (recipients.isEmpty) return KeyEventResult.ignored;
        // 第一次退格只是**选中**最后一个（不删）—— 这是这类控件的通用手势。
        // 直接删的话，用户想删的是「刚打完的那个字」，结果少了一个收件人。
        setState(() => _selection.selectLast(recipients.length));
        return KeyEventResult.handled;
      }
      _removeSelected(recipients);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete) {
      if (_selection.isEmpty) return KeyEventResult.ignored;
      _removeSelected(recipients);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (recipients.isEmpty) return KeyEventResult.ignored;
      setState(() => _selection.arrowLeft(recipients.length));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_selection.isEmpty) return KeyEventResult.ignored;
      setState(() => _selection.arrowRight(recipients.length));
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyA) {
      if (recipients.isEmpty) return KeyEventResult.ignored;
      setState(() => _selection.selectAll(recipients.length));
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyC) {
      if (_selection.isEmpty) return KeyEventResult.ignored;
      unawaited(_copySelected(recipients));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -------------------------------------------------------------- 下拉

  /// 下拉此刻该不该开。**推导**而非动作：聚焦、补全内容、Esc 抑制、路由是否
  /// 仍然是当前页 —— 任何一项变了，下一帧的可见性自然跟着变。
  bool _panelWanted(List<({String address, String name})> suggestions) {
    if (suggestions.isEmpty) return false;
    if (!_focus.hasFocus) return false;
    if (_panelSuppressed) return false;
    // 上面压了新的一页时不开：面板挂在 Navigator 那层 Overlay 上，push 之后
    // 它只是被盖住（offstage），pop 回来会「自己冒出来」—— 看起来像一张忘了
    // 关的浮层。
    return ModalRoute.of(context)?.isCurrent ?? true;
  }

  /// 把「该不该开」落到 OverlayPortal 上。
  ///
  /// **不能在 build 里直接 `show()` / `hide()`**：`_OverlayPortalState.show` 有
  /// 一条「schedulerPhase != persistentCallbacks」的断言，构建期间调用必抛。
  /// 排到帧后即可 —— 所有触发路径（聚焦变化、补全异步回来、Esc、路由变化）
  /// 最后都收敛到 build 这一次推导上，不需要每处各调一次，也就不会出现
  /// 「一个地方忘了 hide」的漏网。
  void _syncOverlay(bool show) {
    if (_overlayDesired == show) return;
    _overlayDesired = show;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final wanted = _overlayDesired;
      if (wanted && !_panel.isShowing) {
        _panel.show();
      } else if (!wanted && _panel.isShowing) {
        _panel.hide();
      }
    });
  }

  int _highlightFor(List<({String address, String name})> suggestions) {
    if (suggestions.isEmpty) return 0;
    return _highlight.clamp(0, suggestions.length - 1);
  }

  void _moveHighlight(
    int delta,
    List<({String address, String name})> suggestions,
  ) {
    if (suggestions.isEmpty) return;
    setState(() {
      _highlight = (_highlightFor(suggestions) + delta).clamp(
        0,
        suggestions.length - 1,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _highlightKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  void _pickHighlighted(List<({String address, String name})> suggestions) {
    if (suggestions.isEmpty) return;
    _pickSuggestion(suggestions[_highlightFor(suggestions)].address);
  }

  /// 补全列表变了就把高亮复位到第一行。
  ///
  /// 在 build 里改这个字段是安全的：它只影响本次 build 的渲染结果，不触发
  /// 重建（`setState` 才会）。写成 `didChangeDependencies` 之类的地方反而
  /// 看不到「这一次列表是什么」。
  void _syncHighlight(List<({String address, String name})> suggestions) {
    final signature = suggestions.map((s) => s.address).join('\u0000');
    if (signature == _suggestionsSignature) return;
    _suggestionsSignature = signature;
    _highlight = 0;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 没上 `ConsumerWidget` 而是直接 `ref.watch`：这个控件**渲染用的**就是
    // state 里的收件人，所以必须 watch（`_c.state` 那种读法只适合事件回调里
    // 顺手取一次快照，用在这里会永远不刷新）。
    final state = ref.watch(composeControllerProvider(_c.args));
    final recipients = state.recipients;
    // 列表可能在两次 build 之间被别人改过（删草稿、发送成功清空、恢复草稿），
    // 选择里那些下标要先夹回当前长度，否则高亮会飘到空处、删除会错位。
    _selection.reconcile(recipients.length);
    final suggestions = state.recipientSuggestions
        .where(
          (s) => !state.effectiveRecipients.any(
            (e) => e.toLowerCase() == s.address.toLowerCase(),
          ),
        )
        .toList(growable: false);
    _syncHighlight(suggestions);
    _syncOverlay(_panelWanted(suggestions));

    return OverlayPortal(
      controller: _panel,
      overlayChildBuilder: (overlayContext) =>
          _buildPanel(overlayContext, suggestions),
      // 整块（chips + 输入框 + 操作条 + 内联错误）都算「输入框内部」。
      //
      // 桌面平台点输入框以外的地方会在 **pointer-down** 就 unfocus（不等抬手），
      // 而失焦会走 `_commit()`，它顺手清空 chip 选择 —— 于是「点操作条上的复制」
      // 会先丢选择、再复制一个空串（在 macOS 上必现，在 Android/测试默认平台上
      // 完全看不出来）。`TextFieldTapRegion` 的 groupId 默认就是 `EditableText`，
      // 与输入框同组，所以这里包一层就够了。（下拉那棵树也包了，见 `_buildPanel`。）
      child: TextFieldTapRegion(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ComposeFieldRow(
              label: l10n.composeTo,
              onTap: _tapRow,
              child: CompositedTransformTarget(
                link: _link,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _panelWidth = math.min(
                      constraints.maxWidth,
                      kRecipientSuggestionMaxWidth,
                    );
                    return _buildFlow(
                      context,
                      l10n,
                      recipients,
                      suggestions,
                      available: constraints.maxWidth,
                    );
                  },
                ),
              ),
            ),
            // 选择操作条：只在有选中时出现，高度很小（32），不挤占正文。
            if (_selection.isNotEmpty)
              _SelectionBar(
                key: const ValueKey('recipient-selection-bar'),
                count: _selection.length,
                onCopy: () => unawaited(_copySelected(recipients)),
                onRemove: () => _removeSelected(recipients),
              ),
            // 非法地址的内联错误：SnackBar 会消失，这一行会留到用户改输入为止。
            if (_showInvalid)
              Padding(
                key: const ValueKey('recipient-invalid'),
                padding: const EdgeInsets.fromLTRB(
                  16 + kComposeFieldLabelWidth + kComposeFieldGap,
                  0,
                  16,
                  4,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.error_outline,
                      size: 14,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        l10n.composeRecipientInvalid,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// chips + 输入框的流式排布。
  ///
  /// 宽度是**算出来的**：`TextField` 默认吃满可用宽度，那样它永远自成一行，
  /// 「紧跟最后一个 chip」就无从谈起。所以按当前文字量一个宽度，夹在
  /// `[kRecipientInputMinWidth, 可用宽度]` 之间。
  Widget _buildFlow(
    BuildContext context,
    AppLocalizations l10n,
    List<String> recipients,
    List<({String address, String name})> suggestions, {
    required double available,
  }) {
    final theme = Theme.of(context);
    final inputWidth = _inputWidth(
      context,
      available,
      hasChips: recipients.isNotEmpty,
    );
    return Wrap(
      spacing: kRecipientChipGap,
      runSpacing: kRecipientChipGap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        for (var i = 0; i < recipients.length; i++)
          _RecipientChip(
            key: ValueKey('recipient-chip-${recipients[i]}'),
            address: recipients[i],
            selected: _selection.contains(i),
            deleteLabel: l10n.composeRemoveRecipient,
            onTap: () => _onChipTap(i),
            onDelete: () => _removeChip(recipients[i]),
          ),
        SizedBox(
          width: inputWidth,
          child: Focus(
            onKeyEvent: (node, event) =>
                _onKey(node, event, recipients, suggestions),
            child: TextField(
              key: const ValueKey('recipient-input'),
              controller: _text,
              focusNode: _focus,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              style: theme.textTheme.bodyMedium,
              // 回车**只走 onSubmitted**（IME 的 done action）。
              //
              // 不要在 `_onKey` 里再认一次 Enter：桌面上一次真实的 Enter 会
              // 同时送来按键事件**和** done action（flutter/flutter #119268），
              // 两条路都接就会提交两次 —— 第二次时输入框已经空了，于是
              // 「回车收下地址」会变成「回车又补全进来一个地址」。
              //
              // 同时**必须**给一个空的 `onEditingComplete`：默认实现会按
              // `textInputAction: next` 把焦点挪到主题栏，那样这一行之后再也
              // 收不到 ↑/↓、Esc（焦点不在）。空回调正好把默认行为顶掉，
              // 提交逻辑全在 onSubmitted 里。
              onEditingComplete: () {},
              onChanged: _onChanged,
              onSubmitted: (_) => _commitOrSuggestion(suggestions),
              onTap: _onInputTap,
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                // 上下各 5：bodyMedium 的行高 20 + 10 = 30 = `ComposeFieldRow`
                // 的首行高度（`kComposeFieldLineHeight`），label 的对齐基准就是
                // 按这个约定算的（主题行、发件人那一行用的也是同一个值）。
                contentPadding: const EdgeInsets.fromLTRB(
                  0,
                  kComposeFieldContentPadding,
                  0,
                  kComposeFieldContentPadding,
                ),
                hintText: recipients.isEmpty
                    ? l10n.composeRecipientsHint
                    : null,
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 输入框该多宽。
  ///
  /// - **一个 chip 都没有时占满整行**（hint 要摆得下，光标也不能缩在一角）。
  ///   开始打字之后**不缩**：边打字边把框从整行缩成一小截，光标会横向跳一大格，
  ///   是最典型的「控件在跟我抢」的坏手感。
  /// - 有 chip 时按文字量算，于是它会挤在最后一个 chip 右边；内容变宽就跟着
  ///   变宽，宽到这一行放不下时 `Wrap` 自然把它折到下一行。
  double _inputWidth(
    BuildContext context,
    double available, {
    required bool hasChips,
  }) {
    if (!hasChips) return available;
    final painter = TextPainter(
      text: TextSpan(
        text: _text.text,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    // +2 是光标那一格：不留的话光标会贴在框沿上，看不见。
    final wanted = painter.width + 2;
    return math.min(available, math.max(kRecipientInputMinWidth, wanted));
  }

  Widget _buildPanel(
    BuildContext overlayContext,
    List<({String address, String name})> suggestions,
  ) {
    final theme = Theme.of(overlayContext);
    final query = _text.text.trim();
    final highlighted = _highlightFor(suggestions);
    final maxHeight = math.min(
      kRecipientSuggestionMaxHeight,
      MediaQuery.sizeOf(overlayContext).height * 0.4,
    );
    return CompositedTransformFollower(
      link: _link,
      // 触发区还没画过时不画面板（默认会把它摆在原点）。
      showWhenUnlinked: false,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(0, 6),
      child: Align(
        alignment: Alignment.topLeft,
        // 与输入框同组：桌面端 `EditableText` 的 tap-outside 在 pointer-down
        // 就 unfocus，不同组的话点下拉 = 先失焦（面板收掉、半截被提交），
        // 行上的 onTap 永远等不到抬手。见类注释坑 1。
        child: TextFieldTapRegion(
          child: Material(
            key: const ValueKey('recipient-suggestions'),
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            color: theme.colorScheme.surfaceContainerHigh,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: _panelWidth,
                maxHeight: maxHeight,
              ),
              child: SizedBox(
                width: _panelWidth,
                child: SingleChildScrollView(
                  controller: _panelScroll,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (var i = 0; i < suggestions.length; i++)
                        // 高亮行单独挂一个 GlobalKey 供 `ensureVisible`；行的
                        // 查找 key 不跟着变，测试与语义标签都按地址定位。
                        KeyedSubtree(
                          key: i == highlighted ? _highlightKey : null,
                          child: _SuggestionRow(
                            key: ValueKey(
                              'recipient-suggestion-'
                              '${suggestions[i].address}',
                            ),
                            address: suggestions[i].address,
                            name: suggestions[i].name,
                            query: query,
                            highlighted: i == highlighted,
                            onHover: () {
                              if (i == highlighted) return;
                              setState(() => _highlight = i);
                            },
                            onTap: () =>
                                _pickSuggestion(suggestions[i].address),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 补全下拉的最大宽度：桌面窗口再宽，一条邮箱地址也不需要 800px 的行。
const double kRecipientSuggestionMaxWidth = 420;

/// 补全下拉的最大高度（还会被屏高的 40% 再夹一次）。
const double kRecipientSuggestionMaxHeight = 320;

/// 下拉每一行的最小高度。行高**不是定高**：文本放大到装不下时让行自然长高，
/// 定高会在大字号下把字裁掉。
const double kRecipientSuggestionRowHeight = 44;

/// chips 之间、以及 chip 与输入框之间的间距。
const double kRecipientChipGap = 6;

/// 输入框在有 chip 时的最小宽度：再窄就只剩一条缝，用户不知道该往哪敲。
const double kRecipientInputMinWidth = 96;

/// 选中 N 个收件人时的操作条。
///
/// 高度刻意压到 32 以内：它是**临时**的（选完就消失），不该把正文往下顶一大截。
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    super.key,
    required this.count,
    required this.onCopy,
    required this.onRemove,
  });

  final int count;
  final VoidCallback onCopy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      // 左边界与输入区对齐（label 列之后）。
      padding: const EdgeInsets.fromLTRB(
        16 + kComposeFieldLabelWidth + kComposeFieldGap,
        0,
        16,
        4,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              l10n.composeSelectedCount(count),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('recipient-copy'),
            onPressed: onCopy,
            style: _barButtonStyle,
            child: Text(l10n.composeCopyAddresses),
          ),
          const SizedBox(width: 4),
          TextButton(
            key: const ValueKey('recipient-remove'),
            onPressed: onRemove,
            style: _barButtonStyle,
            child: Text(l10n.composeRemoveSelected),
          ),
        ],
      ),
    );
  }

  static final ButtonStyle _barButtonStyle = TextButton.styleFrom(
    minimumSize: const Size(0, 28),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    visualDensity: VisualDensity.compact,
  );
}

/// 一枚收件人 chip。
///
/// 不用 `InputChip`：它把「点击整枚」「删除按钮」「选中态」三件事的语义与
/// 尺寸绑死在 Material 的默认值上，而这里需要
/// 1. 整枚的点击要能读到 ⌘/Shift 修饰键（→ 得自己套手势）；
/// 2. 选中态要**明显**（主题色底 + 描边），不是 Material 默认那颗小勾；
/// 3. 删除按钮要能单独报读屏标签。
/// 自绘这一小坨比跟 `ChipAttributes` 的默认行为较劲短得多。
class _RecipientChip extends StatelessWidget {
  const _RecipientChip({
    super.key,
    required this.address,
    required this.selected,
    required this.deleteLabel,
    required this.onTap,
    required this.onDelete,
  });

  final String address;
  final bool selected;
  final String deleteLabel;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: address,
      onTap: onTap,
      child: Material(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          // 不给键盘焦点：焦点必须留在输入框，否则 ↑/↓/Esc/退格全失效。
          canRequestFocus: false,
          excludeFromSemantics: true,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ExcludeSemantics(
                  child: Text(
                    address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: selected ? scheme.onPrimaryContainer : null,
                    ),
                  ),
                ),
                // 删除按钮：单独成节点、单独报读屏标签（「移除」）。整枚 chip
                // 的语义里再塞一句「点这里删除」的话，读屏会把它念两遍。
                Semantics(
                  button: true,
                  label: deleteLabel,
                  onTap: onDelete,
                  // 悬停给一句提示：这枚小叉只有 14px，光看图标不一定敢点
                  // （尤其是没选中态时它和整枚 chip 的边框混在一起）。
                  // `excludeFromSemantics` 是必须的 —— 读屏标签已经挂在外面
                  // 那层 `Semantics` 上了，不加的话同一句会念两遍。
                  child: Tooltip(
                    message: deleteLabel,
                    excludeFromSemantics: true,
                    waitDuration: const Duration(milliseconds: 600),
                    child: InkResponse(
                      onTap: onDelete,
                      excludeFromSemantics: true,
                      radius: 12,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        // **不要换成 `Icons.close`**：写邮件页 AppBar 上那个
                        // 「关掉本页」按钮用的就是它，而 `find.byIcon(Icons.close)`
                        // 是按 IconData 匹配的 —— 有收件人 chip 的页面上会一次
                        // 命中两枚，几处既有测试（`compose_body_flush_test`
                        // 回复模式、`compose_draft_open_test`）就变成了 ambiguous。
                        // `Icons.clear` 是同一个 X 字形、另一个 code point。
                        child: Icon(
                          Icons.clear,
                          size: 14,
                          color: selected
                              ? scheme.onPrimaryContainer.withValues(alpha: 0.8)
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 下拉里的一行：头像 + 姓名/地址（匹配部分高亮）。
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    super.key,
    required this.address,
    required this.name,
    required this.query,
    required this.highlighted,
    required this.onTap,
    required this.onHover,
  });

  final String address;
  final String name;

  /// 用户已经敲进来的那截文字，用来在行里加高亮。
  final String query;

  /// 键盘/鼠标当前停在这一行（回车会选它）。与「已经选中的收件人」不是一件事。
  final bool highlighted;

  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final nameStyle = theme.textTheme.bodyMedium;
    final addressStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final hitStyle = TextStyle(
      color: scheme.primary,
      fontWeight: FontWeight.w700,
    );
    final label = name.isEmpty ? address : '$name <$address>';
    return Semantics(
      container: true,
      button: true,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: MouseRegion(
          onHover: (_) => onHover(),
          child: Material(
            color: highlighted
                ? scheme.surfaceContainerHighest
                : Colors.transparent,
            child: InkWell(
              onTap: onTap,
              canRequestFocus: false,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: kRecipientSuggestionRowHeight,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: <Widget>[
                      // 首字母头像：与邮件列表/详情里的发件人头像同一套取色，
                      // 「同一个人永远同一个颜色」这条在补全里同样成立。
                      CircleAvatar(
                        radius: 13,
                        backgroundColor: AvatarColors.of(address),
                        child: Text(
                          AvatarColors.initial(name.isEmpty ? address : name),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (name.isNotEmpty)
                              Text.rich(
                                TextSpan(
                                  children: _matchSpans(
                                    name,
                                    query,
                                    nameStyle,
                                    hitStyle,
                                  ),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            Text.rich(
                              TextSpan(
                                children: _matchSpans(
                                  address,
                                  query,
                                  addressStyle,
                                  hitStyle,
                                ),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 把 [text] 里命中 [query] 的部分切成单独一段（加粗 + 主题色）。
///
/// 只做**忽略大小写的子串**匹配，不做模糊/拼音匹配 —— 补全的候选本身是本地
/// 按 LIKE 查出来的，这里加亮同一段文字，用户才能对上「我敲的这几个字被认成
/// 了哪个联系人」。
List<TextSpan> _matchSpans(
  String text,
  String query,
  TextStyle? base,
  TextStyle hit,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return <TextSpan>[TextSpan(text: text, style: base)];
  final haystack = text.toLowerCase();
  final spans = <TextSpan>[];
  var cursor = 0;
  while (cursor < haystack.length) {
    final at = haystack.indexOf(needle, cursor);
    if (at < 0) break;
    if (at > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, at), style: base));
    }
    spans.add(
      TextSpan(
        text: text.substring(at, at + needle.length),
        style: base?.merge(hit) ?? hit,
      ),
    );
    cursor = at + needle.length;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: base));
  }
  return spans;
}

/// 把收件人列表拼成一行只读文本（列表页/发件箱展示用）。
String describeRecipients(List<String> recipients) =>
    recipients.where(looksLikeEmail).join(', ');
