import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/slash_actions.dart';
import 'package:mail_app/features/compose/editor/slash_menu.dart';

/// 记下菜单里被点了什么，不真的去动文档 —— 条目动作本身由
/// `plan_slash_actions_test.dart` 各自驱动。
class Spy {
  var tables = 0;
  var images = 0;
  var drafts = 0;
}

SlashContext contextFor(q.QuillController controller, Spy spy) => SlashContext(
      controller: controller,
      focusNode: FocusNode(),
      onInsertTable: (rows, columns) {
        spy.tables++;
        expect(rows, 3);
        expect(columns, 3);
      },
      onPickImage: () async => spy.images++,
      onAiDraft: () async => spy.drafts++,
    );

/// 数 [initState] 被调了几次 —— P-5 用它钉住「开/关菜单不会重建 child」。
/// 每次重建都 +1，正常应当**恒为 1**。
class CountInits extends StatefulWidget {
  const CountInits({super.key, required this.counter});

  final ValueNotifier<int> counter;

  @override
  State<CountInits> createState() => _CountInitsState();
}

class _CountInitsState extends State<CountInits> {
  @override
  void initState() {
    super.initState();
    // +1 放在 initState 里而不是 build：要数的正是「子树有没有被重新
    // inflate」——重建时 State 对象是新的，initState 必然再跑一次。
    widget.counter.value++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand(child: Text('正文'));
}

Widget host({
  required q.QuillController controller,
  required SlashContext slashContext,
  bool allowAi = true,
  FocusNode? editorFocusNode,
  Widget? childOverride,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SlashMenuHost(
          controller: controller,
          slashContext: slashContext,
          allowAi: allowAi,
          editorFocusNode: editorFocusNode,
          child: childOverride ??
              const SizedBox.expand(child: Text('正文')),
        ),
      ),
    );

/// 把 [plain] 装进文档，光标停在末尾。
q.QuillController doc(String plain) => q.QuillController(
      document: q.Document.fromJson([
        {'insert': plain},
      ]),
      selection: TextSelection.collapsed(offset: plain.length - 1),
    );

void main() {
  group('斜杠菜单', () {
    testWidgets('非空行敲 / 不弹菜单（写路径、写日期不该被抢）', (tester) async {
      final controller = doc('写了一半 /biaoti\n');
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, Spy()),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert-table')), findsNothing);
      expect(tester.takeException(), isNull);
      controller.dispose();
    });

    testWidgets('空行敲 / → 弹出全部条目，含 AI 起草', (tester) async {
      final controller = doc('/\n');
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, Spy()),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert-table')), findsOneWidget);
      expect(find.byKey(const ValueKey('insert-aiDraft')), findsOneWidget);
      expect(tester.takeException(), isNull);
      controller.dispose();
    });

    testWidgets('没配 AI → 菜单里没有 AI 起草（「两个入口、一份定义」同样过滤）',
        (tester) async {
      final controller = doc('/\n');
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, Spy()),
        allowAi: false,
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert-table')), findsOneWidget);
      expect(find.byKey(const ValueKey('insert-aiDraft')), findsNothing);
      controller.dispose();
    });

    testWidgets('敲关键字按过滤（英文关键字与中文标签两条路都认）', (tester) async {
      final controller = doc('/h1\n');
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, Spy()),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert-heading1')), findsOneWidget);
      expect(find.byKey(const ValueKey('insert-table')), findsNothing);
      controller.dispose();
    });

    testWidgets('敲中文标签也能过滤（/表格）', (tester) async {
      final controller = doc('/表格\n');
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, Spy()),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert-table')), findsOneWidget);
      expect(find.byKey(const ValueKey('insert-heading1')), findsNothing);
      controller.dispose();
    });

    testWidgets('过滤之后没有候选 → 菜单整个收起来，不是空面板', (tester) async {
      final controller = doc('/zzzz\n');
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, Spy()),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert-table')), findsNothing);
      expect(find.byKey(const ValueKey('insert-heading1')), findsNothing);
      controller.dispose();
    });

    testWidgets('点条目 → 先清掉 /query，再执行动作', (tester) async {
      final spy = Spy();
      final controller = doc('/table\n');
      final slashContext = contextFor(controller, spy);
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: slashContext,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('insert-table')));
      await tester.pumpAndSettle();

      expect(spy.tables, 1);
      // `/table` 这段必须已经从文档里消失 —— 否则它会跟着表格一起留在正文里。
      expect(controller.document.toPlainText().trim(), isEmpty);
      expect(tester.takeException(), isNull);
      controller.dispose();
    });
  });

  group('斜杠菜单的键盘操作', () {
    /// 直接驱动 [SlashMenuHostState.handleKey]（纯逻辑），不走真键盘 ——
    /// 真键盘在 `HardwareKeyboard` 上是全局状态，多个测试互相会串。
    Future<SlashMenuHostState> mounted(WidgetTester tester, String initial) async {
      final controller = doc(initial);
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, Spy()),
      ));
      await tester.pumpAndSettle();
      return tester.state<SlashMenuHostState>(find.byType(SlashMenuHost));
    }

    testWidgets('菜单没开时一个键都不吃（否则编辑器没法打字）', (tester) async {
      final state = await mounted(tester, '普通一行\n');
      expect(
        state.handleKey(LogicalKeyboardKey.arrowDown, isShiftDown: false),
        isFalse,
      );
      expect(
        state.handleKey(LogicalKeyboardKey.enter, isShiftDown: false),
        isFalse,
      );
      expect(
        state.handleKey(LogicalKeyboardKey.escape, isShiftDown: false),
        isFalse,
      );
    });

    testWidgets('菜单开着：Esc 关掉、上下键与回车被吃掉', (tester) async {
      final state = await mounted(tester, '/\n');
      expect(
        state.handleKey(LogicalKeyboardKey.arrowDown, isShiftDown: false),
        isTrue,
      );
      expect(
        state.handleKey(LogicalKeyboardKey.arrowUp, isShiftDown: false),
        isTrue,
      );
      expect(
        state.handleKey(LogicalKeyboardKey.enter, isShiftDown: false),
        isTrue,
      );
      // 回车执行之后菜单该关了。
      expect(
        state.handleKey(LogicalKeyboardKey.enter, isShiftDown: false),
        isFalse,
      );
    });

    testWidgets('Shift+Enter 不吃 —— 那是「换行」的固定语义', (tester) async {
      final state = await mounted(tester, '/\n');
      expect(
        state.handleKey(LogicalKeyboardKey.enter, isShiftDown: true),
        isFalse,
      );
    });

    testWidgets('Esc 关掉之后上下键不再被吃', (tester) async {
      final state = await mounted(tester, '/\n');
      expect(state.handleKey(LogicalKeyboardKey.escape, isShiftDown: false), isTrue);
      expect(
        state.handleKey(LogicalKeyboardKey.arrowDown, isShiftDown: false),
        isFalse,
      );
    });

    testWidgets('过滤到没有候选时，回车不吃键（用户是在换行）', (tester) async {
      final state = await mounted(tester, '/zzzz\n');
      expect(
        state.handleKey(LogicalKeyboardKey.enter, isShiftDown: false),
        isFalse,
      );
    });

    // P-4：Dart 的 `%` 对负数返回非负（`-1 % 12 == 11`），原实现的
    // `(_index + delta) % length` 于是在第 0 条按 ↑ 会直接落到**最后一条**，
    // 再按回车就执行了它（最后一条是「AI 起草」，会开面板）。
    // 选定语义：**两端停住，不回绕**（理由见 `_move` 的注释）。
    testWidgets('P-4 第 0 条按 ↑ 停在原地，回车执行的是第一条而不是最后一条',
        (tester) async {
      final spy = Spy();
      final controller = doc('/\n');
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, spy),
      ));
      await tester.pumpAndSettle();
      final state = tester.state<SlashMenuHostState>(find.byType(SlashMenuHost));

      expect(state.handleKey(LogicalKeyboardKey.arrowUp, isShiftDown: false), isTrue);
      expect(state.handleKey(LogicalKeyboardKey.enter, isShiftDown: false), isTrue);
      await tester.pumpAndSettle();
      // 末尾那条是 AI 起草 —— 回绕的话它会被执行。
      expect(spy.drafts, 0, reason: '从顶部按 ↑ 不该回绕到末尾并执行它');
      controller.dispose();
    });

    testWidgets('P-4 末尾按 ↓ 停在原地，不回绕到第一条', (tester) async {
      final spy = Spy();
      final controller = doc('/\n');
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, spy),
      ));
      await tester.pumpAndSettle();
      final state = tester.state<SlashMenuHostState>(find.byType(SlashMenuHost));

      // 多按几次保证已经到底；再按一下应当**停住**（不回绕到第一条）。
      for (var i = 0; i < 20; i++) {
        state.handleKey(LogicalKeyboardKey.arrowDown, isShiftDown: false);
      }
      state.handleKey(LogicalKeyboardKey.arrowDown, isShiftDown: false);
      expect(state.handleKey(LogicalKeyboardKey.enter, isShiftDown: false), isTrue);
      await tester.pumpAndSettle();
      // 停在末尾 → 执行的是最后一条（AI 起草）；回绕到第一条则不会。
      expect(spy.drafts, 1, reason: '末尾按 ↓ 应当停住，执行最后一条');
      controller.dispose();
    });
  });

  // P-3：`HardwareKeyboard` 的处理器跑在**所有**焦点节点之前，`_onKey` 原样
  // 转发给 [SlashMenuHostState.handleKey]，而那里只判「菜单开着没」——
  // 于是焦点在别的输入框时，回车/方向键也被菜单吃掉。E5 的真实布局是
  // 「主题输入框在上、SlashMenuHost 罩着正文在下」，用户在主题框里敲回车
  // 会被当成「确认斜杠菜单最后一项」。
  group('斜杠菜单的焦点判据（P-3）', () {
    /// 搭一个贴近 E5 的布局：主题输入框在上、SlashMenuHost 罩着正文在下，
    /// 编辑器的 FocusNode 显式接进 host。
    Future<({SlashMenuHostState state, FocusNode editor, FocusNode subject})>
        buildE5(WidgetTester tester, q.QuillController controller, Spy spy) async {
      final editor = FocusNode();
      final subject = FocusNode();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: subject),
              Expanded(
                child: SlashMenuHost(
                  controller: controller,
                  slashContext: contextFor(controller, spy),
                  editorFocusNode: editor,
                  child: Focus(focusNode: editor, child: const SizedBox.expand()),
                ),
              ),
            ],
          ),
        ),
      ));
      // 先把焦点放进编辑器（真实场景里用户正是在正文里敲的 `/`），
      // 再让 postFrame 的 `_sync` 弹菜单。
      editor.requestFocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert-table')), findsOneWidget);
      final state = tester.state<SlashMenuHostState>(find.byType(SlashMenuHost));
      return (state: state, editor: editor, subject: subject);
    }

    testWidgets('主焦点在别的输入框时，按键一个都不吃、文档不变', (tester) async {
      final spy = Spy();
      final controller = doc('/\n');
      final built = await buildE5(tester, controller, spy);
      final before = controller.document.toPlainText();

      // 鼠标点主题输入框：主焦点离开编辑器。
      built.subject.requestFocus();
      await tester.pumpAndSettle();
      expect(built.editor.hasFocus, isFalse);

      expect(
        built.state.handleKey(LogicalKeyboardKey.enter, isShiftDown: false),
        isFalse,
      );
      expect(
        built.state.handleKey(LogicalKeyboardKey.arrowDown, isShiftDown: false),
        isFalse,
      );
      expect(spy.drafts, 0);
      // 斜杠没被清掉、正文里没有凭空多出表格。
      expect(controller.document.toPlainText(), before);

      controller.dispose();
      built.editor.dispose();
      built.subject.dispose();
    });

    testWidgets('主焦点仍在编辑器上时，按键照常被执行', (tester) async {
      final spy = Spy();
      final controller = doc('/\n');
      final built = await buildE5(tester, controller, spy);

      // 焦点就在编辑器上（buildE5 已经把焦点放了进去）。
      expect(
        built.state.handleKey(LogicalKeyboardKey.arrowDown, isShiftDown: false),
        isTrue,
      );
      expect(
        built.state.handleKey(LogicalKeyboardKey.enter, isShiftDown: false),
        isTrue,
      );
      await tester.pumpAndSettle();

      controller.dispose();
      built.editor.dispose();
      built.subject.dispose();
    });

    testWidgets('焦点离开编辑器 → 菜单自动收起来', (tester) async {
      final spy = Spy();
      final controller = doc('/\n');
      final built = await buildE5(tester, controller, spy);
      expect(find.byKey(const ValueKey('insert-table')), findsOneWidget);

      built.subject.requestFocus();
      await tester.pumpAndSettle();

      // 菜单不该一直挂在正文上。
      expect(find.byKey(const ValueKey('insert-table')), findsNothing);

      controller.dispose();
      built.editor.dispose();
      built.subject.dispose();
    });

    testWidgets('没接 editorFocusNode → 退化成旧行为（不判焦点）', (tester) async {
      final spy = Spy();
      final controller = doc('/\n');
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, spy),
      ));
      await tester.pumpAndSettle();
      final state = tester.state<SlashMenuHostState>(find.byType(SlashMenuHost));
      // 旧调用方没传 FocusNode：菜单开着时按键照吃，不被焦点判据拦掉。
      expect(
        state.handleKey(LogicalKeyboardKey.arrowDown, isShiftDown: false),
        isTrue,
      );
      controller.dispose();
    });
  });

  // P-5：菜单开/关时 child 的位置在「唯一子节点」↔「Stack 第 0 个子节点」
  // 之间切换，Flutter 判定结构变化 → 整棵子树重新 inflate。E5 里 child 就是
  // `MailQuillEditor`，每次弹 `/` 都会重建它的 ScrollController 与 EditorState。
  group('斜杠菜单开合不重建 child（P-5）', () {
    testWidgets('开 → 关 → 再开，child 的 initState 只跑一次', (tester) async {
      final counter = ValueNotifier<int>(0);
      final spy = Spy();
      // 文档先是一行普通文字（菜单不开），再用 controller 变化把 `/` 敲上去。
      final controller = doc('普通一行\n');
      await tester.pumpWidget(host(
        controller: controller,
        slashContext: contextFor(controller, spy),
        childOverride: CountInits(counter: counter),
      ));
      await tester.pumpAndSettle();
      expect(counter.value, 1); // 正常挂载一次

      // 开菜单：整篇换成空行 + `/`，光标紧随其后。
      void rewrite(String plain, int cursor) {
        controller.document = q.Document.fromJson([
          {'insert': plain},
        ]);
        controller.updateSelection(
          TextSelection.collapsed(offset: cursor),
          q.ChangeSource.local,
        );
      }

      rewrite('/\n', 1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert-table')), findsOneWidget);

      // 关菜单：换成普通文字。
      rewrite('文字\n', 1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert-table')), findsNothing);

      // 再开一次。
      rewrite('/\n', 1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert-table')), findsOneWidget);

      // 原实现（child 在两种结构间换位）在这里会数到 4。
      expect(counter.value, 1, reason: '开合菜单不该重建 child 子树');
      controller.dispose();
      counter.dispose();
    });
  });
}
