import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/config/app_defaults.dart';
import 'package:mail_app/features/settings/sections/push_section.dart';

/// 一个只提供「内置推送默认值」的假扩展。
///
/// 真扩展是商业版的 `CirroMailPro`（值编在 pro 包里）；这里只需要它能返回
/// 一组值，用来钉住 `resolveBuiltInPushDefaults` 的优先级。
class _FakeExtension extends AppExtension {
  const _FakeExtension(this.id, this.defaults);

  @override
  final String id;

  final PushDefaults? defaults;

  @override
  PushDefaults? get pushDefaults => defaults;
}

void main() {
  group('resolveBuiltInPushDefaults', () {
    // 通知：这些用例跑在**公开版**的编译期常量下 —— `AppDefaults` 里只有
    // 中转地址有默认值，实例位与配对码是空串（`--dart-define` 没注入）。
    // 所以「扩展兜底」才看得出来。

    test('没有扩展时，结果就是 --dart-define 那三个值（公开版行为不变）', () {
      final resolved = resolveBuiltInPushDefaults(const <AppExtension>[]);
      expect(resolved.relayUrl, AppDefaults.pushRelayUrl);
      expect(resolved.instanceId, AppDefaults.pushInstanceId);
      expect(resolved.pairingCode, AppDefaults.pushPairingCode);
    });

    test('扩展补上 --dart-define 留空的实例位与配对码', () {
      const builtIn = PushDefaults(
        relayUrl: 'https://push.example.com',
        instanceId: 'inst-0123456789abcdef0123456789abcdef',
        pairingCode: 'AAAA-BBBB-CCCC-DDDD-EEEE',
      );
      final resolved = resolveBuiltInPushDefaults(
        const <AppExtension>[_FakeExtension('test.fake', builtIn)],
      );
      expect(resolved.instanceId, builtIn.instanceId);
      expect(resolved.pairingCode, builtIn.pairingCode);
    });

    test('--dart-define 已经有值的字段优先，扩展不覆盖', () {
      // 中转地址在这份构建里恒有默认值（`AppDefaults.pushRelayUrl`），
      // 所以扩展给一个不同的地址也不该生效 —— 「构建期注入优先」的判据。
      const builtIn = PushDefaults(
        relayUrl: 'https://push.example.com',
        instanceId: 'inst-0123456789abcdef0123456789abcdef',
        pairingCode: 'AAAA-BBBB-CCCC-DDDD-EEEE',
      );
      final resolved = resolveBuiltInPushDefaults(
        const <AppExtension>[_FakeExtension('test.fake', builtIn)],
      );
      expect(resolved.relayUrl, AppDefaults.pushRelayUrl);
      expect(resolved.relayUrl, isNot(builtIn.relayUrl));
    });

    test('多个扩展只认第一个返回非 null 的，后面的不参与', () {
      const first = PushDefaults(
        relayUrl: 'https://first.example.com',
        instanceId: 'inst-11111111111111111111111111111111',
        pairingCode: '1111-1111-1111-1111-1111',
      );
      const second = PushDefaults(
        relayUrl: 'https://second.example.com',
        instanceId: 'inst-22222222222222222222222222222222',
        pairingCode: '2222-2222-2222-2222-2222',
      );
      final resolved = resolveBuiltInPushDefaults(
        const <AppExtension>[
          _FakeExtension('test.first', first),
          _FakeExtension('test.second', second),
        ],
      );
      expect(resolved.instanceId, first.instanceId);
      expect(resolved.pairingCode, first.pairingCode);
    });

    test('返回 null 的扩展被跳过（不占「第一个」的位置）', () {
      const builtIn = PushDefaults(
        relayUrl: 'https://push.example.com',
        instanceId: 'inst-0123456789abcdef0123456789abcdef',
        pairingCode: 'AAAA-BBBB-CCCC-DDDD-EEEE',
      );
      final resolved = resolveBuiltInPushDefaults(
        const <AppExtension>[
          _FakeExtension('test.null', null),
          _FakeExtension('test.real', builtIn),
        ],
      );
      expect(resolved.instanceId, builtIn.instanceId);
      expect(resolved.pairingCode, builtIn.pairingCode);
    });
  });
}
