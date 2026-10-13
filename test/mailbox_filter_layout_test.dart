import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/providers/profile_providers.dart' show kAllMailboxes;

/// 把「本地邮箱列表」折成勾选面板里的行。
///
/// 这一段是纯函数，所以能脱离 widget 测 —— 而它恰好是最容易错的地方：
/// 缺 `account:query` 权限的实例**本地没有邮箱列表**，面板里得给它一行
/// 合并项，否则那台实例的信在筛了别的实例之后会整体消失，用户完全不知道原因。
///
/// 文件名里的 `layout` 指的是「这些项怎么摊成行」，**不是** widget 布局 ——
/// 原来叫 `mailbox_filter_sheet`，那颗底部弹层已经被锚定浮层替掉了；这些
/// 规则现在同时供浮层与侧栏的邮箱下级菜单使用，所以按内容重新命名。
void main() {
  const a = MailboxAccount(accountId: 1, email: 'a@example.net', name: 'A');
  const a2 = MailboxAccount(accountId: 2, email: 'a2@example.net', name: 'A2');
  const b = MailboxAccount(accountId: 3, email: 'b@example.com', name: 'B');

  test('一个邮箱 → 一项', () {
    expect(
      boxesOfProfile('P', const <MailboxAccount>[a]),
      const <MailboxFilter>[MailboxFilter(profileId: 'P', accountId: 1)],
    );
  });

  test('多个邮箱 → 多个项，顺序与列表一致', () {
    expect(
      boxesOfProfile('P', const <MailboxAccount>[b, a, a2])
          .map((x) => x.accountId),
      const <int>[3, 1, 2],
    );
  });

  test('没有邮箱列表（缺 account:query 权限）→ 一行合并项', () {
    // `kAllMailboxes` 不是「没指名」，是「这个实例的全部邮箱」。
    expect(
      boxesOfProfile('P', const <MailboxAccount>[]),
      const <MailboxFilter>[
        MailboxFilter(profileId: 'P', accountId: kAllMailboxes),
      ],
    );
  });

  test('拼多个实例时保持实例顺序', () {
    final boxes = allBoxesOf(<String, List<MailboxAccount>>{
      'P': const <MailboxAccount>[a, a2],
      'Q': const <MailboxAccount>[b],
    });
    expect(boxes, const <MailboxFilter>[
      MailboxFilter(profileId: 'P', accountId: 1),
      MailboxFilter(profileId: 'P', accountId: 2),
      MailboxFilter(profileId: 'Q', accountId: 3),
    ]);
  });

  test('实例之间不会因为账号 id 撞号而互相污染', () {
    const sameId = MailboxAccount(accountId: 1, email: 'x@x.com');
    final boxes = allBoxesOf(<String, List<MailboxAccount>>{
      'P': const <MailboxAccount>[sameId],
      'Q': const <MailboxAccount>[sameId],
    });
    expect(boxes.length, 2);
    expect(boxes[0] == boxes[1], isFalse);
  });

  test('默认全选：写进 prefs 的是 null', () {
    final boxes = allBoxesOf(<String, List<MailboxAccount>>{
      'P': const <MailboxAccount>[a, a2],
    });
    expect(MailboxSelection.resolve(boxes, null).toPrefsValue(), isNull);
  });

  test('筛过的值读回来是同一组（跨实例）', () {
    final boxes = allBoxesOf(<String, List<MailboxAccount>>{
      'P': const <MailboxAccount>[a, a2],
      'Q': const <MailboxAccount>[b],
    });
    const saved = <MailboxFilter>[
      MailboxFilter(profileId: 'P', accountId: 2),
      MailboxFilter(profileId: 'Q', accountId: 3),
    ];
    final selection = MailboxSelection.resolve(boxes, saved);
    expect(selection.selected, saved);
    expect(selection.profileState('P'), MailboxTriState.partial);
    expect(selection.profileState('Q'), MailboxTriState.all);
  });

  test('按实例分组渲染时的顺序与实例列表一致', () {
    final boxes = allBoxesOf(<String, List<MailboxAccount>>{
      'P': const <MailboxAccount>[a, a2],
      'Q': const <MailboxAccount>[b],
    });
    expect(profileOrderOf(boxes), const <String>['P', 'Q']);
  });

  test('邮箱行的标签：合并项是「全部邮箱」，具体项是它的地址', () {
    final byProfile = <String, List<MailboxAccount>>{
      'P': const <MailboxAccount>[a, a2],
    };
    expect(
      mailboxLabelOf(const MailboxFilter(profileId: 'P', accountId: 2), byProfile),
      'a2@example.net',
    );
    expect(
      mailboxLabelOf(
        const MailboxFilter(profileId: 'P', accountId: kAllMailboxes),
        byProfile,
      ),
      '全部邮箱',
    );
  });

  test('邮箱已经不在本地表里时不假装知道，退回账号号', () {
    expect(
      mailboxLabelOf(
        const MailboxFilter(profileId: 'P', accountId: 99),
        const <String, List<MailboxAccount>>{},
      ),
      '99',
    );
  });
}
