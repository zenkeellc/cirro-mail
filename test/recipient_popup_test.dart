// 收件人自动补全下拉：出现/高亮/键盘与鼠标选中/两级 Esc。
//
// 这里必须挂**真的** `ComposeScreen`：下拉的候选来自
// `ComposeController.setRecipientInput` → 本地库 `suggestRecipients`，而「选中
// 之后焦点还在不在输入框」「Esc 会不会顺手把页面关掉」都是这一行与页面之间的
// 接线问题 —— 单挂 `RecipientField` 造一个假控制器，这些一条都测不到。
//
// 候选是**真的写进本地库**（`localDao.recordRecipients`），不 mock DAO：这条链路
// 上一次坏掉的表现就是「补全框空着但没有任何报错」。
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
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
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

/// 写进「最近联系人」的两条。地址与姓名都带 `zh`，方便用同一个查询词过滤出两行。
const List<({String address, String name})> _history =
    <({String address, String name})>[
      (address: 'zhang@a.example', name: '张三'),
      (address: 'zhao@a.example', name: '赵四'),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 挂真的写邮件页，并往本地库塞好最近联系人。
  ///
  /// 排序是「使用次数 → 最近使用」：这里让「张三」记两次，于是补全的第一行
  /// 稳定是它 —— 键盘用例要靠这个顺序断言「↓ 之后回车选到的是第二个」。
  Future<_Harness> pumpCompose(WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.localDao.recordRecipients('p1', _history);
    await db.localDao.recordRecipients('p1', _history.take(1));

    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
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
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const ComposeScreen()),
    );
    await tester.pumpAndSettle();
    return _Harness(tester, db);
  }

  Finder suggestionRow(String address) =>
      find.byKey(ValueKey('recipient-suggestion-$address'));

  testWidgets('打一个字就弹出下拉：姓名 + 地址都在、页面上仍然只有 2 个 TextField', (tester) async {
    final h = await pumpCompose(tester);
    expect(
      find.byKey(const ValueKey('recipient-suggestions')),
      findsNothing,
      reason: '还没输入时不该有下拉（候选是随查询词查出来的）',
    );

    await h.enterText('zh');
    await h.pumpSettle();

    expect(find.byKey(const ValueKey('recipient-suggestions')), findsOneWidget);
    expect(suggestionRow('zhang@a.example'), findsOneWidget);
    expect(suggestionRow('zhao@a.example'), findsOneWidget);
    expect(find.text('张三'), findsOneWidget, reason: '有姓名就显示姓名');
    expect(
      find.text('zhang@a.example'),
      findsOneWidget,
      reason: '地址也要在 —— 同名联系人只靠姓名分不出来',
    );
    expect(
      find.byType(TextField),
      findsNWidgets(2),
      reason: '这个下拉里**不能**再放搜索框：页面上的 TextField 总数必须还是 2',
    );
  });

  testWidgets('聚焦空输入框：直接列出最近联系人（不用先打字）', (tester) async {
    final h = await pumpCompose(tester);
    await tester.tap(h.input);
    await h.pumpSettle();
    expect(
      find.byKey(const ValueKey('recipient-suggestions')),
      findsOneWidget,
      reason: '「最近联系人」在空输入框上才是最该出现的东西 —— 一聚焦就要有东西可点',
    );
    expect(suggestionRow('zhang@a.example'), findsOneWidget);
  });

  testWidgets('每一行有首字母头像，且命中的那几个字被加亮', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('zh');
    await h.pumpSettle();

    expect(
      find.descendant(
        of: suggestionRow('zhang@a.example'),
        matching: find.text('张'),
      ),
      findsOneWidget,
      reason: '首字母头像：一个联系人一条，光靠文字行在长列表里不显眼',
    );

    // 命中高亮是纯样式，只能翻 RichText 的 span 看 —— `zh` 命中的是地址开头。
    final address = tester.widget<Text>(find.text('zhang@a.example'));
    final spans = (address.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(
      spans.any((span) => span.style?.fontWeight == FontWeight.w700),
      isTrue,
      reason: '用户得看出「我敲的这几个字被认成了哪一段」，否则不知道候选为什么出现',
    );
  });

  testWidgets('过滤：查询词只命中一个时只剩一行', (tester) async {
    final h = await pumpCompose(tester);
    // 张三/赵四的地址都含 `zha`，但姓名 `赵四`/`张三` 都不含 `zhan` 以外的
    // 词 —— 用 `zhang@` 精确命中第一个。
    await h.enterText('zhang@');
    await h.pumpSettle();
    expect(suggestionRow('zhang@a.example'), findsOneWidget);
    expect(suggestionRow('zhao@a.example'), findsNothing);
  });

  testWidgets('↓ 换高亮、回车选中的是高亮那一行；选完焦点还在输入框', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('zh');
    await h.pumpSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await h.pumpSettle();

    expect(
      h.chip('zhao@a.example'),
      findsOneWidget,
      reason: '↓ 把高亮移到第二行，回车应当选第二行而不是永远选第一条',
    );
    expect(h.chip('zhang@a.example'), findsNothing);
    expect(h.inputController!.text, isEmpty);
    expect(
      tester.widget<TextField>(h.input).focusNode?.hasFocus,
      isTrue,
      reason: '选完要把焦点留在输入框：连选几个收件人才不用每选一次点一下',
    );
  });

  testWidgets('Tab 也选中高亮行（键盘流不用离开输入框）', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('zh');
    await h.pumpSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await h.pumpSettle();
    expect(h.chip('zhang@a.example'), findsOneWidget);
  });

  testWidgets('鼠标点一行就收下', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('zh');
    await h.pumpSettle();

    await tester.tap(suggestionRow('zhao@a.example'));
    await h.pumpSettle();
    expect(h.chip('zhao@a.example'), findsOneWidget);
    expect(
      tester.widget<TextField>(h.input).focusNode?.hasFocus,
      isTrue,
      reason: '点下拉行不能把焦点抢走（那样键盘手势全失效）',
    );
  });

  // 桌面平台上「点下拉行」是最容易坏的一条：`EditableText` 在 pointer-down
  // 就判 outside 并 unfocus，不等抬手 —— 面板那时已经被收掉，行上的 `onTap`
  // 永远等不到。所以面板必须包在 `TextFieldTapRegion` 里（与输入框同组）。
  // 这条用例显式切 macOS，就是为了把这条坑钉住。
  testWidgets('macOS：点下拉行能收下地址，且焦点没跑', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final h = await pumpCompose(tester);
      await h.enterText('zh');
      await h.pumpSettle();

      await tester.tap(suggestionRow('zhao@a.example'));
      await h.pumpSettle();
      expect(h.chip('zhao@a.example'), findsOneWidget);
      expect(
        tester.widget<TextField>(h.input).focusNode?.hasFocus,
        isTrue,
        reason: '点一下候选行不能让键盘流断掉',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('选完一个下拉还开着，可以接着选第二个', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('zh');
    await h.pumpSettle();

    await tester.tap(suggestionRow('zhang@a.example'));
    await h.pumpSettle();
    expect(h.chip('zhang@a.example'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recipient-suggestions')),
      findsOneWidget,
      reason: '下拉要留住 —— 收件人一次写两三个是常态，每选一次都要重新打字最烦人',
    );
    expect(
      suggestionRow('zhang@a.example'),
      findsNothing,
      reason: '已经收下的不该再列出来',
    );

    await tester.tap(suggestionRow('zhao@a.example'));
    await h.pumpSettle();
    expect(h.chip('zhao@a.example'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recipient-suggestions')),
      findsNothing,
      reason: '候选都被收完了，下拉应当自己收起来',
    );
  });

  testWidgets('Esc 两级：第一下只关下拉、页面还在；第二下才关页', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('zh');
    await h.pumpSettle();
    expect(find.byKey(const ValueKey('recipient-suggestions')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await h.pumpSettle();
    expect(
      find.byKey(const ValueKey('recipient-suggestions')),
      findsNothing,
      reason: '第一级 Esc 只关下拉',
    );
    expect(
      find.byType(ComposeScreen),
      findsOneWidget,
      reason: '用户想取消的是补全，不是整封邮件 —— Esc 必须能分两级',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await h.pumpSettle();
    expect(
      find.byType(ComposeScreen),
      findsNothing,
      reason: '下拉已经关了，第二次 Esc 交回页面（= 离开写邮件页）',
    );
  });

  testWidgets('Esc 关掉下拉之后，回车不再替用户选补全', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('zh');
    await h.pumpSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await h.pumpSettle();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await h.pumpSettle();

    expect(
      h.chip('zhang@a.example'),
      findsNothing,
      reason: '用户刚按 Esc 说「别替我选」，回车再把第一条塞进来就是打脸',
    );
    expect(
      find.text(h.l10n.composeRecipientInvalid),
      findsOneWidget,
      reason: '「zh」不是地址，回车应当按原样提交并报错',
    );
  });

  testWidgets('焦点离开收件人这一行时下拉收起', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('zh');
    await h.pumpSettle();
    expect(find.byKey(const ValueKey('recipient-suggestions')), findsOneWidget);

    // 点正文：下拉是浮层，允许盖住主题那一行（它就是「压在内容上面」的东西），
    // 所以「点别处收起来」要挑一个**不在面板矩形里**的位置。
    await tester.tap(find.byType(MailQuillEditor));
    await h.pumpSettle();
    expect(find.byKey(const ValueKey('recipient-suggestions')), findsNothing);
  });

  testWidgets('无障碍：下拉行是 button，标签是「姓名 <地址>」', (tester) async {
    final h = await pumpCompose(tester);
    final semantics = tester.ensureSemantics();
    await h.enterText('zh');
    await h.pumpSettle();

    final row = tester.getSemantics(suggestionRow('zhang@a.example'));
    final data = row.getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(
      row.label,
      '张三 <zhang@a.example>',
      reason: '读屏要一次念完「谁、什么地址」—— 分成两段会让用户听完姓名还得找地址',
    );
    semantics.dispose();
  });

  testWidgets('查询词一个都不匹配时下拉不存在', (tester) async {
    final h = await pumpCompose(tester);
    await h.enterText('qqq');
    await h.pumpSettle();
    expect(find.byKey(const ValueKey('recipient-suggestions')), findsNothing);
  });
}

/// 一个已经挂好写邮件页的测试台。
class _Harness {
  _Harness(this.tester, this.db);

  final WidgetTester tester;
  final AppDatabase db;

  Finder get input => find.byType(TextField).first;

  Finder chip(String address) =>
      find.byKey(ValueKey('recipient-chip-$address'));

  TextEditingController? get inputController =>
      tester.widget<TextField>(input).controller;

  AppLocalizations get l10n =>
      AppLocalizations.of(tester.element(find.byType(ComposeScreen)));

  Future<void> enterText(String text) => tester.enterText(input, text);

  Future<void> pumpSettle() => tester.pumpAndSettle();
}
