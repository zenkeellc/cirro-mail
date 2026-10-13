import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_quill/flutter_quill.dart' as q;

import 'slash_actions.dart';
import 'slash_command.dart';

/// 斜杠菜单的**挂载**：盯着光标，判定该不该弹，弹出过滤后的条目。
///
/// 判定逻辑全在 [SlashCommand] 里（纯函数、可单测），这里只做三件事：
/// 听 controller、把菜单摆到光标下方、执行条目**之前**先清掉 `/query`。
///
/// 条目定义与过滤在 [slashEntries] / [filterSlashEntries]（`slash_actions.dart`）——
/// 早先渲染也共用底部「+」那个面板（`insert_menu.dart`），面板删掉后改成这里
/// 自带一列渲染（见 [_SlashMenuList]：**键名沿用 `insert-<item.name>`**）。
class SlashMenuHost extends StatefulWidget {
  const SlashMenuHost({
    super.key,
    required this.controller,
    required this.slashContext,
    required this.child,
    this.editorFocusNode,
    this.allowAi = true,
    this.menuWidth = 240,
    this.maxHeight = 260,
  });

  final q.QuillController controller;

  /// 条目执行时手头有的东西。由页面构造（它才握着额度与面板）。
  final SlashContext slashContext;

  /// 正文编辑器。
  final Widget child;

  /// 正文编辑器的 [FocusNode]。
  ///
  /// 为什么需要它：`HardwareKeyboard` 的处理器在**所有**焦点节点之前跑
  /// （见 [SlashMenuHostState.initState] 的说明），于是 `_onKey` 只凭自己
  /// 分不清「这次按键到底是谁的」—— 不做焦点判断的话，用户在**主题输入框**
  /// 里敲回车也会被菜单吃掉（实测：斜杠被清掉、正文里凭空插进一张表格）。
  ///
  /// **默认为 null 时退化成旧行为**（完全不做焦点判断）：只有调用方真的把
  /// 编辑器的 FocusNode 传进来，焦点判据才生效。这样已有调用方不被破坏，
  /// 新的写信页（E5）再显式接线。
  final FocusNode? editorFocusNode;

  /// 允许出现 AI 起草条目吗。没配 AI 时传 false —— 与浮动工具栏上
  /// 「没有回调就不显示 AI 按钮」是同一条规矩。
  final bool allowAi;

  final double menuWidth;
  final double maxHeight;

  @override
  State<SlashMenuHost> createState() => SlashMenuHostState();
}

class SlashMenuHostState extends State<SlashMenuHost> {
  SlashTrigger? _trigger;
  var _index = 0;

  /// 当前该显示的条目（已按 `/` 后面敲的字过滤）。
  ///
  /// 过滤本身在 [filterSlashEntries] —— 底部面板也用同一份，两个入口才不会
  /// 各漏各的（那个函数的注释里写了为什么）。
  List<SlashActionEntry> get _entries {
    final trigger = _trigger;
    if (trigger == null) return const <SlashActionEntry>[];
    return filterSlashEntries(trigger.query, allowAi: widget.allowAi);
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    // 焦点离开正文编辑器时也要 `_sync` 一次（它会把菜单收起来）。光靠
    // controller 的变化不够 —— 「鼠标点主题框」这个动作不一定带来文档变化，
    // 而菜单会一直挂在正文上，接着在主题框里敲回车就会被它吃掉。
    widget.editorFocusNode?.addListener(_sync);
    // 挂载时也要判一次：页面可能是**带着一个现成的文档**打开的（草稿、引用块），
    // 而那时触发器已经在文档里了（比如草稿最后一行就是个「/」），光靠 listener
    // 等不到下一次变化。放到帧后是因为 `_sync` 会 `setState`。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
    // 键盘用 `HardwareKeyboard.addHandler` 而**不是** `Shortcuts`/`Focus.onKeyEvent`：
    // 后者要抢在编辑器前面拿到事件，而编辑器自己也在抢 —— 谁先拿到取决于
    // widget 树的深度，很不稳。`HardwareKeyboard` 的处理器在**所有**焦点节点
    // 之前跑，于是「菜单开着时上下键选条目」这件事是确定的。
    // 代价是**要在没开菜单时立刻放手**（返回 false），见 [handleKey]。
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    widget.editorFocusNode?.removeListener(_sync);
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  /// `HardwareKeyboard.addHandler` 要的回调是 `bool Function(KeyEvent)` ——
  /// **不是** `KeyEventResult`（那个枚举在 `widgets` 里，是给焦点树用的）。
  /// 返回 true = 这次按键被吃掉了。
  ///
  /// 焦点判据在 [handleKey] 里，`_onKey` 只负责把「主焦点现在在哪」这件事
  /// 读出来传进去 —— `HardwareKeyboard` 的处理器拿不到 `FocusManager`，
  /// 而 `handleKey` 是纯逻辑，在测试里不能去读全局状态。
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    return handleKey(
      event.logicalKey,
      isShiftDown: HardwareKeyboard.instance.isShiftPressed,
      primaryFocus: FocusManager.instance.primaryFocus,
    );
  }

  void _sync() {
    final next = SlashCommand.detect(widget.controller);
    // 焦点离开了编辑器就把菜单收起来。
    //
    // 为什么不在「主焦点变化」时立刻收（比如给 FocusManager 挂监听）：`detect`
    // 只在 controller 变化时才算，而「点主题框」这个动作通常会连带一次
    // controller 变化（编辑器失焦会收敛一下选区/输入连接），`_sync` 因此会被
    // 带跑。这条判据是**兜底**：哪怕某次点击不触发 controller 变化，下一次
    // 任何变化也会把挂着的菜单收掉。
    //
    // 判据缺省（`editorFocusNode == null`）时不判焦点 —— 与 [handleKey] 同一套
    // 退化规则，免得破坏没接线焦点节点的调用方。
    final focusLeftEditor = widget.editorFocusNode != null &&
        !_hasEditorFocus(FocusManager.instance.primaryFocus);
    final shown = focusLeftEditor ? null : next;
    if (shown?.start != _trigger?.start || shown?.query != _trigger?.query) {
      // 条目集变了要把高亮拉回第一项 —— 否则过滤之后 `_index` 可能落在
      // 已经不存在的位置上，回车会执行一个看不见的条目。
      _index = 0;
    }
    if (shown == null && _trigger == null) return;
    setState(() => _trigger = shown);
  }

  /// 主焦点是不是就在正文编辑器上。
  ///
  /// 判据是「主焦点就是那个节点、或是它的**后代**」：编辑器内部还有自己的焦点
  /// 节点（`QuillRawEditor` 会 requestFocus 到更靠里的那个），所以页面传进来的
  /// 通常只是编辑器那一层的 [FocusNode]，真正的 `primaryFocus` 是它的后代 ——
  /// `ancestors` 从主焦点往上走能碰到它。反过来「主焦点是编辑器的祖先」不算
  /// —— 那正是「焦点跑去别的输入框」时会出现的形状，放行它等于没判。
  ///
  /// 不用 `node.hasFocus`：它只回答「编辑器那一层有没有焦点」，而这个函数要
  /// 回答的是「这次按键该归编辑器吗」。测试里也能看出区别 —— 编辑器明明还
  /// 持有焦点、但主焦点已经被搬到别处时，应该判「不在编辑器」。
  bool _hasEditorFocus(FocusNode? primaryFocus) {
    final node = widget.editorFocusNode;
    if (node == null) return true;
    if (primaryFocus == null) return true;
    return primaryFocus == node || primaryFocus.ancestors.contains(node);
  }

  /// 清掉 `/query` 并收起菜单。
  ///
  /// **点条目和敲回车两条路都要先走这里**，顺序不能反：动作里有插图、开面板
  /// 这类要等用户下一步的操作，清触发器必须**立刻**发生 —— 否则用户会看到
  /// `/表格` 跟着新插入的表格一起留在文档里。
  void _dismiss({required bool clearTrigger}) {
    final trigger = _trigger;
    if (trigger != null && clearTrigger) {
      SlashCommand.clearTrigger(widget.controller, trigger);
    }
    if (_trigger != null) setState(() => _trigger = null);
  }

  /// 键盘回车选中一个条目。
  Future<void> _run(SlashActionEntry entry) async {
    _dismiss(clearTrigger: true);
    // 焦点还回编辑器：不还的话用户接着敲字会发现「按了没反应」。
    widget.slashContext.focusNode.requestFocus();
    await entry.run(widget.slashContext);
  }

  void _move(int delta) {
    final entries = _entries;
    if (entries.isEmpty) return;
    // **不回绕**：见 [handleKey] 里 arrowUp/arrowDown 两条的说明。
    final next = (_index + delta).clamp(0, entries.length - 1);
    setState(() => _index = next);
  }

  /// 键盘事件的处理。**公开是为了能单测** —— 菜单开着时的上下键与回车，
  /// 是「按了没反应」「按错条目」这类问题的全部来源。
  ///
  /// 返回 true 表示「这次按键我吃了」；false 表示「让编辑器照常处理」。
  /// [isShiftDown] 传进来而不是现读：`handleKey` 是纯逻辑，读全局键盘状态
  /// 会让它在测试里不可控。[primaryFocus] 同理 —— 由 [_onKey] 从
  /// `FocusManager` 读出后传进来。
  ///
  /// **焦点不在正文编辑器上时一个键都不吃**：`HardwareKeyboard` 的处理器在
  /// 所有焦点节点之前跑（见 `initState`），不判焦点的话，用户在主题输入框里
  /// 敲回车会被这里吃掉 —— 实测后果是斜杠被清掉、正文里凭空插进一张表格。
  bool handleKey(
    LogicalKeyboardKey key, {
    required bool isShiftDown,
    FocusNode? primaryFocus,
  }) {
    if (_trigger == null) return false;
    // `primaryFocus == null`（比如没有行焦点）时**不**当作「焦点走了」：
    // 纯逻辑测试不挂 widget 树，那时它天然是 null，把 null 判成「焦点不在
    // 编辑器」会让所有键盘用例失效。真正的「焦点在别处」一定给得出一个
    // 具体节点。
    if (primaryFocus != null && !_hasEditorFocus(primaryFocus)) return false;
    switch (key) {
      case LogicalKeyboardKey.escape:
        setState(() => _trigger = null);
        return true;
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return true;
      case LogicalKeyboardKey.arrowUp:
        // **两端停住，不回绕**。Dart 的 `%` 对负数返回非负（`-1 % 12 == 11`），
        // 原实现用 `(_index + delta) % length` 于是在第 0 条按↑会直接跳到
        // **最后一条**，再按回车就执行了它（可能是「AI 起草」这种会开面板的
        // 动作）。回绕在这里的收益很小（菜单只有十几条、用户要么停在顶/底、
        // 要么直接敲字过滤），而误触发的代价明显更高，所以选「停住」。
        _move(-1);
        return true;
      case LogicalKeyboardKey.enter:
        // Shift+Enter 是「换行」这个固定语义，别抢。
        if (isShiftDown) return false;
        // Enter 在没有候选时**不**吃键：那时用户多半是在换行。
        final entries = _entries;
        if (entries.isEmpty) return false;
        _run(entries[_index.clamp(0, entries.length - 1)]);
        return true;
      default:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final trigger = _trigger;
    final entries = _entries;
    final menuOpen = trigger != null && entries.isNotEmpty;
    // **永远返回同一个 Stack 形状**，菜单不开时只是少一个覆盖物。
    //
    // 原来是「不开菜单 `return widget.child`；开着返回 `Stack([child, …])`」，
    // 于是 child 在「唯一子节点」与「Stack 第 0 个子节点」之间换了位置 ——
    // Flutter 判定结构变化、整棵子树重新 inflate。E5 里 child 就是
    // `MailQuillEditor`：每弹一下 `/`，`_MailQuillEditorState` 的
    // `ScrollController` 与 `GlobalKey<EditorState>` 都被 dispose 重建，
    // 正文滚动位置当场丢失、浮动工具栏的定位依据（renderEditor）也换了新。
    // 把 child 钉死在 Stack 的第 0 个位置上，这些就都不会发生。
    return Stack(
      children: [
        widget.child,
        if (menuOpen)
          Positioned(
            left: 12,
            // **不给定 `right`**：给了的话宽度就是「正文区宽度 - 24」，菜单会被
            // 拉成一条横贯屏幕的长条 —— 而斜杠菜单是一列。
            // 宽度由 `ConstrainedBox` 的 `maxWidth` 定，位置由 `Align` 靠左。
            top: 8,
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: widget.menuWidth,
                  // **这一条必须真的生效**：`top` 之外不给定 `bottom`/`height`
                  // 时，`RenderStack` 给子节点的高度约束是 `0..infinity`，
                  // 于是只有 `maxHeight` 能把它夹住 —— 菜单因此是一个**定高
                  // 窗口**，条目多于窗口时由 [_SlashMenuList] 在里面滚。
                  maxHeight: widget.maxHeight,
                ),
                child: Material(
                  elevation: 6,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: _SlashMenuList(
                    slashContext: widget.slashContext,
                    entries: entries,
                    // 点条目：清掉 `/query` 并收起菜单，**然后**才跑动作。
                    // 顺序不能反（与 [_run] 同一套），所以走同一个方法。
                    onDone: () => _dismiss(clearTrigger: true),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 斜杠浮层里那一列条目。
///
/// 这个 widget 原来在 `insert_menu.dart`（`MailInsertMenu`），是「底部『+』面板
/// 与斜杠浮层共用一份渲染」的产物。底部面板删掉之后它只剩这一个调用方，就地
/// 收进本文件。
///
/// ## 键名是 `insert-<item.name>`，**不要改**
///
/// `test/slash_menu_test.dart` 全篇按这套 key 断言（`insert-table`、
/// `insert-heading1`…）。键名跟着 `SlashItem` 的枚举名走，重命名条目就等于
/// 改测试契约，所以它是**稳定接口**而不是随手起的名字。
///
/// ## 为什么外面套一层 `SingleChildScrollView`
///
/// 浮层外层只是一个**定高**盒子（`ConstrainedBox(maxHeight: 260)`）。滚动不能
/// 交给列表自己：网格/列表在**有界**高度下会把 `shrinkWrap` 理解为「只量可见
/// 的那几行」，盒子外面的条目**根本没有被 inflate** —— 既滚不出来，也查不到
/// （`find.byKey('insert-table')` 返回 0 个，「点不到」与「测试红」是同一个
/// 病根）。套一层滚动视图后滚动方向的高度约束被放开，全部条目都会建出来。
class _SlashMenuList extends StatelessWidget {
  const _SlashMenuList({
    required this.slashContext,
    required this.entries,
    required this.onDone,
  });

  final SlashContext slashContext;
  final List<SlashActionEntry> entries;

  /// 一个条目执行完之后调 —— 浮层据此把 `/query` 清掉并收起自己。
  final VoidCallback onDone;

  /// 条目高度。40 = `bodyMedium` 的行高（14px 字号约 20px）或 18px 图标里取大
  /// 的那个，外加条目自身 `vertical: 4` 的上下内边距。既能放下内容，又够手指点。
  static const double _tileHeight = 40;

  @override
  Widget build(BuildContext context) => FocusScope(
        // 菜单里点一下之后焦点必须能还回编辑器，而 `FocusScope` 默认的
        // `canRequestFocus` 会把焦点吞在菜单内部；`skipTraversal` 让 Tab 键
        // 直接穿过菜单。
        skipTraversal: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [for (final entry in entries) _tile(context, entry)],
          ),
        ),
      );

  Widget _tile(BuildContext context, SlashActionEntry entry) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey('insert-${entry.item.name}'),
      borderRadius: BorderRadius.circular(8),
      // 动作是异步的（插图要弹文件选择器、AI 起草要开面板），但菜单**不等它**
      // —— 先把菜单关掉、焦点还回编辑器，否则文件选择器会盖在一个还开着的
      // 菜单上。返回的 Future 不 await 是**刻意的**。
      onTap: () {
        onDone();
        entry.run(slashContext);
      },
      child: SizedBox(
        height: _tileHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Icon(entry.icon, size: 18,
                  color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
