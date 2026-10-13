import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 一个只实现 `aboutExtras` 的假扩展 —— 用来验注册表把它的货拼了出来。
class _FakeExt extends AppExtension {
  _FakeExt(this.id, {this.cards = 1, this.extraRoutes = 0, this.onBoot});

  @override
  final String id;

  final int cards;
  final int extraRoutes;
  final Future<void> Function()? onBoot;

  @override
  List<Widget> aboutExtras(BuildContext context) =>
      <Widget>[for (var i = 0; i < cards; i++) Text('$id#$i')];

  @override
  List<RouteBase> routes() => <RouteBase>[
        for (var i = 0; i < extraRoutes; i++)
          GoRoute(
            path: '/$id/$i',
            builder: (context, state) => const SizedBox.shrink(),
          ),
      ];

  @override
  Future<void> onBootstrap() async => onBoot?.call();
}

void main() {
  // 单例跨用例存活，每个用例前后都清一次，免得互相串味。
  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  group('注册', () {
    test('按注册顺序拼接', () {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[_FakeExt('a'), _FakeExt('b')]);
      expect(
        AppExtensionRegistry.instance.extensions.map((e) => e.id),
        <String>['a', 'b'],
      );
    });

    test('id 重复的忽略，不覆盖先前那个', () {
      final first = _FakeExt('dup', cards: 3);
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        first,
        _FakeExt('dup', cards: 1),
      ]);
      expect(AppExtensionRegistry.instance.extensions, hasLength(1));
      expect(AppExtensionRegistry.instance.extensions.single, same(first));
    });

    test('extensions 是快照，改它不影响注册表', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[_FakeExt('a')]);
      expect(
        () => AppExtensionRegistry.instance.extensions.add(_FakeExt('b')),
        throwsUnsupportedError,
      );
    });
  });

  group('读取', () {
    testWidgets('空注册表：什么都不返回（公开版就是这个行为）', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final context = tester.element(find.byType(SizedBox).first);
      expect(AppExtensionRegistry.instance.aboutExtras(context), isEmpty);
      expect(AppExtensionRegistry.instance.routes(), isEmpty);
    });

    testWidgets('aboutExtras 按扩展顺序铺平', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', cards: 2),
        _FakeExt('b', cards: 1),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      final context = tester.element(find.byType(SizedBox).first);
      final texts = AppExtensionRegistry.instance
          .aboutExtras(context)
          .cast<Text>()
          .map((t) => t.data)
          .toList();
      expect(texts, <String>['a#0', 'a#1', 'b#0']);
    });

    testWidgets('routes 按扩展顺序铺平且路径原样', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', extraRoutes: 1),
        _FakeExt('b', extraRoutes: 1),
      ]);
      expect(
        AppExtensionRegistry.instance
            .routes()
            .cast<GoRoute>()
            .map((r) => r.path)
            .toList(),
        <String>['/a/0', '/b/0'],
      );
    });
  });

  group('启动钩子', () {
    test('bootstrapAll 不等待 —— 同步方法返回时 Future 还没结束', () {
      final gate = Completer<void>();
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('slow', onBoot: () => gate.future),
      ]);
      // 只要求它「发出去了且没把调用方挂住」：调用是同步返回的，
      // 到这里还没 await 那个 Future。把它放开，避免挂起的 Future 让
      // 测试框架在 tearDown 时抱怨。
      AppExtensionRegistry.instance.bootstrapAll();
      gate.complete();
    });
  });
}
