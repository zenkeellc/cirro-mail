// 发件人选择器：跨实例的主路径 + 过滤 + 键盘 + 单候选的形态。
//
// 从**真的** `ComposeScreen` 上打进去（而不是单独挂 `SenderField`）——
// `compose_screen.dart` 的接线（`ref.listen(composeSendersProvider)` →
// `syncSenderGroups`）正是最容易漏的一环，单测测不到它。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/sender_picker.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Profile _profileA = Profile(
  id: 'p1',
  baseUrl: 'https://a.example/api',
  email: 'me@a.example',
  userName: '甲',
  userId: 7,
);

const Profile _profileB = Profile(
  id: 'p2',
  baseUrl: 'https://b.example/api',
  email: 'me@b.example',
  userName: '乙',
  userId: 8,
  serverTitle: '自建实例',
);

const MailboxAccount _boxA3 = MailboxAccount(
  accountId: 3,
  email: 'me@a.example',
  name: '王五',
);

const MailboxAccount _boxA9 = MailboxAccount(
  accountId: 9,
  email: 'fin@a.example',
  name: '财务',
);

const MailboxAccount _boxB3 = MailboxAccount(
  accountId: 3,
  email: 'hi@b.example',
  name: '李四',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 挂真的 `ComposeScreen`。默认给两台实例、A 两个邮箱、B 一个。
  Future<ProviderContainer> pumpCompose(
    WidgetTester tester, {
    List<Profile> profiles = const <Profile>[_profileA, _profileB],
    Map<String, List<MailboxAccount>> mailboxes =
        const <String, List<MailboxAccount>>{
      'p1': <MailboxAccount>[_boxA3, _boxA9],
      'p2': <MailboxAccount>[_boxB3],
    },
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        currentProfileIdProvider.overrideWithValue('p1'),
        profilesProvider.overrideWith((ref) => Stream.value(profiles)),
        mailboxesProvider.overrideWith(
          (ref, profileId) =>
              Stream.value(mailboxes[profileId] ?? const <MailboxAccount>[]),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const ComposeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('触发行显示「姓名 <邮箱>」与实例名', (tester) async {
    await pumpCompose(tester);
    expect(find.text('王五 <me@a.example>'), findsOneWidget);
    expect(
      find.text('me@a.example'),
      findsOneWidget,
      reason: '实例显示名的兜底顺序是 名字 → serverTitle → 邮箱 → host；'
          '这台实例前三样都没有，所以落到主邮箱',
    );
  });

  testWidgets('只有一个候选时不画下拉箭头，点它也不弹面板', (tester) async {
    await pumpCompose(
      tester,
      profiles: const <Profile>[_profileA],
      mailboxes: const <String, List<MailboxAccount>>{
        'p1': <MailboxAccount>[_boxA3],
      },
    );
    expect(find.byKey(const ValueKey('sender-chevron')), findsNothing);
    expect(
      find.byKey(const ValueKey('sender-trigger')),
      findsNothing,
      reason: '不可点时整行连 InkWell 都不套 —— 这是「点不动」的直接证据，'
          '比「点了没弹面板」更硬（后者若是 InkWell 空回调也会通过）',
    );
    await tester.tap(find.text('王五 <me@a.example>'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sender-sheet')), findsNothing);
  });

  testWidgets('一台实例挂两个邮箱时照样能展开（数的是邮箱数，不是实例数）', (tester) async {
    // 这条钉住一个**按组数判会漏掉**的情形：组数是 1，面板里却有两行要选。
    // 改造前的 `DropdownButton` 数的是扁平后的候选，这里是能选的 ——
    // 按组数判会让 `fin@a.example` 永远选不到。
    await pumpCompose(
      tester,
      profiles: const <Profile>[_profileA],
      mailboxes: const <String, List<MailboxAccount>>{
        'p1': <MailboxAccount>[_boxA3, _boxA9],
      },
    );
    expect(find.byKey(const ValueKey('sender-chevron')), findsOneWidget);
  });

  testWidgets('点「发件邮箱」label 也能开面板，再点一次收起', (tester) async {
    // 三行表头里只有发件人这一行的「输入区」不是真输入框，用户会顺手点
    // label。这里同时钉住「第二次点是收起」—— 若 label 不在面板的
    // TapRegion 组里，第一次点击会先被 onTapOutside hide、再被 toggle show，
    // 面板看起来永远关不掉。
    await pumpCompose(tester);
    await tester.tap(find.text('发件邮箱'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sender-sheet')), findsOneWidget);

    await tester.tap(find.text('发件邮箱'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sender-sheet')), findsNothing);
  });

  /// 打开面板（点触发行）。
  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('sender-trigger')));
    await tester.pumpAndSettle();
  }

  testWidgets('面板按实例分组，两台实例的邮箱都在', (tester) async {
    await pumpCompose(tester);
    await openSheet(tester);

    expect(find.byKey(const ValueKey('sender-sheet')), findsOneWidget);
    expect(find.text('me@a.example'), findsWidgets, reason: 'A 的组头');
    expect(find.text('自建实例'), findsWidgets, reason: 'B 的组头');
    expect(find.text('李四 <hi@b.example>'), findsOneWidget, reason: '跨实例的那一个');
    expect(find.text('财务 <fin@a.example>'), findsOneWidget);
  });

  testWidgets('点 B 实例的邮箱：选中它、面板关掉', (tester) async {
    final container = await pumpCompose(tester);
    await openSheet(tester);

    await tester.tap(find.text('李四 <hi@b.example>'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sender-sheet')), findsNothing);
    expect(
      container
          .read(composeControllerProvider(const ComposeArgs()))
          .sender!
          .profile
          .id,
      'p2',
    );
  });

  testWidgets('搜索框实时过滤：命中邮箱、命中名字、命中实例名', (tester) async {
    await pumpCompose(tester);
    await openSheet(tester);

    await tester.enterText(
      find.byKey(const ValueKey('sender-search')),
      'fin',
    );
    await tester.pumpAndSettle();
    expect(find.text('财务 <fin@a.example>'), findsOneWidget);
    expect(find.text('李四 <hi@b.example>'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('sender-search')),
      '自建',
    );
    await tester.pumpAndSettle();
    expect(
      find.text('李四 <hi@b.example>'),
      findsOneWidget,
      reason: '实例名也是可搜的字段',
    );
    expect(find.text('财务 <fin@a.example>'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sender-sheet')),
        matching: find.text('me@a.example'),
      ),
      findsNothing,
      reason: 'A 组一行都没命中就该整组隐藏 —— 组头留着会变成一行孤零零的'
          '「me@a.example」（A 的实例显示名兜底到主邮箱，正好与组头同字）。'
          '必须 scope 进面板：触发行下面那行小字也叫 me@a.example，不 scope '
          '的话面板里藏没藏组头都是这句 findsNothing —— 等于没测',
    );
  });

  testWidgets('全不命中时显示空态那句；清空搜索恢复全部', (tester) async {
    await pumpCompose(tester);
    await openSheet(tester);

    await tester.enterText(
      find.byKey(const ValueKey('sender-search')),
      'zzzz',
    );
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的邮箱'), findsOneWidget);
    expect(find.text('李四 <hi@b.example>'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('sender-search')), '');
    await tester.pumpAndSettle();
    expect(find.text('李四 <hi@b.example>'), findsOneWidget);
  });

  // 面板键盘路径的回归网（三条）。
  //
  // - ↓ 那条是**唯一**真正在探「面板级 `CallbackShortcuts` 能不能赢过
  //   `EditableText` 的方向键 intent」的用例 —— 这是本设计里唯一一处「机制
  //   对不对靠实测」的地方，别把它删了。
  // - 回车一律用 `receiveAction(done)` 驱动，不用 `sendKeyEvent(enter)`：
  //   后者只把按键交给框架、**不产生** IME 的 done action，所以根本走不到
  //   `TextField.onSubmitted`（`EditableText.onSubmitted` 的文档原文如此）。
  //   真机上回车就是走 IME 这条路的，加一条按键路径反而会让桌面按一次提交两次。
  // - ↑ 那条钉住高亮的边界：初值是第一项，从第一项再按 ↑ 应该**停住**，
  //   不是绕到最后一项（`-1` 哨兵时代就会绕）。
  testWidgets('键盘：↓ 走位之后回车选中的是**第二项**，不是第一项', (tester) async {
    final container = await pumpCompose(tester);
    await openSheet(tester);

    // 焦点在搜索框里（面板一打开就是）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final picked = container
        .read(composeControllerProvider(const ComposeArgs()))
        .sender!;
    expect(
      picked.mailbox.email,
      'fin@a.example',
      reason: '第一项是 me@a.example —— 高亮没生效时选中的会是它',
    );
  });

  testWidgets('键盘：面板刚打开就回车 = 确认第一项（高亮本来就在第一项）', (tester) async {
    final container = await pumpCompose(tester);
    await openSheet(tester);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      container.read(composeControllerProvider(const ComposeArgs())).sender!
          .mailbox
          .email,
      'me@a.example',
    );
    expect(
      find.byKey(const ValueKey('sender-sheet')),
      findsNothing,
      reason: '提交真的发生了才有关面板这个副作用 —— 只断言 sender 没牙齿：'
          '默认发件人本来就是第一项，没有提交路径这条也会绿',
    );
  });

  testWidgets('键盘：刚打开就按 ↑ = 停在第一项（不绕到最后一项）', (tester) async {
    final container = await pumpCompose(tester);
    await openSheet(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      container.read(composeControllerProvider(const ComposeArgs())).sender!
          .mailbox
          .email,
      'me@a.example',
      reason: '高亮初值是第一项，从它再按 ↑ 只会夹在原地；'
          '若初值退回 `-1` 哨兵，这一按会绕到最后一项 hi@b.example',
    );
  });

  testWidgets('键盘：↓ 走位会把高亮行滚进视野（组头会错开「下标×行高」）', (tester) async {
    // 这条钉住 `_move` 的滚动位置**不能**按「下标 × 行高」估：列表里还夹着
    // 组头，组数一多那个估算就偏到把高亮行滚出屏外（实测 10 组起 flat[9]
    // 被裁、14 组时 flat[10..13] 根本没 build）。
    //
    // 造 14 台单邮箱实例：面板 maxHeight 360 → 视口 291px，14 个组头 + 14 行
    // 装不下，必然要滚。

    /// 组头（实例显示名）：姓名留空、serverTitle 也不给，兜底落到主邮箱。
    String headerOf(int i) => 'me${i + 1}@s.example';

    /// 行的标签：有名字时是「名字 <地址>」—— 与组头同字就分不出 find 到的是
    /// 行还是组头，所以给个只属于行的名字。
    String rowLabelOf(int i) => '箱${i + 1} <${headerOf(i)}>';

    final profiles = <Profile>[
      for (var i = 0; i < 14; i++)
        Profile(
          id: 'p${i + 1}', // 'p1' 与 currentProfileId 对上，触发行才画得出来
          baseUrl: 'https://p${i + 1}.example/api',
          email: headerOf(i),
          userName: '用户${i + 1}',
          userId: 100 + i,
        ),
    ];
    final mailboxes = <String, List<MailboxAccount>>{
      for (var i = 0; i < 14; i++)
        'p${i + 1}': <MailboxAccount>[
          MailboxAccount(accountId: i + 1, email: headerOf(i), name: '箱${i + 1}'),
        ],
    };

    await pumpCompose(tester, profiles: profiles, mailboxes: mailboxes);
    await openSheet(tester);

    // 一路 ↓ 到最后一组（flat[13]）—— 老实现这个下标已经彻底在屏外了。
    for (var i = 0; i < 13; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }

    final sheet = find.byKey(const ValueKey('sender-sheet'));
    expect(sheet, findsOneWidget, reason: '面板还在');

    // 高亮行：(1) 必须被 build 出来；(2) 它的矩形得落在面板矩形之内。
    //
    // **光靠 finder 没有牙齿**：列表改成一口气建完之后（`SingleChildScrollView`
    // + `Column`）每一行恒在树里，哪怕 `_reveal` 完全不动，`find` 也照样找得到
    // 高亮行 —— 所以真正钉住「滚了」的是下面那两条**几何**断言。
    final highlighted = find.descendant(
      of: sheet,
      matching: find.text(rowLabelOf(13)),
    );
    expect(
      highlighted,
      findsOneWidget,
      reason: '走到最后一项，它必须已经被 build —— 滚偏了它根本不在树里',
    );

    final sheetRect = tester.getRect(sheet);
    final rowRect = tester.getRect(highlighted);
    expect(
      rowRect.bottom,
      lessThanOrEqualTo(sheetRect.bottom),
      reason: '高亮行底边 $rowRect 露在面板 $sheetRect 之外 = 被滚出了视口',
    );
    expect(
      rowRect.top,
      greaterThanOrEqualTo(sheetRect.top),
      reason: '高亮行顶边也得在面板里',
    );
  });

  testWidgets('文本放大到 2.5：组头与行都跟着长高，不裁字', (tester) async {
    // 组头与行曾经被钉成定高（36 / 40）去喂「按组头 + 行高累加估滚动偏移」那套
    // 旧机制，代价是文本缩放到 1.75（组头）/ 2.5（行）就被裁。定高拆掉之后盒子
    // 跟着字号长高，这条守着「大字号下不裁字」这个回归点。
    //
    // **`takeException()` 在这里看不见裁字**：`Text` 默认会把超出盒子的部分
    // 静默裁掉（softWrap + clip），不抛 `RenderFlex` 溢出 —— 所以只能量几何：
    // 把组头那一行的真实高度用 `TextPainter` 算出来，再跟布局给它的盒子比。
    // 旧的写法（组头钉死 `SizedBox(36)`）在 2.5 倍字号下盒子 36 < 行高 40，
    // 这条就会红；2.0 倍时行高才 32、定高 36 照样装得下，抓不到。
    tester.platformDispatcher.textScaleFactorTestValue = 2.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpCompose(tester);
    await openSheet(tester);
    expect(find.byKey(const ValueKey('sender-sheet')), findsOneWidget);

    final sheetContext = tester.element(find.byType(SenderSheet));
    final scaler = MediaQuery.textScalerOf(sheetContext);
    final theme = Theme.of(sheetContext);
    // 组头用 B 实例的显示名「自建实例」：`p2` 有 `serverTitle: '自建实例'`，
    // 而触发行的实例名小字画的是**当前**发件人（p1，其显示名兜底成
    // `me@a.example`），所以这个串在面板里只作为组头出现一次 ——
    // `me@a.example` 那种「组头与行标签同字」的串会让 `.first` 定位不确定。
    final headerText = '自建实例';
    final lineHeight = (TextPainter(
      text: TextSpan(
        text: headerText,
        // `_GroupHeader` 实际渲染 `labelSmall` + `FontWeight.w600`。
        style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout())
        .height;

    final headerBox = tester.getSize(
      find.ancestor(
        of: find.text(headerText),
        matching: find.byType(Padding),
      ).first,
    );

    // 几何断言才是这条用例的牙齿：让字截断的是「盒子装不下」，不是异常。
    expect(
      headerBox.height,
      greaterThanOrEqualTo(lineHeight),
      reason: '组头的盒子（${headerBox.height}）必须装得下它那一行字（$lineHeight）——'
          ' 定高的话大字号下会把字裁掉，而裁字不抛异常，只有量几何才看得见',
    );
    // `takeException()` 仍留着：它抓不到裁字，但真出现 `RenderFlex` 溢出这类
    // 布局异常时（例如行被塞进装不下的定高盒）它还是唯一能发现的地方。
    expect(tester.takeException(), isNull);
  });
}
