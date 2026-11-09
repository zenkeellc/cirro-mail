import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/attachment_cache.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/ai/ai_client.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/mail_detail/mail_detail_screen.dart';
import 'package:mail_app/features/mail_list/mail_panes.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/features/suggest/suggest_panel.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// **窗口宽窄切换时，AI 建议面板不许消失**（用户报的 bug）。
///
/// 面板是正文下方停靠的一块，而「正文」的宿主在两种布局里是两棵不同的 widget
/// 树：分栏（>= 1024）是右栏里内嵌的 `MailDetailScreen`，单栏是整页的
/// `MailDetailScreen`。窗口拖过那条线时宿主整棵被拆掉重建 —— 开关如果留在
/// `State` 里，面板就跟着旧 widget 一起没了。
///
/// 这里钉住三件事：
/// 1. 宿主从「内嵌」换成「整页」之后，面板**还在**、内容还是上一次那一段
///    （不是又转一圈）；
/// 2. 只分析了一次 —— 重建不许把模型再问一遍（既慢又白烧 token）；
/// 3. 缩到手机宽度（< 600）面板仍然可见（用户的原话是「一直可见」）。

/// 清附件目录那一步的空实现（与 `mail_detail_suggest_test.dart` 同款）：
/// widget 测试跑在 fake async 下，真磁盘 I/O 的 future 永远不完成。
class _NoopAttachmentCache extends AttachmentCache {
  @override
  Future<void> deleteMail(String profileId, int emailId) async {}
}

/// 打开详情会顺手撤通知，换成空实现（理由同上一个测试文件）。
class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #cancelFor) return Future<void>.value();
    return null;
  }
}

class _UsableAiSettings extends AiSettingsController {
  @override
  Future<AiSettings> build() async => AiSettings(
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
        hasApiKey: true,
        mailSuggestEnabled: true,
      );
}

class _FakeAi extends Mock implements AiService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profileId = 'p1';
  const emailId = 12;
  const summary = '这封建议你现在处理一下';
  final detailIcon = find.byKey(const ValueKey<String>('ai-suggest-detail'));
  final summaryText = find.byKey(const ValueKey<String>('ai-suggest-summary'));

  MailRow mail() => MailRow(
        emailId: emailId,
        profileId: profileId,
        name: '发件人',
        sendEmail: 'from@x.com',
        subject: '一封邮件',
        text: '正文',
        content: '<p>正文</p>',
        hasFullBody: true,
        // 已读：`openMail` 就不会顺手去标已读（那一趟在测试里会等网络）。
        unread: UnreadState.read,
        type: MailType.receive,
        createTime: DateTime(2026, 1, 2, 3, 4),
      );

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// 绝不 `pumpAndSettle` 面板那几帧：转圈是永不结束的动画（见
  /// `suggest_panel_test.dart` 第一段注释）。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  AiStart started(String json) => AiStarted(AiStream(
        text: Stream<String>.value(json),
        done: Future<String>.value(json),
        cancel: () {},
      ));

  testWidgets('内嵌右栏 → 整页详情：面板还在、结果不重跑；缩到手机宽度也还在',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.mailDao.upsertPage(<MailRow>[mail()]);

    final ai = _FakeAi();
    var suggestCalls = 0;
    when(() => ai.suggest(
          input: any(named: 'input'),
          actionIds: any(named: 'actionIds'),
        )).thenAnswer((_) async {
      suggestCalls++;
      return started('{"summary":"$summary",'
          '"actions":[{"action":"delete","reason":"广告"}]}');
    });

    final container = ProviderContainer(overrides: [
      bootstrapProvider.overrideWithValue(BootstrapData(
        db: db,
        tokens: TokenStore(),
        prefs: PrefsStore(await SharedPreferences.getInstance()),
      )),
      notificationServiceProvider.overrideWithValue(_SilentNotifications()),
      attachmentCacheProvider.overrideWithValue(_NoopAttachmentCache()),
      aiServiceProvider.overrideWithValue(ai),
      aiSettingsProvider.overrideWith(_UsableAiSettings.new),
    ]);
    addTearDown(container.dispose);

    Widget host(Widget home) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            home: home,
          ),
        );

    /// 分栏宿主里的右栏（宽屏）。
    Widget embedded() => Scaffold(
          body: MailPanes(
            selected: const MailRef(profileId: profileId, emailId: emailId),
            onClosed: () {},
            list: const SizedBox.shrink(),
          ),
        );

    /// 单栏宿主里的整页详情（窄屏 / 中屏）。
    Widget page() => const MailDetailScreen(
          profileId: profileId,
          emailId: emailId,
        );

    // ---- 1. 宽屏：在右栏里把面板开起来 -------------------------------
    await tester.pumpWidget(host(embedded()));
    await settle(tester);
    expect(detailIcon, findsOneWidget, reason: '前提：右栏开着、AI 那颗在');

    await tester.tap(detailIcon);
    await settle(tester);
    expect(find.byType(SuggestView), findsOneWidget, reason: '面板应当停靠在正文下方');
    expect(summaryText, findsOneWidget, reason: '分析结果画出来了');
    expect(suggestCalls, 1, reason: '前提：分析只发了一次请求');

    // ---- 2. 宿主换成整页详情（等价于窗口拖窄、路由把 `?sel=` 展开成整页）
    await tester.pumpWidget(host(page()));
    await settle(tester);
    expect(
      find.byType(MailDetailScreen),
      findsOneWidget,
      reason: '前提：换成了整页那一个宿主',
    );
    expect(
      find.byType(SuggestView),
      findsOneWidget,
      reason: '宿主被整棵拆掉重建之后，面板必须还在 —— 用户报的正是这里消失',
    );
    expect(
      summaryText,
      findsOneWidget,
      reason: '重建要用上一次的成品，不是重新转圈',
    );
    expect(
      suggestCalls,
      1,
      reason: '重建不许把模型再问一遍（慢，而且白烧一次 token）',
    );

    // ---- 3. 继续缩到手机宽度：面板仍然可见 ----------------------------
    tester.view.physicalSize = const Size(500, 800);
    await settle(tester);
    expect(
      find.byType(SuggestView),
      findsOneWidget,
      reason: '手机宽度原来的设计是走整页路由，但已经开着的面板必须「一直可见」',
    );
    expect(summaryText, findsOneWidget);

    // ---- 4. 收起：× 仍然是同一个开关（两种宿主都认它）------------------
    await tester.tap(find.byKey(const ValueKey<String>('ai-suggest-close')));
    await tester.pump();
    expect(find.byType(SuggestView), findsNothing);

    // 收树再推一帧：drift 的流关闭排的是零延时定时器。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  });
}
