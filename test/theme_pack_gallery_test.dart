// 「设置 → 外观」的主题画廊接缝（`AppExtension.themes`）。
//
// 这条是**商业版主题功能的公开面护栏**：
//
// 1. 空注册表（公开版）时，外观页与接缝出现之前**逐字一致** —— 没有画廊、
//    没有多出来的滚动容器、主题仍然是内置默认那套；
// 2. 注册了主题包之后，画廊真的出现、每套一张卡、卡里有亮暗两个缩影；
// 3. 点一张卡**即时生效**并落盘（`PrefsStore.themePackId`），再进 App 还是
//    这一套；
// 4. 选中的 id 在注册表里查不到（换了构建 / 卸载了扩展）时安静回退到内置
//    默认主题，不抛也不白屏。
//
// 容器搭建照 `about_section_extension_test.dart`（prefs 塞 mock 初值）。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/theme/app_theme.dart';
import 'package:mail_app/features/settings/sections/appearance_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一套纯色假主题：亮 / 暗各一个可辨认的种子色，背板是一块实色。
class _FakePack extends ThemePack {
  const _FakePack(this.id, this.label, this.seed);

  @override
  final String id;
  final String label;
  final Color seed;

  @override
  String name(Locale locale) => label;

  @override
  String family(Locale locale) => '测试族';

  @override
  ThemeData build(Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: brightness,
        ),
      );

  @override
  Widget? buildBackdrop(BuildContext context) => const ColoredBox(
        color: Color(0xFF112233),
        key: ValueKey('fake-backdrop'),
      );
}

class _ThemesExt extends AppExtension {
  const _ThemesExt();

  @override
  String get id => 'test.themes';

  @override
  List<ThemePack> themes() => const <ThemePack>[
        _FakePack('qinghua', '青花瓷', Color(0xFF1F4E9C)),
        _FakePack('jiguang', '极光', Color(0xFF4FE3C1)),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  Future<PrefsStore> pumpAppearance(
    WidgetTester tester, {
    Iterable<AppExtension> extensions = const <AppExtension>[],
  }) async {
    AppExtensionRegistry.instance.registerAll(extensions);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsStoreProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const Scaffold(body: AppearanceSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  testWidgets('空注册表：外观页只有内置两行，没有主题画廊', (tester) async {
    await pumpAppearance(tester);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(AppearanceSection)),
    );
    expect(find.text(l10n.appearance), findsOneWidget);
    expect(find.text(l10n.themeGalleryTitle), findsNothing);
    // 内置那两行还在（明暗下拉 + 语言）。
    expect(find.text(l10n.language), findsOneWidget);
    expect(find.byType(DropdownButton<ThemeMode>), findsOneWidget);
  });

  testWidgets('注册主题包后：每套一张卡，卡里亮暗两个缩影', (tester) async {
    await pumpAppearance(tester, extensions: const <_ThemesExt>[_ThemesExt()]);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(AppearanceSection)),
    );
    expect(find.text(l10n.themeGalleryTitle), findsOneWidget);
    // 内置默认 + 两套扩展主题。
    expect(find.text(l10n.themeDefault), findsOneWidget);
    expect(find.text('青花瓷'), findsOneWidget);
    expect(find.text('极光'), findsOneWidget);
    // 三张卡都带着族名（内置默认那套没有族名，所以只有两条）。
    expect(find.text('测试族'), findsNWidgets(2));
  });

  testWidgets('点一张卡：即时生效并落盘', (tester) async {
    final prefs = await pumpAppearance(
      tester,
      extensions: const <_ThemesExt>[_ThemesExt()],
    );

    await tester.tap(find.text('青花瓷'));
    await tester.pumpAndSettle();

    expect(prefs.themePackId, 'qinghua');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AppearanceSection)),
    );
    expect(container.read(themePackProvider), 'qinghua');
    expect(container.read(activeThemePackProvider)?.id, 'qinghua');
    // 再点「默认」能退回去。
    final l10n = AppLocalizations.of(
      tester.element(find.byType(AppearanceSection)),
    );
    await tester.tap(find.text(l10n.themeDefault));
    await tester.pumpAndSettle();
    expect(prefs.themePackId, isNull);
    expect(container.read(activeThemePackProvider), isNull);
  });

  test('选中的 id 查不到时回退到内置默认主题', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cm_theme_pack': 'not-installed',
    });
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer(
      overrides: [prefsStoreProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    expect(container.read(themePackProvider), 'not-installed');
    expect(container.read(activeThemePackProvider), isNull);
    final data = container.read(activeThemeDataProvider);
    expect(data.light.colorScheme.primary, AppTheme.light().colorScheme.primary);
  });

  test('选中的包同时决定 theme 与 darkTheme 两版', () async {
    AppExtensionRegistry.instance.registerAll(
      const <AppExtension>[_ThemesExt()],
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cm_theme_pack': 'jiguang',
    });
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer(
      overrides: [prefsStoreProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final pack = container.read(activeThemePackProvider);
    expect(pack?.id, 'jiguang');
    final data = container.read(activeThemeDataProvider);
    expect(data.light.brightness, Brightness.light);
    expect(data.dark.brightness, Brightness.dark);
    // 两版都来自这套主题（不是默认蓝）。
    expect(
      data.light.colorScheme.primary,
      pack!.build(Brightness.light).colorScheme.primary,
    );
    expect(
      data.dark.colorScheme.primary,
      pack.build(Brightness.dark).colorScheme.primary,
    );
  });
}
