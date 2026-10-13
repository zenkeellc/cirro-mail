// 顶栏图标按钮的落点（`AppExtension.shellActions`）。
//
// 这一条接缝只有三处落点，而三处**都是静默失败**：漏接一处不会报错，只是
// 那个页面上没有按钮 —— 用户会以为「这个功能在这个页面不可用」。所以逐处钉。
//
// 同时钉住反方向：**空注册表时一颗都不多**。公开版（以及没装扩展的商业版）
// 的顶栏必须与从前逐像素相同。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/home/home_menu_screen.dart';
import 'package:mail_app/features/mail_list/mail_list_screen.dart';
import 'package:mail_app/features/sync/sync_status_panel.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个往顶栏插一颗搜索按钮的假扩展 —— 形状与商业版那颗一致。
class _SearchExt extends AppExtension {
  const _SearchExt();

  @override
  String get id => 'test.search';

  @override
  List<Widget> shellActions(BuildContext context) => <Widget>[
        IconButton(
          key: const ValueKey('ext-search'),
          icon: const Icon(Icons.search),
          tooltip: '搜索',
          onPressed: () {},
        ),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  /// 两个页面共用的宿主。列表相关的数据源全换成固定流 —— 这里断言的是
  /// 「按钮在不在」，不是数据。
  ///
  /// **容器由测试自己持有**（`UncontrolledProviderScope`），不走
  /// `ProviderScope`。理由是 `MailListScreen.deactivate`：它排了一个帧后回调
  /// 去 `_preselect.clear()`，而一帧内 `drawFrame` 是**先** `finalizeTree`
  /// （连容器一起 unmount 掉）**再**跑帧后回调的 —— 于是「把列表页摘下来」
  /// 这件与本题无关的事会以 `UnmountedRefException` 的形式红在这里。
  /// 容器活着，回调就正常跑完（`compose_*_test.dart` 里那一族用的是同一个
  /// 形状）。
  ///
  /// 不写成 `List<Override>`：`Override` 在 riverpod 3 里是 `sealed` 且没有
  /// 对外导出，显式写那个类型名反而编译不过（与 `main.dart` 里同一句注释）。
  /// 让推断来 —— 所以这里返回 `List<dynamic>` 再交给调用方展开是不行的，
  /// 直接把 override 建在 `pump` 里面。
  Future<void> pump(WidgetTester tester, Widget child) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        prefsStoreProvider.overrideWithValue(prefs),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[
            Profile(id: 'p1', baseUrl: 'https://x/api', email: 'a@x.com'),
          ]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(const <MailboxAccount>[]),
        ),
        mailListProvider.overrideWith(
          (ref, query) => Stream.value(const <MailRow>[]),
        ),
        unsyncedPlaceholderProvider.overrideWith(
          (ref, query) => Stream<int?>.value(null),
        ),
        syncOverviewProvider.overrideWith(
          (ref) => Stream.value(const <SyncOverview>[]),
        ),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
      ],
    );
    // 后进先出：先 dispose 容器（它取消底下那些 drift 流订阅），再关库。
    addTearDown(db.close);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: child,
      ),
    ));
    await tester.pumpAndSettle();
  }

  const listScreen = MailListScreen(folder: MailFolder.receive);

  /// 把页面摘下来，并把时钟往前推一帧。
  ///
  /// 容器**不随这一句销毁**（`UncontrolledProviderScope` 不持有它），所以
  /// `deactivate` 的帧后回调跑得完；它那份 drift 流订阅是到 `addTearDown` 里
  /// 才取消的，而那时 flutter_test 的「还有没有挂着的定时器」已经查过了 ——
  /// 检查是在用例体返回时做的（`mail_detail_header_test.dart` 里同名函数写着
  /// 同一句话）。时钟那一帧是给别处那些零延时清扫定时器留的。
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  }

  group('窄屏邮件列表页', () {
    testWidgets('窄屏：扩展按钮与同步按钮并排出现在 AppBar 里', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _SearchExt(),
      ]);
      await pump(tester, listScreen);

      expect(find.byKey(const ValueKey('ext-search')), findsOneWidget);
      // 同步按钮照旧（扩展是追加，不是替换）。
      expect(find.byType(SyncStatusButton), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('没注册扩展时只有同步按钮那一颗', (tester) async {
      await pump(tester, listScreen);
      expect(find.byKey(const ValueKey('ext-search')), findsNothing);
      expect(find.byType(SyncStatusButton), findsOneWidget);
      expect(
        tester.widget<AppBar>(find.byType(AppBar)).actions,
        hasLength(1),
        reason: '空注册表时 actions 里只该有同步按钮',
      );

      await unmount(tester);
    });
  });

  group('窄屏主屏', () {
    testWidgets('扩展按钮出现在 AppBar 里', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _SearchExt(),
      ]);
      await pump(tester, const HomeMenuScreen());

      expect(find.byKey(const ValueKey('ext-search')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('没注册扩展时 AppBar 没有任何按钮', (tester) async {
      await pump(tester, const HomeMenuScreen());
      expect(find.byKey(const ValueKey('ext-search')), findsNothing);
      expect(
        tester.widget<AppBar>(find.byType(AppBar)).actions,
        anyOf(isNull, isEmpty),
        reason: '主屏从前就没有顶栏按钮，接了接缝之后也不许凭空多一颗',
      );

      await unmount(tester);
    });
  });
}
