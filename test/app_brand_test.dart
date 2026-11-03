// 产品名接缝（`AppExtension.appDisplayName` → `AppBrand`）。
//
// 需求是「商业版叫 `Cirro Mail Pro`，公开版叫 `Cirro Mail`」，但**核心不认
// 商业版**：名字由扩展接缝给，核心只负责在四个显示位把它铺出来。所以这一组
// 钉住两件事：
//
// 1. **空注册表 = 公开版原样**：窗口标题、侧栏左上角、关于页仍然是
//    `Cirro Mail`（接缝不能改变公开版的一字一像素）；
// 2. **注册带名字的扩展之后，那些位置真的换成扩展给的名字**，而且是**整串**
//    （`Cirro Mail Pro` 一起出现），不是核心自己拼的后缀。
//
// 显示位三处（侧栏左上角 / 窗口标题 / 关于页）各起一棵最小的树，不是为了重测
// 布局，而是为了钉「接缝确实接到了那一行」—— 布局由它们各自的测试负责。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/branding/app_brand.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/core/version/app_version.dart';
import 'package:mail_app/core/version/version_info.dart';
import 'package:mail_app/core/version/window_title.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/settings/sections/about_section.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个只声明产品名的假扩展。`name` 为 null / 空白时应当回落到核心默认名。
class _NamedBrand extends AppExtension {
  const _NamedBrand(this.id, this.name);

  @override
  final String id;

  final String? name;

  @override
  String? get appDisplayName => name;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  group('注册表 / AppBrand 的取值规则', () {
    test('空注册表：两个入口都回落到公开版默认名', () {
      expect(AppExtensionRegistry.instance.appDisplayName, isNull);
      expect(AppBrand.extensionName, isNull);
      expect(AppBrand.windowName, 'Cirro Mail');
    });

    test('注册后：窗口名直接用扩展给的整串（不拼接、不改写）', () {
      AppExtensionRegistry.instance.registerAll(const <AppExtension>[
        _NamedBrand('test.brand.pro', 'Cirro Mail Pro'),
      ]);

      expect(AppBrand.extensionName, 'Cirro Mail Pro');
      expect(AppBrand.windowName, 'Cirro Mail Pro');
    });

    test('空白名按「不参与命名」处理，不把 App 名弄成空标题', () {
      AppExtensionRegistry.instance.registerAll(const <AppExtension>[
        _NamedBrand('test.brand.blank', '   '),
        _NamedBrand('test.brand.pro', 'Cirro Mail Pro'),
      ]);

      expect(AppBrand.windowName, 'Cirro Mail Pro');
    });

    test('多个扩展都认领时按注册顺序取第一个 —— 产品名只能有一个', () {
      AppExtensionRegistry.instance.registerAll(const <AppExtension>[
        _NamedBrand('test.brand.a', 'First Name'),
        _NamedBrand('test.brand.b', 'Second Name'),
      ]);

      expect(AppBrand.windowName, 'First Name');
    });

    test('名字首尾空白会被去掉（避免标题里多出空格）', () {
      AppExtensionRegistry.instance.registerAll(const <AppExtension>[
        _NamedBrand('test.brand.padded', '  Cirro Mail Pro  '),
      ]);

      expect(AppBrand.windowName, 'Cirro Mail Pro');
    });
  });

  group('界面文字里的产品名（AppBrand.displayName）', () {
    /// 一棵只提供本地化环境的树，用它的 context 调 [AppBrand.displayName]。
    Future<String> displayNameIn(
      WidgetTester tester,
      Locale locale,
    ) async {
      late String name;
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) {
              name = AppBrand.displayName(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return name;
    }

    testWidgets('空注册表：中文 / 英文都回落 ARB 的 appTitle', (tester) async {
      expect(await displayNameIn(tester, const Locale('zh')), 'Cirro Mail');
      expect(await displayNameIn(tester, const Locale('en')), 'Cirro Mail');
    });

    testWidgets('注册后：产品名是整串，中英界面一致（商标不随语言翻译）',
        (tester) async {
      AppExtensionRegistry.instance.registerAll(const <AppExtension>[
        _NamedBrand('test.brand.pro', 'Cirro Mail Pro'),
      ]);

      expect(await displayNameIn(tester, const Locale('zh')), 'Cirro Mail Pro');
      expect(await displayNameIn(tester, const Locale('en')), 'Cirro Mail Pro');
    });
  });

  group('显示位：侧栏左上角', () {
    /// 起**真外壳 + 真路由**，只关心侧栏标题行那一行字。
    ///
    /// 与 `app_shell_sidebar_test.dart` 同一套最小依赖：建库 / 预填充数 /
    /// 钉死几个同步数字，树拆掉之后不留时钟与 drift 查询。
    Future<void> pumpShell(WidgetTester tester, {Locale? locale}) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      const profile = Profile(
        id: 'p1',
        baseUrl: 'https://x/api',
        email: 'a@x.com',
        userId: 7,
      );

      final container = ProviderContainer(
        overrides: [
          bootstrapProvider.overrideWithValue(
            BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
          ),
          prefsStoreProvider.overrideWithValue(prefs),
          profilesProvider.overrideWith(
            (ref) => Stream.value(const <Profile>[profile]),
          ),
          allMailboxesByProfileProvider.overrideWithValue(
            const <String, List<MailboxAccount>>{},
          ),
          mailboxUnreadProvider.overrideWith((ref, key) => 0),
          mailboxTotalProvider.overrideWith((ref, key) => null),
          profileUnreadProvider.overrideWith((ref, profileId) => 0),
          instanceTotalProvider.overrideWith((ref, profileId) => null),
          totalUnreadProvider.overrideWithValue(0),
          outboxPendingCountProvider.overrideWithValue(0),
          draftCountProvider.overrideWithValue(0),
          syncControllerProvider.overrideWith(_FakeSyncController.new),
        ],
      );
      addTearDown(container.dispose);

      final router = container.read(routerProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale ?? const Locale('zh'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      router.go('/mail/p1');
      await tester.pumpAndSettle();
    }

    /// 拆树再推一帧：外壳里零延时的清理定时器不能在用例结束时还挂着。
    Future<void> settleAndDispose(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 5));
    }

    testWidgets('空注册表：侧栏左上角是 Cirro Mail，没有 Pro', (tester) async {
      await pumpShell(tester);
      expect(find.text('Cirro Mail'), findsOneWidget);
      expect(find.text('Cirro Mail Pro'), findsNothing);
      await settleAndDispose(tester);
    });

    testWidgets('注册后：侧栏左上角显示整串 Cirro Mail Pro', (tester) async {
      AppExtensionRegistry.instance.registerAll(const <AppExtension>[
        _NamedBrand('test.brand.pro', 'Cirro Mail Pro'),
      ]);
      await pumpShell(tester);
      expect(find.text('Cirro Mail Pro'), findsOneWidget);
      expect(find.text('Cirro Mail'), findsNothing);
      await settleAndDispose(tester);
    });
  });

  group('显示位：桌面窗口标题', () {
    const windowChannel = MethodChannel('com.zenkee.cirromail/window');

    List<MethodCall> captureWindowCalls() {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(windowChannel, null);
      });
      return calls;
    }

    /// 平台覆盖必须在用例体内复位（放 `addTearDown` 会被
    /// `debugAssertAllFoundationVarsUnset` 判成「测试改了 foundation 变量」）。
    Future<void> withMacOS(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<void> pumpHost(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appVersionProvider.overrideWith(
              (ref) async => const AppVersion(name: '0.1.0', buildNumber: 131),
            ),
          ],
          child: const WindowTitleHost(child: SizedBox.shrink()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('空注册表：标题里是 Cirro Mail', (tester) async {
      final calls = captureWindowCalls();
      await withMacOS(() async {
        await pumpHost(tester);
        expect(
          calls.single.arguments,
          <String, Object?>{'title': 'Cirro Mail v0.1.0+131'},
        );
      });
    });

    testWidgets('注册后：标题里是整串 Cirro Mail Pro', (tester) async {
      AppExtensionRegistry.instance.registerAll(const <AppExtension>[
        _NamedBrand('test.brand.pro', 'Cirro Mail Pro'),
      ]);
      final calls = captureWindowCalls();
      await withMacOS(() async {
        await pumpHost(tester);
        expect(
          calls.single.arguments,
          <String, Object?>{'title': 'Cirro Mail Pro v0.1.0+131'},
        );
      });
    });
  });

  group('显示位：设置 → 关于', () {
    Future<void> pumpAbout(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsStoreProvider.overrideWithValue(prefs),
            // 版本钉成「未知」：这一组只关心名字，不该被真实 PackageInfo
            // （`flutter_tester` 里没有平台通道）或版本明细干扰。
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

    testWidgets('空注册表：关于页第一行是 Cirro Mail', (tester) async {
      await pumpAbout(tester);
      expect(find.text('Cirro Mail'), findsOneWidget);
      expect(find.text('Cirro Mail Pro'), findsNothing);
    });

    testWidgets('注册后：关于页第一行是整串 Cirro Mail Pro', (tester) async {
      AppExtensionRegistry.instance.registerAll(const <AppExtension>[
        _NamedBrand('test.brand.pro', 'Cirro Mail Pro'),
      ]);
      await pumpAbout(tester);
      expect(find.text('Cirro Mail Pro'), findsOneWidget);
      // 版本行仍在它下面（名字换了，那一行的结构不动）。
      expect(
        find.byKey(const ValueKey<String>('about-version')),
        findsOneWidget,
      );
    });
  });
}

/// `SyncController` 真身会拉起整个调度器（时钟 + 平台通道），用例里换成空的。
class _FakeSyncController extends SyncController {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  void setActiveProfile(String? profileId) {}
}
