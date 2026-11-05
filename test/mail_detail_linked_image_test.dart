import 'package:cached_network_image/cached_network_image.dart';
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
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
  // 和 `mail_detail_external_resources_test.dart` 一样：扩展注册表是全局的，
  // 不重置的话将来某个 Pro 测试留下「自动加载外联资源」的实现，第三条用例
  // 就看不到 BlockedImageTile 了。
  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

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

  testWidgets('块级链接（营销邮件的常见写法）同样打开链接', (tester) async {
    final launched = _mockUrlLauncher(tester);
    final previewed = <String>[];

    await _pump(
      tester,
      '<a href="https://example.com/big">'
          '<div><img src="$_dataUri" width="80" height="40"></div>'
          '</a>',
      onTapImage: previewed.add,
    );

    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(launched, <String>['https://example.com/big']);
    expect(previewed, isEmpty);
  });

  testWidgets('相对 href 按 ossBase 解析后再打开', (tester) async {
    final launched = _mockUrlLauncher(tester);

    await _pump(
      tester,
      '<a href="/landing"><img src="$_dataUri" width="40" height="40"></a>',
    );

    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(launched, <String>['https://mail.example.com/landing']);
  });

  testWidgets('<a name> 不是链接：图片仍打开预览', (tester) async {
    final launched = _mockUrlLauncher(tester);
    final previewed = <String>[];

    await _pump(
      tester,
      '<a name="anchor"><img src="$_dataUri" width="40" height="40"></a>',
      onTapImage: previewed.add,
    );

    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(previewed, <String>[_dataUri]);
    expect(launched, isEmpty);
  });

  testWidgets('href="#" 不接管图片点击，避免打开 ossBase# 这种垃圾地址', (tester) async {
    final launched = _mockUrlLauncher(tester);
    final previewed = <String>[];

    await _pump(
      tester,
      '<a href="#"><img src="$_dataUri" width="40" height="40"></a>',
      onTapImage: previewed.add,
    );

    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(previewed, <String>[_dataUri]);
    expect(launched, isEmpty);
  });

  testWidgets('打不开的 href 保留图片预览，不会变成一次死点击', (tester) async {
    final launched = _mockUrlLauncher(tester);

    // `ftp://` 会被 `_onTapUrl` 拦下（只弹 toast）；前后带空格的地址在
    // `_onTapUrl` 里 `Uri.tryParse` 失败、被静默吞掉 —— 两种都是「点了没
    // 反应」，所以不该把点击从图片预览手里抢走。
    for (final href in <String>[
      'ftp://example.com/f',
      '  https://example.com/z  ',
    ]) {
      final previewed = <String>[];
      await _pump(
        tester,
        '<a href="$href"><img src="$_dataUri" width="40" height="40"></a>',
        onTapImage: previewed.add,
      );

      await tester.tap(find.byType(Image));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(previewed, <String>[_dataUri], reason: 'href=$href');
      expect(launched, isEmpty, reason: 'href=$href');
    }
  });

  testWidgets('带 title 的图片：Tooltip 还在，点击仍打开链接', (tester) async {
    final launched = _mockUrlLauncher(tester);

    await _pump(
      tester,
      '<a href="https://example.com/title">'
          '<img src="$_dataUri" width="40" height="40" title="点我看详情">'
          '</a>',
    );

    expect(find.byType(Tooltip), findsOneWidget);
    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(launched, <String>['https://example.com/title']);
  });

  testWidgets('同一段里带链接与不带链接的图各自路由', (tester) async {
    final launched = _mockUrlLauncher(tester);
    final previewed = <String>[];

    await _pump(
      tester,
      '<p><a href="https://example.com/a">'
          '<img src="$_dataUri" width="40" height="40">'
          '</a>'
          '<img src="$_dataUri" width="40" height="40">'
          '</p>',
      onTapImage: previewed.add,
    );

    await tester.tap(find.byType(Image).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(launched, <String>['https://example.com/a']);
    expect(previewed, isEmpty);

    await tester.tap(find.byType(Image).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(previewed, <String>[_dataUri]);
  });
}
