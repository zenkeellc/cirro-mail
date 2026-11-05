import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/mail_detail/external_resource_banner.dart';
import 'package:mail_app/features/mail_detail/html_body_view.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 1×1 透明 GIF，避免测试里真的建网络图（`cached_network_image` 在 widget
/// 测试里会让 `pumpAndSettle` 永远挂着）。
const _dataUri =
    'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

const _oss = 'https://mail.example.com/api/oss/';

/// 拦住 `url_launcher` 的方法通道，记录「到底打开了哪个链接」。
///
/// `flutter_tester` 里没有 `url_launcher` 的平台实现，真调会抛（fwfh 自己
/// 会 catch 掉，测试就只能看到「什么都没发生」）。这里直接接管通道。
List<String> _mockUrlLauncher(WidgetTester tester) {
  final launched = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/url_launcher'),
    (call) async {
      switch (call.method) {
        case 'canLaunch':
          return true;
        case 'launch':
          launched.add((call.arguments as Map)['url'] as String);
          return true;
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
  });
  return launched;
}

Future<void> _pump(
  WidgetTester tester,
  String html, {
  void Function(String url)? onTapImage,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: SingleChildScrollView(
          child: HtmlBodyView(
            html: html,
            ossBase: _oss,
            shrinkWrap: true,
            onTapImage: onTapImage,
          ),
        ),
      ),
    ),
  );
  // 不用 pumpAndSettle：data URI 图片解码是异步的，而这里只需要布局做完。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('点带链接的图片：打开链接，而不是打开图片预览', (tester) async {
    final launched = _mockUrlLauncher(tester);
    final previewed = <String>[];

    await _pump(
      tester,
      '<p><a href="https://example.com/landing">'
          '<img src="$_dataUri" width="40" height="40">'
          '</a></p>',
      onTapImage: previewed.add,
    );

    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(launched, <String>['https://example.com/landing']);
    expect(previewed, isEmpty);
  });

  testWidgets('没有链接的图片照旧：点开图片预览', (tester) async {
    final launched = _mockUrlLauncher(tester);
    final previewed = <String>[];

    await _pump(
      tester,
      '<p><img src="$_dataUri" width="40" height="40"></p>',
      onTapImage: previewed.add,
    );

    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(previewed, <String>[_dataUri]);
    expect(launched, isEmpty);
  });

  testWidgets('被拦截的外联图片仍先「点一下启用」，不会被链接抢走', (tester) async {
    // 外联图默认拦截，占位块上的点击是「只启用这一张」的入口 —— 这里仍然是
    // 图片自己的手势赢，不能因为外面裹了 <a> 就变成打开链接、跳过启用。
    final launched = _mockUrlLauncher(tester);

    await _pump(
      tester,
      '<a href="https://example.com/landing">'
          '<img src="https://cdn.example.com/x.png" width="200" height="100">'
          '</a>',
    );

    expect(find.byType(BlockedImageTile), findsOneWidget);
    await tester.tap(find.byType(BlockedImageTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(launched, isEmpty);
    expect(find.byType(BlockedImageTile), findsNothing);

    // 启用之后再点，图片已经能显示，这时候才轮到链接。
    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(launched, <String>['https://example.com/landing']);
  });
}
