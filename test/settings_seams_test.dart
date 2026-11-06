import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/settings/settings_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/features/shell/nav_sidebar.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 两条**新接缝**的钉子：
///
/// 1. [SettingsSection.pinFirst]：置顶扩展要排在**所有内置分类之前**（商业版
///    的「账号」合并完订阅之后就是第一排），默认选中项也跟着它走；「安全」
///    「关于」仍然固定收尾。
/// 2. [AppExtension.aiUsageExtras]：扩展往「设置 → AI」页「用量」分组末尾
///    加的行要真的铺出来；空注册表（公开版）时一个像素都不多。
///
/// 为什么不并进 `settings_layout_test.dart`：那组用例的视口是 900 高，
/// AI 页的「用量」分组在折线下面，要滚才能见到 —— 这里单独用一个很高的
/// 视口，让整页一次建完，断言落在「铺没铺出来」而不是「滚没滚到」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  Future<void> pumpWide(WidgetTester tester) async {
    // 高度给到 2600：AI 页整页（含用量分组）一次建完。
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        aiServiceProvider.overrideWithValue(_FakeAiService()),
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

  Finder railItem(String label) => find.descendant(
        of: find.byType(NavSidebarItem),
        matching: find.text(label),
      );

  List<String> railLabels(WidgetTester tester) => tester
      .widgetList<NavSidebarItem>(find.byType(NavSidebarItem))
      .map((item) => item.label)
      .toList();

  group('SettingsSection.pinFirst', () {
    testWidgets('置顶扩展排在第一个，且默认选中它', (tester) async {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[const _PinnedAccountExt()]);
      await pumpWide(tester);

      // 分类栏第一项是扩展自己给的「账号」，内置的「实例」退到第二。
      expect(railLabels(tester).take(2), <String>['账号', '实例']);
      // 「安全」「关于」仍然固定收尾。
      expect(railLabels(tester).skip(railLabels(tester).length - 2),
          <String>['安全', '关于']);
      // 默认选中就是它：右栏直接是置顶栏的正文，不是实例的空态。
      expect(find.text('账号正文'), findsOneWidget);
      expect(find.text('添加第一个实例'), findsNothing);
    });

    testWidgets('不置位的扩展仍然排在内置之后、「安全」之前', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _PlainDndExt(),
        const _PinnedAccountExt(),
      ]);
      await pumpWide(tester);

      final labels = railLabels(tester);
      expect(labels.indexOf('账号'), 0);
      expect(labels.indexOf('实例'), 1);
      // 免打扰（不置位）在「诊断」与「安全」之间。
      expect(
        labels.sublist(labels.length - 4),
        <String>['诊断', '免打扰', '安全', '关于'],
      );
    });
  });

  group('AppExtension.aiUsageExtras', () {
    testWidgets('扩展的行铺在「设置 → AI」用量分组末尾', (tester) async {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[const _AiUsageExt()]);
      await pumpWide(tester);

      await tester.tap(railItem('AI'));
      await tester.pumpAndSettle();

      expect(find.text('订阅与用量'), findsOneWidget);
    });

    testWidgets('空注册表：AI 页一条都不多', (tester) async {
      await pumpWide(tester);

      await tester.tap(railItem('AI'));
      await tester.pumpAndSettle();

      expect(find.text('订阅与用量'), findsNothing);
    });
  });
}

/// 置顶的「账号」栏：真实商业版在 `SettingsSection.pinFirst: true` 之后
/// 走的就是这一条路。
class _PinnedAccountExt extends AppExtension {
  const _PinnedAccountExt();

  @override
  String get id => 'test.account';

  @override
  List<SettingsSection> settingsSections(BuildContext context) =>
      <SettingsSection>[
        SettingsSection(
          id: 'test.account.section',
          icon: Icons.account_circle_outlined,
          selectedIcon: Icons.account_circle,
          title: '账号',
          pinFirst: true,
          body: (context) => const Center(child: Text('账号正文')),
        ),
      ];
}

/// 不置位的扩展（「免打扰」那一类）：必须仍然排在内置之后。
class _PlainDndExt extends AppExtension {
  const _PlainDndExt();

  @override
  String get id => 'test.dnd';

  @override
  List<SettingsSection> settingsSections(BuildContext context) =>
      <SettingsSection>[
        SettingsSection(
          id: 'test.dnd.rules',
          icon: Icons.do_not_disturb_on_outlined,
          selectedIcon: Icons.do_not_disturb_on,
          title: '免打扰',
          body: (context) => const Center(child: Text('免打扰正文')),
        ),
      ];
}

/// 往 AI 页「用量」分组末尾加一行。
class _AiUsageExt extends AppExtension {
  const _AiUsageExt();

  @override
  String get id => 'test.ai';

  @override
  List<Widget> aiUsageExtras(BuildContext context) => <Widget>[
        ListTile(
          leading: const Icon(Icons.workspace_premium_outlined),
          title: const Text('订阅与用量'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {},
        ),
      ];
}

/// 只回答 `usedToday`，其余一概不实现 —— 这组用例不点 AI 的按钮。
class _FakeAiService implements AiService {
  @override
  int get usedToday => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('这一组测试不用 ${invocation.memberName}');
}
