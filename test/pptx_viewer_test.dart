import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/viewers/pptx_viewer_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';

import 'support/ooxml_fixture.dart';

String _write(List<int> bytes) {
  final file = File(
    '${Directory.systemTemp.path}/mail_app_pptx_${DateTime.now().microsecondsSinceEpoch}.pptx',
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

Future<void> pumpPptx(WidgetTester tester, List<int> bytes) async {
  await tester.binding.setSurfaceSize(const Size(800, 600));
  final path = _write(bytes);
  await tester.pumpWidget(_host(PptxViewerScreen(path: path, title: 'd.pptx')));
  await _settle(tester);
}

void main() {
  testWidgets('每页一张卡片，页头写「第 N 页 / 共 M 页」', (tester) async {
    await pumpPptx(
      tester,
      pptx(<String>[
        slideShape(<String>['第一页文字']),
        slideShape(<String>['第二页文字']),
      ]),
    );

    expect(find.textContaining('Slide 1 of 2'), findsOneWidget);
    expect(find.textContaining('Slide 2 of 2'), findsOneWidget);
    expect(find.text('第一页文字'), findsOneWidget);
    expect(find.text('第二页文字'), findsOneWidget);
  });

  testWidgets('标题在卡片里画成标题样式', (tester) async {
    await pumpPptx(
      tester,
      pptx(<String>[
        slideShape(<String>['季度总结'], placeholder: 'title') +
            slideBody('<a:p><a:r><a:t>正文</a:t></a:r></a:p>'),
      ]),
    );

    expect(find.text('季度总结'), findsOneWidget);
    expect(find.text('正文'), findsOneWidget);
  });

  testWidgets('项目符号与表格都画得出来', (tester) async {
    await pumpPptx(
      tester,
      pptx(<String>[
        slideBullets(<String>['要点一', '要点二']) +
            slideTable(<List<String>>[
              <String>['左边', '右边'],
            ]),
      ]),
    );

    expect(find.text('要点一'), findsOneWidget);
    // 两个项目符号点，两条列表项。
    expect(find.text('•'), findsNWidgets(2));
    expect(find.text('左边'), findsOneWidget);
    expect(find.text('右边'), findsOneWidget);
  });

  testWidgets('没有文字的一页说「这一页没有文字」', (tester) async {
    // 一个空的文本框：`p:sp` 在、`a:p` 一条都没有。
    await pumpPptx(
      tester,
      pptx(<String>[slideBody('')]),
    );

    expect(find.textContaining('no text on this slide'), findsOneWidget);
  });

  testWidgets('只有图片的一页**不**说「没有文字」（[图片] 就是内容）', (tester) async {
    await pumpPptx(
      tester,
      pptx(<String>[slidePicture]),
    );

    expect(find.text('[图片]'), findsOneWidget);
    expect(find.textContaining('no text on this slide'), findsNothing);
  });

  testWidgets('「只显示文字」的说明一直在', (tester) async {
    await pumpPptx(tester, pptx(<String>[slideShape(<String>['x'])]));

    expect(find.textContaining('text only'), findsOneWidget);
  });

  testWidgets('页数截断时底部说明', (tester) async {
    final slides = <String>[
      for (var i = 0; i < 110; i++) slideShape(<String>['page $i']),
    ];
    await pumpPptx(tester, pptx(slides));

    expect(find.textContaining('first 100 slides'), findsOneWidget);
  });

  testWidgets('不是 OOXML 包时说「不是文档」', (tester) async {
    await pumpPptx(tester, utf8.encode('just a text file'));

    expect(find.textContaining('isn\'t a Word/Excel/PowerPoint'), findsOneWidget);
  });

  testWidgets('包坏了时说「文档已损坏」', (tester) async {
    await pumpPptx(
      tester,
      <int>[0x50, 0x4B, 0x03, 0x04, ...List<int>.filled(64, 0x41)],
    );

    expect(find.textContaining('damaged'), findsOneWidget);
  });

  testWidgets('文件不在了给一句人话', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_host(
      const PptxViewerScreen(path: '/nonexistent/definitely/not/here.pptx'),
    ));
    await _settle(tester);

    expect(find.text('The file is no longer on disk'), findsOneWidget);
  });

  testWidgets('超过预览上限时说「不能应用内预览」', (tester) async {
    await pumpPptx(tester, List<int>.filled(20 * 1024 * 1024 + 1, 0x41));

    expect(find.textContaining('can\'t be previewed in-app'), findsOneWidget);
  });
}
