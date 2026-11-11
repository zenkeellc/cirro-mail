import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/features/notifications/push_service.dart';
import 'package:mail_app/features/settings/sections/push_section.dart';
import 'package:mail_app/features/settings/settings_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「设置 → 通知 → 后台推送」这个**子页**的两条出口：
///
/// - 扩展（`AppExtension.pushSettings`）返回非 null → **整块替换**；
/// - 全部返回 null（公开版的空注册表就是这一种）→ **原样回退**核心自带的
///   七页向导。
///
/// 这条接缝最容易被写坏的地方是「回退时把向导建了两遍」或者「替换时仍然
/// 先把向导建出来」（`PushSection` 一构造就会读钥匙串、打中转端）—— 所以
/// 下面不只断言「看到了哪个」，也断言「另一个没被构造」。
///
/// 推送向导以前独占分类栏里的一栏（「推送」），现在降级成「通知」页里的一个
/// 子页 —— 所以进它的路径变成「点『通知』→ 点『系统推送』那一行」两步。
/// 这里的入口开关不变，只换入口的走法。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  /// 窄屏（宽 800 < 1024）的设置页 —— 一进来是分类列表，点「通知」才进正文。
  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final tokens = TokenStore();
    final push = PushService(
      prefs: prefs,
      tokens: tokens,
      readProfiles: () async => const [],
      readMailboxes: (_) async => const [],
      forceAvailable: true,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        tokenStoreProvider.overrideWithValue(tokens),
        pushServiceProvider.overrideWithValue(push),
        // 「通知」页会读 `notificationService.isSupported` —— 换成空实现，
        // 免得为了一条导航断言去构造真的平台插件。
        notificationServiceProvider.overrideWithValue(_SilentNotifications()),
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

  /// 进「通知 → 后台推送」这个子页。
  ///
  /// 两步：分类列表里点「通知」，再点那一页里「后台推送」组的「系统推送」
  /// 那一行。推送**不再**是分类栏里的一栏 —— 少了这一栏，用户不用再在两栏
  /// 「推送 / 通知」之间猜哪个才是自己要的。
  Future<void> openPush(WidgetTester tester) async {
    await tester.tap(find.descendant(
      of: find.byType(SettingsCategoryTile),
      matching: find.text('通知'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统推送'));
    await tester.pumpAndSettle();
  }

  testWidgets('空注册表：点进「推送」还是核心的七页向导', (tester) async {
    await pumpSettings(tester);
    await openPush(tester);

    expect(find.byType(PushSection), findsOneWidget);
    expect(find.text('托管推送面板'), findsNothing);
  });

  testWidgets('扩展返回 null：仍然回退七页向导（不接管就不拦路）',
      (tester) async {
    AppExtensionRegistry.instance
        .registerAll(<AppExtension>[const _NoPushExt()]);
    await pumpSettings(tester);
    await openPush(tester);

    expect(find.byType(PushSection), findsOneWidget);
  });

  testWidgets('扩展接管：整块替换，且**不**构造七页向导', (tester) async {
    AppExtensionRegistry.instance
        .registerAll(<AppExtension>[const _PushPanelExt('托管推送面板')]);
    await pumpSettings(tester);
    await openPush(tester);

    expect(find.text('托管推送面板'), findsOneWidget);
    expect(find.byType(PushSection), findsNothing,
        reason: '被替换时向导不该被构造：它一建出来就会读钥匙串、打 /devices');
  });

  testWidgets('第一个返回非 null 的扩展赢', (tester) async {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      const _NoPushExt(),
      const _PushPanelExt('第一个面板'),
      const _PushPanelExt('第二个面板', id: 'ext.push.second'),
    ]);
    await pumpSettings(tester);
    await openPush(tester);

    expect(find.text('第一个面板'), findsOneWidget);
    expect(find.text('第二个面板'), findsNothing);
    expect(find.byType(PushSection), findsNothing);
  });

  testWidgets('扩展可以自己把七页向导要回去（订阅失效时走这条）',
      (tester) async {
    AppExtensionRegistry.instance
        .registerAll(<AppExtension>[const _AskFallbackExt()]);
    await pumpSettings(tester);
    await openPush(tester);

    expect(find.byType(PushSection), findsOneWidget);
  });
}

/// 只加一栏设置、不碰推送的扩展 —— 「返回 null 就等于不参与」。
class _NoPushExt extends AppExtension {
  const _NoPushExt();

  @override
  String get id => 'ext.push.none';
}

/// 接管推送设置页的假扩展。
class _PushPanelExt extends AppExtension {
  const _PushPanelExt(this.label, {this.id = 'ext.push.panel'});

  @override
  final String id;
  final String label;

  @override
  Widget? pushSettings(
    BuildContext context,
    PushFacade facade,
    Widget Function() fallback,
  ) =>
      Center(child: Text(label));
}

/// 「这一块现在轮不到我画」—— 把核心给的回退构造器原样调回去。
class _AskFallbackExt extends AppExtension {
  const _AskFallbackExt();

  @override
  String get id => 'ext.push.fallback';

  @override
  Widget? pushSettings(
    BuildContext context,
    PushFacade facade,
    Widget Function() fallback,
  ) =>
      fallback();
}

/// 「通知」页只读 `NotificationService.isSupported`；这一组测的是推送面板的
/// 接管与回退，与平台通知无关 —— 空实现，别去构造真的插件。
///
/// `isSupported` 必须回 `true`：默认的 `null` 落到 `bool` 位置会当场抛，
/// 而「通知」页靠它决定横幅开关画不画。
class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #isSupported) return true;
    return null;
  }
}
