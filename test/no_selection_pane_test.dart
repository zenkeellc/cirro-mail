// 右栏空态：还没选中邮件时，那一格空白说的不再是「选择一封邮件」，而是
// 「给项目点个 Star」的引导。
//
// 钉四件事：
//
// 1. **挂在真的位置**：`MailPanes` 在 `selected == null` 时渲染的确实是这块
//    —— 只测 widget 本身看不出它有没有被接上；
// 2. **三样内容都在**：大号 👍、夸赞文案、仓库地址与「点个 Star」按钮，外加
//    那张 GitHub 标志（是 `Image`，不是 Material 图标）；
// 3. **地址只有一处**：卡片上显示的地址与按钮打开的目标是同一个常量
//    （`GithubRepo`，与「设置 → 关于」页的「开源项目」分组共用），
//    不会改一处忘另一处；
// 4. **点下去真的去开那个地址，开不成只弹 SnackBar**：`flutter_tester` 里
//    没有 `url_launcher` 的平台实现（真调会一直挂着、既不返回也不抛），
//    所以这里注入 `NoSelectionPane.openUrl` 分别模拟「开成」与「没开成」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/widgets/github_star_card.dart';
import 'package:mail_app/features/mail_list/mail_panes.dart';
import 'package:mail_app/features/mail_list/no_selection_pane.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations zh;

  setUp(() {
    zh = lookupAppLocalizations(const Locale('zh'));
  });

  Future<void> pumpPane(WidgetTester tester, {UrlOpener? openUrl}) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: openUrl == null
              ? const NoSelectionPane()
              : NoSelectionPane(openUrl: openUrl),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('内容：大号 👍 + 夸赞文案 + GitHub 标志 / 地址 / 点 Star 按钮', (tester) async {
    await pumpPane(tester);

    expect(find.text('👍'), findsOneWidget);
    expect(find.text(zh.noSelectionPraise), findsOneWidget);
    expect(find.text(GithubRepo.displayUrl), findsOneWidget);
    expect(find.text(zh.starOnGithub), findsOneWidget);
    // 右栏最宽 320：卡片竖排（地址在上、按钮在下），按钮不会被挤成半截。
    expect(
      tester.getCenter(find.text(GithubRepo.displayUrl)).dy,
      lessThan(tester.getCenter(find.text(zh.starOnGithub)).dy),
      reason: '窄处竖排：地址在上、按钮在下',
    );
    // GitHub 标志必须是**一张图**：Material 图标里没有 GitHub 的牌，
    // 换成某个近似图标（`Icons.code` 之类）在视觉上就不是那个意思了。
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('仓库地址只有一处：卡片显示与按钮目标是同一个常量', (tester) async {
    expect(GithubRepo.url, 'https://github.com/zenkeellc/cirro-mail');
    expect(GithubRepo.displayUrl, 'github.com/zenkeellc/cirro-mail');
    // 显示形式就是常量去掉协议，两处不可能各写一份写歪。
    expect(GithubRepo.displayUrl, GithubRepo.url.split('//').last);
  });

  testWidgets('点「点个 Star」打开的就是仓库地址（整张卡片也是同一个动作）', (tester) async {
    final opened = <Uri>[];
    await pumpPane(
      tester,
      openUrl: (uri) async {
        opened.add(uri);
        return true;
      },
    );

    await tester.tap(find.text(zh.starOnGithub));
    await tester.pump();
    expect(opened, <Uri>[Uri.parse(GithubRepo.url)]);
    // 打开成功就不该再弹「打不开」。
    expect(find.text(zh.githubOpenFailed), findsNothing);

    // 地址那一行（信息量小、目标是它旁边的按钮）同样把用户送过去。
    await tester.tap(find.text(GithubRepo.displayUrl));
    await tester.pump();
    expect(opened.length, 2);
  });

  testWidgets('没开成（返回 false）：只弹一条 SnackBar，不冒异常', (tester) async {
    await pumpPane(tester, openUrl: (uri) async => false);

    await tester.tap(find.text(zh.starOnGithub));
    // SnackBar 入场：微任务 → 首帧 → 动画。不用 `pumpAndSettle`，那会一路
    // 等到 SnackBar 自己消失（`update_host_test.dart` 里记过这个坑）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text(zh.githubOpenFailed), findsOneWidget);
  });

  testWidgets('阅读区最窄（420）且窗口很矮时：不溢出，整块可滚动', (tester) async {
    // 420 是 `Breakpoints.readerMinWidth`，也就是右栏能拿到的最小宽度；
    // 240 高是笔记本分屏时可能剩下的高度。这块东西竖着比 240 高，所以
    // 靠 `SingleChildScrollView` 兜住 —— 溢出的表现是 pump 直接抛
    // `RenderFlex overflowed`，这里不需要额外断言。
    tester.view.physicalSize = const Size(420, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpPane(tester);

    expect(tester.takeException(), isNull);
    expect(find.text(zh.noSelectionPraise), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('MailPanes 未选中邮件时，右栏就是这块', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsStoreProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: MailPanes(
              list: const SizedBox(width: 320),
              selected: null,
              onClosed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NoSelectionPane), findsOneWidget);
    expect(find.text(zh.noSelectionPraise), findsOneWidget);
    // 右栏不再重复「选择一封邮件」：空态已经把话说完了。
    expect(find.text(zh.pickMail), findsNothing);
  });
}
