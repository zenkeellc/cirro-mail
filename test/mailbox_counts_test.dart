import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/shell/sidebar_counts.dart';

/// 侧栏那些数字的文案。
///
/// 这几条分支的错法全是**安静**的：多一个 `/0`、少一个数字、几十个邮箱每个
/// 名字后面挂一个浅灰的 `0`（看着像坏了）—— 都不会有任何东西崩，只能靠断言。
void main() {
  group('formatSidebarCount', () {
    test('99 以内原样，100 起折成 99+', () {
      expect(formatSidebarCount(0), '0');
      expect(formatSidebarCount(1), '1');
      expect(formatSidebarCount(99), '99');
      expect(formatSidebarCount(100), '99+');
      expect(formatSidebarCount(9999), '99+');
    });
  });

  group('formatMailboxTotal', () {
    test('未知（还没探过）→ 不画', () {
      // `null` 与 `0` 不可互换：前者是「还没探过」，后者是「服务端说它是空的」。
      // 但对这一格来说两者都该安静 —— 区别在徽章那边（未读仍会显示）。
      expect(formatMailboxTotal(null), isNull);
    });

    test('已知 0 → 不画（空邮箱不挂一个浅灰的 0）', () {
      expect(formatMailboxTotal(0), isNull);
    });

    test('已知正数 → 总数本身', () {
      expect(formatMailboxTotal(1), '1');
      expect(formatMailboxTotal(12), '12');
    });

    test('99+ 在总数这一格生效', () {
      expect(formatMailboxTotal(99), '99');
      expect(formatMailboxTotal(4000), '99+');
    });
  });
}
