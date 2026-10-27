import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/mail_list/mail_row_tile.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/profile_providers.dart';

/// 「分栏形态下正在看的那一行要高亮」这条需求的两个可见面。
///
/// 钉住的是**最左那一格的排他性**：选中竖条与聚合视图的实例色带抢同一个
/// 位置。两份都画的话，选中那一行会比上下两行宽 3px —— 列表里所有标题一起
/// 往右挪一点，而「选中/取消选中」在用户眼里就变成了一次列表抖动。这个
/// 溢出量小到肉眼未必立刻发现，所以只能靠尺寸断言钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profile = Profile(
    id: 'p1',
    baseUrl: 'https://x/api',
    email: 'a@x.com',
    userId: 7,
  );

  final row = MailRow(
    emailId: 3,
    profileId: profile.id,
    name: '发件人',
    subject: '主题',
    text: '正文摘要',
    type: 0,
    unread: 1,
    createTime: DateTime(2026, 1, 2, 3, 4),
  );

  Future<void> pump(
    WidgetTester tester, {
    required bool selected,
    required bool band,
    bool selectionMode = false,
    VoidCallback? onCheckboxToggle,
    MailRow? mail,
  }) async {
    await tester.pumpWidget(ProviderScope(
      // 不写 `<Override>[]`：`Override` 在 riverpod 3 里没有对外导出
      // （见 `mail_list_deactivate_test.dart` 里同一句注释）。
      overrides: [
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[profile]),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          // 定宽：两个形态宽度必须一模一样才谈得上「不抖」。
          body: SizedBox(
            width: 400,
            child: MailRowTile(
              row: mail ?? row,
              showInstanceBand: band,
              selected: selected,
              selectionMode: selectionMode,
              onCheckboxToggle: onCheckboxToggle,
              onTap: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  final band = find.byKey(const ValueKey<String>('selectedBand'));
  final surface = find.byKey(const ValueKey<String>('rowSurface'));

  /// 整行底色。它回答的是「这一片是选中区」，大小写在这里无所谓。
  Color? surfaceColor(WidgetTester tester) =>
      tester.widget<Container>(surface).color;

  testWidgets('没选中时不画选中竖条', (tester) async {
    await pump(tester, selected: false, band: true);

    expect(band, findsNothing);
    expect(find.text('主题'), findsOneWidget);
  });

  testWidgets('选中的那一行左侧有竖条，且整行底色与没选中时不同', (tester) async {
    await pump(tester, selected: false, band: false);
    final plain = surfaceColor(tester);

    await pump(tester, selected: true, band: false);

    expect(band, findsOneWidget);
    expect(
      surfaceColor(tester),
      isNotNull,
      reason: '选中行要有整行底色（竖条只说明「是这一行」）',
    );
    expect(surfaceColor(tester), isNot(plain));
  });

  /// 未读行整行铺一层极淡的主题色，已读行保持透明。
  ///
  /// 旧方案只靠字重（w600/w700）区分未读：一列几十行里扫视时，字重差在
  /// 「不看具体文字」的余光里几乎读不出来，而底色是一整块，能直接回答
  /// 「这一片里有几封没读」。这里同时钉住它是**浅**的：未读色的密度必须
  /// 低于选中色（两者同色相，一档之差在列表里认不出来）。
  testWidgets('未读收件行有浅主题底色，已读行没有', (tester) async {
    final unreadRow = MailRow(
      emailId: 5,
      profileId: profile.id,
      name: '发件人',
      subject: '主题',
      type: MailType.receive,
      // `unread` 的语义与字段名相反：0 = 未读、1 = 已读。
      unread: UnreadState.unread,
      createTime: DateTime(2026, 1, 2, 3, 4),
    );

    await pump(tester, selected: false, band: false, mail: unreadRow);
    final unreadTint = surfaceColor(tester);
    expect(unreadTint, isNotNull, reason: '未读行要有整行底色');

    // 选中态：同一个色相、更重的一档。
    await pump(tester, selected: true, band: false, mail: unreadRow);
    final selectedTint = surfaceColor(tester)!;
    expect(selectedTint.a, greaterThan(unreadTint!.a),
        reason: '「正开着」必须比「没读」重，否则两种状态看起来一样');

    await pump(tester, selected: false, band: false);
    expect(surfaceColor(tester), isNull, reason: '已读行不铺底色');
  });

  /// 选中与未读撞在同一行时**不做混合**：整行底色只取选中那一支。叠加会
  /// 混出第三种颜色，而「这一行正开着」必须比「这一行没读」更硬。未读在
  /// 选中行上仍有字重与信封两个出口，信息不丢。
  testWidgets('选中底色压过未读底色', (tester) async {
    final unreadRow = MailRow(
      emailId: 6,
      profileId: profile.id,
      name: '发件人',
      subject: '主题',
      type: MailType.receive,
      unread: UnreadState.unread,
      createTime: DateTime(2026, 1, 2, 3, 4),
    );

    await pump(tester, selected: false, band: false, mail: unreadRow);
    final unreadTint = surfaceColor(tester);

    await pump(tester, selected: true, band: false, mail: unreadRow);
    expect(surfaceColor(tester), isNot(unreadTint));
  });

  /// 发件方向没有未读语义（服务端只在收信时写 `unread`），`unread == 0`
  /// 不能给发件行上底色 —— 否则发件箱里每一行都会是「未读」。
  testWidgets('发件行不因 unread=0 铺底色', (tester) async {
    final sentRow = MailRow(
      emailId: 7,
      profileId: profile.id,
      sendEmail: 'me@x.com',
      toEmail: 'you@example.net',
      subject: '主题',
      type: MailType.send,
      unread: UnreadState.unread,
      createTime: DateTime(2026, 1, 2, 3, 4),
    );

    await pump(tester, selected: false, band: false, mail: sentRow);
    expect(surfaceColor(tester), isNull);
  });

  /// 聚合视图里实例色带与选中竖条是**同一个位置**（最左 3px）。
  /// 两条都画 = 这一行比别的行宽 3px —— 选中一次列表会整体右移一下。
  testWidgets('选中竖条压过实例色带：宽度与没选中时一致', (tester) async {
    await pump(tester, selected: false, band: true);
    final plainWidth = tester.getSize(find.byType(MailRowTile)).width;

    await pump(tester, selected: true, band: true);

    expect(band, findsOneWidget);
    expect(tester.getSize(find.byType(MailRowTile)).width, plainWidth);
  });

  /// 多选那两条：**复选框替掉头像位，行宽与文字位置一分不动**。
  ///
  /// 这正是上面那条宽度断言关心的同一件事的第二种形态 —— 多留一个控件在
  /// 旁边，「进入多选」这个动作本身就会让整列标题平移一次。
  testWidgets('多选：复选框替掉头像，宽度与普通行一模一样', (tester) async {
    await pump(tester, selected: false, band: false);
    final plainWidth = tester.getSize(find.byType(MailRowTile)).width;
    final plainSubject = tester.getTopLeft(find.text('主题'));

    var toggled = 0;
    await pump(
      tester,
      selected: false,
      band: false,
      selectionMode: true,
      onCheckboxToggle: () => toggled++,
    );

    expect(find.byKey(const ValueKey<String>('selectionCheckbox')),
        findsOneWidget);
    expect(tester.getSize(find.byType(MailRowTile)).width, plainWidth,
        reason: '复选框外框 40×40 与头像直径相同');
    expect(tester.getTopLeft(find.text('主题')), plainSubject,
        reason: '主题的左边距不该因为进了多选而挪');

    await tester.tap(find.byKey(const ValueKey<String>('selectionCheckbox')));
    expect(toggled, 1);
  });

  testWidgets('多选但没给 onCheckboxToggle：不画复选框（发件箱那条路）',
      (tester) async {
    await pump(tester, selected: false, band: false, selectionMode: true);

    expect(find.byKey(const ValueKey<String>('selectionCheckbox')), findsNothing);
  });

  /// 发件人没有显示名时，这一格退回**原始地址** —— 那时要把用户名加重：
  /// 一列地址里域名几乎恒定，扫视时先认出来的是「谁」。带显示名的行不受
  /// 影响（没有地址就没有加粗的片段），这条一起钉住，免得哪天把名字也切了。
  testWidgets('发件人地址：用户名加粗，@域名常规；显示名不受影响', (tester) async {
    final addressRow = MailRow(
      emailId: 4,
      profileId: profile.id,
      sendEmail: 'box@example.net',
      name: '',
      subject: '主题',
      text: '正文摘要',
      type: 0,
      // 注意 `unread` 是 0 未读 / 1 已读（与字段名的直觉相反，见 AGENTS 红线）。
      unread: 1,
      createTime: DateTime(2026, 1, 2, 3, 4),
    );

    await pump(tester, selected: false, band: false, mail: addressRow);

    final address = tester.widget<Text>(find.text('box@example.net'));
    final addressSpans =
        (address.textSpan! as TextSpan).children!.cast<TextSpan>().toList();
    expect(addressSpans.map((s) => s.text), <String>['box', '@example.net']);
    // 已读那行：基础字重 w500，用户名再重一档（未读是 w600 / w700）。
    expect(address.style?.fontWeight, FontWeight.w500);
    expect(addressSpans.first.style?.fontWeight, FontWeight.w600);
    expect(addressSpans.last.style, isNull);

    await pump(tester, selected: false, band: false);

    final named = tester.widget<Text>(find.text('发件人'));
    final namedSpans =
        (named.textSpan! as TextSpan).children!.cast<TextSpan>().toList();
    expect(namedSpans.map((s) => s.text), <String>['发件人']);
    expect(namedSpans.single.style, isNull);
  });
}
