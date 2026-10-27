// 收件人输入行：内联 chips + 输入框的流式排布、以及「chip 多选与文本编辑」
// 那套手势的接线。
//
// 为什么从真的 `ComposeScreen` 上打进去：这一行只在页面里才有意义（它要
// `ComposeController`、要 `ScaffoldMessenger` 弹提示、要被页面那层 Esc 快捷键
// 接住）。单挂 `RecipientField` 得自己造一个 controllers 的 provider，测出来的
// 是「我造的那个」，不是真实接线。
import 'dart:ui' show Tristate;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Profile _profile = Profile(
  id: 'p1',
  baseUrl: 'https://a.example/api',
  email: 'me@a.example',
  userName: '甲',
  userId: 7,
);

const MailboxAccount _box = MailboxAccount(
  accountId: 3,
  email: 'me@a.example',
  name: '甲',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<_Harness> pumpCompose(WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        // 少了 `bootstrapProvider`，控制器 `refreshQuota()` 那条链会撞上
        // 「必须被 override」的 StateError（与其它写邮件页测试同一句）。
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        currentProfileIdProvider.overrideWithValue('p1'),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[_profile]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(
            profileId == 'p1' ? const <MailboxAccount>[_box] : const [],
          ),
        ),
      ],
    );
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    // 推一个真的路由：Esc 那一级要能 `pop` 掉页面，`home:` 里弹不掉。
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const ComposeScreen()),
    );
    await tester.pumpAndSettle();
    return _Harness(tester, db, container);
  }

  /// 用 `,` 收下一串地址（走「输入变化 → 实时拆分」那条真实路径）。
  Future<void> typeChips(_Harness h, List<String> addresses) async {
    await h.enterText('${addresses.join(', ')},');
    await h.pumpSettle();
  }

  Future<void> pressWithControl(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool pump = true,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    if (pump) await tester.pumpAndSettle();
  }

  Future<void> pressWithShift(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool pump = true,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (pump) await tester.pumpAndSettle();
  }

  testWidgets('空行：输入框占满整行并显示 hint；有了 chip 之后 hint 让位', (tester) async {
    final h = await pumpCompose(tester);
    final l10n = h.l10n;
    expect(find.text(l10n.composeRecipientsHint), findsOneWidget);

    // 800 宽测试面：内容列 = 800 - 32（左右 16）- 64（label 列）- 8（间距）。
    expect(
      tester.getSize(h.input).width,
      closeTo(800 - 32 - 64 - 8, 1),
      reason:
          '没有 chip 时输入框必须占满整行 —— 留一小截的话 hint 摆不下，'
          '光标也缩在一角看着像坏了',
    );

    await typeChips(h, <String>['a@x.com']);
    expect(h.chip('a@x.com'), findsOneWidget);
    expect(
      find.text(l10n.composeRecipientsHint),
      findsNothing,
      reason: 'hint 说的是「输入姓名或邮箱」，已经有收件人时再说一遍是噪音',
    );
  });

  testWidgets('输入框紧跟最后一个 chip 同一行，且随输入变宽', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com']);

    final chipRect = tester.getRect(h.chip('a@x.com'));
    final emptyRect = tester.getRect(h.input);
    expect(
      emptyRect.center.dy,
      closeTo(chipRect.center.dy, 2),
      reason:
          '输入框与 chip 必须在同一行（中线差 '
          '${(emptyRect.center.dy - chipRect.center.dy).abs()}px）',
    );
    expect(
      emptyRect.left,
      greaterThan(chipRect.right),
      reason: '输入框要接在 chip 后面，不能绕回行首',
    );

    // 空输入时是「最小宽度」；打一长串之后必须真的变宽（否则长地址在框里
    // 横向滚动，用户看不到自己刚打的字）。
    final emptyWidth = emptyRect.width;
    await h.enterText('zhangkang.liu@example.com');
    await h.pumpSettle();
    final typedWidth = tester.getSize(h.input).width;
    expect(
      typedWidth,
      greaterThan(emptyWidth),
      reason: '输入内容变宽了（$emptyWidth → $typedWidth），输入框却没跟着变宽',
    );
    // 而且仍然与 chip 同行（还没宽到放不下）。
    expect(tester.getRect(h.input).center.dy, closeTo(chipRect.center.dy, 2));
  });

  testWidgets('逗号自动收下；粘贴一串只收完整地址，尾部半截留在输入框', (tester) async {
    final h = await pumpCompose(tester);

    await h.enterText('a@x.com,');
    await h.pumpSettle();
    expect(h.chip('a@x.com'), findsOneWidget);
    expect(h.inputController!.text, isEmpty, reason: '收下之后输入框要清空');

    // 一次粘贴三枚：前两枚完整、最后一枚没写完。
    await h.enterText('b@y.com, c@z.com, d@w');
    await h.pumpSettle();
    expect(h.chip('b@y.com'), findsOneWidget);
    expect(h.chip('c@z.com'), findsOneWidget);
    expect(
      h.inputController!.text,
      'd@w',
      reason: '没有分隔符收尾的那一截是「用户还在打」，不能替他收下',
    );
    expect(h.chip('d@w'), findsNothing);
  });

  testWidgets('退格两步：第一下只选中最后一个，第二下才删', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com', 'b@y.com']);
    await tester.tap(h.input);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(
      h.chip('b@y.com'),
      findsOneWidget,
      reason: '第一下退格只是「选中最后一个」—— 直接删会让用户少一个收件人',
    );
    expect(h.selectionBar, findsOneWidget);
    expect(find.text(h.l10n.composeSelectedCount(1)), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(h.chip('b@y.com'), findsNothing, reason: '第二下才真的删掉选中的');
    expect(h.chip('a@x.com'), findsOneWidget, reason: '没选中的那个不能跟着没');
    expect(h.selectionBar, findsNothing);
  });

  testWidgets('Ctrl+A 全选 chip；Delete 一次删光选中', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com', 'b@y.com']);
    await tester.tap(h.input);
    await tester.pumpAndSettle();

    await pressWithControl(tester, LogicalKeyboardKey.keyA);
    expect(h.selectionBar, findsOneWidget);
    expect(find.text(h.l10n.composeSelectedCount(2)), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(h.chip('a@x.com'), findsNothing);
    expect(h.chip('b@y.com'), findsNothing);
    expect(h.selectionBar, findsNothing, reason: '删完列表空了，操作条也该消失');
  });

  testWidgets('← 从末尾往左扩、→ 收缩；Esc 第二级清空选择且不关页', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com', 'b@y.com', 'c@z.com']);
    await tester.tap(h.input);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text(h.l10n.composeSelectedCount(1)), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text(h.l10n.composeSelectedCount(2)), findsOneWidget);
    await pressWithShift(tester, LogicalKeyboardKey.arrowLeft);
    expect(find.text(h.l10n.composeSelectedCount(3)), findsOneWidget);

    // → 收缩一格（Shift+→ 与 → 同一套收缩语义）
    await pressWithShift(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text(h.l10n.composeSelectedCount(2)), findsOneWidget);

    // Esc 第一级在「没有下拉」时就是清空 chip 选择；页面**不许**被关掉。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(h.selectionBar, findsNothing);
    expect(
      find.byType(ComposeScreen),
      findsOneWidget,
      reason: '清空选择是 Esc 的第二级；页面那层 Esc 只在「什么都没选中」时才该生效',
    );
  });

  testWidgets('输入框里有字时方向键/全选交还 TextField，不碰 chip', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com']);
    await h.enterText('zhang');
    await h.pumpSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await pressWithControl(tester, LogicalKeyboardKey.keyA);
    expect(
      h.selectionBar,
      findsNothing,
      reason:
          '输入框里有文字时，←/Ctrl+A 是文本编辑手势 —— 抢走它们，用户就'
          '没法在地址中间改字了',
    );
  });

  testWidgets('打字会清掉 chip 的选择态', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com']);
    await tester.tap(h.input);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(h.selectionBar, findsOneWidget);

    await h.enterText('z');
    await h.pumpSettle();
    expect(h.selectionBar, findsNothing);
  });

  testWidgets('点击 chip 单选；Shift+点击按锚点扩成范围', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com', 'b@y.com', 'c@z.com']);

    await tester.tap(h.chip('a@x.com'));
    await tester.pumpAndSettle();
    expect(find.text(h.l10n.composeSelectedCount(1)), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(h.chip('c@z.com'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(
      find.text(h.l10n.composeSelectedCount(3)),
      findsOneWidget,
      reason: 'Shift+点击是「从锚点到落点」的连续范围，中间的 b 也要选中',
    );
  });

  testWidgets('Ctrl+点击切换单枚', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com', 'b@y.com']);

    await tester.tap(h.chip('a@x.com'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(h.chip('b@y.com'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text(h.l10n.composeSelectedCount(2)), findsOneWidget);

    // 再点一次取消（不连带 a）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(h.chip('b@y.com'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text(h.l10n.composeSelectedCount(1)), findsOneWidget);
  });

  testWidgets('操作条上的「移除」删掉选中的整组收件人', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com', 'b@y.com', 'c@z.com']);
    await tester.tap(h.input);
    await tester.pumpAndSettle();
    await pressWithControl(tester, LogicalKeyboardKey.keyA);
    // 取消最后一枚，只删前两枚 —— 顺带验「删的是选中的那几个」。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(h.chip('c@z.com'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text(h.l10n.composeSelectedCount(2)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recipient-remove')));
    await tester.pumpAndSettle();
    expect(h.chip('a@x.com'), findsNothing);
    expect(h.chip('b@y.com'), findsNothing);
    expect(h.chip('c@z.com'), findsOneWidget);
  });

  testWidgets('Ctrl+C 把选中地址用 ", " 连起来写进剪贴板', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com', 'b@y.com']);
    await tester.tap(h.input);
    await tester.pumpAndSettle();
    await pressWithControl(tester, LogicalKeyboardKey.keyA);

    final writes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        // 别的平台调用（SystemChrome / HapticFeedback …）照旧放过。
        if (call.method == 'Clipboard.setData') {
          writes.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pressWithControl(tester, LogicalKeyboardKey.keyC);
    expect(writes, <String>[
      'a@x.com, b@y.com',
    ], reason: '复制出来的是一整串（", " 分隔），用户可以直接粘到别处');
    expect(find.text(h.l10n.copied), findsOneWidget, reason: '复制要有反馈');
  });

  // 桌面端的两个平台差异，这条用例专治「在 flutter_tester 的默认平台上看不出来」：
  // 1. 桌面点输入框以外的任意位置，`EditableText` 会在 **pointer-down** 就失焦；
  // 2. 失焦会触发这一行的 `_commit()`，而它顺手清空 chip 选择。
  // 于是「点复制」在 macOS 上会变成「先清空选择、再复制一个空串」——
  // Android 默认平台上永远绿，真机上永远失效。所以要显式切到 macOS。
  testWidgets('macOS：点操作条上的按钮不会先把 chip 选择弄丢', (tester) async {
    // 必须在本体里改回 null：`addTearDown` 跑在框架「foundation 调试变量没被
    // 改过」的校验之后，会报 "The value of a foundation debug variable was
    // changed by the test"。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final h = await pumpCompose(tester);
      await typeChips(h, <String>['a@x.com', 'b@y.com']);
      await tester.tap(h.chip('a@x.com'));
      await tester.pumpAndSettle();

      final writes = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            writes.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('recipient-copy')));
      await tester.pumpAndSettle();
      expect(writes, <String>[
        'a@x.com',
      ], reason: '按钮自己也读 `_selection` —— 点它之前选择就被失焦清掉的话，这里会是空串');
      expect(h.chip('b@y.com'), findsOneWidget);

      // 同一套失焦逻辑对「移除」一样致命：先清选择、再删 0 个。
      await tester.tap(find.byKey(const ValueKey('recipient-remove')));
      await tester.pumpAndSettle();
      expect(h.chip('a@x.com'), findsNothing);
      expect(h.chip('b@y.com'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('非法地址：SnackBar + 行下常驻内联错误，输入一变就清', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('not-an-email');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    expect(
      find.text(h.l10n.composeBadRecipient('not-an-email')),
      findsOneWidget,
      reason: '原有行为：收不下的地址要弹 SnackBar 说出来',
    );
    expect(h.invalidLine, findsOneWidget);
    expect(find.text(h.l10n.composeRecipientInvalid), findsOneWidget);

    await h.enterText('n');
    await tester.pump();
    expect(
      h.invalidLine,
      findsNothing,
      reason: '输入一变就把错误收起来 —— 用户已经在改了，红字还挂着像在骂人',
    );
  });

  testWidgets('点 label / 行内空白：清空选择并把焦点请进输入框', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com']);
    await tester.tap(h.chip('a@x.com'));
    await tester.pumpAndSettle();
    expect(h.selectionBar, findsOneWidget);

    // 点 label：整行都是热区（`ComposeFieldRow.onTap`），用户不用精确点到
    // 输入框里那 1px 宽的文字起点。
    await tester.tap(find.text(h.l10n.composeTo));
    await tester.pumpAndSettle();
    expect(h.selectionBar, findsNothing, reason: '点空白 = 放弃选择');
    expect(
      tester.widget<TextField>(h.input).focusNode?.hasFocus,
      isTrue,
      reason: '清空选择的同时要把光标放回输入框 —— 用户下一步就是接着打',
    );
  });

  testWidgets('中文输入法组字期间不拆地址', (tester) async {
    final h = await pumpCompose(tester);
    await tester.showKeyboard(h.input);
    // 组字中（composing 有效）：这串里虽然有逗号和空格，但它们是候选词的一部分。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhang, ',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    expect(
      h.chip('zhang'),
      findsNothing,
      reason: '组字期间改写输入框文本会把候选框顶掉 —— 用户刚敲的字就丢了',
    );
    expect(h.inputController!.text, 'zhang, ');
  });

  testWidgets('窄屏：chips 排满之后输入框自然折到下一行', (tester) async {
    tester.view.physicalSize = const Size(380, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final h = await pumpCompose(tester);
    await typeChips(h, <String>[
      'a@x.com',
      'b@y.com',
      'c@z.com',
      'd@w.com',
      'e@v.com',
    ]);
    await h.enterText('zhangkang.liu@example.com');
    await h.pumpSettle();

    expect(tester.takeException(), isNull, reason: '折行不等于溢出');
    expect(
      tester.getRect(h.input).top,
      greaterThan(tester.getRect(h.chip('a@x.com')).top),
      reason: '一行放不下时要跟着 chips 折到下一行，而不是在行内横向挤',
    );
  });

  testWidgets('无障碍：chip 是 button+selected，删除按钮单独报标签', (tester) async {
    final h = await pumpCompose(tester);
    await typeChips(h, <String>['a@x.com']);
    final semantics = tester.ensureSemantics();
    await tester.tap(h.chip('a@x.com'));
    await tester.pumpAndSettle();

    final chip = tester.getSemantics(
      find.byKey(const ValueKey('recipient-chip-a@x.com')),
    );
    final data = chip.getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(
      data.flagsCollection.isSelected,
      Tristate.isTrue,
      reason: '读屏要能听出「这个收件人被选中了」—— 只靠颜色的话看不见的用户不知道',
    );
    expect(
      find.bySemanticsLabel(h.l10n.composeRemoveRecipient),
      findsOneWidget,
      reason: '删除按钮必须有自己的标签，不能只是整枚 chip 上的一个副作用',
    );
    semantics.dispose();
  });

  testWidgets('回车收下合法地址（走 IME 的 next action）', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('someone@example.com');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    expect(h.chip('someone@example.com'), findsOneWidget);
    expect(h.inputController!.text, isEmpty);
    // 焦点留在这一行：连着敲下一个收件人才不用伸手去点。
    expect(
      tester.widget<TextField>(h.input).focusNode?.hasFocus,
      isTrue,
      reason: '回车把焦点交给主题栏的话，这一行之后再也收不到键盘手势',
    );
  });
}

/// 一个已经挂好写邮件页的测试台。
class _Harness {
  _Harness(this.tester, this.db, this.container);

  final WidgetTester tester;
  final AppDatabase db;
  final ProviderContainer container;

  /// 收件人输入框。**按位置取**：`Column` 的顺序是收件人、主题，而收件人这一行
  /// 的输入框是页面上第一个 `TextField`（补全下拉里刻意没有输入框）。
  Finder get input => find.byType(TextField).first;

  Finder chip(String address) =>
      find.byKey(ValueKey('recipient-chip-$address'));

  Finder get selectionBar =>
      find.byKey(const ValueKey('recipient-selection-bar'));

  Finder get invalidLine => find.byKey(const ValueKey('recipient-invalid'));

  TextEditingController? get inputController =>
      tester.widget<TextField>(input).controller;

  AppLocalizations get l10n =>
      AppLocalizations.of(tester.element(find.byType(ComposeScreen)));

  Future<void> enterText(String text) => tester.enterText(input, text);

  Future<void> pumpSettle() => tester.pumpAndSettle();
}
