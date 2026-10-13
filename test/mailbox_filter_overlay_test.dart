import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/mail_list/mailbox_filter_button.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 浮层跟着「这一页还在不在栈顶」收起。
///
/// 这条路径**在界面上看不出来**是在哪儿坏的：面板挂在 Navigator 那层
/// `Overlay` 上，push 一整页详情时它只是被不透明的路由**盖住**（offstage），
/// 并没有被拆掉；退回来时它会原样出现在屏幕上，看起来像「谁忘了关的浮层」。
/// 主流程（窄屏从列表点开一封信、再按返回）正好每一步都踩在它上面。
///
/// 收口的方式不是订阅（本版 Flutter 的 `Route` 不是 `Listenable`、
/// 没有 `addListener`），而是 `ModalRoute.of(context)` 建立的那条依赖：
/// `_ModalScopeStatus` 变了就重建 `MailboxFilterHeaderButton`，它在 build 里
/// 发现自己不再是栈顶，帧后 `hide()`。
///
/// 这是仓库里**第一组**「pump 一整块挂 `ProviderScope` 的界面」的用例
/// （`push_pages_test.dart` 里记着此前没有先例），所以顺带把最小 override
/// 的写法固定下来：**只换 prefs 与两条数据源，不建数据库**。
/// `bootstrapProvider` 那一套（内存库 + token）在这里是多余的 —— 面板要的
/// 「有哪些邮箱可勾」和「谁在列表里」都被下面两条 override 挡掉了，
/// 而建库会留下 drift 的流关闭定时器，`flutter test` 会以
/// 「A Timer is still pending」收场。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('push 一页之后浮层收起，退回来不复活', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(ProviderScope(
      // 不写 `<Override>[]`：`Override` 在 riverpod 3 里是 `sealed` 且没有
      // 对外导出，显式写类型名反而编译不过（`lib/main.dart` 里同一句注释）。
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        activeProfilesProvider.overrideWithValue(const <Profile>[
          Profile(id: 'p1', baseUrl: 'https://x/api', email: 'a@x.com'),
        ]),
        allMailboxesByProfileProvider.overrideWithValue(
          <String, List<MailboxAccount>>{
            'p1': const <MailboxAccount>[
              MailboxAccount(accountId: 1, email: 'a@x.com'),
            ],
          },
        ),
      ],
      child: MaterialApp(
        navigatorKey: navKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Center(child: MailboxFilterHeaderButton(count: 1)),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 点开浮层。
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(find.text('按邮箱筛选'), findsOneWidget);

    // 压一页上去（窄屏点开一封信走的就是这条）。
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('DETAIL')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('DETAIL'), findsOneWidget);

    // 退回来：浮层不该「复活」。
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('按邮箱筛选'), findsNothing);

    // 按钮本身照旧可用（收的是浮层，不是入口）。
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(find.text('按邮箱筛选'), findsOneWidget);
  });
}
