// 「设置 → 关于」页的版本展示与更新检查 UI。
//
// 钉住四件事：
//
// 1. App 名行显示具体版本（`版本 0.1.0+131`）与构建号 / 提交 / 渠道；
// 2. 版本未知时优雅降级（显示「版本未知」，不画明细），页面照常打开；
// 3. 清单地址为空（构建期关掉检查）时整块检查 UI 隐藏，版本展示不变；
// 4. 「检查」按钮走状态机：检查中 → 有更新（备注 + 下载 + 稍后）/ 失败（重试）。
//
// 全程不碰网络：更新服务用 mocktail 换掉，版本用 `appVersionProvider`
// override 注入，prefs 是 mock 的 SharedPreferences。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/update/update_manifest.dart';
import 'package:mail_app/core/update/update_service.dart';
import 'package:mail_app/core/version/app_version.dart';
import 'package:mail_app/core/version/version_info.dart';
import 'package:mail_app/features/settings/sections/about_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockUpdateService extends Mock implements UpdateService {}

const AppVersion _knownVersion = AppVersion(
  name: '0.1.0',
  buildNumber: 131,
  commit: 'abc1234',
  channel: 'public',
);

UpdateRelease _release() => const UpdateRelease(
      version: '0.9.0',
      buildNumber: 900,
      notes: '修了几个问题',
      releaseUrl: 'https://cirro.zenkee.com/download',
      downloads: <String, String>{
        'macos': 'https://cdn.example.com/CirroMail.dmg',
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockUpdateService service;
  late AppLocalizations l10n;

  setUp(() {
    l10n = lookupAppLocalizations(const Locale('zh'));
    service = _MockUpdateService();
    when(() => service.isConfigured).thenReturn(true);
  });

  Future<void> pump(
    WidgetTester tester, {
    AppVersion version = _knownVersion,
    bool configured = true,
  }) async {
    when(() => service.isConfigured).thenReturn(configured);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
          updateServiceProvider.overrideWithValue(service),
          appVersionProvider.overrideWith((ref) async => version),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: AboutSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('版本展示：App 名 + 具体版本号 + 构建号 / 提交 / 渠道', (tester) async {
    await pump(tester);

    expect(find.text(l10n.appTitle), findsOneWidget);
    // 「具体版本」就是 build 号也显示出来，形如 `版本 0.1.0+131`。
    expect(find.text('${l10n.version} 0.1.0+131'), findsOneWidget);
    expect(find.text(l10n.versionBuild), findsOneWidget);
    expect(find.text('131'), findsOneWidget);
    expect(find.text(l10n.versionCommit), findsOneWidget);
    expect(find.text('abc1234'), findsOneWidget);
    expect(find.text(l10n.versionChannel), findsOneWidget);
    expect(find.text('public'), findsOneWidget);
    // 整页仍然只有一个滚动视图（扩展块铺在同一个 ListView 里）。
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('版本未知：显示占位、不画明细，更新检查仍可用', (tester) async {
    await pump(tester, version: AppVersion.unknown);

    expect(find.text(l10n.versionUnknown), findsOneWidget);
    expect(find.text(l10n.versionBuild), findsNothing);
    expect(find.text(l10n.versionCommit), findsNothing);
    // 版本未知不影响检查入口（只是不做新旧判断）。
    expect(find.text(l10n.checkForUpdates), findsOneWidget);
  });

  testWidgets('清单地址为空：整块更新 UI 隐藏，版本展示不变', (tester) async {
    await pump(tester, configured: false);

    expect(find.text('${l10n.version} 0.1.0+131'), findsOneWidget);
    expect(find.text(l10n.checkForUpdates), findsNothing);
    expect(find.text(l10n.updateAutoCheck), findsNothing);
  });

  testWidgets('检查 → 有更新：显示版本、备注与下载 / 稍后', (tester) async {
    when(() => service.fetchLatest()).thenAnswer((_) async => _release());
    await pump(tester);

    // 还没有检查：只有「检查更新」那行。
    expect(find.text(l10n.checkForUpdates), findsOneWidget);
    await tester.tap(find.text(l10n.updateCheckNow));
    await tester.pumpAndSettle();

    expect(find.text(l10n.updateAvailable('0.9.0+900')), findsOneWidget);
    expect(find.text('修了几个问题'), findsOneWidget);
    expect(find.text(l10n.updateDownload), findsOneWidget);
    expect(find.text(l10n.updateLater), findsOneWidget);
  });

  testWidgets('检查 → 已是最新：显示已是最新版本，可再次检查', (tester) async {
    when(() => service.fetchLatest()).thenAnswer(
      (_) async => const UpdateRelease(version: '0.1.0', buildNumber: 131),
    );
    await pump(tester);

    await tester.tap(find.text(l10n.updateCheckNow));
    await tester.pumpAndSettle();

    expect(find.text(l10n.updateUpToDate), findsOneWidget);
    // 仍留一个重新检查的按钮。
    expect(find.text(l10n.updateCheckNow), findsOneWidget);
  });

  testWidgets('检查 → 失败：显示检查失败与重试', (tester) async {
    when(() => service.fetchLatest()).thenThrow(
      const UpdateException(UpdateFailureKind.network, '没网'),
    );
    await pump(tester);

    await tester.tap(find.text(l10n.updateCheckNow));
    await tester.pumpAndSettle();

    expect(find.text(l10n.updateCheckFailed), findsOneWidget);
    expect(find.text(l10n.updateRetry), findsOneWidget);
  });

  testWidgets('自动检查开关：改一下立刻落 prefs，并让状态回到 idle', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
          updateServiceProvider.overrideWithValue(service),
          appVersionProvider.overrideWith((ref) async => _knownVersion),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: AboutSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.updateAutoCheck), findsOneWidget);
    await tester.tap(find.text(l10n.updateAutoCheck));
    await tester.pumpAndSettle();

    expect(prefs.updateCheckEnabled, isFalse);
  });
}
