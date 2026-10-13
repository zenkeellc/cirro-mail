import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_run.dart';
import 'package:mail_app/features/ai/ai_service.dart';
import 'package:mail_app/features/ai/ai_stream_view.dart';

void main() {
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
}
