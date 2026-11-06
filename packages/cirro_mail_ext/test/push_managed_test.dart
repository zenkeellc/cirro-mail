import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 托管推送这两条接缝的**注册表出口**：
///
/// - `managedPushConfig()`：「问一圈，第一个非 null 的赢」，单个扩展抛异常
///   不拖累别人（推送是尽力而为的东西）；
/// - `pushSettings()`：「第一个返回非 null 的赢，全为 null 时原样构造回退」。
///
/// 这两条都不涉及核心 App，所以能在包自己的测试里钉住 —— 核心那边只需要
/// 相信「空注册表 = 既有行为」这个前提，而它正是下面第一组要钉的东西。
void main() {
  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  group('ManagedPushConfig', () {
    const full = ManagedPushConfig(
      relayUrl: 'https://push.example.com',
      instanceId: 'inst-1',
      deviceCode: 'CODE-1',
      entitlement: 'v1.payload.sig',
    );

    test('三条值齐了才算 usable', () {
      expect(full.usable, isTrue);
      expect(
        const ManagedPushConfig(
          relayUrl: '',
          instanceId: 'inst-1',
          deviceCode: 'CODE-1',
        ).usable,
        isFalse,
      );
      expect(
        const ManagedPushConfig(
          relayUrl: 'https://push.example.com',
          instanceId: '  ',
          deviceCode: 'CODE-1',
        ).usable,
        isFalse,
        reason: '空白串与空串同义 —— 扩展从 JSON 里解出来的值可能带空格',
      );
      expect(
        const ManagedPushConfig(
          relayUrl: 'https://push.example.com',
          instanceId: 'inst-1',
          deviceCode: '',
        ).usable,
        isFalse,
      );
    });

    test('订阅凭证与到期时间都是可选的（开源版的中转位不校验凭证）', () {
      const minimal = ManagedPushConfig(
        relayUrl: 'https://push.example.com',
        instanceId: 'inst-1',
        deviceCode: 'CODE-1',
      );
      expect(minimal.entitlement, isEmpty);
      expect(minimal.expiresAt, isNull);
      expect(minimal.usable, isTrue);
    });
  });

  group('AppExtension 的默认实现', () {
    test('不提供托管配置、也不接管推送设置页', () async {
      const ext = _NoopExt();
      expect(await ext.managedPushConfig(), isNull);
      expect(
        ext.pushSettings(
          _NoContext(),
          _NoopFacade(),
          () => const Text('回退'),
        ),
        isNull,
      );
    });
  });

  group('注册表：managedPushConfig', () {
    test('空注册表 → null（公开版逐字不变）', () async {
      expect(await AppExtensionRegistry.instance.managedPushConfig(), isNull);
    });

    test('按注册顺序取第一个非 null', () async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _NoopExt(),
        const _ManagedExt(config: _managedA),
        const _ManagedExt(id: 'ext.second', config: _managedB),
      ]);

      final config = await AppExtensionRegistry.instance.managedPushConfig();
      expect(config, isNotNull);
      expect(config!.instanceId, 'inst-1',
          reason: '第二个扩展也给了配置，但第一个赢 —— 一个进程只该有一条托管配置');
    });

    test('单个扩展抛异常时跳过它、继续问下一个', () async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _ThrowingExt(),
        const _ManagedExt(config: _managedB),
      ]);

      final config = await AppExtensionRegistry.instance.managedPushConfig();
      expect(config?.instanceId, 'inst-2');
    });

    test('全部返回 null → null', () async {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[const _NoopExt(), const _ManagedExt()]);
      expect(await AppExtensionRegistry.instance.managedPushConfig(), isNull);
    });
  });

  group('注册表：pushSettings', () {
    test('空注册表 → 原样调用回退构造器', () {
      var built = 0;
      final widget = AppExtensionRegistry.instance.pushSettings(
        _NoContext(),
        _NoopFacade(),
        () {
          built++;
          return const Text('回退');
        },
      );
      expect(built, 1);
      expect(widget, isA<Text>());
    });

    test('扩展返回 null → 回退', () {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[const _NoopExt()]);
      var built = 0;
      final widget = AppExtensionRegistry.instance.pushSettings(
        _NoContext(),
        _NoopFacade(),
        () {
          built++;
          return const Text('回退');
        },
      );
      expect(built, 1);
      expect(widget, isA<Text>());
    });

    test('第一个返回非 null 的赢，回退**一次都不构造**', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _NoopExt(),
        const _SettingsExt(id: 'ext.one', label: '第一个'),
        const _SettingsExt(id: 'ext.two', label: '第二个'),
      ]);
      var built = 0;
      final widget = AppExtensionRegistry.instance.pushSettings(
        _NoContext(),
        _NoopFacade(),
        () {
          built++;
          return const Text('回退');
        },
      );
      expect(built, 0, reason: '回退构造器一被调用就会打一轮网络（见 PushSection._load）');
      expect(widget, isA<Text>());
      expect((widget as Text).data, '第一个');
    });

    test('扩展自己可以调 fallback 把七页向导要回去', () {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[const _FallbackExt()]);
      final widget = AppExtensionRegistry.instance.pushSettings(
        _NoContext(),
        _NoopFacade(),
        () => const Text('回退'),
      );
      expect((widget as Text).data, '回退');
    });
  });
}

const ManagedPushConfig _managedA = ManagedPushConfig(
  relayUrl: 'https://push.example.com',
  instanceId: 'inst-1',
  deviceCode: 'CODE-1',
);
const ManagedPushConfig _managedB = ManagedPushConfig(
  relayUrl: 'https://push.example.com',
  instanceId: 'inst-2',
  deviceCode: 'CODE-2',
);

class _NoopExt extends AppExtension {
  const _NoopExt();

  @override
  String get id => 'ext.noop';
}

class _ManagedExt extends AppExtension {
  const _ManagedExt({this.id = 'ext.managed', this.config});

  @override
  final String id;
  final ManagedPushConfig? config;

  @override
  Future<ManagedPushConfig?> managedPushConfig() async => config;
}

class _ThrowingExt extends AppExtension {
  const _ThrowingExt();

  @override
  String get id => 'ext.throwing';

  @override
  Future<ManagedPushConfig?> managedPushConfig() async =>
      throw StateError('读配置失败');
}

class _SettingsExt extends AppExtension {
  const _SettingsExt({required this.id, required this.label});

  @override
  final String id;
  final String label;

  @override
  Widget? pushSettings(
    BuildContext context,
    PushFacade facade,
    Widget Function() fallback,
  ) =>
      Text(label);
}

class _FallbackExt extends AppExtension {
  const _FallbackExt();

  @override
  String get id => 'ext.fallback';

  @override
  Widget? pushSettings(
    BuildContext context,
    PushFacade facade,
    Widget Function() fallback,
  ) =>
      fallback();
}

/// 这些扩展都不读 context —— 拿一个「一读就抛」的假 context 最省事，也顺带
/// 钉住「注册表出口不该碰 context」。
class _NoContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('注册表出口不该读 context');
}

/// 门面在这组测试里没人调用（扩展只把它转手/忽略）。
class _NoopFacade implements PushFacade {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('这组测试不用 ${invocation.memberName}');
}
