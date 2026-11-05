// 图标徽章：把「全部实例的收件未读总数」推到系统图标上。
//
// 两个被测面：
//
// 1. `IconBadge.set` 的协议 —— 方法名 `setBadge`、参数 `{"count": int}`、
//    负数按 0、通道没接上时静默；
// 2. `IconBadgeHost` 的推送时机 —— 首帧补推、未读数变化推、相同数字不重复推、
//    归零推 0 清除，并且 child 原样返回。
//
// 与 `window_title_test.dart` 同一路数：通道名从实现里取（商业版检出会换前缀），
// mock handler 记下每一条调用。
//
// **不需要**覆盖 `debugDefaultTargetPlatformOverride`：徽章在五个平台都要推
// （手机桌面图标也是角标），实现里没有 `_isDesktop` 那样的平台闸门 ——
// 这正是它和 `WindowChannel.setTitle` 的区别。
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/notify/icon_badge.dart';
import 'package:mail_app/features/notifications/icon_badge_host.dart';
import 'package:mail_app/providers/sync_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 图标徽章通道。名字与五个 runner 注册的逐字一致；从实现里取，商业版
  /// 检出换了前缀也不用改测试。
  final badgeChannel = MethodChannel(IconBadge.channelName);

  List<MethodCall> captureBadgeCalls() {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(badgeChannel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(badgeChannel, null);
    });
    return calls;
  }

  /// 记下一串调用里的数字（按到达顺序）。
  List<int> countsOf(List<MethodCall> calls) => [
        for (final call in calls)
          (call.arguments as Map<Object?, Object?>)['count']! as int,
      ];

  Future<void> pumpHost(
    WidgetTester tester, {
    required Stream<Map<String, int>> unread,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          unreadByProfileProvider.overrideWith((ref) => unread),
        ],
        child: const IconBadgeHost(
          child: SizedBox(key: ValueKey<String>('icon-badge-child')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('IconBadge.set', () {
    test('发 setBadge，参数是 {"count": N}', () async {
      final calls = captureBadgeCalls();

      await IconBadge.set(7);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'setBadge');
      expect(calls.single.arguments, <String, Object?>{'count': 7});
    });

    test('负数按 0 处理（清除而不是显示 -1）', () async {
      final calls = captureBadgeCalls();

      await IconBadge.set(-3);

      expect(countsOf(calls), <int>[0]);
    });

    test('原生侧没接住（旧构建 / 通道缺失）：静默，不抛', () async {
      // 刻意不装 mock handler —— `invokeMethod` 会抛 `MissingPluginException`，
      // `IconBadge.set` 必须吞掉它。
      await expectLater(IconBadge.set(3), completes);
    });
  });

  group('IconBadgeHost', () {
    testWidgets('首帧之后补推一次：全部实例未读合计', (tester) async {
      final calls = captureBadgeCalls();

      await pumpHost(
        tester,
        unread: Stream.value(<String, int>{'p1': 2, 'p2': 3}),
      );

      expect(
        find.byKey(const ValueKey<String>('icon-badge-child')),
        findsOneWidget,
      );
      // 两条：**先**一条 0（冷启动时把上一次进程留下的旧角标清掉 —— iOS 的
      // `applicationIconBadgeNumber` 是跨启动持久的，不清就会一直挂着），
      // **再**等本地库的未读数到达后推 5。
      expect(countsOf(calls), <int>[0, 5]);
    });

    testWidgets('未读数变化：跟着推新数字', (tester) async {
      final calls = captureBadgeCalls();
      final controller = StreamController<Map<String, int>>();
      addTearDown(controller.close);

      await pumpHost(tester, unread: controller.stream);

      controller.add(<String, int>{'p1': 1});
      await tester.pumpAndSettle();
      controller.add(<String, int>{'p1': 4, 'p2': 6});
      await tester.pumpAndSettle();

      expect(countsOf(calls), <int>[0, 1, 10]);
    });

    testWidgets('相同数字不重复推（无关刷新不重绘原生图标）', (tester) async {
      final calls = captureBadgeCalls();
      final controller = StreamController<Map<String, int>>();
      addTearDown(controller.close);

      await pumpHost(tester, unread: controller.stream);

      controller.add(<String, int>{'p1': 3});
      await tester.pumpAndSettle();
      // 总数还是 3，但参与合计的实例换了一个 —— 对徽章来说这是「没变化」。
      controller.add(<String, int>{'p1': 1, 'p2': 2});
      await tester.pumpAndSettle();

      expect(countsOf(calls).where((count) => count == 3), hasLength(1));
    });

    testWidgets('未读归零：推 0 把角标清掉', (tester) async {
      final calls = captureBadgeCalls();
      final controller = StreamController<Map<String, int>>();
      addTearDown(controller.close);

      await pumpHost(tester, unread: controller.stream);

      controller.add(<String, int>{'p1': 3});
      await tester.pumpAndSettle();
      controller.add(const <String, int>{});
      await tester.pumpAndSettle();

      expect(countsOf(calls), <int>[0, 3, 0]);
    });
  });
}
