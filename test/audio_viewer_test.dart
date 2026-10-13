import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/audio_playback.dart';
import 'package:mail_app/features/attachment/viewers/audio_viewer_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 一个假的播放器 —— 插件在 `flutter_tester` 里只有 `MissingPluginException`，
/// 控件层的每一个交互都要靠它才验得了（见 `AudioPlayback` 的类注释）。
class FakePlayback implements AudioPlayback {
  FakePlayback({
    this.failOnLoad = false,
    this.autoDuration = const Duration(seconds: 90),
  });

  /// 加载就抛 —— 模拟 Linux 缺 gstreamer。
  final bool failOnLoad;

  /// 加载后假装解出来的时长。
  final Duration autoDuration;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _state = StreamController<PlaybackState>.broadcast();
  final _complete = StreamController<void>.broadcast();

  int playCount = 0;
  int pauseCount = 0;
  final List<Duration> seeks = <Duration>[];
  final List<double> rates = <double>[];
  bool disposed = false;
  String? loadedPath;

  @override
  Future<void> load(String path) async {
    loadedPath = path;
    if (failOnLoad) throw StateError('no backend');
    // 平台层解出时长是在加载之后，异步来的。
    scheduleMicrotask(() => _duration.add(autoDuration));
    scheduleMicrotask(() => _state.add(PlaybackState.paused));
  }

  @override
  Future<void> play() async {
    playCount++;
    _state.add(PlaybackState.playing);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _state.add(PlaybackState.paused);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _position.add(position);
  }

  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Stream<PlaybackState> get stateStream => _state.stream;

  @override
  Stream<void> get completeStream => _complete.stream;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _position.close();
    await _duration.close();
    await _state.close();
    await _complete.close();
  }

  // ---- 测试用的推动手段

  void emitPosition(Duration position) => _position.add(position);

  void finish() {
    _complete.add(null);
    _state.add(PlaybackState.completed);
  }
}

String _write(List<int> bytes) {
  final file = File(
    '${Directory.systemTemp.path}/mail_app_audio_${DateTime.now().microsecondsSinceEpoch}.m4a',
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

/// 起一个页面，返回注入进去的那个假播放器。
Future<FakePlayback> pumpAudio(
  WidgetTester tester, {
  bool failOnLoad = false,
  List<int>? bytes,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 600));
  final path = _write(bytes ?? List<int>.filled(16, 0));
  // 先在**外面**造好：超限那一档在 `_load` 里就返回了、根本不会调用
  // 工厂，若把赋值放在工厂里，那个用例会连一个播放器都拿不到。
  final fake = FakePlayback(failOnLoad: failOnLoad);
  await tester.pumpWidget(_host(AudioViewerScreen(
    path: path,
    title: 'voice.m4a',
    playerFactory: () => fake,
  )));
  await _settle(tester);
  return fake;
}

void main() {
  testWidgets('加载完成后显示时长与播放键', (tester) async {
    final fake = await pumpAudio(tester);

    expect(fake.loadedPath, isNotNull);
    expect(find.text('1:30'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('点播放变成暂停键，再点变回来', (tester) async {
    final fake = await pumpAudio(tester);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await _settle(tester);
    expect(fake.playCount, 1);
    expect(find.byIcon(Icons.pause), findsOneWidget);

    await tester.tap(find.byIcon(Icons.pause));
    await _settle(tester);
    expect(fake.pauseCount, 1);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('位置流推进时时间跟着走', (tester) async {
    final fake = await pumpAudio(tester);

    fake.emitPosition(const Duration(seconds: 12));
    await _settle(tester);
    expect(find.text('0:12'), findsOneWidget);
  });

  testWidgets('拖动过程中位置回调不会把滑块从手指底下拽走', (tester) async {
    final fake = await pumpAudio(tester);
    fake.emitPosition(const Duration(seconds: 10));
    await _settle(tester);

    final slider = find.byType(Slider);
    final box = tester.getRect(slider);
    // 按在进度条大约一半的位置并拖动。
    final gesture = await tester.startGesture(
      Offset(box.left + box.width * 0.5, box.center.dy),
    );
    await tester.pump();
    final dragged = tester.widget<Slider>(slider).value;

    // 手指按住的时候，位置流还在推 —— 它必须被挡住。
    fake.emitPosition(const Duration(seconds: 1));
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, dragged);

    await gesture.up();
    await _settle(tester);
    // 松手才 seek，而且只 seek 一次。
    expect(fake.seeks.length, 1);
    expect(fake.seeks.single.inSeconds, closeTo(dragged.round() ~/ 1000, 1));
  });

  testWidgets('放完之后位置停在末尾，按钮回到播放；再点先回到开头', (tester) async {
    final fake = await pumpAudio(tester);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await _settle(tester);

    fake.finish();
    await _settle(tester);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    // 位置停在末尾而不是跳回 0。
    expect(find.text('1:30'), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.play_arrow));
    await _settle(tester);
    // 先 seek 回 0，再 play —— 不这么做平台层会立刻再发一次 complete。
    expect(fake.seeks.single, Duration.zero);
    expect(fake.playCount, 2);
  });

  testWidgets('切倍速会传给播放器', (tester) async {
    final fake = await pumpAudio(tester);

    await tester.tap(find.text('1.5x'));
    await _settle(tester);
    expect(fake.rates, <double>[1.5]);
  });

  testWidgets('平台放不了时说「放不了」，不是「文件不在了」', (tester) async {
    await pumpAudio(tester, failOnLoad: true);

    expect(find.textContaining('Couldn\'t play this file'), findsOneWidget);
    expect(find.text('The file is no longer on disk'), findsNothing);
  });

  testWidgets('文件不在了给一句人话', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_host(AudioViewerScreen(
      path: '/nonexistent/definitely/not/here.m4a',
      playerFactory: FakePlayback.new,
    )));
    await _settle(tester);

    expect(find.text('The file is no longer on disk'), findsOneWidget);
  });

  testWidgets('超过预览上限时说「不能应用内预览」', (tester) async {
    await pumpAudio(
      tester,
      bytes: List<int>.filled(20 * 1024 * 1024 + 1, 0),
    );

    expect(find.textContaining('can\'t be previewed in-app'), findsOneWidget);
  });

  testWidgets('离开页面会 dispose 播放器', (tester) async {
    final fake = await pumpAudio(tester);

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await _settle(tester);
    expect(fake.disposed, isTrue);
  });
}
