import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/compose/editor/compose_toolbar.dart';
import 'package:mail_app/features/compose/editor/slash_actions.dart';
import 'package:mail_app/features/compose/writing_snippets.dart';

/// 这一组只钉**下拉与溢出菜单的焦点契约**（spec §1.3 与 §8 第 1 条）：
/// 点开它们、以及点其中的条目之后，编辑器都必须**仍有焦点、选区仍在**，
/// 且那一下动作作用在那个选区上。其余行为各自由专门的测试钉。

class Spy {
  var tables = 0;
  var images = 0;
  var drafts = 0;
  var attached = 0;
  var signature = 0;
  var phrase = 0;
  final tones = <RewriteTone>[];
}

SlashContext contextFor(q.QuillController controller, Spy spy, FocusNode focus) =>
    SlashContext(
      controller: controller,
      focusNode: focus,
      onInsertTable: (rows, columns) => spy.tables++,
      onPickImage: () async => spy.images++,
      onAiDraft: () async => spy.drafts++,
    );

/// 「一句」+ 行尾，光标选中前两个字（非折叠）。
q.QuillController selectedDoc() => q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句\n'},
      ]),
      selection: const TextSelection(baseOffset: 0, extentOffset: 2),
    );

void main() {
  testWidgets('AI 下拉：六个语气一个不少，点哪个回哪个', (tester) async {
    final controller = selectedDoc();
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComposeToolbar(
            slashContext: contextFor(controller, spy, focus),
            onAiTone: (tone) => spy.tones.add(tone),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ct-ai')));
    await tester.pumpAndSettle();
    // **六个，一个不少**：这一条是防「加了新语气忘了接上」的护栏。
    for (final tone in RewriteTone.values) {
      expect(find.text(tone.label), findsOneWidget, reason: tone.name);
    }

    await tester.tap(find.byKey(const ValueKey('ct-ai-formal')));
    await tester.pumpAndSettle();
    expect(spy.tones, <RewriteTone>[RewriteTone.formal]);
  });

  testWidgets('段落样式下拉：打开后焦点与选区都在', (tester) async {
    final controller = selectedDoc();
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    focus.requestFocus();

    await tester.pumpWidget(_host(controller, spy, focus));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ct-paragraph')));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue, reason: '打开下拉不该让编辑器失焦');
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 2),
      reason: '选区塌掉的话，下面那一下 formatSelection 就作用在错的地方',
    );

    await tester.tap(find.byKey(const ValueKey('ct-paragraph-h1')));
    await tester.pumpAndSettle();
    expect(
      controller.document.toDelta().toJson().toString(),
      contains('header'),
      reason: '菜单条目要真的作用到文档上',
    );
    expect(focus.hasFocus, isTrue, reason: '点完条目要把焦点还给编辑器');
  });

  testWidgets('溢出菜单：打开后焦点与选区都在', (tester) async {
    final controller = selectedDoc();
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    focus.requestFocus();

    await tester.pumpWidget(_host(controller, spy, focus));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ct-overflow')));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 2));
    // 溢出里不能有下拉类条目（spec §2.2）。
    expect(find.text('清除格式'), findsOneWidget);
    expect(find.text('两端对齐'), findsOneWidget);
    expect(find.text('上标'), findsOneWidget);
    expect(find.text('下标'), findsOneWidget);
    expect(find.text('引用'), findsOneWidget);
    expect(find.text('代码块'), findsOneWidget);
  });

  testWidgets('emoji 面板：打开、点一个、插进文档且焦点还在', (tester) async {
    final controller = q.QuillController(
      document: q.Document()..insert(0, '\n'),
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    focus.requestFocus();          // ← 补上：见下方「为什么必须有这一行」

    await tester.pumpWidget(_host(controller, spy, focus));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue, reason: '前置条件：这条用例全程靠它成立');

    await tester.tap(find.byKey(const ValueKey('ct-emoji')));
    await tester.pumpAndSettle();
    // 面板出现了，编辑器没丢焦点（点触发按钮那一下最危险）。
    expect(find.byKey(const ValueKey('emoji-😀')), findsOneWidget);
    expect(focus.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('emoji-😀')));
    await tester.pumpAndSettle();
    expect(controller.document.toPlainText(), contains('😀'));
    expect(focus.hasFocus, isTrue, reason: '插完还要能接着打字');
    // **面板必须真的关上** —— `EmojiPanel` 里是裸 `InkWell`，没有
    // `MenuItemButton` 那层「选完自动关」的收口（`menu_anchor.dart:1303`），
    // 关菜单全靠调用点给的 `onClose`。少了这一条断言，`onClose` 写成
    // 只还焦点不关菜单（或 `MenuController.maybeOf` 在错 context 上返回 null）
    // 时用例照样全绿，而用户看到的是「点完 emoji 面板还杵在那儿，
    // 每点一颗又插一颗」。
    expect(find.byKey(const ValueKey('emoji-😀')), findsNothing,
        reason: '选完要真的把面板关掉，不是只把焦点要回来');
  });

  testWidgets('插入日期：中文格式随 locale', (tester) async {
    final controller = q.QuillController(
      document: q.Document()..insert(0, '\n'),
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    // `pumpWidget` 之后编辑器**没有**焦点（`QuillEditor` 没有 `autofocus`），
    // 不给它焦点的话下面的 `hasFocus` 断言会因为「前置条件不成立」而红 ——
    // 红的是前置条件，不是「日期插没插进去」。注意：`_back()` 在不在，
    // 这句 `hasFocus` 都能绿，所以它**不是** `_back()` 的回归保护，
    // 只是把契约写下来。
    focus.requestFocus();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              ComposeToolbar(
                slashContext: contextFor(controller, spy, focus),
                onAttach: () => spy.attached++,
                onAiTone: (tone) => spy.tones.add(tone),
              ),
              Expanded(
                child: q.QuillEditor(
                  controller: controller,
                  focusNode: focus,
                  scrollController: ScrollController(),
                  config: const q.QuillEditorConfig(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ct-date')));
    await tester.pumpAndSettle();
    // **不要断言 `find.text('插入日期')`** —— 那是 `Tooltip` 的 message，
    // 只有长按/悬停才会画出来，点一下是找不到的。
    final text = controller.document.toPlainText();
    expect(text, matches(RegExp(r'\d{4}年\d{1,2}月\d{1,2}日')),
        reason: '中文界面下插进去的应当是 `2026年10月11日` 这种形状');
    expect(focus.hasFocus, isTrue, reason: '插完要把焦点还给编辑器');
  });

  /// **日期是插在光标处、不是甩在文末。**
  ///
  /// 上面那条的文档是空的、光标在 0，`matches` 又是「串里任一处出现过」
  /// 的语义 —— 把日期**追加到文末**、或者插两遍，它**照样绿**（实测）。
  /// 所以光标语义要单独钉：文档里先有一段字，光标停在中间，断言插进去
  /// 之后的**完整文本**。
  testWidgets('插入日期：落在光标处，不是文末', (tester) async {
    final controller = q.QuillController(
      // 用 `fromJson` 而不是 `Document()..insert(0, …)` —— 后者是往一个
      // 已经含 `'\n'` 的空文档里插，末尾会多出一个空段（实测
      // `toPlainText()` 是 `'前 后\n\n'`），把光标位置算歪。
      document: q.Document.fromJson([
        {'insert': '前后\n'},
      ]),
      // 「前」与「后」之间。
      selection: const TextSelection.collapsed(offset: 1),
    );
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    focus.requestFocus();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              ComposeToolbar(
                slashContext: contextFor(controller, spy, focus),
                onAttach: () => spy.attached++,
                onAiTone: (tone) => spy.tones.add(tone),
              ),
              Expanded(
                child: q.QuillEditor(
                  controller: controller,
                  focusNode: focus,
                  scrollController: ScrollController(),
                  config: const q.QuillEditorConfig(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ct-date')));
    await tester.pumpAndSettle();

    final text = controller.document.toPlainText();
    // 「今天」是什么日子由运行那一刻决定，所以拼期望值时同样取 DateTime.now()
    // —— 只比**位置**，不比具体是哪一天。
    final date = DateFormat.yMMMMd('zh').format(DateTime.now());
    expect(text, '前$date后\n',
        reason: '日期要落在光标处（「前」与「后」之间），甩在文末的话这里会红');
  });

  /// A4 代码审查的 Minor：`SlashItem.paragraph`（「正文」）只清块级属性，
  /// **行内残留照原样留着** —— 上标 / 居中对齐都清不掉。
  ///
  /// 这一条把它钉成**已知行为**（改了会让这里红，那时候再决定是改行为还是
  /// 改用例）。它与溢出里那颗「清除格式」不是同一件事：那颗走的是
  /// `clearFormatting`，块级与行内一起清（`slash_actions_test.dart` 有钉子）。
  testWidgets('「正文」只清块级：上标与对齐的行内残留留着（已知行为）', (tester) async {
    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句\n'},
      ]),
      selection: const TextSelection(baseOffset: 0, extentOffset: 2),
    );
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    focus.requestFocus();

    await tester.pumpWidget(_host(controller, spy, focus));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ct-paragraph')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-paragraph-h1')));
    await tester.pumpAndSettle();

    controller.formatSelection(q.ScriptAttribute(q.ScriptAttributes.sup));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ct-paragraph')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-paragraph-text')));
    await tester.pumpAndSettle();

    final ops = controller.document.toDelta().toJson();
    final lineAttrs = <String, dynamic>{
      for (final op in ops)
        if (op['insert'] is String &&
            (op['insert'] as String).contains('\n') &&
            op['attributes'] is Map)
          ...Map<String, dynamic>.from(op['attributes'] as Map),
    };
    expect(lineAttrs.containsKey('header'), isFalse, reason: '块级要清掉：这正是它做的事');
    expect(
      ops.toString(),
      contains('super'),
      reason: '**已知行为**：行内的 `script` 不在它的清理范围内，会留着。'
          '要连行内一起清的是溢出菜单里的「清除格式」',
    );
  });

  /// **桌面 / 鼠标这条路与移动端不是同一条代码。**
  ///
  /// quill 失焦那一下只在**桌面与移动端浏览器**上做
  /// （`raw_editor_state.dart:360-383` 的 `_defaultOnTapOutside` 按
  /// `defaultTargetPlatform` 分流），而移动端**触摸**事件那一支根本
  /// 不 `unfocus`。所以「点下拉会不会让编辑器失焦」在移动端**恒真**，
  /// 拿它当护栏是空的 —— 上面那几条（默认 `android` 平台）挡不住
  /// 「把 `ToolbarMenu` 的 `TextFieldTapRegion` 拆了」这个回归。
  ///
  /// 加一段鼠标事件、跑在 desktop 变体上的断言才真的钉住它。实测：
  /// 拆掉那层 region 时**这一组每条都红**（默认平台那几条照样绿）。
  group('桌面 + 鼠标：触发按钮的 TextFieldTapRegion 是真的在用', () {
    for (final key in const ['ct-paragraph', 'ct-overflow', 'ct-ai']) {
      testWidgets('点开 $key 之后编辑器仍有焦点', (tester) async {
        final controller = selectedDoc();
        addTearDown(controller.dispose);
        final spy = Spy();
        final focus = FocusNode();
        addTearDown(focus.dispose);
        focus.requestFocus();

        await tester.pumpWidget(_host(controller, spy, focus));
        await tester.pumpAndSettle();
        expect(focus.hasFocus, isTrue, reason: '前置条件');

        await tester.tap(
          find.byKey(ValueKey(key)),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(
          focus.hasFocus,
          isTrue,
          reason: '桌面上点到编辑器外面会 unfocus（quill 只对鼠标这么做），'
              '触发按钮必须自己包一层 TextFieldTapRegion 挡回去',
        );
      },
          variant: TargetPlatformVariant.desktop());
    }
  });

  /// 菜单**条目**那一层 region（`ToolbarMenuItem` 自己包的）实测**不是**
  /// 「保焦点」的唯一依靠 —— `MenuItemButton.onPressed` 是在
  /// `addPostFrameCallback` 里跑的（`menu_anchor.dart:1308`），那时焦点已经
  /// 还原过一次，条目末尾的 `_back()` 再兜一次。所以这两条断言在**拆掉
  /// 条目那层 region 之后照样绿**（实测）。
  ///
  /// 留着那层 region 是因为桌面鼠标的 pointer-down 会先 `unfocus`（上面那组
  /// 钉的就是触发按钮那一半），region 让中间那一瞬不闪 —— 但**别把这两条
  /// 当成它的回归护栏**，它们钉的是「点完条目之后状态是对的」。
  testWidgets('桌面 + 鼠标：点菜单条目之后文档改了、选区还在原处', (tester) async {
    final controller = selectedDoc();
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    focus.requestFocus();

    await tester.pumpWidget(_host(controller, spy, focus));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-paragraph')),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-paragraph-h1')),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(controller.document.toDelta().toJson().toString(), contains('header'));
    expect(controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 2),
        reason: '选区塌掉的话，formatSelection 就作用在错的地方');
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('颜色下拉：点一格，选区拿到 color 属性', (tester) async {
    final controller = selectedDoc();
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    focus.requestFocus();
    await tester.pumpWidget(_host(controller, spy, focus));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue, reason: '前置条件：这条用例全程靠它成立');

    await tester.tap(find.byKey(const ValueKey('ct-color')));
    await tester.pumpAndSettle();
    expect(controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 2),
        reason: '开下拉不许把选区弄丢');
    await tester.tap(find.byKey(const ValueKey('ct-color-#1a73e8')));
    await tester.pumpAndSettle();

    final style = controller.getSelectionStyle();
    expect(style.attributes['color']?.value, '#1a73e8');
    expect(focus.hasFocus, isTrue);
  });

  /// **高亮与颜色只差 `_swatchGrid` 的第三个实参**（`'background'` vs `'color'`），
  /// 而它是颜色字号那三个下拉里唯一没被上面那条顺带盖住的 —— 把 `_colorMenu`
  /// 整段抄来当高亮菜单、忘了改那个实参，色块照样画、点下去也「有反应」，
  /// 现有用例却一条都红不了：文字落的是 `color`，用户看到的是「字变色了」
  /// 而不是「高亮上了」。
  ///
  /// 所以下面两条断言缺一不可。只看 `attributes['background']` 不够 ——
  /// 菜单接错线时那条仍可能因为别的原因凑上；**补上 `attributes['color']`
  /// 为空**，才真的钉住「这一下落在 background 上」。
  testWidgets('高亮下拉：点一格，选区拿到 background 属性（而不是 color）', (tester) async {
    final controller = selectedDoc();
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    focus.requestFocus();
    await tester.pumpWidget(_host(controller, spy, focus));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue, reason: '前置条件：这条用例全程靠它成立');

    await tester.tap(find.byKey(const ValueKey('ct-highlight')));
    await tester.pumpAndSettle();
    // `'#fef7e0'` 是 `kHighlightColors` 的第一格（text_styles.dart）。
    await tester.tap(find.byKey(const ValueKey('ct-highlight-#fef7e0')));
    await tester.pumpAndSettle();

    final style = controller.getSelectionStyle();
    expect(style.attributes['background']?.value, '#fef7e0');
    expect(style.attributes['color'], isNull,
        reason: '接成 color 的菜单会让文字变色而不是高亮 —— 这里红才是对的');
  });

  testWidgets('字号下拉：点「大」设成 19', (tester) async {
    final controller = selectedDoc();
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    focus.requestFocus();
    await tester.pumpWidget(_host(controller, spy, focus));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue, reason: '前置条件：这条用例全程靠它成立');

    await tester.tap(find.byKey(const ValueKey('ct-size')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-size-19')));
    await tester.pumpAndSettle();

    expect(controller.getSelectionStyle().attributes['size']?.value, '19');
  });

  testWidgets('签名按钮：回调被调到（是否有签名由调用方决定画不画）', (tester) async {
    final controller = selectedDoc();
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComposeToolbar(
            slashContext: contextFor(controller, spy, focus),
            onInsertSignature: () => spy.signature++,
            onInsertPhrase: (_) => spy.phrase++,
            phrases: const <WritingSnippet>[
              WritingSnippet(id: '1', name: '约时间', text: '方便的话…'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ct-signature')));
    await tester.pumpAndSettle();
    expect(spy.signature, 1);

    await tester.tap(find.byKey(const ValueKey('ct-phrase')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-phrase-1')));
    await tester.pumpAndSettle();
    expect(spy.phrase, 1);
  });

  testWidgets('没有签名/常用语时那两颗按钮不画', (tester) async {
    final controller = selectedDoc();
    addTearDown(controller.dispose);
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);

    await tester.pumpWidget(_host(controller, spy, focus));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ct-signature')), findsNothing);
    expect(find.byKey(const ValueKey('ct-phrase')), findsNothing);
  });
}

Widget _host(q.QuillController controller, Spy spy, FocusNode focus) =>
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            ComposeToolbar(
              slashContext: contextFor(controller, spy, focus),
              onAttach: () => spy.attached++,
              onAiTone: (tone) => spy.tones.add(tone),
            ),
            Expanded(
              child: q.QuillEditor(
                controller: controller,
                focusNode: focus,
                scrollController: ScrollController(),
                config: const q.QuillEditorConfig(),
              ),
            ),
          ],
        ),
      ),
    );
