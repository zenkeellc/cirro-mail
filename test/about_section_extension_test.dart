// 「设置 → 关于」页的扩展接缝（`AppExtension.aboutExtras`）。
//
// 这一条是**商业版功能的公开面护栏**：商业代码不能改核心，只能往注册表里
// 放扩展；核心在关于页把它铺出来。所以这里要钉住两件事：
//
// 1. **空注册表时这一页没有扩展内容** —— 公开版不能因为多了接缝而多出
//    扩展块（商业版是同一份核心代码，接缝必须对公开版是零影响）；
// 2. 注册一个扩展后，它的块**真的**出现在这一页内置内容**之后**，而且
//    **没有多套一层滚动容器**（套了就是两层滚动 —— 页面滚不动或者滚两次）。
//
// ## 基线为什么变了（2026-11）
//
// 以前这一页只有「App 名 + 版本号」一行，所以空注册表的断言是
// 「只有一个 ListTile」。加了版本自动升级之后，关于页多了内置的版本明细与
// 检查更新块（状态行 + 自动检查开关），空注册表**不再只有一个 ListTile**。
// 于是基线改为：App 名那一行仍然在最前、检查更新块在它之后、扩展块在最后、
// 整页仍然只有一个 ListView。**本意一点没变**，只是内置内容变多了。
//
// 容器搭建照 `settings_compose_section_test.dart`（prefs 塞 mock 初值）。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/version/app_version.dart';
import 'package:mail_app/core/version/version_info.dart';
import 'package:mail_app/features/settings/sections/about_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个只在关于页挂一张卡片的假扩展。
class _AboutExt extends AppExtension {
  const _AboutExt();

  @override
  String get id => 'test.about';

  @override
  List<Widget> aboutExtras(BuildContext context) => const <Widget>[
        Card(child: ListTile(key: ValueKey('pro-card'), title: Text('商业版'))),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  /// 内置内容（不带任何扩展）在关于页画出来的 ListTile 数：
  /// App 名行 + 检查更新状态行 + 自动检查开关（`SwitchListTile` 内部
  /// 也是一个 `ListTile`）。版本未知时没有明细行。
  const int builtInTiles = 3;

  /// 刻意**不写 `const`**：`AboutSection` 是 const 构造的，写成
  /// `const Scaffold(body: AboutSection())` 每次 `pumpWidget` 传进去的是
  /// **同一个实例**，Flutter 的 `updateChild` 发现 `identical(old, new)`
  /// 就直接跳过重建 —— 于是「清空注册表后再挂一次」看起来什么都没变。
  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
          // 固定成「版本未知」：这一组只关心扩展接缝，不该被真实 PackageInfo
          // （`flutter_tester` 里没有平台通道）或版本明细行数干扰。
          appVersionProvider.overrideWith((ref) async => AppVersion.unknown),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(body: AboutSection(key: UniqueKey())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空注册表：只有内置内容，没有扩展块', (tester) async {
    await pump(tester);

    expect(find.byType(ListTile), findsNWidgets(builtInTiles));
    expect(find.text('商业版'), findsNothing);
    // 整页只有一个滚动视图 —— 扩展开启后也必须是这样。
    expect(find.byType(ListView), findsOneWidget);
    // App 名那一行永远是第一项。
    expect(find.byKey(const ValueKey<String>('about-version')), findsOneWidget);
  });

  testWidgets('注册后：扩展的块追加在内置内容之后，没有第二层滚动', (tester) async {
    AppExtensionRegistry.instance.registerAll(const <AppExtension>[_AboutExt()]);
    await pump(tester);

    expect(find.byKey(const ValueKey('pro-card')), findsOneWidget);
    // 仍然是**一个** ListView：扩展的块铺在它的 children 里，不是自己再套一个。
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(builtInTiles + 1));

    // 顺序：内置内容全部在前，商业版卡片在最后。
    final appTile =
        tester.getTopLeft(find.byKey(const ValueKey<String>('about-version')));
    final statusTile = tester.getTopLeft(
      find.byKey(const ValueKey<String>('about-update-status')),
    );
    final proCard = tester.getTopLeft(find.byKey(const ValueKey('pro-card')));
    expect(
      statusTile.dy,
      greaterThan(appTile.dy),
      reason: '检查更新块排在「App 名 + 版本号」之后',
    );
    expect(
      proCard.dy,
      greaterThan(statusTile.dy),
      reason: '扩展块必须排在内置内容之后，插到前面会顶掉主标识',
    );
  });

  testWidgets('注册表清空后回到原样（商业版关掉 = 公开版）', (tester) async {
    AppExtensionRegistry.instance.registerAll(const <AppExtension>[_AboutExt()]);
    await pump(tester);
    expect(find.byKey(const ValueKey('pro-card')), findsOneWidget);

    AppExtensionRegistry.instance.reset();
    await pump(tester);
    expect(find.byKey(const ValueKey('pro-card')), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(builtInTiles));
  });
}
