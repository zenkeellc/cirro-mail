import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/providers/profile_providers.dart' show kAllMailboxes;

/// 收件箱多选邮箱的取值规则。
///
/// 三件事在界面上看不出对错，只能靠这里钉住：
/// 1. `null`（没筛过）与「全部勾上」是**同一个意思**；
/// 2. 取消到只剩一个之后不能再取消 —— 不允许出现「一个都不选」；
/// 3. 实例行的勾选态有第三种（半选），它不等于「全勾」也不等于「没勾」。
void main() {
  const a1 = MailboxFilter(profileId: 'A', accountId: 1);
  const a2 = MailboxFilter(profileId: 'A', accountId: 2);
  const b1 = MailboxFilter(profileId: 'B', accountId: 3);
  const all = <MailboxFilter>[a1, a2, b1];

  group('resolve', () {
    test('没筛过 = 全部勾上', () {
      final s = MailboxSelection.resolve(all, null);
      expect(s.selected, all);
      expect(s.isAll, isTrue);
      expect(s.isPartiallySelected, isFalse);
    });

    test('只认还在邮件箱列表里的那些（邮箱被删掉了不会留下幽灵勾选）', () {
      final s = MailboxSelection.resolve(
        all,
        const <MailboxFilter>[
          MailboxFilter(profileId: 'A', accountId: 1),
          MailboxFilter(profileId: 'Z', accountId: 9),
        ],
      );
      expect(s.selected, const <MailboxFilter>[a1]);
    });

    test('一项都对不上时退回「全部」，不留一个空集', () {
      // 全删光之后 `selected` 为空会让列表永久空白，用户又找不到原因。
      final s = MailboxSelection.resolve(
        all,
        const <MailboxFilter>[MailboxFilter(profileId: 'Z', accountId: 9)],
      );
      expect(s.selected, all);
    });
  });

  group('toggle', () {
    test('取消一个 → 剩两个', () {
      final s = MailboxSelection.resolve(all, null).toggle(a1);
      expect(s.selected, const <MailboxFilter>[a2, b1]);
      expect(s.isAll, isFalse);
      expect(s.isPartiallySelected, isTrue);
    });

    test('取消到只剩一个之后再取消会被拒绝', () {
      var s = MailboxSelection.resolve(all, null).toggle(a1).toggle(a2);
      expect(s.selected, const <MailboxFilter>[b1]);
      final after = s.toggle(b1);
      expect(after.selected, const <MailboxFilter>[b1]);
      expect(after.rejected, isTrue);
    });

    test('取消到只剩一个之后再勾回来是允许的', () {
      final s = MailboxSelection.resolve(all, null)
          .toggle(a1)
          .toggle(a2)
          .toggle(a1);
      expect(s.selected, const <MailboxFilter>[a1, b1]);
    });

    test('勾满之后 isAll 为真（回 prefs 时写 null）', () {
      final s = MailboxSelection.resolve(all, null).toggle(a1).toggle(a1);
      expect(s.isAll, isTrue);
      expect(s.toPrefsValue(), isNull);
    });

    test('不是全选时 toPrefsValue 给出具体集合', () {
      final s = MailboxSelection.resolve(all, null).toggle(a1);
      expect(s.toPrefsValue(), const <MailboxFilter>[a2, b1]);
    });
  });

  group('实例行', () {
    test('该实例全勾 → 全选', () {
      final s = MailboxSelection.resolve(all, null);
      expect(s.profileState('A'), MailboxTriState.all);
      expect(s.profileState('B'), MailboxTriState.all);
    });

    test('该实例勾了一部分 → 半选', () {
      final s = MailboxSelection.resolve(all, null).toggle(a2);
      expect(s.profileState('A'), MailboxTriState.partial);
      expect(s.profileState('B'), MailboxTriState.all);
    });

    test('该实例一个都没勾 → 没勾', () {
      final s = MailboxSelection.resolve(all, null).toggle(a1).toggle(a2);
      expect(s.profileState('A'), MailboxTriState.none);
      expect(s.profileState('B'), MailboxTriState.all);
    });

    test('点实例行 = 该实例整组切换', () {
      final s = MailboxSelection.resolve(all, null).toggleProfile('A');
      expect(s.selected, const <MailboxFilter>[b1]);

      final back = s.toggleProfile('A');
      expect(back.selected, all);
    });

    test('点实例行把整组取消时，同样受「最少留一个」约束', () {
      final s = MailboxSelection.resolve(
        const <MailboxFilter>[a1, a2],
        null,
      ).toggleProfile('A');
      expect(s.selected, const <MailboxFilter>[a1, a2]);
      expect(s.rejected, isTrue);
    });

    test('没有任何邮箱的实例（缺 account:query 权限）用合并项代表', () {
      const merged = <MailboxFilter>[
        MailboxFilter(profileId: 'A', accountId: kAllMailboxes),
      ];
      final s = MailboxSelection.resolve(merged, null);
      expect(s.selected, merged);
      expect(s.profileState('A'), MailboxTriState.all);
    });
  });

  group('wire 格式', () {
    test('转成字符串再转回来是同一个值', () {
      expect(a1.wire, 'A/1');
      expect(MailboxFilter.parse('A/1'), a1);
      expect(MailboxFilter.parse('A/0'), a1.copyWithAccount(kAllMailboxes));
    });

    test('坏数据解析成 null 而不是抛异常', () {
      expect(MailboxFilter.tryParse(''), isNull);
      expect(MailboxFilter.tryParse('A'), isNull);
      expect(MailboxFilter.tryParse('A/x'), isNull);
      expect(MailboxFilter.tryParse('/1'), isNull);
    });

    test('mailboxesToPrefs / prefsToMailboxes 往返', () {
      final prefs = mailboxesToPrefs(const <MailboxFilter>[a1, b1]);
      expect(prefs, const <String>['A/1', 'B/3']);
      expect(prefsToMailboxes(prefs), const <MailboxFilter>[a1, b1]);
    });
  });
}
