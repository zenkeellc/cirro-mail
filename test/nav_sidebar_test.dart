import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/theme/app_theme.dart';
import 'package:mail_app/features/shell/nav_sidebar.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 一级导航项右侧那个数字的两种形态。
///
/// 「未读邮件」那一项的数字是**红色徽章**（与邮箱行最右那颗同款），其余入口
/// （收件箱 / 发件箱 / 草稿箱）保持灰色数字。两者错了都不会崩：只会让红色
/// 失去「专指未读」的含义，或者让未读数在一列灰字里看不见 —— 只能靠断言。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required int count,
    bool countBadge = false,
    bool alwaysShowCount = false,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: NavSidebarItem(
          icon: Icons.mark_email_unread_outlined,
          selectedIcon: Icons.mark_email_unread,
          label: '未读邮件',
          selected: false,
          count: count,
          countBadge: countBadge,
          alwaysShowCount: alwaysShowCount,
          onTap: () {},
        ),
      ),
    ));
  }

  testWidgets('countBadge：未读数画成红色徽章', (tester) async {
    await pump(tester, count: 3, countBadge: true);

    final badge = find.byType(SidebarUnreadBadge);
    expect(badge, findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.byType(SidebarCountPill), findsNothing);

    final container = tester.widget<Container>(
      find.descendant(of: badge, matching: find.byType(Container)).first,
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.color, AppTheme.light().colorScheme.error);
  });

  testWidgets('countBadge：读屏拿到的是「未读 N」而不是一个孤立的数字', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, count: 3, countBadge: true);

    // 红色是**视觉**语义；裸着一个「3」读屏只会念出一个数字。整行是一个
    // 可点的语义节点（标签会与「未读邮件」合并成多行），所以断言「包含」。
    final node = tester.getSemantics(find.byType(SidebarUnreadBadge));
    expect(node.label, contains('未读 3'));

    handle.dispose();
  });

  testWidgets('不传 countBadge：还是原来那颗灰色数字', (tester) async {
    await pump(tester, count: 3);

    expect(find.byType(SidebarUnreadBadge), findsNothing);
    expect(find.byType(SidebarCountPill), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('未读 0 时徽章不出现（红色只留给「有未读」）', (tester) async {
    await pump(tester, count: 0, countBadge: true);

    expect(find.byType(SidebarUnreadBadge), findsNothing);
    expect(find.text('0'), findsNothing);
  });
}
