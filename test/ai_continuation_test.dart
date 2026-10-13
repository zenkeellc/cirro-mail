import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/inline_continuation.dart';

q.QuillController at(String text, int offset) => q.QuillController(
      document: q.Document.fromJson([{'insert': '$text\n'}]),
      selection: TextSelection.collapsed(offset: offset),
    );

/// 带**行级属性**的文档（如代码块、引用块）—— 模拟光标落在这种行里。
q.QuillController atStyled(
    String text, int offset, Map<String, dynamic> attributes) {
  return q.QuillController(
    document: q.Document.fromJson([
      {'insert': '$text\n', 'attributes': attributes},
    ]),
    selection: TextSelection.collapsed(offset: offset),
  );
}

/// 一封「用户写了一段 + 引用了原信」的邮件。
///
/// 形状照 `ComposeQuote` 认的那样来（见 `test/compose_quote_test.dart` 的
/// `user写了两行` 那条）：用户区在前、分隔线与引用在后，而 `mail-quote` 标记
/// 打在**每一行行尾那个 `\n`** 上 —— 分隔线 `---` 的文字本身不算标记的一部分，
/// 带标记的是**终止它那一行的换行**。少打这一层，`userEnd` 会把整个用户区也
/// 算成引用（这条夹具第一次就是这么错的）。
q.QuillController quoted(String user, {required String quote}) {
  final delta = <dynamic>[
    {'insert': user},
    {'insert': '\n---'},
    {'insert': '\n', 'attributes': <String, dynamic>{'mail-quote': true}},
    {'insert': quote, 'attributes': <String, dynamic>{'mail-quote': true}},
    {'insert': '\n', 'attributes': <String, dynamic>{'mail-quote': true}},
  ];
  return q.QuillController(
    document: q.Document.fromJson(delta),
    // 光标停在用户区末尾（`user` 之后那个 `\n` 之前）—— 续写只在这里触发。
    selection: TextSelection.collapsed(offset: user.length),
  );
}

void main() {
  test('开关关着 → 不请求', () {
    expect(
        InlineContinuation.shouldRequest(
            controller: at('这是一句写得差不多的话', 11),
            enabled: false,
            isGenerating: false),
        isFalse);
  });

  test('正在生成 → 不请求（避免叠加）', () {
    expect(
        InlineContinuation.shouldRequest(
            controller: at('这是一句写得差不多的话', 11),
            enabled: true,
            isGenerating: true),
        isFalse);
  });

  test('有选区 → 不请求', () {
    final c = q.QuillController(
      document: q.Document.fromJson([{'insert': '这是一句写得差不多的话\n'}]),
      selection: const TextSelection(baseOffset: 2, extentOffset: 6),
    );
    expect(
        InlineContinuation.shouldRequest(
            controller: c, enabled: true, isGenerating: false),
        isFalse);
  });

  test('光标在行中间（后面还有字）→ 不请求', () {
    expect(
        InlineContinuation.shouldRequest(
            controller: at('这是一句写得差不多的话', 5),
            enabled: true,
            isGenerating: false),
        isFalse);
  });

  test('当前行太短 → 不请求（刚敲两三个字不该被建议打断）', () {
    expect(
        InlineContinuation.shouldRequest(
            controller: at('短', 1), enabled: true, isGenerating: false),
        isFalse);
  });

  test('行尾且行足够长 → 请求', () {
    expect(
        InlineContinuation.shouldRequest(
            controller: at('这是一句写得差不多的话', 11),
            enabled: true,
            isGenerating: false),
        isTrue);
  });

  test('空文档 / 光标在开头 → 不请求', () {
    expect(
        InlineContinuation.shouldRequest(
            controller: at('', 0), enabled: true, isGenerating: false),
        isFalse);
  });

  group('build：整封邮件 + 光标标记', () {
    test('短文本：光标处插标记，无引用', () {
      final c = at('前面的话', 4);
      final input = InlineContinuation.build(c);
      expect(input.marked, '前面的话${InlineContinuation.marker}');
      expect(input.quoteTrimmed, isFalse);
      expect(input.userTrimmed, isFalse);
    });

    test('光标在行中间：标记落在光标那个字符之前', () {
      final c = at('前面的话', 2);
      expect(InlineContinuation.build(c).marked,
          '前面${InlineContinuation.marker}的话');
    });

    test('有引用：整封都给，标记在光标处，引用在标记之后', () {
      final c = quoted('写好了', quote: '引用原文');
      final input = InlineContinuation.build(c);
      expect(input.marked, startsWith('写好了${InlineContinuation.marker}'));
      expect(input.marked, contains('引用原文'), reason: '引用要进上下文');
      expect(input.quoteTrimmed, isFalse);
    });

    test('超预算：优先剪引用（用户区一个字不少）', () {
      final c = quoted('写好了', quote: '引' * 1000);
      final input = InlineContinuation.build(c, limit: 200);
      expect(input.quoteTrimmed, isTrue);
      expect(input.userTrimmed, isFalse, reason: '剪引用就够，别动用户区');
      expect(input.marked.length <= 200, isTrue);
      expect(input.marked, contains('写好了${InlineContinuation.marker}'));
      // 引用被从尾部截断，远端的内容不该还在。
      expect(input.marked, isNot(contains('引' * 300)));
    });

    test('连用户区都超预算：再剪用户区的头，标记仍在末尾', () {
      final c = quoted('前' * 500, quote: '引用原文');
      final input = InlineContinuation.build(c, limit: 80);
      expect(input.userTrimmed, isTrue);
      expect(input.marked.length <= 80, isTrue);
      expect(input.marked, endsWith(InlineContinuation.marker));
    });
  });

  test('接受建议：插到光标处，光标落到后面', () {
    final c = at('已经写好的话', 6);
    InlineContinuation.accept(c, '，还有一句');
    expect(c.document.toPlainText(), '已经写好的话，还有一句\n');
    expect(c.selection.extentOffset, 11); // 6 + '，还有一句'.length
  });

  test('接受空建议 → 什么都不做', () {
    final c = at('abc', 3);
    InlineContinuation.accept(c, '');
    expect(c.document.toPlainText(), 'abc\n');
  });

  test('光标移开 → 丢弃建议', () {
    final c = at('abcdefghij', 10);
    expect(
        InlineContinuation.shouldDiscard(suggestionAt: 5, controller: c), isTrue);
    expect(
        InlineContinuation.shouldDiscard(suggestionAt: 10, controller: c), isFalse);
  });

  // ---- M-4：代码块 / 引用块里不请求续写 ----
  test('M-4：光标在代码块行 → 不请求（不能往代码里塞自然语言）', () {
    expect(
        InlineContinuation.shouldRequest(
            controller: atStyled('这是一句足够长的代码注释', 12,
                {'code-block': true}),
            enabled: true,
            isGenerating: false),
        isFalse);
  });

  test('M-4：光标在引用块行 → 不请求', () {
    expect(
        InlineContinuation.shouldRequest(
            controller: atStyled('这是一句足够长的引用内容', 12,
                {'blockquote': true}),
            enabled: true,
            isGenerating: false),
        isFalse);
  });

  test('M-4：普通段落 → 仍然请求（别把规则放太宽）', () {
    expect(
        InlineContinuation.shouldRequest(
            controller: at('这是一句足够长的普通段落', 12),
            enabled: true,
            isGenerating: false),
        isTrue);
  });
}
