// 写邮件页表头（发件人 / 收件人 / 主题三行）的对齐、行高与窄屏 AppBar。
//
// **为什么量几何而不是找文字**：改造前三行各写各的 `Padding + Text +
// SizedBox(12)`，label 的宽度跟着字数走（「发件邮箱」四个字 vs 「主题」两个字），
// 于是主题框比收件人框往左缩了 28px。这种偏差没有任何一条「找得到某个文字」
// 的断言能发现 —— 三行都还在、字都对、就是没对齐。所以这里量的是
// `tester.getTopLeft` 出来的 dx，以及行高、分割线。
//
// 收件人那一行的 label 在 `RecipientField` **内部**（chips 会换行，label 该对
// 「内容的第一行」还是「整块内容的顶边」，只有它自己知道），所以跨组件的那条
// 基准线用「收件人 TextField 与主题 TextField 的 dx 相等」来验。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/compose/compose_field_row.dart';
import 'package:mail_app/features/compose/compose_screen.dart';
import 'package:mail_app/features/compose/editor/compose_toolbar.dart';
import 'package:mail_app/features/compose/editor/mail_quill_editor.dart';
import 'package:mail_app/features/compose/sender_picker.dart';
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

/// 两个邮箱 —— 触发行因此**可展开**（有 `sender-trigger` 的 InkWell），
/// 与真实使用形状一致；只有一个候选时那一行连 InkWell 都不套（另一条用例
/// 在 `compose_sender_picker_test.dart` 里守着），拿它量对齐会少一层盒子。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 挂真的 `ComposeScreen`（表头三行是真的组件，单挂 `SenderField` 量不到
  /// 「三行之间对不对得齐」这件事本身）。
  Future<void> pumpCompose(WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        // 发件人是从 drift 流里递进来的，所以要给真的 `BootstrapData`：
        // 少了它 `refreshQuota()` 那条链会撞上「必须被 override」的 StateError。
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        currentProfileIdProvider.overrideWithValue('p1'),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[_profile]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(
            profileId == 'p1'
                ? const <MailboxAccount>[_boxA3, _boxA9]
                : const <MailboxAccount>[],
          ),
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
  }

  /// 三行 label / 内容用的 finder。label 的字面量从 l10n 取：文案将来改了，
  /// 这里跟着走，不至于因为「字变了」红一片。
  ({
    Finder fromLabel,
    Finder toLabel,
    Finder subjectLabel,
    Finder recipientInput,
    Finder subjectInput,
    Finder senderTrigger,
  }) headerFinders(WidgetTester tester) {
    final l10n = AppLocalizations.of(tester.element(find.byType(ComposeScreen)));
    return (
      fromLabel: find.text(l10n.composeFrom),
      toLabel: find.text(l10n.composeTo),
      subjectLabel: find.text(l10n.composeSubject),
      // 收件人在前、主题在后（`compose_esc_exit_test` 的 `TextField.at(1)`
      // 与 `compose_editor_wiring_test` 的 `findsNWidgets(2)` 都钉着这个顺序）。
      recipientInput: find.byType(TextField).first,
      subjectInput: find.byKey(const ValueKey('compose-subject')),
      senderTrigger: find.byKey(const ValueKey('compose-sender-trigger')),
    );
  }

  testWidgets('800 宽：三行 label 与内容的左边界严格一致', (tester) async {
    await pumpCompose(tester);
    final f = headerFinders(tester);

    // ① label 列：三行都从 16 起算（`kComposeFieldRowPadding.left`）。
    final fromLabel = tester.getTopLeft(f.fromLabel).dx;
    final toLabel = tester.getTopLeft(f.toLabel).dx;
    final subjectLabel = tester.getTopLeft(f.subjectLabel).dx;
    expect(toLabel, fromLabel, reason: '收件人行的 label 与发件人行 label 没对齐');
    expect(subjectLabel, fromLabel, reason: '主题行的 label 与发件人行 label 没对齐');
    expect(fromLabel, kComposeFieldRowPadding.left);

    // ② 内容列：`16 + 64 + 8 = 88`。这一条是本次改动的主诉 ——
    // 改造前主题框跟着「主题」两个字的宽度走，比收件人框缩进 28px。
    final recipientLeft = tester.getTopLeft(f.recipientInput).dx;
    final subjectLeft = tester.getTopLeft(f.subjectInput).dx;
    final senderLeft = tester.getTopLeft(f.senderTrigger).dx;
    expect(
      subjectLeft,
      recipientLeft,
      reason: '主题框与收件人框的左边界差 ${subjectLeft - recipientLeft}px —— '
          '两行的内容不在同一条竖线上，就是「没排过版」',
    );
    expect(
      senderLeft,
      recipientLeft,
      reason: '发件人触发器与收件人框的左边界不同（差 ${senderLeft - recipientLeft}px）',
    );
    final expectedLeft =
        kComposeFieldRowPadding.left + kComposeFieldLabelWidth + kComposeFieldGap;
    expect(recipientLeft, expectedLeft, reason: '内容列应当从 16 + 64 + 8 起算');
  });

  testWidgets('800 宽：单行行高 <= 48，首行 30（label 的对齐基准）', (tester) async {
    await pumpCompose(tester);

    // 主题是单行，行高应当就是「30 + 上下 6 + 6」。
    final subjectRow = tester.getSize(
      find.byKey(const ValueKey('compose-subject-row')),
    );
    expect(subjectRow.height, lessThanOrEqualTo(48.0));

    // 内容**首行**高 30：`ComposeFieldRow` 的 label 上留白是按这个数算的，
    // 它一变三行的 label 就整体偏。
    final subjectInput = tester.getSize(
      find.byKey(const ValueKey('compose-subject')),
    );
    expect(
      subjectInput.height,
      closeTo(kComposeFieldLineHeight, 1.0),
      reason: '主题框比 30 高/矮，说明 textInputAction 那一行的 contentPadding '
          '或字号变了 —— label 的对齐基准跟着变',
    );

    // 发件人行是两行（主行 + 实例名小字），比单行行高多一行小字的高度，
    // 但不该超过 64（30 + 16 + 上下 6 + 6 = 58）。
    final senderRow = tester.getSize(find.byType(SenderField));
    expect(
      senderRow.height,
      lessThanOrEqualTo(64.0),
      reason: '发件人行 ${senderRow.height} 高 —— 两行内容也不该超过 64',
    );
    // 主行（姓名/邮箱那一行）就在内容的顶部 30 里，实例名小字压在它下面。
    expect(
      tester.getTopLeft(find.text('王五 <me@a.example>')).dy,
      greaterThanOrEqualTo(tester.getTopLeft(find.byType(SenderField)).dy),
    );
  });

  testWidgets('800 宽：表头三行之间各一条 Divider(height: 1)，且都在工具栏之上',
      (tester) async {
    await pumpCompose(tester);

    final headerTop = tester.getTopLeft(find.byType(SenderField)).dy;
    final toolbarTop = tester.getTopLeft(find.byType(ComposeToolbar)).dy;

    // 只数**表头区间**里的分割线：工具栏自己底部还有一条（`ComposeToolbar`
    // 里那句 `Divider(height: 1)`），页面别处也各有各的分割线。
    final heights = <double>[];
    final count = find.byType(Divider).evaluate().length;
    for (var i = 0; i < count; i++) {
      final rect = tester.getRect(find.byType(Divider).at(i));
      if (rect.top >= headerTop - 1 && rect.bottom <= toolbarTop + 1) {
        heights.add(rect.height);
      }
    }
    expect(
      heights,
      hasLength(3),
      reason: '发件人/收件人/主题三行之间应当各有一条分割线'
          '（实际 ${heights.length} 条）—— 层次不清时用户不知道哪几行是表头',
    );
    for (final height in heights) {
      expect(
        height,
        lessThanOrEqualTo(1.5),
        reason: '分割线一律 `Divider(height: 1)`；$height 厚的那条会把表头切成两段',
      );
    }
  });

  /// 两段文字的**中线**是否在同一水平线上。
  ///
  /// 比「左边界对齐」更细的一层：`ComposeFieldRow` 给 label 的上留白是按**内容
  /// 首行**高度算的。内容若又自己加了一层 Padding、或换了字号，左边界照样齐，
  /// 中线却会差几个像素 —— 单行看不出来，三行叠在一起就是「label 有点飘」。
  void expectSameCenterY(
    WidgetTester tester,
    Finder label,
    Finder contentFirstLine,
    String what,
  ) {
    final labelCenter = tester.getRect(label).center.dy;
    final contentCenter = tester.getRect(contentFirstLine).center.dy;
    expect(
      (labelCenter - contentCenter).abs(),
      lessThanOrEqualTo(2.0),
      reason: '$what 的 label 中线 $labelCenter 与内容首行中线 $contentCenter '
          '差 ${(labelCenter - contentCenter).abs()}px —— 超过 2px 肉眼就是「飘」',
    );
  }

  testWidgets('800 宽：三行 label 与内容首行的中线误差 <= 2px', (tester) async {
    await pumpCompose(tester);
    final f = headerFinders(tester);

    // 主题：内容首行就是 TextField 里那行字（`EditableText` 的盒子高度 = 行高）。
    expectSameCenterY(
      tester,
      f.subjectLabel,
      find.descendant(of: f.subjectInput, matching: find.byType(EditableText)),
      '主题行',
    );
    // 发件人：内容首行是 30 高主行里的「姓名 <邮箱>」。
    expectSameCenterY(
      tester,
      f.fromLabel,
      find.text('王五 <me@a.example>'),
      '发件人行',
    );
  });

  testWidgets('主题行回车（next）把焦点交给正文', (tester) async {
    await pumpCompose(tester);
    final f = headerFinders(tester);

    await tester.enterText(f.subjectInput, '月报');
    await tester.pump();
    // 真实桌面上 Enter 走来的是 IME 的 next action，不是裸按键事件 ——
    // 只有 `receiveAction` 能复现那条路（`EditableText.performAction`）。
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    final editor = tester.widget<MailQuillEditor>(find.byType(MailQuillEditor));
    expect(
      editor.focusNode.hasFocus,
      isTrue,
      reason: '主题是表头最后一行，「下一项」只能是正文 —— 焦点没进去用户就得'
          '自己点一下正文才能接着写',
    );
  });

  testWidgets('点主题那一行的 label 也能把光标请进输入框', (tester) async {
    await pumpCompose(tester);
    final f = headerFinders(tester);

    // label 是「这一行」的一部分：`ComposeFieldRow` 用 translucent 的
    // GestureDetector 把整行都做成热区，否则用户得精确点到输入框里那 1px 宽
    // 的文字起点。
    await tester.tap(f.subjectLabel);
    await tester.pump();
    final field = tester.widget<TextField>(f.subjectInput);
    expect(field.focusNode?.hasFocus, isTrue);
  });

  testWidgets('800 宽：发送按钮带文字（不窄屏时形状不变）', (tester) async {
    await pumpCompose(tester);

    final appBar = find.byType(AppBar);
    expect(
      find.descendant(
        of: appBar,
        matching: find.widgetWithText(FilledButton, '发送'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('380 宽：能 pump，发送按钮只留图标但 tooltip 还在', (tester) async {
    // 整块测试面就是 380 逻辑像素宽（dpr = 1）：断点读的是 MediaQuery 的
    // 窗口宽，套一个 `SizedBox(width: 380)` 不会让 `compactOf` 变 true。
    tester.view.physicalSize = const Size(380, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpCompose(tester);
    expect(tester.takeException(), isNull, reason: '窄屏下不许有布局溢出');

    final appBar = find.byType(AppBar);
    expect(
      find.descendant(of: appBar, matching: find.text('发送')),
      findsNothing,
      reason: '窄屏的发送按钮只留图标 —— 带两个字会把 AppBar 挤到溢出',
    );
    expect(
      find.descendant(of: appBar, matching: find.byTooltip('发送')),
      findsOneWidget,
      reason: '文字去掉了，tooltip 必须留着：否则这个按钮就没有任何可读名字',
    );
    expect(
      find.descendant(of: appBar, matching: find.byType(FilledButton)),
      findsNothing,
      reason: '窄屏不该还是那颗带字的 FilledButton',
    );
    // 表头三行在窄屏下同样要在，`输入区`仍从同一条边界起算。
    final f = headerFinders(tester);
    expect(f.senderTrigger, findsOneWidget);
    expect(
      tester.getTopLeft(f.subjectInput).dx,
      tester.getTopLeft(f.recipientInput).dx,
      reason: '窄屏下三行的对齐同样不能垮',
    );
  });

  testWidgets('320 宽（最窄档）：不溢出，发送按钮仍是图标', (tester) async {
    // 320 是这套断点里真正会出事的那一档（spec §9 风险 2 用的也是它）：
    // 关闭 + 立即发送 + 发送 + 标题四样挤在一行，宽屏那版「发送」两个字在这里
    // 直接把 AppBar 顶到溢出。`RenderFlex overflowed` 在测试里就是一条能被
    // `takeException` 抓到的异常，不需要去数条纹。
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpCompose(tester);
    expect(
      tester.takeException(),
      isNull,
      reason: '320 宽下 AppBar 与表头三行都不许溢出',
    );

    final appBar = find.byType(AppBar);
    expect(
      find.descendant(of: appBar, matching: find.text('发送')),
      findsNothing,
      reason: '最窄档的发送按钮只留图标',
    );
    expect(
      find.descendant(of: appBar, matching: find.byTooltip('发送')),
      findsOneWidget,
    );
  });

  testWidgets('发件人面板贴在触发行下方 4px（触发行改高度后锚点不能漂）', (tester) async {
    await pumpCompose(tester);
    final trigger = find.byKey(const ValueKey('compose-sender-trigger'));
    final triggerRect = tester.getRect(trigger);

    await tester.tap(find.byKey(const ValueKey('sender-trigger')));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('sender-sheet'));
    expect(sheet, findsOneWidget, reason: '点触发行要能展开面板');

    // `CompositedTransformTarget` 锚在触发行左下、follower 对左上、偏移 (0, 4)。
    // 触发行从「Padding + 两行 Column」改成「30 主行 + 小字」之后，这个锚点
    // 仍是那条 CompositionTarget 的盒子 —— 这条用例守着它没有跟着漂。
    final sheetRect = tester.getRect(sheet);
    expect(
      sheetRect.top,
      closeTo(triggerRect.bottom + 4, 0.5),
      reason: '面板顶边 ${sheetRect.top} 应当等于触发行底边 ${triggerRect.bottom} + 4',
    );
    expect(
      sheetRect.left,
      closeTo(triggerRect.left, 0.5),
      reason: '面板左边界应当与触发行（= 内容列）同一条竖线',
    );
  });
}
