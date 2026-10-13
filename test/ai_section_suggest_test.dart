import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/settings/sections/ai_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/ai_providers.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个「已经配好了」的设置控制器：开关区只在 `isUsable` 时才有意义。
class _Usable extends AiSettingsController {
  @override
  Future<AiSettings> build() async => const AiSettings(
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
        hasApiKey: true,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('开关区第五个是 AI 建议，默认开', (tester) async {
    // 开关区排在页面的后半段（地址 / 格式 / Key / 模型那几段之后），默认
    // 800×600 的测试视口里它整个落在折线以下 —— `ListView` 懒构建，那一组
    // `SwitchListTile` 根本还没被创建，直接 expect 会 `findsNothing`（不是
    // 第五个开关丢了，是它还没 build 出来）。与 `ai_settings_section_test.dart`
    // 里那些开关用例同一个坑，同样把视口调高让整页铺得下。
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(overrides: <Override>[
      prefsStoreProvider.overrideWithValue(prefs),
      aiSettingsProvider.overrideWith(_Usable.new),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: Scaffold(body: AiSettingsSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.byKey(const ValueKey<String>('ai-suggest'));
    expect(tile, findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(tile).value,
      isTrue,
      reason: '默认开',
    );
    // 顺序：排在 ai-polish 之后
    final polishY = tester.getTopLeft(find.byKey(const ValueKey<String>('ai-polish'))).dy;
    expect(tester.getTopLeft(tile).dy, greaterThan(polishY));
  });
}
