// 「设置 → 实例 → 添加实例 → 添加并登录」之后，用户必须走得出登录页。
//
// ## 这里钉的是什么
//
// `/login/:profileId` 是**顶层路由**（壳之外，全屏）—— 壳的侧栏与底部导航
// 在这一屏都不在，`AppBar` 的 `automaticallyImplyLeading` 只认
// `Navigator.canPop()`。而这一条流程用的是 `context.go`（不压栈），于是
// `canPop()` 是 false，箭头一颗都没有：一条全屏登录页，没有任何出口。
//
// 用户看到的就是「页面占满全屏，没有返回按钮」。
//
// 修法在 `LoginScreen.build`：`go` 上来、且**确实有一个已登录实例**时
// 显式补一颗 `BackButton`（`_leave`）。没有已登录实例时不补 —— 那时
// `resolveRedirect` 会把任何别的地址立刻弹回登录页，一颗点了没用的箭头
// 比不给更糟。
//
// ## 为什么用真的 `routerProvider`
//
// 缺陷的成因就是「顶层路由 + `go`」，拿一个 `Navigator` 或单页 widget 测
// 不出来（单页里 `canPop()` 恒为 false，反而会把正确行为判成错误）。所以
// 这里起真的 `GoRouter`，并让 `profilesProvider` 真的给出实例列表 ——
// 「有没有已登录实例」这个前提是修法的一半。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:mail_app/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 一个已登录的实例（`isLoggedIn` 要求 userId > 0 且邮箱非空）。
  const loggedIn = Profile(
    id: 'p1',
    baseUrl: 'https://a/api',
    email: 'a@a.com',
    userId: 7,
  );

  /// 刚建出来、还没登录的实例 —— 「添加并登录」之后落到的就是它。
  const fresh = Profile(id: 'p2', baseUrl: 'https://b/api');

  /// 起一棵真路由 + 真外壳。返回 router，顺带把时钟推进到稳定。
  ///
  /// [seedDb] 为真时，把 [profiles] 真的写进 drift 库、并让
  /// `profilesProvider` 走**真**仓库（而不是 `Stream.value` 的常量快照）。
  /// 删除那一条必须这样 —— 用例要验的正是「删完之后列表真的变了，
  /// `redirect` 因此把我们送去别处」，一个写死的快照验不出来。
  Future<GoRouterLike> pump(
    WidgetTester tester, {
    required List<Profile> profiles,
    required Size size,
    bool seedDb = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 删除实例要清 token（`TokenStore` 走安全存储）；不给 mock 的话那条
    // 通道直接抛 `MissingPluginException`。
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    if (seedDb) {
      for (final p in profiles) {
        await db.profileDao.upsertProfile(p);
      }
    }

    final container = ProviderContainer(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        prefsStoreProvider.overrideWithValue(prefs),
        if (!seedDb)
          profilesProvider.overrideWith((ref) => Stream.value(profiles)),
        // `SyncController` 的真身会拉起整个调度器（20s 周期时钟 + 平台通道），
        // 树拆掉之后那个时钟还在，`flutter_test` 会判「还有 Timer 没结束」。
        // 这一组验的是**地址与返回入口**，调度器不参与，换成空壳。
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
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return GoRouterLike(router);
  }

  /// 收尾：拆树再推一帧。
  ///
  /// 外壳里 `syncControllerProvider` 起着一个 20s 的周期时钟（收件轮询），
  /// 树拆掉时它还在，`flutter_test` 会判「树都拆了还有 Timer 没结束」——
  /// 那与本题无关。拆完推一帧把零延时的清理定时器放掉。
  Future<void> settleAndDispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  group('加实例流程走完之后，登录页必须有出口', () {
    for (final size in const <Size>[Size(420, 900), Size(1400, 900)]) {
      final label = '${size.width.toInt()}w';

      testWidgets('$label：go 上来的登录页有一颗能按的返回',
          (tester) async {
        final r = await pump(
          tester,
          profiles: const <Profile>[loggedIn, fresh],
          size: size,
        );

        // 照真流程走：设置 → 添加实例 → 添加并登录（表单调的就是这一句）。
        r.go(Routes.addInstance);
        await tester.pumpAndSettle();
        r.go('${Routes.login}/p2?next=settings');
        await tester.pumpAndSettle();

        expect(
          find.byType(BackButton),
          findsOneWidget,
          reason: '$label：顶层登录页是 _go_ 上来的（不压栈），'
              'AppBar 不会自己给箭头。没有它这一屏就是死路 —— '
              '壳的侧栏 / 底部导航在这条顶层路由上都不在。',
        );

        // 按下去要真的离开，而且回到来处（设置页）。
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();

        expect(r.uri, Routes.settings,
            reason: '$label：从 `?next=settings` 进来的，退出该回设置页 —— '
                '那正是登录成功之后的落点，两条路对得上');
        await settleAndDispose(tester);
      });
    }

    testWidgets('万一被 push 上来，也不会变成两颗箭头', (tester) async {
      final r = await pump(
        tester,
        profiles: const <Profile>[loggedIn, fresh],
        size: const Size(1400, 900),
      );
      r.go(Routes.settings);
      await tester.pumpAndSettle();

      // 现在仓库里**没有** `push` 到登录页的入口（设置页那两处、同步面板、
      // 加实例流程全是 `go`）。这一条是给将来留的护栏：`push` 上来时
      // `AppBar` 的 `automaticallyImplyLeading` 已经给了一颗，我们再补一颗
      // 就会是两颗。
      r.router.push('${Routes.login}/p2');
      await tester.pumpAndSettle();

      expect(
        find.byType(BackButton),
        findsOneWidget,
        reason: 'push 上来时 AppBar 的 automaticallyImplyLeading 已经给了一颗，'
            '我们再补一颗就会是两颗',
      );

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(r.uri, Routes.settings, reason: 'pop 回前一页');
      await settleAndDispose(tester);
    });

    testWidgets('设置页那颗「登录」带上了 next=settings —— 退出回设置页',
        (tester) async {
      // 设置页的入口**也是 `go`**（不是 push），所以它同样靠 `?next=settings`
      // 才知道退出与登录成功的落点。少了这个参数，用户从设置页点了登录、
      // 再按返回，会被丢到聚合收件箱 —— 接不上刚才那步操作。
      final r = await pump(
        tester,
        profiles: const <Profile>[loggedIn, fresh],
        size: const Size(1400, 900),
      );
      r.go(Routes.settings);
      await tester.pumpAndSettle();

      // 照实例行里那颗按钮的地址走。
      r.go('${Routes.login}/p2?next=settings');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(r.uri, Routes.settings);
      await settleAndDispose(tester);
    });

    testWidgets('一个已登录实例都没有时**不**给箭头，但必须留一条删除的路',
        (tester) async {
      // 这是**初次安装填错地址**的那一幕：只有一个实例、它还没登录。
      // `resolveRedirect` 会把 `/settings`、`/mail/all`、`/setup` 全都弹回
      // 这一页，而这一页此前没有任何删除入口 —— 整个 App 永久卡死，
      // 只能删 App 重装。所以此刻「返回」没用（用户本来就必须先登录），
      // 但**必须**能把这个填错的实例删掉。
      final r = await pump(
        tester,
        profiles: const <Profile>[fresh],
        size: const Size(1400, 900),
        seedDb: true,
      );
      r.go('${Routes.login}/p2');
      await tester.pumpAndSettle();

      expect(r.uri, '${Routes.login}/p2');
      expect(
        find.byType(BackButton),
        findsNothing,
        reason: '还没登录时没有可去的地方 —— 一颗点了只会被 redirect 弹回来的'
            '箭头比不给更糟',
      );

      // 删除入口在，而且按下去真的能出去。
      final remove = find.widgetWithText(TextButton, '删除实例');
      expect(
        remove,
        findsOneWidget,
        reason: '一个待登录实例都没有的时候，这是**唯一**的出路',
      );

      await tester.tap(remove);
      await tester.pumpAndSettle();
      // 确认框：同一颗按钮文案出现在对话框里，取最后一个（对话框在上面）。
      await tester.tap(find.widgetWithText(TextButton, '删除实例').last);
      await tester.pumpAndSettle();

      // 实例删光了 → redirect 把人送到「服务器设置」页，用户能重新填地址。
      expect(
        r.uri,
        Routes.setup,
        reason: '删掉最后一个实例之后没有实例了，`resolveRedirect` 该送到设置页',
      );
      await settleAndDispose(tester);
    });
  });
}

/// 把 `GoRouter` 收窄成这一组要用的两样（`go` / `push`），外加一个读地址的。
class GoRouterLike {
  GoRouterLike(this.router);

  final dynamic router;

  void go(String location) => router.go(location);

  void push(String location) => router.push(location);

  String get uri => router.routeInformationProvider.value.uri.toString();
}

/// `SyncController` 的真身会拉起整个调度器（时钟、平台通道）。这一组验的是
/// 地址与返回入口，所以只留一个空壳 —— 与 `sidebar_mailboxes_test.dart` 里
/// 那一个是同一个写法。
class _FakeSyncController extends SyncController {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  void setActiveProfile(String? profileId) {}
}
