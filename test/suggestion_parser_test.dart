import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/suggest/mail_action.dart';
import 'package:mail_app/features/suggest/suggestion.dart';

/// 全量池子（只有过滤掉的才不算）。
const _all = MailAction.values;

void main() {
  Suggestion suggestionOf(SuggestionParseResult result) {
    expect(result, isA<SuggestionParsed>(),
        reason: '期望读出了东西，实际是完全失败');
    return (result as SuggestionParsed).suggestion;
  }

  group('干净 JSON', () {
    const raw = '''
{"summary":"对方问了三个问题","actions":[
  {"action":"reply","reason":"都在等你确认"},
  {"action":"remind","reason":"周五之前回就行"}
],"replyDraft":"你好，\\n\\n关于上线时间：","forwardNote":"转给运维组"}''';

    test('顺序就是数组顺序，reason 原样带出来', () {
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.summary, '对方问了三个问题');
      expect(s.choices.map((c) => c.action),
          <MailAction>[MailAction.reply, MailAction.remind]);
      expect(s.choices.first.reason, '都在等你确认');
    });

    test('replyDraft 只挂在 reply 那一项上', () {
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices[0].replyDraft, '你好，\n\n关于上线时间：');
      expect(s.choices[1].replyDraft, isNull);
    });

    test('forwardNote 只挂在 forward 那一项上（这份没有 forward，就不挂）', () {
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.every((c) => c.forwardNote == null), isTrue);
    });

    test('包了 ```json 围栏也认', () {
      final fenced = '```json\n$raw\n```';
      final s = suggestionOf(SuggestionParser.parse(raw: fenced, pool: _all));
      expect(s.choices, hasLength(2));
    });

    test('围栏去掉之后前后还有废话也认', () {
      final noisy = '好的，这是分析结果：\n\n$raw\n\n希望有帮助。';
      expect(suggestionOf(SuggestionParser.parse(raw: noisy, pool: _all)).choices,
          hasLength(2));
    });
  });

  group('配平大括号要跳过字符串里的花括号', () {
    test('reason 里的 {name} 不会把计数提前归零', () {
      const raw = '{"summary":"s","actions":'
          '[{"action":"reply","reason":"用 {name} 替换掉 {value} 就行"}]}'
          '\n\n后面还有一堆解释文字';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.reason, '用 {name} 替换掉 {value} 就行');
    });

    test('字符串里的转义引号也不提前结束字符串', () {
      const raw = r'{"summary":"他说 \"行\"","actions":'
          r'[{"action":"reply","reason":"他说 \"行\" {x}"}]}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.reason, '他说 "行" {x}');
    });

    test('回话被截断（没有配平的 }）→ 走降级扫描而不是整体崩掉', () {
      const raw = '{"summary":"对方问了上线时间","actions":[{"action":"reply",';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.action, MailAction.reply);
    });
  });

  group('逐项校验', () {
    test('白名单外的 id 整项丢掉，不猜', () {
      const raw = '{"actions":[{"action":"archive","reason":"归档到项目文件夹"},'
          '{"action":"reply","reason":"回一下"}]}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.map((c) => c.action), <MailAction>[MailAction.reply]);
    });

    test('被当前状态过滤掉的 id 也丢掉（池子里没有就是没有）', () {
      const raw = '{"actions":[{"action":"star","reason":"加个星"},'
          '{"action":"none","reason":""}]}';
      final s = suggestionOf(SuggestionParser.parse(
        raw: raw,
        pool: const <MailAction>[MailAction.none, MailAction.delete],
      ));
      expect(s.choices.map((c) => c.action), <MailAction>[MailAction.none]);
    });

    test('同一个 id 重复出现只留第一次', () {
      const raw = '{"actions":[{"action":"reply","reason":"第一次"},'
          '{"action":"reply","reason":"第二次"},{"action":"none","reason":""}]}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.map((c) => c.action),
          <MailAction>[MailAction.reply, MailAction.none]);
      expect(s.choices.first.reason, '第一次');
    });

    test('reason 超过 200 字截断', () {
      final long = '字' * 500;
      final raw = '{"actions":[{"action":"reply","reason":"$long"}]}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.reason.length, SuggestionParser.maxReasonLength);
    });

    test('缺 reason 时是空串，不是 null', () {
      const raw = '{"actions":[{"action":"reply"}]}';
      expect(suggestionOf(SuggestionParser.parse(raw: raw, pool: _all))
          .choices.single.reason, '');
    });

    test('reason 不是字符串（模型给成数字）时也当空串，不崩', () {
      const raw = '{"actions":[{"action":"reply","reason":123}]}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.reason, '');
    });

    test('一万个未配平的花括号不卡死（配平扫描是线性的，找不到就退回扫描路）', () {
      final raw = '{"a":' * 10000 + '还没写完';
      final result = SuggestionParser.parse(raw: raw, pool: _all);
      // 没有 `actions` 数组、没有动作名、没有草稿 ⇒ 失败态（不兜底）
      expect(result, isA<SuggestionUnreadable>());
    });

    test('真 JSON 前面先复述了一个带花括号的模板 → 认得出真 JSON', () {
      const raw = '模板是 "{x}"，分析结果：'
          '{"summary":"s","actions":[{"action":"reply","reason":"回一下"}]}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.action, MailAction.reply);
      expect(s.choices.single.reason, '回一下');
    });

    test('散文里的孤立引号不该把起点甩到后面去（那种 `"` 只要一个）', () {
      // 这一句里 `"` 只有一个，`_objectStart` 认它不配对，于是退回「第一个 `{`」。
      const raw = '他说"行 然后给了：{"actions":[{"action":"reply"}]}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.action, MailAction.reply);
    });
  });

  group('降级扫描（JSON 已经成功时也跑）', () {
    test('模型把动作名写在了 JSON 外面', () {
      const raw = '{"summary":"s","actions":[]}\n\nreply —— 对方在等你确认\n'
          'remind —— 周末再说';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.map((c) => c.action),
          <MailAction>[MailAction.reply, MailAction.remind]);
      expect(s.choices.first.reason, '对方在等你确认');
    });

    test('JSON 写坏了但行里能认出 id', () {
      const raw = '{"actions":[{"action":"reply","reason":"好}\n'
          '- delete 广告信\n- none 纯通知';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.map((c) => c.action),
          <MailAction>[MailAction.reply, MailAction.delete, MailAction.none]);
    });

    test('扫描也去重，同一个 id 出现两次只留第一次', () {
      const raw = 'reply —— 第一次\n别的废话\nreply —— 第二次';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices, hasLength(1));
      expect(s.choices.single.reason, '第一次');
    });

    test('从坏 JSON 里捞 replyDraft（reply 在池子里）', () {
      const raw = '{"actions":[{"action":"repl\n'
          '"replyDraft": "你好，\\n\\n确认一下时间。"';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.action, MailAction.reply);
      expect(s.choices.single.replyDraft, '你好，\n\n确认一下时间。');
    });

    test('reply 不在池子里时，整段 draft 一个字都不捞', () {
      const raw = '全是废话，没有动作名。\n"replyDraft": "你好，确认一下。"';
      final result = SuggestionParser.parse(
        raw: raw,
        pool: const <MailAction>[MailAction.none, MailAction.delete],
      );
      // 连 replyDraft 都不捞 ⇒ 什么都没读出来 ⇒ 完全失败（不是兜底成 none）
      expect(result, isA<SuggestionUnreadable>());
    });

    test('降级路只捞 replyDraft，不捞 forwardNote', () {
      const raw = '说了一堆话但没有任何动作名。\n"forwardNote": "转给运维"';
      // 只有 forwardNote / 没有动作名 / 没有 draft ⇒ 什么都没读出来
      expect(SuggestionParser.parse(raw: raw, pool: _all),
          isA<SuggestionUnreadable>());
    });

    test('词边界：in_replyDraft 里的 reply 不算一次命中', () {
      const raw = '这里只提到了 in_replyDraft 这个字段名，没有别的。';
      expect(SuggestionParser.parse(raw: raw, pool: _all),
          isA<SuggestionUnreadable>());
    });
  });

  group('兜底：永远至少一项（spec §3.4）', () {
    test('JSON 成功但没有一项过白名单，有 draft → 补 reply（reason 空串）', () {
      const raw = '{"actions":[{"action":"archive"}],'
          '"replyDraft":"你好，确认一下时间。"}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.action, MailAction.reply);
      expect(s.choices.single.reason, '');
      expect(s.choices.single.replyDraft, '你好，确认一下时间。');
    });

    test('JSON 成功但没有一项过白名单，也没 draft → 补 none', () {
      const raw = '{"summary":"读完了","actions":[{"action":"archive"}]}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.action, MailAction.none);
      expect(s.choices.single.reason, '');
      expect(s.summary, '读完了');
    });

    test('扫出了动作名但全被白名单挡下 → 补 none（不是失败）', () {
      const raw = 'star —— 加个星';
      final s = suggestionOf(SuggestionParser.parse(
        raw: raw,
        pool: const <MailAction>[MailAction.none],
      ));
      expect(s.choices.single.action, MailAction.none);
    });

    test('一行里两个动作名、靠前那个不在池子里 → 取**池子里**那一个', () {
      // 这条钉的是**「扫两遍」而不是「扫一遍再过滤」**。`star 或者 reply 都行`
      // 这一行里 `star` 出现得更早：只扫全量再过滤的话，这一行只留下 `star`、
      // 白名单一挡就整行丢掉，`reply` 陪着一起没了 —— 而 `reply` 是这条链路上
      // 唯一一份模型写出来的正文（`_scanActions` 的文档里也记了这笔）。
      const raw = 'star 或者 reply 都行';
      final s = suggestionOf(SuggestionParser.parse(
        raw: raw,
        pool: const <MailAction>[MailAction.reply, MailAction.none],
      ));
      expect(s.choices.map((c) => c.action), <MailAction>[MailAction.reply]);
      expect(s.choices.single.reason, contains('都行'));
    });

    test('reply 不在池子里时，draft 不会变成 reply 而落到 none', () {
      const raw = '{"actions":[],"replyDraft":"你好"}';
      final s = suggestionOf(SuggestionParser.parse(
        raw: raw,
        pool: const <MailAction>[MailAction.delete, MailAction.none],
      ));
      expect(s.choices.single.action, MailAction.none);
    });
  });

  group('完全失败：不给任何可点动作', () {
    test('一句自然语言、没有任何 id、没有 draft → SuggestionUnreadable', () {
      const raw = '我觉得这封信不用处理，你可以不管它。';
      final result = SuggestionParser.parse(raw: raw, pool: _all);
      expect(result, isA<SuggestionUnreadable>());
      // 原文要原样带出来给面板显示
      expect((result as SuggestionUnreadable).raw, raw);
    });

    test('空回话也是失败', () {
      expect(SuggestionParser.parse(raw: '   ', pool: _all),
          isA<SuggestionUnreadable>());
    });

    test('JSON 能解但既没有 actions 也没有 draft → 失败（不是「无需处理」）', () {
      const raw = '{"summary":"我不确定"}';
      expect(SuggestionParser.parse(raw: raw, pool: _all),
          isA<SuggestionUnreadable>());
    });

    test('完全失败时 raw 是**没剥过围栏**的原文（用户要看模型真正写了什么）', () {
      const raw = '```\n我没有建议。\n```';
      final result = SuggestionParser.parse(raw: raw, pool: _all);
      expect((result as SuggestionUnreadable).raw, raw);
    });
  });

  test('summary 拿不到时是空串（面板据此不画第一行）', () {
    const raw = '{"actions":[{"action":"none"}]}';
    expect(suggestionOf(SuggestionParser.parse(raw: raw, pool: _all)).summary, '');
  });

  // 这一组钉的是「扫哪儿」。`_scanActions` 拿到的不是原始回话，而是**把 JSON
  // 那段挖空之后**的文本（`parse` 里的 `scanText`）—— 因为 JSON 里的动作名
  // 是**数据**，不是「模型建议这么做」。这个区分在 `none` / `reply` 这种温和的
  // 动作上看不出差别，但在 `delete` 上就是另一回事：模型说「请不要 delete」，
  // 扫出来的却是一条**可点**的删除建议，而这个按钮真的会删信。
  group('JSON 字符串里的动作名不算建议（挖空之后才扫）', () {
    test('模型**否定**一个破坏性动作，不能把它变成一条可点建议', () {
      const raw = '{"summary":"请不要 delete 这封信，它还有用"}';
      expect(SuggestionParser.parse(raw: raw, pool: _all),
          isA<SuggestionUnreadable>());
    });

    test('否定 forward 也一样（英文里 forward 是常见的普通词）', () {
      const raw = '{"summary":"不用 forward 给任何人"}';
      expect(SuggestionParser.parse(raw: raw, pool: _all),
          isA<SuggestionUnreadable>());
    });

    test('`actions` 是空的、总结里提到过动作名 → 补 none（读出了东西，不是失败）', () {
      const raw = '{"summary":"对方只是想 reply 一下确认时间","actions":[]}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.action, MailAction.none);
    });

    test('模型写在 JSON **外面**的动作名照样扫得到（挖空没伤到降级路）', () {
      const raw = '{"summary":"看完了"}\n\nreply —— 对方在等你确认';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.map((c) => c.action), <MailAction>[MailAction.reply]);
      expect(s.choices.single.reason, '对方在等你确认');
    });

    test('JSON 里的字符串值里的动作名不算（总结里的 forward 不是建议）', () {
      const raw = '{"summary":"我会 forward 给你的","actions":[]}';
      // 挖空之后：`actions` 是个空数组 ⇒ 读出了东西 ⇒ 兜底补 none。
      // 没挖空的话这里会冒出一条**可点**的 forward —— 而模型根本没建议转发。
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.map((c) => c.action), <MailAction>[MailAction.none]);
    });

    test('回话里有**两个** JSON 对象时，后面那个也要挖空（复述格式 + 真答案）', () {
      // 模型先复述一遍格式、再给真答案。只挖第一个的话，真答案整段留在扫描路
      // 的输入里，它那句「请不要 delete」会变成一条**可点**的删除建议 ——
      // 正是挖空要挡的东西换了个形状又回来。（这里第一个对象是复述的格式，
      // 按 spec §3.2「第一个配平的对象」它被当成答案，于是读出了 `id` 不是
      // 动作、`actions` 也不是数组 ⇒ 读不出动作；后面那个真答案里又只有一句
      // 否定 delete。两边都不该给出可点动作。）
      const raw = '先看格式：{"action":"id","reason":"原因"}\n'
          '我的建议：{"summary":"请不要 delete 这封信","actions":[]}';
      final result = SuggestionParser.parse(raw: raw, pool: _all);
      expect(result, isA<SuggestionUnreadable>());
    });

    test('前一个对象能解开时，后面那个解不开也不影响前面（挖空只挖解开的）', () {
      const raw = '{"actions":[{"action":"reply","reason":"回一下"}]}\n'
          '另外，模板是 {x}，你照着填。';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.action, MailAction.reply);
      expect(s.choices.single.reason, '回一下');
    });

    test('**散文里一个未配平的 `{` 之后**的真答案也要挖空（别一遇到就收工）', () {
      // 这是上一版解析器的一个真洞（实测过）：`_jsonObjects` 一遇到配平却
      // 解不开的片段就 `break`，于是 `{"a":1}` 之后那半句模板里的 `{name}`
      // 把真答案一起圈进「配平但解不开」里，真答案一个字都没进挖空集合 ——
      // 它那句「请不要 delete」照样变成一条**可点**的删除建议。
      // 现在失败之后从**下一个 `{`** 接着起扫，真答案照挖。
      const raw = '{"a":1}\n按 {name} 模板。分析：'
          '{"summary":"请不要 delete 这封信","actions":[]}';
      expect(SuggestionParser.parse(raw: raw, pool: _all),
          isA<SuggestionUnreadable>());
    });

    test('复述的模板只开了一半、真答案紧随其后，也认得出真答案', () {
      // 同一个洞的另一种形状：模板那一行只写了 `{"action":"id"`（没闭合），
      // 于是「配平」的那一步直接从模板的 `{` 一路吃到真答案的 `}`，切出来
      // 一整段解不开的东西。跳过之后从下一个 `{`（真答案）接着起扫。
      const raw = '复述：{"action":"id"\n真答案：'
          '{"summary":"请不要 delete 这封信","actions":[{"action":"none"}]}';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.single.action, MailAction.none);
      expect(s.choices.single.reason, '');
    });
  });

  // spec §3.4 只管「动作列表是空的」那种兜底，没说「扫出来的全是别的动作、
  // 可模型已经写好一整封回信」该怎么办。我们的答案是**补一项 reply 放最前面**：
  // 草稿是这条链路上唯一一份「模型直接写出来的正文」，丢掉它比多给一个选项
  // 代价大得多；放最前面是因为肯写整封信，说明回信就是它最想说的那件事。
  group('有草稿就一定要有 reply 承载它', () {
    test('JSON 里 actions 空、外面扫到一个 delete → reply 在前、草稿挂上', () {
      const raw = '{"actions":[],"replyDraft":"这是草稿"}\ndelete —— 广告';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.map((c) => c.action),
          <MailAction>[MailAction.reply, MailAction.delete]);
      expect(s.choices.first.replyDraft, '这是草稿');
      expect(s.choices.last.replyDraft, isNull);
    });

    test('已经有 reply 了就不重复补（顺序仍是模型给的）', () {
      const raw = '{"actions":[],"replyDraft":"这是草稿"}\n'
          'delete —— 广告\nreply —— 回一下';
      final s = suggestionOf(SuggestionParser.parse(raw: raw, pool: _all));
      expect(s.choices.map((c) => c.action),
          <MailAction>[MailAction.delete, MailAction.reply]);
      expect(s.choices.last.replyDraft, '这是草稿');
    });

    test('`reply` 不在池子里时一个字都不补（草稿只能落到 none / 别的动作）', () {
      const raw = '{"actions":[],"replyDraft":"这是草稿"}\ndelete —— 广告';
      final s = suggestionOf(SuggestionParser.parse(
        raw: raw,
        pool: const <MailAction>[MailAction.delete, MailAction.none],
      ));
      expect(s.choices.map((c) => c.action), <MailAction>[MailAction.delete]);
      expect(s.choices.single.replyDraft, isNull);
    });
  });
}
