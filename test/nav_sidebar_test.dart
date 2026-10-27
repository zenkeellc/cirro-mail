import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/theme/app_theme.dart';
import 'package:mail_app/features/shell/nav_sidebar.dart';

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
