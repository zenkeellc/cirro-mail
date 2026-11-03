import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/settings/sections/security_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置 → 安全 里的「外联资源域名白名单」。
///
/// 这一组钉的是**这一页真的写到了数据层**，而不只是界面上多了一行字：
///
/// - 加：粘贴整条 URL / 大写 / 通配符的写法，落盘的是规范化之后的 pattern；
/// - 不加：非法输入**不落盘**，而且错误要能看见（不是一闪而过的 SnackBar）；
/// - 删：点垃圾篓之后列表与 prefs 同步少掉那条；
/// - 空：列表为空时给一句空态，而不是一片空白。
///
/// pump 方式照抄 `settings_layout_test.dart`：假 prefs + `ProviderScope`
/// 只覆盖 `prefsStoreProvider`（这一页不发请求、不读钥匙串）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final zh = lookupAppLocalizations(const Locale('zh'));

  /// 挂起这一页，返回它正在用的那份 prefs —— 用例直接查**落盘结果**，
  /// 不只看界面。
  Future<PrefsStore> pumpSection(
    WidgetTester tester, {
    Map<String, Object> initial = const <String, Object>{},
  }) async {
    SharedPreferences.setMockInitialValues(initial);
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
          home: const Scaffold(body: SecuritySection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  Future<void> add(WidgetTester tester, String input) async {
    await tester.enterText(
      find.byKey(const ValueKey('security-domain-input')),
      input,
    );
    await tester.tap(find.byKey(const ValueKey('security-domain-add')));
    await tester.pumpAndSettle();
  }

  testWidgets('空名单：给一句空态，不给一行空白', (tester) async {
    await pumpSection(tester);

    expect(find.text(zh.securityExternalResourcesEmpty), findsOneWidget);
    // 白名单条目一条都没有。
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    // 输入框与按钮是该页的主操作，空态下也得在。
    expect(find.byKey(const ValueKey('security-domain-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('security-domain-add')), findsOneWidget);
  });

  testWidgets('粘整条 URL、大写、通配符 → 规范化后落盘，输入框清空', (tester) async {
    final prefs = await pumpSection(tester);

    await add(tester, 'https://*.Example.com/a.png');

    // 输入框清空 —— 加完还留着原文的话，用户会以为没加进去又点一次。
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('security-domain-input')))
          .controller!
          .text,
      isEmpty,
    );
    // 列表里显示的是**规范化之后**的 pattern，不是用户敲的那一整条 URL。
    expect(find.text('*.example.com'), findsOneWidget);
    expect(find.text('https://*.Example.com/a.png'), findsNothing);
    // 真落盘了：不是只改了内存里的 provider。
    expect(prefs.externalAllowedHosts, <String>['*.example.com']);
    // 有回执，顺带说明「落到哪个 pattern」。
    expect(
      find.text(zh.securityExternalResourcesAdded('*.example.com')),
      findsOneWidget,
    );
    // 空态让位。
    expect(find.text(zh.securityExternalResourcesEmpty), findsNothing);
  });

  testWidgets('空输入不触发：不报错、不落盘、不弹条', (tester) async {
    final prefs = await pumpSection(tester);

    await tester.tap(find.byKey(const ValueKey('security-domain-add')));
    await tester.pumpAndSettle();

    expect(find.text(zh.securityExternalResourcesInvalid), findsNothing);
    expect(prefs.externalAllowedHosts, isEmpty);
    expect(find.text(zh.securityExternalResourcesEmpty), findsOneWidget);
  });

  testWidgets('非法输入：错误就地显示，prefs 仍为空', (tester) async {
    final prefs = await pumpSection(tester);

    await add(tester, 'bad host');

    expect(find.text(zh.securityExternalResourcesInvalid), findsOneWidget);
    expect(prefs.externalAllowedHosts, isEmpty);
    // 输入框里的原文留着，用户改一个字符就能重试（不该被清空）。
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('security-domain-input')))
          .controller!
          .text,
      'bad host',
    );
  });

  testWidgets('单独一个 * 不算白名单（等于全部放行），照样报错', (tester) async {
    final prefs = await pumpSection(tester);

    await add(tester, '*');

    expect(find.text(zh.securityExternalResourcesInvalid), findsOneWidget);
    expect(prefs.externalAllowedHosts, isEmpty);
  });

  testWidgets('点删除：条目消失，prefs 同步清空', (tester) async {
    final prefs = await pumpSection(
      tester,
      initial: <String, Object>{
        'cm_external_allowed_hosts': <String>['*.example.com'],
      },
    );

    expect(find.text('*.example.com'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('security-domain-remove-*.example.com')),
    );
    await tester.pumpAndSettle();

    expect(find.text('*.example.com'), findsNothing);
    expect(prefs.externalAllowedHosts, isEmpty);
    // 删完回到空态。
    expect(find.text(zh.securityExternalResourcesEmpty), findsOneWidget);
  });
}
