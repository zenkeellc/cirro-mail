import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 一个只在关于页挂一张卡片的假扩展 —— 用来验注册表把它的货拼了出来。
class _FakeExt extends AppExtension {
  _FakeExt(
    this.id, {
    this.cards = 1,
    this.extraRoutes = 0,
    this.onBoot,
    this.actions = 0,
    this.sections = 0,
    this.allow,
    this.prepareFail = false,
    this.onPrepare,
  });

  @override
  final String id;

  final int cards;
  final int extraRoutes;
  final Future<void> Function()? onBoot;

  /// 往顶栏插几颗按钮。
  final int actions;

  /// 往设置页插几栏。
  final int sections;

  /// 这一条准不准弹。null = 用基类的「恒 true」。
  final bool Function(NotificationCandidate candidate)? allow;

  /// `prepareNotificationPolicy` 抛不抛。
  final bool prepareFail;

  /// 记录 `prepareNotificationPolicy` 被调用时的顺序号。
  final void Function()? onPrepare;

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
  List<Widget> shellActions(BuildContext context) =>
      <Widget>[for (var i = 0; i < actions; i++) Text('action:$id#$i')];

  @override
  List<SettingsSection> settingsSections(BuildContext context) => <SettingsSection>[
        for (var i = 0; i < sections; i++)
          SettingsSection(
            id: '$id#$i',
            icon: Icons.circle_outlined,
            selectedIcon: Icons.circle,
            title: '$id#$i',
            body: (context) => Text('body:$id#$i'),
          ),
      ];

  @override
  Future<void> onBootstrap() async => onBoot?.call();

  @override
  Future<void> prepareNotificationPolicy() async {
    onPrepare?.call();
    if (prepareFail) throw StateError('$id 读配置失败');
  }

  @override
  bool allowsNotification(NotificationCandidate candidate) =>
      allow?.call(candidate) ?? true;
}

/// 一个只记「谁被挂上来了」的假 [MailStore]。
class _FakeStore implements MailStore {
  @override
  Future<List<LocalMail>> pageAfter({
    String? profileId,
    String? afterProfileId,
    int afterEmailId = 0,
    int limit = 500,
    bool withContent = true,
  }) async =>
      const <LocalMail>[];

  @override
  Future<int> count({String? profileId}) async => 0;

  @override
  Future<Set<int>> existingEmailIds(String profileId, Iterable<int> emailIds) async =>
      const <int>{};

  @override
  Future<List<LocalMail>> updatedSince(DateTime since, {String? profileId}) async =>
      const <LocalMail>[];

  @override
  Stream<MailStoreEvent> changes() => const Stream<MailStoreEvent>.empty();
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
      expect(AppExtensionRegistry.instance.shellActions(context), isEmpty);
      expect(AppExtensionRegistry.instance.settingsSections(context), isEmpty);
      expect(AppExtensionRegistry.instance.mailStore, isNull);
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

    testWidgets('shellActions 按扩展顺序铺平', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', actions: 2),
        _FakeExt('b', actions: 1),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      final context = tester.element(find.byType(SizedBox).first);
      expect(
        AppExtensionRegistry.instance
            .shellActions(context)
            .cast<Text>()
            .map((t) => t.data)
            .toList(),
        <String>['action:a#0', 'action:a#1', 'action:b#0'],
      );
    });

    testWidgets('settingsSections 按扩展顺序铺平', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', sections: 2),
        _FakeExt('b', sections: 1),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      final context = tester.element(find.byType(SizedBox).first);
      expect(
        AppExtensionRegistry.instance
            .settingsSections(context)
            .map((s) => s.id)
            .toList(),
        <String>['a#0', 'a#1', 'b#0'],
      );
    });
  });

  group('本地邮件读取口', () {
    test('没挂时是 null（公开版就是这个样子）', () {
      expect(AppExtensionRegistry.instance.mailStore, isNull);
    });

    test('挂上之后读得到，且 Ready 随之完成', () async {
      final store = _FakeStore();
      AppExtensionRegistry.instance.attachMailStore(store);
      expect(AppExtensionRegistry.instance.mailStore, same(store));
      expect(await AppExtensionRegistry.instance.mailStoreReady, same(store));
    });

    /// 第二次必须是**空操作**。
    ///
    /// `BootstrapGate` 的重试会重跑 `bootstrap()`、建一个新的 `AppDatabase`，
    /// 如果 `attachMailStore` 允许覆盖，扩展侧就会起第二个索引器 —— 同一份数据
    /// 灌两遍、两个连接互相抢锁。那比「不生效」难查得多。
    test('第二次 attach 是空操作（重试不会换掉 store）', () async {
      final first = _FakeStore();
      final second = _FakeStore();
      AppExtensionRegistry.instance.attachMailStore(first);
      AppExtensionRegistry.instance.attachMailStore(second);
      expect(AppExtensionRegistry.instance.mailStore, same(first));
      expect(await AppExtensionRegistry.instance.mailStoreReady, same(first));
    });

    /// 「挂上来了」这件事**只有一个来源**。谁先等谁先醒 ——
    /// 扩展的冷扫不必去轮询，也不必赌「库一定第几帧建好」。
    test('mailStoreReady 在 attach 之前 await 也不会挂住调用方', () async {
      final pending = AppExtensionRegistry.instance.mailStoreReady;
      final store = _FakeStore();
      AppExtensionRegistry.instance.attachMailStore(store);
      expect(await pending, same(store));
    });

    test('reset 之后回到「没挂」', () {
      AppExtensionRegistry.instance.attachMailStore(_FakeStore());
      AppExtensionRegistry.instance.reset();
      expect(AppExtensionRegistry.instance.mailStore, isNull);
    });
  });

  group('通知策略', () {
    test('空注册表恒放行（公开版行为不变）', () {
      expect(
        AppExtensionRegistry.instance
            .allowsNotification(const NotificationCandidate(profileId: 'p', emailId: 1)),
        isTrue,
      );
    });

    test('无参允许时放行，否决时拦住', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('mute', allow: (c) => c.emailId != 7),
      ]);
      bool allows(int id) => AppExtensionRegistry.instance
          .allowsNotification(NotificationCandidate(profileId: 'p', emailId: id));
      expect(allows(6), isTrue);
      expect(allows(7), isFalse);
    });

    /// 多个扩展之间是 **AND**：任何一个说别弹就不弹。
    ///
    /// 「静音」在用户心里的语义是「别打扰我」——另一个扩展把它翻回来说不过去。
    test('多个扩展之间是 AND', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', allow: (c) => c.emailId.isEven),
        _FakeExt('b', allow: (c) => c.emailId > 5),
      ]);
      bool allows(int id) => AppExtensionRegistry.instance
          .allowsNotification(NotificationCandidate(profileId: 'p', emailId: id));
      expect(allows(6), isTrue, reason: '偶数 且 >5');
      expect(allows(8), isTrue);
      expect(allows(4), isFalse, reason: '偶数但没 >5');
      expect(allows(7), isFalse, reason: '>5 但不是偶数');
    });

    test('prepareNotificationPolicies 逐个 await，顺序即注册顺序', () async {
      final order = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', onPrepare: () => order.add('a')),
        _FakeExt('b', onPrepare: () => order.add('b')),
      ]);
      await AppExtensionRegistry.instance.prepareNotificationPolicies();
      expect(order, <String>['a', 'b']);
    });

    /// 一个扩展读配置失败**不该拖累其他扩展**：通知判定是尽力而为的事，
    /// 坏掉的那个当作「没有规则」放行，而不是让整条通知链路都不弹了。
    test('单个扩展抛异常不影响其他扩展，也不冒泡出来', () async {
      final order = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('boom', prepareFail: true, onPrepare: () => order.add('boom')),
        _FakeExt('ok', onPrepare: () => order.add('ok')),
      ]);
      await AppExtensionRegistry.instance.prepareNotificationPolicies();
      expect(order, <String>['boom', 'ok']);
      // 失败的那个仍然是「没有规则」= 放行。
      expect(
        AppExtensionRegistry.instance
            .allowsNotification(const NotificationCandidate(profileId: 'p', emailId: 1)),
        isTrue,
      );
    });

    test('空注册表时 prepare 是安全的空操作', () async {
      await AppExtensionRegistry.instance.prepareNotificationPolicies();
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
