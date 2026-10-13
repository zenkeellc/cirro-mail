import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/viewers/xlsx_viewer_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';

import 'support/ooxml_fixture.dart';

String _write(List<int> bytes) {
  final file = File(
    '${Directory.systemTemp.path}/mail_app_xlsx_${DateTime.now().microsecondsSinceEpoch}.xlsx',
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

Future<void> pumpXlsx(WidgetTester tester, List<int> bytes) async {
  await tester.binding.setSurfaceSize(const Size(800, 600));
  final path = _write(bytes);
  await tester.pumpWidget(_host(XlsxViewerScreen(path: path, title: 's.xlsx')));
  await _settle(tester);
}

void main() {
  group('列标', () {
    test('A / Z / AA / AZ / BA', () {
      expect(columnLabel(0), 'A');
      expect(columnLabel(25), 'Z');
      expect(columnLabel(26), 'AA');
      expect(columnLabel(51), 'AZ');
      expect(columnLabel(52), 'BA');
      expect(columnLabel(99), 'CV');
    });
  });

  testWidgets('单元格都画出来，数字与文字各就各位', (tester) async {
    await pumpXlsx(
      tester,
      xlsx(
        <String, String>{
          'S': row(
            1,
            cell('A1', type: 's', body: '<v>0</v>')
                + cell('B1', body: '<v>42</v>')
                + cell('C1', type: 's', body: '<v>1</v>'),
          ),
        },
        sharedStrings: sharedString('名称') + sharedString('备注'),
      ),
    );

    expect(find.text('名称'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('备注'), findsOneWidget);
    // 列标头是画出来的。
    expect(find.text('A'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
  });

  testWidgets('日期列显示成日期，不是一串五位数', (tester) async {
    await pumpXlsx(
      tester,
      xlsx(
        <String, String>{
          'S': row(1, cell('A1', style: '0', body: '<v>45778</v>')),
        },
        cellXfs: '<xf numFmtId="14"/>',
      ),
    );

    expect(find.text('2025-05-01'), findsOneWidget);
    expect(find.text('45778'), findsNothing);
  });

  testWidgets('多张表时有切换栏，点一下换表', (tester) async {
    await pumpXlsx(
      tester,
      xlsx(<String, String>{
        '第一页': row(1, cell('A1', body: '<v>111</v>')),
        '第二页': row(1, cell('A1', body: '<v>222</v>')),
      }),
    );

    expect(find.text('第一页'), findsOneWidget);
    expect(find.text('第二页'), findsOneWidget);
    expect(find.text('111'), findsOneWidget);
    expect(find.text('222'), findsNothing);

    await tester.tap(find.text('第二页'));
    await tester.pump();

    expect(find.text('222'), findsOneWidget);
    expect(find.text('111'), findsNothing);
  });

  testWidgets('只有一张表时没有切换栏', (tester) async {
    await pumpXlsx(
      tester,
      xlsx(<String, String>{
        '唯一': row(1, cell('A1', body: '<v>1</v>')),
      }),
    );

    // 表名不该以 chip 的形式出现。
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('空表说「空工作表」而不是画一张空表格', (tester) async {
    await pumpXlsx(tester, xlsx(<String, String>{'S': ''}));

    expect(find.textContaining('empty sheet'), findsOneWidget);
  });

  testWidgets('行数截断时底部说明', (tester) async {
    final rows = StringBuffer();
    for (var i = 1; i <= 5100; i++) {
      rows.write(row(i, cell('A$i', body: '<v>$i</v>')));
    }
    await pumpXlsx(tester, xlsx(<String, String>{'S': rows.toString()}));

    expect(find.textContaining('Showing the first 5000 rows'), findsOneWidget);
  });

  testWidgets('数字格式简化的说明一直在', (tester) async {
    await pumpXlsx(
      tester,
      xlsx(<String, String>{
        'S': row(1, cell('A1', body: '<v>1</v>')),
      }),
    );

    expect(find.textContaining('charts and images'), findsOneWidget);
  });

  testWidgets('不是 OOXML 包时说「不是文档」', (tester) async {
    await pumpXlsx(tester, utf8.encode('just a text file'));

    expect(find.textContaining('isn\'t a Word/Excel/PowerPoint'), findsOneWidget);
    expect(find.text('The file is no longer on disk'), findsNothing);
  });

  testWidgets('包坏了时说「文档已损坏」', (tester) async {
    await pumpXlsx(
      tester,
      <int>[0x50, 0x4B, 0x03, 0x04, ...List<int>.filled(64, 0x41)],
    );

    expect(find.textContaining('damaged'), findsOneWidget);
  });

  testWidgets('文件不在了给一句人话', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_host(
      const XlsxViewerScreen(path: '/nonexistent/definitely/not/here.xlsx'),
    ));
    await _settle(tester);

    expect(find.text('The file is no longer on disk'), findsOneWidget);
  });

  testWidgets('超过预览上限时说「不能应用内预览」', (tester) async {
    await pumpXlsx(tester, List<int>.filled(20 * 1024 * 1024 + 1, 0x41));

    expect(find.textContaining('can\'t be previewed in-app'), findsOneWidget);
  });
}
