// `UpdateHost`：启动自动检查 + 「发现新版本」SnackBar。
//
// 这一层是启动提示的唯一入口，钉住四条：
//
// 1. 启动时真的检查一次，发现新版本弹 SnackBar（动作「下载」）；
// 2. 同一个版本提示过一次就不再弹（判据是 prefs 里的版本串）；
// 3. 用户关掉「自动检查更新」→ 启动时不打网络、也不弹；
// 4. 24 小时内检查过 → 不重复打网络。
//
// 全程不碰网络：服务用 mocktail 换掉、版本用 provider override 注入。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/update/update_manifest.dart';
import 'package:mail_app/core/update/update_service.dart';
import 'package:mail_app/core/version/app_version.dart';
import 'package:mail_app/core/version/version_info.dart';
import 'package:mail_app/features/update/update_host.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockUpdateService extends Mock implements UpdateService {}

const AppVersion _current = AppVersion(name: '0.1.0', buildNumber: 131);

UpdateRelease _release() => const UpdateRelease(
      version: '0.9.0',
      buildNumber: 900,
      notes: '修了几个问题',
      releaseUrl: 'https://cirro.zenkee.com/download',
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

  /// 挂起 `UpdateHost`。
  ///
  /// **不用 `pumpAndSettle`**：SnackBar 有 12 秒计时器，settle 会一路把它
  /// 等到消失，那时再断言就什么都找不到了。这里按「微任务 → 首帧 →
  /// post-frame → 入场动画」手动推进。
  Future<PrefsStore> pumpHost(
    WidgetTester tester, {
    Map<String, Object> prefValues = const <String, Object>{},
    required Future<UpdateRelease> Function() fetch,
  }) async {
    when(() => service.fetchLatest()).thenAnswer((_) => fetch());
    SharedPreferences.setMockInitialValues(prefValues);
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsStoreProvider.overrideWithValue(prefs),
          updateServiceProvider.overrideWithValue(service),
          appVersionProvider.overrideWith((ref) async => _current),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: UpdateHost(child: const Text('主界面')),
          ),
        ),
      ),
    );
    // initState 里的检查是异步的：先让微任务跑完，再推进入场动画。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    return prefs;
  }

  testWidgets('启动检查发现新版本：弹 SnackBar 并记为已提示', (tester) async {
    final prefs = await pumpHost(tester, fetch: () async => _release());

    expect(find.text('主界面'), findsOneWidget);
    expect(find.text(l10n.updateAvailable('0.9.0+900')), findsOneWidget);
    expect(find.text(l10n.updateDownload), findsOneWidget);
    // 「已经提示过」落盘，下一次启动不再弹。
    expect(prefs.updateLastNotified, '0.9.0+900');
  });

  testWidgets('同一个版本提示过：不再弹 SnackBar', (tester) async {
    await pumpHost(
      tester,
      prefValues: <String, Object>{'cm_update_last_notified': '0.9.0+900'},
      fetch: () async => _release(),
    );

    expect(find.text(l10n.updateAvailable('0.9.0+900')), findsNothing);
  });

  testWidgets('没有新版本：不弹 SnackBar', (tester) async {
    await pumpHost(
      tester,
      fetch: () async =>
          const UpdateRelease(version: '0.1.0', buildNumber: 131),
    );

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('用户关掉自动检查：启动不打网络、不弹提示', (tester) async {
    await pumpHost(
      tester,
      prefValues: <String, Object>{'cm_update_check_enabled': false},
      fetch: () async => _release(),
    );

    expect(find.byType(SnackBar), findsNothing);
    verifyNever(() => service.fetchLatest());
  });

  testWidgets('24 小时内检查过：不重复打网络', (tester) async {
    await pumpHost(
      tester,
      prefValues: <String, Object>{
        'cm_update_last_check_ms': DateTime.now().millisecondsSinceEpoch,
      },
      fetch: () async => _release(),
    );

    expect(find.byType(SnackBar), findsNothing);
    verifyNever(() => service.fetchLatest());
  });
}
