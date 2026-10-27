import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/core/theme/avatar_colors.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/recipient.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/mail_detail/mail_detail_screen.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 打开详情时会顺手撤掉这条通知（见 `MailDetailScreen._openOnce`）。测试里
/// 那会真的去建平台插件、失败一次、留一行与本题无关的日志。换成空实现 ——
/// 形状照 `test/mail_detail_header_test.dart` 的 `_SilentNotifications`。
class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #cancelFor) return Future<void>.value();
    return null;
  }
}

/// 还没配 AI。**必须覆盖**：真身 `build` 会去读钥匙串（平台通道），在测试里
/// 那个调用会在用例结束之后才失败，留一句与本文件无关的话。
class _UnconfiguredAiSettings extends AiSettingsController {
  @override
  Future<AiSettings> build() async => const AiSettings();
}

/// 详情页头部（v2）与「全部回复」。
///
/// 这一组守的是四件事，它们错了都**不报错**、只是界面上少点什么：
///
/// 1. 发件人区真的把「谁发的」说清楚了 —— 头像取的是 [`AvatarColors`] 的
///    发件人色（不是实例色：实例已由上方那条色带表达）；
/// 2. 收件人详情**默认收起**、点开能看到抄送/密送、再点收起 —— 这是渐进披露
///    的全部行为，少一环就变成「点开之后关不掉」或「一直摊着」；
/// 3. 「全部回复」只在收件方向出现（已发送件回复自己没有意义）；
/// 4. 窄屏（500）不炸、次要动作真的收进了 ⋯ 菜单，而且菜单里那一项**能用**
///    （点下去开出的是 `mode=replyAll` 的写邮件页，不是别的模式）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profileId = 'p1';
  const emailId = 12;
  const subject = '头部要验的一封邮件';

  final l10n = _l10nHolder();

  MailRow mail({
    int type = MailType.receive,
    List<Recipient> recipients = const <Recipient>[],
    List<Recipient> cc = const <Recipient>[],
    List<Recipient> bcc = const <Recipient>[],
  }) =>
      MailRow(
        emailId: emailId,
        profileId: profileId,
        name: 'Alice',
        sendEmail: 'alice@x.com',
        subject: subject,
        text: '正文',
        content: '<p>正文</p>',
        hasFullBody: true,
        type: type,
        recipients: recipients,
        cc: cc,
        bcc: bcc,
        createTime: DateTime.utc(2026, 1, 2, 3, 4),
      );

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// 建一棵「详情页能自己跑起来」的树。
  ///
  /// 用 `GoRouter` 而不是 `MaterialApp`：第 4 条要在窄屏的 ⋯ 菜单里点
  /// 「全部回复」，那个动作会 `context.push` 到写邮件页 —— 没有路由表就是
  /// 一个 `GoError`，测出来的东西与「折叠对不对」无关。写邮件页用**代替品**
  /// （把 `mode` 参数打成一行字）：本文件不关心写邮件页本身。
  ///
  /// [width] 是**窗口**宽：500 = compact，1000 = 宽屏（顶栏图标直出）。
  Future<void> pumpDetail(
    WidgetTester tester,
    MailRow row, {
    double width = 1000,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.mailDao.upsertPage(<MailRow>[row]);

    final router = GoRouter(
      initialLocation: '/detail',
      routes: <RouteBase>[
        GoRoute(
          path: '/detail',
          builder: (context, state) =>
              const MailDetailScreen(profileId: profileId, emailId: emailId),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) => Scaffold(
            body: Text('compose:${state.uri.queryParameters['mode']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        bootstrapProvider.overrideWithValue(BootstrapData(
          db: db,
          tokens: TokenStore(),
          prefs: PrefsStore(await SharedPreferences.getInstance()),
        )),
        notificationServiceProvider.overrideWithValue(_SilentNotifications()),
        aiSettingsProvider.overrideWith(_UnconfiguredAiSettings.new),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 拆树并把时钟往前推一帧（drift 的流在取消订阅时排的是零延时定时器）。
  /// **断言必须在它之前** —— 空树上一个都找不到。
  Future<void> disposeDetail(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  final avatarKey = find.byKey(const ValueKey<String>('detail-sender-avatar'));

  testWidgets('发件人区：姓名 / 地址 / 头像，头像取发件人的哈希色', (tester) async {
    await pumpDetail(tester, mail());

    expect(find.text('Alice'), findsOneWidget);
    // `EmailAddressText` 是 `Text.rich`，`find.text` 比的是拼起来的纯文本。
    expect(find.text('alice@x.com'), findsOneWidget);

    expect(avatarKey, findsOneWidget);
    final avatar = tester.widget<Container>(
      find.descendant(of: avatarKey, matching: find.byType(Container)),
    );
    final decoration = avatar.decoration! as BoxDecoration;
    expect(
      decoration.color,
      AvatarColors.of('alice@x.com'),
      reason: '头像要按**发件地址**取色（同一个发件人永远同一个颜色）；'
          '取成实例色的话，聚合视图里它会和上方那条实例色带重复',
    );
    expect(decoration.shape, BoxShape.circle);
    // 首字母是显示名的首字（`AvatarColors.initial`）。
    expect(find.descendant(of: avatarKey, matching: find.text('A')),
        findsOneWidget);

    await disposeDetail(tester);
  });

  testWidgets('收件人详情：默认收起 → 点开见到抄送/密送 → 再点收起', (tester) async {
    await pumpDetail(
      tester,
      mail(
        recipients: const <Recipient>[Recipient(address: 'bob@x.com')],
        cc: const <Recipient>[Recipient(address: 'carol@x.com')],
        bcc: const <Recipient>[Recipient(address: 'secret@x.com')],
      ),
    );

    // 收起时只有一行摘要：`收件人  bob@x.com`（标签 + 两个空格 + 地址）。
    expect(
      find.text('${l10n.detailTo}  bob@x.com'),
      findsOneWidget,
      reason: '默认收起 —— 四行地址全摊开会把正文挤出首屏',
    );
    expect(find.text('carol@x.com'), findsNothing);
    expect(find.text('secret@x.com'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    // 展开
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    expect(find.text('carol@x.com'), findsOneWidget);
    expect(
      find.text('secret@x.com'),
      findsOneWidget,
      reason: '密送是收信方的信息，详情页要如实显示（只是「回复全部」不带它）',
    );
    expect(find.text('bob@x.com'), findsOneWidget);
    // 发件人那一行：`Alice <alice@x.com>`
    expect(find.text('Alice <alice@x.com>'), findsOneWidget);
    expect(find.text(l10n.detailHideDetails), findsOneWidget);

    // 再点收起
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();

    expect(find.text('carol@x.com'), findsNothing);
    expect(find.text('secret@x.com'), findsNothing);
    expect(find.text('${l10n.detailTo}  bob@x.com'), findsOneWidget);

    await disposeDetail(tester);
  });

  testWidgets('「全部回复」只在收件方向出现', (tester) async {
    await pumpDetail(tester, mail());

    expect(find.byIcon(Icons.reply_all), findsOneWidget);
    expect(find.byTooltip(l10n.replyAll), findsOneWidget);
    // 位置：回复 → 全部回复 → 转发（顺序错了不报错，只是手感变差）。
    // 比横坐标而不是像素尺寸：图标尺寸与内边距会漂，次序不会。
    final replyX = tester.getTopLeft(find.byIcon(Icons.reply)).dx;
    final replyAllX = tester.getTopLeft(find.byIcon(Icons.reply_all)).dx;
    final forwardX = tester.getTopLeft(find.byIcon(Icons.forward)).dx;
    expect(replyAllX, greaterThan(replyX));
    expect(forwardX, greaterThan(replyAllX));

    await disposeDetail(tester);
  });

  testWidgets('已发送方向：回复 / 全部回复 / 转发都不出现', (tester) async {
    // 拆成独立用例而不是在同一个用例里 pump 两次：两棵 `AppDatabase` 同时在
    // 场时 drift 会打一句「同一进程建了多个库」的 warn（无害，但会盖住真正
    // 的失败信息）。
    await pumpDetail(tester, mail(type: MailType.send));

    expect(find.byIcon(Icons.reply_all), findsNothing);
    expect(find.byIcon(Icons.reply), findsNothing,
        reason: '自己的已发送件「回复自己」没有意义（Web 端也是这样做的）');
    expect(find.byIcon(Icons.forward), findsNothing);

    await disposeDetail(tester);
  });

  testWidgets('500 宽不炸：次要动作收进 ⋯ 菜单，点「全部回复」开出 replyAll', (tester) async {
    await pumpDetail(tester, mail(), width: 500);

    expect(tester.takeException(), isNull,
        reason: '窄屏顶栏放不下六颗按钮 —— 折叠就是为了这里不溢出');

    // 顶栏只留 回复 / 星标 / ⋯。
    expect(find.byIcon(Icons.reply), findsOneWidget);
    expect(find.byIcon(Icons.reply_all), findsNothing);
    expect(find.byIcon(Icons.forward), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text(l10n.replyAll), findsOneWidget);
    expect(find.text(l10n.forward), findsOneWidget);

    await tester.tap(find.text(l10n.replyAll));
    await tester.pumpAndSettle();

    expect(
      find.text('compose:replyAll'),
      findsOneWidget,
      reason: '菜单里那一项必须真的开出「全部回复」，'
          '开出 reply / forward 都不算 —— 三个入口各写一遍正是这里要防的',
    );

    await disposeDetail(tester);
  });
}

/// `AppLocalizations` 需要一棵有 `Localizations` 的树才拿得到，而这几条断言
/// 要在 pump 之前就拼出中文文案。用 `lookupAppLocalizations('zh')` 直接取一份
/// 就够了 —— 与树里那份是同一组字符串。
AppLocalizations _l10nHolder() => lookupAppLocalizations(const Locale('zh'));
