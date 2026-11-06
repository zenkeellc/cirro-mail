import 'dart:convert';
import 'dart:typed_data';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/error/app_exception.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/notifications/push_service.dart';
import 'package:mail_app/features/notifications/relay_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 托管推送配置（`AppExtension.managedPushConfig`）在核心这一侧的三条承诺：
///
/// 1. **优先**：托管配置在时，中转地址 / 实例位 / 配对码都取它，回落才是
///    prefs / 钥匙串里的手填值；
/// 2. **不落盘**：托管配置下核心不把三条值写进 prefs / 钥匙串（设备号例外，
///    它是本机的，不落盘就注销不掉旧注册）；
/// 3. **凭证透传**：订阅凭证只加在 register / unregister / devices / events
///    四个请求上，中转端回 `entitlement_*` 时结果里带 `subscriptionRequired`。
///
/// 还有一条同样重要的**负向**承诺：没有托管配置时（公开版的空注册表），上面
/// 一切都不发生 —— 用真 `PrefsStore` / `TokenStore` / `RelayClient` 跑，行为
/// 与加接缝之前逐字相同。

/// 一个最小的 profile（`isLoggedIn` 是派生值，只能靠字段摆出来）。
Profile _profile(String id, {required bool loggedIn}) => Profile(
      id: id,
      baseUrl: 'https://mail.example.com/api',
      name: id,
      email: 'a@b.com',
      userId: loggedIn ? 1 : 0,
      needsLogin: !loggedIn,
    );

MailboxAccount _mailbox(String email) => MailboxAccount(
      accountId: email.hashCode & 0xffff,
      email: email,
      name: '',
    );

/// 把 `flutter_secure_storage` 换成插件自带的内存实现，返回底层 map（好反向
/// 断言「有没有写进去」）。
Map<String, String> fakeKeychain({
  Map<String, String> initial = const <String, String>{},
}) {
  final data = Map<String, String>.of(initial);
  FlutterSecureStorage.setMockInitialValues(data);
  return data;
}

/// 托管配置的三条值，刻意与下面 [handPrefs] 里那组**全都不一样** —— 一样的话
/// 「到底读了哪一份」断不出来。
const ManagedPushConfig _managed = ManagedPushConfig(
  relayUrl: 'https://managed.example.com',
  instanceId: 'inst-managed',
  deviceCode: 'MANAGED-CODE',
  entitlement: 'v1.payload.sig',
);

const Map<String, Object> handPrefs = <String, Object>{
  'cm_push_relay_url': 'https://hand.example.com',
  'cm_push_instance_id': 'inst-hand',
  'cm_push_device_id': 'inst-hand-abc123',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fakeKeychain();
  });

  Future<({PushService push, PrefsStore prefs, Map<String, String> keychain})>
      service({
    Map<String, Object> prefs = const <String, Object>{},
    Map<String, String> keychain = const <String, String>{},
    Future<ManagedPushConfig?> Function()? readManagedConfig,
    List<Profile> Function()? profiles,
    List<MailboxAccount> Function(String profileId)? mailboxes,
    RelayClient Function(String baseUrl)? clientFactory,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final store = await PrefsStore.open();
    final keys = fakeKeychain(initial: keychain);
    final push = PushService(
      prefs: store,
      tokens: TokenStore(),
      readProfiles: () async => profiles?.call() ?? const <Profile>[],
      readMailboxes: (profileId) async =>
          mailboxes?.call(profileId) ?? const <MailboxAccount>[],
      readManagedConfig: readManagedConfig,
      forceAvailable: true,
      clientFactory: clientFactory,
    );
    return (push: push, prefs: store, keychain: keys);
  }

  // ------------------------------------------------------- 没有托管配置

  group('没有托管配置（公开版）行为不变', () {
    test('三条值仍然来自 prefs / 钥匙串', () async {
      final s = await service(
        prefs: handPrefs,
        keychain: <String, String>{'push_inst-hand': 'HAND-CODE'},
      );

      await s.push.refreshManagedConfig();

      expect(s.push.managedConfig, isNull);
      expect(s.push.relayUrl, 'https://hand.example.com');
      expect(s.push.instanceId, 'inst-hand');
      expect(await s.push.pairingCode(), 'HAND-CODE');
      expect(s.push.isConfigured, isTrue);
    });

    test('isConfigured 仍然要求设备号在（不会凭空变出配置）', () async {
      final s = await service(
        prefs: const <String, Object>{
          'cm_push_relay_url': 'https://hand.example.com',
          'cm_push_instance_id': 'inst-hand',
        },
      );
      await s.push.refreshManagedConfig();
      expect(s.push.isConfigured, isFalse);
    });

    test('问扩展失败/返回 null 不会清掉手填值', () async {
      final s = await service(
        prefs: handPrefs,
        readManagedConfig: () async => throw StateError('扩展挂了'),
      );

      await s.push.refreshManagedConfig();

      expect(s.push.relayUrl, 'https://hand.example.com');
      expect(s.push.instanceId, 'inst-hand');
    });
  });

  // ------------------------------------------------------------ 优先级

  group('托管配置优先', () {
    test('地址 / 实例位 / 配对码都取托管配置', () async {
      final s = await service(
        prefs: handPrefs,
        keychain: <String, String>{'push_inst-hand': 'HAND-CODE'},
        readManagedConfig: () async => _managed,
      );

      await s.push.refreshManagedConfig();

      expect(s.push.relayUrl, 'https://managed.example.com');
      expect(s.push.instanceId, 'inst-managed');
      expect(await s.push.pairingCode(), 'MANAGED-CODE');
    });

    test('设备号跟着托管实例位重掷（它是本机值，不是三条值之一）', () async {
      final s = await service(
        prefs: handPrefs,
        readManagedConfig: () async => _managed,
      );

      await s.push.refreshManagedConfig();

      expect(s.push.deviceId, startsWith('inst-managed-'));
      expect(s.push.deviceIdValid, isTrue);
      expect(s.push.isConfigured, isTrue,
          reason: '托管配置接手后设备号已就位，不该还显示「没配置」');
      // 设备号**要**落盘：下次冷启动不落盘就注销不掉旧注册。
      expect(s.prefs.pushDeviceId, s.push.deviceId);
      expect(s.prefs.pushDeviceId, isNot('inst-hand-abc123'));
    });

    test('再无托管配置时回落手填值', () async {
      var enabled = true;
      final s = await service(
        prefs: handPrefs,
        readManagedConfig: () async => enabled ? _managed : null,
      );

      await s.push.refreshManagedConfig();
      expect(s.push.instanceId, 'inst-managed');

      // 订阅到期 —— 扩展那侧返回 null。
      enabled = false;
      await s.push.refreshManagedConfig(force: true);

      expect(s.push.managedConfig, isNull);
      expect(s.push.relayUrl, 'https://hand.example.com');
      expect(s.push.instanceId, 'inst-hand');
    });

    test('推送事件的 instanceId 按托管位映射到 profile', () async {
      final s = await service(
        prefs: handPrefs,
        readManagedConfig: () async => _managed,
        profiles: () => <Profile>[_profile('p-1', loggedIn: true)],
        mailboxes: (_) => <MailboxAccount>[_mailbox('a@b.com')],
      );
      await s.push.refreshManagedConfig();

      final event = await s.push.debugDecode(<String, dynamic>{
        'kind': 'new_mail',
        'emailId': '128',
        'instanceId': 'inst-managed',
        'mailboxEmail': 'a@b.com',
      });

      expect(event?.profileId, 'p-1');
    });
  });

  // ------------------------------------------------------------ 不落盘

  group('托管配置下不写三条值', () {
    test('取回配置只写设备号，不碰 prefs 的地址/实例位、也不写钥匙串', () async {
      final s = await service(
        prefs: handPrefs,
        readManagedConfig: () async => _managed,
      );
      final before = (await SharedPreferences.getInstance())
          .getKeys()
          .toSet();

      await s.push.refreshManagedConfig();

      expect(s.prefs.pushRelayUrl, 'https://hand.example.com',
          reason: '手填值原样留着 —— 托管配置失效时要能回退');
      expect(s.prefs.pushInstanceId, 'inst-hand');
      expect(s.keychain.keys.where((k) => k.startsWith('push_')), isEmpty,
          reason: '托管配置的配对码只在内存里，绝不写钥匙串');
      final raw = await SharedPreferences.getInstance();
      // 只多了设备号那一条（它本来就在 prefs 里，只是值变了）。
      expect(raw.getKeys().difference(before), isEmpty);
      expect(raw.getString('cm_push_relay_url'), 'https://hand.example.com');
    });

    test('configure() 在托管配置下什么都不落盘', () async {
      final s = await service(
        prefs: handPrefs,
        readManagedConfig: () async => _managed,
      );

      final result = await s.push.configure(
        relayUrl: 'https://typed.example.com',
        instanceId: 'inst-typed',
        pairingCode: 'TYPED-CODE',
      );

      expect(result.ok, isTrue);
      expect(result.message, contains('托管'));
      expect(s.prefs.pushRelayUrl, 'https://hand.example.com');
      expect(s.prefs.pushInstanceId, 'inst-hand');
      expect(s.keychain.keys.where((k) => k.startsWith('push_')), isEmpty);
    });
  });

  // -------------------------------------------------------- 凭证透传

  group('订阅凭证只加在四条请求上', () {
    test('unregister 带 X-Push-Entitlement，且用托管的三条值', () async {
      final adapter = _FakeAdapter();
      final s = await service(
        prefs: handPrefs,
        keychain: <String, String>{'push_inst-hand': 'HAND-CODE'},
        readManagedConfig: () async => _managed,
        clientFactory: (baseUrl) =>
            RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
      );

      final result = await s.push.unsubscribe();

      expect(result.ok, isTrue);
      final request = adapter.requests.single;
      expect(request.path, '/unregister');
      expect(request.body['instanceId'], 'inst-managed');
      expect(request.body['deviceToken'], 'MANAGED-CODE');
      expect(adapter.headers.single[RelayClient.entitlementHeader],
          'v1.payload.sig');
    });

    test('devices 带 X-Push-Entitlement', () async {
      final adapter = _FakeAdapter(
        respond: (path) => path == '/devices'
            ? const <String, Object?>{
                'code': 200,
                'data': <String, Object?>{
                  'mailboxes': <Object?>[
                    <String, Object?>{'mailboxEmail': 'a@b.com'},
                  ],
                },
              }
            : null,
      );
      final s = await service(
        prefs: handPrefs,
        readManagedConfig: () async => _managed,
        clientFactory: (baseUrl) =>
            RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
      );

      final mailboxes = await s.push.remoteMailboxes();

      expect(mailboxes, <String>['a@b.com']);
      expect(adapter.headers.single[RelayClient.entitlementHeader],
          'v1.payload.sig');
    });

    test('register 带 X-Push-Entitlement（直接测 RelayClient 那一层）', () async {
      final adapter = _FakeAdapter();
      final client =
          RelayClient(baseUrl: 'https://push.example.com', dio: adapter.dio());

      await client.register(
        instanceId: 'inst-1',
        deviceToken: 'code-1',
        deviceId: 'inst-1-abc',
        mailboxEmail: 'a@b.com',
        fcmToken: 'fcm-1',
        platform: 'macos',
        entitlement: 'v1.payload.sig',
      );

      expect(adapter.headers.single[RelayClient.entitlementHeader],
          'v1.payload.sig');
    });

    test('events 带 X-Push-Entitlement', () async {
      final adapter = _FakeAdapter();
      final client =
          RelayClient(baseUrl: 'https://push.example.com', dio: adapter.dio());

      await client.events(
        instanceId: 'inst-1',
        deviceToken: 'code-1',
        deviceId: 'inst-1-abc',
        since: 7,
        entitlement: 'v1.payload.sig',
      );

      expect(adapter.headers.single[RelayClient.entitlementHeader],
          'v1.payload.sig');
    });

    test('verify-webhook **不**带凭证（中转端那条不校验它）', () async {
      final adapter = _FakeAdapter(
        respond: (path) => path == '/verify-webhook'
            ? const <String, Object?>{
                'code': 200,
                'data': <String, Object?>{
                  'instanceId': 'inst-1',
                  'name': '',
                  'webhookUrl': '',
                  'webhookPath': '',
                  'codeOk': true,
                  'urlOk': true,
                },
              }
            : null,
      );
      final s = await service(
        prefs: handPrefs,
        keychain: <String, String>{'push_inst-hand': 'HAND-CODE'},
        readManagedConfig: () async => _managed,
        clientFactory: (baseUrl) =>
            RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
      );

      await s.push.verifyWebhook();

      expect(
        adapter.headers.single.containsKey(RelayClient.entitlementHeader),
        isFalse,
        reason: '凭证只透传给 register/unregister/devices/events',
      );
    });

    test('没有托管配置时**一个凭证头都不发**（公开版逐字不变）', () async {
      final adapter = _FakeAdapter();
      final s = await service(
        prefs: handPrefs,
        keychain: <String, String>{'push_inst-hand': 'HAND-CODE'},
        clientFactory: (baseUrl) =>
            RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
      );

      await s.push.unsubscribe();

      expect(
        adapter.headers.single.containsKey(RelayClient.entitlementHeader),
        isFalse,
      );
    });
  });

  // ------------------------------------------------------ 凭证失效

  group('中转端判定订阅失效', () {
    Map<String, Object?> entitlementReject(String reason) =>
        <String, Object?>{
          'code': 401,
          'message': '订阅已失效，推送已改为手动配置',
          'data': <String, Object?>{'reason': reason},
        };

    test('unregister 回 entitlement_expired → subscriptionRequired', () async {
      final adapter = _FakeAdapter(
        respond: (_) => entitlementReject('entitlement_expired'),
      );
      final s = await service(
        prefs: handPrefs,
        readManagedConfig: () async => _managed,
        clientFactory: (baseUrl) =>
            RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
      );

      final result = await s.push.unsubscribe();

      expect(result.ok, isFalse);
      expect(result.subscriptionRequired, isTrue);
      expect(result.message, isNotEmpty);
    });

    test('普通 401（配对码不对）**不**算订阅失效', () async {
      final adapter = _FakeAdapter(
        respond: (_) => const <String, Object?>{
          'code': 401,
          'message': '配对码不正确',
        },
      );
      final s = await service(
        prefs: handPrefs,
        keychain: <String, String>{'push_inst-hand': 'HAND-CODE'},
        clientFactory: (baseUrl) =>
            RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
      );

      final result = await s.push.unsubscribe();

      expect(result.ok, isFalse);
      expect(result.subscriptionRequired, isFalse);
    });

    test('devices 回 entitlement_invalid → remoteMailboxes 抛专用异常', () async {
      final adapter = _FakeAdapter(
        respond: (_) => entitlementReject('entitlement_invalid'),
      );
      final s = await service(
        prefs: handPrefs,
        readManagedConfig: () async => _managed,
        clientFactory: (baseUrl) =>
            RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
      );

      await expectLater(
        s.push.remoteMailboxes(),
        throwsA(isA<PushSubscriptionRequiredException>()),
      );
    });

    test('RelayClient 把 data.reason 带在异常里（诊断用）', () async {
      final adapter = _FakeAdapter(
        respond: (_) => entitlementReject('entitlement_unconfigured'),
      );
      final client =
          RelayClient(baseUrl: 'https://push.example.com', dio: adapter.dio());

      try {
        await client.devices(
          instanceId: 'inst-1',
          deviceToken: 'code-1',
          deviceId: 'inst-1-abc',
          entitlement: 'v1.payload.sig',
        );
        fail('应当抛 PushSubscriptionRequiredException');
      } on PushSubscriptionRequiredException catch (e) {
        expect(e.reason, 'entitlement_unconfigured');
      }
    });
  });

  // ------------------------------------------------------------ 节流

  group('取回节流', () {
    test('30 秒内只问一次扩展；force 时再问', () async {
      var calls = 0;
      final s = await service(
        readManagedConfig: () async {
          calls++;
          return _managed;
        },
      );

      await s.push.refreshManagedConfig();
      await s.push.refreshManagedConfig();
      await s.push.refreshManagedConfig();
      expect(calls, 1);

      await s.push.refreshManagedConfig(force: true);
      expect(calls, 2);
    });

    test('并发调用共用同一次取回', () async {
      var calls = 0;
      final s = await service(
        readManagedConfig: () async {
          calls++;
          await Future<void>.delayed(Duration.zero);
          return _managed;
        },
      );

      await Future.wait<void>(<Future<void>>[
        s.push.refreshManagedConfig(),
        s.push.refreshManagedConfig(),
        s.push.refreshManagedConfig(),
      ]);

      expect(calls, 1);
    });

    test('公开操作前都会问一次（30 秒内合并）', () async {
      var calls = 0;
      final s = await service(
        prefs: handPrefs,
        keychain: <String, String>{'push_inst-hand': 'HAND-CODE'},
        readManagedConfig: () async {
          calls++;
          return null;
        },
      );

      await s.push.ensureDeviceId();
      await s.push.initialize();
      await s.push.unsubscribe();
      await s.push.remoteMailboxes();
      await s.push.verifyWebhook().then((_) {}, onError: (_) {});

      expect(calls, 1, reason: '同一窗口里几次操作共用一次取回');
    });
  });
}

/// 只回预设信封的适配器，记下每个请求的路径、body 与头。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this._respond});

  final Map<String, Object?>? Function(String path)? _respond;

  final List<({String path, Map<String, dynamic> body})> requests =
      <({String path, Map<String, dynamic> body})>[];
  final List<Map<String, dynamic>> headers = <Map<String, dynamic>>[];

  Dio dio() {
    final dio = Dio(
      BaseOptions(
        validateStatus: (_) => true,
        contentType: Headers.jsonContentType,
      ),
    );
    dio.httpClientAdapter = this;
    return dio;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    final decoded = bytes.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    requests.add((path: options.uri.path, body: decoded));
    headers.add(Map<String, dynamic>.of(options.headers));

    final body = _respond?.call(options.uri.path) ??
        <String, Object?>{'code': 200, 'data': <String, Object?>{}};
    final encoded = utf8.encode(jsonEncode(body));
    return ResponseBody(
      Stream<Uint8List>.fromIterable(<Uint8List>[Uint8List.fromList(encoded)]),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
