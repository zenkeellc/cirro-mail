import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/html/delta_to_email_html.dart';
import 'package:mail_app/features/compose/html/mail_html_to_delta.dart';

/// 把一行文字 + 行属性拼成 Delta（每个测试都用它，省得重复写 \n）。
List<dynamic> _line(String text, [Map<String, dynamic>? attrs]) => <dynamic>[
      <String, dynamic>{'insert': text},
      <String, dynamic>{'insert': '\n', 'attributes': ?attrs},
    ];

void main() {
  group('段落与转义', () {
    test('一段普通文字', () {
      expect(
        DeltaToEmailHtml.convert(_line('你好')),
        '<p style="margin:0 0 12px 0">你好</p>',
      );
    });

    test('空段落输出 <br>（邮件客户端会吃掉空的 <p>）', () {
      expect(
        DeltaToEmailHtml.convert(_line('')),
        '<p style="margin:0 0 12px 0"><br></p>',
      );
    });

    test('文本里的尖括号与引号被实体化', () {
      expect(
        DeltaToEmailHtml.convert(_line('a<b>&"c\'')),
        '<p style="margin:0 0 12px 0">a&lt;b&gt;&amp;&quot;c&#39;</p>',
      );
    });
  });

  group('行内格式', () {
    test('粗斜下划删除线代码', () {
      final delta = <dynamic>[
        {'insert': 'a', 'attributes': {'bold': true}},
        {'insert': 'b', 'attributes': {'italic': true}},
        {'insert': 'c', 'attributes': {'underline': true}},
        {'insert': 'd', 'attributes': {'strike': true}},
        {'insert': 'e', 'attributes': {'code': true}},
        {'insert': '\n'},
      ];
      expect(
        DeltaToEmailHtml.convert(delta),
        '<p style="margin:0 0 12px 0"><strong>a</strong><em>b</em><u>c</u>'
        '<s>d</s><code>e</code></p>',
      );
    });

    test('链接带内联样式，URL 里的引号被转义', () {
      final delta = <dynamic>[
        {'insert': '点', 'attributes': {'link': 'https://e.com/?q="x"'}},
        {'insert': '\n'},
      ];
      final html = DeltaToEmailHtml.convert(delta);
      expect(html, contains('<a href="https://e.com/?q=&quot;x&quot;"'));
      expect(html, contains('color:#1A73E8'));
      expect(html, isNot(contains('href="https://e.com/?q="x""')));
    });

    test('上标 / 下标各自成标签', () {
      final delta = <dynamic>[
        {'insert': 'x'},
        {'insert': '2', 'attributes': {'script': 'super'}},
        {'insert': 'y'},
        {'insert': '1', 'attributes': {'script': 'sub'}},
        {'insert': '\n'},
      ];
      expect(
        DeltaToEmailHtml.convert(delta),
        '<p style="margin:0 0 12px 0">x<sup>2</sup>y<sub>1</sub></p>',
      );
    });

    test('认不出的 script 值不产标签', () {
      // 值域只有 `super` / `sub`（上游解析器硬编码这两个字符串）。别的值一律
      // 当没有 —— 这个字符串会进 `style`/标签名，不白名单就等于把标签名交给
      // 不可信输入（与 `_aligns` 同一条规矩）。
      //
      // 逐个都要试：拼标签名的写法（`'<$v>'`）只要**有一个**值溜进去就成洞，
      // 只试一个对抗值证明不了白名单的完整性。
      for (final bad in <Object?>[
        'sup"><script>alert(1)</script>', // 想越出标签名
        'SUPER', // 大小写：全等比较要挡住
        'sup',
        'sub2',
        '',
        42,
        true,
        null,
      ]) {
        final delta = <dynamic>[
          {'insert': 'x', 'attributes': {'script': bad}},
          {'insert': '\n'},
        ];
        expect(
          DeltaToEmailHtml.convert(delta),
          '<p style="margin:0 0 12px 0">x</p>',
          reason: 'script=$bad',
        );
      }
    });

    test('上标与链接同行：两层都在，链接在外', () {
      // 这条钉的是「script 与 link 同时挂在一个 run 上时两样都不丢」。
      // 断言用 `contains` 而不是全等：批 B 的 B4 会往这条链里插
      // 颜色/字号三层并重排中间那几层，但 **`link` 仍在最外、`sup` 仍挂在
      // 它里面**（spec §4.1），所以这两条到 B4 之后照样成立。
      final delta = <dynamic>[
        {'insert': '2', 'attributes': {'script': 'super', 'link': 'https://e.com'}},
        {'insert': '\n'},
      ];
      final html = DeltaToEmailHtml.convert(delta);
      expect(html, contains('<sup>2</sup>'));
      expect(html, contains('<a href="https://e.com"'));
    });

    test('颜色 / 高亮 / 字号各出一个 span', () {
      final delta = <dynamic>[
        {'insert': '红', 'attributes': {'color': '#d93025'}},
        {'insert': '绿', 'attributes': {'background': '#e6f4ea'}},
        {'insert': '大', 'attributes': {'size': '19'}},
        {'insert': '\n'},
      ];
      expect(
        DeltaToEmailHtml.convert(delta),
        // 批 B5：用了颜色/高亮，整篇要多一层白底容器（见 `白底容器` 一组）。
        '<div style="background:#ffffff">'
        '<p style="margin:0 0 12px 0">'
        '<span style="color:#d93025">红</span>'
        '<span style="background-color:#e6f4ea">绿</span>'
        '<span style="font-size:19px">大</span>'
        '</p></div>',
      );
    });

    test('形状不对的颜色与档位之外的字号都不写出去', () {
      final delta = <dynamic>[
        {'insert': 'a', 'attributes': {'color': 'javascript:alert(1)'}},
        {'insert': 'b', 'attributes': {'size': '120'}},
        {'insert': '\n'},
      ];
      expect(DeltaToEmailHtml.convert(delta), '<p style="margin:0 0 12px 0">ab</p>');
    });

    test('嵌套顺序：code 最里、a 最外（spec §4.1）', () {
      final delta = <dynamic>[
        {
          'insert': 'x',
          'attributes': {
            'bold': true,
            'italic': true,
            'underline': true,
            'strike': true,
            'code': true,
            'color': '#d93025',
            'background': '#e6f4ea',
            'size': '19',
            'link': 'https://e.com',
          },
        },
        {'insert': '\n'},
      ];
      expect(
        DeltaToEmailHtml.convert(delta),
        // 批 B5：用了颜色/高亮，整篇多一层白底容器。
        '<div style="background:#ffffff">'
        '<p style="margin:0 0 12px 0">'
        '<a href="https://e.com" style="color:#1A73E8;text-decoration:underline">'
        '<strong><em><u><s>'
        '<span style="font-size:19px">'
        '<span style="background-color:#e6f4ea">'
        '<span style="color:#d93025">'
        '<code>x</code></span></span></span></s></u></em></strong></a></p></div>',
      );
    });

    test('属性值不是字符串时不抛、也不写出去', () {
      // `_stringOf` 存在的唯一理由就是这条路径：`attrs` 是从落库再读出来的
      // Delta 里拿的，属性值的类型没有任何人保证，而 `42 as String?` /
      // `true as String?` / `<int>[1] as String?` 都会抛 `_TypeError` ——
      // 那会把整封邮件的导出带崩（本函数的契约是纯函数、绝不抛）。
      // 把三处换回 `as String?` 这条就会红。
      final delta = <dynamic>[
        {
          'insert': 'x',
          'attributes': <String, dynamic>{
            'color': 42,
            'background': true,
            'size': <int>[1],
          },
        },
        {'insert': '\n'},
      ];
      expect(DeltaToEmailHtml.convert(delta), '<p style="margin:0 0 12px 0">x</p>');
    });
  });

  group('块级', () {
    test('连续两段是同一个块（对照组：确认 blockquote 的合并不是特例）', () {
      final delta = <dynamic>[
        {'insert': '一'},
        {'insert': '\n'},
        {'insert': '二'},
        {'insert': '\n'},
      ];
      expect(
        DeltaToEmailHtml.convert(delta),
        '<p style="margin:0 0 12px 0">一</p><p style="margin:0 0 12px 0">二</p>',
      );
    });

    test('标题一到三，四以上降级成段落加粗', () {
      expect(
        DeltaToEmailHtml.convert(_line('H1', {'header': 1})),
        startsWith('<h1 style="'),
      );
      expect(
        DeltaToEmailHtml.convert(_line('H4', {'header': 4})),
        startsWith('<p style="'),
      );
      expect(DeltaToEmailHtml.convert(_line('H4', {'header': 4})), contains('font-weight:700'));
    });

    test('居中对齐', () {
      expect(
        DeltaToEmailHtml.convert(_line('中', {'align': 'center'})),
        contains('text-align:center'),
      );
    });

    test('段落缩进写成 padding-left，像素是 16 的整数倍', () {
      // `16` 这个倍数**不是随便取的**：上游 `parseToIndent` 是 `px / 16`
      // 四舍五入，只有 16 的倍数才能一字不差地读回来。列表那条**历史**公式
      // `12 + indent*24` **已从代码里删掉**（列表改用容器嵌套，见 `21fe260`），
      // 它给出 36px → 2.25 → 2，用在这里 1 级会变 2 级。
      expect(
        DeltaToEmailHtml.convert(_line('缩进段', {'indent': 1})),
        '<p style="margin:0 0 12px 0;padding-left:16px">缩进段</p>',
      );
      expect(
        DeltaToEmailHtml.convert(_line('缩进段', {'indent': 3})),
        '<p style="margin:0 0 12px 0;padding-left:48px">缩进段</p>',
      );
    });

    test('段落缩进与对齐、标题共存', () {
      expect(
        DeltaToEmailHtml.convert(
          _line('缩进居中', {'indent': 1, 'align': 'center'}),
        ),
        '<p style="margin:0 0 12px 0;padding-left:16px;text-align:center">'
        '缩进居中</p>',
      );
      expect(
        DeltaToEmailHtml.convert(_line('缩进标题', {'header': 1, 'indent': 1})),
        startsWith('<h1 style="margin:0 0 12px 0;padding-left:16px;'),
      );
    });

    test('引用块行上的 indent 不导出（导入端也不读，见 _openBlockFor 说明）', () {
      // 已知限制：引用/代码块的 opening 是整块标签，行上的 `indent` 没有落脚点。
      // 这条用例**不是**在说这是对的，是在把它钉成「有意如此」，
      // 免得以后有人以为导出端漏了 `indent` 而顺手补上一个回不来的值。
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': 'q'},
        {'insert': '\n', 'attributes': {'blockquote': true, 'indent': 1}},
      ]);
      expect(html, startsWith('<blockquote'));
      expect(html, isNot(contains('padding-left:16px')));
      // 顺带钉住「回不来」这一半：导入端也读不出 indent。
      final back = MailHtmlToDelta.convert(
        '<blockquote style="padding-left:28px">q</blockquote>',
      );
      expect(jsonEncode(back), isNot(contains('"indent"')));
    });

    test('畸形 indent 一律安全降级成不带 padding-left（且不抛）', () {
      for (final bad in <Object?>[1.5, '3', true, null, 0, -2]) {
        final html = DeltaToEmailHtml.convert(_line('x', {'indent': bad}));
        expect(html, isNot(contains('padding-left')), reason: 'indent=$bad');
      }
    });

    test('连续无序列表合并成一个 ul', () {
      final delta = <dynamic>[
        {'insert': '甲'},
        {'insert': '\n', 'attributes': {'list': 'bullet'}},
        {'insert': '乙'},
        {'insert': '\n', 'attributes': {'list': 'bullet'}},
      ];
      final html = DeltaToEmailHtml.convert(delta);
      expect(html, '<ul style="margin:0 0 12px 0;padding-left:24px">'
          '<li>甲</li><li>乙</li></ul>');
    });

    test('嵌套列表用容器嵌套表达（上游只按嵌套深度读 indent）', () {
      final delta = <dynamic>[
        {'insert': '甲'},
        {'insert': '\n', 'attributes': {'list': 'bullet'}},
        {'insert': '子'},
        {'insert': '\n', 'attributes': {'list': 'bullet', 'indent': 1}},
        {'insert': '丙'},
        {'insert': '\n', 'attributes': {'list': 'bullet'}},
      ];
      expect(
        DeltaToEmailHtml.convert(delta),
        '<ul style="margin:0 0 12px 0;padding-left:24px">'
        '<li>甲<ul style="margin:0;padding-left:24px"><li>子</li></ul></li>'
        '<li>丙</li></ul>',
      );
    });

    test('有序列表', () {
      final delta = <dynamic>[
        {'insert': '一'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
      ];
      expect(DeltaToEmailHtml.convert(delta), contains('<ol style="'));
    });

    test('列表与段落交替时正确开合', () {
      final delta = <dynamic>[
        {'insert': '前'},
        {'insert': '\n'},
        {'insert': '甲'},
        {'insert': '\n', 'attributes': {'list': 'bullet'}},
        {'insert': '后'},
        {'insert': '\n'},
      ];
      final html = DeltaToEmailHtml.convert(delta);
      expect(html, '<p style="margin:0 0 12px 0">前</p>'
          '<ul style="margin:0 0 12px 0;padding-left:24px"><li>甲</li></ul>'
          '<p style="margin:0 0 12px 0">后</p>');
    });

    test('连续引用合并成一个 blockquote', () {
      final delta = <dynamic>[
        {'insert': '两行'},
        {'insert': '\n', 'attributes': {'blockquote': true}},
        {'insert': '都是引用'},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ];
      final html = DeltaToEmailHtml.convert(delta);
      expect(html, startsWith('<blockquote style="'));
      expect(html, contains('两行<br>都是引用'));
      expect(html, endsWith('</blockquote>'));
    });

    test('代码块的两行用真换行分隔（<pre> 里不能是 <br>）', () {
      final delta = <dynamic>[
        {'insert': '甲'},
        {'insert': '\n', 'attributes': {'code-block': true}},
        {'insert': '乙'},
        {'insert': '\n', 'attributes': {'code-block': true}},
      ];
      final html = DeltaToEmailHtml.convert(delta);
      expect(html, contains('<pre style="'));
      expect(html, contains('white-space:pre-wrap'));
      expect(html, endsWith('</pre>'));
      expect(html, contains('甲\n乙'));
      expect(html, isNot(contains('<br>')));
    });
  });

  group('分隔线', () {
    test('只有 `---` 的一段落成 <hr>（不再是一个字面段落）', () {
      final delta = <dynamic>[
        {'insert': '前'},
        {'insert': '\n'},
        {'insert': '---'},
        {'insert': '\n'},
        {'insert': '后'},
        {'insert': '\n'},
      ];
      final html = DeltaToEmailHtml.convert(delta);
      expect(html, contains('<hr'));
      expect(html, isNot(contains('>---<')));
      expect(html, startsWith('<p style="'));
      expect(html, endsWith('</p>'));
    });

    test('夹在别的字里的 `---` 不算分隔线', () {
      expect(
        DeltaToEmailHtml.convert(const <dynamic>[
          {'insert': '一二---三\n'},
        ]),
        contains('一二---三'),
      );
    });

    test('引用块里的 `---` 也是引用，不是分隔线', () {
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '---'},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ]);
      expect(html, startsWith('<blockquote'));
      expect(html, contains('>---<'));
    });
  });

  group('嵌入', () {
    test('图片带 max-width，URI 里的引号被转义', () {
      final delta = <dynamic>[
        {'insert': {'image': 'https://e.com/a"b.png'}},
        {'insert': '\n'},
      ];
      final html = DeltaToEmailHtml.convert(delta);
      expect(html, contains('<img src="https://e.com/a&quot;b.png"'));
      expect(html, contains('max-width:100%'));
    });

    test('base64 图片原样保留（服务端 toImageUrlHtml 会把它变成 cid）', () {
      final delta = <dynamic>[
        {'insert': {'image': 'data:image/png;base64,AAAA'}},
        {'insert': '\n'},
      ];
      expect(DeltaToEmailHtml.convert(delta), contains('src="data:image/png;base64,AAAA"'));
    });

    test('表格块的内容原样输出', () {
      const table = '<table border="1" style="border-collapse:collapse">'
          '<tr><td>x</td></tr></table>';
      final delta = <dynamic>[
        {'insert': {'x-email-table': table}},
        {'insert': '\n'},
      ];
      expect(DeltaToEmailHtml.convert(delta), table);
    });

    test('未知嵌入降级成一个空段落，不吞掉整行', () {
      final delta = <dynamic>[
        {'insert': {'video': 'https://e.com/v.mp4'}},
        {'insert': '\n'},
      ];
      expect(DeltaToEmailHtml.convert(delta), '<p style="margin:0 0 12px 0"><br></p>');
    });
  });

  group('整体', () {
    test('空 Delta 输出空串', () {
      expect(DeltaToEmailHtml.convert(const <dynamic>[]), '');
    });

    test('一个 op 里夹着多个换行也要按行拆开（Document.toDelta 的常态形状）', () {
      // 落库再读出来就是这个样子：`Document.toDelta()` 会把相邻同属性的文本
      // 合并成一个 op（探针 probe53 实测：用户敲出来的 `甲\n乙\n` 就是一个 op）。
      // 把它当成 `<br>` 会把「两段」画成「一段里夹 <br>」。
      expect(
        DeltaToEmailHtml.convert(const <dynamic>[
          {'insert': '一\n二\n'},
        ]),
        '<p style="margin:0 0 12px 0">一</p><p style="margin:0 0 12px 0">二</p>',
      );
    });

    test('合并 op 上的行属性跟着每一行走', () {
      expect(
        DeltaToEmailHtml.convert(const <dynamic>[
          {'insert': '甲\n乙\n', 'attributes': {'list': 'bullet'}},
        ]),
        '<ul style="margin:0 0 12px 0;padding-left:24px"><li>甲</li><li>乙</li></ul>',
      );
    });

    test('末尾没有换行的行也会被收掉', () {
      expect(
        DeltaToEmailHtml.convert(const <dynamic>[
          {'insert': '没有换行结尾'},
        ]),
        '<p style="margin:0 0 12px 0">没有换行结尾</p>',
      );
    });
  });

  group('畸形输入兜底', () {
    // 契约是「纯函数、绝不抛」：脏数据只跳过，不能把整封邮件带崩。
    test('空 Delta 不抛', () {
      expect(DeltaToEmailHtml.convert(const <dynamic>[]), '');
    });

    test('非 Map 的 op 被跳过（type cast 不该炸）', () {
      expect(
        DeltaToEmailHtml.convert(const <dynamic>[
          {'insert': '甲\n'},
          'garbage',
        ]),
        '<p style="margin:0 0 12px 0">甲</p>',
      );
    });

    test('insert 是 int 时当空串', () {
      expect(
        DeltaToEmailHtml.convert(const <dynamic>[
          {'insert': 42},
          {'insert': '\n'},
        ]),
        '<p style="margin:0 0 12px 0"><br></p>',
      );
    });

    test('insert 是 null 时当空串', () {
      expect(
        DeltaToEmailHtml.convert(const <dynamic>[
          {'insert': null},
          {'insert': '\n'},
        ]),
        '<p style="margin:0 0 12px 0"><br></p>',
      );
    });

    test('insert 是 List 时当空串', () {
      expect(
        DeltaToEmailHtml.convert(const <dynamic>[
          {'insert': <dynamic>[1, 2]},
          {'insert': '\n'},
        ]),
        '<p style="margin:0 0 12px 0"><br></p>',
      );
    });

    test('attributes 不是 Map 时不留行属性', () {
      expect(
        DeltaToEmailHtml.convert(const <dynamic>[
          {'insert': '甲'},
          {'insert': '\n', 'attributes': 'oops'},
        ]),
        '<p style="margin:0 0 12px 0">甲</p>',
      );
    });
  });

  group('align 白名单', () {
    test('合法值仍产出 text-align', () {
      expect(
        DeltaToEmailHtml.convert(_line('中', {'align': 'center'})),
        contains('text-align:center'),
      );
    });

    test('注入串被丢掉，不能越出 style 属性', () {
      // align 的值会被拼进 style="…"，不白名单就等于把属性值交给了不可信输入。
      final html = DeltaToEmailHtml.convert(
        _line('中', {'align': 'center" onmouseover="x'}),
      );
      expect(html, isNot(contains('onmouseover')));
      expect(html, isNot(contains('text-align')));
      expect(html, '<p style="margin:0 0 12px 0">中</p>');
    });

    test('标题分支同样走白名单', () {
      final html = DeltaToEmailHtml.convert(
        _line('中', {'header': 1, 'align': 'center" onmouseover="x'}),
      );
      expect(html, isNot(contains('onmouseover')));
    });
  });

  group('危险链接', () {
    test('javascript: 被丢掉，但文字还在', () {
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '点我', 'attributes': {'link': 'javascript:alert(1)'}},
        {'insert': '\n'},
      ]);
      expect(html, isNot(contains('javascript:')));
      expect(html, contains('点我'));
      expect(html, isNot(contains('<a ')));
    });

    test('换行走私的 java\\nscript: 也挡得住', () {
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '点我', 'attributes': {'link': 'java\nscript:alert(1)'}},
        {'insert': '\n'},
      ]);
      expect(html, isNot(contains('<a ')));
      expect(html, contains('点我'));
    });

    test('正常 https 链接仍保留 href', () {
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '点我', 'attributes': {'link': 'https://e.com/a'}},
        {'insert': '\n'},
      ]);
      expect(html, contains('<a href="https://e.com/a"'));
    });

    test('属性值里的引号/尖括号被转义（不止双引号）', () {
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': '点我', 'attributes': {'link': "https://e.com/a'b<c>d\"e"}},
        {'insert': '\n'},
      ]);
      final href = html.substring(html.indexOf('href="'), html.indexOf('" style='));
      expect(href, isNot(contains('<')));
      expect(href, isNot(contains('>')));
      expect(href, isNot(contains("'")));
      expect(href.split('"').length - 1, 1);
    });
  });

  group('嵌入与文字的同行竞争', () {
    test('同一行里图片后面还有文字：走行内路径，<img> 与文字同段', () {
      // 图像不是块级嵌入（block:false），后面这行文字必须走 flush 的行内路径，
      // 不能被当成块整体直出。
      final html = DeltaToEmailHtml.convert(const <dynamic>[
        {
          'insert': {'image': 'https://e.com/a.png'},
        },
        {'insert': '后面\n'},
      ]);
      expect(html, startsWith('<p style="margin:0 0 12px 0">'));
      expect(html, contains('<img src="https://e.com/a.png"'));
      expect(html, contains('后面'));
      expect(html, endsWith('</p>'));
    });
  });

  group('列表往返（导出 → 导入）', () {
    /// 导出再读回来，取每一行的行属性。
    List<String> roundTrip(List<dynamic> delta) => MailHtmlToDelta.convert(
          DeltaToEmailHtml.convert(delta),
        )
            .where((op) => op['attributes'] is Map)
            .map((op) => jsonEncode(op['attributes']))
            .toList();

    test('平铺两级各自回到原位', () {
      expect(
        roundTrip(const <dynamic>[
          {'insert': '甲'},
          {'insert': '\n', 'attributes': {'list': 'bullet'}},
          {'insert': '子'},
          {'insert': '\n', 'attributes': {'list': 'bullet', 'indent': 1}},
          {'insert': '丙'},
          {'insert': '\n', 'attributes': {'list': 'bullet'}},
        ]),
        <String>['{"list":"bullet"}', '{"list":"bullet","indent":1}',
            '{"list":"bullet"}'],
      );
    });

    test('跳级（0 → 2）收敛成深一层，这是已知接受的损失', () {
      expect(
        roundTrip(const <dynamic>[
          {'insert': '甲'},
          {'insert': '\n', 'attributes': {'list': 'bullet'}},
          {'insert': '孙'},
          {'insert': '\n', 'attributes': {'list': 'bullet', 'indent': 2}},
        ]),
        <String>['{"list":"bullet"}', '{"list":"bullet","indent":1}'],
      );
    });

    test('无序紧接有序不串行', () {
      expect(
        roundTrip(const <dynamic>[
          {'insert': '甲'},
          {'insert': '\n', 'attributes': {'list': 'bullet'}},
          {'insert': '一'},
          {'insert': '\n', 'attributes': {'list': 'ordered'}},
          {'insert': '二'},
          {'insert': '\n', 'attributes': {'list': 'ordered', 'indent': 1}},
          {'insert': '乙'},
          {'insert': '\n', 'attributes': {'list': 'bullet'}},
        ]),
        <String>['{"list":"bullet"}', '{"list":"ordered"}',
            '{"list":"ordered","indent":1}', '{"list":"bullet"}'],
      );
    });

    test('嵌套层的同层换标签：条目不能丢（只损失编号/圆点之别）', () {
      // 深度 ≥ 2 时另起容器会让新容器落进父级 `<li>` 里，被
      // `package:html` 整棵丢掉 —— 条目**无声消失**。「序」必须还在，
      // 且仍在 indent 1 上；只有 `list` 的类型允许从 ordered 退成 bullet。
      expect(
        roundTrip(const <dynamic>[
          {'insert': '甲'},
          {'insert': '\n', 'attributes': {'list': 'bullet'}},
          {'insert': '子'},
          {'insert': '\n', 'attributes': {'list': 'bullet', 'indent': 1}},
          {'insert': '序'},
          {'insert': '\n', 'attributes': {'list': 'ordered', 'indent': 1}},
          {'insert': '丙'},
          {'insert': '\n', 'attributes': {'list': 'bullet'}},
        ]),
        <String>[
          '{"list":"bullet"}',
          '{"list":"bullet","indent":1}',
          '{"list":"bullet","indent":1}',
          '{"list":"bullet"}',
        ],
      );
    });

    test('段落缩进往返（列表缩进与段落缩进不会串）', () {
      final ops = MailHtmlToDelta.convert(
        DeltaToEmailHtml.convert(const <dynamic>[
          {'insert': '缩进段'},
          {'insert': '\n', 'attributes': {'indent': 1}},
          {'insert': '甲'},
          {'insert': '\n', 'attributes': {'list': 'bullet'}},
        ]),
      );
      final attrs = ops
          .where((op) => op['attributes'] is Map)
          .map((op) => op['attributes'] as Map)
          .toList();
      expect(attrs.any((a) => a['indent'] == 1 && a['list'] == null), isTrue);
      expect(attrs.any((a) => a['list'] == 'bullet'), isTrue);
    });

    test('上下标往返', () {
      // super 与 sub 都要走一遍：只测 super 的话，导出端把 `sub` 写错
      // （比如两个分支写成同一个字面量）看不出来。
      final back = MailHtmlToDelta.convert(DeltaToEmailHtml.convert(const <dynamic>[
        {'insert': 'x'},
        {'insert': '2', 'attributes': {'script': 'super'}},
        {'insert': 'y'},
        {'insert': '1', 'attributes': {'script': 'sub'}},
        {'insert': '\n'},
      ]));
      final scripts = back
          .where((op) => op['attributes'] is Map)
          .map((op) => (op['attributes'] as Map)['script'])
          .toList();
      expect(scripts, <Object?>['super', 'sub']);
    });
  });
}
