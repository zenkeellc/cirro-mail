import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/theme/avatar_colors.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/mail_list/mail_row_tile.dart';
import 'package:mail_app/features/mail_list/sender_avatar.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/profile_providers.dart';

/// 列表行这三处新视觉的可见面：**发件人头像**、**未读信封**、**附件标记**。
///
/// 三者的共同点是「它们都是**状态**的显示，而不只是装饰」—— 所以每个都要
/// 钉住「什么时候**不**显示」，那才是容易写错的一半：
/// - 头像：发件人空的时候要回落到 `?` 而不是崩/空白；
/// - 信封：发件行**没有**未读语义（服务端不写 `type=1` 的 `unread`），
///   照搬收件那套会让所有发出去的信都显示成未读；
/// - 附件：附件数没同步回来时不能假装是 0（那会给一个会变的标记）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profile = Profile(
    id: 'p1',
    baseUrl: 'https://x/api',
    email: 'a@x.com',
    userId: 7,
  );

  MailRow mail({
    String name = '张三',
    String sendEmail = 'zhangsan@example.com',
    int type = MailType.receive,
    int unread = 0,
    bool hasFullBody = true,
    int attachmentCount = 0,
  }) =>
      MailRow(
        emailId: 3,
        profileId: profile.id,
        name: name,
        sendEmail: sendEmail,
        subject: '主题',
        text: '正文摘要',
        type: type,
        // **0 = 未读、1 = 已读**（与字段名直觉相反）。
        unread: unread,
        hasFullBody: hasFullBody,
        attachmentCount: attachmentCount,
        createTime: DateTime(2026, 1, 2, 3, 4),
      );

  Future<void> pump(WidgetTester tester, MailRow row) async {
    await tester.pumpWidget(ProviderScope(
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
          body: SizedBox(
            width: 400,
            child: MailRowTile(row: row, onTap: () {}),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  final avatar = find.byType(SenderAvatar);
  final unreadEnvelope = find.byKey(const ValueKey<String>('unreadEnvelope'));
  final readEnvelope = find.byKey(const ValueKey<String>('readEnvelope'));
  final clip = find.byIcon(Icons.attach_file);

  /// 头像上那个字。
  String avatarLetter(WidgetTester tester) =>
      tester.widget<Text>(find.descendant(of: avatar, matching: find.byType(Text)))
          .data!;

  Color avatarColor(WidgetTester tester) =>
      (tester.widget<Container>(find.descendant(
        of: avatar,
        matching: find.byType(Container),
      )).decoration! as BoxDecoration)
          .color!;

  group('发件人头像', () {
    testWidgets('每个收件行都有一个，字取发件人显示名', (tester) async {
      await pump(tester, mail(name: '张三'));

      expect(avatar, findsOneWidget);
      expect(avatarLetter(tester), '张');
    });

    testWidgets('颜色取自发件地址：同一个地址永远同色，不同地址色不同',
        (tester) async {
      await pump(tester, mail(sendEmail: 'bob@example.com'));
      final first = avatarColor(tester);

      // 换个显示名、同一个地址 —— 颜色必须不变（改昵称不该换头像色）。
      await pump(tester, mail(name: 'Robert', sendEmail: 'bob@example.com'));
      expect(avatarColor(tester), first);

      await pump(tester, mail(sendEmail: 'carol@example.com'));
      expect(avatarColor(tester), isNot(first));
    });

    testWidgets('没有发件人名字时回落成「未知」的第一个字，不崩', (tester) async {
      await pump(tester, mail(name: '', sendEmail: ''));

      expect(avatar, findsOneWidget);
      expect(avatarLetter(tester), '未',
          reason: '`displaySender` 与这里都回落到 l10n.unknown');
    });

    testWidgets('发件行用本地发件地址取色（那一行显示的是收件人）', (tester) async {
      await pump(tester, mail(
        sendEmail: 'me@x.com',
        type: MailType.send,
      ));

      expect(avatarColor(tester), AvatarColors.of('me@x.com'));
    });
  });

  group('未读信封', () {
    testWidgets('未读收件行：合着的信封', (tester) async {
      await pump(tester, mail(unread: 0));

      expect(unreadEnvelope, findsOneWidget);
      expect(readEnvelope, findsNothing);
    });

    testWidgets('已读收件行：拆开的信封', (tester) async {
      await pump(tester, mail(unread: 1));

      expect(readEnvelope, findsOneWidget);
      expect(unreadEnvelope, findsNothing);
    });

    testWidgets('发件行恒用拆开的那个，不显示未读', (tester) async {
      // 服务端只在收信时写 `unread`，所以发件行的 0 **不是**未读。
      await pump(tester, mail(type: MailType.send, unread: 0));

      expect(readEnvelope, findsOneWidget);
      expect(unreadEnvelope, findsNothing,
          reason: '照搬收件那套会让所有发出去的信都显示成未读');
      expect(find.text('主题'), findsOneWidget);
    });

    testWidgets('标题行那个信封取代了原来发件人左边那个未读点', (tester) async {
      // 一个状态只该有一个显示位置。原来未读是发件人左边一颗 8px 圆点，
      // 现在归信封；两个都在的话用户要猜哪个是权威的。
      await pump(tester, mail(unread: 0));

      expect(unreadEnvelope, findsOneWidget, reason: '未读要有地方显示');
      final dots = tester.widgetList<Container>(find.byType(Container)).where(
            (c) =>
                c.decoration is BoxDecoration &&
                (c.decoration! as BoxDecoration).shape == BoxShape.circle &&
                c.constraints?.maxWidth == 8,
          );
      expect(dots, isEmpty, reason: '原来那颗未读点必须已经删掉');
    });

    testWidgets('「正文未同步」的灰点还在原位（且只有一个点）', (tester) async {
      await pump(tester, mail(hasFullBody: false));

      // 它原来紧跟在未读点后面，靠「更小 + 更淡 + 位置紧随」与之区分。
      // 未读点没了之后它是唯一的一个点，位置与 tooltip 都不该动。
      final tooltip = find.byTooltip('正文尚未同步');
      expect(tooltip, findsOneWidget);
      final box = tester.widget<Container>(find.descendant(
        of: tooltip,
        matching: find.byType(Container),
      ));
      expect(box.constraints?.maxWidth, 6);
    });
  });

  group('附件标记', () {
    testWidgets('有附件时画回形针和数量', (tester) async {
      await pump(tester, mail(attachmentCount: 3));

      expect(clip, findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('没有附件时不画', (tester) async {
      await pump(tester, mail(attachmentCount: 0));

      expect(clip, findsNothing);
    });

    testWidgets('正文还没同步时不画 —— 那会儿的 0 是「还不知道」',
        (tester) async {
      // 附件数来自列表查询的子查询，而摘要行的附件还没同步回来：
      // 这时候显示 0 个或「有附件」都是猜的。
      await pump(tester, mail(hasFullBody: false, attachmentCount: 0));

      expect(clip, findsNothing);
    });

    testWidgets('正文齐了、附件数为 0 时不画（与「还不知道」是两回事）',
        (tester) async {
      await pump(tester, mail(hasFullBody: true, attachmentCount: 0));

      expect(clip, findsNothing);
    });
  });
}
