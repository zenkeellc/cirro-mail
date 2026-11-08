import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/viewers/eml_viewer_screen.dart';
import 'package:mail_app/features/attachment/viewers/text_viewer_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 一份「像真的」的 `.eml`：CRLF、折行主题、multipart/alternative、HTML 正文。
String _sampleEml() => <String>[
      'From: Alice <alice@example.com>',
      'To: Bob <bob@example.com>',
      'Subject: Quarterly report',
      'Date: Tue, 03 Nov 2026 05:36:47 +0000',
      'MIME-Version: 1.0',
      'Content-Type: multipart/alternative; boundary="alt"',
      '',
      '--alt',
      'Content-Type: text/plain; charset="utf-8"',
      '',
      'plain fallback',
      '--alt',
      'Content-Type: text/html; charset="utf-8"',
      '',
      '<p>Rendered <b>body</b></p>',
      '--alt--',
      '',
    ].join('\r\n');

String _write(String name, List<int> bytes) {
  final file = File(
    '${Directory.systemTemp.path}/mail_app_eml_${name}_${DateTime.now().microsecondsSinceEpoch}',
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

/// 推进到内容就位（同 `text_viewer_test.dart` 的理由：**不能** `pumpAndSettle`，
/// 等待期那一圈转圈是无限动画；而 `_load` 排在 postFrame 之后的 0 时长 timer 里，
/// 第一次 pump 必须带时长）。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

/// 全树可见文字的并集：`HtmlBodyView` 渲染成 `RichText`、地址走 `Text.rich`，
/// `find.text` 在这两种上都找不到。
List<String> _renderedTexts(WidgetTester tester) => <String>[
      ...tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? ''),
      ...tester
          .widgetList<RichText>(find.byType(RichText))
          .map((t) => t.text.toPlainText()),
    ];

bool _renders(WidgetTester tester, String needle) =>
    _renderedTexts(tester).any((t) => t.contains(needle));

void main() {
  testWidgets('整页：头与 HTML 正文都显示，源码不上屏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write('sample.eml', utf8.encode(_sampleEml()));
    await tester.pumpWidget(_host(EmlViewerScreen(path: path, title: 'sample.eml')));
    await _settle(tester);

    expect(_renders(tester, 'Quarterly report'), isTrue);
    expect(_renders(tester, 'Alice <alice@example.com>'), isTrue);
    expect(_renders(tester, 'Bob <bob@example.com>'), isTrue);
    // HTML 正文渲染出来了，纯文本那一路没抢镜。
    expect(_renders(tester, 'Rendered body'), isTrue);
    expect(_renders(tester, 'plain fallback'), isFalse);
    // **这是本次修改的要点**：MIME 源码不该出现在预览里。
    expect(_renders(tester, 'Content-Type'), isFalse);
    expect(_renders(tester, 'boundary='), isFalse);
    // 标题栏里是附件名，且给了一条「看原文」的退路。
    expect(find.text('sample.eml'), findsOneWidget);
    expect(find.text('Plain text'), findsOneWidget);
  });

  testWidgets('没有 HTML 时退回纯文本正文', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write(
      'plain.eml',
      utf8.encode(<String>[
        'From: Alice <alice@example.com>',
        'Subject: plain only',
        'Content-Type: text/plain; charset=utf-8',
        '',
        '第一段',
        '第二段',
      ].join('\r\n')),
    );
    await tester.pumpWidget(_host(EmlViewerScreen(path: path)));
    await _settle(tester);

    expect(_renders(tester, 'plain only'), isTrue);
    expect(_renders(tester, '第一段'), isTrue);
    expect(_renders(tester, '第二段'), isTrue);
  });

  testWidgets('点「源码」看得到原始 MIME（复用文本 viewer，不是另写一个页面）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write('source.eml', utf8.encode(_sampleEml()));
    await tester.pumpWidget(_host(EmlViewerScreen(path: path)));
    await _settle(tester);

    await tester.tap(find.text('Plain text'));
    await _settle(tester);
    // 路线动画。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.byType(TextViewerScreen), findsOneWidget);
    expect(_renders(tester, 'Content-Type:'), isTrue);
  });

  testWidgets('解析不出来时说人话，并留一条看原文的路', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write('not-a-mail.eml', utf8.encode('just some text\n'));
    await tester.pumpWidget(_host(EmlViewerScreen(path: path)));
    await _settle(tester);

    expect(find.text('This message cannot be read — try the raw content'),
        findsOneWidget);
    expect(find.text('Plain text'), findsOneWidget);
  });

  testWidgets('文件不在了给一句人话，不是空白页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_host(
      const EmlViewerScreen(path: '/nonexistent/definitely/not/here.eml'),
    ));
    await _settle(tester);

    expect(find.text('The file is no longer on disk'), findsOneWidget);
  });

  testWidgets('内嵌形态不自己撑 Scaffold / AppBar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write('embedded.eml', utf8.encode(_sampleEml()));
    await tester.pumpWidget(_host(
      Scaffold(body: EmlViewerScreen(path: path, embedded: true)),
    ));
    await _settle(tester);

    expect(find.byType(AppBar), findsNothing);
    expect(_renders(tester, 'Rendered body'), isTrue);
  });

  testWidgets('信里带的附件列出来（只读）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write(
      'with-attachment.eml',
      utf8.encode(<String>[
        'From: Alice <alice@example.com>',
        'Subject: with attachment',
        'Content-Type: multipart/mixed; boundary="mix"',
        '',
        '--mix',
        'Content-Type: text/plain; charset=utf-8',
        '',
        'body',
        '--mix',
        'Content-Type: application/pdf',
        r'Content-Disposition: attachment; filename="report.pdf"',
        'Content-Transfer-Encoding: base64',
        '',
        'JVBERi0xLjQK',
        '--mix--',
        '',
      ].join('\r\n')),
    );
    await tester.pumpWidget(_host(EmlViewerScreen(path: path)));
    await _settle(tester);

    expect(_renders(tester, 'report.pdf'), isTrue);
    expect(_renders(tester, '9 B'), isTrue);
  });
}
