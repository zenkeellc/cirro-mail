// 「设置 → 关于」页的扩展接缝（`AppExtension.aboutExtras`）。
//
// 这一条是**商业版功能的公开面护栏**：商业代码不能改核心，只能往注册表里
// 放扩展；核心在关于页把它铺出来。所以这里要钉住两件事：
//
// 1. **空注册表时这一页与从前完全一样** —— 公开版不能因为多了接缝而多出任何
//    东西（商业版是同一份核心代码，接缝必须对公开版是零影响）；
// 2. 注册一个扩展后，它的块**真的**出现在 App 名那一行**之后**，而且**没有
//    多套一层滚动容器**（套了就是两层滚动 —— 页面滚不动或者滚两次）。
//
// 容器搭建照 `settings_compose_section_test.dart`（prefs 与 secure storage
// 都塞 mock 初值）。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/settings/sections/about_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';

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

  /// 刻意**不写 `const`**：`AboutSection` 是 const 构造的，写成
  /// `const Scaffold(body: AboutSection())` 每次 `pumpWidget` 传进去的是
  /// **同一个化实例**，Flutter 的 `updateChild` 发现 `identical(old, new)`
  /// 就直接跳过重建 —— 于是「清空注册表后再挂一次」看起来什么都没变。
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(body: AboutSection(key: UniqueKey())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空注册表：只有「App 名 + 版本号」那一行', (tester) async {
    await pump(tester);

    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('商业版'), findsNothing);
    // 整页只有一个滚动视图 —— 扩展开启后也必须是这样。
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('注册后：扩展的块追加在 App 名之后，没有第二层滚动', (tester) async {
    AppExtensionRegistry.instance.registerAll(const <AppExtension>[_AboutExt()]);
    await pump(tester);

    expect(find.byKey(const ValueKey('pro-card')), findsOneWidget);
    // 仍然是**一个** ListView：扩展的块铺在它的 children 里，不是自己再套一个。
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(2));

    // 顺序：App 名那一行在前，商业版卡片在后。
    final appTile = tester.getTopLeft(find.byType(ListTile).first);
    final proCard = tester.getTopLeft(find.byKey(const ValueKey('pro-card')));
    expect(
      proCard.dy,
      greaterThan(appTile.dy),
      reason: '扩展块必须排在「App 名 + 版本号」之后，插到前面会顶掉主标识',
    );
  });

  testWidgets('注册表清空后回到原样（商业版关掉 = 公开版）', (tester) async {
    AppExtensionRegistry.instance.registerAll(const <AppExtension>[_AboutExt()]);
    await pump(tester);
    expect(find.byKey(const ValueKey('pro-card')), findsOneWidget);

    AppExtensionRegistry.instance.reset();
    await pump(tester);
    expect(find.byKey(const ValueKey('pro-card')), findsNothing);
    expect(find.byType(ListTile), findsOneWidget);
  });
}
