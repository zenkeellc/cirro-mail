import 'dart:convert';

import 'mail_action.dart';

/// 面板 pop 回给调用方的东西：**一个动作 + 它的参数**（spec §4.6）。
///
/// 面板只选不做，所以这个对象里没有 `BuildContext`、没有 `WidgetRef`、
/// 也没有任何「怎么执行」的痕迹。好处是面板能脱离 Riverpod 单测，而且
/// 「从列表点」与「从详情页点」走的是同一个执行器，两个入口的行为不可能分叉。
class SuggestionChoice {
  const SuggestionChoice({
    required this.action,
    this.reason = '',
    this.replyDraft,
    this.forwardNote,
  });

  final MailAction action;

  /// 模型给的理由。转发时当附言的第一行（spec §6.2 末段）。
  final String reason;

  /// 只在 [MailAction.reply] 上有值。
  final String? replyDraft;

  /// 只在 [MailAction.forward] 上有值。
  final String? forwardNote;

  @override
  String toString() =>
      'SuggestionChoice(${action.id}'
      '${reason.isEmpty ? '' : ', reason: $reason'})';
}

/// 一次分析的产出：一句话总结 + 按「该先做哪个」排好序的选项。
///
/// **顺序即优先级**（spec §3.1）：数组的第一项就是最推荐的，所以这里没有
/// 单独的 `priority` 字段 —— 让模型同时维护一个数组和一个排序数字，两者
/// 不一致时还得决定信谁，不如只留一个有顺序的东西。
class Suggestion {
  const Suggestion({this.summary = '', required this.choices});

  /// 面板顶部那一句。拿不到就是空串（面板据此不画第一行）。
  final String summary;

  /// 至少一项（兜底见 [SuggestionParser]）。
  final List<SuggestionChoice> choices;
}

/// 解析的两种结局。**「读出了东西」与「什么都没读出来」是两回事**，
/// 用类型分开而不是用一个空列表表示 —— 后者会让调用方把「无需处理」
/// 和「解析失败」混在一起（spec §3.4 末段特意说明了这个区别）。
sealed class SuggestionParseResult {
  const SuggestionParseResult();
}

/// 读出了东西（可能只是一条兜底的 `none`），面板画动作列表。
class SuggestionParsed extends SuggestionParseResult {
  const SuggestionParsed(this.suggestion);

  final Suggestion suggestion;
}

/// 什么都没读出来。面板显示 [raw] 并给「重试」，**不给任何可点动作**。
class SuggestionUnreadable extends SuggestionParseResult {
  const SuggestionUnreadable(this.raw);

  /// 模型原话，**没剥过围栏** —— 用户要能自己读出来它想说什么。
  final String raw;
}

/// 把模型的回话读成一份 [Suggestion]。纯函数。
///
/// 步骤（spec §3.2）：剥围栏 → 找第一个配平的 `{…}`（跳过字符串字面量里的
/// 花括号）→ `jsonDecode` → 逐项过 [pool] 白名单（去重、reason 截断）→
/// 空则降级扫描 → 还空则兜底补一项。
///
/// **唯一的「成不成功」判据**：模型说的话里，我们读出了任何东西吗。
/// 读出了东西、但一个动作都没捞到 → 兜底补一项（§3.4）；
/// 什么都没读出来 → [SuggestionUnreadable]，**不兜底**。
///
/// 为什么宽容到这个程度：模型的输出格式是它最不愿意遵守的一件事，而这条
/// 链路上「格式不对」的表现只是「用户看不到建议」，不是任何数据被写坏。
/// 所以宁可多认几种写法，也不要一句「解析失败」把一次已经付过钱的调用丢掉。
abstract final class SuggestionParser {
  const SuggestionParser._();

  /// reason 的上限。**面板上那是一行说明，不是正文** —— 模型偶尔会把整段
  /// 分析塞进 reason，不截的话面板会被一行字顶开。
  static const int maxReasonLength = 200;

  static SuggestionParseResult parse({
    required String raw,
    required List<MailAction> pool,
  }) {
    final text = _stripFences(raw);

    // spec §3.2 末那个判据有**两半**，这里分开记：
    //   `sawActions`    —— 回话里有一个 `actions` 数组吗（哪怕空、哪怕全被白名单挡下）；
    //   `rawScanned`    —— 回话里出现过任何动作名吗（不管白名单，下面算）。
    // 混成一个「JSON 解开了吗」会出两种错：`{"summary":"我不确定"}`（能解、
    // 但根本没有动作字段）被当成读出了东西，于是一次彻底的失败变成一条兜底的
    // `none`，用户看到「无需处理」就真的不去处理了；反过来，`star —— 加个星`
    // 配一份没有 `star` 的池子会被当成「什么都没读出来」，而 spec §3.4 说
    // 那是**兜底**。
    var sawActions = false;
    var summary = '';
    String? replyDraft;
    String? forwardNote;
    final fromJson = <SuggestionChoice>[];
    // 降级扫描要看的那一份文本：顶层那些 `{…}` 全都要挖空（理由见下面）。
    var scanText = text;

    final objects = _jsonObjects(text);
    // spec §3.2 第 2 步是「找**第一个**配平的 `{…}`」—— 不复述一句之后追认
    // 后面那个（挑起点只做一层，理由见 [_objectStart]）。这里如实照做：解出来的
    // 那一份就是第一个对象，其余对象只参与上面的「挖空」。
    final answer = objects.isEmpty ? null : objects.first;
    if (answer != null) {
      final decoded = answer.decoded;
      // **扫描只扫 JSON 外面的字。** JSON 里的字符串值也是「模型说的话」，
      // 但里面的动作名不是「它建议这么做」，有时正好相反：一句
      // `{"summary":"请不要 delete 这封信"}` 会让 `delete` 被扫成一条**可点**
      // 的建议 —— 而这个功能的按钮是真的会删信。所以解码成功之后，把 `{…}`
      // 整段挖成空白再扫（保长度、保换行，行数不变）；模型写在 JSON **外面**的
      // 动作名（降级扫描本来就要救的那种）一个字都不受影响。
      //
      // **挖的是每一个顶层对象，不止抽出来那一个。** 模型偶尔先复述一遍格式、
      // 再给真答案（`先看格式：{"action":"id",…}` 换行 `我的建议：{…}`）：只挖
      // 第一个的话，真答案那一整段 `{…}` 留在扫描路的输入里，于是
      // `{"summary":"请不要 delete 这封信"}` 又变成一条可点建议 —— 正是这条
      // 挖空要挡的东西，换了个形状又回来了。（真答案是被 [answer] 抽出来的
      // 那一个；其余对象连同这份「抽出来的」一起挖掉。）
      final buffer = StringBuffer();
      var at = 0;
      for (final object in objects) {
        buffer
          ..write(text.substring(at, object.start))
          ..write(text.substring(object.start, object.end)
              .replaceAll(RegExp(r'[^\n]'), ' '));
        at = object.end;
      }
      buffer.write(text.substring(at));
      scanText = buffer.toString();
      summary = _text(decoded['summary'])?.trim() ?? '';
      replyDraft = _nonBlank(_text(decoded['replyDraft']));
      forwardNote = _nonBlank(_text(decoded['forwardNote']));
      final items = decoded['actions'];
      if (items is List) {
        sawActions = true;
        final seen = <MailAction>{};
        for (final item in items) {
          if (item is! Map) continue;
          final action = MailAction.byId(_text(item['action']) ?? '');
          // 不认识的 id、以及被当前状态过滤掉的 id，都当没看见：
          // 模型不能凭空造一个动作去执行，也不该把「标记已读」提给一封已读信。
          if (action == null || !pool.contains(action)) continue;
          // 同一个 id 重复出现只留第一次：顺序靠前的更靠前，
          // 也更能说明模型的本意。
          if (!seen.add(action)) continue;
          fromJson.add(SuggestionChoice(
            action: action,
            reason: _truncate(_text(item['reason'])?.trim() ?? ''),
          ));
        }
      }
    }

    // 降级扫描：**JSON 成功时也跑** —— 它便宜，而且能救「模型把动作名写在了
    // JSON 外面」那种（它直接在 JSON 后面跟了一行 `reply —— 对方在等你确认`）。
    //
    // 两遍各有各的用途，**两遍都要跑，而且不能合成一遍**：
    //   `rawScanned` —— 扫**全量** `MailAction.values`，只用来判「回话里出现过
    //                   动作名吗」（不管白名单）；
    //   `scanned`    —— 扫**[pool]**，取候选。**这一遍必须直接传池子**，不能
    //                   拿 `rawScanned` 去过滤：`_scanActions` 是「每行取最先
    //                   出现的那个名字」，全量那一遍里 `star 或者 reply 都行`
    //                   取到的是 `star`，过滤之后 `reply` 就跟着没了 —— 而
    //                   `reply` 恰恰是这条链路上唯一一份模型写出来的正文。传
    //                   池子时「最先出现的」是在池子内部算的，这一行取到 `reply`。
    //   判据那一遍也不能改成扫池子：池子里没有 `star` 时 `star —— 加个星`
    //   一个字都扫不到，于是「扫出了动作名但全被白名单挡下」被误判成「什么都
    //   没读出来」，而 spec §3.4 明确说那种情况要兜底补一项、**不是**失败态。
    final rawScanned = _scanActions(scanText, MailAction.values);
    final scanned = _scanActions(scanText, pool);
    // `reply` 不在池子里时整段跳过：捞出一份没法变成任何动作的草稿没有用。
    // 同样扫 [scanText]：JSON 里的那份已经在上面直取过了。
    final scannedDraft =
        pool.contains(MailAction.reply) ? _scanReplyDraft(scanText) : null;

    // 那个唯一的判据（spec §3.2 末段）：**JSON 里有一个 `actions` 数组，
    // 或者回话里出现过动作名，或者捞到了一份草稿**。
    if (!sawActions && rawScanned.isEmpty && scannedDraft == null) {
      return SuggestionUnreadable(raw);
    }

    // 草稿 / 附言只挂在各自对应的那一项上：一封信里 `reply` 与 `forward`
    // 可能同时在候选里，两个都挂上会让「转发」也带一份回信草稿。
    final draft = replyDraft ?? scannedDraft;

    var choices = fromJson;
    if (choices.isEmpty) choices = scanned;
    // 有草稿、却没有一项 `reply` 承载它（JSON 的 `actions` 是空的、或者 JSON 外面
    // 只写了别的动作名）→ 补一项 `reply` 放**最前面**。模型肯写一整封回信，
    // 说明「回信」就是它最想说的那件事；把它排在被白名单挡剩下的那几个动作后面，
    // 等于我们替它降了级。**草稿是这条链路上唯一一份「模型直接写出来的正文」**，
    // 丢掉它比多给一个选项代价大得多。
    if (draft != null &&
        pool.contains(MailAction.reply) &&
        !choices.any((choice) => choice.action == MailAction.reply)) {
      choices = <SuggestionChoice>[
        SuggestionChoice(action: MailAction.reply, replyDraft: draft),
        ...choices,
      ];
    }

    // 兜底补一项（§3.4）：走到这里说明一个动作都没有 —— JSON 里没有、扫描没扫到、
    // 也没有草稿能变成 `reply`。**有草稿时上面那一支已经补过了**，顺序不能换。
    if (choices.isEmpty) {
      choices = const <SuggestionChoice>[
        SuggestionChoice(action: MailAction.none),
      ];
    }

    final out = <SuggestionChoice>[
      for (final choice in choices)
        SuggestionChoice(
          action: choice.action,
          reason: choice.reason,
          replyDraft: choice.replyDraft ??
              (choice.action == MailAction.reply ? draft : null),
          forwardNote:
              choice.action == MailAction.forward ? forwardNote : null,
        ),
    ];

    return SuggestionParsed(Suggestion(summary: summary, choices: out));
  }

  /// 剥掉首尾的 ```` ```json ```` / ```` ``` ````。
  ///
  /// 模型有相当比例会把 JSON 包起来，即便 prompt 里明确说了不要 —— 这一条
  /// 出现在解析步骤的第一位，就是因为它最常发生、代价最小。
  static String _stripFences(String raw) {
    var text = raw.trim();
    if (!text.startsWith('```')) return text;
    final firstNewline = text.indexOf('\n');
    text = firstNewline < 0 ? '' : text.substring(firstNewline + 1);
    final lastFence = text.lastIndexOf('```');
    if (lastFence >= 0) text = text.substring(0, lastFence);
    return text.trim();
  }

  /// 找那个 `{`：优先**不在引号里**的第一个，找不到再退回第一个 `{`。
  ///
  /// 为什么要挑：模型有时先复述一句 `模板是 "{x}"，结果是：{…}`，第一个 `{`
  /// 落在引号里、跟着的那个 `}` 也在引号里 —— 从它起步切出来的是 `"{x}"` 中间
  /// 那一小截（`{x}`），解出来不是合法的对象，于是真 JSON 整段被当成「写坏了」，
  /// 悄悄退到扫描路。挑过一次就够了：**只挑起点、不做「多试几个起点直到解开」**
  /// —— 后者在回话里有一万个未配平花括号时是平方级的。
  ///
  /// 引号在两段之间的普通散文里不配对（`他说"你好` 只有一个），所以「不在引号里」
  /// 只在一个 `"` 后面还跟着另一个 `"` 时才认；否则整段退化成「第一个 `{`」。
  ///
  /// [from] 是搜索起点（含），默认 0 —— [SuggestionParser._jsonObjects] 找下一个
  /// 对象时从上一个的 `end` 接着扫，不需要把前面那段重扫一遍。
  static int _objectStart(String text, [int from = 0]) {
    var quote = -1;
    for (var i = from; i < text.length; i++) {
      final ch = text[i];
      if (ch == '"') {
        // 只看「`"` 后面还有没有配对的 `"`」——有才认这一段在引号里。
        final next = text.indexOf('"', i + 1);
        if (next < 0) break;
        i = next;
        continue;
      }
      if (ch == '{') {
        quote = i;
        break;
      }
    }
    return quote >= 0 ? quote : text.indexOf('{', from);
  }

  /// 找**所有**顶层、配平、且能解成 `Map` 的 `{…}`，按出现顺序，各带自己的区间。
  ///
  /// 为什么要「所有」而不是「第一个」（spec §3.2 第 2 步只说了第一个）：
  /// 第一个用来**抽答案**，其余的也要一起交给调用方 —— 挖空的时候一个都不能漏
  /// （见 `parse` 里那段）。模型先复述一句格式、再给真答案时，真答案那一整段
  /// 如果留在扫描路的输入里，它里面那句 `"请不要 delete 这封信"` 会变成一条
  /// **可点**的删除建议 —— 正是挖空要挡的东西换了个形状又回来。
  ///
  /// **解不开的那一段要跳过去接着找**，不是一遇到就收工。模型先复述模板、再给
  /// 真答案时，那个走了一半的模板会把真答案一起圈进同一段「配平但解不开」里
  /// （实测两种形状：`复述：{"action":"id"` 换行 `真答案：{…}`，以及
  /// `{"a":1}` 换行 `按 {name} 模板。分析：{…}`）—— 就此收工的话真答案一个字
  /// 都不挖，它里面那句「请不要 delete」照样变成一条**可点**建议。所以失败之后
  /// 从**下一个 `{`** 接着起扫（而不是从 `chunk.end` —— 那会把真答案整个跳过）。
  ///
  /// 跳过是**有预算**的：每次失败都从头扫一遍，最坏是平方级（「一万个只有开
  /// 括号的 `{`」那种输入里，每一次都要扫到串尾）。预算按全文长度的倍数给
  /// （[_scanBudgetFactor]），花完就收工。真实回话里那几个 `{` 离这个预算差着
  /// 几个数量级，而那种病态输入里本来也没有答案可抽。
  static const int _scanBudgetFactor = 4;

  static List<({int start, int end, Map<Object?, Object?> decoded})>
      _jsonObjects(String text) {
    final out = <({int start, int end, Map<Object?, Object?> decoded})>[];
    final budget = text.length * _scanBudgetFactor;
    var spent = 0;
    var from = 0;
    while (from < text.length) {
      final start = _objectStart(text, from);
      if (start < 0) break;
      final chunk = _balancedObject(text, start);
      spent += chunk.end - start;
      final decoded = chunk.decoded;
      if (decoded != null) {
        out.add((start: start, end: chunk.end, decoded: decoded));
        from = chunk.end;
      } else {
        from = start + 1;
      }
      if (spent > budget) break;
    }
    return out;
  }

  /// 从 [start]（必须是 `{`）起步找那个配平的 `{…}` 并解成 `Map`。
  ///
  /// 返回 `(end, decoded)`：`end` 是**扫到哪就停在哪**（配平时是 `}` 的下一位，
  /// 没配平时是串尾）—— 调用方靠它算这一趟花了多少预算；`decoded` 是解出来的
  /// 对象，**找不到配平的 `}`（回话被截断）或者配平了却解不开时都是 null**。
  /// 两种失败对调用方的意义相同（都要「往后接着找」），所以不分开返回。
  ///
  /// 必须跳过字符串字面量里的花括号：`"reason": "用 {name} 替换"` 会让朴素的
  /// 计数提前归零，于是切出来的那一截根本不是一个完整的 JSON。
  ///
  /// 嵌套的对象由 [depth] 吃掉 —— 这里要的是**顶层**那一个。
  static ({int end, Map<Object?, Object?>? decoded}) _balancedObject(
    String text,
    int start,
  ) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          Map<Object?, Object?>? decoded;
          try {
            final value = jsonDecode(text.substring(start, i + 1));
            if (value is Map) decoded = value;
          } catch (_) {
            // 配平但写坏了 —— 交给降级扫描。
          }
          return (end: i + 1, decoded: decoded);
        }
      }
    }
    return (end: text.length, decoded: null);
  }

  /// 逐行找 [candidates] 里的 id 关键字，按**出现顺序**收成列表。
  ///
  /// 参数叫 `candidates` 而不是 `pool`，因为它**不是**「动作池」、只是「这一遍
  /// 要在哪些名字里找」：调用方一次传 `MailAction.values`（判「读出了东西吗」）、
  /// 一次传过滤后的池子（取候选）。函数本身对被过滤掉的那些一无所知、也不该知道。
  ///
  /// **一行里命中多个 id 时取的是「这一遍的 [candidates] 里最先出现的那个」**，
  /// 所以同一个行在两遍里可能给出不同的名字 —— 这正是要的效果：`star 或者
  /// reply 都行` 配一份没有 `star` 的池子，全量那一遍取到 `star`（只用来判
  /// 「读出了东西」），池子那一遍取到 `reply`（真的当候选）。反过来「先扫全量
  /// 再过滤」会让这一行只留下 `star`、被白名单挡掉之后连 `reply` 一起丢掉 ——
  /// 而 `reply` 是这条链路上唯一一份模型写出来的正文。
  ///
  /// `reason` 取这一行去掉 id 之后的余下文字 —— 这正是「模型用自然语言写了
  /// `reply —— 对方在等你确认`」那种回话的形状。
  ///
  /// **词边界是必要的**：没有 `\b` 的话，`in_replyDraft` 里的 `reply` 会被
  /// 当成一次命中（实测 `\breply\b` 不匹配它）。
  static List<SuggestionChoice> _scanActions(
    String text,
    List<MailAction> candidates,
  ) {
    if (candidates.isEmpty) return const <SuggestionChoice>[];
    final patterns = <MapEntry<MailAction, RegExp>>[
      for (final action in candidates)
        MapEntry(action, RegExp('\\b${RegExp.escape(action.id)}\\b')),
    ];
    final seen = <MailAction>{};
    final out = <SuggestionChoice>[];
    for (final line in text.split('\n')) {
      MailAction? hit;
      var at = -1;
      for (final entry in patterns) {
        final match = entry.value.firstMatch(line);
        if (match == null) continue;
        if (at < 0 || match.start < at) {
          at = match.start;
          hit = entry.key;
        }
      }
      if (hit == null || !seen.add(hit)) continue;
      final rest =
          line.substring(0, at) + line.substring(at + hit.id.length);
      out.add(SuggestionChoice(action: hit, reason: _truncate(_tidy(rest))));
    }
    return out;
  }

  /// 从**坏 JSON 里**也能捞出一份回信草稿。
  ///
  /// 正则只认 JSON 字符串的形状（含转义），取出来再走一次 `jsonDecode` 把
  /// `\n` / `\"` 还原 —— 手工 `replaceAll` 那一支是给「转义本身就坏了」兜底的。
  ///
  /// **只捞 `replyDraft`，不捞 `forwardNote`**（spec §3.4）：附言只有跟着一个
  /// `forward` 动作才有意义，单独捞出来既没有动作承载它、也不能变成别的动作。
  /// 草稿不一样 —— 它本身就是一份可用的回信。
  static String? _scanReplyDraft(String text) {
    final match =
        RegExp(r'"replyDraft"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(text);
    if (match == null) return null;
    final body = match.group(1) ?? '';
    try {
      final decoded = jsonDecode('"$body"');
      if (decoded is String) return _nonBlank(decoded);
    } catch (_) {
      // 转义坏到 jsonDecode 都吃不下 —— 手工还原，总比整段丢掉好。
    }
    return _nonBlank(
      body.replaceAll(r'\\', r'\').replaceAll(r'\n', '\n').replaceAll(r'\"', '"'),
    );
  }

  /// 掐掉 reason 两端剩下的标点。扫描路捞出来的东西长这样：
  /// `- reply —— 对方在等你确认`，去掉 id 之后两头都是符号。
  static const String _edge = '-—–:：,，。.;；!！?？"\'“”‘’「」『』[]{}（）()';

  static String _tidy(String raw) {
    var text = raw.trim();
    while (text.isNotEmpty && _edge.contains(text[0])) {
      text = text.substring(1).trim();
    }
    while (text.isNotEmpty && _edge.contains(text[text.length - 1])) {
      text = text.substring(0, text.length - 1).trim();
    }
    return text;
  }

  static String _truncate(String reason) => reason.length <= maxReasonLength
      ? reason
      : reason.substring(0, maxReasonLength);

  static String? _text(Object? value) => value is String ? value : null;

  /// 空串与 null 一样对待：`"replyDraft": ""` 不是一份草稿。
  static String? _nonBlank(String? value) =>
      value == null || value.trim().isEmpty ? null : value;
}
