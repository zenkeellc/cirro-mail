// 这一条钉的是**「实例」行菜单 → 备注名**那条路径上的一个旧 bug：
// `_promptText` 把 `TextEditingController` 建在方法里，`await showDialog(...)`
// 一返回就 `dispose()`。可那句话返回时路由还没走完 —— 退场动画（150ms）
// 期间 `TextField` 还活着、会被焦点持有并重建，撞上
//
//   A TextEditingController was used after being disposed.
//
// 以及连锁的 `_dependents.isEmpty is not true` / 在错误的 build scope 里
// 构建脏 widget。`mailboxes_section.dart` 里 `_RenameDialog` 已经修成
// 「控制器归对话框自己所有」（commit `2f3d2f9`），但**同一段形状**在
// `instances_section.dart` 的 `_promptText` 里原样留着，此前没有任何测试
// 覆盖到这条路径。
//
// 这条测试**只压「保存后把框关掉、退场动画跑完」这一下**，断言
// `tester.takeException()` 是 null —— 用 takeException 而不是让它飘到测试
// 收尾，才能把这个异常判成「这一条失败」而不是污染后续用例。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/instance_capabilities.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/features/settings/sections/instances_section.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final zh = lookupAppLocalizations(const Locale('zh'));

  late AppDatabase db;
  late PrefsStore prefs;
  late AuthEvents authEvents;
  late RuntimeRegistry registry;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    prefs = PrefsStore(await SharedPreferences.getInstance());
    authEvents = AuthEvents();
    registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: TokenStore(),
      prefs: prefs,
      // 这一条**永远不该建 runtime**（不该有任何真请求）；真被调到了，
      // 直接在那一行抛，比一个假的 200 更容易定位。
      buildApiDio: (_) => throw UnsupportedError('这一条用例不打网络'),
    );
  });
  tearDown(() async {
    registry.dispose();
    await authEvents.dispose();
    await db.close();
  });

  /// 已登录的实例：`userId > 0` 且 `email` 非空 → `isLoggedIn == true`，
  /// `needsLogin == false`。于是那一行**不会**多出「登录」按钮，trailing
  /// 只剩弹出菜单，定位时不会撞到别的按钮。
  const profile = Profile(
    id: 'pnb:inst',
    baseUrl: 'https://mail.example.net',
    userId: 42,
    email: 'admin@example.net',
    userName: 'admin',
  );

  Future<void> pumpSection(WidgetTester tester) async {
    // `rename` 走 `ProfileRepository.rename → profileDao.updateProfileFields`，
    // 那是真的落库，所以 `databaseProvider` 必须给一个真库（内存库即可）。
    await db.profileDao.upsertProfile(profile);
    final capabilities = CapabilityRepository(db);
    // `rename` 分支读 `profileRepositoryProvider` —— 显式喂一份只碰数据库与
    // 钥匙串的实例，不牵扯 registry / 同步那一大坨。
    final profiles = ProfileRepository(
      db: db,
      tokens: TokenStore(),
      prefs: prefs,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        databaseProvider.overrideWithValue(db),
        prefsStoreProvider.overrideWithValue(prefs),
        capabilityRepositoryProvider.overrideWithValue(capabilities),
        profileRepositoryProvider.overrideWithValue(profiles),
        runtimeRegistryProvider.overrideWithValue(registry),
        profilesProvider.overrideWith(
          (ref) => Stream<List<Profile>>.value(const <Profile>[profile]),
        ),
        capabilitiesProvider.overrideWith(
          (ref, String id) =>
              Stream<InstanceCapabilities>.value(const InstanceCapabilities()),
        ),
        // 行副标题的状态行读 `syncOverviewProvider`。这一条测的是对话框，
        // 不测同步面板，钉成空值省掉真调度器与它的定时器。
        syncOverviewProvider.overrideWith(
          (ref) => Stream<List<SyncOverview>>.value(const <SyncOverview>[]),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const Scaffold(body: InstancesSection()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('实例行菜单 → 备注名 → 保存：退场动画期间不该撞上「控制器已释放」',
      (tester) async {
    await pumpSection(tester);

    // 打开那一行的弹出菜单（按 `ValueKey<String>(profile.id)` 定位那一行，
    // 与 `_InstanceTile` 上的 key 一致），点「备注名」。
    final row = find.byKey(const ValueKey<String>('pnb:inst'));
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(zh.nickname));
    await tester.pumpAndSettle();

    // 输入新备注名 → 保存，把框关掉。
    await tester.enterText(find.byType(TextField), '新的备注名');
    await tester.tap(find.widgetWithText(FilledButton, zh.save));

    // 退场动画 + `rename` 落库都在这一句里跑完 —— 旧形状下控制器已经在
    // `_promptText` 返回后立刻被 dispose，而退场中的 `TextField` 还会再 build
    // 一次，于是异常就出在这里。用 takeException 明确收下它。
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: '控制器必须在对话框的 State.dispose 里释放，不能在 '
            'await showDialog 之后立刻释放');

    // 改名的效果本身也要在（不该为了修异常把落库弄丢了）。
    final saved = await db.profileDao.findProfile('pnb:inst');
    expect(saved?.name, '新的备注名');
  });
}
