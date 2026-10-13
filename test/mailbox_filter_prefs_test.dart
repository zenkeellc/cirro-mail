import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 邮箱筛选的落盘与 `MailListQuery` 的值语义。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('没存过 = null（= 全部）', () async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    expect(prefs.mailboxFilter, isNull);
  });

  test('存进去再读回来是同一组', () async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    await prefs.setMailboxFilter(const <MailboxFilter>[
      MailboxFilter(profileId: 'A', accountId: 1),
      MailboxFilter(profileId: 'B', accountId: 3),
    ]);
    expect(prefs.mailboxFilter, const <MailboxFilter>[
      MailboxFilter(profileId: 'A', accountId: 1),
      MailboxFilter(profileId: 'B', accountId: 3),
    ]);
  });

  test('写 null 或空集合都清掉（= 回到全部）', () async {
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    await prefs.setMailboxFilter(const <MailboxFilter>[
      MailboxFilter(profileId: 'A', accountId: 1),
    ]);
    await prefs.setMailboxFilter(null);
    expect(prefs.mailboxFilter, isNull);

    await prefs.setMailboxFilter(const <MailboxFilter>[
      MailboxFilter(profileId: 'A', accountId: 1),
    ]);
    await prefs.setMailboxFilter(const <MailboxFilter>[]);
    expect(prefs.mailboxFilter, isNull);
  });

  test('坏数据整条丢掉，不影响剩下那些', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cm_mailbox_filter': <String>['A/1', 'garbage', 'B/x', 'B/3'],
    });
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    expect(prefs.mailboxFilter, const <MailboxFilter>[
      MailboxFilter(profileId: 'A', accountId: 1),
      MailboxFilter(profileId: 'B', accountId: 3),
    ]);
  });

  group('侧栏的邮箱下级菜单展开态', () {
    /// **默认展开**：这一组是「某一个邮箱的收件箱」这条路径的唯一入口，
    /// 默认收着等于新功能没人看得见。取 `?? true` 而不是存 `false`，
    /// 是为了让升级上来的老用户（没有这个 key）看到的也是展开态。
    test('没存过 = 展开', () async {
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      expect(prefs.sidebarMailboxesExpanded, isTrue);
    });

    test('存进去再读回来是同一个值', () async {
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      await prefs.setSidebarMailboxesExpanded(false);
      expect(prefs.sidebarMailboxesExpanded, isFalse);
      await prefs.setSidebarMailboxesExpanded(true);
      expect(prefs.sidebarMailboxesExpanded, isTrue);
    });
  });

  group('每台实例的展开态', () {
    /// 存的是「**收起**了哪些」：默认展开，所以只记偏离默认的那些 ——
    /// 新实例、新装的 App、老版本升级上来这三种情况都**不该写任何东西**。
    test('没存过 = 空集合（每台都展开）', () async {
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      expect(prefs.collapsedSidebarInstances, isEmpty);
    });

    test('存进去再读回来是同一组', () async {
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      await prefs.setCollapsedSidebarInstances(<String>{'p1', 'p2'});
      expect(prefs.collapsedSidebarInstances, <String>{'p1', 'p2'});
    });

    /// **空集合要 remove 而不是写一个空列表**：写空列表读回来也是空集合，
    /// 行为上看不出来，但那个 key 会一直留在 prefs 里 —— 这一条钉的是
    /// 「回到默认态 = 回到没写过的样子」。
    test('清空 = 把 key 整个删掉', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cm_sidebar_collapsed_instances': <String>['p1'],
      });
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      expect(prefs.collapsedSidebarInstances, <String>{'p1'});
      await prefs.setCollapsedSidebarInstances(<String>{});
      expect(prefs.collapsedSidebarInstances, isEmpty);
      final raw = await SharedPreferences.getInstance();
      expect(raw.containsKey('cm_sidebar_collapsed_instances'), isFalse);
    });

    /// 里面可能留着已经删掉的实例 id（用户删实例时没人去清）：读的时候
    /// 对不上就忽略，**不能**因为多了一个不认识的 id 就整组读不出来。
    test('留着已经删掉的实例 id 不影响剩下的', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cm_sidebar_collapsed_instances': <String>['gone', 'p1'],
      });
      final prefs = PrefsStore(await SharedPreferences.getInstance());
      expect(prefs.collapsedSidebarInstances, <String>{'gone', 'p1'});
    });
  });

  group('instanceMailboxesExpanded', () {
    /// 一括开关开着、这台没被单独收起 —— 展开。
    test('默认展开', () {
      expect(
        instanceMailboxesExpanded(
          master: true,
          forced: false,
          collapsed: <String>{},
          profileId: 'p1',
        ),
        isTrue,
      );
    });

    test('一括关掉 → 全部收起', () {
      expect(
        instanceMailboxesExpanded(
          master: false,
          forced: false,
          collapsed: <String>{},
          profileId: 'p1',
        ),
        isFalse,
      );
    });

    /// 单独收起只影响那一台。
    test('单独收起的那台是收起的，别的台不受影响', () {
      bool at(String id) => instanceMailboxesExpanded(
            master: true,
            forced: false,
            collapsed: <String>{'p1'},
            profileId: id,
          );
      expect(at('p1'), isFalse);
      expect(at('p2'), isTrue);
    });

    /// `forced` **优先于** `collapsed`：地址正落在这台实例上时，那一行本身
    /// 必须是看得见的，否则「高亮的那一行」这个说法就不成立。这条与
    /// 原来那句 `expanded = global || pinned != null` 是同一条理由。
    test('地址落在这台上时，单独收起也不算数', () {
      expect(
        instanceMailboxesExpanded(
          master: true,
          forced: true,
          collapsed: <String>{'p1'},
          profileId: 'p1',
        ),
        isTrue,
      );
      expect(
        instanceMailboxesExpanded(
          master: false,
          forced: true,
          collapsed: <String>{'p1'},
          profileId: 'p1',
        ),
        isTrue,
      );
    });
  });

  group('MailListQuery 值语义', () {
    test('邮箱集合不同 → 不相等（Riverpod family 靠它区分）', () {
      const a = <MailboxFilter>[MailboxFilter(profileId: 'A', accountId: 1)];
      const b = <MailboxFilter>[MailboxFilter(profileId: 'A', accountId: 2)];
      expect(
        MailListQuery(mailboxes: a) == MailListQuery(mailboxes: b),
        isFalse,
      );
      expect(
        MailListQuery(mailboxes: a) == MailListQuery(mailboxes: a),
        isTrue,
      );
    });

    test('顺序不参与比较', () {
      const x = MailboxFilter(profileId: 'A', accountId: 1);
      const y = MailboxFilter(profileId: 'B', accountId: 3);
      expect(
        MailListQuery(mailboxes: const <MailboxFilter>[x, y]) ==
            MailListQuery(mailboxes: const <MailboxFilter>[y, x]),
        isTrue,
      );
    });

    test('unreadOnly 参与比较', () {
      expect(
        MailListQuery(unreadOnly: true) == MailListQuery(),
        isFalse,
      );
    });

    test('profileIds 是去重后的实例表', () {
      const q = MailListQuery(mailboxes: <MailboxFilter>[
        MailboxFilter(profileId: 'A', accountId: 1),
        MailboxFilter(profileId: 'A', accountId: 2),
        MailboxFilter(profileId: 'B', accountId: 3),
      ]);
      expect(q.profileIds, const <String>['A', 'B']);
    });

    test('空集合 = 全部', () {
      const q = MailListQuery();
      expect(q.allMailboxes, isTrue);
      expect(q.profileIds, isEmpty);
    });
  });
}
