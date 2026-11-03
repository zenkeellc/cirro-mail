// 「设置 → 关于」页最末尾那个**通用推广位**（设计稿 §7.1）。
//
// 这一块在公开仓里是「构建期注入才出现」的可选内容：核心只留位置与交互，
// 标题 / 正文 / 按钮 / 链接全部来自 `--dart-define-from-file`（见
// `core/config/promo_defaults.dart`）。公开仓没有注入 → 关于页一个像素都不变，
// 所以这里先用 `PromoConfig` 的纯逻辑钉住「什么算没注入 / 什么语言可见」，
// 再用假配置钉住卡片本身的形状与行为：
//
// 1. **没注入**：不渲染，页末还是「开源项目」那张卡；
// 2. **注入后**：标题 + 正文（最多两行）+ 主按钮 + 右上角「×」，排在页末；
// 3. **点按钮**：把**注入的完整 URL**（含 `?src=app-about` 这类来源参数）交给
//    注入的 `UrlOpener`，核心不拼 query；打不开只弹一句 SnackBar；
// 4. **×**：立刻消失并把 URL 记进 `PrefsStore`；同一个 URL 再进页不出现，
//    换了 URL（换活动）重新出现 —— 用 URL 相等判断，不是布尔值；
// 5. **不跨语言兜底**：en 下只认 EN 文案（缺就不显示），zh 同理。
//
// 文案一律用中性测试串，公开仓里不出现任何商业字样。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/config/promo_defaults.dart';
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

/// 中性测试文案（不是任何真实活动的文案）。
const String _titleZh = '看看这个';
const String _titleEn = 'Take a look';
const String _bodyZh = '一句中性的测试文案，用来验证推广位在页面上的样子。';
const String _bodyEn = 'A neutral test blurb used to check how this slot looks.';
const String _ctaZh = '了解详情';
const String _ctaEn = 'Learn more';

/// 全空 = 公开仓（没有构建期注入）的样子。
const PromoConfig _notInjected = PromoConfig(
  url: '',
  titleZh: '',
  titleEn: '',
  bodyZh: '',
  bodyEn: '',
  ctaZh: '',
  ctaEn: '',
);

PromoConfig _injected({
  String url = 'https://example.com/learn-more?src=app-about',
  String titleEn = _titleEn,
  String bodyEn = _bodyEn,
  String ctaEn = _ctaEn,
}) =>
    PromoConfig(
      url: url,
      titleZh: _titleZh,
      titleEn: titleEn,
      bodyZh: _bodyZh,
      bodyEn: bodyEn,
      ctaZh: _ctaZh,
      ctaEn: ctaEn,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockUpdateService service;

  setUp(() {
    service = _MockUpdateService();
    // 关掉更新分组：这一页只留主标识 + 版本信息 + 开源项目 + 推广位。
    when(() => service.isConfigured).thenReturn(false);
  });

  Future<PrefsStore> freshPrefs() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    return PrefsStore(await SharedPreferences.getInstance());
  }

  Future<void> pump(
    WidgetTester tester, {
    required PromoConfig promo,
    Locale locale = const Locale('zh'),
    UrlOpener? openUrl,
    PrefsStore? prefs,
  }) async {
    final store = prefs ?? await freshPrefs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsStoreProvider.overrideWithValue(store),
          updateServiceProvider.overrideWithValue(service),
          appVersionProvider.overrideWith((ref) async => _knownVersion),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Scaffold(
            body: AboutSection(
              promo: promo,
              // 不注入时给一个「开成功」的假实现：推广位不该出现，谁也用不到它。
              openUrl: openUrl ?? (uri) async => true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('PromoConfig：可见条件', () {
    test('全空 = 没注入：enabled / visibleFor 都为 false', () {
      expect(_notInjected.enabled, isFalse);
      expect(_notInjected.visibleFor(const Locale('zh')), isFalse);
      expect(_notInjected.visibleFor(const Locale('en')), isFalse);
    });

    test('只有 http/https 的绝对地址才算注入', () {
      for (final url in <String>[
        'https://example.com/',
        'http://example.com/x?src=app-about',
      ]) {
        expect(_injected(url: url).enabled, isTrue, reason: url);
      }
      for (final url in <String>[
        '',
        'example.com/learn-more', // 缺协议：不是「绝对地址」
        'javascript:alert(1)',
        'file:///tmp/x.html',
        'mailto:someone@example.com',
      ]) {
        expect(_injected(url: url).enabled, isFalse, reason: url);
      }
    });

    test('按当前语言取文案，不跨语言兜底', () {
      final config = _injected();
      expect(config.titleFor(const Locale('zh')), _titleZh);
      expect(config.titleFor(const Locale('en')), _titleEn);
      expect(config.bodyFor(const Locale('zh')), _bodyZh);
      expect(config.bodyFor(const Locale('en')), _bodyEn);
      expect(config.ctaFor(const Locale('zh')), _ctaZh);
      expect(config.ctaFor(const Locale('en')), _ctaEn);

      // 只有 zh 有文案：en 下什么都不给，zh 下照常。
      final zhOnly = _injected(titleEn: '', bodyEn: '', ctaEn: '');
      expect(zhOnly.visibleFor(const Locale('zh')), isTrue);
      expect(zhOnly.visibleFor(const Locale('en')), isFalse);
      expect(zhOnly.titleFor(const Locale('en')), isNull);

      // zh / en 之外的语言一律不可见（App 也只支持这两种）。
      expect(zhOnly.visibleFor(const Locale('fr')), isFalse);
    });
  });

  group('关于页：推广位', () {
    final l10nZh = lookupAppLocalizations(const Locale('zh'));
    final l10nEn = lookupAppLocalizations(const Locale('en'));

    testWidgets('没注入：卡片不渲染，页末仍是「开源项目」', (tester) async {
      await pump(tester, promo: _notInjected);

      expect(find.byKey(const ValueKey<String>('about-promo')), findsNothing);
      expect(find.text(_titleZh), findsNothing);
      expect(find.text(l10nZh.aboutGroupOpenSource), findsOneWidget);
      // 整页仍只套一个 ListView（没有给推广位另起滚动容器）。
      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('注入 zh：标题 / 两行正文 / 按钮都在，且排在开源项目之后',
        (tester) async {
      await pump(tester, promo: _injected());

      expect(find.byKey(const ValueKey<String>('about-promo')), findsOneWidget);
      expect(find.text(_titleZh), findsOneWidget);
      expect(find.text(_bodyZh), findsOneWidget);
      expect(find.text(_ctaZh), findsOneWidget);

      // 正文最多两行：注入方写多了也不许把关于页撑长。
      final body = tester.widget<Text>(
        find.byKey(const ValueKey<String>('about-promo-body')),
      );
      expect(body.maxLines, 2);
      expect(body.overflow, TextOverflow.ellipsis);

      // 位置：页末，开源项目分组之后。
      final openSource = tester.getTopLeft(
        find.text(l10nZh.aboutGroupOpenSource),
      );
      final promoCard = tester.getTopLeft(
        find.byKey(const ValueKey<String>('about-promo')),
      );
      expect(promoCard.dy, greaterThan(openSource.dy));
    });

    testWidgets('点按钮：把注入的完整 URL（含来源参数）交给 UrlOpener',
        (tester) async {
      final opened = <Uri>[];
      const url = 'https://example.com/learn-more?src=app-about';
      await pump(
        tester,
        promo: _injected(url: url),
        openUrl: (uri) async {
          opened.add(uri);
          return true;
        },
      );

      await tester.tap(find.byKey(const ValueKey<String>('about-promo-cta')));
      await tester.pump();

      expect(opened, <Uri>[Uri.parse(url)]);
      // 核心不拼 query：收到的就是注入的那一串，原样。
      expect(opened.single.toString(), url);
      expect(find.text(l10nZh.linkOpenFailed), findsNothing);
    });

    testWidgets('开不成 / 抛异常：只弹一句 SnackBar，不冒泡', (tester) async {
      await pump(
        tester,
        promo: _injected(),
        openUrl: (uri) async => false,
      );
      await tester.tap(find.byKey(const ValueKey<String>('about-promo-cta')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text(l10nZh.linkOpenFailed), findsOneWidget);

      await pump(
        tester,
        promo: _injected(),
        openUrl: (uri) async => throw StateError('no browser'),
      );
      await tester.tap(find.byKey(const ValueKey<String>('about-promo-cta')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text(l10nZh.linkOpenFailed), findsOneWidget);
    });

    testWidgets('×：立刻消失并记住 URL；同 URL 不再出现，换 URL 重新出现',
        (tester) async {
      final prefs = await freshPrefs();
      const urlA = 'https://example.com/learn-more?src=app-about';
      final configA = _injected(url: urlA);

      await pump(tester, promo: configA, prefs: prefs);
      expect(find.byKey(const ValueKey<String>('about-promo')), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('about-promo-dismiss')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('about-promo')), findsNothing);
      // 记的是 URL，不是布尔。
      expect(prefs.promoDismissedUrl, urlA);

      // 同一份 prefs 重建页面：同一个 URL 不再出现。
      await pump(tester, promo: configA, prefs: prefs);
      expect(find.byKey(const ValueKey<String>('about-promo')), findsNothing);

      // 换活动 = 换 URL：重新出现。
      const urlB = 'https://example.com/another?src=app-about';
      await pump(tester, promo: _injected(url: urlB), prefs: prefs);
      expect(find.byKey(const ValueKey<String>('about-promo')), findsOneWidget);
    });

    testWidgets('en locale 用 EN 文案；缺 EN 时 en 下不显示、zh 下显示',
        (tester) async {
      await pump(tester, promo: _injected(), locale: const Locale('en'));
      expect(find.text(_titleEn), findsOneWidget);
      expect(find.text(_bodyEn), findsOneWidget);
      expect(find.text(_ctaEn), findsOneWidget);
      expect(find.text(_titleZh), findsNothing);

      // EN 三条都缺：en 下整张卡不存在，zh 下照常。
      final zhOnly = _injected(titleEn: '', bodyEn: '', ctaEn: '');
      await pump(tester, promo: zhOnly, locale: const Locale('en'));
      expect(find.byKey(const ValueKey<String>('about-promo')), findsNothing);
      expect(find.text(_titleEn), findsNothing);

      await pump(tester, promo: zhOnly, locale: const Locale('zh'));
      expect(find.byKey(const ValueKey<String>('about-promo')), findsOneWidget);
      expect(find.text(_titleZh), findsOneWidget);
      // en 界面上的那句回执在这里不该出现（用的是 zh 的 l10n）。
      expect(find.text(l10nEn.linkOpenFailed), findsNothing);
    });

    testWidgets('非 http/https 的 URL（如 javascript:）→ 不显示', (tester) async {
      await pump(
        tester,
        promo: _injected(url: 'javascript:alert(1)'),
      );
      expect(find.byKey(const ValueKey<String>('about-promo')), findsNothing);
    });
  });
}
