import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/mail_detail/html_body_view.dart';
import 'package:mail_app/features/mail_detail/mail_detail_screen.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只有 `text/plain` 部分的邮件（GitHub 通知、很多站内信）在服务端
/// `content` 就是空串 —— `postal-mime` 对这类邮件**只给 `text`、不给 `html`**，
/// 而详情页只认 `content`，于是「明明有正文」的一封会显示成
/// 「（这封邮件没有正文）」。
///
/// 两层都要钉住，因为它们**各自都能单独复发**：
/// - 服务端（`mail-worker/src/email/email.js`）新收的信由
///   `emailUtils.textToHtml(text)` 顶上 `content`；
/// - App 这边对**存量**（已经落库的空 `content`）在 `HtmlBodyView` 之前
///   自己包一层 `<pre>`，对齐 Web 端 `content/index.vue` 的 `v-else`。
///
/// 转义那一条不是附赠：`text` 与 `content` 一样是**不可信输入**，把它裸接进
/// HTML 再交给 `HtmlWidget` 就等于 XSS，而这条兜底恰恰是「没有 HTML 可净化」
/// 的那一支 —— `sanitizeEmailHtml` 只负责它拿到的字符串，接错的那一步在它
/// 之前。
class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #cancelFor) return Future<void>.value();
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profileId = 'p1';
  const emailId = 12;
  const subject = '只有纯文本的邮件';
  // 两行 + 一个长得会溢出容器的 URL：换行必须保住、长行必须能折。
  const bodyLine1 = 'An email address (dev@example.com) was added to your account.';
  const bodyLine2 = 'Visit https://github.com/settings/emails to review it.';
  const bodyText = '$bodyLine1\n$bodyLine2';

  MailRow rowWith({String? content, String? text}) => MailRow(
        emailId: emailId,
        profileId: profileId,
        name: 'GitHub',
        sendEmail: 'noreply@github.com',
        subject: subject,
        content: content,
        text: text ?? bodyText,
        hasFullBody: true,
        type: 0,
        createTime: DateTime(2026, 1, 2, 3, 4),
      );

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpDetail(WidgetTester tester, MailRow row) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.mailDao.upsertPage(<MailRow>[row]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        bootstrapProvider.overrideWithValue(BootstrapData(
          db: db,
          tokens: TokenStore(),
          prefs: PrefsStore(await SharedPreferences.getInstance()),
        )),
        notificationServiceProvider.overrideWithValue(_SilentNotifications()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: MailDetailScreen(profileId: profileId, emailId: emailId),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 拆树并把时钟往前推一帧（drift 的流在取消订阅时会排一个零延时定时器）。
  /// 断言必须在拆树**之前** —— 空树上一个都找不到。
  Future<void> disposeDetail(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  testWidgets('content 是空串：正文按 text 渲染，而不是「没有正文」', (tester) async {
    await pumpDetail(tester, rowWith(content: ''));

    // `find.text` 是**整段精确匹配**，而 fwfh 把 `<pre>` 的内容合成了一段
    // 文本，所以这里只能按子串找。
    expect(
      find.textContaining(bodyLine1, findRichText: true),
      findsOneWidget,
      reason: '空 content 必须由 text 顶上，否则用户看到的是「（这封邮件没有正文）」',
    );
    // 换行也得保住：两行合成一行说明 `white-space: pre-wrap` 没生效。
    expect(find.textContaining(bodyLine2, findRichText: true), findsOneWidget);
    expect(find.text('（这封邮件没有正文）'), findsNothing);

    await disposeDetail(tester);
  });

  testWidgets('content 是 null（老实例的摘要行）：同样按 text 渲染', (tester) async {
    await pumpDetail(tester, rowWith(content: null));

    expect(find.textContaining(bodyLine1, findRichText: true), findsOneWidget);
    expect(find.text('（这封邮件没有正文）'), findsNothing);

    await disposeDetail(tester);
  });

  testWidgets('content 有 HTML：仍然走 HTML 那一支，text 不参与', (tester) async {
    await pumpDetail(
      tester,
      rowWith(content: '<p>html version</p>', text: 'plain version'),
    );

    expect(find.text('html version', findRichText: true), findsOneWidget);
    expect(find.text('plain version', findRichText: true), findsNothing);

    await disposeDetail(tester);
  });

  testWidgets('text 里的标签是字面量，不变成真标签（XSS 边界）', (tester) async {
    await pumpDetail(
      tester,
      rowWith(content: '', text: '<img src=x onerror=alert(1)> <b>bold</b>'),
    );

    // 兜底那一支**整个**是文本：`<b>` 不该变成粗体标签，`<img>` 更不该建出来。
    expect(find.byType(Image), findsNothing);
    expect(
      find.text('<img src=x onerror=alert(1)> <b>bold</b>', findRichText: true),
      findsOneWidget,
    );

    await disposeDetail(tester);
  });

  testWidgets('content 与 text 都空：才显示「没有正文」', (tester) async {
    await pumpDetail(tester, rowWith(content: '', text: ''));

    expect(find.text('（这封邮件没有正文）'), findsOneWidget);
    // 空正文时不该建出 `HtmlBodyView` 的空壳内容 —— 那一支也是同一句话，
    // 两处都出现说明兜底被判了两次。
    expect(find.byType(HtmlBodyView), findsOneWidget);

    await disposeDetail(tester);
  });
}
