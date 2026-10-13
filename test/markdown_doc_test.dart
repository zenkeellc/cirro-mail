import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/codecs/markdown_doc.dart';

void main() {
  group('守卫放行真实文档', () {
    test('常见 markdown 全部结构都过', () {
      const doc = '''
# Title

Intro with **bold**, *italic*, `code`, and a [link](https://example.com).

> quote
> > nested quote

- a
  - b
    - c

1. one
2. two

| a | b |
|---|---|
| 1 | 2 |

- [x] done
- [ ] todo

~~struck~~

```dart
final code = [1, 2, 3];
```
''';
      expect(MarkdownDoc.exceedsLimit(doc), isFalse);
    });

    test('代码块里的深层括号不算 —— 那是全篇最可能堆括号的地方', () {
      final doc = '```\n${'[' * 5000}x\n```\n';
      expect(MarkdownDoc.exceedsLimit(doc), isFalse);
    });

    test('缩进代码块不跳过 —— 宁可高估，宁可退回源码', () {
      // markdown 里四空格缩进确实是代码块，但**缩进到哪结束**这件事
      // 比围栏难判得多（可能是列表项的子块），判错一次就是一条绕过路径。
      // 所以守卫只在围栏代码块上跳过，缩进的照数 —— 代价是这份文档退回
      // 源码视图，而源码是全文都在的。见「围栏识别」那组的对应用例。
      final doc = 'text\n\n    ${'[' * 300}x\n';
      expect(MarkdownDoc.exceedsLimit(doc), isTrue);
      // 但缩进本身不该被当成「列表嵌套」：300 层缩进才 300÷2=150，
      // 没到 100 层上限的是另一种情形 —— 这里钉住的是括号那一档。
      final shallow = 'text\n\n    sample\n';
      expect(MarkdownDoc.exceedsLimit(shallow), isFalse);
    });

    test('转义的方括号不算嵌套', () {
      // `\[` 是字面量，markdown 不会拿它去配链接。
      expect(MarkdownDoc.exceedsLimit(r'\[x\] ' * 500), isFalse);
    });

    test('空文档与纯文本都不拦', () {
      expect(MarkdownDoc.exceedsLimit(''), isFalse);
      expect(MarkdownDoc.exceedsLimit('just text\n' * 1000), isFalse);
    });
  });

  group('守卫拦下已知会卡死 / 爆栈的输入', () {
    // 探针实测（macOS 开发机，`ExtensionSet.gitHubFlavored`）：
    // `'>' * 20000 + ' x'` 解析 47 秒后 StackOverflowError；
    // `'[' * 20000 + 'a' + ']' * 20000` 解析 21 秒。两者都只有几十 KB ——
    // 所以「限长度」这条路走不通，必须按深度拦。
    test('一行两万个 `>`', () {
      expect(MarkdownDoc.exceedsLimit('${'>' * 20000} x'), isTrue);
    });

    test('两三万层方括号嵌套', () {
      expect(MarkdownDoc.exceedsLimit('${'[' * 5000}a${']' * 5000}'), isTrue);
    });

    test('`[a` 连写的嵌套', () {
      expect(MarkdownDoc.exceedsLimit('${'[a' * 5000}${']' * 5000}'), isTrue);
    });

    test('深层嵌套列表', () {
      final lines = <String>[];
      for (var i = 0; i < 1000; i++) {
        lines.add('${'  ' * i}- item');
      }
      expect(MarkdownDoc.exceedsLimit(lines.join('\n')), isTrue);
    });

    test('守卫扫描本身足够快（几十 KB 的输入）', () {
      final bomb = '${'[' * 20000}a${']' * 20000}';
      final sw = Stopwatch()..start();
      MarkdownDoc.exceedsLimit(bomb);
      sw.stop();
      // 解析要 21 秒；扫描是 O(n)，实测量级是毫秒。
      expect(sw.elapsedMilliseconds, lessThan(200));
    });
  });

  group('围栏识别与解析器对齐（错认就是一条绕过路径）', () {
    // 一段真会被解析的括号炸弹。缩进量在守卫的打点范围之外，所以只要没被
    // 当成代码块跳过，守卫就必须看见它。
    final bomb = '${'[' * 4000}a${']' * 4000}';

    test('反引号围栏的 info string 里出现反引号 → 不是围栏', () {
      // `markdown` 包的 codeFencePattern 是 `[^`]*`，这条不匹配，于是它成了
      // 普通段落。守卫若把它当围栏跳过，后面的炸弹就溜过去了。
      expect(MarkdownDoc.exceedsLimit('```a`b\n$bomb\n'), isTrue);
    });

    test('合法的反引号围栏才跳过', () {
      expect(MarkdownDoc.exceedsLimit('```\n$bomb\n```\n'), isFalse);
      expect(MarkdownDoc.exceedsLimit('```dart\n$bomb\n```\n'), isFalse);
    });

    test('波浪号围栏的 info string 里可以有反引号', () {
      expect(MarkdownDoc.exceedsLimit('~~~\n$bomb\n~~~\n'), isFalse);
      expect(MarkdownDoc.exceedsLimit('~~~a`b\n$bomb\n~~~\n'), isFalse);
    });

    test('围栏前最多三个空格；四个空格是缩进代码块', () {
      expect(MarkdownDoc.exceedsLimit('   ```\n$bomb\n```\n'), isFalse);
      // 四空格不是围栏。守卫不跳过，看见炸弹 → 拦下（高估方向，安全）。
      expect(MarkdownDoc.exceedsLimit('    ```\n$bomb\n'), isTrue);
    });

    test('不足三个的 ` 或 ~ 不是围栏', () {
      expect(MarkdownDoc.exceedsLimit('``\n$bomb\n'), isTrue);
    });
  });

  group('转义的反斜杠要数奇偶（数错就是绕过）', () {
    test('奇数个反斜杠 = 转义，不算嵌套', () {
      expect(MarkdownDoc.exceedsLimit(r'\[ ' * 500), isFalse);
      expect(MarkdownDoc.exceedsLimit(r'\\\[' * 500), isFalse);
    });

    test('偶数个反斜杠 = 真的方括号，必须拦', () {
      // `\\[` 里那个 `[` 是真括号 —— 只看「前面有没有反斜杠」会漏掉它。
      expect(MarkdownDoc.exceedsLimit(r'\\[' * 500), isTrue);
      expect(MarkdownDoc.exceedsLimit(r'\\\\[' * 500), isTrue);
    });
  });

  group('渲染', () {
    test('超限时返回 null', () {
      expect(MarkdownDoc.toHtml('${'>' * 5000} x'), isNull);
    });

    test('正常文档渲染成 HTML', () {
      final html = MarkdownDoc.toHtml('# Hi\n\nSome **bold** text.\n')!;
      expect(html, contains('<h1>Hi</h1>'));
      expect(html, contains('<strong>bold</strong>'));
    });

    test('表格、任务列表、删除线都认得（走的是 gitHubFlavored）', () {
      final html = MarkdownDoc.toHtml(
        '| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n~~x~~\n',
      )!;
      expect(html, contains('<table>'));
      expect(html, contains('type="checkbox"'));
      expect(html, contains('<del>x</del>'));
    });

    test('图片换成 `[图片: alt]`，不留 src', () {
      final html = MarkdownDoc.toHtml('![a logo](images/logo.png)\n')!;
      expect(html, contains('[图片: a logo]'));
      expect(html, isNot(contains('<img')));
      expect(html, isNot(contains('images/logo.png')));
    });

    test('没有 alt 的图片也有占位', () {
      final html = MarkdownDoc.toHtml('![](bare.png)\n')!;
      expect(html, contains('[图片]'));
      expect(html, isNot(contains('bare.png')));
    });

    test('alt 里的尖括号被转义，占位文字不会自己变成标签', () {
      final html = MarkdownDoc.toHtml('![a > b](x.png)\n')!;
      // 渲染器的 `alt` 本就把 `>` 转义成 `&gt;`；解析回来之后交给文本节点，
      // 序列化时再转义一次 —— 关键是它**没有**变成一个真标签。
      expect(html, isNot(contains('<img')));
      expect(html, contains('a &gt; b'));
    });

    test('没有图片时原样返回，不做多余的解析', () {
      const src = '# Hi\n\nNo images here.\n';
      expect(MarkdownDoc.toHtml(src), contains('No images here.'));
    });

    test('行内 HTML 原样透出，交给下游净化处理', () {
      // 这里**不**负责安全 —— `HtmlBodyView` 里的 `sanitizeEmailHtml` 才是
      // 那道关。本用例只钉住「我们没在这一点上自作聪明地改动它」。
      final html = MarkdownDoc.toHtml('a\n\n<script>alert(1)</script>\n\nb\n')!;
      expect(html, contains('<script>'));
    });
  });
}
