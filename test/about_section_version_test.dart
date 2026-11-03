// 「设置 → 关于」页的版本展示与更新检查 UI。
//
// 钉住五件事：
//
// 1. **主标识**：App 名 + 具体版本（`版本 0.1.0+131`），永远是第一项；
// 2. **版本信息分组**：构建号 / 渠道 / 提交 / 构建时间，只画知道的那几项，
//    顺序是「这个构建是谁 → 从哪来 → 什么时候打的」；
// 3. **分组顺序**：主标识 → 版本信息 → 更新 → 开源项目（按信息字段的逻辑排，
//    不是想到哪写到哪）；
// 4. 版本未知、清单地址为空时各自优雅降级（整组隐藏，页面照常打开）；
// 5. 「检查」按钮走状态机：检查中 → 有更新（备注 + 下载 + 稍后）/ 失败（重试）。
//
// 全程不碰网络：更新服务用 mocktail 换掉，版本用 `appVersionProvider`
// override 注入，prefs 是 mock 的 SharedPreferences。开源仓库卡片的打开测试
// 在 `about_section_github_test.dart`（那一组要注入假的 UrlOpener）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/update/update_manifest.dart';
import 'package:mail_app/core/update/update_service.dart';
import 'package:mail_app/core/version/app_version.dart';
import 'package:mail_app/core/version/version_info.dart';
import 'package:mail_app/core/widgets/github_star_card.dart';
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

  testWidgets('版本展示：App 名 + 具体版本号 + 「版本信息」分组里的四个字段', (tester) async {
    await pump(tester);

    expect(find.text(l10n.appTitle), findsOneWidget);
    // 「具体版本」就是 build 号也显示出来，形如 `版本 0.1.0+131`。
    expect(find.text('${l10n.version} 0.1.0+131'), findsOneWidget);
    // 分组小标题：这一组回答「这个构建是什么」。
    expect(find.text(l10n.aboutGroupVersion), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('about-group-version')),
        findsOneWidget);
    expect(find.text(l10n.versionBuild), findsOneWidget);
    expect(find.text('131'), findsOneWidget);
    expect(find.text(l10n.versionCommit), findsOneWidget);
    expect(find.text('abc1234'), findsOneWidget);
    expect(find.text(l10n.versionChannel), findsOneWidget);
    expect(find.text('public'), findsOneWidget);
    // 这一份版本没有构建时间 —— 缺的那项不出现，也不留占位。
    expect(find.text(l10n.versionBuiltAt), findsNothing);
    // 整页仍然只有一个滚动视图。
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('版本未知：显示占位、不画版本信息分组，更新检查仍可用', (tester) async {
    await pump(tester, version: AppVersion.unknown);

    expect(find.text(l10n.versionUnknown), findsOneWidget);
    expect(find.text(l10n.versionBuild), findsNothing);
    expect(find.text(l10n.versionCommit), findsNothing);
    // 整组都不画：没有可展示的字段时，一个空标题比没有更糟。
    expect(find.text(l10n.aboutGroupVersion), findsNothing);
    // 版本未知不影响检查入口（只是不做新旧判断）。
    expect(find.text(l10n.checkForUpdates), findsOneWidget);
  });

  testWidgets('清单地址为空：整块更新 UI 隐藏，版本展示与开源入口不变', (tester) async {
    await pump(tester, configured: false);

    expect(find.text('${l10n.version} 0.1.0+131'), findsOneWidget);
    expect(find.text(l10n.checkForUpdates), findsNothing);
    expect(find.text(l10n.updateAutoCheck), findsNothing);
    expect(find.text(l10n.aboutGroupUpdate), findsNothing);
    // 更新是「渠道能力」，开源项目不是：构建期关掉更新检查不该动它。
    expect(find.text(l10n.aboutGroupOpenSource), findsOneWidget);
    expect(find.text(l10n.starOnGithub), findsOneWidget);
  });

  testWidgets('分组顺序：主标识 → 版本信息 → 更新 → 开源项目', (tester) async {
    await pump(tester);

    double top(Finder finder) => tester.getTopLeft(finder).dy;

    expect(
      top(find.byKey(const ValueKey<String>('about-version'))),
      lessThan(top(find.byKey(const ValueKey<String>('about-group-version')))),
      reason: '主标识永远在最前',
    );
    expect(
      top(find.byKey(const ValueKey<String>('about-group-version'))),
      lessThan(top(find.byKey(const ValueKey<String>('about-group-update')))),
      reason: '先讲「这个构建是什么」，再讲「要不要更新」',
    );
    expect(
      top(find.byKey(const ValueKey<String>('about-group-update'))),
      lessThan(top(find.text(l10n.aboutGroupOpenSource))),
      reason: '开源/Star 是页脚引导，排在信息与动作之后',
    );
    // 仓库卡片在它自己的分组里、且只有一张。
    expect(find.text(GithubRepo.displayUrl), findsOneWidget);
    expect(find.text(l10n.aboutOpenSourceHint), findsOneWidget);
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
