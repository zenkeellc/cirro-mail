// 「设置 → 关于」页的「开源项目」分组（仓库链接 + 去 GitHub 点 Star）。
//
// 这一组要钉住的是「跟右栏空白预览页那个一样的功能」：
//
// 1. **内容**：分组标题、一句请求、GitHub 标志（是图片不是 Material 图标）、
//    仓库地址、点 Star 按钮；
// 2. **地址只有一处**：卡片上显示的地址与按钮打开的目标都来自 `GithubRepo`
//    （与 `NoSelectionPane` 共用），不会改一处忘另一处；
// 3. **点下去真的去开那个地址，开不成只弹 SnackBar**：`flutter_tester` 里
//    没有 `url_launcher` 的平台实现（真调会一直挂着、既不返回也不抛），
//    所以这里注入假的 `UrlOpener` 分别模拟「开成」与「没开成」。
//
// 更新分组用 mock 的服务关掉（`isConfigured == false`）：这一组只关心开源卡片，
// 不该被更新状态行干扰。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations l10n;
  late _MockUpdateService service;

  setUp(() {
    l10n = lookupAppLocalizations(const Locale('zh'));
    service = _MockUpdateService();
    // 关掉更新分组：关于页只留主标识 + 版本信息 + 开源项目。
    when(() => service.isConfigured).thenReturn(false);
  });

  Future<void> pump(WidgetTester tester, {UrlOpener? openUrl}) async {
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
          home: Scaffold(
            body: openUrl == null
                ? const AboutSection()
                : AboutSection(openUrl: openUrl),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('内容：分组标题 + 请求点 Star 的一句 + 地址 + 按钮 + GitHub 标志',
      (tester) async {
    await pump(tester);

    expect(find.text(l10n.aboutGroupOpenSource), findsOneWidget);
    expect(find.text(l10n.aboutOpenSourceHint), findsOneWidget);
    expect(find.text(GithubRepo.displayUrl), findsOneWidget);
    expect(find.text(l10n.starOnGithub), findsOneWidget);
    // GitHub 标志必须是**一张图**：Material 图标里没有 GitHub 的牌。
    expect(find.byType(Image), findsOneWidget);
    // 地址只有一处来源：卡片显示的就是 `GithubRepo` 去掉协议的形式。
    expect(GithubRepo.displayUrl, GithubRepo.url.split('//').last);
  });

  testWidgets('宽了并成一行：地址在左、按钮在右（窄屏另测竖排）', (tester) async {
    await pump(tester);

    final address = tester.getCenter(find.text(GithubRepo.displayUrl)).dy;
    final button = tester.getCenter(find.text(l10n.starOnGithub)).dy;
    expect(
      (address - button).abs(),
      lessThan(6),
      reason: '关于页宽度够（760）时不该还把按钮摞到地址下面',
    );
  });

  testWidgets('点按钮 / 点整张卡片：打开的都是仓库地址，开成不弹回执', (tester) async {
    final opened = <Uri>[];
    await pump(
      tester,
      openUrl: (uri) async {
        opened.add(uri);
        return true;
      },
    );

    await tester.tap(find.text(l10n.starOnGithub));
    await tester.pump();
    expect(opened, <Uri>[Uri.parse(GithubRepo.url)]);
    expect(find.text(l10n.githubOpenFailed), findsNothing);

    // 地址那一行（字小，但整张卡片可点）也是同一个动作。
    await tester.tap(find.text(GithubRepo.displayUrl));
    await tester.pump();
    expect(opened.length, 2);
  });

  testWidgets('没开成（返回 false）：只弹一条 SnackBar，不冒异常', (tester) async {
    await pump(tester, openUrl: (uri) async => false);

    await tester.tap(find.text(l10n.starOnGithub));
    // SnackBar 入场：微任务 → 首帧 → 动画。不用 `pumpAndSettle`，那会一路
    // 等到 SnackBar 自己消失。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text(l10n.githubOpenFailed), findsOneWidget);
  });

  testWidgets('抛异常（平台实现缺失）：同样只弹 SnackBar，不冒泡', (tester) async {
    await pump(tester, openUrl: (uri) async => throw StateError('no browser'));

    await tester.tap(find.text(l10n.starOnGithub));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text(l10n.githubOpenFailed), findsOneWidget);
  });

  testWidgets('开源分组在更新分组之后（更新关掉时仍在页末），整页不套第二层滚动',
      (tester) async {
    await pump(tester);

    // 更新关掉：这一页只有主标识 + 版本信息 + 开源项目。
    expect(find.text(l10n.aboutGroupUpdate), findsNothing);
    expect(find.text(l10n.aboutGroupVersion), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);

    final versionGroup = tester.getTopLeft(
      find.byKey(const ValueKey<String>('about-group-version')),
    );
    final openSource = tester.getTopLeft(find.text(l10n.aboutGroupOpenSource));
    expect(
      openSource.dy,
      greaterThan(versionGroup.dy),
      reason: '开源/Star 是页脚引导，排在信息之后',
    );
  });
}
