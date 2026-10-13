// 剪贴板读取要走 `ClipboardServiceProvider`，它在 flutter_quill 11.6 上标了
// `@experimental` —— 但**没有别的路子**能拿到「剪贴板里的 HTML 风味」这件事
// （`QuillEditorConfig` 上根本没有这个口子）。用它，并把原因写在这里：
// 将来升级 flutter_quill 时，这个 import 是最先要复查的一处。
// ignore_for_file: experimental_member_use

import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_quill/internal.dart' as qi;
import 'package:flutter_quill/quill_delta.dart' as qd;

import '../html/mail_html_to_delta.dart';

/// 富文本粘贴的**接线**：系统剪贴板 → `MailHtmlToDelta` → 文档。
///
/// 为什么不直接用 flutter_quill 自带的 HTML 粘贴：它走 `DeltaX.fromHtml`
/// （`quill_controller_rich_paste.dart:40`），而那个实现遇到表格会转换两次
/// （spec §0.2 第 2 条）。所以 [mailQuillController] 把
/// `enableExternalRichPaste` 关了，HTML 这一路改由本文件接管。
///
/// **为什么返回 `Future<bool>` 而不是直接插**：flutter_quill 的
/// `clipboardPaste` 用这个返回值决定要不要继续往下走
/// （`quill_controller.dart:578`）。返回 `false` = 「我不管」，于是粘贴会落到
/// 图片 → 纯文本那几条通路；返回 `true` = 「处理完了」。
/// 这个「让位」很关键：**纯文本粘贴必须能落到默认通路**，否则从记事本
/// 粘一段字会被我们吞掉。
///
/// **转换失败一律让位，绝不抛出去**：剪贴板里的 HTML 是任意的外部输入，
/// 上游 `HtmlToDelta` 有已知的崩溃缺陷（flutter_quill #2635，2026-08-11：
/// `nodeToOperation` 抛 `Bad state: No element`）。让位之后粘贴会退到纯文本
/// 通路 —— 用户看到的是「格式丢了」，而不是「编辑器白屏了」。
///
/// 这条承诺覆盖**两个阶段**，缺一不可：
/// - **转换阶段**：`MailHtmlToDelta.convert` 抛异常 → 让位（见 try 的说明）；
/// - **写入阶段**：读剪贴板是异步的（真实实现走 `QuillNativeBridge`，几十毫秒
///   起步），这期间用户完全可能关掉写信页 → `controller.dispose()`。写回一个
///   已销毁的 controller 会撞 `Document.compose` 的
///   `assert(!documentChangeObserver.isClosed)` 并**抛穿** `clipboardPaste`
///   的调用方（`raw_editor_state.dart:150`）。所以 try 要一直包到 [insertOps]。
abstract final class MailPasteHandler {
  const MailPasteHandler._();

  /// 从系统剪贴板取 HTML 并粘进来。返回 true 表示**处理完了**
  /// （调用了 [insertOps]），false 表示让给默认通路。
  static Future<bool> handleHtmlPaste(q.QuillController controller) async {
    // try 必须**连写入阶段一起包**：`insertOps` 里的 `replaceText` 在
    // controller 已被销毁（页面关掉了）时会抛断言。只包 `convert` 是不够的
    // —— 那只是「读取失败」，而「写完时页面没了」同样属于「不该把异常抛给
    // 调用方」这一类的失败。
    try {
      final html = await qi.ClipboardServiceProvider.instance.getHtmlText();
      if (html == null || html.trim().isEmpty) return false;

      final ops = MailHtmlToDelta.convert(html);
      // 见 [_isBlankOps]：`convert` 的保底最小文档让 `ops.isEmpty` 失效，
      // 判据必须是「有没有实际内容」。
      if (_isBlankOps(ops)) return false;
      // 读取期间页面可能已经关了。写入前再确认一次，顺手把返回值也定成
      // 「没处理」。（[insertOps] 里另有一道同款防线，那是给直接调用它的
      // 入口用的 —— 它拿不到这里的判断结果。）
      if (_isDisposed(controller)) return false;

      insertOps(controller, ops);
      return true;
    } on Object {
      // 见类注释：外部输入 + 上游已知缺陷，退到纯文本通路。
      return false;
    }
  }

  /// controller 是否已经销毁（写信页被关掉了）。
  ///
  /// 为什么不直接看 `QuillController`：11.6 的它**没有公开的 `disposed`
  /// getter**（`_isDisposed` 是私有字段），而 `addListener`/`notifyListeners`
  /// 那些保险措施对「还能不能改文档」这个问题并不作答。
  ///
  /// `dispose()` 会 `document.close()`，而 `StreamController.isClosed` 是干净、
  /// 稳定的公开 API，正是「这份文档还能不能改」的判据 —— 也恰好就是
  /// `Document.compose` 那条断言在查的东西。
  static bool _isDisposed(q.QuillController controller) =>
      controller.document.documentChangeObserver.isClosed;

  /// ops 是否**没有任何实际内容**（只有空白文本、或压根就是空的）。
  ///
  /// 为什么不能直接用 `ops.isEmpty`：`MailHtmlToDelta.convert` **从不返回空
  /// 列表** —— 走到「可解析、清洗后什么都不剩」的输入（`<script>` /
  /// `<style>` / `<iframe>` / `<svg>` / `<template>` / 空 `<div>` …）时，它
  /// 保底返回 [_minimalDocument] 那种 `[{"insert":"\n"}]`。于是原实现的
  /// `ops.isEmpty == false` 放行，把用户的选区替换成一个**空段落** —— 数据
  /// 丢失，而且跟类注释「转换失败一律让位」自相矛盾。
  ///
  /// 判据因此是「内容」而不是「列表长度」：只要有一个非空白的文字片段、或
  /// 任何一个嵌入（表格 / 图片），就算有内容。
  static bool _isBlankOps(List<Map<String, dynamic>> ops) {
    for (final op in ops) {
      if (op['insert'] is Map) return false;
      final data = op['insert'];
      if (data is String && data.trim().isNotEmpty) return false;
    }
    return true;
  }

  /// 把 [MailHtmlToDelta] 产出的 op 列表插到光标处。
  ///
  /// 单独公开是为了能测：粘贴的**手工验证成本很高**（要真去操作系统剪贴板），
  /// 而这里最容易错的部分是「插进去之后文档还合不合法」，那部分不需要剪贴板。
  static void insertOps(
    q.QuillController controller,
    List<Map<String, dynamic>> ops,
  ) {
    if (ops.isEmpty) return;
    // **写入前先看 controller 还活着没有**。`handleHtmlPaste` 是异步的（等
    // 剪贴板），回来时写信页可能已经被关掉、controller 已 dispose。此时再
    // `replaceText` 会撞 `Document.compose` 的
    // `assert(!documentChangeObserver.isClosed)`（`document.dart:462`）并
    // **抛穿**调用方 —— 承诺「绝不抛出去」的路径上，写入阶段同样要安静返回。
    if (_isDisposed(controller)) return;
    final document = controller.document;

    // 正文**原来就是空的**（只有空白）时，整篇替换 —— 否则粘贴内容会被挤到
    // 后面，留一个空段落在前头，用户得手动删。`Document()` 天生带一个 `\n`，
    // 所以「空文档」的长度是 1，这不是什么异常状态。
    final blank = document.toPlainText().trim().isEmpty;
    final int start;
    final int end;
    if (blank) {
      start = 0;
      end = document.length;
    } else {
      // **偏移必须夹在 `0 .. length-1`**：`document.length` 含末尾那个 `\n`，
      // 在 `length` 处插入会撞上 `QuillContainer.insert` 的 `index < length`
      // 断言（`container.dart:137`）—— debug 下直接崩。
      final last = document.length - 1;
      final selection = controller.selection;
      start = (selection.isValid ? selection.start : last).clamp(0, last);
      end = (selection.isValid ? selection.end : start).clamp(0, last);
    }

    // 落点是不是行首：文首算，前一个字符是换行也算。**不能**用「当前行是否
    // 为空」判断 —— 光标正好停在 `\n` 上时那个说法会答错。
    final atLineStart =
        start == 0 || document.getPlainText(start - 1, 1) == '\n';
    final fitted = _fitToContext(ops, atLineStart: atLineStart);
    // 贴合之后可能什么都不剩（比如「行中粘一个空段落」，末尾那个换行被削掉
    // 就没了）。这时**不能**去 replaceText：一个空的 Delta 走到
    // `Document.compose` 会撞上 `assert(delta.isNotEmpty)`
    // （`document.dart:468`），落点在 0 时连 retain 都没有。
    if (fitted.isEmpty) return;

    controller.replaceText(
      start,
      end - start,
      qd.Delta.fromJson(fitted),
      TextSelection.collapsed(offset: start),
    );
  }

  /// 把粘贴内容**贴合到落点**。三件事，都是为了「粘进来之后文档仍然合法」：
  ///
  /// 1. 以**块级嵌入**开头的粘贴，必须落在一行的行首 —— 否则嵌入跟在半句话
  ///    后面，`QuillEditor` 会抛 `UnimplementedError` 然后白屏
  ///    （spec §0.2 第 6 条）。落点在行中就补一个换行。
  /// 2. 嵌入**夹在中间、落在结尾、或就在开头**时，都要把它前后断开成独占一行
  ///    （[_isolateEmbeds]）。这一条原来漏了两处：
  ///    - 判据写的是「ops 是**以**嵌入开头」，于是 `甲<img>乙` 走到「没有块嵌入」
  ///      那条分支被原样放行，嵌入和文字同居一行；
  ///    - **以嵌入开头的**那一支直接返回 `ops`，于是 `<p><img>后</p>` 里嵌入
  ///      后面那个「后」同样和嵌入同居一行 —— 正是 [MailHtmlToDelta] 与
  ///      `image_insert.dart` 到处在守的那条 `Line` 不变量。
  /// 3. 落点在**一行中间**、且粘贴内容全是文字时，去掉末尾那个换行 ——
  ///    在「你好世界」中间粘「新字」，用户要的是「你好新字世界」，不是把
  ///    「世界」挤到下一行。反过来，落点本来就在行首时保留换行，粘贴内容
  ///    自成一段。
  static List<Map<String, dynamic>> _fitToContext(
    List<Map<String, dynamic>> ops, {
    required bool atLineStart,
  }) {
    if (_hasEmbed(ops)) {
      // 嵌入打头且落点在行中 → 先在它前面补一个换行（理由见第 1 条）。
      // 补**在这里**而不是在 [_emitLine] 里：`_emitLine` 只在「out 里已经有
      // 东西且不以换行结尾」时才补，而这一支的 out 是空的 —— 粘贴内容自己
      // 带的那个开头的嵌入会让它无从判断。
      final fitted = _startsWithBlockEmbed(ops) && !atLineStart
          ? <Map<String, dynamic>>[
              <String, dynamic>{'insert': '\n'},
              ...ops,
            ]
          : ops;
      // 注意这里**不**给「嵌入前面那段文字」补前导换行：那是内联内容，
      // 应当留在光标所在行（与纯文字粘贴一致）；要断的是嵌入**本身**那一行，
      // [_isolateEmbeds] 会在它前面补换行。
      //
      // `atLineStart` 传下去只影响**第一行**吃不吃粘贴内容自己的行级属性 ——
      // 见 [_isolateEmbeds] 里 `suppressFirstLineAttrs` 的说明。
      return _isolateEmbeds(fitted, suppressFirstLineAttrs: !atLineStart);
    }
    if (!atLineStart) {
      return _stripTrailingNewline(ops);
    }
    return ops;
  }

  /// 粘贴内容是否**以**嵌入开头。
  ///
  /// 口径与 [_hasEmbed] 一致：**任何**嵌入（行内 `image` 与块级
  /// `x-email-table` 一视同仁）都算。代价是行内图片也会像块级表格那样被劈成
  /// 独占一行 —— 但按 flutter_quill 的 `Line` 规矩，一行里有嵌入就不能再有
  /// 文字（见 [_isolateEmbeds]），且邮件里的图片本来就该按块级排版，
  /// 这个代价是划算的。
  static bool _startsWithBlockEmbed(List<Map<String, dynamic>> ops) =>
      ops.first['insert'] is Map;

  /// ops 里是否含有**任何嵌入**（图 / 表格）。
  ///
  /// 判据取「`insert` 是 `Map`」而不是具体类型名：嵌入类型的清单在
  /// `MailHtmlToDelta._knownEmbeds` 那边维护，本文件只关心「它占整行」这件事，
  /// 任何嵌入都算 —— 与 [_startsWithBlockEmbed] 同一条口径。
  static bool _hasEmbed(List<Map<String, dynamic>> ops) =>
      ops.any((op) => op['insert'] is Map);

  /// 挂在**行尾那个 `\n`** 上的属性 —— 名单只有一份，
  /// 就是 [MailHtmlToDelta.lineAttributes]（那边是产出这些属性的地方）。
  static const Set<String> _lineAttributes = MailHtmlToDelta.lineAttributes;

  /// 把 op 列表解析成「行」：每行的内容 + 它那个行尾 `\n` 上的行级属性。
  ///
  /// 先按 `MailHtmlToDelta._splitLines` 的形状把「文字里混着换行」的 op 拆开
  /// （文字一段、`\n` 一段；行级属性跟 `\n` 走，行内属性留在文字上），再按
  /// `\n` 切行。所有路径最终都以 `\n` 收尾，所以最后不会剩下「没有行尾的
  /// 半截内容」——那一支只是防御。
  ///
  /// 判定「哪些属性算行级」用 [MailHtmlToDelta.lineAttributes] —— **只有那一份
  /// 名单**。这里曾经复了一份字面量并写着「两处改动必须同步」，那种约定迟早会
  /// 漂（那边加一个、这边忘了改，行就切错，而且不报错）。
  static List<_PasteLine> _pasteLines(List<Map<String, dynamic>> ops) {
    final flat = <Map<String, dynamic>>[];
    for (final op in ops) {
      final data = op['insert'];
      if (data is! String || !data.contains('\n')) {
        flat.add(op);
        continue;
      }
      final attrs = op['attributes'];
      final inline = <String, dynamic>{};
      final line = <String, dynamic>{};
      if (attrs is Map) {
        for (final entry in attrs.entries) {
          final key = entry.key.toString();
          if (_lineAttributes.contains(key)) {
            line[key] = entry.value;
          } else {
            inline[key] = entry.value;
          }
        }
      }
      var rest = data;
      while (true) {
        final at = rest.indexOf('\n');
        if (at < 0) break;
        final chunk = rest.substring(0, at);
        if (chunk.isNotEmpty) {
          flat.add(<String, dynamic>{
            'insert': chunk,
            if (inline.isNotEmpty) 'attributes': inline,
          });
        }
        flat.add(<String, dynamic>{
          'insert': '\n',
          if (line.isNotEmpty) 'attributes': line,
        });
        rest = rest.substring(at + 1);
      }
      if (rest.isNotEmpty) {
        flat.add(<String, dynamic>{
          'insert': rest,
          if (inline.isNotEmpty) 'attributes': inline,
        });
      }
    }

    final lines = <_PasteLine>[];
    var content = <Map<String, dynamic>>[];
    for (final op in flat) {
      if (op['insert'] == '\n') {
        lines.add(_PasteLine(content, _lineAttrsOf(op)));
        content = <Map<String, dynamic>>[];
      } else {
        content.add(op);
      }
    }
    if (content.isNotEmpty) {
      lines.add(_PasteLine(content, const <String, dynamic>{}));
    }
    return lines;
  }

  /// 让每一个嵌入**独占一行**，并把嵌入所在那一行的**行级属性搬到正确的位置**。
  ///
  /// 嵌入必须独占一行是 flutter_quill 的硬约束 —— `q.Line` 的文档注释写明
  /// 「一行里有嵌入就不能再有文字」（"When a line contains an embed, it fully
  /// occupies the line, no other embeds or text nodes are allowed."），
  /// `image_insert.dart` 的 `_breakLineAt` 也是为此才先把行劈开。上游
  /// `MailHtmlToDelta._normalize` 虽然按这条规矩补过换行，但它补在
  /// `_splitLines` **之前**，随后的拆行会把「嵌入与文字同在一个 op」重新打散
  /// —— 所以这里得自己再拆一遍，顺便把行级属性摆正。
  ///
  /// **要修的缺陷**：行级属性（`header`/`list`/`blockquote`/`code-block`/…）
  /// 挂在**行尾那个 `\n`** 上（`_splitLines` 的口径）。`<h1>标<img></h1>` 被
  /// 拆成 `[标, img, \n/header:1]`，旧实现会在嵌入前补一个**裸**换行把「标」
  /// 断成普通段落，那个 `header:1` 于是落到后面一个空行上并被收尾处理丢掉
  /// —— 用户从网页复制「标题里带图」粘进来，标题格式整行消失、还多一个空行。
  ///
  /// **做法**：以「行」为单位重建。行级属性只认**行尾那个 `\n`**（这是
  /// `_splitLines` 唯一的真相来源），然后：
  /// 1. 行里若有嵌入，按嵌入把它切成「文字段 / 嵌入 / 文字段…」——每个文字段
  ///    后面的换行都带上这一行的行级属性（文字保住标题 / 列表），嵌入那一行
  ///    用裸 `\n`（属性归文字，嵌入行保持素净）；
  /// 2. 「只有属性、没有内容」的空行（表格抽取会在正文后面留一个这样的尾巴）
  ///    把属性**向上浮**到前面最近的内容行，自己丢掉 —— 这就是
  ///    `<h1>标<table>…</table></h1>` 里 `header:1` 回到「标」那一行的路径。
  ///    上浮时跳过「只放了嵌入」的行：属性属于标题 / 列表里的**文字**，不该
  ///    落到嵌入那一行。
  ///
  /// [suppressFirstLineAttrs] 为 **true**（落点在文档已有行的中间）时，粘贴的
  /// 第一行会并进文档里已有的那一行，**不**吃粘贴内容的行级属性 —— 理由见
  /// [_fitToContext]。只压制**第一个嵌入之前**那段文字（它才是并进原行的
  /// 部分）；嵌入把它后面的文字断成**新的一行**，那些文字仍保住行级样式。
  static List<Map<String, dynamic>> _isolateEmbeds(
    List<Map<String, dynamic>> ops, {
    required bool suppressFirstLineAttrs,
  }) {
    final lines = _pasteLines(ops);

    // 从后往前：把「只有属性的空行」的属性浮到前面的内容行。
    var pending = const <String, dynamic>{};
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      if (line.content.isEmpty) {
        if (line.attrs.isNotEmpty) {
          pending = line.attrs;
          line.dropped = true;
        }
        continue;
      }
      // 嵌入独占的那一行不吃上浮的属性，继续往前找文字行（见上面的说明）。
      if (line.isEmbedOnly && pending.isNotEmpty && line.attrs.isEmpty) {
        continue;
      }
      line.effective = line.attrs.isNotEmpty ? line.attrs : pending;
      pending = const <String, dynamic>{};
    }

    final out = <Map<String, dynamic>>[];
    var first = true;
    for (final line in lines) {
      if (line.dropped) continue;
      if (line.content.isEmpty) {
        // 真空白行（没有任何属性）原样保留。
        out.add(<String, dynamic>{'insert': '\n'});
        first = false;
        continue;
      }
      _emitLine(
        line.content,
        line.effective,
        out,
        suppressLeadingAttrs: first && suppressFirstLineAttrs,
      );
      first = false;
    }
    return out;
  }

  /// 把**一行**的内容按嵌入拆开写进 [out]：嵌入前后各断一行，文字段的行尾
  /// 带上这一行的行级属性 [attrs]。
  ///
  /// [suppressLeadingAttrs] 只压制**第一个嵌入之前**那个文字段的行尾属性
  /// （那一段会并进文档里已有的行，见 [_isolateEmbeds]）；之后的文字段都是
  /// 嵌入断出来的新行，照常带属性。
  static void _emitLine(
    List<Map<String, dynamic>> content,
    Map<String, dynamic> attrs,
    List<Map<String, dynamic>> out, {
    bool suppressLeadingAttrs = false,
  }) {
    var text = <Map<String, dynamic>>[];
    void flushText() {
      if (text.isEmpty) return;
      out.addAll(text);
      text = <Map<String, dynamic>>[];
    }

    // 第一个嵌入之前那段文字用的行级属性（被压制时为空）。
    Map<String, dynamic> leadingAttrs() =>
        suppressLeadingAttrs ? const <String, dynamic>{} : attrs;
    var embedded = false;

    for (final op in content) {
      if (op['insert'] is! Map) {
        text.add(op);
        continue;
      }
      flushText();
      // 嵌入前面得先有换行（开头位置不补 —— 由 [_fitToContext] 按落点决定
      // 要不要前导换行）。断行时带上这一行的行级属性，文字才不掉出标题 / 列表。
      if (out.isNotEmpty && !_endsWithNewline(out.last)) {
        final carry = embedded ? attrs : leadingAttrs();
        out.add(<String, dynamic>{
          'insert': '\n',
          if (carry.isNotEmpty) 'attributes': carry,
        });
      }
      out.add(op);
      // 嵌入独占一行：它后面那个换行不带属性 —— 属性归文字。
      out.add(<String, dynamic>{'insert': '\n'});
      embedded = true;
    }
    flushText();
    if (out.isNotEmpty && !_endsWithNewline(out.last)) {
      final carry = embedded ? attrs : leadingAttrs();
      out.add(<String, dynamic>{
        'insert': '\n',
        if (carry.isNotEmpty) 'attributes': carry,
      });
    }
  }

  /// 取 op 上的行级属性（丢掉行内属性，比如粗体 / 链接）。
  static Map<String, dynamic> _lineAttrsOf(Map<String, dynamic> op) {
    final attrs = op['attributes'];
    if (attrs is! Map || attrs.isEmpty) return const <String, dynamic>{};
    return <String, dynamic>{
      for (final entry in attrs.entries)
        if (_lineAttributes.contains(entry.key.toString()))
          entry.key.toString(): entry.value,
    };
  }

  static bool _endsWithNewline(Map<String, dynamic> op) {
    final data = op['insert'];
    // 嵌入结尾当然不算「以换行结尾」—— 它后面必须再补一个换行。
    return data is String && data.endsWith('\n');
  }

  /// 去掉最后一个 op 末尾的换行。只去**一个** —— 多段粘贴时前面的段落分隔
  /// 都留着，只有末段跟着落点行续写。
  static List<Map<String, dynamic>> _stripTrailingNewline(
    List<Map<String, dynamic>> ops,
  ) {
    final lastOp = ops.last;
    final data = lastOp['insert'];
    if (data is! String || !data.endsWith('\n')) return ops;
    final trimmed = data.substring(0, data.length - 1);
    final result = ops.sublist(0, ops.length - 1);
    if (trimmed.isNotEmpty) {
      result.add(<String, dynamic>{
        'insert': trimmed,
        if (lastOp['attributes'] is Map)
          'attributes': lastOp['attributes'] as Map,
      });
    }
    // 只有一个 op 且被削空 → 返回空列表，调用方插一个空 Delta 是无害的。
    return result;
  }

  /// 只处理**纯文本**粘贴。
  ///
  /// 默认通路已经能贴纯文本，那为什么还要接？因为默认通路会把换行原样塞进
  /// 一个段落里（Quill 的块就是行，`\n` 会切开），而文本里的**空行**应当
  /// 变成段落分隔。返回 null 表示「不改，用默认的」。
  static String? normalizePlainText(String plainText) {
    final trimmed = plainText.trim();
    if (trimmed.isEmpty) return null;
    // 没有换行 → 没有可规整的结构，交给默认通路。
    if (!trimmed.contains('\n')) return null;
    // 有换行 → 按空行分段、段内单换行也折成段（与 DocumentCodec.fromPlainText
    // 同一套规则，否则「粘贴进来的」与「存回去再打开」的形状会不一样）。
    final lines = trimmed
        .split('\n')
        .map((line) => line.trimRight())
        .toList();
    final result = <String>[];
    var blank = false;
    for (final line in lines) {
      if (line.trim().isEmpty) {
        blank = true;
        continue;
      }
      if (result.isNotEmpty && blank) result.add('');
      result.add(line);
      blank = false;
    }
    return result.isEmpty ? null : result.join('\n');
  }
}

/// [_pasteLines] 拆出来的一行：内容 op（不含行尾那个 `\n`）+ 行级属性。
///
/// 放在文件顶层（Dart 不允许类声明嵌在类里）。
class _PasteLine {
  _PasteLine(this.content, this.attrs);

  /// 这一行的内容 op（文字 / 嵌入），不含行尾的 `\n`。
  final List<Map<String, dynamic>> content;

  /// 行尾那个 `\n` 上的行级属性（`MailHtmlToDelta._splitLines` 口径）。
  final Map<String, dynamic> attrs;

  /// 行级属性上浮后被搬空的行，输出时跳过。
  bool dropped = false;

  /// 输出这一行时实际用的行级属性（自身有的优先，否则接住上浮来的）。
  Map<String, dynamic> effective = const <String, dynamic>{};

  /// 这一行是不是「只有嵌入、没有文字」。
  bool get isEmbedOnly =>
      content.isNotEmpty && content.every((op) => op['insert'] is Map);
}
