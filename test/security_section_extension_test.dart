// 「设置 → 安全」页的扩展接缝（`AppExtension.securityExtras`）。
//
// 这一条是「外部资源代理并进安全页」的公开面护栏：商业代码不能改核心，只能
// 往注册表里放扩展；核心在安全页正文末尾把它铺出来。要钉住四件事：
//
// 1. **空注册表时没有扩展内容** —— 公开版不能因为多了接缝就多出块（商业版
//    与公开版是同一份核心代码，接缝对公开版必须是零影响）；
// 2. 注册一个扩展后，它的块**真的**出现在这一页，且在**白名单之后**（合并
//    进来的开关属于「正文里能发生什么」的另一半：拦不拦 / 怎么连）；
// 3. **没有多套一层滚动容器** —— 扩展块铺在同一个 `ListView` 的 children 里；
// 4. 注册表清空后回到原样（商业版关掉 = 公开版）。
//
// 容器搭建照 `about_section_extension_test.dart`（prefs 塞 mock 初值）。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/settings/sections/security_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个只往安全页末尾挂一块的假扩展（模拟商业版的「外部资源代理」）。
class _SecurityExt extends AppExtension {
  const _SecurityExt();

  @override
  String get id => 'test.security';

  @override
  List<Widget> securityExtras(BuildContext context) => const <Widget>[
        Card(
          child: ListTile(
            key: ValueKey('pro-security-block'),
            leading: Icon(Icons.travel_explore_outlined),
            title: Text('代理开关'),
          ),
        ),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  /// 刻意**不写 `const`**：`SecuritySection` 是 const 构造的，写成
  /// `const Scaffold(body: SecuritySection())` 每次 `pumpWidget` 传进去的是
  /// **同一个实例**，Flutter 的 `updateChild` 发现 `identical(old, new)`
  /// 就直接跳过重建 —— 「清空注册表后再挂一次」看起来什么都没变。
  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(body: SecuritySection(key: UniqueKey())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空注册表：白名单页没有扩展块，也不多滚动容器', (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('security-domain-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('pro-security-block')), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('注册后：扩展块铺在白名单之后，且是同一个 ListView', (tester) async {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      const _SecurityExt(),
    ]);
    await pump(tester);

    expect(find.byKey(const ValueKey('pro-security-block')), findsOneWidget);
    expect(find.text('代理开关'), findsOneWidget);

    // 仍然是**一个** ListView：扩展块铺在它的 children 里，不是自己再套一个。
    expect(find.byType(ListView), findsOneWidget);

    // 顺序：白名单的输入框 → 扩展块。合并进来的开关排在后面，不顶掉既有内容。
    final input = tester.getTopLeft(
      find.byKey(const ValueKey('security-domain-input')),
    );
    final block = tester.getTopLeft(
      find.byKey(const ValueKey('pro-security-block')),
    );
    expect(
      block.dy,
      greaterThan(input.dy),
      reason: '扩展块必须铺在白名单之后 —— 插到前面会顶掉这一页的主操作',
    );
  });

  testWidgets('注册表清空后回到原样（商业版关掉 = 公开版）', (tester) async {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      const _SecurityExt(),
    ]);
    await pump(tester);
    expect(find.byKey(const ValueKey('pro-security-block')), findsOneWidget);

    AppExtensionRegistry.instance.reset();
    await pump(tester);
    expect(find.byKey(const ValueKey('pro-security-block')), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
  });
}
