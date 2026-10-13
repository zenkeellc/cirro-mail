import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/util/attachment_mime.dart';
import 'package:mail_app/features/attachment/viewers/text_viewer_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 写一个临时文件，返回路径。
///
/// 放在 `Directory.systemTemp` 而不是仓库里：这几个用例要造的是「一份 GBK
/// 的日志」「一个 200KB 的单行文件」，正是本仓库明确不往 `test/` 里提交的
/// 二进制样本。
String _write(String name, List<int> bytes) {
  final file = File(
    '${Directory.systemTemp.path}/mail_app_tv_${name}_${DateTime.now().microsecondsSinceEpoch}',
  );
  file.writeAsBytesSync(bytes);
  addTearDown(() {
    if (file.existsSync()) file.deleteSync();
  });
  return file.path;
}

/// 起一个带本地化的 `MaterialApp`。
///
/// 少了这几个 delegate，`AppLocalizations.of` 里的 `!` 会直接抛
/// （生成的代码假定调用方一定提供了）。
Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: child,
    );

/// 推进到内容就位。
///
/// **不能用 `pumpAndSettle`**：等待期那一圈 `CircularProgressIndicator` 是
/// 无限动画，`pumpAndSettle` 会一直等它停下，直到超时。
///
/// 也不能只 `pump()`（不带时长）：不带时长的 `pump` 不推进假时钟，而 `_load`
/// 排在 `addPostFrameCallback` 之后的那个 **0 时长 timer** 里，只有让假时钟走
/// 一格它才会跑。所以第一次 pump 要带一个时长。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(); // 画首帧，顺带排队 postFrameCallback
  await tester.pump(const Duration(milliseconds: 1)); // 跑 _load
  await tester.pump(); // 画出内容
}

/// 全树可见文字的并集。
///
/// Markdown 走的是 `HtmlBodyView` → `HtmlWidget`，它把一段 HTML 渲染成
/// **一个** `RichText`（不是一个标签一个 `Text`）—— `find.text` 只在
/// `Text` / `EditableText` 上找，在这种页面上会一无所获。真要看渲染结果就得
/// 落到 `RichText` 的 `text.toPlainText()`。
List<String> _renderedTexts(WidgetTester tester) => <String>[
      ...tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? ''),
      ...tester
          .widgetList<RichText>(find.byType(RichText))
          .map((t) => t.text.toPlainText()),
    ];

bool _renders(WidgetTester tester, String needle) =>
    _renderedTexts(tester).any((t) => t.contains(needle));

void main() {
  testWidgets('UTF-8 文本按行渲染，没有多余提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write('plain.txt', utf8.encode('hello\n世界\n'));
    await tester.pumpWidget(_host(TextViewerScreen(path: path, title: 'plain.txt')));
    await _settle(tester);

    expect(find.text('hello'), findsOneWidget);
    expect(find.text('世界'), findsOneWidget);
    expect(find.text('plain.txt'), findsOneWidget);
    // 编码猜对了、也没超限 —— 底部那一条说明不该出现。
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('空行占一行高度，不会被抽掉', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write('blank.txt', utf8.encode('a\n\nb\n'));
    await tester.pumpWidget(_host(TextViewerScreen(path: path)));
    await _settle(tester);

    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    // 三行：'a'、''、'b'。空行也得有一条。
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.semanticChildCount, 3);
  });

  testWidgets('GBK 字节解出中文，不报 lossy', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    // 「中文」的 GBK：D6D0 CEC4。手写死值，不用编码器 —— 用自家编码器造
    // 输入、再用自家解码器读，两边共一张映射表时会同时错而测出绿。
    final path = _write('gbk.txt', <int>[0xD6, 0xD0, 0xCE, 0xC4]);
    await tester.pumpWidget(_host(TextViewerScreen(path: path)));
    await _settle(tester);

    expect(find.text('中文'), findsOneWidget);
    // 'utf-8-lossy' 那条提示不该出现。
    expect(find.textContaining('lossy'), findsNothing);
  });

  testWidgets('解不出来的字节给出编码提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write('bad.txt', <int>[0x41, 0xFF, 0x42]);
    await tester.pumpWidget(_host(TextViewerScreen(path: path)));
    await _settle(tester);

    expect(find.textContaining('utf-8-lossy'), findsOneWidget);
  });

  testWidgets('文件不在了给一句人话，不是空白页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_host(
      const TextViewerScreen(path: '/nonexistent/definitely/not/here.txt'),
    ));
    await _settle(tester);

    expect(find.text('The file is no longer on disk'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  group('Markdown', () {
    Future<void> pumpDoc(WidgetTester tester, String source) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      final path = _write('doc.md', utf8.encode(source));
      await tester.pumpWidget(_host(TextViewerScreen(
        path: path,
        title: 'doc.md',
        kind: AttachmentKind.markdown,
      )));
      await _settle(tester);
    }

    testWidgets('默认渲染排版，源码里才看得到标记', (tester) async {
      await pumpDoc(tester, '# Title\n\nSome **bold** text.\n');

      // 渲染之后没有 `#` 和 `**`，只有标题与正文。
      expect(_renders(tester, '# Title'), isFalse);
      expect(_renders(tester, 'Some bold text.'), isTrue);
      // 切换按钮在，且当前是「去看源码」。
      expect(find.text('Source'), findsOneWidget);
      expect(find.text('Rendered'), findsNothing);
    });

    testWidgets('切到源码后看得到原始标记，也能切回来', (tester) async {
      await pumpDoc(tester, '# Title\n\nSome **bold** text.\n');

      await tester.tap(find.text('Source'));
      await _settle(tester);

      expect(_renders(tester, '# Title'), isTrue);
      expect(_renders(tester, 'Some **bold** text.'), isTrue);
      expect(find.text('Rendered'), findsOneWidget);

      await tester.tap(find.text('Rendered'));
      await _settle(tester);
      expect(_renders(tester, '# Title'), isFalse);
    });

    testWidgets('图片换成占位文字，不留一个取不到的 src', (tester) async {
      await pumpDoc(tester, 'before\n\n![a logo](images/logo.png)\n\nafter\n');

      expect(_renders(tester, '[图片: a logo]'), isTrue);
      // `HtmlBodyView` 那一侧不该收到任何 img。
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('嵌套太深时退回源码，并说明原因', (tester) async {
      // 守卫的括号阈值是 200 层；这里给 400 层，稳过线。
      await pumpDoc(tester, '${'[' * 400}a${']' * 400}\n');

      expect(find.textContaining('Nested too deeply'), findsOneWidget);
      // 退回源码：既没有排版按钮（连渲染都没成功），原始文本在。
      expect(find.text('Source'), findsNothing);
      expect(find.textContaining('[[[['), findsOneWidget);
      // 走到的是源码那一路（ListView），不是 HTML 那一路。
      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('普通的单个链接不会被当成嵌套', (tester) async {
      // 回归：括号计数是「运行峰值」，`[文本](链接)` 一开一合不该攒成深度。
      await pumpDoc(tester, 'See [the site](https://example.com) for details.\n');

      expect(find.textContaining('Nested too deeply'), findsNothing);
      expect(find.text('Source'), findsOneWidget);
    });
  });

  testWidgets('超长单行被切成多段，不会建一个 20 万字符的 Text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write('long.txt', utf8.encode('x' * 5000));
    await tester.pumpWidget(_host(TextViewerScreen(path: path)));
    await _settle(tester);

    // 5000 字符按 2000 一段 → 3 段。
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.semanticChildCount, 3);
    expect(find.text('x' * 2000), findsOneWidget);
  });

  testWidgets('超过 20 万字符时截断并说明', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    // 20 万字符上限 + 一点余量。用换行撑开，免得变成一条超长行。
    final path = _write('huge.txt', utf8.encode('line\n' * 41000));
    await tester.pumpWidget(_host(TextViewerScreen(path: path)));
    await _settle(tester);

    expect(find.textContaining('Only the first 200000 characters'), findsOneWidget);
  });
}
