import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/recipient_selection.dart';

/// 多选模型与粘贴拆分器的**纯逻辑**测试。
///
/// 为什么不放进控件测试里：这两段代码的 bug 都长一个样 —— 「边界差一格」。
/// 在控件里它只表现为「chip 颜色不对」，而一条断言 `indices == [1, 2]`
/// 能直接指出是哪一格错。控件测试（`recipient_input_test.dart`）只负责
/// 验「手势真的接到了模型上」。
void main() {
  group('RecipientSelection 基本状态', () {
    test('一开始是空的', () {
      final s = RecipientSelection();
      expect(s.isEmpty, isTrue);
      expect(s.isNotEmpty, isFalse);
      expect(s.length, 0);
      expect(s.indices, isEmpty);
      expect(s.anchor, isNull);
      expect(s.contains(0), isFalse);
      expect(s.addressesFrom(<String>['a@x.com']), isEmpty);
    });

    test('单击选一个，锚点跟着落过去', () {
      final s = RecipientSelection()..selectSingle(1);
      expect(s.indices, <int>[1]);
      expect(s.anchor, 1);
      expect(s.contains(1), isTrue);
      expect(s.contains(0), isFalse);
    });

    test('⌘ 点切换：加得上、也去得掉', () {
      final s = RecipientSelection()..selectSingle(0);
      s.toggle(2);
      expect(s.indices, <int>[0, 2]);
      s.toggle(0);
      expect(s.indices, <int>[2]);
      // 取消之后活动端落在刚取消的那一格上，下一次 Shift+点击从这里量。
      expect(s.anchor, 0);
      s.toggle(2);
      expect(s.isEmpty, isTrue);
      expect(s.anchor, isNull);
    });

    test('⌘A 全选；空列表上全选 = 空', () {
      final s = RecipientSelection()..selectAll(3);
      expect(s.indices, <int>[0, 1, 2]);
      expect(s.length, 3);
      s.selectAll(0);
      expect(s.isEmpty, isTrue);
    });

    test('地址按下标升序输出（复制出去那一串要与视觉顺序一致）', () {
      final s = RecipientSelection()..selectSingle(2);
      s.toggle(0);
      expect(
        s.addressesFrom(<String>['a@x.com', 'b@x.com', 'c@x.com']),
        <String>['a@x.com', 'c@x.com'],
      );
    });
  });

  group('← / → 的边界', () {
    test('空选区按 ←：选最后一个；再按往左扩', () {
      final s = RecipientSelection();
      expect(s.arrowLeft(3), isTrue);
      expect(s.indices, <int>[2], reason: '第一下只是「选中最后一个」，不是扩');
      expect(s.arrowLeft(3), isTrue);
      expect(s.indices, <int>[1, 2]);
      expect(s.arrowLeft(3), isTrue);
      expect(s.indices, <int>[0, 1, 2]);
      expect(s.arrowLeft(3), isFalse, reason: '顶到最左边之后不再有变化');
      expect(s.indices, <int>[0, 1, 2]);
    });

    test('→ 是收缩：一格一格往回缩，缩完再按一次就取消', () {
      final s = RecipientSelection();
      s.arrowLeft(3); // [2]
      s.arrowLeft(3); // [1,2]
      expect(s.arrowRight(3), isTrue);
      expect(s.indices, <int>[2]);
      expect(s.arrowRight(3), isTrue);
      expect(
        s.isEmpty,
        isTrue,
        reason:
            '只剩一个时再按 → 应该「什么都没选」，'
            '而不是卡在一个选中的 chip 上（否则接下来的退格会删掉它）',
      );
      // 取消之后再按没有东西可缩。
      expect(s.arrowRight(3), isFalse);
    });

    test('Shift+点击向右扩之后再按 → 是继续扩', () {
      final s = RecipientSelection()..selectSingle(0);
      s.extendTo(2);
      expect(s.indices, <int>[0, 1, 2]);
      expect(s.arrowRight(5), isTrue, reason: '活动端在右边，→ 往右扩');
      expect(s.indices, <int>[0, 1, 2, 3]);
      expect(s.arrowLeft(5), isTrue, reason: '← 把活动端收回来');
      expect(s.indices, <int>[0, 1, 2]);
    });

    test('空列表上方向键什么都不做', () {
      final s = RecipientSelection();
      expect(s.arrowLeft(0), isFalse);
      expect(s.arrowRight(0), isFalse);
      expect(s.isEmpty, isTrue);
    });
  });

  group('Shift+点击的范围', () {
    test('锚点到落点之间的闭区间，两个方向都成立', () {
      final s = RecipientSelection()..selectSingle(2);
      s.extendTo(0);
      expect(s.indices, <int>[0, 1, 2]);
      s.extendTo(3);
      expect(s.indices, <int>[2, 3]);
      expect(s.anchor, 2, reason: '锚点始终不动，只有活动端跟着鼠标走');
    });

    test('没有锚点（比如先在空白处点掉了选择）时退化成单击', () {
      final s = RecipientSelection()..extendTo(2);
      expect(s.indices, <int>[2]);
      expect(s.anchor, 2);
    });
  });

  group('reconcile：列表变了之后把下标夹回来', () {
    test('删掉中间那个 chip 之后，越界的高亮不会指向别人', () {
      // 原来选中下标 1、2（b、c）；现在列表只剩 a、b（c 被删）。
      final s = RecipientSelection()..selectSingle(1);
      s.extendTo(2);
      s.reconcile(2);
      expect(s.indices, <int>[1], reason: '下标 2 已经不存在，必须被扔掉');
    });

    test('列表整体变短：锚点与活动端一起夹回去', () {
      final s = RecipientSelection()..selectAll(4);
      s.reconcile(1);
      expect(s.indices, <int>[0]);
      expect(s.anchor, 0);
    });

    test('列表被清空：选择也归零', () {
      final s = RecipientSelection()..selectAll(2);
      s.reconcile(0);
      expect(s.isEmpty, isTrue);
      expect(s.anchor, isNull);
    });
  });

  group('splitRecipientInput：粘贴/输入时拆地址', () {
    test('没有分隔符：原样留在输入框', () {
      final r = splitRecipientInput('zhang');
      expect(r.accepted, isEmpty);
      expect(r.remainder, 'zhang');
    });

    test('逗号结尾：收下，输入框清空', () {
      final r = splitRecipientInput('a@x.com,');
      expect(r.accepted, <String>['a@x.com']);
      expect(r.remainder, '');
    });

    test('一长串：前面的收下，尾部半截留着', () {
      final r = splitRecipientInput('a@x.com, b@y.com, c@z');
      expect(r.accepted, <String>['a@x.com', 'b@y.com']);
      expect(r.remainder, 'c@z');
    });

    test('末尾带分隔符的一长串：全部收下', () {
      final r = splitRecipientInput('a@x.com, b@y.com,');
      expect(r.accepted, <String>['a@x.com', 'b@y.com']);
      expect(r.remainder, '');
    });

    test('完整地址后的空格也是边界（复制一行地址的常见形状）', () {
      final r = splitRecipientInput('a@x.com b@y');
      expect(r.accepted, <String>['a@x.com']);
      expect(r.remainder, 'b@y');
    });

    test('半截文字后面的空格不是边界（打名字时会有空格）', () {
      final r = splitRecipientInput('zhang ');
      expect(r.accepted, isEmpty);
      expect(r.remainder, 'zhang ');
    });

    test('前面那截不是地址时整串不动 —— 绝不能把写错的地址吃掉', () {
      final r = splitRecipientInput('abc, a@x.com');
      expect(r.accepted, isEmpty);
      expect(r.remainder, 'abc, a@x.com');
    });

    test('中文分隔符：，、、都认', () {
      final r = splitRecipientInput('a@x.com，b@y.com、');
      expect(r.accepted, <String>['a@x.com', 'b@y.com']);
      expect(r.remainder, '');
    });

    test('换行（多行剪贴板）也认', () {
      final r = splitRecipientInput('a@x.com\nb@y.com\n');
      expect(r.accepted, <String>['a@x.com', 'b@y.com']);
      expect(r.remainder, '');
    });

    test('连着的分隔符会跳过空段', () {
      final r = splitRecipientInput('a@x.com,, b@y.com,');
      expect(r.accepted, <String>['a@x.com', 'b@y.com']);
      expect(r.remainder, '');
    });

    test('空串：没得拆', () {
      final r = splitRecipientInput('');
      expect(r.accepted, isEmpty);
      expect(r.remainder, '');
    });
  });
}
