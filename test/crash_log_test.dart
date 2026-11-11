// 未捕获异常的落盘与「那块灰白」的替代品。
//
// 背景：release 下某个 widget 在 build 里抛异常时，用户看到的是一块**灰白**，
// 开发者什么也拿不到 —— 「设置 → 实例 点不开/右栏空白」就是这类症状里最典型
// 的一次。这个文件钉住两件事：
//
// 1. `FlutterError.onError` / `PlatformDispatcher.onError` 收到的异常必须进
//    `crash.log`（进程退出后还在），且文件有封顶、不会把沙盒写满；
// 2. release/profile 下那块灰白换成**看得懂**的卡片：有摘要、不依赖 Theme /
//    Localizations / MediaQuery（它可能出现在启动阶段那棵还没有 MaterialApp
//    的树里，多依赖一样就可能在兜底路径上再抛一次）。
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/diagnostics/crash_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('crash-log-test');
  });

  tearDown(() async {
    await CrashLog.resetForTest();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('记下的异常进内存流水，并按发生顺序排', () {
    CrashLog.record('FlutterError', StateError('boom'), StackTrace.current);
    CrashLog.record('uncaught', ArgumentError('nope'), null);

    expect(CrashLog.recent, hasLength(2));
    expect(CrashLog.recent.first, contains('FlutterError'));
    expect(CrashLog.recent.first, contains('boom'));
    expect(CrashLog.recent.last, contains('uncaught'));
    expect(CrashLog.recent.last, contains('nope'));
  });

  test('内存流水封顶，不会无限长', () {
    for (var i = 0; i < CrashLog.maxEntries + 20; i++) {
      CrashLog.record('FlutterError', StateError('boom $i'), null);
    }
    expect(CrashLog.recent, hasLength(CrashLog.maxEntries));
    // 丢的是最早的，留的是最新的。
    expect(CrashLog.recent.last, contains('boom ${CrashLog.maxEntries + 19}'));
  });

  test('目录接上之前攒的异常会在接上之后补写', () async {
    CrashLog.record('FlutterError', StateError('early'), null);
    await CrashLog.attachDirectoryForTest(dir);

    final file = File('${dir.path}/${CrashLog.fileName}');
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('early'));
  });

  test('接上目录之后每条都落盘，带时间戳与异常类型', () async {
    await CrashLog.attachDirectoryForTest(dir);
    CrashLog.record(
      'FlutterError',
      StateError('kaboom'),
      StackTrace.fromString('#0      fake frame\n#1      another'),
      where: 'building InstancesSection',
    );

    final text =
        File('${dir.path}/${CrashLog.fileName}').readAsStringSync();
    expect(text, contains('FlutterError'));
    expect(text, contains('building InstancesSection'));
    expect(text, contains('kaboom'));
    // 栈至少带着前几帧，不然排障时只剩一句「Bad state」。
    expect(text, contains('#0      fake frame'));
    // 时间戳：ISO8601 的年份前缀，够证明「这是哪一次」。
    expect(text, contains(DateTime.now().year.toString()));
  });

  test('文件封顶：写爆之后不会无限增长', () async {
    await CrashLog.attachDirectoryForTest(dir);
    final chunk = 'x' * 2048;
    // 远超 64KB 的量。
    for (var i = 0; i < 80; i++) {
      CrashLog.record('FlutterError', StateError('$chunk $i'), null);
    }
    final file = File('${dir.path}/${CrashLog.fileName}');
    expect(file.lengthSync(), lessThanOrEqualTo(CrashLog.maxBytes));
  });

  test('栈只写前若干帧（release 的栈上百帧，会瞬间把文件灌满）', () async {
    await CrashLog.attachDirectoryForTest(dir);
    final frames = List<String>.generate(200, (i) => '#$i  frame');
    CrashLog.record(
      'uncaught',
      StateError('deep'),
      StackTrace.fromString(frames.join('\n')),
    );

    final text =
        File('${dir.path}/${CrashLog.fileName}').readAsStringSync();
    expect(text, contains('#0  frame'));
    expect(text, isNot(contains('#${CrashLog.maxStackLines}  frame')));
  });

  test('install 之后 FlutterError 上报会进流水', () {
    CrashLog.install();
    FlutterError.reportError(FlutterErrorDetails(
      exception: StateError('reported via install'),
      stack: StackTrace.current,
    ));

    expect(
      CrashLog.recent.any((line) => line.contains('reported via install')),
      isTrue,
    );
  });

  testWidgets('替代那块灰白的卡片：有摘要，且不依赖 Theme / Localizations',
      (tester) async {
    final details = FlutterErrorDetails(
      exception: StateError('Bad state: 实例列表炸了'),
      stack: StackTrace.current,
    );

    // 裸 Directionality（没有 MaterialApp / Theme / Localizations / MediaQuery）
    // —— 启动阶段那棵树就长这样。
    await tester.pumpWidget(CrashLog.buildCard(details));

    expect(find.textContaining('这一块界面没加载出来'), findsOneWidget);
    expect(find.textContaining('实例列表炸了'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片在被压到很窄时也不会再抛（兜底路径不能再炸一次）',
      (tester) async {
    final details = FlutterErrorDetails(
      exception: StateError('x' * 2000),
      stack: StackTrace.current,
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 60,
            height: 40,
            child: CrashLog.buildCard(details),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
