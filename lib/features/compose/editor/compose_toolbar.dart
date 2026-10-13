import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

import 'date_insert.dart';
import 'emoji_picker.dart';
import 'link_insert.dart';
import 'slash_actions.dart';
import 'slash_command.dart';
import 'style_dropdown.dart';
import 'text_styles.dart';
import 'toolbar_button.dart';
import '../../ai/ai_prompts.dart';
import '../writing_snippets.dart';

/// 正文上方的**常驻编辑工具栏**。
///
/// ## 它和选中态浮动工具栏（`EditorToolbar`）的分工
///
/// 这一条**一直在**。原来只有「选中才浮出」那一条（spec §3.2 的静默画布），
/// 代价是「想加粗还没打的字」得先选中点什么 —— 空行上根本没有东西可选。
/// 浮出那条**不动**，两条并存：常驻这条管「随时可点」，浮出那条管「选中之后
/// 就近操作」。
///
/// 两条共用 [ToolbarButton] 的尺寸，所以不会出现「常驻 32px、浮出 40px」这种
/// 只有肉眼能发现的不一致；key 前缀则**必须**分开（这条 `ct-`、浮出那条 `tb-`）
/// —— 两条同时在屏幕上时，同名的 key 会让 `find.byKey` 一次命中两个。
///
/// ## 点它不会让编辑器失焦
///
/// flutter_quill 在编辑器外层包了 `TextFieldTapRegion`（`raw_editor_state.dart`），
/// 默认 `onTapOutsideEnabled` 为真 —— **点到编辑器外面就会 `unfocus()`**。
/// 不把它挡回去，点「加粗」这一下会先把编辑器弄失焦：选区高亮没了、浮动工具栏
/// 没了，接着那一下 `formatSelection` 作用在一个已经不成立的选区上（用户看到的
/// 是「点了没反应」）。解法是每个按钮自己声明成输入框的点击区域 —— 平铺按钮在
/// [ToolbarButton] 里做了，下拉的**触发按钮**在 [ToolbarMenu] 里做了（弹出项挂在
/// 应用级 Overlay 上、落在那个 region 之外，所以每家各自包一层）。
///
/// ## 窄屏
///
/// 一行按钮在 320px 里排不下，所以整条横向滚动（与浮出那条同一个做法，见
/// `editor_toolbar.dart` 的 F-7 说明）。滚一下够得着，比把按钮缩到点不中好。
///
/// ## tooltip 为什么是内置中文
///
/// 与 [slashEntries] 的条目文案同一条取舍：这一层是**编辑器内部的展示定义**，
/// 而 l10n 走的是设置页那一类用户会反复看到的界面文案。写死的代价是英文界面上
/// 这几条 tooltip 仍是中文 —— 与仓库里既有的做法一致（`editor_toolbar.dart`
/// 的「AI 改写」也是写死的）。
class ComposeToolbar extends StatelessWidget {
  const ComposeToolbar({
    super.key,
    required this.slashContext,
    this.onAiTone,
    this.onAiReply,
    this.onAttach,
    this.onInsertSignature,
    this.onInsertPhrase,
    this.phrases = const <WritingSnippet>[],
  });

  /// 条目动作的执行环境（controller / focusNode / 三个面板回调）。
  ///
  /// **与斜杠菜单共用同一个对象**：插入表格、插图、AI 起草这几件事只该有一份
  /// 实现，工具栏只是它们的第二个入口。
  final SlashContext slashContext;

  /// 用某个语气改写选中文字。**为空时整颗按钮不画**（与原来 `onAi` 同一条
  /// 规矩：没配 AI 就不要让用户点到一个没反应的图标）。
  ///
  /// 参数是语气而不是「打开面板」：六个语气**面板里本来就有**，
  /// 工具栏这颗只是把它们提前暴露一层（spec §3 批 D）。用户点「更简洁」
  /// 就是「用更简洁这个语气开面板」，面板打开时那个 chip 已经是选中的 ——
  /// 仍然可以直接换语气再生成。
  final ValueChanged<RewriteTone>? onAiTone;

  /// ⑤ 起一次回复建议。**为空时那颗按钮不画** —— 普通写邮件、转发、
  /// 或者回复模式下拿不到来信正文时，用户点它只会看到一个空面板
  /// （spec §6.3）。
  final VoidCallback? onAiReply;

  /// 选附件。为 null 就不画回形针。附件不是正文内容，所以它不经过
  /// [slashContext]（`SlashItem` 里也没有这一项）。
  final VoidCallback? onAttach;

  /// 插入签名。为空（没配签名 / 发件人还没定）时那颗按钮**不画** ——
  /// 与 [onAiTone] 同一条规矩：不要让用户点到一个没反应的图标。
  final VoidCallback? onInsertSignature;

  /// 插入一条常用语。
  final ValueChanged<WritingSnippet>? onInsertPhrase;

  /// 当前发件邮箱的常用语（用来填下拉）。
  final List<WritingSnippet> phrases;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = slashContext.controller;
    // 这一条**一直在**，所以必须订阅 controller：按钮高亮（加粗开着没有）
    // 与撤销可用性都随选区、文档变化，不订阅就会停在上一帧的状态上。
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Material(
        color: theme.colorScheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: kMailToolbarHeight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: kMailToolbarPadding,
                child: Row(children: _items(context)),
              ),
            ),
            Divider(height: 1, thickness: 1, color: theme.dividerColor),
          ],
        ),
      ),
    );
  }

  List<Widget> _items(BuildContext context) {
    final attach = onAttach;
    final aiTone = onAiTone;
    final aiReply = onAiReply;
    return <Widget>[
      // ---- 历史 -----------------------------------------------------------
      _history('ct-undo', Icons.undo, '撤销', () => slashContext.controller.undo(),
          () => slashContext.controller.hasUndo),
      _history('ct-redo', Icons.redo, '重做', () => slashContext.controller.redo(),
          () => slashContext.controller.hasRedo),
      const ToolbarSeparator(),
      // ---- 段落样式（下拉，互斥）-------------------------------------------
      _paragraphMenu(),
      const ToolbarSeparator(),
      // ---- 行内 -----------------------------------------------------------
      _toggle('ct-bold', Icons.format_bold, q.Attribute.bold, '加粗'),
      _toggle('ct-italic', Icons.format_italic, q.Attribute.italic, '斜体'),
      _toggle('ct-underline', Icons.format_underline, q.Attribute.underline, '下划线'),
      _toggle('ct-strike', Icons.format_strikethrough, q.Attribute.strikeThrough, '删除线'),
      _toggle('ct-code', Icons.code, q.Attribute.inlineCode, '行内代码'),
      const ToolbarSeparator(),
      // ---- 列表与缩进 -----------------------------------------------------
      // 缩进紧挨列表：它们回答的是同一个问题（「这一段在第几层」），
      // 而且对列表与段落都成立。
      _toggle('ct-ul', Icons.format_list_bulleted, q.Attribute.ul, '项目符号'),
      _toggle('ct-ol', Icons.format_list_numbered, q.Attribute.ol, '编号列表'),
      _indent('ct-outdent', Icons.format_indent_decrease, false),
      _indent('ct-indent', Icons.format_indent_increase, true),
      const ToolbarSeparator(),
      // ---- 对齐（两端对齐在溢出里）----------------------------------------
      _toggle('ct-align-left', Icons.format_align_left, q.Attribute.leftAlignment, '左对齐'),
      _toggle('ct-align-center', Icons.format_align_center, q.Attribute.centerAlignment, '居中'),
      _toggle('ct-align-right', Icons.format_align_right, q.Attribute.rightAlignment, '右对齐'),
      // ---- 文字样式 -------------------------------------------------------
      _colorMenu(),
      _highlightMenu(),
      _sizeMenu(),
      const ToolbarSeparator(),
      // ---- 插入 -----------------------------------------------------------
      // 「表格」只给「插入表格」一个按钮 —— 表格块内的加行/删列由表格自己的
      // 操作条负责（选中单元格时出现），不在这里重复一套。
      _action('ct-divider', Icons.horizontal_rule, '分隔线', () => _run(SlashItem.divider)),
      _action('ct-link', Icons.link, '插入链接', () => _editLink(context), active: _linkActive()),
      _entry('ct-image', Icons.image_outlined, '插入图片', SlashItem.image),
      _entry('ct-table', Icons.table_chart_outlined, '插入表格', SlashItem.table),
      if (attach != null)
        _action('ct-attach', Icons.attach_file, '添加附件', attach),
      // ---- 写作（批 A6 加日期、批 A5 的 emoji 面板、批 C 的常用语/签名插在这里）
      _action(
        'ct-date',
        Icons.calendar_today_outlined,
        '插入日期',
        () => _insertText(formatDateForLocale(context)),
      ),
      _emojiMenu(),
      if (onInsertSignature != null)
        _action('ct-signature', Icons.draw_outlined, '插入签名', onInsertSignature!),
      if (onInsertPhrase != null && phrases.isNotEmpty)
        _phraseMenu(),
      // ---- AI -------------------------------------------------------------
      if (aiTone != null) ..._aiItems(aiTone, aiReply),
      // ---- 溢出 -----------------------------------------------------------
      const ToolbarSeparator(),
      _overflowMenu(),
    ];
  }

  // ---------------------------------------------------------------- 取样式

  /// 当前选区/光标处的样式（决定按钮与下拉标签的高亮）。
  ///
  /// 直接用 `controller.getSelectionStyle()`：它是
  /// `document.collectStyle(start, end - start).mergeAll(toggledStyle)`
  /// （`quill_controller.dart:138`），**同时**满足两件事 ——
  /// 光标停在一个已有的 H1 行上时读得到 `header`，空行上「先点加粗再打字」时
  /// 读得到刚点上去的 `bold`（`toggledStyle` 那半）。
  ///
  /// **⚠️ 「读得到 `header`」有一个例外，别把这句话写满**：`collectStyle` 里
  /// `res.offset == 0 && len == 0` 那一支会把 `header` **显式排掉**
  /// （`document.dart:212-224`：「exclude headers which apply only to the active
  /// line」），只能从上一行继承行内属性与其余块级属性。实测：文档
  /// `[h1 "title", "next"]`，光标在**第 0 列**时
  /// `getSelectionStyle().attributes.keys == []`（下拉显示「正文」），
  /// 挪到第 1 列起才是 `[header]`。
  /// 所以「光标停在 h1 行上、下拉却显示正文」是**上游的既有行为**，
  /// 不是这里的读法漏了 —— 但注释里不能写成「只要在 h1 行上就读得到」。
  ///
  /// 早先这里自己写分支（折叠时读 `toggledStyle`、否则 `collectStyle`），
  /// 漏掉的正是「光标在已有格式的行上」那一半。
  q.Style _style() => slashContext.controller.getSelectionStyle();

  /// 当前样式里有没有这个属性（按下拉的 label / 按钮高亮读它）。
  ///
  /// **按 key 而不是按整个 [q.Attribute] 对象**：传进来的 `Attribute` 与样式表
  /// 里那个未必**相等**，而颜色/高亮/字号这些值是运行时才知道的
  /// （`q.Attribute('color', …, '#1a73e8')` 与 `q.Attribute('color', …,
  /// '#d93025')` 是两个不相等的对象）。按 key 判「这一段有没有设过颜色」，
  /// 正是下拉按钮高亮要问的问题。
  ///
  /// 早先叫 `_has`，那个名字容易被读成「对象相等」；这里随新增的按 key 判定的
  /// 调用点（[_toggleFormat]）一起改名。
  bool _hasKey(String key) => _style().attributes.containsKey(key);

  // ---------------------------------------------------------------- 段落样式下拉

  /// 段落样式下拉。**互斥**（H1→H2 是换掉不是叠加），所以不是
  /// [ToolbarButton] 那种 toggle，而是「点一个设一个」。
  Widget _paragraphMenu() {
    final current = _paragraphLabel();
    return ToolbarMenu(
      button: ToolbarMenuButton(
        key: const ValueKey('ct-paragraph'),
        label: current ?? '正文',
        tooltip: '段落样式',
        active: current != null,
      ),
      menuChildren: <Widget>[
        _paragraphItem('ct-paragraph-text', '正文', null),
        _paragraphItem('ct-paragraph-h1', '大标题', q.Attribute.h1),
        _paragraphItem('ct-paragraph-h2', '标题', q.Attribute.h2),
        _paragraphItem('ct-paragraph-h3', '小标题', q.Attribute.h3),
      ],
    );
  }

  /// 当前段落的样式名（正文返回 null）。
  ///
  /// 读的是 [q.QuillController.getSelectionStyle]（**不是** `toggledStyle`）：
  /// 后者只记「光标处接下来要用的格式」，光标停在一个已有的 H1 行上时它是空的
  /// —— 实测 `getSelectionStyle().attributes.keys == [header]` 而
  /// `toggledStyle` 是空的。`getSelectionStyle` 内部是
  /// `document.collectStyle(...).mergeAll(toggledStyle)`（`quill_controller.dart:138`），
  /// 两条都满足。
  ///
  /// 同样的例外见 [_style] 的注释：h1 行上**第 0 列**读不到 `header`
  /// （上游 `document.dart:212-224` 显式排掉），下拉那时显示「正文」。
  /// 那是上游行为，这里不去绕。
  String? _paragraphLabel() {
    final header = _style().attributes[q.Attribute.header.key]?.value;
    return switch (header) {
      1 => 'H1',
      2 => 'H2',
      3 => 'H3',
      _ => null,
    };
  }

  /// 下拉里的一格。`target` 为 null 就是「正文」。
  ///
  /// 属性**由调用方直接给对象**，不按 key 再推一遍 —— 早先这里是
  /// `switch (key) { 'ct-paragraph-h1' => q.Attribute.h1, … }`，把 key 这个
  /// 字符串当成了第二份真相：key 改个名字（或者两个格子拿到同一个 key）
  /// 会**静默**落到 `_ => null` 那一支，「点大标题变成正文」。
  ///
  /// **它只动 `header`，不清行内**：从「上标 + H1」上点「正文」得到的是
  /// 「上标 + 普通段落」，`script` 会留着（`compose_toolbar_menus_test.dart`
  /// 有一条用例把它钉成已知行为）。与 [SlashItem.paragraph] 一致（那条也只
  /// 清块级）；要连行内一起清的是溢出菜单里的「清除格式」。
  Widget _paragraphItem(String key, String label, q.Attribute<Object?>? target) {
    return ToolbarMenuItem(
      key: ValueKey(key),
      label: label,
      onPressed: () {
        final controller = slashContext.controller;
        // 先清三个标题（互斥），再设目标。`null` 就是「正文」。
        for (final attr in const [q.Attribute.h1, q.Attribute.h2, q.Attribute.h3]) {
          controller.formatSelection(q.Attribute.clone(attr, null));
        }
        if (target != null) controller.formatSelection(target);
        _back();
      },
    );
  }

  // ---------------------------------------------------------------- 文字样式下拉

  /// 调色格。**同一个色块既是「设色」也是「清色」的入口**吗？不是 ——
  /// 再点一次同一个色不给清，清色走「选「默认」（黑）那颗」或者溢出里的
  /// 「清除格式」。加一条「再点一次取消」会让「我以为设上了其实取消了」
  /// 这种误操作变多（按钮的高亮状态不足以让人确认这一点）。
  Widget _colorMenu() => ToolbarMenu(
        button: ToolbarMenuButton(
          key: const ValueKey('ct-color'),
          icon: Icons.format_color_text,
          tooltip: '文字颜色',
          active: _hasKey('color'),
        ),
        menuChildren: <Widget>[
          _swatchGrid('ct-color', kTextColors, 'color'),
        ],
      );

  Widget _highlightMenu() => ToolbarMenu(
        button: ToolbarMenuButton(
          key: const ValueKey('ct-highlight'),
          icon: Icons.format_color_fill,
          tooltip: '高亮',
          active: _hasKey('background'),
        ),
        menuChildren: <Widget>[
          _swatchGrid('ct-highlight', kHighlightColors, 'background'),
        ],
      );

  Widget _sizeMenu() => ToolbarMenu(
        button: ToolbarMenuButton(
          key: const ValueKey('ct-size'),
          label: kFontSizeLabels[_sizeValue()] ?? '字号',
          tooltip: '字号',
          active: _sizeValue() != null,
        ),
        menuChildren: <Widget>[
          for (final key in kFontSizes.keys)
            ToolbarMenuItem(
              key: ValueKey('ct-size-$key'),
              label: '${kFontSizeLabels[key]}（${kFontSizes[key]!.round()}）',
              active: _sizeValue() == key,
              onPressed: () {
                slashContext.controller.formatSelection(
                  q.Attribute('size', q.AttributeScope.inline, key),
                );
                _back();
              },
            ),
        ],
      );

  /// 当前选区的 `size` 值（没有就 null）。
  String? _sizeValue() {
    final v = _style().attributes['size']?.value;
    return v is String ? v : null;
  }

  /// 一格色块的网格。key 用 `$prefix-$hex`，测试直接按它点。
  ///
  /// **这是菜单内容，不要再套一层 [ToolbarMenu]**。焦点由
  /// [ToolbarSwatch] 自己包的那层 [TextFieldTapRegion] 加上末尾的 `_back()`
  /// 一起保住（见 [ToolbarMenu] 的注释）。
  Widget _swatchGrid(
    String prefix,
    List<TextColorOption> colours,
    String attrKey,
  ) =>
      Padding(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final c in colours)
              ToolbarSwatch(
                key: ValueKey('$prefix-${c.hex}'),
                color: c.swatch,
                onTap: () {
                  slashContext.controller.formatSelection(
                    q.Attribute(attrKey, q.AttributeScope.inline, c.hex),
                  );
                  _back();
                },
              ),
          ],
        ),
      );

  // ---------------------------------------------------------------- 溢出菜单
  /// 溢出菜单：**只放「单击即生效」的条目**。
  ///
  /// 下拉类（段落样式、颜色、字号）**不能**放进来 —— 下拉套菜单会有两层路由
  /// 与两次 `TextFieldTapRegion` 处置，spec §2.2 明确划掉了。
  Widget _overflowMenu() => ToolbarMenu(
        button: const ToolbarMenuButton(
          key: ValueKey('ct-overflow'),
          icon: Icons.more_horiz,
          tooltip: '更多',
        ),
        menuChildren: <Widget>[
          _overflowItem('ct-justify', '两端对齐', () =>
              _toggleFormat(q.Attribute.justifyAlignment)),
          _overflowItem('ct-sup', '上标', () =>
              _toggleFormat(q.ScriptAttribute(q.ScriptAttributes.sup))),
          _overflowItem('ct-sub', '下标', () =>
              _toggleFormat(q.ScriptAttribute(q.ScriptAttributes.sub))),
          _overflowItem('ct-quote', '引用', () => _toggleFormat(q.Attribute.blockQuote)),
          _overflowItem('ct-codeblock', '代码块', () => _toggleFormat(q.Attribute.codeBlock)),
          _overflowItem('ct-clear', '清除格式', () => clearFormatting(slashContext.controller)),
        ],
      );

  Widget _overflowItem(String key, String label, VoidCallback action) =>
      ToolbarMenuItem(key: ValueKey(key), label: label, onPressed: () {
        action();
        _back();
      });

  // ---------------------------------------------------------------- AI

  /// AI 那两颗粒：改写下拉（六个语气）+ 回复建议。
  ///
  /// 返回的是**一组**而不是一颗：回复建议只跟着 [onAiTone] 走 —— 「没有来信
  /// 正文 **或** 根本没有 AI 入口时都不画」，这条耦合写在 [onAiReply] 的文档里。
  /// 拆出来之后 `_items` 里就只剩一句展开，与它旁边那七颗下拉的形状一致。
  ///
  /// **必须是 `List<Widget>` 而不是 `Column`**：这两个是同一行里**并排**的
  /// 两颗，竖着码进 `Column` 会把常驻工具栏的行高撑成两倍（320px 那条
  /// 窄屏用例量的是这一行的宽度）。
  ///
  /// `_action` 与 `ToolbarMenu` 都自带 [TextFieldTapRegion]，这里不用再包。
  List<Widget> _aiItems(ValueChanged<RewriteTone> aiTone, VoidCallback? aiReply) =>
      <Widget>[
        // 与附件之间隔一条线：左边都是「改正文」，它是「让模型改正文」。
        const ToolbarSeparator(),
        ToolbarMenu(
          button: const ToolbarMenuButton(
            key: ValueKey('ct-ai'),
            icon: Icons.auto_awesome,
            tooltip: 'AI 改写',
          ),
          menuChildren: <Widget>[
            for (final tone in RewriteTone.values)
              ToolbarMenuItem(
                key: ValueKey('ct-ai-${tone.name}'),
                label: tone.label,
                onPressed: () {
                  aiTone(tone);
                  _back();
                },
              ),
          ],
        ),
        // ⑤ 回复建议。紧挨 AI 改写下拉，共用同一条分隔线 —— 两者都是
        // 「让模型动正文」，只是入口不同。**没有来信正文就不画**
        // （`onAiReply` 为空），与 `ct-ai` 同一条规矩。
        if (aiReply != null)
          _action('ct-ai-reply', Icons.reply_outlined, 'AI 回复建议', aiReply),
      ];

  // ---------------------------------------------------------------- emoji

  /// emoji 面板。插入的是**纯文本**（spec §5.1），走
  /// `replaceText(index, 0, emoji, ...)` 那条 —— 不经过
  /// `insertParagraphText`，因为 emoji 要**接着光标**、不是单起一段。
  Widget _emojiMenu() => ToolbarMenu(
        button: const ToolbarMenuButton(
          key: ValueKey('ct-emoji'),
          icon: Icons.emoji_emotions_outlined,
          tooltip: '表情',
        ),
        menuChildren: <Widget>[
          Builder(
            // **这层 `Builder` 不能省**：`EmojiPanel` 的 `build(context)` 拿到的
            // context 是 `menuChildren` 被构造时那个，在 `MenuAnchor` 的面板
            // 子树**之外**，`MenuController.maybeOf` 在那里返回 null ——
            // 于是「点完 emoji 菜单不关」。`Builder` 把 context 往下挪一层，
            // 挪进面板子树里面，才找得到那个 scope。
            builder: (menuContext) => EmojiPanel(
              onPick: (emoji) => _insertText(emoji),
              onClose: () => MenuController.maybeOf(menuContext)?.close(),
            ),
          ),
        ],
      );

  /// 常用语下拉。条目就是名字，点了插到光标处。
  ///
  /// 用 [ToolbarMenuItem] 那条路径（不是色块那种裸 `InkWell`）：条目是
  /// 文字，`MenuItemButton` 的布局本来就是这个样子，而且它帮我们把
  /// 「先让焦点还原、再调 `onPressed`」那件事做了。
  Widget _phraseMenu() {
    final handler = onInsertPhrase!;
    return ToolbarMenu(
      button: const ToolbarMenuButton(
        key: ValueKey('ct-phrase'),
        icon: Icons.quickreply_outlined,
        tooltip: '常用语',
      ),
      menuChildren: <Widget>[
        for (final snippet in phrases)
          ToolbarMenuItem(
            key: ValueKey('ct-phrase-${snippet.id}'),
            label: snippet.name,
            onPressed: () {
              handler(snippet);
              _back();
            },
          ),
      ],
    );
  }

  /// 在光标处插一段**行内**文字（不新起段落）。
  ///
  /// `_back()` 必须调：`EmojiPanel` 里是裸 `InkWell`，没有
  /// `MenuItemButton` 那层「post-frame 之后焦点已还原」的收口，
  /// 不主动要焦点的话，菜单一关焦点就落在触发按钮上了。
  /// （关菜单那一半是调用点的 `onClose` 管的，见 `_emojiMenu`。）
  void _insertText(String text) {
    final controller = slashContext.controller;
    final selection = controller.selection;
    final index = selection.isValid ? selection.start : 0;
    controller.replaceText(
      index,
      0,
      text,
      TextSelection.collapsed(offset: index + text.length),
    );
    _back();
  }

  // ---------------------------------------------------------------- 按钮

  /// 开关一个行内/块级属性。开着就清、关着就设（与浮出那条同一套）。
  Widget _toggle(String key, IconData icon, q.Attribute<Object?> attr, String tooltip) {
    return _action(
      key,
      icon,
      tooltip,
      () => _toggleFormat(attr),
      active: _attrOn(attr),
    );
  }

  /// [ToolbarMenuItem] 版的开/关一个属性（与 [_toggle] 同一套判据）。
  void _toggleFormat(q.Attribute<Object?> attr) {
    final controller = slashContext.controller;
    controller.formatSelection(
      _attrOn(attr) ? q.Attribute.clone(attr, null) : attr,
    );
  }

  /// 同一个 key 底下挂**多个值**、彼此互斥的那几族属性。
  ///
  /// 上游 `QuillToolbarToggleStyleButton._getIsToggled`
  /// （`toggle_style_button.dart:138-149`）就是按这四个 key 分流的，这里
  /// 跟它对齐 —— 不是我们发明的判据。
  static const Set<String> _valueDistinguishedKeys = <String>{
    'list', 'header', 'script', 'align',
  };

  /// 这个属性**在当前选区上算不算开着**。按钮高亮与 [_toggleFormat] 的
  /// 开关判断都读它。
  ///
  /// 大多数属性（`bold`、`color`…）「开着」就是「样式表里有这个 key」。但
  /// [_valueDistinguishedKeys] 那四族例外 —— 同一个 key 底下是不同的**值**。
  /// 光问「有没有这个 key」会出两个错，两个都是实测过的：
  ///
  /// 1. **高亮会一起亮**：`align: right` 时左/中/右三颗按钮**全是**选中的
  ///    （实测 `isSelected` 三颗都 true）—— 用户看不出当前用的是哪一个。
  ///    列表那两颗同理（`list: bullet` 时「编号列表」也亮着）。
  /// 2. **点同族的另一个值会「关掉」而不是「换过去」**：`align: center` 上点
  ///    「左对齐」得到的是**没有 align**（回默认），不是 `align: left`；
  ///    `list: bullet` 上点「编号列表」把列表整个清掉。溢出里的「两端对齐」
  ///    同理 —— 在 `align: center` 上点它是把对齐清掉，不是切到两端对齐。
  ///
  /// 按值比一比就两个都对：族内**换值**（`center` → `left`），族外仍是
  /// 「再点一次关掉」。
  ///
  /// 注意 `q.Attribute.ul` / `ol` 的 key 都是 `list`、值分别是 `bullet` /
  /// `ordered`，所以它们天然落在这一族里。
  bool _attrOn(q.Attribute<Object?> attr) {
    final current = _style().attributes[attr.key];
    if (current == null) return false;
    if (!_valueDistinguishedKeys.contains(attr.key)) return true;
    return current.value == attr.value;
  }

  /// 加/减缩进。走 `controller.indentSelection`（quill 自带的实现，
  /// 夹在 0..5；`quill_controller.dart:145`），不自己算 `indent` 值 ——
  /// 它已经处理了「选区跨多行时逐行加」这件容易写错的事。
  Widget _indent(String key, IconData icon, bool increase) => _action(
        key,
        icon,
        increase ? '增加缩进' : '减少缩进',
        () => slashContext.controller.indentSelection(increase),
      );

  /// 跑一个**已有的**斜杠条目。
  ///
  /// 表格 / 图片 / 分隔线这三件事只该有一份实现（分隔线那条尤其：它要先清掉
  /// 当前行尾 `\n` 上的块级属性，否则在标题行插分隔线会落下一个仍带 `header`
  /// 的 `---`，导出端认不出来）。复用 [slashEntries] 里对应的 `run` 就是这份
  /// 实现，**不要**在工具栏里重写一遍。
  void _run(SlashItem item) {
    final entry = slashEntries.firstWhere((e) => e.item == item);
    // 与斜杠菜单同一个顺序：先跑动作，再把焦点要回来。`_back` 挂在
    // `whenComplete` 上 —— 图片与 AI 起草会弹面板，那时焦点本来就该让出去。
    entry.run(slashContext).whenComplete(_back);
  }

  Widget _entry(String key, IconData icon, String tooltip, SlashItem item) =>
      _action(key, icon, tooltip, () => _run(item));

  // ---------------------------------------------------------------- 链接

  bool _linkActive() => _hasKey(q.Attribute.link.key);

  /// 插入 / 编辑 / 移除链接。
  ///
  /// 三处必须小心（都在这里处理掉）：
  /// 1. **选区要在弹窗前记下来** —— `showDialog` 会让编辑器失焦，失焦会把选区
  ///    收敛掉，弹窗回来再读 `controller.selection` 已经是个空选区。
  /// 2. **返回值有三态**：null = 取消（什么都不做）、空串 = 明确移除、其余 =
  ///    要挂上的地址。三者不能压成两个，否则用户点弹窗外面关掉也会顺手删掉链接。
  /// 3. **地址要先规范化**：`LinkInsert.normalize` 只放行 http/https/mailto/tel，
  ///    认不出来就当场说清楚，而不是写完再被导出端悄悄丢掉。
  Future<void> _editLink(BuildContext context) async {
    final controller = slashContext.controller;
    final selection = controller.selection;
    // `Style.attributes` 里存的是 **Attribute 对象**，链接地址在它的 `value`
    // 上（`Attribute.link` 那个常量本身就是 `LinkAttribute(null)`）。
    final existing = _style().attributes[q.Attribute.link.key]?.value;
    final result = await showDialog<_LinkResult>(
      context: context,
      builder: (dialogContext) => _LinkDialog(
        initial: existing is String ? existing : null,
        onInvalid: () => ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(content: Text('这个地址不能用（只支持 http / https / mailto / tel）')),
        ),
      ),
    );
    // 焦点先还回去，否则下面的 `formatSelection` 作用在一个没有焦点的编辑器上
    // （用户接着敲字也会发现按了没反应）。
    _back();
    if (result == null) return;
    if (result.remove) {
      LinkInsert.clear(controller, selection);
      return;
    }
    final url = result.url!;
    LinkInsert.apply(controller, selection, url);
  }

  /// 撤销/重做：可用性来自 `controller.hasUndo` / `hasRedo`，不可用时灰掉
  /// （灰掉比「点了没反应」说得清）。
  Widget _history(
    String key,
    IconData icon,
    String tooltip,
    VoidCallback action,
    bool Function() enabled,
  ) =>
      _action(key, icon, tooltip, action, enabled: enabled());

  /// 所有按钮的公共外壳：点完把焦点还给编辑器。
  ///
  /// 工具栏自己包了 [TextFieldTapRegion]（见文件头），所以点它**不会**让编辑器
  /// 失焦；但撤销/重做这类动作会把光标搬走，键盘焦点若不显式还回去，用户接着
  /// 敲字会发现「按了没反应」（浮出那条每一步之后也都这么做）。
  Widget _action(
    String key,
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool active = false,
    bool enabled = true,
  }) =>
      ToolbarButton(
        key: ValueKey(key),
        icon: icon,
        active: active,
        enabled: enabled,
        tooltip: tooltip,
        onTap: () {
          onTap();
          _back();
        },
      );

  void _back() => slashContext.focusNode.requestFocus();
}

/// 链接弹窗的结局。**整个 dialog 返回 null 表示取消** —— 与「移除」必须分得开，
/// 否则用户点弹窗外面关掉也会顺手把链接删了。
class _LinkResult {
  const _LinkResult.url(this.url) : remove = false;
  const _LinkResult.remove()
      : url = null,
        remove = true;

  /// 要挂上的地址（已规范化）。[remove] 为真时是 null。
  final String? url;

  final bool remove;
}

/// 输入 / 编辑一个链接地址。
///
/// 是 `StatefulWidget` 而不是就地写一个 `TextField`：输入框要**预填**当前链接
/// （用户多半是来改的），而 `TextEditingController` 得有人持有并释放。放在这里
/// 而不是页面里 —— 它是工具栏自己的对话框，页面不需要知道。
class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.initial, required this.onInvalid});

  /// 当前选区上已有的链接，没有就是 null。
  final String? initial;

  /// 地址不合法时叫一声（就地给提示，而不是关掉弹窗让人猜为什么没生效）。
  final VoidCallback onInvalid;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _input =
      TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 「确定」：规范化通过才关；不通过就**留在弹窗里**并提示 —— 关掉的话
  /// 用户只会看到链接没生效，还得重新点一次按钮、再选一遍文字。
  void _submit() {
    final url = LinkInsert.normalize(_input.text);
    if (url == null) {
      widget.onInvalid();
      return;
    }
    Navigator.of(context).pop(_LinkResult.url(url));
  }

  @override
  Widget build(BuildContext context) {
    final hasLink = widget.initial != null && widget.initial!.isNotEmpty;
    return AlertDialog(
      title: const Text('链接'),
      content: TextField(
        key: const ValueKey('link-input'),
        controller: _input,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(hintText: 'example.com'),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        if (hasLink)
          TextButton(
            key: const ValueKey('link-remove'),
            onPressed: () =>
                Navigator.of(context).pop(const _LinkResult.remove()),
            child: const Text('移除链接'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('link-ok'),
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
