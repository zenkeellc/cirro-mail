import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/viewers/docx_viewer_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';

import 'support/ooxml_fixture.dart';

String _write(List<int> bytes) {
  final file = File(
    '${Directory.systemTemp.path}/mail_app_docx_${DateTime.now().microsecondsSinceEpoch}.docx',
  );
  file.writeAsBytesSync(bytes);
  addTearDown(() {
    if (file.existsSync()) file.deleteSync();
  });
  return file.path;
}

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: child,
    );

/// 与其它 viewer 测试同一套：`pumpAndSettle` 会卡在等待期那个无限动画上，
/// 只 `pump()` 又不推进假时钟、排好的宏任务不会跑。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

Future<void> pumpDocx(WidgetTester tester, List<int> bytes) async {
  await tester.binding.setSurfaceSize(const Size(800, 600));
  final path = _write(bytes);
  await tester.pumpWidget(_host(DocxViewerScreen(path: path, title: 'r.docx')));
  await _settle(tester);
}

/// 在 span 树里找到 `text` 恰好等于 [needle] 的那一个。
///
/// `Text.rich` 会在外面再套一层 `TextSpan`（`Text` 的 `build` 把传进来的
/// `textSpan` 挂到自己的那层下面），所以不能假定它在顶层。
TextSpan? _spanWithText(Iterable<InlineSpan> spans, String needle) {
  for (final span in spans) {
    if (span is! TextSpan) continue;
    if (span.text == needle) return span;
    final found = _spanWithText(span.children ?? const <InlineSpan>[], needle);
    if (found != null) return found;
  }
  return null;
}

void main() {
  testWidgets('标题、正文与列表都画出来', (tester) async {
    await pumpDocx(
      tester,
      docx(
        '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
        '<w:r><w:t>标题</w:t></w:r></w:p>'
        '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>加粗</w:t></w:r>'
        '<w:r><w:t>普通</w:t></w:r></w:p>'
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr>'
        '<w:r><w:t>项目</w:t></w:r></w:p>',
      ),
    );

    expect(find.text('标题'), findsOneWidget);
    expect(find.text('加粗普通'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    // 列表符号单独一列。
    expect(find.text('•'), findsOneWidget);
  });

  testWidgets('粗体那一段真的带上了 FontWeight', (tester) async {
    await pumpDocx(
      tester,
      docx('<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r></w:p>'),
    );

    // 按文本内容在 span 树里找那一个 —— 树里第一个 `RichText` 是 AppBar 的
    // 标题，而 `Text.rich` 自己还会在外面套一层（`Text` 的 `build` 把
    // `textSpan` 挂到 `TextSpan(style: effectiveTextStyle, children: …)` 上）。
    final span = _spanWithText(
      tester.widgetList<RichText>(find.byType(RichText)).map((r) => r.text),
      'bold',
    );
    expect(span, isNotNull);
    expect(span!.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('表格画成行列，合并格只出现一次内容', (tester) async {
    await pumpDocx(
      tester,
      docx(
        '<w:tbl>'
        '<w:tr>'
        '<w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr>'
        '<w:p><w:r><w:t>合并表头</w:t></w:r></w:p></w:tc>'
        '</w:tr>'
        '<w:tr>'
        '<w:tc><w:p><w:r><w:t>左</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>右</w:t></w:r></w:p></w:tc>'
        '</w:tr>'
        '</w:tbl>',
      ),
    );

    expect(find.text('合并表头'), findsOneWidget);
    expect(find.text('左'), findsOneWidget);
    expect(find.text('右'), findsOneWidget);
  });

  testWidgets('行尾不齐的表格不崩（空格子补上）', (tester) async {
    await pumpDocx(
      tester,
      docx(
        '<w:tbl>'
        '<w:tr><w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc></w:tr>'
        '<w:tr><w:tc><w:p><w:r><w:t>只有一格</w:t></w:r></w:p></w:tc></w:tr>'
        '</w:tbl>',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('只有一格'), findsOneWidget);
  });

  testWidgets('图片位置有 [图片] 占位，页脚说明少了什么', (tester) async {
    await pumpDocx(
      tester,
      docx('<w:p><w:r><w:drawing/></w:r></w:p>'),
    );

    expect(find.textContaining('[图片]'), findsOneWidget);
    expect(find.textContaining('Images and layout'), findsOneWidget);
  });

  testWidgets('不是 OOXML 包时说「不是文档」，不是「文件不在了」', (tester) async {
    await pumpDocx(tester, utf8.encode('just a text file'));

    expect(find.textContaining('isn\'t a Word/Excel/PowerPoint'), findsOneWidget);
    expect(find.text('The file is no longer on disk'), findsNothing);
  });

  testWidgets('包坏了时说「文档已损坏」', (tester) async {
    // 魔数像 zip，但一个条目都读不出来。
    await pumpDocx(
      tester,
      <int>[0x50, 0x4B, 0x03, 0x04, ...List<int>.filled(64, 0x41)],
    );

    expect(find.textContaining('damaged'), findsOneWidget);
  });

  testWidgets('是个 zip 但不是文档 → 损坏那一档（缺部件）', (tester) async {
    await pumpDocx(
      tester,
      buildPackage(<String, String>{'hello.txt': 'nope'}),
    );

    expect(find.textContaining('damaged'), findsOneWidget);
  });

  testWidgets('文件不在了给一句人话', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_host(
      const DocxViewerScreen(path: '/nonexistent/definitely/not/here.docx'),
    ));
    await _settle(tester);

    expect(find.text('The file is no longer on disk'), findsOneWidget);
  });

  testWidgets('超过预览上限时说「不能应用内预览」', (tester) async {
    await pumpDocx(
      tester,
      List<int>.filled(20 * 1024 * 1024 + 1, 0x41),
    );

    expect(find.textContaining('can\'t be previewed in-app'), findsOneWidget);
  });
}
