import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/features/mail_list/mail_selection.dart';

/// `MailSelection` 是纯值对象，这里全部脱离 widget 测。
///
/// 重点只有一条：**「已选 N 封」这个数字与按钮真正作用的对象是同一个集合**。
/// 拖动带越界、列表中途变短、外加几格勾选，都要能算出一个不重不漏的下标表。

MailRef ref(int emailId) => MailRef(profileId: 'p1', emailId: emailId);

/// 一个列表的 refs（下标 i 就是 emailId = i 的那封）。
List<MailRef> list(int count) => <MailRef>[for (var i = 0; i < count; i++) ref(i)];

void main() {
  group('positions：cells 路径', () {
    test('空选择什么都不选', () {
      expect(MailSelection.empty.positions(10), isEmpty);
      expect(MailSelection.empty.isActive, isFalse);
    });

    test('逐个勾选：升序、不重复', () {
      const selection = MailSelection(cells: <int>{7, 1, 3});
      expect(selection.positions(10), <int>[1, 3, 7]);
    });

    test('越界的下标被丢掉（列表变短了）', () {
      const selection = MailSelection(cells: <int>{1, 9});
      expect(selection.positions(3), <int>[1]);
    });

    test('列表空了就什么都不选', () {
      const selection = MailSelection(cells: <int>{0});
      expect(selection.positions(0), isEmpty);
    });
  });

  group('positions：拖动带', () {
    test('常见区间：起 2 长 3', () {
      const selection = MailSelection(bandStart: 2, bandLength: 3);
      expect(selection.positions(10), <int>[2, 3, 4]);
    });

    test('越过末尾 → 整体退回最后 k 行（不是把尾巴压平）', () {
      const selection = MailSelection(bandStart: 8, bandLength: 4);
      // 8+4 > 10，于是这一段是 [6, 10) —— **仍然是 4 行**。
      expect(selection.positions(10), <int>[6, 7, 8, 9]);
    });

    test('带子比列表还长：不多算一格、不重复', () {
      const selection = MailSelection(bandStart: 1, bandLength: 99);
      expect(selection.positions(5), <int>[0, 1, 2, 3, 4]);
    });

    test('列表变短：这一段跟着缩到新的行数，且不含越界项', () {
      const selection = MailSelection(bandStart: 3, bandLength: 5);
      expect(selection.positions(12), <int>[3, 4, 5, 6, 7]);
      // 同步进来一批之前是 12 行，之后只剩 4 行（切了筛选 / 删了一批）。
      expect(selection.positions(4), <int>[0, 1, 2, 3]);
    });

    test('cells 与 band 一起算进去，两份不重复', () {
      const selection = MailSelection(
        cells: <int>{9},
        bandStart: 1,
        bandLength: 2,
      );
      expect(selection.positions(10), <int>[1, 2, 9]);
    });
  });

  group('变换', () {
    test('toggle：加一个 / 减一个', () {
      const selection = MailSelection();
      final one = selection.toggle(3);
      expect(one.positions(10), <int>[3]);
      expect(one.isActive, isTrue);
      final none = one.toggle(3);
      expect(none.isActive, isFalse, reason: '减到空 = 退出多选');
    });

    test('toggle 不改原对象', () {
      const selection = MailSelection(cells: <int>{1});
      selection.toggle(2);
      expect(selection.positions(10), <int>[1]);
    });

    test('only：把选择换成一行，并默认带上新锚点', () {
      const selection = MailSelection(cells: <int>{1, 2}, anchor: null);
      final next = selection.only(5, anchor: ref(5));
      expect(next.positions(10), <int>[5]);
      expect(next.anchor, ref(5));
    });

    test('only(clearAnchor: false) 保留旧锚点（勾选不该动 Shift 的起点）', () {
      const selection = MailSelection(cells: <int>{1}, anchor: null);
      final withAnchor = selection.only(1, anchor: ref(1));
      final again = withAnchor.only(2);
      expect(again.anchor, ref(1));
    });

    test('all：全选本页', () {
      expect(const MailSelection().all(3).positions(3), <int>[0, 1, 2]);
      expect(const MailSelection().all(0).isActive, isFalse);
    });

    test('extendTo：从锚点到这一行（往前也行）', () {
      final initial = MailSelection(cells: const <int>{4}, anchor: ref(4));
      expect(initial.extendTo(7, list(10)).positions(10), <int>[4, 5, 6, 7]);
      expect(initial.extendTo(2, list(10)).positions(10), <int>[2, 3, 4]);
    });

    test('extendTo：锚点解析不出来 → 退回只选这一行并改锚点', () {
      final selection = MailSelection(cells: const <int>{0}, anchor: ref(99));
      final next = selection.extendTo(3, list(10));
      expect(next.positions(10), <int>[3]);
      expect(next.anchor, ref(3));
    });

    test('extendTo：没有锚点 → 同上', () {
      final next = const MailSelection().extendTo(3, list(10));
      expect(next.positions(10), <int>[3]);
      expect(next.anchor, ref(3));
    });

    test('beginBand / bandAt：起一条带子', () {
      final band = const MailSelection().beginBand(2, anchor: ref(2));
      expect(band.positions(10), <int>[2]);
      expect(band.isActive, isTrue);
      final grown = band.bandAt(1, 4);
      expect(grown.positions(10), <int>[1, 2, 3, 4]);
    });

    test('bandAt(length: 0)：退出多选（拖回原点也算）', () {
      final band = const MailSelection().bandAt(2, 0);
      expect(band.isActive, isFalse);
    });

    test('commitBand：折成集合，带子不再跟着走', () {
      const band = MailSelection(bandStart: 2, bandLength: 3);
      final committed = band.commitBand(10);
      expect(committed.cells, <int>{2, 3, 4});
      expect(committed.bandLength, 0);
      // 折过之后列表变短，剩下的那几格仍然在（而不是整段重算）。
      expect(committed.positions(3), <int>[2]);
    });

    test('normalize：清掉越界项', () {
      const selection = MailSelection(cells: <int>{1, 9});
      expect(selection.normalize(3).cells, <int>{1});
    });
  });

  group('refsOf', () {
    test('按列表顺序解析出被选中的那几封', () {
      const selection = MailSelection(cells: <int>{2, 0});
      expect(selection.refsOf(list(5)), <MailRef>[ref(0), ref(2)]);
    });
  });

  group('相等性', () {
    test('cells 与列表顺序无关', () {
      const a = MailSelection(cells: <int>{1, 2, 3});
      const b = MailSelection(cells: <int>{3, 1, 2});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('scope 不同就不相等', () {
      const a = MailSelection(scope: 'all|receive|all|*');
      const b = MailSelection(scope: 'all|send|all|*');
      expect(a == b, isFalse);
    });
  });

  group('selectionScopeOf', () {
    test('四项各变一次都要换一个 scope', () {
      const base = 'all|receive|all|*';
      expect(selectionScopeOf(), base);
      expect(selectionScopeOf(listNode: 'p1'), isNot(base));
      expect(selectionScopeOf(folder: 'send'), isNot(base));
      expect(selectionScopeOf(unreadOnly: true), isNot(base));
      expect(selectionScopeOf(mailboxSet: 'p1/0'), isNot(base));
    });

    test('listNode 为 null 与 all 是同一条（聚合页的两种写法）', () {
      expect(selectionScopeOf(), selectionScopeOf(listNode: 'all'));
    });

    test('同一组输入稳定（存进状态、跨屏比较都靠它）', () {
      const a = 'all|receive|unread|p1/0,p2/0';
      expect(
        selectionScopeOf(
          folder: 'receive',
          unreadOnly: true,
          mailboxSet: 'p1/0,p2/0',
        ),
        a,
      );
    });
  });

  group('selectionAppliesTo', () {
    test('没在选 = 不接管（哪怕 scope 对得上）', () {
      expect(selectionAppliesTo(const MailSelection(scope: 'x'), 'x'), isFalse);
    });

    test('scope 对不上 = 不接管（另一块列表、另一个文件夹）', () {
      const selection = MailSelection(scope: 'x', cells: <int>{0});
      expect(selectionAppliesTo(selection, 'x'), isTrue);
      expect(selectionAppliesTo(selection, 'y'), isFalse);
    });
  });
}
