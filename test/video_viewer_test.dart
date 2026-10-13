import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/viewers/video_viewer_screen.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 视频这一侧**只测到「还没碰插件」的那几条路径**。
///
/// `video_player` 在 `flutter_tester` 里既没有平台实现也没有可用的解码器，
/// `VideoPlayerController.file(...).initialize()` 必然失败 —— 也就是说
/// 「能播、能拖、时间对不对」在本机是测不了的（同 `attachment_kind_test.dart`
/// 里那条「mime 层测得了、插件层测不了」的分工）。
///
/// 幸好这一页的**读盘那一段**跑在插件之前：文件不在了、超限，两种都是
/// `LocalFile` 判完就返回。这两条恰恰是最该有测试的 —— 它们是「点了没反应」
/// 最容易藏身的地方。
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

void main() {
  testWidgets('文件不在了给一句人话，不去碰播放器', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_host(const VideoViewerScreen(
      path: '/nonexistent/definitely/not/here.mp4',
      title: 'clip.mp4',
    )));
    await _settle(tester);

    expect(find.text('The file is no longer on disk'), findsOneWidget);
  });

  testWidgets('超过预览上限时说「不能应用内预览」', (tester) async {
    final file = File(
      '${Directory.systemTemp.path}/mail_app_video_${DateTime.now().microsecondsSinceEpoch}.mp4',
    );
    // 内容不重要，只看长度 —— 直接造一个超限的稀疏文件即可。
    file.writeAsBytesSync(List<int>.filled(20 * 1024 * 1024 + 1, 0));
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_host(VideoViewerScreen(
      path: file.path,
      title: 'big.mp4',
    )));
    await _settle(tester);

    expect(find.textContaining('can\'t be previewed in-app'), findsOneWidget);
  });
}
