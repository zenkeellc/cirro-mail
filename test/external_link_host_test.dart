// 外部链接接线柱（`ExternalLinkHost`）：入站 URI → 问扩展「去哪」→ 跳转。
//
// 这一组钉的是**接缝有没有接上**，不是某个具体产品：核心只做三件通用的事 ——
// 订阅每个扩展的流、按注册顺序问 `routeForExternalUri`、拿到地址就 `go`。
// 所以这里用**假 scheme**（`cirromailpro-test://`）与一个只有两条路由的小路由
// 表，不引任何产品代码。
//
// 为什么必须开真路由树（真 `GoRouter` + `MaterialApp.router`，而不是一个假
// 的导航器）：要验的正是「地址解出来对不对、go 之后落在哪一页」—— 用假导航器
// 只能验「我传了一个字符串进去」，而这段代码的失败模式恰恰是地址拼错、
// 落在 404，或者根本没人跳。
//
// 覆盖的语义（对应 `AppExtension` 那两段文档）：
//   ① 认得的链接 → 跳到扩展给的地址，参数原样带过去；
//   ② 没人认领 → 停在原地，不弹 UI、不抛；
//   ③ 多个扩展时**第一个非 null 的赢**（含「前面的返回 null，后面的接手」）；
//   ④ 流上冒错只 `debugPrint`，之后的链接照常处理（一条坏链接不能把链路打死）；
//   ⑤ 这一层被拆掉就退订；空注册表（公开版）什么都不做。
import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mail_app/features/deeplink/external_link_host.dart';
import 'package:mail_app/router.dart';

/// 假 scheme 的 host 段 —— `scheme://host?query` 里的那个 host。
const String _deeplinkHost = 'cirromailpro-test';

/// 一条「激活」深链。
Uri _activate(String code) =>
    Uri.parse('$_deeplinkHost://activate?code=$code');

/// 把 `…://activate?code=…` 映射到 `/activate-subscription?code=…` 的解析器。
///
/// 用 `Uri(...)` 拼而不是手写 `'…?code=$code'`：参数里一旦出现 `&`、`+`、
/// 非 ASCII，手拼出来的地址就会被 go_router 解析成另一个 query —— 这正是
/// 扩展侧真要小心的那件事（核心原样把字符串交给 `go`）。
String? _activateRoute(Uri uri) {
  if (uri.scheme != _deeplinkHost || uri.host != 'activate') return null;
  final code = uri.queryParameters['code'];
  if (code == null || code.isEmpty) return null;
  return Uri(
    path: '/activate-subscription',
    queryParameters: <String, String>{'code': code},
  ).toString();
}

/// 一个只会「送 URI」的假扩展。
///
/// [mapper] 就是 `routeForExternalUri`：返回 null 表示不认领。控制器由用例
/// 自己 `add` —— 要验的是「收到一条之后核心干了什么」，所以流从外面驱动。
class _FakeLinkExtension extends AppExtension {
  _FakeLinkExtension(this.id, {this.mapper});

  @override
  final String id;

  final String? Function(Uri uri)? mapper;

  final StreamController<Uri> controller = StreamController<Uri>();

  @override
  Stream<Uri> externalUriStream() => controller.stream;

  @override
  String? routeForExternalUri(Uri uri) => mapper?.call(uri);

  Future<void> close() => controller.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 单例跨用例存活，注册表要自己清（与 `app_extension_registry_test.dart`
  // 同一理由）。
  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  /// 装一棵「真路由器 + 接线柱」的最小树，停在主屏。
  ///
  /// 两页都用纯 `Text`：这一组只关心落在哪儿，页面本身没有可测的东西。
  Future<GoRouter> pumpHost(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: <RouteBase>[
        GoRoute(
          path: '/home',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('主屏'))),
        ),
        GoRoute(
          path: '/activate-subscription',
          builder: (context, state) => Scaffold(
            body: Center(
              child: Text('激活页 code=${state.uri.queryParameters['code']}'),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [routerProvider.overrideWithValue(router)],
        child: MaterialApp.router(
          routerConfig: router,
          // 接线柱挂在 **builder** 里 —— 与 `lib/app.dart` 相同的位置。
          builder: (context, child) =>
              ExternalLinkHost(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// 拆树并推一帧（流订阅的取消是异步的，见 `_ExternalLinkHostState.dispose`）。
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('认得的链接：go 到扩展给的地址，参数原样带过去', (tester) async {
    final extension = _FakeLinkExtension('fake.activate', mapper: _activateRoute);
    addTearDown(extension.close);
    AppExtensionRegistry.instance.registerAll(<AppExtension>[extension]);

    await pumpHost(tester);
    expect(find.text('主屏'), findsOneWidget, reason: '起始就在主屏');

    extension.controller.add(_activate('ABC'));
    await tester.pumpAndSettle();

    expect(find.text('激活页 code=ABC'), findsOneWidget);
    expect(find.text('主屏'), findsNothing, reason: 'go 是替换，不是压栈');
    await disposeTree(tester);
  });

  testWidgets('没人认领的链接：停在原地，不弹 UI 也不抛', (tester) async {
    final extension = _FakeLinkExtension('fake.activate', mapper: _activateRoute);
    addTearDown(extension.close);
    AppExtensionRegistry.instance.registerAll(<AppExtension>[extension]);

    await pumpHost(tester);

    // 同一个扩展的流，但协议不认识（另一个 scheme、即别的 App 的链接）。
    extension.controller.add(Uri.parse('another-app://activate?code=ABC'));
    await tester.pumpAndSettle();

    expect(find.text('主屏'), findsOneWidget);
    expect(find.textContaining('激活页'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposeTree(tester);
  });

  testWidgets('前面的扩展返回 null 时，后面的接手（谁送到流里无关）', (tester) async {
    final first = _FakeLinkExtension('fake.first');
    final second = _FakeLinkExtension('fake.second', mapper: _activateRoute);
    addTearDown(first.close);
    addTearDown(second.close);
    AppExtensionRegistry.instance
        .registerAll(<AppExtension>[first, second]);

    await pumpHost(tester);

    // 从**第一个**扩展的流进来一条它自己不认识的链接 —— 解析归第二个扩展。
    // 流是「谁送来的」，`routeForExternalUri` 是「谁认得它」，两件独立的事。
    first.controller.add(_activate('XYZ'));
    await tester.pumpAndSettle();

    expect(find.text('激活页 code=XYZ'), findsOneWidget);
    await disposeTree(tester);
  });

  testWidgets('两个扩展都认领时，按注册顺序第一个赢', (tester) async {
    final first = _FakeLinkExtension(
      'fake.first',
      mapper: (uri) => _activateRoute(uri) == null
          ? null
          : '/activate-subscription?code=first',
    );
    final second = _FakeLinkExtension(
      'fake.second',
      mapper: (uri) => _activateRoute(uri) == null
          ? null
          : '/activate-subscription?code=second',
    );
    addTearDown(first.close);
    addTearDown(second.close);
    AppExtensionRegistry.instance
        .registerAll(<AppExtension>[first, second]);

    await pumpHost(tester);

    // 从第二个扩展的流送进来也一样：顺序由注册表定，不由流定。
    second.controller.add(_activate('ABC'));
    await tester.pumpAndSettle();

    expect(find.text('激活页 code=first'), findsOneWidget);
    expect(find.text('激活页 code=second'), findsNothing);
    await disposeTree(tester);
  });

  testWidgets('流上冒错只记一行，之后的链接照常处理', (tester) async {
    final extension = _FakeLinkExtension('fake.activate', mapper: _activateRoute);
    addTearDown(extension.close);
    AppExtensionRegistry.instance.registerAll(<AppExtension>[extension]);

    await pumpHost(tester);

    // 启动期来了一条「坏链接」—— 不该把 App 打红，也不该把订阅弄死。
    extension.controller.addError(StateError('坏链接'));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'onError 已经接住了');

    extension.controller.add(_activate('OK'));
    await tester.pumpAndSettle();
    expect(find.text('激活页 code=OK'), findsOneWidget);
    await disposeTree(tester);
  });

  testWidgets('这一层被拆掉就退订', (tester) async {
    final extension = _FakeLinkExtension('fake.activate', mapper: _activateRoute);
    addTearDown(extension.close);
    AppExtensionRegistry.instance.registerAll(<AppExtension>[extension]);

    await pumpHost(tester);
    expect(extension.controller.hasListener, isTrue);

    await disposeTree(tester);
    expect(extension.controller.hasListener, isFalse);

    // 退订之后再送一条：没有监听者，也就不会去碰已经拆掉的 `ref`。
    extension.controller.add(_activate('LATE'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('空注册表（公开版）：child 原样返回，什么都不订阅', (tester) async {
    await pumpHost(tester);

    expect(find.text('主屏'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposeTree(tester);
  });
}
