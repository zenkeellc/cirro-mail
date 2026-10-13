import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/shell/sidebar_counts.dart';

/// 侧栏右侧那一格的文案。
///
/// 这几条分支的错法全是**安静**的：多一个 `/0`、少一个数字、几十个邮箱每个
/// 挂一个灰色 `—`（看着像坏了）—— 都不会有任何东西崩，只能靠断言。
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

  group('formatMailboxCounts', () {
    test('总数未知 + 未读 0 → 整格不画', () {
      expect(formatMailboxCounts(unread: 0, total: null, unknown: '—'), isNull);
    });

    test('总数未知 + 未读 > 0 → 未读/—', () {
      expect(formatMailboxCounts(unread: 3, total: null, unknown: '—'), '3/—');
    });

    test('已知 0/0 → 整格不画（空邮箱不挂一个灰色的 0）', () {
      expect(formatMailboxCounts(unread: 0, total: 0, unknown: '—'), isNull);
    });

    test('已知总数 + 未读 > 0 → 未读/总数', () {
      expect(formatMailboxCounts(unread: 3, total: 12, unknown: '—'), '3/12');
    });

    test('已知总数 + 未读 0 → 只画总数', () {
      expect(formatMailboxCounts(unread: 0, total: 12, unknown: '—'), '12');
    });

    test('未读为 0 而总数未知，与「未知 + 有未读」是两回事', () {
      // 这一条钉的是「`total == null` 与 `total == 0` 不可互换」：
      // 前者是「还没探过」，后者是「服务端说它是空的」。
      expect(formatMailboxCounts(unread: 0, total: null, unknown: '—'), isNull);
      expect(formatMailboxCounts(unread: 0, total: 0, unknown: '—'), isNull);
      expect(formatMailboxCounts(unread: 5, total: null, unknown: '—'), '5/—');
      expect(formatMailboxCounts(unread: 5, total: 0, unknown: '—'), '5/0');
    });

    test('99+ 在未读与总数两侧都生效', () {
      expect(formatMailboxCounts(unread: 150, total: 4000, unknown: '—'), '99+/99+');
      expect(formatMailboxCounts(unread: 0, total: 4000, unknown: '—'), '99+');
      expect(formatMailboxCounts(unread: 150, total: null, unknown: '—'), '99+/—');
    });

    test('未知那个占位符是调用方给的，不是写死的字面量', () {
      // 钉住「`—` 来自 l10n」：写死在纯函数里的话，将来本地化要换一个别的
      // 占位符就得回来改这个函数，而它看着只是个 `—`，很容易被当成无害。
      expect(formatMailboxCounts(unread: 3, total: null, unknown: '?'), '3/?');
    });
  });
}
