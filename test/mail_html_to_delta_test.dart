import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' show Document;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/html/delta_to_email_html.dart';
import 'package:mail_app/features/compose/html/email_html_sanitizer.dart';
import 'package:mail_app/features/compose/html/mail_html_to_delta.dart';

/// 把结果装进 Document —— 这是最硬的验收：装不进去编辑器就白屏。
Document _doc(List<Map<String, dynamic>> ops) => Document.fromJson(ops);


/// 取出一个 op 的**嵌入**部分；不是 Map（也就是普通文本行）时给 null。
///
/// 不要写 `o['insert'] as Map?` —— Dart 里把非 null 的 String 转成 `Map?`
/// 会直接抛类型错误，测试自己会炸在断言之前。
Map<dynamic, dynamic>? _embed(Map<String, dynamic> op) =>
    op['insert'] is Map ? op['insert'] as Map : null;

String _plain(List<Map<String, dynamic>> ops) => _doc(ops).toPlainText();

void main() {
  group('行内与块级', () {
    test('粗斜下划删除线代码都落成 Delta 属性', () {
      final ops = MailHtmlToDelta.convert(
        '<p><strong>b</strong><em>i</em><u>u</u><s>st</s><code>c</code></p>',
      );
      final attrs = ops
          .where((o) => o['attributes'] != null)
          .map((o) => o['attributes'] as Map)
          .toList();
      expect(attrs.any((a) => a['bold'] == true), isTrue);
      expect(attrs.any((a) => a['italic'] == true), isTrue);
      expect(attrs.any((a) => a['underline'] == true), isTrue);
      expect(attrs.any((a) => a['strike'] == true), isTrue);
      expect(attrs.any((a) => a['code'] == true), isTrue);
    });

    test('标题与对齐', () {
      final ops = MailHtmlToDelta.convert(
        '<h1>一</h1><h3>三</h3><p style="text-align:center">中</p>',
      );
      final attrs = ops
          .where((o) => o['attributes'] != null)
          .map((o) => o['attributes'] as Map)
          .toList();
      expect(attrs.any((a) => a['header'] == 1), isTrue);
      expect(attrs.any((a) => a['header'] == 3), isTrue);
      expect(attrs.any((a) => a['align'] == 'center'), isTrue);
    });

    test('无序列表与嵌套缩进', () {
      final ops = MailHtmlToDelta.convert(
        '<ul><li>甲<ul><li>子</li></ul></li></ul>',
      );
      final attrs = ops
          .where((o) => o['attributes'] != null)
          .map((o) => o['attributes'] as Map)
          .toList();
      expect(attrs.any((a) => a['list'] == 'bullet'), isTrue);
      expect(attrs.any((a) => a['list'] == 'bullet' && a['indent'] == 1), isTrue);
    });

    test('两个段落不许被并成一行', () {
      // 上游 `NodeExt.isBlock`（`node_ext.dart:31`）不含 `p`，不传
      // `isBlockValidator` 的话这条会拿到 `[{"insert":"甲乙\n"}]`。
      final ops = MailHtmlToDelta.convert('<p>甲</p><p>乙</p>');
      expect(
        ops.where((o) => o['insert'] == '\n').length,
        2,
        reason: '两段就该有两个行尾',
      );
      expect(_doc(ops).toPlainText(), '甲\n乙\n');
    });

    test('div 包着的段落仍然分段（blackNodesList 会把它拼平）', () {
      final ops = MailHtmlToDelta.convert('<div><p>甲</p><p>乙</p></div>');
      expect(_doc(ops).toPlainText(), '甲\n乙\n');
    });

    test('换行与文字拆成各自的 op（下游按「insert == \n」判行尾）', () {
      final ops = MailHtmlToDelta.convert('<h1>标</h1><p>文</p>');
      for (final op in ops) {
        final data = op['insert'];
        if (data is String && data != '\n') {
          expect(data.contains('\n'), isFalse, reason: '文字 op 里不许夹换行');
        }
      }
    });

    test('不会在末尾多留一个空段落（Word/Gmail 的 div>p 形状）', () {
      final ops = MailHtmlToDelta.convert(
        '<div style="border:none;padding:3pt"><p>甲</p><p>乙</p></div>',
      );
      expect(_doc(ops).toPlainText(), '甲\n乙\n', reason: '末尾只该有一个 \\n');
    });

    test('引用与代码块', () {
      final ops = MailHtmlToDelta.convert(
        '<blockquote>引</blockquote><pre>code</pre>',
      );
      final attrs = ops
          .where((o) => o['attributes'] != null)
          .map((o) => o['attributes'] as Map)
          .toList();
      expect(attrs.any((a) => a['blockquote'] == true), isTrue);
      expect(attrs.any((a) => a['code-block'] == true), isTrue);
    });

    test('链接保留，危险协议被删掉', () {
      final good = MailHtmlToDelta.convert('<a href="https://e.com">x</a>');
      expect(
        good.any((o) => (o['attributes'] is Map ? o['attributes'] as Map : null)?['link'] == 'https://e.com'),
        isTrue,
      );

      final bad = MailHtmlToDelta.convert('<a href="javascript:alert(1)">x</a>');
      final encoded = jsonEncode(bad);
      expect(encoded, isNot(contains('javascript:')));
    });

    test('图片落成 image 嵌入（base64 与 http 都认）', () {
      final base64 = MailHtmlToDelta.convert(
        '<p><img src="data:image/png;base64,AAAA"></p>',
      );
      expect(
        base64.any((o) => _embed(o)?['image'] == 'data:image/png;base64,AAAA'),
        isTrue,
      );
      final http = MailHtmlToDelta.convert('<p><img src="https://e.com/a.png"></p>');
      expect(
        http.any((o) => _embed(o)?['image'] == 'https://e.com/a.png'),
        isTrue,
      );
    });
  });

  group('上游认不出的容器（会整段吞掉内容）', () {
    test('section / article / figure 里的东西不许消失', () {
      // 上游 `resolveCurrentElement`（`html_to_operation.dart:33`）是一串
      // `if (element.isXxx)`，白名单外的标签名一个都不匹配 → 返回空操作列表
      // → **连孩子都不会被访问**。网页上右键复制出来的 HTML 里
      // `<section>`/`<article>`/`<figure>` 很常见。
      expect(_plain(MailHtmlToDelta.convert('<section>甲</section>')), '甲\n');
      expect(
        _plain(MailHtmlToDelta.convert('<article><p>甲</p><p>乙</p></article>')),
        '甲\n乙\n',
      );
      final figure = MailHtmlToDelta.convert(
        '<figure><img src="https://e.com/a.png"></figure>',
      );
      expect(
        figure.any((o) => _embed(o)?['image'] == 'https://e.com/a.png'),
        isTrue,
      );
    });

    test('更冷门的行内标签也不吞内容', () {
      // 用**精确**的 `_plain` 断言，不用 `contains('甲')`：后者在
      // 「标签被剥成空壳」或「后半段被吞」时照样通过。
      for (final html in <String>[
        '<mark>甲</mark>',
        '<small>甲</small>',
        '<kbd>甲</kbd>',
        '<q>甲</q>',
        '<abbr title="x">甲</abbr>',
        '<cite>甲</cite>',
        '<center>甲</center>',
      ]) {
        expect(_plain(MailHtmlToDelta.convert(html)), '甲\n', reason: html);
      }
      // `<dl>` 的两个条目（`dt`/`dd` 不在上游白名单里）会被剥壳后连成一行。
      expect(_plain(MailHtmlToDelta.convert('<dl><dt>甲</dt><dd>乙</dd></dl>')), '甲乙\n');
    });

    test('<hr> 落成一段 `---`（导出时再变回 <hr>）', () {
      final ops = MailHtmlToDelta.convert('<p>前</p><hr><p>后</p>');
      expect(_plain(ops), '前\n---\n后\n');
      // `---` 必须是**独占一行**的段落，不能粘在别的行上。
      final index = ops.indexWhere((o) => o['insert'] == '---');
      expect(ops[index + 1]['insert'], '\n');
    });
  });

  group('引用块分段（上游会把多段压成一行）', () {
    test('两段引用是两行', () {
      final ops = MailHtmlToDelta.convert(
        '<blockquote><p>原文一</p><p>原文二</p></blockquote>',
      );
      expect(_plain(ops), '原文一\n原文二\n');
      expect(
        ops.where((o) => (o['attributes'] as Map?)?['blockquote'] == true).length,
        2,
        reason: '两行就该有两个引用行尾',
      );
    });

    test('Gmail / Apple Mail 的 div 形状也一样（回复引用的常态）', () {
      expect(
        _plain(
          MailHtmlToDelta.convert(
            '<blockquote><div>原文一</div><div>原文二</div></blockquote>',
          ),
        ),
        '原文一\n原文二\n',
      );
    });

    test('嵌套引用不丢层级（都落成引用行，顺序不变）', () {
      expect(
        _plain(
          MailHtmlToDelta.convert(
            '<blockquote><p>外一</p><blockquote><p>内</p></blockquote>'
            '<p>外二</p></blockquote>',
          ),
        ),
        '外一\n内\n外二\n',
      );
    });

    test('列表里的每个条目各占一行', () {
      expect(
        _plain(
          MailHtmlToDelta.convert('<blockquote><ul><li>甲</li><li>乙</li></ul></blockquote>'),
        ),
        '甲\n乙\n',
      );
    });

    test('空的引用块不留下一个空行', () {
      expect(_plain(MailHtmlToDelta.convert('<blockquote></blockquote><p>后</p>')), '后\n');
    });

    test('引用块与表格：表格仍是块嵌入，不粘在引用里', () {
      final ops = MailHtmlToDelta.convert(
        '<blockquote><p>原文</p><table><tr><td>格</td></tr></table></blockquote>',
      );
      final index = ops.indexWhere((o) => o['insert'] is Map);
      expect(index, greaterThan(0));
      expect(ops[index + 1]['insert'], '\n');
      expect(() => _doc(ops), returnsNormally);
    });
  });

  /// 批 B 只把颜色/字号放开到 `paragraphToOp` / `headerToOp` / `spanToOp`
  /// 那几条路（它们给 `processNode` 传了 `addSpanAttrs: true`）——
  /// `blockquoteToOp` / `codeblockToOp` **没传**，于是引用行 / 代码行上的
  /// `color` / `background` / `size` 一进这两个容器就被悄悄丢掉（导出端照常
  /// 把它们写出去，所以是「发出去了、回不来」）。`_QuoteLineOperations`
  /// 把这两处补上，与相邻那几条路对齐。
  ///
  /// **这一组的任务是双向的**：既钉住「引用 / 代码行上的颜色活着」，
  /// 也钉住「`indent` / `align` 没被顺手搬到文字 run 上」—— 后者是这次
  /// 改 `addSpanAttrs` 最需要防的副作用。
  group('引用块 / 代码块行内颜色（addSpanAttrs 的边）', () {
    test('引用行里的 color 不再丢（导入）', () {
      final ops = MailHtmlToDelta.convert(
        '<blockquote><p>普通行</p>'
        '<p><span style="color:#d93025">红色行</span></p></blockquote>',
      );
      expect(
        ops.any((o) =>
            o['insert'] == '红色行' &&
            (o['attributes'] as Map?)?['color'] == '#d93025'),
        isTrue,
      );
      // 普通行没有被牵连上颜色。
      expect(
        ops.any((o) =>
            o['insert'] == '普通行' && o['attributes'] != null),
        isFalse,
      );
      expect(() => _doc(ops), returnsNormally);
    });

    test('代码块行里的 color 不再丢（导入）', () {
      final ops = MailHtmlToDelta.convert(
        '<pre><span style="color:#d93025">代码</span></pre>',
      );
      expect(
        ops.any((o) =>
            o['insert'] == '代码' &&
            (o['attributes'] as Map?)?['color'] == '#d93025'),
        isTrue,
      );
      expect(
        ops.any((o) => (o['attributes'] as Map?)?['code-block'] == true),
        isTrue,
      );
      expect(() => _doc(ops), returnsNormally);
    });

    test('颜色 / 高亮 / 字号经导出再导入都还在（引用行往返）', () {
      List<Map<String, dynamic>> roundTrip(Map<String, dynamic> runAttrs) {
        final html = DeltaToEmailHtml.convert(<dynamic>[
          {'insert': '行', 'attributes': runAttrs},
          {'insert': '\n', 'attributes': {'blockquote': true}},
        ]);
        return MailHtmlToDelta.convert(html);
      }

      for (final attrs in <Map<String, dynamic>>[
        {'color': '#d93025'},
        {'background': '#e6f4ea'},
        {'size': '19'},
      ]) {
        final back = roundTrip(attrs);
        final key = attrs.keys.first;
        expect(
          back.any((o) =>
              o['insert'] == '行' &&
              (o['attributes'] as Map?)?[key] == attrs[key]),
          isTrue,
          reason: '引用行上的 $attrs 往返后必须还在',
        );
      }

      // **`background` 这一格由导出端翻成 `background-color`**（行内属性
      // 一律经 `_renderInline` 拼 CSS 属性名），所以它绕开了净化器对
      // `background` **简写**的拦截。带简写 `<span>` 的原始 HTML 直连
      // [MailHtmlToDelta] 时读不到高亮 —— 那是净化器的既有行为，
      // 与本组要钉的两条通路无关，这里只把事实写下来，不改它。
      expect(
        EmailHtmlSanitizer.toSafeSubset(
          '<p><span style="background:#e6f4ea">x</span></p>',
        ),
        isNot(contains('background')),
        reason: '简写照旧被削；往返走的是 background-color 那条',
      );
    });

    test('引用行的 \\n 依旧带 blockquote，文字 run 不背 indent（往返）', () {
      final html = DeltaToEmailHtml.convert(<dynamic>[
        {'insert': '红', 'attributes': {'color': '#d93025'}},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ]);
      final back = MailHtmlToDelta.convert(html);

      final newlines =
          back.where((o) => o['insert'] == '\n').toList();
      expect(newlines.length, 1, reason: '一条引用行就该只有一个行尾');
      expect(newlines.single['attributes'], <String, dynamic>{'blockquote': true});

      final run = back.firstWhere((o) => o['insert'] == '红');
      expect(run['attributes'], <String, dynamic>{'color': '#d93025'},
          reason: '文字 run 只该有颜色，indent/align 不许迁移过来');
    });

    test('对齐与缩进不被搬上文字 run（导入侧的类型化断言）', () {
      // 块级属性的落点是**行尾 `\\n`**，不是文字 run。
      final ops = MailHtmlToDelta.convert(
        '<blockquote><p style="text-align:center;padding-left:32px">'
        '<span style="color:#d93025">中</span></p></blockquote>',
      );
      final run = ops.firstWhere((o) => o['insert'] == '中');
      expect(
        run['attributes'],
        <String, dynamic>{'color': '#d93025'},
        reason: '文字 run 上只该有颜色',
      );
      final tail = ops.firstWhere(
        (o) => o['insert'] == '\n' && o['attributes'] != null,
      );
      expect(
        (tail['attributes'] as Map).containsKey('align'),
        isFalse,
        reason: '引用行的对齐本来就不落（见 delta_to_email_html 的已知限制），'
            '但也绝不能因为这次改动跑到文字 run 上',
      );
    });

    test('容器外的行内颜色不受影响（对照组）', () {
      // 这四种今天就是好的；引用/代码的改动不许把它们带坏。
      for (final html in <String>[
        '<p><span style="color:#d93025">p</span></p>',
        '<div><span style="color:#d93025">d</span></div>',
        '<h1><span style="color:#d93025">h</span></h1>',
        '<ul><li><span style="color:#d93025">i</span></li></ul>',
      ]) {
        expect(
          MailHtmlToDelta.convert(html).any((o) =>
              (o['attributes'] as Map?)?['color'] == '#d93025'),
          isTrue,
          reason: html,
        );
      }
      // 行级属性各自还在原来的位置（`h1` 的 header、`li` 的 list）。
      final h1 = MailHtmlToDelta.convert(
        '<h1><span style="color:#d93025">h</span></h1>',
      );
      expect(h1.any((o) => (o['attributes'] as Map?)?['header'] == 1), isTrue);
      final li = MailHtmlToDelta.convert(
        '<ul><li><span style="color:#d93025">i</span></li></ul>',
      );
      expect(
        li.any((o) => (o['attributes'] as Map?)?['list'] == 'bullet'),
        isTrue,
      );
    });

    test('嵌套引用里的颜色也活着，层级不串', () {
      // 用 `color`（而不是 `background` **简写**）：后者会被净化器削掉，
      // 与本次要测的容器无关，只会让这条用例测到别的既有行为。
      final ops = MailHtmlToDelta.convert(
        '<blockquote><p>外一</p><blockquote>'
        '<p><span style="color:#d93025">内</span></p></blockquote>'
        '<p>外二</p></blockquote>',
      );
      expect(_plain(ops), '外一\n内\n外二\n');
      expect(
        ops.any((o) =>
            o['insert'] == '内' &&
            (o['attributes'] as Map?)?['color'] == '#d93025'),
        isTrue,
      );
      expect(
        ops.where((o) => (o['attributes'] as Map?)?['blockquote'] == true)
            .length,
        3,
        reason: '三行引用就该有三个引用行尾',
      );
    });
  });

  group('属性过滤（spec 决策 5：中等子集）', () {
    test('行高丢掉，颜色与字号留下（批 B 反向）', () {
      final ops = MailHtmlToDelta.convert(
        '<p><span style="color:#d93025;font-size:19px;line-height:2">红</span></p>',
      );
      final encoded = jsonEncode(ops);
      expect(encoded, contains('#d93025'));
      expect(encoded, contains('"size":"19"'));
      expect(encoded, isNot(contains('line-height')));
    });

    test('字号被夹到四个档位（120px 不能原样进文档）', () {
      final ops = MailHtmlToDelta.convert(
        '<p><span style="font-size:120px">巨</span></p>',
      );
      final encoded = jsonEncode(ops);
      expect(encoded, contains('"size":"24"'));
      expect(encoded, isNot(contains('"size":"120"')));
    });

    test('段落上的 padding-left 落成裸 indent，列表里的 indent 也留下', () {
      final ops = MailHtmlToDelta.convert(
        '<p style="padding-left:32px">缩进的段</p>'
        '<ul><li>甲<ul><li>子</li></ul></li></ul>',
      );
      final attrs = ops
          .where((o) => o['attributes'] != null)
          .map((o) => o['attributes'] as Map)
          .toList();
      // 段落那条：**裸 indent**（没有 list）。spec 的批 A 明确要放开它 ——
      // 它现在有唯一的来源（工具栏的缩进按钮）与唯一的载体
      // （`padding-left`），不会与列表缩进混淆。
      expect(
        attrs.any((a) => a['indent'] == 2 && a['list'] == null),
        isTrue,
        reason: '32px / 16 = 2 级',
      );
      expect(attrs.any((a) => a['indent'] == 1 && a['list'] != null), isTrue);
    });

    test('上下标保留（script），行高仍丢', () {
      final ops = MailHtmlToDelta.convert(
        '<p>x<sup>2</sup>y<sub>1</sub><span style="line-height:2">z</span></p>',
      );
      final encoded = jsonEncode(ops);
      expect(encoded, contains('"script":"super"'));
      expect(encoded, contains('"script":"sub"'));
      expect(encoded, isNot(contains('line-height')));
      expect(() => _doc(ops), returnsNormally);
    });
  });

  group('表格（哨兵法）', () {
    test('表格落成 x-email-table 块，单元格文字不回流成正文', () {
      final ops = MailHtmlToDelta.convert(
        '<p>见下表：</p>'
        '<table border="1"><tbody><tr><td>格1</td><td>格2</td></tr></tbody></table>'
        '<p>表后的话</p>',
      );
      final embed = ops.firstWhere(
        (o) => _embed(o)?['x-email-table'] != null,
        orElse: () => <String, dynamic>{},
      );
      expect(embed, isNotEmpty, reason: '表格必须落成块嵌入');
      final data = _embed(embed)!['x-email-table'] as String;
      expect(data, contains('<table'));
      expect(data, contains('格2'));

      final text = _plain(ops);
      expect(text, contains('见下表'));
      expect(text, contains('表后的话'));
      expect(text, isNot(contains('格1')), reason: '单元格文字不得重复进正文');
    });

    test('块嵌入独占一行（否则编辑器白屏）', () {
      final ops = MailHtmlToDelta.convert(
        '<p>前</p><table><tr><td>a</td></tr></table><p>后</p>',
      );
      final index = ops.indexWhere((o) => o['insert'] is Map);
      expect(index, greaterThan(0));
      expect(
        (ops[index - 1]['insert'] as String).endsWith('\n'),
        isTrue,
        reason: '块嵌入前一个 op 必须以换行结尾',
      );
      expect(ops[index + 1]['insert'], '\n', reason: '块嵌入之后必须立即结束该行');

      // 最硬的验收：能装进 Document
      expect(() => _doc(ops), returnsNormally);
    });

    test('开头就是表格', () {
      final ops = MailHtmlToDelta.convert(
        '<table><tr><td>a</td></tr></table><p>后面</p>',
      );
      expect(ops.first['insert'], isA<Map>());
      expect(() => _doc(ops), returnsNormally);
      expect(_plain(ops), contains('后面'));
    });

    test('两个表格各自成块', () {
      final ops = MailHtmlToDelta.convert(
        '<table><tr><td>甲</td></tr></table><p>中间</p>'
        '<table><tr><td>乙</td></tr></table>',
      );
      final embeds =
          ops.where((o) => _embed(o)?['x-email-table'] != null);
      expect(embeds.length, 2);
      expect(() => _doc(ops), returnsNormally);
      expect(_plain(ops), contains('中间'));
    });

    test('表格里的危险内容在落库前被净化', () {
      final ops = MailHtmlToDelta.convert(
        '<table><tr><td><script>x()</script>文字</td></tr></table>',
      );
      final data = ops.firstWhere((o) => _embed(o)?['x-email-table'] != null);
      expect(_embed(data)!['x-email-table'], isNot(contains('script')));
    });

    test('空表格不产生块嵌入（没法编辑的空网格只会让用户困惑）', () {
      final ops = MailHtmlToDelta.convert('<p>前</p><table></table><p>后</p>');
      expect(ops.any((o) => o['insert'] is Map), isFalse);
    });
  });

  group('健壮性', () {
    test('空串与纯空白给出一份可编辑的最小文档', () {
      for (final input in <String>['', '   ', '\n\n']) {
        final ops = MailHtmlToDelta.convert(input);
        expect(() => _doc(ops), returnsNormally, reason: '输入=$input');
        expect(ops, isNotEmpty);
      }
    });

    test('畸形与敌意 HTML 一律不抛异常', () {
      const samples = <String>[
        '<p>a<span>b</p></span>',
        '<table><tr><td>未闭合',
        '<div><style>p{}</style><script>x()</script>正文</div>',
        '<td>游离单元格</td>',
        '<hr>',
        '纯文本没有标签',
        '<a href="vbscript:x">坏链</a>',
        '<font color="red" size="5">font</font>',
      ];
      for (final sample in samples) {
        expect(
          () => _doc(MailHtmlToDelta.convert(sample)),
          returnsNormally,
          reason: '样本=$sample',
        );
      }
    });

    test('文档末尾以换行收尾（否则光标无处落脚）', () {
      final ops = MailHtmlToDelta.convert('<p>一句话</p>');
      expect((ops.last['insert'] as String).endsWith('\n'), isTrue);
    });
  });

  group('质量审查修正（崩溃 / 属性 / 哨兵 / 注释 / 空插入）', () {
    test('超长数字的假哨兵不许抛（int.parse → tryParse + 位数守卫）', () {
      // 19 位以上纯数字会让 `int.parse` 抛
      // `FormatException: Positive input exceeds the limit of integer`。
      // 这条入口吃的是剪贴板 / 别人的邮件，一崩就是写信页白屏。
      final ops = MailHtmlToDelta.convert(
        '<p>甲&#xE000;99999999999999999999&#xE000;乙</p>'
        '<table><tr><td>格</td></tr></table>',
      );
      expect(() => _doc(ops), returnsNormally);
      // 那串数字是用户正文，必须原样留在文本里，不被当成标记吞掉。
      expect(_plain(ops), contains('甲99999999999999999999乙'));
      // 真表格照常落成嵌入。
      expect(ops.any((o) => _embed(o)?['x-email-table'] != null), isTrue);
    });

    test('表格切开的运行段继承 attributes（加粗、链接）', () {
      final bold = MailHtmlToDelta.convert(
        '<p><b>甲<table><tr><td>格</td></tr></table>乙</b></p>',
      );
      final boldAttrs = bold
          .where((o) => o['insert'] == '乙')
          .map((o) => o['attributes'] as Map?);
      expect(boldAttrs.length, 1);
      expect(boldAttrs.first?['bold'], isTrue, reason: '乙 必须还是加粗的');

      final link = MailHtmlToDelta.convert(
        '<p><a href="https://x.com">前<table><tr><td>格</td></tr></table>后</a></p>',
      );
      final linkAttrs = link
          .where((o) => o['insert'] == '后')
          .map((o) => o['attributes'] as Map?);
      expect(linkAttrs.length, 1);
      expect(linkAttrs.first?['link'], 'https://x.com', reason: '后 必须还有链接');
    });

    test('末行带属性的 \\n 不被削掉（header / list 保住）', () {
      final h1 = MailHtmlToDelta.convert(
        '<h1>标<table><tr><td>格</td></tr></table></h1>',
      );
      expect(
        h1.any((o) => (o['attributes'] as Map?)?['header'] == 1),
        isTrue,
        reason: 'header 不能整条消失',
      );

      final ul = MailHtmlToDelta.convert(
        '<ul><li>项<table><tr><td>格</td></tr></table></li></ul>',
      );
      expect(
        ul.any((o) => (o['attributes'] as Map?)?['list'] == 'bullet'),
        isTrue,
        reason: 'list 不能整条消失',
      );
    });

    test('正文里的哨兵码位被剥掉，只当普通文字', () {
      // （a）有表格时：同一张表格只能出现一次，不许被复制进正文中间。
      final withTable = MailHtmlToDelta.convert(
        '<p>甲&#xE000;0&#xE000;乙</p><table><tr><td>格</td></tr></table>',
      );
      expect(
        withTable.where((o) => _embed(o)?['x-email-table'] != null).length,
        1,
        reason: '表格只该落成一个嵌入',
      );
      expect(_plain(withTable), contains('甲0乙'));

      // （b）没有表格时：哨兵字面量不许进 Delta。
      final noTable = MailHtmlToDelta.convert('<p>甲&#xE000;0&#xE000;乙</p>');
      expect(jsonEncode(noTable), isNot(contains('')));
      expect(jsonEncode(noTable), isNot(contains('')));
      expect(_plain(noTable), '甲0乙\n');

      // 行内代码的哨兵同理：正文里写 U+E002 不许把后半段吃成 code 属性。
      final codeMark = MailHtmlToDelta.convert('<p>甲&#xE002;乙</p>');
      expect(jsonEncode(codeMark), isNot(contains('')));
      expect(_plain(codeMark), '甲乙\n');
    });

    test('注释节点与空壳元素不算「有内容」，不产生空引用行', () {
      // `<!--x-->` 在 package:html 里 `text` 非 null，旧实现会判成有内容。
      expect(_plain(MailHtmlToDelta.convert('<blockquote><!--x--></blockquote>')), '\n');
      // 与空引用块（整体 remove）行为一致：都只剩收尾换行。
      expect(_plain(MailHtmlToDelta.convert('<blockquote></blockquote>')), '\n');
      // 空 `<span>` 壳不该多出一行。
      expect(
        _plain(
          MailHtmlToDelta.convert('<blockquote><span></span><p>甲</p></blockquote>'),
        ),
        '甲\n',
      );
    });

    test('空 insert 统一剔除（空的 <code> 记号要留）', () {
      final code = MailHtmlToDelta.convert('<p>前<code></code>后</p>');
      // 空 code 的「开启记号」`{"insert":"", code:true}` 保留（它是属性载体）。
      expect(
        code.any((o) => o['insert'] == '' && (o['attributes'] as Map?)?['code'] == true),
        isTrue,
      );
      expect(
        code.where((o) => o['insert'] == '' && o['attributes'] == null),
        isEmpty,
        reason: '空 insert + 空属性一律丢',
      );

      final video = MailHtmlToDelta.convert('<video src="https://e.com/v.mp4"></video>');
      expect(video.any((o) => o['insert'] == ''), isFalse);
      expect(() => _doc(video), returnsNormally);
    });

    test('深嵌套输入不抛（块嵌入不变量 + 收尾换行都成立）', () {
      for (final n in <int>[2000, 5000]) {
        final html = '${'<blockquote>' * n}<p>层</p>${'</blockquote>' * n}';
        final ops = MailHtmlToDelta.convert(html);
        expect(() => _doc(ops), returnsNormally, reason: 'n=$n');
        expect((ops.last['insert'] as String).endsWith('\n'), isTrue, reason: 'n=$n');
      }
    });

    test('深度超限 → 降级成纯文本段落，内容不丢、不抛', () {
      // **为什么 n 取 1500**：上限是 1000，`convert` 的预检在**解析之前**就判超限、
      // 直接走降级，所以 1500 和 15 万一样快（毫秒级）。真正会爆栈/卡住的
      // n（8 千起明显变慢、10 万约 192 秒）只在探针里手动验证过，**不进 CI** ——
      // 这条只断言「预检触发 → 走降级 → 内容还在」这条通路。
      final n = 1500;
      final html = '${'<div>' * n}<p>Hello &amp; &lt;b&gt; world</p>${'</div>' * n}';
      final ops = MailHtmlToDelta.convert(html);
      // 内容一个字不丢（实体解回原文），格式整体丢掉。
      expect(_plain(ops), 'Hello & <b> world\n');
      // 仍然是一份能装进编辑器的文档。
      expect(() => _doc(ops), returnsNormally);
      // 并且是**普通段落**，没有残留任何块级属性（表格 / 引用 / 标题都没有）。
      expect(
        ops.where((o) => o['attributes'] != null),
        isEmpty,
        reason: '降级产物是纯文本，不该有任何行内/行级属性',
      );
    });

    test('深度预检不吃「本来就浅」的输入：真实回复链照旧逐字节保留', () {
      // 仿 Gmail / Apple Mail 的 「div > 文字 + blockquote > p」：只有 3 层，
      // 远在 1000 之下 —— 必须走正常通路（有 blockquote 属性），不能降级。
      final ops = MailHtmlToDelta.convert(
        '<div><p>我的回复</p>'
        '<blockquote><div><p>原信第一行</p><p>原信第二行</p></div></blockquote>'
        '</div>',
      );
      expect(_plain(ops), '我的回复\n原信第一行\n原信第二行\n');
      expect(
        ops.any((o) => (o['attributes'] as Map?)?['blockquote'] == true),
        isTrue,
        reason: '浅输入必须保留引用块属性',
      );
    });

    test('fuzz：畸形 / 超长 / 控制字符一律不抛且能装进 Document', () {
      final samples = <String>[
        '<p>甲\r\n乙</p>',
        '<p>甲\u0000乙</p>',
        '<p>${'甲' * 50000}</p>',
        // 下面三条的深度都在预检上限（1000）**以下**：这条 fuzz 想覆盖的是
        // 「畸形但**还能解析**」的输入（净化 / 剪枝 / 上游转换器的通路），
        // 不是「超限降级」那条通路（那条另有专门用例）。原来的 2000/5000
        // 会走降级，等于这条用例测不到它本来想测的东西。
        '<p>${'<b>' * 800}甲${'</b>' * 800}</p>',
        '${'<table><tr><td>x</td></tr>' * 200}</table>',
        '${'<div>' * 800}<p>x</p>${'</div>' * 800}',
        '${'<span>' * 800}<p>x</p>${'</span>' * 800}',
        '${'<blockquote>' * 800}<p>x</p>${'</blockquote>' * 800}',
        '<div><p>未闭合<table><tr><td>',
        '<a href="javascript:\u0000x">x</a>',
        '<p>&#xE000;0&#xE000;</p><p>&#xE002;</p>',
      ];
      for (var i = 0; i < samples.length; i++) {
        final sample = samples[i];
        expect(
          () => _doc(MailHtmlToDelta.convert(sample)),
          returnsNormally,
          reason: '样本 #$i',
        );
      }
    });

    /// [_maxNestingDepth] 这一档**不是死的**，但它生效的区间很窄，
    /// 而上面那条 fuzz 只断言「不抛」—— 把 200 改成别的数、或者把封顶整段
    /// 删掉，它一条都不会红。这条把那段区间的两端钉住，免得以后误以为
    /// 200 可以随手调。
    ///
    /// 实测（`'<div>'*n + '<p>MARK</p>' + '</div>'*n`）：
    /// - `n ≤ 197` 正常通路，MARK 保住；
    /// - `n = 198…998` 预检放行（原始深度 ≤ 999），解析后元素深度
    ///   （`html > body > n 个 div > p`）越过 200，**MARK 整棵丢光**；
    /// - `n ≥ 999` 预检就拦下走降级，MARK 反而保住。
    test('深度封顶生效的那一档：198…998 层丢内容，≤197 与 ≥999 都保住', () {
      String plainAt(int n) => _plain(MailHtmlToDelta.convert(
            '<body>${'<div>' * n}<p>MARK</p>${'</div>' * n}</body>',
          ));

      expect(plainAt(197), contains('MARK'), reason: '正常通路的边界');
      expect(plainAt(198), isNot(contains('MARK')),
          reason: '预检放行（原始深度 199 < 1000），但解析后的元素深度越过 200');
      expect(plainAt(998), isNot(contains('MARK')), reason: '这一档的另一端');
      expect(plainAt(999), contains('MARK'),
          reason: '原始深度 1000 触发预检 → 走降级通路，正文反而保住。'
              '这与上一行只差一层却结果相反，是两道阈值不齐（200 vs 1000）所致');
    });
  });
}
