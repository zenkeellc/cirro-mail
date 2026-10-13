import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as quill;

/// 正文 / 草稿的 `Drafts.content` 字符串 ⇄ `quill.Document`。
///
/// 为什么单独一层：草稿表里既可能有**旧的纯文本**（本轮之前存的），也可能有
/// 新的 Delta JSON。两种都要能读进来，且读旧格式时不能崩 —— 纯文本本身就是
/// 合法 Delta（`{"insert":"...\n"}`），所以这里不做「格式迁移」，只做**嗅探**。
///
/// 一条实测约束（flutter_quill 11.6）：`Document.fromJson` 的最后一个 op 必须
/// 以 `\n` 结尾，否则 `loadDocument` 的 assert 会炸；而**多**插一个裸
/// `{"insert":"\n"}` 会真的多出一个空行（`toPlainText` 是把 root 的子节点直接
/// 串起来的）。所以这里既不补也不压 —— 只保证「最后一个 op 以 \n 结尾」。
abstract final class DocumentCodec {
  const DocumentCodec._();

  /// 空文档的存储形式：一个空段落。
  ///
  /// **必须是 raw 字符串** —— 这里要的是两个字符 `\` `n`（JSON 转义），
  /// 不是真的换行符。写成普通字面量的话，跟 [encode] 的输出永远对不上。
  static const String emptyDelta = r'[{"insert":"\n"}]';

  /// 空文档。`Document()` 自带一个 `\n`，**不要**再补一个。
  static quill.Document empty() => quill.Document();

  /// 草稿/正文的存储格式 → Document。
  ///
  /// 判定顺序（不能反）：
  /// 1. 空白串 → 空文档；
  /// 2. 能按 JSON 解析出「每个元素都带 insert 的 List」→ 当 Delta；
  /// 3. 其余 → 当纯文本（旧草稿）。
  ///
  /// **任何一步出错都退到纯文本**，绝不抛给调用方 —— 用户在写信页看到的
  /// 应该是他的字，不是一个红屏。
  static quill.Document decode(String? stored) {
    final raw = stored ?? '';
    if (raw.trim().isEmpty) return empty();
    final delta = _tryParseDelta(raw);
    if (delta != null) {
      try {
        return quill.Document.fromJson(delta);
      } on Object {
        // 保底（不是死代码）：flutter_quill 11.6 对畸形 Delta 并非全宽容。
        // 过得了上面的嗅探（Map + insert + 末 op 以 \n 收尾）、但
        // `Document.fromJson` 仍会抛的有：`insert` 为 null / bool / 数字 /
        // List，`attributes` 非 Map（如字符串）——那时 Quill 在类型 cast 上炸。
        // 真宽容的只有「Map 形态的嵌入但值类型不对」（`{'image':123}` 被静默
        // 丢弃）。两种情况都在测试里锁了：这里退到纯文本，绝不把异常漏出去。
      }
    }
    return fromPlainText(raw);
  }

  /// 旧草稿（纯文本）→ Document。
  ///
  /// 与 `ComposeHtml.fromPlainText` 的归一化一致：先统一换行符
  /// （`\r\n` / `\r` → `\n`），再按空行（`\n{2,}`）分段、每段 `trim()`、
  /// 空段丢弃。这样同一份旧草稿在「编辑器里的段落」和「发送出去的 `<p>`」两边
  /// 形状相同；不统一换行符的话，裸 `\r` 会原样进 Delta、进导出器、进收件人
  /// 的 HTML，老式 CR 甚至会把整段挤成一个 Quill 块。
  ///
  /// **单换行也分段** —— Quill 里「块」就是「行」（每个 `\n` 结束一个 Line），
  /// 同一块内的软换行表达不出来，所以段内再按 `\n` 逐行展开成每行一个 op。
  /// 代价是旧草稿里「一段内的手动折行」会变成两个段落，视觉上多一个段间距；
  /// 这在旧草稿里是少见的写法，且**只在第一次编辑时**发生（之后就存成 Delta）。
  static quill.Document fromPlainText(String plain) {
    final normalized = plain.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final ops = <Map<String, dynamic>>[];
    for (final paragraph in normalized.split(RegExp(r'\n{2,}'))) {
      final trimmed = paragraph.trim();
      if (trimmed.isEmpty) continue;
      for (final line in trimmed.split('\n')) {
        ops.add(<String, dynamic>{'insert': '$line\n'});
      }
    }
    if (ops.isEmpty) ops.add(<String, dynamic>{'insert': '\n'});
    return quill.Document.fromJson(ops);
  }

  /// Document → 存储格式（Delta JSON 字符串）。草稿与正文都用它。
  ///
  /// **不做任何规整** —— 尾部空行是用户敲出来的，存的时候一模一样地存回去。
  static String encode(quill.Document document) =>
      jsonEncode(document.toDelta().toJson());

  /// 这份（存储形式的）Delta 算不算**空正文**。
  ///
  /// 为什么不能在导出的 HTML 上判：`DeltaToEmailHtml.convert` 对空文档产出的是
  /// `<p style="margin:0 0 12px 0"><br></p>` —— `trim()` 之后**永远不为空**，
  /// 于是 `SendValidationError.emptyContent` 那条路径在包成 HTML 之后就再也
  /// 触发不了了（探针 probe67 实测）。判定必须落回 Delta。
  ///
  /// **嵌入算内容**：一封只有一张图的信是能发出去的。图片与表格在纯文本里
  /// 是 `￼`，直接 `trim()` 会把它当空白 —— 所以先看有没有嵌入，再看文字。
  static bool isEmptyDelta(String? stored) {
    final raw = stored ?? '';
    if (raw.trim().isEmpty) return true;
    final decoded = _tryParseDelta(raw);
    if (decoded == null) return raw.trim().isEmpty;
    for (final op in decoded) {
      final insert = (op as Map)['insert'];
      if (insert is Map) return false; // 块级嵌入
      if (insert is String && insert.replaceAll('\n', '').trim().isNotEmpty) {
        return false;
      }
    }
    return true;
  }

  static List<dynamic>? _tryParseDelta(String raw) {
    if (!raw.trimLeft().startsWith('[')) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) return null;
      for (final op in decoded) {
        if (op is! Map || !op.containsKey('insert')) return null;
      }
      final last = decoded.last['insert'];
      // 最后一个 op 必须以 \n 收尾，否则 Quill 的文档树建不出来。
      return (last is String && last.endsWith('\n')) ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
