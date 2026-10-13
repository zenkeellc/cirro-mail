import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/compose/editor/compose_toolbar.dart';
import 'package:mail_app/features/compose/editor/slash_actions.dart';
import 'package:mail_app/features/compose/writing_snippets.dart';

/// **常驻工具栏（`ComposeToolbar`）在 320px 窄屏下的可测那一半。**
///
/// spec §9 风险 2（320px 窄屏）原本只在计划末尾写成「交付后**手工**验证」：
/// 「窄屏 320px 打开写信页：工具栏能不能横向滚到最右」。视觉那一半（滚起来顺不
/// 顺手）确实得手看，但**决定结果的是结构**：按钮行必须在**横向滚动容器**里、
/// 内容得比 320 宽（否则没有可滚的余量）、且最右那颗（`ct-overflow`）拖得到
/// 视口内。这三条在 widget 测试里都能量，且量出来的正是「滚不到就得把「写作」
/// 那段挪进溢出菜单」这个决策依据。
///
/// **别把这条与浮动工具栏（`EditorToolbar`）混为一谈**：那一条受 F-7 的**硬宽度
/// 约束**（`rect.right <= 320`，`test/editor_toolbar_test.dart`），spec §2.1 记着
/// 「加一个 40px 下拉把它撑到 353、F-7 当场红，于是那颗按钮**被撤掉**」——
/// 它是**不许溢出**的那条。常驻这条相反：它**就是要滚**（`compose_toolbar.dart`
/// 文件头「窄屏」一节），所以这里断言的是 `maxScrollExtent > 0`，而不是
/// 「宽度 <= 320 的那一份内容」。
///
/// ## 这条用例挡住哪个 mutation
///
/// 把 `compose_toolbar.dart` 的 `build` 里那层 `SingleChildScrollView`
/// **去掉**（`Row` 直接塞进那个 `SizedBox(height: kMailToolbarHeight)`）——
/// 也就是把「整条横向滚动」退回「排不下就溢出」：320px 下按钮行实测约 590px，
/// 这一条会在第 1 步就红（要么 `find.byType(SingleChildScrollView)` 找不到那层，
/// 要么 `RenderFlex overflowed`）。实测过：去掉那层，这条红；装回去，绿。
void main() {
  testWidgets('320px：常驻工具栏在横向滚动容器里，能滚到最右（spec §9 风险 2）', (tester) async {
    // **整块测试面就是 320 逻辑像素宽**（dpr = 1，物理 == 逻辑），而不是只在
    // 树里套一个 `SizedBox(width: 320)` —— 后者要靠「Scaffold 的 body 恰好摆在
    // 左边 0」才成立，量到的坐标才是视口坐标。设 tester.view 是从**根**上把它
    // 定死，下面 `getRect().right <= 320` 断言的「视口右边缘」才与产品的真实
    // 窄屏一致。（`editor_toolbar_test.dart` 的 F-7 用的是 `SizedBox` 那条路，
    // 达到的是同一件事；这里选从 view 定死，省掉坐标系上的隐含前提。）
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = q.QuillController(
      document: q.Document.fromJson([
        {'insert': '一句\n'},
      ]),
      selection: const TextSelection(baseOffset: 0, extentOffset: 2),
    );
    addTearDown(controller.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final spy = _Spy();

    // **把可选按钮全打开**（附件 / AI 改写 / AI 回复 / 签名 / 常用语），
    // 让这一行处在**最宽的真实形状**上 —— 风险问的就是这个形状在 320px 下
    // 够不够滚。回调全给上，`phrases` 给一条（`_phraseMenu` 要求它非空）。
    await tester.pumpWidget(MaterialApp(
      // 中文界面：日期那颗等用到 locale 的按钮在这个 locale 下才有意义，
      // 与 `compose_toolbar_menus_test.dart` 的宿主一致。
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: ComposeToolbar(
          slashContext: SlashContext(
            controller: controller,
            focusNode: focus,
            onInsertTable: (_, _) => spy.tables++,
            onPickImage: () async => spy.images++,
            onAiDraft: () async => spy.drafts++,
          ),
          onAttach: () => spy.attached++,
          onAiTone: (tone) => spy.tones.add(tone),
          onAiReply: () => spy.replies++,
          onInsertSignature: () => spy.signature++,
          onInsertPhrase: (_) => spy.phrase++,
          phrases: const <WritingSnippet>[
            WritingSnippet(id: '1', name: '约时间', text: '方便的话…'),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // ---- 1. 没有溢出 --------------------------------------------------------
    // 排不下又没滚动容器时，`Row` 会报 `RenderFlex overflowed by N pixels`
    // （测试框架把它记成一次异常）。这里显式取一次，让「溢出」有独立的一条
    // 断言，而不是只在别的断言上顺带表现出来。
    expect(
      tester.takeException(),
      isNull,
      reason: '320px 下按钮行排不下就该滚动，不是溢出（溢出在真机上是一条红黑警告条）',
    );

    // ---- 2. 按钮行确实在横向滚动容器里 --------------------------------------
    // **按类型查找在这里不唯一**（`SingleChildScrollView` 在整个 app 里不止一个），
    // 所以先用 `find.descendant` 把它夹在 `ComposeToolbar` 子树里，并断言
    // `findsOneWidget` —— 免得悄悄量到别处的滚动容器、把这条测试变成空转。
    final scroller = find.descendant(
      of: find.byType(ComposeToolbar),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scroller, findsOneWidget, reason: '常驻工具栏应当恰好有一层滚动容器');
    expect(
      tester.widget<SingleChildScrollView>(scroller).scrollDirection,
      Axis.horizontal,
      reason: '行是一维横排的，只能横向滚；纵向滚会让窄屏上的工具栏变成可上下拖',
    );

    // ---- 3. 内容比视口宽（滚得动）------------------------------------------
    // 用 `ScrollableState.position`：这层滚动容器**没有挂 controller**
    // （`compose_toolbar.dart` 里就是裸 `SingleChildScrollView`），所以拿不到
    // `ScrollController`；但每个 `Scrollable` 必然有一个 `ScrollPosition`，
    // 它同时给出 `viewportDimension`（视口宽）与 `maxScrollExtent`（可滚余量），
    // 比拿内层 `Row` 和 320 相减更直接、也更诚实（不用自己找那层 Row）。
    final scrollable = find.descendant(
      of: scroller,
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.viewportDimension, 320,
        reason: '前置条件：视口真的是 320px 宽，否则下面量的是另一个尺寸下的行为');
    expect(
      position.maxScrollExtent,
      greaterThan(0),
      reason: '内容不比视口宽 = 没有可滚的余量 = 右边的按钮根本够不着。'
          '这一条红说明「滚到最右」在结构上就不成立，得按计划把「写作」那段挪进溢出菜单',
    );
    // 内层那一行的**实排版宽度**（内容总宽）—— 它就是「320px 下这一行有多宽」
    // 这个数，报告里要的就是它。**按 widget 实例找，不按类型找**：那一行里的
    // 每个下拉按钮自己内部还有一个 `Row`（`style_dropdown.dart`），
    // `find.byType(Row)` 会一次命中好几个。`SingleChildScrollView.child` 就是
    // 外层那一行本身，`find.byWidget` 按实例相等匹配，正好唯一定位到它。
    final scrollView = tester.widget<SingleChildScrollView>(scroller);
    final innerRow = find.byWidget(scrollView.child!);
    expect(innerRow, findsOneWidget, reason: '滚动容器的唯一孩子应当就是那一行按钮');
    final contentWidth = tester.getSize(innerRow).width;
    expect(
      contentWidth,
      greaterThan(320),
      reason: '内层行实测宽 $contentWidth，**不比 320 宽就没有可滚的东西**',
    );
    // 交叉验证：可滚内容总宽 = 视口 + 余量 = **内层行宽 + 这层滚动容器自己的
    // 左右内边距**（`kMailToolbarPadding` 的 padding 也算在可滚内容里）。
    // 两个来源对不上说明其中某个数不可信。内边距按实际值取、不写死 8。
    final padding = (scrollView.padding ?? EdgeInsets.zero)
        .resolve(Directionality.of(tester.element(scroller)));
    expect(
      contentWidth + padding.horizontal,
      position.maxScrollExtent + position.viewportDimension,
      reason: '实排版宽度（含容器内边距）应当等于「视口 + 可滚余量」',
    );

    // ---- 4. 能滚到最右，溢出触发按钮进得来 ----------------------------------
    // 拖的距离按**实测的余量**来（再 overshoot 40px 保证吃满），而不是写死一个
    // 「看起来够大」的数 —— 往右加按钮时写死的距离会悄悄变得不够。
    await tester.drag(scroller, Offset(-(position.maxScrollExtent + 40), 0));
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent,
        reason: '滚到底之后应当停在最右端');

    final overflow = tester.getRect(find.byKey(const ValueKey('ct-overflow')));
    expect(
      overflow.right,
      lessThanOrEqualTo(320),
      reason: '`ct-overflow` 是这一行最右那颗；滚到底它还得在视口外的话，'
          '「横向滚到最右」这条手工验证就是**过不了**的 —— 这正是 spec §9 风险 2 问的事',
    );
    expect(overflow.left, greaterThanOrEqualTo(0),
        reason: '滚过头会把最右那颗顶出左边，同样点不到');
  });
}

class _Spy {
  var tables = 0;
  var images = 0;
  var drafts = 0;
  var attached = 0;
  var signature = 0;
  var replies = 0;
  var phrase = 0;
  final tones = <RewriteTone>[];
}
