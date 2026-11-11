import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/settings/settings_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「发送延迟」（`sendDelay`）这一行**在哪一页**。
///
/// 它管的是「点了发送之后还能反悔多久」，属于写信这件事的收尾，却一直躺在
/// 叫「收信」的页面里 —— 想撤销发送的人不会想到去「收信」找。现在它在
/// 「写邮件」页的「发送」组里。
///
/// 这条只有把设置页真的翻过去才看得见：单测 `ComposeSection` 只能证明
/// 「写邮件页里有它」，证明不了「收信页里没有它」。两个方向都要钉 ——
/// 只搬一半（两页都有）时用户会以为有两个不同的设置，而两处其实是同一个
/// provider。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final zh = lookupAppLocalizations(const Locale('zh'));

  /// 窄屏（宽 800 < 1024）的设置页。`profiles` 默认空：这一组只关心「那一行
  /// 在不在」，不关心签名/常用语按邮箱怎么排。
  Future<void> pumpSettings(
    WidgetTester tester, {
    List<Profile> profiles = const <Profile>[],
  }) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        profilesProvider.overrideWith((ref) => Stream.value(profiles)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder categoryRow(String label) => find.descendant(
        of: find.byType(SettingsCategoryTile),
        matching: find.text(label),
      );

  Future<void> open(WidgetTester tester, String label) async {
    await tester.tap(categoryRow(label));
    await tester.pumpAndSettle();
  }

  testWidgets('「写邮件」页有「发送」组与发送延迟，且空态（没有邮箱）照样在',
      (tester) async {
    await pumpSettings(tester);
    await open(tester, zh.compose);

    // 组标题是「发送」（不是「收信」），说明它管的是写信的收尾。
    expect(find.text(zh.send), findsOneWidget);
    expect(find.text(zh.sendDelay), findsOneWidget);
    // 说明文字出现两次：组标题下的说明 + 那一行的副标题（同一个字符串，
    // 同一个 provider —— 这里只钉它确实跟着这一组画出来了）。
    expect(find.text(zh.sendDelayHint), findsNWidgets(2));

    // 空态下也在：这一组按「有没有邮箱」都该画出来（以前它跟着收信页，
    // 空态根本与它无关 —— 断言这一点是防止有人把 sendGroup 挪进非空分支）。
    expect(find.text(zh.composeSignatureEmpty), findsOneWidget,
        reason: '没有实例时写邮件页应当是空态');
    expect(
      find.text(zh.sendDelay),
      findsOneWidget,
      reason: '空态下「发送延迟」也必须在 —— 它不依赖邮箱',
    );
  });

  testWidgets('「收信」页只剩检查间隔与预取正文，**没有**发送延迟',
      (tester) async {
    await pumpSettings(tester);
    await open(tester, zh.polling);

    expect(find.text(zh.pollInterval), findsOneWidget);
    expect(find.text(zh.prefetchTitle), findsOneWidget);
    expect(
      find.text(zh.sendDelay),
      findsNothing,
      reason: '发送延迟已经搬到「写邮件」页；两页都有会像两个不同的设置',
    );
    // 两张提醒开关也搬走了（见 `settings_notifications_test.dart`）。
    expect(find.text(zh.notifyEnabledHint), findsNothing);
  });
}
