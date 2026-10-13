import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/viewers/csv_viewer_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 写一个临时文件，返回路径。理由与 `text_viewer_test.dart` 相同：
/// 这些用例要造的是「GBK 的 CSV」「20MB 的表」，正是不往仓库里提交的样本。
String _write(String name, List<int> bytes) {
  final file = File(
    '${Directory.systemTemp.path}/mail_app_csv_${name}_${DateTime.now().microsecondsSinceEpoch}',
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

/// 与文本预览同一套：`pumpAndSettle` 会卡在等待期那个无限动画上，
/// 而只 `pump()` 不推进假时钟、排好的那个宏任务不会跑。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

Future<void> pumpCsv(
  WidgetTester tester,
  String source, {
  Size size = const Size(800, 600),
}) async {
  await tester.binding.setSurfaceSize(size);
  final path = _write('data.csv', utf8.encode(source));
  await tester.pumpWidget(
    _host(CsvViewerScreen(path: path, title: 'data.csv')),
  );
  await _settle(tester);
}

void main() {
  testWidgets('表头与正文都渲染出来', (tester) async {
    await pumpCsv(tester, 'name,city\nalice,beijing\nbob,shanghai\n');

    expect(find.text('name'), findsOneWidget);
    expect(find.text('city'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('shanghai'), findsOneWidget);
  });

  testWidgets('底部说明报出实际用的分隔符', (tester) async {
    await pumpCsv(tester, 'a;b\n1;2\n');

    expect(find.textContaining('Delimiter: ;'), findsOneWidget);
  });

  testWidgets('制表符在说明里写成 Tab，不是一块空白', (tester) async {
    await pumpCsv(tester, 'a\tb\n1\t2\n');

    expect(find.textContaining('Delimiter: Tab'), findsOneWidget);
  });

  testWidgets('引号里的逗号不切列', (tester) async {
    await pumpCsv(tester, 'a,b\n"x,y",2\n');

    expect(find.text('x,y'), findsOneWidget);
    // 只按逗号切的话这里会是 'x' 与 'y' 两格。
    expect(find.text('x'), findsNothing);
  });

  testWidgets('字段内的换行让这一格显示两行，不是两行数据', (tester) async {
    await pumpCsv(tester, 'a,b\n"line1\nline2",2\n');

    // 单元格里的换行符是内容的一部分，`Text.data` 里带着它。
    expect(find.text('line1\nline2'), findsOneWidget);
    expect(find.text('line2'), findsNothing);
  });

  testWidgets('空文件给一句人话，不是一张只有表头的空表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final path = _write('empty.csv', utf8.encode(''));
    await tester.pumpWidget(_host(CsvViewerScreen(path: path)));
    await _settle(tester);

    expect(find.text('(empty file)'), findsOneWidget);
  });

  testWidgets('文件不在了给一句人话，不是空白页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_host(
      const CsvViewerScreen(path: '/nonexistent/definitely/not/here.csv'),
    ));
    await _settle(tester);

    expect(find.text('The file is no longer on disk'), findsOneWidget);
  });

  testWidgets('超过预览上限时说「不能应用内预览」，不是「文件不在了」', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    // 20MB + 1 字节 —— 刚过线。
    final big = List<int>.filled(20 * 1024 * 1024 + 1, 0x61);
    final path = _write('big.csv', big);
    await tester.pumpWidget(_host(CsvViewerScreen(path: path)));
    await _settle(tester);

    expect(find.textContaining('can\'t be previewed in-app'), findsOneWidget);
    expect(find.text('The file is no longer on disk'), findsNothing);
  });

  testWidgets('GBK 的表头解得出中文，不进乱码兜底', (tester) async {
    // 手写死值，不用编码器 —— 用自家编码器造输入再自家解码器读，
    // 两边共一张映射表时会同时错而测出绿。这条链路是
    // `decodeText`（BOM → 严格 UTF-8 → GB18030）+ `CsvCodec.parse`。
    final path = _write('gbk.csv', <int>[
      0xD0, 0xD5, 0xC3, 0xFB, // 姓名
      0x2C, // ,
      0xB3, 0xC7, 0xCA, 0xD0, // 城市
      0x0A,
    ]);
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_host(CsvViewerScreen(path: path, title: 'gbk.csv')));
    await _settle(tester);

    expect(find.text('姓名'), findsOneWidget);
    expect(find.text('城市'), findsOneWidget);
    expect(find.textContaining('lossy'), findsNothing);
  });

  group('列多的时候', () {
    testWidgets('横向能滚，且表头跟着一起走', (tester) async {
      await pumpCsv(
        tester,
        '${List<String>.generate(12, (i) => 'col$i').join(',')}\n'
        '${List<String>.generate(12, (i) => 'val$i').join(',')}\n',
      );

      // 最开始最后几列在视口外。
      final before = tester.getTopLeft(find.text('col11'));
      final bodyBefore = tester.getTopLeft(find.text('val11'));
      expect(before.dx, greaterThan(800));

      await tester.drag(find.text('col0'), const Offset(-600, 0));
      await tester.pump();

      // 表头与正文**同时**左移，位移量一致 —— 两者共用一个横向滚动视图。
      final after = tester.getTopLeft(find.text('col11'));
      final bodyAfter = tester.getTopLeft(find.text('val11'));
      expect(after.dx, lessThan(before.dx));
      expect(after.dx - before.dx, closeTo(bodyAfter.dx - bodyBefore.dx, 0.01));
    });

    testWidgets('纵向滚动时表头不动', (tester) async {
      final rows = List<String>.generate(80, (i) => 'r$i,v$i').join('\n');
      await pumpCsv(tester, 'name,value\n$rows\n');

      final headerBefore = tester.getTopLeft(find.text('name'));
      await tester.drag(find.text('name'), const Offset(0, -400));
      await tester.pump();

      expect(tester.getTopLeft(find.text('name')), headerBefore);
    });
  });

  group('单元格溢出', () {
    testWidgets('截断的格子点开能看全文', (tester) async {
      // 40 个汉字在 140pt 宽、两行的格子里放不下。
      final long = '这是一段很长的备注内容用来验证点开之后能看到完整的文本' * 3;
      await pumpCsv(tester, 'note\n$long\n');

      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text(long));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      // 弹层里的那份也是同一个完整字符串（不是再截一次）。
      expect(find.text(long), findsNWidgets(2));
    });

    testWidgets('没截断的格子点了什么也不弹 —— 弹层是模态的，打扰不起', (tester) async {
      await pumpCsv(tester, 'note\nok\n');

      await tester.tap(find.text('ok'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('上限', () {
    testWidgets('行数超限时底部说明截断了', (tester) async {
      final buf = StringBuffer('h\n');
      for (var i = 0; i < 5100; i++) {
        buf.writeln('r$i');
      }
      await pumpCsv(tester, buf.toString());

      expect(find.textContaining('Showing the first 5000 rows'), findsOneWidget);
    });

    testWidgets('没超限时不说截断', (tester) async {
      await pumpCsv(tester, 'a,b\n1,2\n');

      expect(find.textContaining('Showing the first'), findsNothing);
    });
  });
}
