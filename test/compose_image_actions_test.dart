import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/image_actions.dart';
import 'package:mail_app/features/compose/editor/mail_image_embed.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 这一组钉**「点一张图 → 改它的对齐 / 换它的 src」**这件事。
/// 两个坑都是实测出来的（探针 /tmp/zzprobe_d，D3 实施前复跑过一遍）：
///
/// 1. 图片的**文档偏移要靠遍历文档找**，不能假设它是第几行第几列；
///    而**遍历的写法有个恒空的陷阱**：`document.root.queryChild(i, false)`
///    永远返回 `Line`、返回不了 `Embed`（它一路钻进 Block 里的 Line），
///    所以逐偏移扫一遍拿到的是空表 —— 见 `image_actions.dart` 的注释；
/// 2. `replaceText(at, 1, ...)` 只在 `at` **正好**是那个嵌入的偏移时才是
///    「替换」—— 偏一格会**多出一张图**。§0.2 第 22 条。
void main() {
  // `ComposeScreen` 那条用例要建 `PrefsStore`（`SharedPreferences` 得先有
  // mock 值），与 `compose_editor_wiring_test.dart` 同一套前置。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  q.QuillController build({String src = 'data:image/png;base64,AAAA'}) =>
      q.QuillController(
        document: q.Document.fromJson(<dynamic>[
          {'insert': '前\n'},
          {
            'insert': <String, dynamic>{'image': src},
          },
          {'insert': '\n后\n'},
        ]),
        selection: const TextSelection.collapsed(offset: 0),
      );

  test('找得到图片的文档偏移', () {
    final c = build();
    addTearDown(c.dispose);
    expect(imageOffsets(c.document), <int>[2]);
  });

  test('设对齐：属性落在图片那一行的行尾上', () {
    final c = build();
    addTearDown(c.dispose);
    setImageAlign(c, 2, q.Attribute.centerAlignment);
    // ⚠️ **别写 `expect(ops.toString(), contains('"align":"center"'))`** ——
    // 那是**恒为假**的：Dart 的 `Map.toString()` 输出 `{align: center}`，
    // 键上根本没有引号（清 C2 那条用例踩的是同一个坑，初版计划抄的也是这句，
    // 实施前用 `dart run` 实测过）。恒假的断言会**编译得过、跑起来红**，
    // 让人以为是生产代码坏了。
    //
    // 判据要落到**属性 Map** 上：找一个**行尾 op**（`insert` 以 `\n` 结尾）
    // 且它的 `attributes['align'] == 'center'`。图片自己那张 op 是
    // **嵌入**（`insert` 是 Map），不带 `align`，所以这条同时钉住
    // 「对齐落在行尾、不是落在图片那一格上」。
    final lineAligns = c.document.toDelta().toJson().whereType<Map>().where(
          (op) =>
              op['insert'] is String &&
              (op['insert'] as String).endsWith('\n') &&
              (op['attributes'] is Map) &&
              (op['attributes'] as Map)['align'] == 'center',
        );
    expect(lineAligns, hasLength(1),
        reason: '对齐没落到图片那一行的行尾上');
    // 图片自己还在（对齐是**行属性**，不是替换图片）。
    expect(imageOffsets(c.document), <int>[2]);
  });

  test('替换 src：仍然只有一张图（不是多一张）', () {
    final c = build();
    addTearDown(c.dispose);
    replaceImage(c, 2, 'data:image/png;base64,BBBB');
    // src 藏在**嵌入 op 的 Map 里**（`{'image': ...}`），不是顶层字符串，
    // 所以这里不能用 `contains('AAAA')` 那种写法去翻整串 —— 翻得到也只说明
    // 某个地方出现过这四个字符。直接读那个嵌入：
    final images = c.document.toDelta().toJson().whereType<Map>().map(
          (op) => op['insert'],
        ).whereType<Map>().map((e) => e['image']).toList();
    expect(images, <String>['data:image/png;base64,BBBB']);
    expect(imageOffsets(c.document).length, 1,
        reason: '偏一格就不是「替换」而是「多插一张」—— 这正是这条要钉的');
  });

  // ------------------------------------------------ 计划之外，实施时补的用例

  test('没有图时 imageOffsets 是空表（不是这一张假图）', () {
    final c = q.QuillController(
      document: q.Document()..insert(0, '只有文字\n'),
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(c.dispose);
    expect(imageOffsets(c.document), isEmpty);
  });

  test('setImageAlign(null) 把对齐清掉（行尾不再带 align）', () {
    final c = build();
    addTearDown(c.dispose);
    setImageAlign(c, 2, q.Attribute.centerAlignment);
    // 先确认设上了，否则「清掉」这条会因为一开始就没设而恒真。
    expect(_lineAligns(c), hasLength(1));
    setImageAlign(c, 2, null);
    expect(_lineAligns(c), isEmpty,
        reason: '传 null 应当把这一行的 align 清掉，而不是留着旧值');
    // 清的是**属性**，不是把图片或那一行删了。
    expect(imageOffsets(c.document), <int>[2]);
  });

  test('两张图给出两个偏移，按文档顺序', () {
    final c = q.QuillController(
      document: q.Document.fromJson(<dynamic>[
        {
          'insert': <String, dynamic>{'image': 'data:image/png;base64,AAAA'},
        },
        {'insert': '\n'},
        {
          'insert': <String, dynamic>{'image': 'data:image/png;base64,BBBB'},
        },
        {'insert': '\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(c.dispose);
    expect(imageOffsets(c.document), <int>[0, 2]);

    // 偏移**正好**时是「换掉那一张」，不是「多插一张」——两张图各验一次。
    replaceImage(c, 2, 'data:image/png;base64,CCCC');
    final images = c.document.toDelta().toJson().whereType<Map>().map(
          (op) => op['insert'],
        ).whereType<Map>().map((e) => e['image']).toList();
    expect(images,
        <String>['data:image/png;base64,AAAA', 'data:image/png;base64,CCCC']);
    expect(imageOffsets(c.document), <int>[0, 2]);
  });

  // ------------------------------------------------------ 回调有没有透传

  /// 「加了参数忘了透传」的表现是**点了没反应**，而本机跑不了真机 UI，
  /// 所以这条从 `MailQuillEditor` 一路点到图片上：中间少一层 `onImageTap`
  /// 的转发，这里就收不到回调。
  testWidgets('点正文里的图：回调收到的是那张图的文档偏移', (tester) async {
    // 假 src（`AAAA`），**故意不是一张真图**：这条钉子钉的是**透传**，
    // 不是解码。用真 PNG 的话，`Image.memory` 会在测试里解出一个
    // **零高度**的一帧（1x1 缩放后量出来是 0），于是 `tester.tap` 去点一个
    // 高为 0 的矩形、永远点不中 —— 恒红的用例比没有用例更糟。
    // 这里的 `data:image/png;base64,AAAA` 会让 [MailImage] 走**裂图占位**那条
    // 路，而**裂图恰恰是最需要换掉的那张**，所以点它本来就必须有反应。
    // 顺便钉住 `_broken` 那条路也在 `GestureDetector` 里面。
    final controller = q.QuillController(
      document: q.Document.fromJson(<dynamic>[
        {'insert': '前\n'},
        {
          'insert': <String, dynamic>{'image': 'data:image/png;base64,AAAA'},
        },
        {'insert': '\n后\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);
    final tapped = <int>[];

    Widget host({EmbedTapCallback? onImageTap}) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 600,
              child: MailQuillEditor(
                controller: controller,
                focusNode: FocusNode(),
                onImageTap: onImageTap,
              ),
            ),
          ),
        );

    await tester.pumpWidget(host(onImageTap: tapped.add));
    await tester.pumpAndSettle();

    final image = find.byType(MailImage);
    expect(image, findsOneWidget);
    // 点在**右上角那一圈空白**上：`GestureDetector` 包在最外层
    // （`ConstrainedBox` 之外）才点得到那里 —— 包在里层的话，能点的只有
    // 「图自己画出来的那一块」，而用户点的往往就是边缘。
    final rect = tester.getRect(image);
    await tester.tapAt(Offset(rect.right - 2, rect.top + 2));
    await tester.pumpAndSettle();
    expect(tapped, <int>[2], reason: '偏移应该是那张图在文档里的位置');
    expect(tester.takeException(), isNull);

    // 不传回调 = 不可点（只读视图走的就是这条）：连 `GestureDetector` 都不该有，
    // 「点一下没反应」是应当的。
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.byType(GestureDetector), findsNothing);
    await tester.tapAt(Offset(rect.right - 2, rect.top + 2));
    await tester.pumpAndSettle();
    expect(tapped, <int>[2], reason: '没传回调就不该有回调');
  });

  // -------------------------------------------- 点图弹出的操作面板（§1.3 / §8）

  /// 点正文里的图弹出的 `_ImageActionsSheet`（`compose_screen.dart` 里
  /// `_onImageTap` 用 `showModalBottomSheet` 推的那个路由）。be6637c 给它包了
  /// `TextFieldTapRegion`，spec §1.3 又要求「每一个新弹出层都要有一条焦点用例
  /// （§8 第 1 条）」—— 这一个当时漏了。**说实话，这一条不是那条行为用例，
  /// 理由见下。**
  ///
  /// ## 边界：这里是真 `ComposeScreen` 流程，不是自己接线的替身
  ///
  /// 走的是页面本身：`pumpCompose` 建真 `ProviderContainer`（只 override
  /// `prefsStore`，与 `compose_editor_wiring_test.dart` 一致），再把正文换成
  /// 带图的那份，然后**点在图上** —— `_onImageTap` 是页面绑的，面板是从
  /// `ComposeScreen.build` 里那个 `showModalBottomSheet` 弹出来的。
  /// 因此下面钉的「开、选、落、关」整条链上的每一环都在被测范围内。
  ///
  /// ## 断言 2（编辑器仍有焦点）**在本机**测不出「有 region / 没 region」的差别
  ///
  /// 已有的 `ai_reply_test.dart`（§1.3 另一处的钉子）为同一件事留过一段实测
  /// 记录，这次把它复跑到图片这一条上，结论一样：**`showModalBottomSheet` 推的
  /// 是顶层 `PopupRoute`，`ModalBottomSheetRoute.requestFocus` 默认是 true，
  /// 路由一上栈就把子树的 `FocusScope` 设成 first focus，正文那圈
  /// `TextFieldTapRegion` 拦不住这一层。**（`navigator.dart`：`Route.requestFocus`
  /// 为真时 `_ModalScopeState` 会 `setFirstFocus(focusScopeNode)`。）
  ///
  /// 实测（本机 `flutter test`，`pump()` 一帧看中间态）：面板**弹出来的那一
  /// 瞬间**，`hasFocus` 就已经是 `false` 了 —— 那时手指还没落在面板上，
  /// `TextFieldTapRegion` 根本没有「pointer-down 要不要算在输入框里」这一问
  /// 可答。六种 `TargetPlatform`（android / iOS 那一支同理，kIsWeb 为假时触摸
  /// 不 unfocus，但这里失焦根本不来自 `unfocus`）+ 触摸 / 鼠标两种 pointer
  /// **全都一样**，拆掉那层 region 前后逐项相同。
  ///
  /// 所以把断言 2 写成「点开之后 `expect(focusNode.hasFocus, isTrue)`」是一条
  /// **不能失败**的空用例：去掉 region 它照样绿。按 ai_reply 那条的先例，
  /// region 的存在改为**结构断言**（`find.ancestor`，断言 2 的位置），
  /// 而 `_onImageTap` 末尾那句 `_bodyFocus.requestFocus()` 由断言 5 钉住。
  ///
  /// ## 能红它的改动（都实测过）
  ///
  /// - 删掉 `_ImageActionsSheet.build` 根上那层 `TextFieldTapRegion`（保留孩子，
  ///   退回裸 `SafeArea`）→ 断言 2 的 `find.ancestor` 立刻 `findsNothing`；
  /// - 把 `_onImageTap` 末尾的 `_bodyFocus.requestFocus()` 删掉 → 断言 5 红
  ///   （这条是真正的**行为**护栏，正常形状的回归就是它挡住的）；
  /// - 面板里任一档改了 `pop` 的字面量（`'center'` 等）→ 断言 4 红。
  testWidgets('点图弹出的操作面板：开 → 选 → 落到图片那一行 → 关（§1.3 / §8）',
      (tester) async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [prefsStoreProvider.overrideWithValue(prefs)],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const ComposeScreen(args: ComposeArgs()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 正文换成「文字 / 裂图 / 文字」，光标回到 0 —— 与上面那条透传用例同一份
    // 文档。`_onImageTap` 存的偏移失效时会退回「离选区最近的一张」，两张图
    // 时那是个真实的歧义；这里只有一张，任何一种选法都指到它，不会让用例
    // 因为无关原因飘。
    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    final focus = editor.focusNode;
    editor.controller.document = q.Document.fromJson(<dynamic>[
      {'insert': '前\n'},
      {'insert': <String, dynamic>{'image': 'data:image/png;base64,AAAA'}},
      {'insert': '\n后\n'},
    ]);
    focus.requestFocus();
    await tester.pumpAndSettle();

    final image = find.byType(MailImage);
    expect(image, findsOneWidget, reason: '前置：正文里那张图要画出来');
    expect(focus.hasFocus, isTrue, reason: '前置：正文有焦点，后面的焦点断言才有意义');

    // 点在**右上角那一圈空白**上：`MailImage` 的 `GestureDetector` 是
    // `HitTestBehavior.opaque`、且包在 `ConstrainedBox` 之外 —— 裂图占位是
    // `Row(mainAxisSize: min)`，只有这一圈空白才真的靠 `opaque` 认领得到
    // （`mail_image_embed.dart` 的注释）。用真 PNG 是不行的：1×1 的图在测试里
    // 量出来是 0px 高，`tapAt` 永远点不中（上面那条用例注释里记了实测）。
    final rect = tester.getRect(image);
    await tester.tapAt(Offset(rect.right - 2, rect.top + 2));
    await tester.pumpAndSettle();

    // 1. 面板真的开了 —— 按它画出来的**可见文字**认（四个 `ListTile` 的
    //    title，`compose_screen.dart:1804-1828`；对白字面量与工具栏上那三个
    //    对齐按钮逐字相同，是同一件事的两种入口）。
    expect(find.text('左对齐'), findsOneWidget);
    expect(find.text('居中'), findsOneWidget);
    expect(find.text('右对齐'), findsOneWidget);
    expect(find.text('换图…'), findsOneWidget);

    // 2. **面板根仍是输入框的点击区域**（spec §1.3 硬约束）。这是结构断言，
    //    不是行为断言 —— 理由见上面那一大段实测：`showModalBottomSheet` 自己
    //    的 requestFocus 先失焦，region 在不在都不影响本机可观测的焦点。
    //    写成行为断言就是一条去掉 region 照样绿的空用例。**删掉 region 这里
    //    红**（已验证），所以它至少把「最容易回归的那一点」钉住了。
    expect(
      find.ancestor(
        of: find.text('居中'),
        matching: find.byType(TextFieldTapRegion),
      ),
      findsOneWidget,
      reason: '`_ImageActionsSheet` 的根必须自包一层 TextFieldTapRegion'
          '（spec §1.3）。能红它：删掉 build 根上那层 region。',
    );

    // 3. 点「居中」，**属性要落到图片那一行的行尾**上 —— 与上面那条
    //    `设对齐：属性落在图片那一行的行尾上` 同一条不变式：找 `\n` 结尾、
    //    且 `attributes['align'] == 'center'` 的 op，有且只有一个。图片自己那张
    //    op 是嵌入（`insert` 是 Map、不带 align），所以这同时钉住「落在行尾、
    //    不是落在图片那一格上」，也钉住 `pop('center')` 这个字面量没被改坏。
    await tester.tap(find.text('居中'));
    await tester.pumpAndSettle();

    final lineAligns = _lineAligns(editor.controller)
        .where((op) => (op['attributes'] as Map)['align'] == 'center');
    expect(lineAligns, hasLength(1),
        reason: '「居中」那一下没落到图片那一行的行尾上：面板 pop 的动作名、'
            '_onImageTap 的 switch、setImageAlign 三者只要断一环就是这个症状');

    // 4. 面板**真的关了**（同 `compose_toolbar_menus_test.dart` 里 emoji 那条
    //    的道理：选完还杵在那儿 = 每点一次又作用一次、用户看得见的 bug）。
    expect(find.text('居中'), findsNothing, reason: '选完要把面板关掉');
    expect(find.text('换图…'), findsNothing);
    expect(find.byType(ListTile), findsNothing);

    // 5. 收尾把焦点还给正文（`_onImageTap` 末尾那一句）—— 用户点完图接着要
    //    打字，不还焦点的话桌面端光标就停在面板原来的地方了。这条**是行为
    //    断言**：删掉那句 `requestFocus()` 这里红。
    expect(focus.hasFocus, isTrue, reason: '点完条目要把焦点还给正文编辑器');
    expect(tester.takeException(), isNull);
  });

  // --------------------------------- imageOffsets 会不会在块级文档上「漂」
  //
  // 实施时留下过一个疑问：`imageOffsets` 是**逐 op 累加**偏移的
  // （`at += data is String ? data.length : 1`），那它是不是**只对平坦文档**
  // 才等于真文档偏移？在「一行里的换行自带块级属性」的引用 / 列表 / 代码块上
  // 会不会漂？
  //
  // 实测（2026-10-11，探针 /tmp/zzprobe_img_offsets.dart，17 种形状，本组又补了
  // 「图是引用块的第一行」共 18 种）：**不漂，全部一致**。机制是：一个 `Line` 比它
  // 孩子之和大出的那**一格**，正好是它自己
  // 那个**带属性的 `\n`**；而那个 `\n` 在 Delta 里是一个独立 op、在这一遍循环里
  // 也**恰好贡献一次 `+1`**，两处的出入逐格抵消。非图片的容器嵌入
  // （`{'_table': 'x'}`）同样每个只占 1。所以「逐 op 累加」不是碰巧对，是与
  // 节点树的长度口径同源。
  //
  // 这条把**两种独立推导**绑在一起：被测的逐 op 累加 vs. 走节点树读
  // `q.Embed.documentOffset`（权威）。期望值**不写死数字** ——
  // 写死就只是在复述一个常数，钉不住任何东西；要的是两条路自己合上。
  group('imageOffsets 与 documentOffset（节点树）在 18 种文档形状下一致', () {
    const imgA = <String, dynamic>{'image': 'data:image/png;base64,AAAA'};
    const imgB = <String, dynamic>{'image': 'data:image/png;base64,BBBB'};

    /// 覆盖：平坦 / 首行即图 / 两张图 / 标题 / 引用 / 列表 / 代码块，
    /// 以及**每种「一行一个换行」的多行块**（`\n` 自带块级属性 —— 逐 op 累加
    /// 最可能在这里滑掉）、容器嵌入、`indent`、空引用行、以及一条把
    /// `header` / `list` / `blockquote` 串起来再放图的文档。
    final shapes = <String, List<dynamic>>{
      '平坦：文字 / 图 / 文字': [
        {'insert': '前\n'},
        {'insert': imgA},
        {'insert': '\n后\n'},
      ],
      '首行就是图': [
        {'insert': imgA},
        {'insert': '\n'},
      ],
      '两张图': [
        {'insert': imgA},
        {'insert': '\n'},
        {'insert': imgB},
        {'insert': '\n'},
      ],
      '标题 + 图': [
        {'insert': '标题\n', 'attributes': {'header': 1}},
        {'insert': imgA},
        {'insert': '\n'},
      ],
      '引用 + 图': [
        {'insert': '引用\n', 'attributes': {'blockquote': true}},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ],
      '列表 + 图': [
        {'insert': '条目\n', 'attributes': {'list': 'bullet'}},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'list': 'bullet'}},
      ],
      '代码块 + 图': [
        {'insert': '代码\n', 'attributes': {'code-block': true}},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'code-block': true}},
      ],
      // 多行块：每行自己的 `\n` 各带一次块级属性，图在第二行之后。
      '多行引用，图在第二个换行之后': [
        {'insert': '第一行\n第二行\n', 'attributes': {'blockquote': true}},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ],
      '多行列表，图在第二个换行之后': [
        {'insert': '第一行\n第二行\n', 'attributes': {'list': 'bullet'}},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'list': 'bullet'}},
      ],
      '多行代码块，图在第二个换行之后': [
        {'insert': '第一行\n第二行\n', 'attributes': {'code-block': true}},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'code-block': true}},
      ],
      // 非图片的**容器嵌入**在图之前：它也占一个 op（+1），别把它漏掉。
      '容器嵌入（_table）在图片之前': [
        {'insert': <String, dynamic>{'_table': 'x'}},
        {'insert': '\n'},
        {'insert': imgA},
        {'insert': '\n'},
      ],
      '项目符号带 indent:1': [
        {'insert': '缩进条目\n', 'attributes': {'list': 'bullet', 'indent': 1}},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'list': 'bullet', 'indent': 1}},
      ],
      '空引用行在图之前': [
        {'insert': '\n', 'attributes': {'blockquote': true}},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ],
      '串起 header:2 / list:ordered indent:2 / blockquote 再放图': [
        {'insert': '标题\n', 'attributes': {'header': 2}},
        {'insert': '列表\n', 'attributes': {'list': 'ordered', 'indent': 2}},
        {'insert': '引用\n', 'attributes': {'blockquote': true}},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ],
      // 图与文字**同一行**（图不单独占行）—— 真编辑器里图通常整行占，
      // 但 Delta 允许同行，这条钉住这种更「歪」的文档也不漂。
      '图与文字同一行、包在引用里': [
        {'insert': '文字'},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ],
      '整行 indent:1（没有块级样式）': [
        {'insert': '缩进文字\n', 'attributes': {'indent': 1}},
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'indent': 1}},
      ],
      // 图是**带块级样式的块的第一行**：块自己的偏移是 0，看看逐 op 累加
      // 与树走查在「块开头就有嵌入」时是否还对得上。
      '图是引用块的第一行': [
        {'insert': imgA},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ],
    };

    for (final entry in shapes.entries) {
      test(entry.key, () {
        final document = q.Document.fromJson(entry.value);
        final viaOps = imageOffsets(document);
        final viaTree = _imageOffsetsViaTree(document).toList();

        // 防「恒真」：两种推导都空也能相等。先钉住树走查确实找到了图，
        // 否则这条会因为「两空相等」永远绿。
        expect(viaTree, isNotEmpty,
            reason: '节点树走查没找到图 —— 这条会退化成恒真，检查 _imageOffsetsViaTree');

        expect(viaOps, viaTree,
            reason: '两种独立推导不一致 = imageOffsets 的逐 op 累加在这种形状下漂了。'
                '点图回调存下的偏移一旦失效，_onImageTap 会拿 imageOffsets 重新认一张'
                '图；偏一格就可能认到隔壁那张图。这正是这条要钉住的。');
      });
    }
  });
}

/// 从**节点树**独立走一遍、收集图片的文档偏移 —— 权威那一头
/// （`q.Embed.documentOffset`，定义在 `q.Node` 上，`node.dart:88`）。
///
/// 两个写法陷阱（都实测踩过，写在这里免得下一个人再踩）：
/// 1. **别把 `Block` 当 `Line` 递归**：`list` / `blockquote` / `code-block`
///    的 `root.children` 是 `Block`（`Block.children` 才是 `Line`），
///    `as q.Line` 会抛 `type 'Block' is not a subtype of type 'Line'`；
/// 2. **别用 `root.queryChild(i, false)`**：它一路钻进 `Block` 里的 `Line`，
///    永远返回不了 `Embed`（实测逐偏移扫一遍返回**空表**）。
Iterable<int> _imageOffsetsViaTree(q.Document document) {
  final out = <int>[];
  void visit(q.Node node) {
    if (node is q.Embed) {
      // 图片是 `Embed`（叶子），`value` 是 `Embeddable`，按 `type` 认。
      if (node.value.type == q.BlockEmbed.imageType) {
        out.add(node.documentOffset);
      }
    } else if (node is q.Root) {
      for (final child in node.children) {
        visit(child);
      }
    } else if (node is q.Block) {
      for (final child in node.children) {
        visit(child);
      }
    } else if (node is q.Line) {
      for (final child in node.children) {
        visit(child);
      }
    }
  }

  visit(document.root);
  return out;
}

/// 文档里带 `align` 的行尾 op（判据同上：落在属性 Map 上，不看 toString）。
Iterable<Map> _lineAligns(q.QuillController c) =>
    c.document.toDelta().toJson().whereType<Map>().where(
          (op) =>
              op['insert'] is String &&
              (op['insert'] as String).endsWith('\n') &&
              (op['attributes'] is Map) &&
              ((op['attributes'] as Map)['align'] != null),
        );
