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
    this.securityCards = 0,
    this.notificationCards = 0,
    this.composeCards = 0,
    this.extraRoutes = 0,
    this.branchRoutes = 0,
    this.onBoot,
    this.actions = 0,
    this.sections = 0,
    this.allow,
    this.prepareFail = false,
    this.onPrepare,
    this.autoLoad = false,
    this.rewrite,
    this.name,
    this.closed,
    this.closeFail = false,
    this.binding,
    this.bindingFail = false,
    this.onDraft,
    this.draftCalls,
    this.draftFail = false,
    this.warning,
    this.warningFail = false,
  });

  @override
  final String id;

  final int cards;

  /// 往「设置 → 安全」页末尾插几块。
  final int securityCards;

  /// 往「设置 → 通知」页末尾插几块。
  final int notificationCards;

  /// 往「设置 → 写邮件」页末尾插几块。
  final int composeCards;
  final int extraRoutes;

  /// 往**邮件那一支**（壳里）插几条路由。
  final int branchRoutes;
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

  /// 是否默认放行外联资源。
  final bool autoLoad;

  /// 外联资源地址改写。
  final String? Function(String url)? rewrite;

  /// 声明的产品名（`AppExtension.appDisplayName`），null = 不参与命名。
  final String? name;

  /// 记录 `onComposeClosed` 收到的参数（null = 不关心，不记账）。
  final List<({String profileId, String? draftUid})>? closed;

  /// `onComposeClosed` 抛不抛 —— 用来验注册表吞异常、不影响后面的扩展。
  final bool closeFail;

  /// 本机订阅的设备身份（`AppExtension.pushLicenseBinding`），null = 没有订阅。
  final ({String licenseId, String licenseDeviceId})? binding;

  /// 读绑定抛不抛 —— 验注册表「一条坏实现不拖累下一个」的纪律。
  final bool bindingFail;

  /// `onDraftChanged` 里要 await 的东西（null = 立刻返回）。测试用 `Completer`
  /// 卡住它，验「注册表是逐个 await 的」。
  final Future<void> Function()? onDraft;

  /// `onDraftChanged` 被调用时往里记自己的 id（null = 不记账）。
  final List<String>? draftCalls;

  /// `onDraftChanged` 抛不抛 —— 同样验注册表吞异常。
  final bool draftFail;

  /// 写信页警示（`AppExtension.draftWarning`）返回什么；null = 基类默认（不报）。
  final String? Function(String profileId, int draftId)? warning;

  /// `draftWarning` 抛不抛 —— 验注册表「一条坏实现不挡下一个」的纪律。
  final bool warningFail;

  @override
  ({String licenseId, String licenseDeviceId})? get pushLicenseBinding {
    if (bindingFail) throw StateError('$id 读订阅身份失败');
    return binding;
  }

  @override
  Future<String?> draftWarning({
    required String profileId,
    required int draftId,
  }) async {
    if (warningFail) throw StateError('$id 读写信页警示失败');
    return warning?.call(profileId, draftId);
  }

  @override
  Future<void> onDraftChanged() async {
    draftCalls?.add(id);
    final hook = onDraft;
    if (hook != null) await hook();
    if (draftFail) throw StateError('$id 处理草稿事件失败');
  }

  @override
  String? get appDisplayName => name;

  @override
  List<Widget> aboutExtras(BuildContext context) =>
      <Widget>[for (var i = 0; i < cards; i++) Text('$id#$i')];

  @override
  List<Widget> securityExtras(BuildContext context) =>
      <Widget>[for (var i = 0; i < securityCards; i++) Text('sec:$id#$i')];

  @override
  List<Widget> notificationExtras(BuildContext context) => <Widget>[
        for (var i = 0; i < notificationCards; i++) Text('notify:$id#$i'),
      ];

  @override
  List<Widget> composeExtras(BuildContext context) =>
      <Widget>[for (var i = 0; i < composeCards; i++) Text('compose:$id#$i')];

  @override
  List<RouteBase> routes() => <RouteBase>[
        for (var i = 0; i < extraRoutes; i++)
          GoRoute(
            path: '/$id/$i',
            builder: (context, state) => const SizedBox.shrink(),
          ),
      ];

  @override
  List<RouteBase> mailBranchRoutes() => <RouteBase>[
        for (var i = 0; i < branchRoutes; i++)
          GoRoute(
            path: '/$id-branch/$i',
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
  Future<void> onComposeClosed({
    required String profileId,
    String? draftUid,
  }) async {
    closed?.add((profileId: profileId, draftUid: draftUid));
    if (closeFail) throw StateError('$id 退出通知失败');
  }

  @override
  Future<void> prepareNotificationPolicy() async {
    onPrepare?.call();
    if (prepareFail) throw StateError('$id 读配置失败');
  }

  @override
  bool allowsNotification(NotificationCandidate candidate) =>
      allow?.call(candidate) ?? true;

  @override
  bool get autoLoadExternalResources => autoLoad;

  @override
  String? rewriteExternalResourceUrl(String url) => rewrite?.call(url);
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

/// 一个只记「谁被挂上来了」的假 [DraftStore]。
///
/// 注册表只关心「挂没挂、谁挂的」，不碰数据 —— 所以这里全部返回空。契约细节
/// 的测试在公开仓的 `test/draft_store_test.dart`（核心实现那一侧）。
class _FakeDraftStore implements DraftStore {
  @override
  Stream<List<DraftSnapshot>> watchAll() =>
      const Stream<List<DraftSnapshot>>.empty();

  @override
  Future<List<DraftSnapshot>> listAll() async => const <DraftSnapshot>[];

  @override
  Future<DraftSnapshot?> byUid(String profileKey, String uid) async => null;

  @override
  Future<DraftSnapshot?> byLocalId(String profileId, int draftId) async => null;

  @override
  Future<void> applyRemote(DraftSnapshot remote) async {}

  @override
  Future<void> clearTombstones(String profileKey, Iterable<String> uids) async {}

  @override
  Future<List<DraftSnapshot>> listTombstones() async =>
      const <DraftSnapshot>[];

  @override
  Future<List<DraftProfileRef>> profiles() async => const <DraftProfileRef>[];

  @override
  Future<String?> profileIdFor(String profileKey) async => null;
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
      expect(AppExtensionRegistry.instance.securityExtras(context), isEmpty);
      expect(AppExtensionRegistry.instance.notificationExtras(context), isEmpty);
      expect(AppExtensionRegistry.instance.composeExtras(context), isEmpty);
      expect(AppExtensionRegistry.instance.routes(), isEmpty);
      expect(AppExtensionRegistry.instance.mailBranchRoutes(), isEmpty);
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

    testWidgets('securityExtras 按扩展顺序铺平', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', securityCards: 2),
        _FakeExt('b', securityCards: 1),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      final context = tester.element(find.byType(SizedBox).first);
      final texts = AppExtensionRegistry.instance
          .securityExtras(context)
          .cast<Text>()
          .map((t) => t.data)
          .toList();
      expect(texts, <String>['sec:a#0', 'sec:a#1', 'sec:b#0']);
    });

    /// 「设置 → 通知」页末尾的块。商业版把「免打扰」铺在这里，与内置的
    /// 应用内提醒 / 后台推送同一页 —— 以前它独占一栏、还排在「诊断」与
    /// 「安全」之间，用户得跨半页去比对两处开关。
    testWidgets('notificationExtras 按扩展顺序铺平', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', notificationCards: 2),
        _FakeExt('b', notificationCards: 1),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      final context = tester.element(find.byType(SizedBox).first);
      final texts = AppExtensionRegistry.instance
          .notificationExtras(context)
          .cast<Text>()
          .map((t) => t.data)
          .toList();
      expect(texts, <String>['notify:a#0', 'notify:a#1', 'notify:b#0']);
    });

    /// 「设置 → 写邮件」页末尾的块。商业版的「云草稿同步」铺在这里：
    /// 草稿是写信的另一半，单独占一栏会让人以为它跟写信无关。
    testWidgets('composeExtras 按扩展顺序铺平', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', composeCards: 1),
        _FakeExt('b', composeCards: 2),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      final context = tester.element(find.byType(SizedBox).first);
      final texts = AppExtensionRegistry.instance
          .composeExtras(context)
          .cast<Text>()
          .map((t) => t.data)
          .toList();
      expect(texts, <String>['compose:a#0', 'compose:b#0', 'compose:b#1']);
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

    /// 壳内路由是**另一条出口**，与 [routes] 分开铺平。
    ///
    /// 两条合成一条的话，调用方拿到的列表里混着「顶层」与「壳内」两种形态，
    /// 而形态差异（渲染在哪个 Navigator 上）在列表里看不出来 —— 混错了的
    /// 症状是点进核心页面当场红屏（见 `AppExtension.mailBranchRoutes`）。
    testWidgets('mailBranchRoutes 是独立的一条出口，按扩展顺序铺平', (tester) async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', extraRoutes: 1, branchRoutes: 1),
        _FakeExt('b', branchRoutes: 2),
      ]);
      expect(
        AppExtensionRegistry.instance
            .routes()
            .cast<GoRoute>()
            .map((r) => r.path)
            .toList(),
        <String>['/a/0'],
        reason: '顶层那条出口只该有 routes() 的货',
      );
      expect(
        AppExtensionRegistry.instance
            .mailBranchRoutes()
            .cast<GoRoute>()
            .map((r) => r.path)
            .toList(),
        <String>['/a-branch/0', '/b-branch/0', '/b-branch/1'],
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

  group('本地草稿读取 / 写回口', () {
    test('没挂时是 null（公开版就是这个样子）', () {
      expect(AppExtensionRegistry.instance.draftStore, isNull);
    });

    test('挂上之后读得到，且 Ready 随之完成', () async {
      final store = _FakeDraftStore();
      AppExtensionRegistry.instance.attachDraftStore(store);
      expect(AppExtensionRegistry.instance.draftStore, same(store));
      expect(await AppExtensionRegistry.instance.draftStoreReady, same(store));
    });

    /// 第二次必须是**空操作**（与 `attachMailStore` 同一取舍）。
    ///
    /// `BootstrapGate` 的重试会重建整棵 `ProviderScope`、建一个新的
    /// `AppDatabase`，允许覆盖的话同步层会拿着两个库句柄推同一批草稿 ——
    /// 其中一个可能已经关掉了。那比「不生效」难查得多。
    test('第二次 attach 是空操作（重试不会换掉 store）', () async {
      final first = _FakeDraftStore();
      final second = _FakeDraftStore();
      AppExtensionRegistry.instance.attachDraftStore(first);
      AppExtensionRegistry.instance.attachDraftStore(second);
      expect(AppExtensionRegistry.instance.draftStore, same(first));
      expect(await AppExtensionRegistry.instance.draftStoreReady, same(first));
    });

    /// 「挂上来了」这件事**只有一个来源**：扩展在启动钩子里 await 它就能醒，
    /// 不必轮询、也不必赌「库一定第几帧建好」。
    test('draftStoreReady 在 attach 之前 await 也不会挂住调用方', () async {
      final pending = AppExtensionRegistry.instance.draftStoreReady;
      final store = _FakeDraftStore();
      AppExtensionRegistry.instance.attachDraftStore(store);
      expect(await pending, same(store));
    });

    test('reset 清空并把 ready 重建为未完成', () async {
      AppExtensionRegistry.instance.attachDraftStore(_FakeDraftStore());
      AppExtensionRegistry.instance.reset();
      expect(AppExtensionRegistry.instance.draftStore, isNull);

      var completed = false;
      unawaited(
        AppExtensionRegistry.instance.draftStoreReady.then((_) {
          completed = true;
        }),
      );
      await pumpEventQueue();
      expect(completed, isFalse, reason: 'reset 后 ready 必须是新的未完成 Completer');

      // 重建后的 ready 跟着下一次 attach 完成，而不是永远挂着。
      final next = _FakeDraftStore();
      AppExtensionRegistry.instance.attachDraftStore(next);
      expect(await AppExtensionRegistry.instance.draftStoreReady, same(next));
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

  group('写信页退出通知', () {
    /// 公开版（没装任何扩展）就是这个样子：调用方是 `unawaited`，
    /// 这里必须是「立刻完成且什么都不做」，不能抛、也不能挂住。
    test('空注册表：安全的空操作（公开版行为）', () async {
      await AppExtensionRegistry.instance
          .notifyComposeClosed(profileId: 'p1');
    });

    /// 退出路径上的钩子：前一个扩展炸了，后一个**仍要收到**，而且异常不能
    /// 漏给调用方（核心那边是 `unawaited`，漏出去就是一条未捕获的 zone 错误）。
    test('第一个扩展抛错：第二个仍收到同一事件，且不冒泡', () async {
      final closed = <({String profileId, String? draftUid})>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('boom', closeFail: true),
        _FakeExt('ok', closed: closed),
      ]);
      await AppExtensionRegistry.instance
          .notifyComposeClosed(profileId: 'p1', draftUid: 'uid-1');
      expect(closed, hasLength(1), reason: '前一个抛错不能挡掉后一个');
      expect(closed.single.profileId, 'p1');
      expect(closed.single.draftUid, 'uid-1', reason: '参数要原样传下去');
    });
  });

  group('写信页警示', () {
    /// 公开版（空注册表）恒为 null —— 写信页那一趟因此什么都不画。
    test('空注册表：null', () async {
      expect(
        await AppExtensionRegistry.instance
            .draftWarningFor(profileId: 'p1', draftId: 7),
        isNull,
      );
    });

    /// 都返回 null / 空白串 = 不显示；空白串不能把后面真有问题的那一条挡掉。
    test('全为 null / 空白串 → null；空白按「不认领」继续问下一个', () async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('none'),
        _FakeExt('blank', warning: (_, _) => '   '),
        _FakeExt('real', warning: (_, _) => '这条草稿有附件没下完'),
      ]);
      expect(
        await AppExtensionRegistry.instance
            .draftWarningFor(profileId: 'p1', draftId: 7),
        '这条草稿有附件没下完',
      );

      AppExtensionRegistry.instance.reset();
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('blank', warning: (_, _) => ''),
      ]);
      expect(
        await AppExtensionRegistry.instance
            .draftWarningFor(profileId: 'p1', draftId: 7),
        isNull,
      );
    });

    test('按注册顺序取第一个非空，参数原样传下去', () async {
      final calls = <({String profileId, int draftId})>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', warning: (profileId, draftId) {
          calls.add((profileId: profileId, draftId: draftId));
          return 'A 的警示';
        }),
        _FakeExt('b', warning: (_, _) => 'B 的警示'),
      ]);
      final text = await AppExtensionRegistry.instance
          .draftWarningFor(profileId: 'p2', draftId: 42);
      expect(text, 'A 的警示');
      expect(calls.single.profileId, 'p2');
      expect(calls.single.draftId, 42);
    });

    /// 这句跑在写信页的构建帧里：一条坏实现既不能把页面打红，也不能挡住
    /// 后面那个真有问题要报的扩展。
    test('第一个扩展抛错：第二个仍被问到', () async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('boom', warningFail: true),
        _FakeExt('ok', warning: (_, _) => '还是我'),
      ]);
      expect(
        await AppExtensionRegistry.instance
            .draftWarningFor(profileId: 'p1', draftId: 1),
        '还是我',
      );
    });
  });

  group('云草稿推送', () {
    /// 公开版（空注册表）恒为 null —— 核心的注册请求因此与没有这条接缝时
    /// 逐字相同，老中转端也不受影响。
    test('pushLicenseBinding：空注册表是 null', () {
      expect(AppExtensionRegistry.instance.pushLicenseBinding, isNull);
    });

    test('pushLicenseBinding：按注册顺序取第一个非 null', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('no-sub'),
        _FakeExt(
          'pro-a',
          binding: (licenseId: 'CM-A', licenseDeviceId: 'dev-a'),
        ),
        _FakeExt(
          'pro-b',
          binding: (licenseId: 'CM-B', licenseDeviceId: 'dev-b'),
        ),
      ]);
      final binding = AppExtensionRegistry.instance.pushLicenseBinding;
      expect(binding?.licenseId, 'CM-A', reason: '设备身份只能有一个');
      expect(binding?.licenseDeviceId, 'dev-a');
    });

    /// 一条坏实现**不该把后面的真订阅一起吞掉**（与 [managedPushConfig] /
    /// [prepareNotificationPolicies] 同一条纪律）。这里第一扩展在 getter 里
    /// 直接抛，第二个给出有效绑定 —— 注册请求不该因此退回「不带 license」。
    test('pushLicenseBinding：第一个扩展抛错，第二个的有效绑定仍被采用', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('boom', bindingFail: true),
        _FakeExt('pro', binding: (licenseId: 'CM-A', licenseDeviceId: 'dev-a')),
      ]);
      final binding = AppExtensionRegistry.instance.pushLicenseBinding;
      expect(binding?.licenseId, 'CM-A');
      expect(binding?.licenseDeviceId, 'dev-a');
    });

    /// `licenseId` 是路由键：空白串与「没有绑定」等价（与 [appDisplayName]
    /// 的「空白不算认领」同一口径）。它若不跳过，一次配空了的绑定会告诉中转端
    /// 「这台设备没有 license」，把后面那个真订阅盖掉。
    test('pushLicenseBinding：licenseId 空白不算认领，继续往后找', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('blank', binding: (licenseId: '   ', licenseDeviceId: 'dev-x')),
        _FakeExt('pro', binding: (licenseId: '  CM-A  ', licenseDeviceId: ' dev-a ')),
      ]);
      final binding = AppExtensionRegistry.instance.pushLicenseBinding;
      expect(binding?.licenseId, 'CM-A', reason: '传给中转端的值不该带首尾空白');
      expect(binding?.licenseDeviceId, 'dev-a');
    });

    /// 与 [notifyComposeClosed] 同一纪律：**逐个 await**。两个扩展各拉一轮
    /// 会把同一条事件变成两轮请求（也违反「实现必须幂等」的兜底假设），所以
    /// 前一个没完成之前，后一个不能开始。
    test('notifyDraftChanged：第一个没完成前第二个不开始（逐个 await）', () async {
      final gate = Completer<void>();
      final calls = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('slow', draftCalls: calls, onDraft: () => gate.future),
        _FakeExt('fast', draftCalls: calls),
      ]);

      final running = AppExtensionRegistry.instance.notifyDraftChanged();
      await pumpEventQueue();
      expect(calls, <String>['slow'], reason: '前一个还卡着，后一个必须还没开始');

      gate.complete();
      await running;
      expect(calls, <String>['slow', 'fast']);
    });

    /// 与 [notifyComposeClosed] 同一纪律：核心是 `unawaited` 调它，这里
    /// 必须立刻完成、什么都不做，也不能抛。
    test('notifyDraftChanged：空注册表是安全的空操作', () async {
      await AppExtensionRegistry.instance.notifyDraftChanged();
    });

    test('notifyDraftChanged：逐个调用，一个抛错不影响另一个', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('bad', draftFail: true),
        _FakeExt('good', draftCalls: calls),
      ]);
      await AppExtensionRegistry.instance.notifyDraftChanged();
      expect(calls, <String>['good'], reason: '前一个抛错不能挡掉后一个');
    });

    test('notifyDraftChanged：按注册顺序串行', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', draftCalls: calls),
        _FakeExt('b', draftCalls: calls),
      ]);
      await AppExtensionRegistry.instance.notifyDraftChanged();
      expect(calls, <String>['a', 'b']);
    });
  });

  group('推送重新登记触发器', () {
    /// 公开版（核心没挂触发器），或者核心还没走到初始化：扩展在 license
    /// 就绪时调它必须是安静的 no-op —— 不能抛，也不能挂住调用方。
    test('未挂钩子时 requestPushSync 是安全的空操作', () async {
      await AppExtensionRegistry.instance.requestPushSync();
    });

    test('挂上之后 requestPushSync 恰好触发一次', () async {
      var calls = 0;
      AppExtensionRegistry.instance.attachPushSyncTrigger(() async {
        calls++;
      });
      await AppExtensionRegistry.instance.requestPushSync();
      expect(calls, 1);
    });

    /// 核心的重试会重建整棵 `ProviderScope`，`NotificationHost` 的 initState
    /// 可能走第二次；第二个触发器若覆盖第一个，就会指向一个已经废弃的 `ref`。
    /// 所以只认第一次 —— 与 [attachMailStore] / [attachDraftStore] 同一口径。
    test('attach 幂等：第二次不覆盖第一个', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance.attachPushSyncTrigger(() async {
        calls.add('first');
      });
      AppExtensionRegistry.instance.attachPushSyncTrigger(() async {
        calls.add('second');
      });
      await AppExtensionRegistry.instance.requestPushSync();
      expect(calls, <String>['first']);
    });

    /// 扩展多半是在 `onBootstrap` 里 `unawaited` 地调它 —— 异常漏出去就是一条
    /// 未捕获的 zone 错误；补登记本来就是尽力而为的事，留一行日志即可。
    test('触发器抛错不冒泡（requestPushSync 正常完成）', () async {
      AppExtensionRegistry.instance.attachPushSyncTrigger(() async {
        throw StateError('补登记失败');
      });
      await expectLater(
        AppExtensionRegistry.instance.requestPushSync(),
        completes,
      );
    });

    /// `reset` 是「回到没挂」的状态：清掉之后 request 是 no-op，而且可以重新
    /// 挂（测试里每个用例前后都 reset）。
    test('reset 清掉触发器，之后可以重新挂', () async {
      var oldCalls = 0;
      AppExtensionRegistry.instance.attachPushSyncTrigger(() async {
        oldCalls++;
      });
      AppExtensionRegistry.instance.reset();

      await AppExtensionRegistry.instance.requestPushSync();
      expect(oldCalls, 0, reason: 'reset 之后不该再调旧触发器');

      var newCalls = 0;
      AppExtensionRegistry.instance.attachPushSyncTrigger(() async {
        newCalls++;
      });
      await AppExtensionRegistry.instance.requestPushSync();
      expect(newCalls, 1);
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

  group('外联资源策略', () {
    test('空注册表：默认拦截且不改写（公开版行为）', () {
      expect(AppExtensionRegistry.instance.autoLoadExternalResources, isFalse);
      expect(
        AppExtensionRegistry.instance
            .rewriteExternalResourceUrl('https://cdn.example.com/a.png'),
        isNull,
      );
    });

    test('autoLoad 是 OR：任一扩展说放行就放行', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a'),
        _FakeExt('b', autoLoad: true),
      ]);
      expect(AppExtensionRegistry.instance.autoLoadExternalResources, isTrue);
    });

    test('改写按注册顺序取第一个非 null，后者不覆盖前者', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a'),
        _FakeExt('b', rewrite: (url) => 'https://b.example/?$url'),
        _FakeExt('c', rewrite: (url) => 'https://c.example/?$url'),
      ]);
      expect(
        AppExtensionRegistry.instance
            .rewriteExternalResourceUrl('https://cdn.example.com/a.png'),
        'https://b.example/?https://cdn.example.com/a.png',
      );
    });

    test('不 return 的扩展不会把前面的改写结果盖成 null', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a', rewrite: (url) => 'https://proxy.example/?$url'),
        _FakeExt('b'),
      ]);
      expect(
        AppExtensionRegistry.instance
            .rewriteExternalResourceUrl('https://cdn.example.com/a.png'),
        'https://proxy.example/?https://cdn.example.com/a.png',
      );
    });
  });

  group('入站外部链接（深链）', () {
    /// 默认实现是「两条都是空的」：没有流、也不认领任何 URI。
    ///
    /// 这不是「还没实现」，而是**公开版的既定行为**：核心的
    /// `external_link_host.dart` 因此一个流都不订阅、一条链接都跳不了 ——
    /// 空注册表 ⇒ 行为逐字节不变。真正的 scheme 注册与 URI 解析全在扩展里，
    /// 核心**不认识任何一个 scheme**（见 `AppExtension.externalUriStream`
    /// 那段文档）。
    test('默认实现：流是空的，且不认领任何 URI（公开版空行为）', () async {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[_FakeExt('plain')]);
      final extension = AppExtensionRegistry.instance.extensions.single;

      // `const Stream.empty()` 订阅后立刻结束 —— 这里用 `toList()` 同时钉住
      // 「没有事件」与「流会正常收尾（不会把监听者挂住）」。
      expect(await extension.externalUriStream().toList(), isEmpty);
      expect(
        extension.routeForExternalUri(
          Uri.parse('example-app://activate?code=ABC'),
        ),
        isNull,
      );
      // 普通 http(s) 链接同样不归扩展管：默认实现返回 null 而不是自己乱猜。
      expect(
        extension.routeForExternalUri(Uri.parse('https://mail.example.com/')),
        isNull,
      );
    });
  });

  group('产品名', () {
    test('空注册表：null —— 核心回落到自己的默认名（公开版行为不变）', () {
      expect(AppExtensionRegistry.instance.appDisplayName, isNull);
    });

    test('按注册顺序取第一个非空；后来的不覆盖', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('a'),
        _FakeExt('b', name: 'Cirro Mail Pro'),
        _FakeExt('c', name: 'Another Name'),
      ]);
      expect(AppExtensionRegistry.instance.appDisplayName, 'Cirro Mail Pro');
    });

    test('空白名不算认领，继续往后找', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('blank', name: '   '),
        _FakeExt('pro', name: 'Cirro Mail Pro'),
      ]);
      expect(AppExtensionRegistry.instance.appDisplayName, 'Cirro Mail Pro');
    });

    test('首尾空白去掉（标题里不该多出空格）', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _FakeExt('pro', name: '  Cirro Mail Pro\n'),
      ]);
      expect(AppExtensionRegistry.instance.appDisplayName, 'Cirro Mail Pro');
    });
  });
}
