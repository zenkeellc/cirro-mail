import 'package:cirro_mail_ext/cirro_mail_ext.dart' as ext;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_stream_view.dart';

/// 只往「失败提示下方」加一颗按钮的假扩展 —— 接缝 S7 的最小实现。
class _ExtWithNotice extends ext.AppExtension {
  @override
  String get id => 'test.ai-notice';

  @override
  List<Widget> aiNoticeExtras(BuildContext context) => <Widget>[
        TextButton(onPressed: () {}, child: const Text('去订阅')),
      ];
}

void main() {
  setUp(ext.AppExtensionRegistry.instance.reset);
  tearDown(ext.AppExtensionRegistry.instance.reset);

  Widget host(AiRun run) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AiStreamView(run: run)),
        ),
      );

  testWidgets('还没出字 → 转圈 + 占位文案', (tester) async {
    final run = AiRun(const AiNotStarted(''))..running.value = true;
    await tester.pumpWidget(host(run));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在生成…'), findsOneWidget);
    expect(run.text.value, isEmpty);
    run.dispose();
  });

  testWidgets('出字之后 → 文字出现，转圈消失', (tester) async {
    final run = AiRun(const AiNotStarted(''))..running.value = true;
    await tester.pumpWidget(host(run));
    run.text.value = '生成出来的第一句';
    await tester.pump();
    expect(find.text('生成出来的第一句'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    run.dispose();
  });

  testWidgets('生成中 → 有停止按钮；点它真的停（running 变 false）', (tester) async {
    final run = AiRun(const AiNotStarted(''))..running.value = true;
    run.text.value = '写到一半';
    await tester.pumpWidget(host(run));
    expect(find.byKey(const ValueKey('ai-stop')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-stop')));
    await tester.pump();
    expect(run.running.value, isFalse);
    expect(find.byKey(const ValueKey('ai-stop')), findsNothing);
    run.dispose();
  });

  testWidgets('出错 → 显示那一句话，且**不留转圈**', (tester) async {
    final run = AiRun(const AiNotStarted(''));
    run.message.value = 'AI 返回 401：invalid api key';
    run.running.value = false;
    await tester.pumpWidget(host(run));
    expect(find.text('AI 返回 401：invalid api key'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '失败时留转圈就是「永远转圈」');
    expect(find.byKey(const ValueKey('ai-stop')), findsNothing);
    run.dispose();
  });

  testWidgets('没配 Key 的提示也走同一条通路（不是 SnackBar，要留在面板里）',
      (tester) async {
    final run = AiRun(
      const AiNotStarted(AiService.notConfiguredMessage),
    );
    await tester.pumpWidget(host(run));
    expect(find.textContaining('设置 → AI'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    run.dispose();
  });

  testWidgets('很长的结果不会把面板顶爆（有高度上限、可滚）', (tester) async {
    final run = AiRun(const AiNotStarted(''))..running.value = false;
    run.text.value = List<String>.filled(400, '这一行会很长很长很长').join('\n');
    await tester.pumpWidget(host(run));
    // 面板自身的高度不该跟着文本无限长。
    final size = tester.getSize(find.byType(AiStreamView));
    expect(size.height, lessThanOrEqualTo(240 + 60));
    expect(find.byType(SingleChildScrollView), findsWidgets);
    run.dispose();
  });

  testWidgets('文字可选中（用户要先读一遍再决定用不用）', (tester) async {
    final run = AiRun(const AiNotStarted(''))..running.value = false;
    run.text.value = '建议的文本';
    await tester.pumpWidget(host(run));
    expect(find.byType(SelectableText), findsOneWidget);
    run.dispose();
  });

  group('aiNoticeExtras 槽（接缝 S7 / 设计稿 §5.3）', () {
    testWidgets('message 非空 → 提示下方接上实现方的动作', (tester) async {
      ext.AppExtensionRegistry.instance
          .registerAll(<ext.AppExtension>[_ExtWithNotice()]);
      final run = AiRun(const AiNotStarted('积分已用完：续订可获得新积分'));
      run.running.value = false;
      await tester.pumpWidget(host(run));
      expect(find.text('积分已用完：续订可获得新积分'), findsOneWidget);
      expect(find.text('去订阅'), findsOneWidget);
      run.dispose();
    });

    testWidgets('message 为空（生成中 / 有结果）→ 不画那组动作', (tester) async {
      ext.AppExtensionRegistry.instance
          .registerAll(<ext.AppExtension>[_ExtWithNotice()]);
      final run = AiRun(const AiNotStarted(''))..running.value = true;
      run.text.value = '写到一半';
      await tester.pumpWidget(host(run));
      expect(find.text('去订阅'), findsNothing);
      run.dispose();
    });

    testWidgets('空注册表 → 失败态只剩那一句话（逐像素不变的护栏）',
        (tester) async {
      final run = AiRun(const AiNotStarted(''));
      run.message.value = 'AI 返回 401：invalid api key';
      run.running.value = false;
      await tester.pumpWidget(host(run));
      expect(find.text('AI 返回 401：invalid api key'), findsOneWidget);
      // 一个多余的按钮都没有：公开版没有实现方，失败提示与从前一样。
      expect(find.byType(TextButton), findsNothing);
      run.dispose();
    });
  });
}
