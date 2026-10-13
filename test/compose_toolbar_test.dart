import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/compose/editor/compose_toolbar.dart';
import 'package:mail_app/features/compose/editor/slash_actions.dart';

/// 记下条目动作被跑了几次，不真的去动文档 —— 表格/图片/分隔线各自的落地
/// 由 `slash_actions_test.dart` 驱动。
class Spy {
  var tables = 0;
  var images = 0;
  var drafts = 0;
  var attached = 0;
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

/// 带行属性的文档（属性挂在行尾那个 `\n` 上）。
q.QuillController doc(String plain) => q.QuillController(
      document: q.Document.fromJson([
        {'insert': plain},
      ]),
      selection: TextSelection.collapsed(offset: plain.length - 1),
    );

Map<String, dynamic> lineAttributes(q.QuillController controller) {
  for (final op in controller.document.toDelta().toJson()) {
    final insert = op['insert'];
    if (insert is String && insert.contains('\n') && op['attributes'] is Map) {
      return Map<String, dynamic>.from(op['attributes'] as Map);
    }
  }
  return const <String, dynamic>{};
}

bool hasInline(q.QuillController controller, String key) => controller
    .document
    .toDelta()
    .toJson()
    .any((op) => op['attributes'] is Map && (op['attributes'] as Map)[key] != null);

/// 这颗按钮画成「选中」了吗（高亮与开关判据读的是同一个状态）。
bool buttonSelected(WidgetTester tester, String key) =>
    tester
        .widget<IconButton>(find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(IconButton),
        ))
        .isSelected ??
    false;

void main() {
  testWidgets('没选中任何东西时整条工具栏也在（这是它存在的理由）', (tester) async {
    final controller = doc('一句话\n');
    final spy = Spy();
    await tester.pumpWidget(host(controller, spy));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ct-bold')), findsOneWidget);
    expect(find.byKey(const ValueKey('ct-attach')), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('空行上先点加粗、再打字 → 真的出粗体（走 toggledStyle）', (tester) async {
    final controller = doc('\n');
    final spy = Spy();
    await tester.pumpWidget(host(controller, spy));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ct-bold')));
    await tester.pumpAndSettle();
    // 高亮必须跟着亮起来：高亮读的是 `toggledStyle`，不是光标前那个字符
    // （空行上没有字符）。读错的话按钮会显示成「没开」、点下去却真的开了。
    expect(
      tester
          .widget<IconButton>(find.descendant(
            of: find.byKey(const ValueKey('ct-bold')),
            matching: find.byType(IconButton),
          ))
          .isSelected,
      isTrue,
      reason: '光标处「接下来要用的格式」应当是加粗',
    );

    controller.replaceText(0, 0, '新写的字', const TextSelection.collapsed(offset: 4));
    await tester.pumpAndSettle();
    expect(hasInline(controller, 'bold'), isTrue,
        reason: '先点加粗再打字，打出来的字必须是粗的');
    controller.dispose();
  });

  testWidgets('选中一段字再加粗 → 那一段带上 bold', (tester) async {
    final controller = doc('一句话\n');
    final spy = Spy();
    await tester.pumpWidget(host(controller, spy));
    await tester.pumpAndSettle();
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      q.ChangeSource.local,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ct-bold')));
    await tester.pumpAndSettle();
    expect(hasInline(controller, 'bold'), isTrue);
    controller.dispose();
  });

  testWidgets('清除格式把行内属性一起清掉（不只是块级）', (tester) async {
    final controller = doc('一句话\n');
    final spy = Spy();
    await tester.pumpWidget(host(controller, spy));
    await tester.pumpAndSettle();
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 1),
      q.ChangeSource.local,
    );
    controller.formatSelection(q.Attribute.bold);
    controller.formatSelection(q.Attribute.h1);
    await tester.pumpAndSettle();
    expect(hasInline(controller, 'bold'), isTrue);
    expect(lineAttributes(controller)['header'], 1);

    await tester.tap(find.byKey(const ValueKey('ct-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-clear')));
    await tester.pumpAndSettle();
    expect(lineAttributes(controller).containsKey('header'), isFalse);
    expect(hasInline(controller, 'bold'), isFalse,
        reason: '点的是「清除格式」，留下的粗体字会让用户以为没生效');
    controller.dispose();
  });

  testWidgets('没给 onAttach / onAiTone 就不画那两颗按钮', (tester) async {
    final controller = doc('一句话\n');
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ComposeToolbar(
          slashContext: SlashContext(
            controller: controller,
            focusNode: focus,
            onInsertTable: (_, _) => spy.tables++,
            onPickImage: () async => spy.images++,
            onAiDraft: () async => spy.drafts++,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ct-attach')), findsNothing);
    expect(find.byKey(const ValueKey('ct-ai')), findsNothing);
    expect(find.byKey(const ValueKey('ct-bold')), findsOneWidget);
    controller.dispose();
  });

  testWidgets('回形针点下去 → 走 onAttach', (tester) async {
    final controller = doc('一句话\n');
    final spy = Spy();
    await tester.pumpWidget(host(controller, spy));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-attach')));
    await tester.pumpAndSettle();
    expect(spy.attached, 1);
    controller.dispose();
  });

  testWidgets('表格/图片按钮跑的是斜杠条目那一份实现', (tester) async {
    final controller = doc('一句话\n');
    final spy = Spy();
    await tester.pumpWidget(host(controller, spy));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ct-table')));
    await tester.pumpAndSettle();
    expect(spy.tables, 1);
    await tester.tap(find.byKey(const ValueKey('ct-image')));
    await tester.pumpAndSettle();
    expect(spy.images, 1);
    controller.dispose();
  });

  testWidgets('撤销：改过之后可用，点一下回到上一版', (tester) async {
    final controller = doc('一句话\n');
    final spy = Spy();
    await tester.pumpWidget(host(controller, spy));
    await tester.pumpAndSettle();

    controller.replaceText(0, 0, '新增', const TextSelection.collapsed(offset: 2));
    await tester.pumpAndSettle();
    expect(controller.document.toPlainText(), contains('新增'));

    await tester.tap(find.byKey(const ValueKey('ct-undo')));
    await tester.pumpAndSettle();
    expect(controller.document.toPlainText(), isNot(contains('新增')));
    controller.dispose();
  });

  testWidgets('没东西可撤销时那颗按钮是灰的', (tester) async {
    final controller = doc('一句话\n');
    final spy = Spy();
    await tester.pumpWidget(host(controller, spy));
    await tester.pumpAndSettle();
    final undo = tester.widget<IconButton>(find.descendant(
      of: find.byKey(const ValueKey('ct-undo')),
      matching: find.byType(IconButton),
    ));
    expect(undo.onPressed, isNull);
    controller.dispose();
  });

  testWidgets('点工具栏不会把编辑器弄失焦', (tester) async {
    final controller = doc('一句话\n');
    final spy = Spy();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            ComposeToolbar(slashContext: contextFor(controller, spy, focus)),
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
    ));
    await tester.pumpAndSettle();
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('ct-bold')));
    await tester.pumpAndSettle();
    // 失焦的后果是连锁的：选区高亮没了、浮出那条工具栏没了，而紧接着的
    // `formatSelection` 作用在一个已经不成立的选区上。
    expect(focus.hasFocus, isTrue,
        reason: '工具栏必须把自己声明成输入框的点击区域（TextFieldTapRegion）');
    controller.dispose();
  });

  /// 同一个 key 底下有多个值、彼此互斥的那几族：点族内的**另一个值**必须是
  /// 「换过去」而不是「关掉」。
  ///
  /// 判据按 key 判「有没有」时这两条都会红 —— `center` 上点「左对齐」得到的
  /// 是**没有 align**（回默认左），不是 `align: left`；按钮高亮那边更明显：
  /// `align: right` 时三颗对齐按钮**一起**亮着，用户看不出当前用的是哪一个。
  /// 上游 `toggle_style_button.dart:138-149` 对
  /// `list`/`header`/`script`/`align` 就是按值比的，这里跟它对齐。
  group('同 key 多值的几族：按值判开关', () {
    for (final (name, first, second, key, want) in <
        (String, String, String, String, Object)>[
      ('列表', 'ct-ul', 'ct-ol', 'list', 'ordered'),
      ('对齐', 'ct-align-center', 'ct-align-left', 'align', 'left'),
      ('对齐（右）', 'ct-align-center', 'ct-align-right', 'align', 'right'),
    ]) {
      testWidgets('$name：点族内的另一个值是换过去，不是关掉', (tester) async {
        final controller = doc('一句话\n');
        final spy = Spy();
        await tester.pumpWidget(host(controller, spy));
        await tester.pumpAndSettle();
        controller.updateSelection(
          const TextSelection(baseOffset: 0, extentOffset: 2),
          q.ChangeSource.local,
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(ValueKey(first)));
        await tester.pumpAndSettle();
        expect(lineAttributes(controller)[key], isNotNull,
            reason: '前置条件：$first 要真的设上');

        await tester.tap(find.byKey(ValueKey(second)));
        await tester.pumpAndSettle();
        expect(
          lineAttributes(controller)[key],
          want,
          reason: '「$second」是换到另一个值 —— 落成「没有这个属性」的话用户看到的是'
              '「点了一下，对齐没了」',
        );
        controller.dispose();
      });
    }

    testWidgets('高亮只亮当前那一个值，不是整族一起亮', (tester) async {
      final controller = doc('一句话\n');
      final spy = Spy();
      await tester.pumpWidget(host(controller, spy));
      await tester.pumpAndSettle();
      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 2),
        q.ChangeSource.local,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ct-align-right')));
      await tester.pumpAndSettle();

      expect(buttonSelected(tester, 'ct-align-right'), isTrue);
      expect(buttonSelected(tester, 'ct-align-left'), isFalse,
          reason: '三颗一起亮的话，用户看不出当前是右对齐');
      expect(buttonSelected(tester, 'ct-align-center'), isFalse);
      controller.dispose();
    });

    testWidgets('溢出里的「两端对齐」在居中的行上是切过去，不是清掉对齐', (tester) async {
      final controller = doc('一句话\n');
      final spy = Spy();
      await tester.pumpWidget(host(controller, spy));
      await tester.pumpAndSettle();
      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 2),
        q.ChangeSource.local,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ct-align-center')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ct-overflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ct-justify')));
      await tester.pumpAndSettle();

      expect(lineAttributes(controller)['align'], 'justify');
      controller.dispose();
    });
  });

  testWidgets('320px 视口里整条不越界，最右边的按钮也点得到', (tester) async {
    final controller = doc('一句话\n');
    final spy = Spy();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 600,
          child: Column(
            children: [
              ComposeToolbar(slashContext: contextFor(controller, spy, FocusNode())),
              Expanded(
                child: q.QuillEditor(
                  controller: controller,
                  focusNode: FocusNode(),
                  scrollController: ScrollController(),
                  config: const q.QuillEditorConfig(),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final bar = find.byType(ComposeToolbar);
    final rect = tester.getRect(bar);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(320));
    // 排不下时整条横向滚动，不是溢出 —— 溢出在真机上是一条红黑警告条。
    expect(tester.takeException(), isNull);
    // 最右边那颗（重做）在树里，滚一下就能点到。
    expect(find.byKey(const ValueKey('ct-redo')), findsOneWidget);
    controller.dispose();
  });

  group('链接', () {
    testWidgets('选中一段字 → 弹框输入 → delta 里出现 link', (tester) async {
      final controller = doc('点这里\n');
      final spy = Spy();
      await tester.pumpWidget(host(controller, spy));
      await tester.pumpAndSettle();
      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 3),
        q.ChangeSource.local,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ct-link')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('link-input')), 'example.com');
      await tester.tap(find.byKey(const ValueKey('link-ok')));
      await tester.pumpAndSettle();

      final ops = controller.document.toDelta().toJson();
      final link = ops
          .map((op) => (op['attributes'] is Map)
              ? (op['attributes'] as Map)['link']
              : null)
          .firstWhere((v) => v != null, orElse: () => null);
      expect(link, 'https://example.com',
          reason: '没写 scheme 的输入要补 https://');
      controller.dispose();
    });

    testWidgets('危险协议：不写进文档，就地给提示', (tester) async {
      final controller = doc('点这里\n');
      final spy = Spy();
      await tester.pumpWidget(host(controller, spy));
      await tester.pumpAndSettle();
      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 3),
        q.ChangeSource.local,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ct-link')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('link-input')),
        'javascript:alert(1)',
      );
      await tester.tap(find.byKey(const ValueKey('link-ok')));
      await tester.pumpAndSettle();

      expect(find.textContaining('这个地址不能用'), findsOneWidget);
      expect(hasInline(controller, 'link'), isFalse);
      controller.dispose();
    });
  });
}

/// 测试宿主：工具栏 + 一个真实的编辑器（有些用例要真的聚焦）。
Widget host(q.QuillController controller, Spy spy) {
  final focus = FocusNode();
  addTearDown(focus.dispose);
  return MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          ComposeToolbar(
            slashContext: contextFor(controller, spy, focus),
            // 附件与 AI 走的是工具栏自己的两个回调（不在 SlashContext 里）。
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
}
