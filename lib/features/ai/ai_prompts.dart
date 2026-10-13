import 'inline_continuation.dart';

/// 六份 prompt 集中一处（① 改写 / ② 成文 / ③ 续写 / ④a 标题 / ⑤ 回复建议 /
/// ⑥ 邮件建议，另有 ④b 发送前检查）。
///
/// **为什么集中**：调 prompt 是这几件事里最需要反复改的部分，散在几个文件里
/// 就一定会改漏（改了改写、忘了续写，两者风格就不一致了）。放在一起还能一眼
/// 看出「模型被要求做的事」与 spec §4.4 的边界是否一致。
///
/// ①–④a 共同的硬约束（这几份各自重申，因为模型不看别的 prompt）：
/// - **只输出正文本身**，不要前言后语（「好的，这是改写后的版本：」这类）；
/// - 沿用邮件安全子集：只能出现段落、标题、粗/斜/下划线/删除线、列表、引用、
///   行内代码；**不要**加颜色、字号、字体；
/// - 不确定的地方不要编（人名、数字、日期）。
///
/// **⑤ 与 ⑥ 不适用上面第一条**：⑤ 要的是一堆短句（回复开头），⑥ 要的是一段
/// JSON。它们各自的形状在方法注释里写清楚了 —— 别把「只输出正文本身」套上去。
///
/// 这一层**不 import 任何 compose 侧的东西**（只 import 同目录的
/// `inline_continuation.dart` 取那个光标标记常量）—— `ai/` 与内容无关，
/// 接线由 `compose/` 那一侧负责。独立性靠 `ai/` 顶层不 import `compose/` 来保证。
abstract final class AiPrompts {
  const AiPrompts._();

  /// ① 选中即改。
  static String rewrite({
    required String selection,
    required RewriteTone tone,
    String? extraInstruction,
  }) =>
      '你是邮件写作助手。把下面这段文字按「${tone.instruction}」改写。\n'
      '要求：\n'
      '- 保持原意与信息量，不增删事实；\n'
      '- 保持原有的称呼、署名与专有名词逐字不变；\n'
      '- 只输出改写后的正文，不要任何说明、不要代码块围栏；\n'
      '- 可以用 Markdown 的 `**粗体**` 与 `` `行内代码` ``，不要用其他标记。\n'
      '${extraInstruction == null || extraInstruction.trim().isEmpty ? '' : '\n额外要求：${extraInstruction.trim()}\n'}'
      '\n原文：\n$selection';

  /// ② 要点成文。
  static String draft({
    required String points,
    required RewriteTone tone,
    required DraftLength length,
    String? subject,
    String? recipient,
  }) =>
      '你是邮件写作助手。根据下面的要点，写一封完整的邮件正文。\n'
      '要求：\n'
      '- 语气：${tone.instruction}；篇幅：${length.instruction}；\n'
      '- 要点里没有的信息**一律不要编**（人名、时间、数字、承诺）；\n'
      '- 要有得体的开头与结尾，但不要写「主题：」这一行；\n'
      '- 只输出正文，不要任何说明、不要代码块围栏。\n'
      '${subject == null || subject.trim().isEmpty ? '' : '\n这封邮件的主题是：${subject.trim()}\n'}'
      '${recipient == null || recipient.trim().isEmpty ? '' : '收件人：${recipient.trim()}\n'}'
      '\n要点：\n$points';

  /// ③ 行内续写。**只要一小段**，多了会打断用户的思路。
  ///
  /// [context] 是**整封邮件**（含引用区），光标处插了
  /// `InlineContinuation.marker`（`【光标位置】`）。模型据此知道该在哪儿接着
  /// 写、以及光标后面还有什么（引用里对方发来的原信）。
  static String continuation({
    required String context,
    String? subject,
  }) =>
      '你是邮件写作助手。下面是一封邮件（可能包含引用进来的原信），其中'
      '「${InlineContinuation.marker}」标出了用户光标的位置。请**只在该位置**'
      '接着往下写一句话。\n'
      '要求：\n'
      '- 只写**一到两句**，最多 60 个汉字或 40 个词；\n'
      '- 只输出插在该位置的内容本身，**不要在输出里重复「'
      '${InlineContinuation.marker}」这个标记**，也不要引号与任何说明；\n'
      '- 顺着标记**前后**已有的语气与称呼继续，不要另起话题、不要重新问候、'
      '不要落款；\n'
      '- 标记之后的引用原信只是参考：**不要**把它当成你自己要写的内容、'
      '也不要改写它；\n'
      '- 如果上文已经是一个完整的结尾（比如「谢谢」「祝好」），就输出空字符串，'
      '不要硬凑。\n'
      '${subject == null || subject.trim().isEmpty ? '' : '\n主题：${subject.trim()}\n'}'
      '\n邮件内容：\n$context';

  /// ④a 标题生成。**只要一个**，直接填进主题栏。
  ///
  /// 以前是「一行一个候选、做成列表让用户挑」，候选面板没了之后那段写法就
  /// 不合适了：调用方拿到的是一整段文字，直接填进主题栏的话会把说明、编号
  /// 一起填进去。现在明确要一行，配合 [subjectLineIn] 抠出来。
  ///
  /// [current] 是主题栏里已经有的字。**有就传** —— 用户自己敲过半句标题时，
  /// 「参考它改得更准」比「无视它另起一个」有用得多，也避免了把用户写的那句
  /// 直接扔掉。
  static String subject({
    required String body,
    String? current,
  }) =>
      '你是邮件写作助手。为下面这封邮件起**一个**主题。\n'
      '要求：\n'
      '- 不超过 20 个汉字或 8 个词；\n'
      '- 直接说事，不要「关于…的邮件」这种套话，不要 emoji；\n'
      '- 只输出主题这一行本身，不要引号、不要编号、不要任何说明。\n'
      '${current == null || current.trim().isEmpty ? '' : '\n已经写了一个主题，参考它（可以沿用，也可以改得更贴切）：${current.trim()}\n'}'
      '\n邮件正文：\n$body';

  /// 从模型回话里抠出**一个**标题。
  ///
  /// 取第一个非空行，再清掉两层模型爱加的东西：
  /// 1. `主题：` / `标题：` / `Subject:` 这类前缀 —— 模型很爱把字段名一起写出来，
  ///    整句填进主题栏就多了一截；
  /// 2. 首尾的引号与书名号（`"` `'` `「」` `《》`）—— 它以为在「引用」一个标题。
  ///
  /// 返回 null 表示一行都没捞到（模型只回了空行），调用方据此什么都不做 ——
  /// 那比往主题栏里填一句「（空）」强。
  static String? subjectLineIn(String raw) {
    final lines = parseLines(raw);
    if (lines.isEmpty) return null;
    var line = lines.first;
    line = line.replaceFirst(
      RegExp(r'^(主题|标题|subject|title)\s*[:：]\s*', caseSensitive: false),
      '',
    );
    line = line.replaceAll(RegExp(r'''^["'“”‘’「」『』《》\s]+|["'“”‘’「」『』《》\s]+$'''), '');
    return line.isEmpty ? null : line;
  }

  /// ⑤ 回复建议：拿来信正文，给几条**回复开头**。
  ///
  /// **与 ② 起草的区别在两头**（spec §6.1）：起草是「用户给要点、成篇」，
  /// 这里是「来信当输入、只要开头」。所以 prompt 里「只写开头、不要整封信」
  /// 那句是这份 prompt 的**核心**，不是修饰 —— 少了它模型会写一整封回信，
  /// 而用户自己还要写正文，拿到的东西没法用。
  static String replySuggestions({
    required String incoming,
    int count = 3,
  }) =>
      '你是邮件助手。下面是一封**别人发来的**邮件，请写出 $count 个不同的回复开头'
      '（2–3 个即可）。\n'
      '要求：\n'
      '- **每个只写开头一到两句**（可含称呼），**不要写完整的一封信**、'
      '不要写落款、不要写正文主体；\n'
      '- $count 个之间要**语气/角度不同**（比如一个确认、一个提问、一个委婉推后）；\n'
      '- 来信里没有的信息**一律不要编**（时间、人名、承诺）；\n'
      '- 每行一条，**行首不要写序号、不要加引号**；\n'
      '- 不要任何说明文字，直接开始写。\n'
      '\n来信：\n$incoming';

  /// 把模型吐的回复候选拆成列表。
  ///
  /// **最多三条**（spec §6.4 说的「2–3 条」的硬上限）：面板里超过三条
  /// 就开始像「选择困难」而不是「给个开头」。
  ///
  /// 过滤规则比 [parseLines] 多一条：**收尾话要滤掉**。模型很爱在最后
  /// 补一句「以上是三个开头」或者「希望对你有帮助」—— 那是一句**说明**，
  /// 不是候选，用户点下去会把这句话插进正文。
  static List<String> replyCandidates(String raw) {
    const closers =
        r'^(以上|希望|如需|如果|如有|请选择|你可以|可以从中|these are|hope|let me know)';
    final out = <String>[];
    for (final line in parseLines(raw)) {
      if (RegExp(closers, caseSensitive: false).hasMatch(line)) continue;
      out.add(line);
      if (out.length == 3) break;
    }
    return out;
  }

  /// ⑥ AI 邮件建议：给一封**别人发来的信**，让模型从**固定的动作池**里挑，
  /// 按「该先做哪个」排好序吐回来。
  ///
  /// 与其它五份 prompt 的根本区别：**它不给模型自由描述一个动作的机会**。
  /// 动作池是程序真正能执行的那几个（[actionIds]），池子外面的一切都会被
  /// 解析器当没看见 —— 模型吐一句「归档到项目文件夹」，点了要么什么都不
  /// 发生、要么被猜成别的动作去执行。所以「只能从下面这个列表里挑」这句是
  /// 这份 prompt 的**核心约束**，不是修饰。
  ///
  /// [actionIds] 是**已经按当前状态过滤过**的那一份（`suggestActionPool`），
  /// 池子里没有 `markRead` 就说明这封信已经读过了 —— 那份过滤是调用方的事，
  /// 这里只管把它们列出来。
  ///
  /// 收裸字符串而不是 `MailAction`：`ai/` 这一层**不许 import `suggest/`**
  /// （文件头那句「`ai/` 与内容无关」）。动作的**语义**（每一行后面那句
  /// 解释）仍然在这里维护 —— 它是 prompt 的一部分，不是 `suggest/` 的常量。
  static String suggest({
    required String input,
    required List<String> actionIds,
  }) {
    final lines = <String>[
      for (final id in actionIds) _suggestActionLines[id] ?? '- $id：',
    ];
    final wantsReply = actionIds.contains('reply');
    final wantsForward = actionIds.contains('forward');
    // 池子是调用方给的，不保证含 `none`（真实链路上 `suggestActionPool` 永远
    // 含它，但测试与未来的调用方会传别的组合）。池子里没有 `none` 时还叫模型
    // 「不用处理就把 none 放进去」，是叫它输出一个列表里根本没有的动作 ——
    // 解析器会当没看见，那一句就成了纯噪音。
    final wantsNone = actionIds.contains('none');
    return '你是邮件助理。下面是一封**别人发来的**邮件，请判断用户接下来'
        '值得做什么。\n'
        '\n'
        '你能给出的动作**只有下面这几个**，不要发明列表以外的动作：\n'
        '${lines.join('\n')}\n'
        '\n'
        '输出要求（**必须**）：\n'
        '- 只输出一个 JSON 对象，不要任何其他文字、不要代码块围栏；\n'
        '- 形状：{"summary":"一句话说明这封信要你做什么",'
        '"actions":[{"action":"…","reason":"…"}]'
        '${wantsReply ? ',"replyDraft":"…"' : ''}'
        '${wantsForward ? ',"forwardNote":"…"' : ''}}\n'
        '- `actions` 给 1–4 项，**最推荐的放第一个**（顺序就是优先级）；\n'
        '- `reason` 一句话，说明**为什么**建议做这一件（不要复述信件内容）；\n'
        '${wantsNone ? '- 这封信确实不用处理时，就把 `none` 放进 `actions`。' : ''}'
        '**不要为了凑数编一个动作**；\n'
        '${wantsReply ? '- `replyDraft` 是一封完整的回信正文，纯文本、段落之间空行。'
            '只在你建议 `reply` 时才写；\n' : ''}'
        '${wantsForward ? '- `forwardNote` 是转发时写给收件人的一两句话。'
            '只在你建议 `forward` 时才写；\n' : ''}'
        '- 来信里没有的信息**一律不要编**（时间、人名、承诺）。\n'
        '\n'
        '来信：\n$input';
  }

  /// `suggest` 里每一行动作的解释，**唯一给模型看的语义表**。
  ///
  /// `mail_action.dart` 的 `promptLine` 是给「不依赖 ai 包」的单元测试看的
  /// 开发者说明，**不进任何一份 prompt**（prompt 只认这张表）。规则不变：
  /// 池子外面的一律不出现。
  static const Map<String, String> _suggestActionLines = <String, String>{
    'reply': '- reply：直接回复发件人，用中文回信。你要同时写出 `replyDraft`',
    'forward': '- forward：转给别人。你要同时写出 `forwardNote`',
    'remind': '- remind：现在不用处理，但过一阵要回来看（时间由用户自己挑）',
    'delete': '- delete：可以删掉（广告、通知、已过期的验证码）',
    'markRead': '- markRead：没什么要做的，标记成已读就行',
    'markUnread': '- markUnread：现在处理不了，留成未读提醒自己回来看',
    'star': '- star：先把星标加上，回头统一处理',
    'unstar': '- unstar：已经处理完了，星标可以撤了',
    'none': '- none：确实不需要用户做任何事（纯通知类的信）',
  };

  /// ④b 发送前检查（模型那一半）。本地规则在 `preflight.dart`，
  /// **那是零成本的、也是最有价值的一条**（声明了附件却没附件）。
  static String preflightReview({
    required String subject,
    required String body,
    required int attachmentCount,
  }) =>
      '你是邮件审校。检查下面这封邮件有没有该改的地方。\n'
      '只检查这四类，其他一律不提：\n'
      '1. 错别字或用错的词；\n'
      '2. 语气前后不一致（比如一半正式一半随意）；\n'
      '3. 说了要附件、要回答的问题，但正文里没交代；\n'
      '4. 可能让人误会的表述。\n'
      '要求：\n'
      '- 每条一行，格式：`一句问题描述`；\n'
      '- **没有问题时输出空行**，不要为了交差硬找；\n'
      '- 不要重写正文、不要给出改后版本、不要任何说明文字。\n'
      '\n主题：${subject.trim().isEmpty ? '（空）' : subject.trim()}\n'
      '附件数：$attachmentCount\n'
      '\n正文：\n$body';

  /// 把模型吐出来的「每行一条」拆成列表。空行、`- ` `1. ` 前缀都清掉。
  ///
  /// 序号正则**只剥真正的序号**，不做「吃掉开头所有数字/符号」这种宽匹配：
  /// 后者会把句子开头的数字一起吃掉（`50% 的人会误解` → `% 的人会误解`、
  /// `3.14 是圆周率` → `是圆周率`）。只认这几种形式：
  /// `-` / `*`（后跟空白）、`1.` / `1、` / `1)`、带括号的 `(1)`；数字限 1–2 位。
  /// 关键取舍是 `.`：它同时是「3.14」「2024.」的一部分，所以**只有点号后面
  /// 紧跟空白**才算序号 —— 于是 `3.14 是圆周率` 与 `2024. 年份写法` 能保住，
  /// 而 `、`/`)` 是明确的列举符号，不要求后面有空白。
  static List<String> parseLines(String raw) => raw
      .split('\n')
      .map((line) => line.trim())
      .map((line) => line
          .replaceFirst(
              RegExp(r'^(?:[-*]\s+|\(\d{1,2}\)\s*|\d{1,2}[)、）]\s*|\d{1,2}\.\s+)'),
              '')
          .trim())
      .where((line) => line.isNotEmpty)
      // 模型偶尔会顶一句「没有问题」——那不是一条发现。
      .where((line) => !RegExp(
            r'^(无|没有|无问题|没有问题|暂未发现|未发现问题|None|No issues?)[。.!！,，]*$',
            caseSensitive: false,
          ).hasMatch(line))
      .toList();
}

/// 改写语气。**只有这几种** —— 与 spec §3.2「明确不做字体/颜色」同一个理由：
/// 能选的越少，结果越稳定，用户也不用去猜。
enum RewriteTone {
  polish('保持原样，只把语句理顺、去掉啰嗦', '润色'),
  formal('更正式、更书面', '更正式'),
  friendly('更友好、更口语', '更友好'),
  concise('更简洁，能删的都删掉', '更简洁'),
  translateEn('翻译成地道的英文', '译成英文'),
  translateZh('翻译成简体中文', '译成中文');

  const RewriteTone(this.instruction, this.label);

  /// 给模型看的要求。
  final String instruction;

  /// 给用户看的按钮名。**单独一个字段** —— 从 [instruction] 里截一段当按钮名
  /// 的话，改一句 prompt 文案就会把界面文案一起改掉（改写面板的 chip 用它）。
  final String label;
}

/// 要点成文的篇幅。
enum DraftLength {
  short('三到五句', '简短'),
  medium('一到两段', '中等'),
  long('三到四段，把要点展开说清楚', '较长');

  const DraftLength(this.instruction, this.label);

  /// 给模型看的要求。
  final String instruction;

  /// 给用户看的按钮名。起草面板的篇幅 chip 用它（理由同 [RewriteTone.label]：
  /// 从 [instruction] 截一段当按钮名的话，改 prompt 文案会连带改掉界面文案）。
  final String label;
}
