import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/suggest/mail_action.dart';

void main() {
  String promptOf(List<String> pool) => AiPrompts.suggest(
        input: '主题：上线时间\n正文：请问下周的会议时间定了吗？',
        actionIds: pool,
      );

  test('每个池子里的 id 都出现在 prompt 里，各占一行', () {
    final prompt = promptOf(const <String>['reply', 'none', 'delete']);
    expect(prompt, contains('\n- reply：'));
    expect(prompt, contains('\n- none：'));
    expect(prompt, contains('\n- delete：'));
  });

  test('池子里没有的 id 一个字都不出现（不能给模型看见不存在的动作）', () {
    final prompt = promptOf(const <String>['none']);
    expect(prompt, isNot(contains('- reply：')));
    expect(prompt, isNot(contains('- star：')));
  });

  test('要求输出那个固定形状的 JSON 键名', () {
    // **池子必须同时含 `reply` 与 `forward`** —— `"replyDraft"` / `"forwardNote"`
    // 两个键是**按池子决定要不要画进形状那行**的（`wantsReply` / `wantsForward`），
    // 池子里没有 `forward` 时那句 `"forwardNote"` 本来就不该出现。只传 `['reply']`
    // 再断言两个键都在，是一条**自相矛盾**的用例。
    final prompt = promptOf(const <String>['reply', 'forward']);
    expect(prompt, contains('"summary"'));
    // `points` 是 spec §3.1 新增的那一项（关键要点数组），解析器认得它，
    // prompt 里少了它模型就只会给一句概述。
    expect(prompt, contains('"points"'));
    expect(prompt, contains('"actions"'));
    expect(prompt, contains('"action"'));
    expect(prompt, contains('"reason"'));
    expect(prompt, contains('"replyDraft"'));
    expect(prompt, contains('"forwardNote"'));
  });

  test('池子里没有 reply / forward 时，形状那行也就不提那两个键', () {
    // 这条与上一条是同一个事实的另一半：形状随池子变。
    final prompt = promptOf(const <String>['none', 'delete']);
    expect(prompt, isNot(contains('"replyDraft"')));
    expect(prompt, isNot(contains('"forwardNote"')));
  });

  test('**数组顺序就是优先级**那句必须在（不允许模型另给排序数字）', () {
    expect(promptOf(const <String>['none']), contains('最推荐的放第一个'));
    expect(promptOf(const <String>['none']), isNot(contains('priority')));
  });

  test('正文原样带进去', () {
    expect(promptOf(const <String>['none']),
        contains('请问下周的会议时间定了吗？'));
  });

  test('池子为空也不会拼出半截句子（工程上不该发生，但不许崩）', () {
    final prompt = AiPrompts.suggest(input: '正文', actionIds: const <String>[]);
    expect(prompt, contains('正文'));
  });

  test('池子里没有 `none` 时，不再叫模型「不用处理就写 none」', () {
    // 真实链路上 `suggestActionPool` 永远含 `none`，所以这条用例传的是一份
    // **构造出来的**池子 —— 它钉住的是「那句话跟着池子走」这个性质，而不是
    // 提示某条真实路径。池子里没有 `none` 还叫模型输出 `none`，等于让它写出
    // 一个列表里根本没有的动作：解析器会当没看见，那一句纯是噪音。
    final prompt = promptOf(const <String>['reply', 'delete']);
    expect(prompt, isNot(contains('就把 `none` 放进')));
    // 后半句是**无条件**的硬约束，池子怎么变都不能少。
    expect(prompt, contains('不要为了凑数'));
  });

  // 这张表（`_suggestActionLines`）是把动作语义**第二次**列出来的地方，
  // 而它与 `MailAction` 之间没有任何编译期约束：新增一个动作、忘了往表里
  // 加一行，`?? '- $id：'` 会静静地把那个动作降级成一行没有解释的裸 id
  // —— prompt 质量掉了，却一个错都不报。A1 那边是穷举 `switch`，加值就
  // 编译不过；这里只能靠这条用例把同样的性质钉住。
  test('表与 MailAction 一一对应，且每一行都有语义（不是裸 id 回退）', () {
    final ids = MailAction.values.map((action) => action.id).toList();
    final prompt =
        AiPrompts.suggest(input: '正文', actionIds: ids);
    for (final id in ids) {
      final bare = '- $id：';
      final row = prompt
          .split('\n')
          .where((line) => line.startsWith(bare))
          .toList();
      expect(row, hasLength(1), reason: '$id 在 prompt 里出现了 ${row.length} 次');
      expect(
        row.single.length,
        greaterThan(bare.length),
        reason: '$id 在 _suggestActionLines 里缺一行（回退成了没有语义的裸 id）',
      );
    }
  });

  // spec §3.1 / §3.2：摘要从「一句话说明要你做什么」升级成「概述 + 关键
  // 要点」，而且颗粒度按**喂进 prompt 的输入长度**分三档。分档是 prompt 的
  // 行为，不是 UI 的事 —— 这里不钉住的话，「长信和短信给一样的摘要」这个
  // 原始抱怨会悄悄回潮。
  group('摘要按输入长度分三档（spec §3.2）', () {
    String promptOfLength(int chars) => AiPrompts.suggest(
          input: '甲' * chars,
          actionIds: const <String>['none'],
        );

    test('`summary` 与 `points` 的语义写清楚了（概述不是复述，没要点给空数组）', () {
      final prompt = promptOfLength(100);
      expect(prompt, contains('`summary` 是**概述**'));
      expect(prompt, contains('`points` 是关键要点数组'));
      expect(prompt, contains('空数组'));
    });

    test('短信（<600 字）：1–2 句摘要 + 0–2 条要点', () {
      final prompt = promptOfLength(100);
      expect(prompt, contains('这封信很短'));
      expect(prompt, contains('1–2 句'));
      expect(prompt, contains('0–2 条'));
      // 三档互斥：短信 prompt 里不该出现中/长档的指标。
      expect(prompt, isNot(contains('2–3 句')));
      expect(prompt, isNot(contains('2–4 句')));
      expect(prompt, isNot(contains('2–5 条')));
    });

    test('中等（600–2000 字）：2–3 句摘要 + 1–3 条要点', () {
      final prompt = promptOfLength(1200);
      expect(prompt, contains('这封信长度中等'));
      expect(prompt, contains('2–3 句'));
      expect(prompt, contains('1–3 条'));
      expect(prompt, isNot(contains('1–2 句')));
      expect(prompt, isNot(contains('0–2 条')));
      expect(prompt, isNot(contains('2–4 句')));
      expect(prompt, isNot(contains('2–5 条')));
    });

    test('长信（>2000 字）：2–4 句概述 + 2–5 条要点，覆盖要求/事实/期限/附件', () {
      final prompt = promptOfLength(5000);
      expect(prompt, contains('这封信很长'));
      expect(prompt, contains('2–4 句'));
      expect(prompt, contains('2–5 条'));
      // 长信要点要覆盖的四类里最容易漏的两类：期限与附件用途。
      expect(prompt, contains('期限'));
      expect(prompt, contains('附件要你做什么'));
      expect(prompt, isNot(contains('1–2 句')));
      expect(prompt, isNot(contains('2–3 句')));
    });

    test('边界归哪一档：599 短、600/2000 中等、2001 长', () {
      expect(promptOfLength(599), contains('这封信很短'));
      expect(promptOfLength(600), contains('这封信长度中等'));
      expect(promptOfLength(2000), contains('这封信长度中等'));
      expect(promptOfLength(2001), contains('这封信很长'));
    });
  });
}
