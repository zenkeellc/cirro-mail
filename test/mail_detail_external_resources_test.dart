import 'package:cached_network_image/cached_network_image.dart';
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/theme/app_theme.dart';
import 'package:mail_app/features/mail_detail/external_resource_banner.dart';
import 'package:mail_app/features/mail_detail/html_body_view.dart';
import 'package:mail_app/l10n/app_localizations.dart';

const _oss = 'https://mail.example.com/api/oss/';

/// 只实现「外联资源策略」的假扩展，用来验接缝真的接到了渲染层。
class _FakeExt extends AppExtension {
  _FakeExt({this.autoLoad = false, this.rewrite});

  final bool autoLoad;
  final String? Function(String url)? rewrite;

  @override
  String get id => 'test.external';

  @override
  bool get autoLoadExternalResources => autoLoad;

  @override
  String? rewriteExternalResourceUrl(String url) => rewrite?.call(url);
}

/// 网络图一旦真的建出来，`pumpAndSettle` 会挂住：`cached_network_image` 走
/// `flutter_cache_manager` → `path_provider`，widget 测试里那个 future 永远不
/// 完成（与附件缓存测试里踩到的是同一个坑）。所以凡是会建出网络图的地方都用
/// 固定帧数 `pump`，不用 settle。
Future<void> pumpFrame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> pumpBody(
  WidgetTester tester,
  String html, {
  String ossBase = _oss,
  bool settle = true,
  List<String> allowedHosts = const <String>[],
  void Function(String host)? onAllowHost,
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
            ossBase: ossBase,
            shrinkWrap: true,
            allowedHosts: allowedHosts,
            onAllowHost: onAllowHost,
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await pumpFrame(tester);
  }
}

void main() {
  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  testWidgets('外联图片默认拦截：占位块 + Banner 列出域名，正文里没有网络图', (tester) async {
    await pumpBody(
      tester,
      '<p>hi</p><img src="https://tracker.example.com/p.gif" alt="像素" '
      'width="200" height="100">',
    );

    expect(find.byType(BlockedImageTile), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.textContaining('已拦截 1 个外部资源'), findsOneWidget);
    expect(find.textContaining('tracker.example.com'), findsOneWidget);

    // 展开后能看到完整 URL 与单项启用按钮。
    await tester.tap(find.textContaining('查看 1 项'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('https://tracker.example.com/p.gif'),
      findsOneWidget,
    );
    expect(find.text('启用'), findsOneWidget);
  });

  testWidgets('点占位块等于只启用这一张，Banner 状态跟着变', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://a.example.com/x.png" width="200" height="100">',
    );

    await tester.tap(find.byType(BlockedImageTile));
    await pumpFrame(tester);

    expect(find.byType(BlockedImageTile), findsNothing);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.textContaining('已启用 1 个外部资源'), findsOneWidget);
  });

  testWidgets('全部启用 / 全部屏蔽', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://a.example.com/x.png" width="200" height="100">'
      '<img src="https://b.example.com/y.png" width="200" height="100">',
    );
    expect(find.textContaining('已拦截 2 个外部资源'), findsOneWidget);

    await tester.tap(find.text('全部启用'));
    await pumpFrame(tester);
    expect(find.byType(CachedNetworkImage), findsNWidgets(2));
    expect(find.textContaining('已启用 2 个外部资源'), findsOneWidget);

    await tester.tap(find.text('全部屏蔽'));
    await pumpFrame(tester);
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byType(BlockedImageTile), findsNWidgets(2));
  });

  testWidgets('1×1 追踪像素被拦但不占版面', (tester) async {
    await pumpBody(
      tester,
      '<p>hi</p><img src="https://tracker.example.com/p.gif" width="1" height="1">',
    );

    // Banner 里照旧列出；正文里不画占位块（否则页脚会多一个空框）。
    expect(find.textContaining('已拦截 1 个外部资源'), findsOneWidget);
    expect(find.byType(BlockedImageTile), findsNothing);
    expect(find.byType(CachedNetworkImage), findsNothing);
  });

  testWidgets('样式表与脚本只列出，标「无法启用」且没有启用按钮', (tester) async {
    await pumpBody(
      tester,
      '<link rel="stylesheet" href="https://css.example.com/a.css">'
      '<script src="https://js.example.com/a.js"></script><p>hi</p>',
    );

    expect(find.textContaining('已拦截 2 个外部资源'), findsOneWidget);
    await tester.tap(find.textContaining('查看 2 项'));
    await tester.pumpAndSettle();

    expect(find.text('无法启用'), findsNWidgets(2));
    expect(find.text('启用'), findsNothing);
    expect(find.textContaining('渲染器不应用外链样式表'), findsOneWidget);
    expect(find.textContaining('脚本不会执行'), findsOneWidget);
  });

  testWidgets('自家 OSS 图片不拦截、不出 Banner', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://mail.example.com/api/oss/a.png" width="200" height="100">',
      settle: false,
    );

    expect(find.byType(BlockedImageTile), findsNothing);
    expect(find.textContaining('已拦截'), findsNothing);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
  });

  testWidgets('Pro 接缝：启用后自动经 rewrite 地址加载，并标「经代理」', (tester) async {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      _FakeExt(rewrite: (url) => 'https://proxy.example/?$url'),
    ]);
    await pumpBody(
      tester,
      '<img src="https://a.example.com/x.png" width="200" height="100">',
    );

    await tester.tap(find.text('全部启用'));
    await pumpFrame(tester);

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(
      image.imageUrl,
      'https://proxy.example/?https://a.example.com/x.png',
    );

    await tester.tap(find.textContaining('查看 1 项'));
    await pumpFrame(tester);
    expect(find.text('经代理'), findsOneWidget);
  });

  testWidgets('Pro 自动加载：默认就放行，全部屏蔽能压回去', (tester) async {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      _FakeExt(autoLoad: true, rewrite: (url) => 'https://proxy.example/?$url'),
    ]);
    await pumpBody(
      tester,
      '<img src="https://a.example.com/x.png" width="200" height="100">',
      settle: false,
    );

    expect(find.byType(BlockedImageTile), findsNothing);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.textContaining('已启用 1 个外部资源'), findsOneWidget);

    await tester.tap(find.text('全部屏蔽'));
    await pumpFrame(tester);
    expect(find.byType(BlockedImageTile), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
  });

  testWidgets('1×1 追踪像素：额外一条安全提醒，并说明原因', (tester) async {
    await pumpBody(
      tester,
      '<p>hi</p>'
      '<img src="https://tracker.example.com/p.gif" width="1" height="1">'
      '<img src="https://cdn.example.com/a.png" width="600" height="300">',
    );

    // 资源 Banner 照旧；额外多一张追踪像素警告卡，讲清「为什么会这样」。
    expect(find.textContaining('已拦截 2 个外部资源'), findsOneWidget);
    expect(find.textContaining('检测到 1 个追踪像素'), findsOneWidget);
    expect(find.textContaining('记录你何时、从哪里、用什么设备打开了它'), findsOneWidget);
    expect(find.textContaining('来源：tracker.example.com'), findsOneWidget);
    expect(find.textContaining('这些图片默认已被拦截'), findsOneWidget);
  });

  testWidgets('没有 1×1 外链图时不出现追踪像素警告', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://cdn.example.com/a.png" width="600" height="300">',
    );

    expect(find.textContaining('追踪像素'), findsNothing);
    expect(find.textContaining('已拦截 1 个外部资源'), findsOneWidget);
  });

  testWidgets('启用追踪像素后，警告里写明「当前已加载」', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://tracker.example.com/p.gif" width="1" height="1">',
    );
    expect(find.textContaining('其中 1 个当前已加载'), findsNothing);

    await tester.tap(find.text('全部启用'));
    await pumpFrame(tester);

    expect(find.textContaining('其中 1 个当前已加载'), findsOneWidget);
    expect(find.textContaining('发件人可能已经收到打开记录'), findsOneWidget);
  });

  testWidgets('Pro 自动加载模式下也提醒，并标出已加载数量', (tester) async {
    AppExtensionRegistry.instance.registerAll(<AppExtension>[
      _FakeExt(autoLoad: true, rewrite: (url) => 'https://proxy.example/?$url'),
    ]);
    await pumpBody(
      tester,
      '<img src="https://tracker.example.com/p.gif" width="1" height="1">',
      settle: false,
    );

    expect(find.textContaining('检测到 1 个追踪像素'), findsOneWidget);
    expect(find.textContaining('其中 1 个当前已加载'), findsOneWidget);
  });

  testWidgets('1×1 写在 <style> 的 class 里也能触发追踪像素警告', (tester) async {
    await pumpBody(
      tester,
      '<style>.px{width:1px;height:1px}</style>'
      '<img class="px" src="https://tracker.example.com/p.gif">',
    );

    expect(find.textContaining('检测到 1 个追踪像素'), findsOneWidget);
    expect(find.textContaining('来源：tracker.example.com'), findsOneWidget);
  });

  testWidgets('只写一个方向的 1px 追踪图也提醒', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://tracker.example.com/p.gif" height="1">',
    );

    expect(find.textContaining('检测到 1 个追踪像素'), findsOneWidget);
  });

  // ── 域名白名单 ─────────────────────────────────────────────────────

  testWidgets('白名单里的域名默认放行，外链图直接加载、不进 Banner 的拦截列表', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://img.trusted.example/a.png" width="200" height="100">',
      allowedHosts: const <String>['*.trusted.example'],
      settle: false,
    );

    expect(find.byType(BlockedImageTile), findsNothing);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.textContaining('已启用 1 个外部资源'), findsOneWidget);
    expect(find.textContaining('已拦截'), findsNothing);
  });

  testWidgets('白名单只按域名生效：根域名与非子域名不受 *. 覆盖', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://trusted.example/a.png" width="200" height="100">'
      '<img src="https://evil-trusted.example/b.png" width="200" height="100">',
      allowedHosts: const <String>['*.trusted.example'],
    );

    expect(find.byType(BlockedImageTile), findsNWidgets(2));
    expect(find.textContaining('已拦截 2 个外部资源'), findsOneWidget);
  });

  testWidgets('白名单域名下的资源在 Banner 里标「白名单」且没有「始终允许」', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://img.trusted.example/a.png" width="200" height="100">',
      allowedHosts: const <String>['img.trusted.example'],
      settle: false,
    );

    await tester.tap(find.textContaining('查看 1 项'));
    // 放行之后正文里会有真网络图：`pumpAndSettle` 会挂在它永不完成的
    // 加载 future 上（见文件顶部 `pumpFrame` 的说明），这里只推几帧。
    await pumpFrame(tester);
    expect(find.text('白名单'), findsOneWidget);
    expect(find.text('始终允许'), findsNothing);
  });

  testWidgets('组头「始终允许」把域名交给宿主白名单回调', (tester) async {
    String? allowedHost;
    await pumpBody(
      tester,
      '<img src="https://a.example.com/x.png" width="200" height="100">',
      onAllowHost: (host) => allowedHost = host,
    );

    await tester.tap(find.textContaining('查看 1 项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('始终允许'));

    expect(allowedHost, 'a.example.com');
  });

  // ── 按域名分组 ─────────────────────────────────────────────────────

  testWidgets('资源列表按域名分组，域名按首次出现顺序，组头带条数', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://a.example.com/1.png" width="10" height="10">'
      '<img src="https://b.example.com/2.png" width="10" height="10">'
      '<img src="https://a.example.com/3.png" width="10" height="10">',
      settle: false,
    );

    await tester.tap(find.textContaining('查看 3 项'));
    await tester.pumpAndSettle();

    final banner = find.byType(ExternalResourceBanner);
    final hostA = find.descendant(
      of: banner,
      matching: find.text('a.example.com'),
    );
    final hostB = find.descendant(
      of: banner,
      matching: find.text('b.example.com'),
    );
    expect(hostA, findsOneWidget);
    expect(hostB, findsOneWidget);
    // a 有 2 个资源、b 有 1 个。
    expect(
      find.descendant(of: banner, matching: find.text('2 个资源')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: banner, matching: find.text('1 个资源')),
      findsOneWidget,
    );
    // 组顺序 = 域名首次出现顺序：a 在 b 上面。
    expect(tester.getTopLeft(hostA).dy, lessThan(tester.getTopLeft(hostB).dy));
  });

  // ── 警告色风格 ─────────────────────────────────────────────────────

  testWidgets('有资源被拦时 Banner 用警告色（琥珀）与警告图标', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://a.example.com/x.png" width="200" height="100">',
    );

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(ExternalResourceBanner),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, AppTheme.warningContainer(Brightness.light));
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('全部放行后 Banner 不再是警告色', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://a.example.com/x.png" width="200" height="100">',
      allowedHosts: const <String>['a.example.com'],
      settle: false,
    );

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(ExternalResourceBanner),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, isNot(AppTheme.warningContainer(Brightness.light)));
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  // ── 被拦图片的 alt / title ─────────────────────────────────────────

  testWidgets('被拦图片的 alt 只在悬浮层显示，不画进版面', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://cdn.example.com/a.png" alt="春季新品大图" '
      'width="200" height="100">',
    );

    // 版面里没有 alt 文案（占位块只有「外部图片已拦截」）。
    expect(find.text('春季新品大图'), findsNothing);

    await tester.longPress(find.byType(BlockedImageTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('春季新品大图'), findsOneWidget);
  });

  // ── 高度无界的布局 ────────────────────────────────────────────────
  //
  // fwfh 把 `<img>` 放进 `WidgetSpan`（正文 inline 混排）或做表格最小宽度
  // 探测时，子 widget 拿到的是「宽度受限、高度无界」的约束。占位块里的
  // `Align`（Container.alignment）与紧凑分支的 `OverflowBox` 都会撑到
  // `constraints.biggest`，无界高度就变成 Infinity ——
  // `RenderConstrainedOverflowBox object was given an infinite size`。真机上会
  // 连着重抛 RenderClipRect / RenderPositionedBox / … 一长串，并让后续绘制
  // 拿到 NaN。这里用完全相同的约束钉住。

  testWidgets('窄且高度无界时占位块自己定高，不会撑成无限', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 30,
              child: const BlockedImageTile(
                url: 'https://cdn.example.com/a.png',
                host: 'cdn.example.com',
              ),
            ),
          ),
        ),
      ),
    );

    // 关键断言：没有布局异常（修复前这里会抛 infinite size）。
    expect(tester.takeException(), isNull);

    final size = tester.getSize(find.byType(BlockedImageTile));
    expect(size.width, 30);
    expect(size.height.isFinite, isTrue);
    expect(size.height, greaterThanOrEqualTo(24));
  });

  testWidgets('没有 alt 时用 title 兜底', (tester) async {
    await pumpBody(
      tester,
      '<img src="https://cdn.example.com/a.png" title="页脚横幅" '
      'width="200" height="100">',
    );

    await tester.longPress(find.byType(BlockedImageTile));
    await tester.pumpAndSettle();
    // fwfh 自己那层 title Tooltip 被吞掉了（否则会跟这里的悬浮层叠成两个
    // 浮层），所以只有我们这一处说明文字。
    expect(find.textContaining('页脚横幅'), findsOneWidget);
  });
}
