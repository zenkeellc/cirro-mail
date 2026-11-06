import 'dart:convert';
import 'dart:typed_data';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/notifications/push_facade.dart';
import 'package:mail_app/features/notifications/push_service.dart';
import 'package:mail_app/features/notifications/relay_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [PushFacadeImpl]：扩展画自己的推送设置页时要用的那个门面。
///
/// 这里用**真的** `PushService` + 真的 prefs / 钥匙串（内存 mock）+ 假的中转
/// 适配器 —— 门面本身没有逻辑，它要保证的是「把核心的能力原样、按同一条
/// 纪律交出去」：动作不抛、失败折成结果、退订不留在中转端。

Profile _profile(String id) => Profile(
      id: id,
      baseUrl: 'https://mail.example.com/api',
      name: id,
      email: 'a@b.com',
      userId: 1,
    );

MailboxAccount _mailbox(String email) =>
    MailboxAccount(accountId: 1, email: email, name: '');

Map<String, String> fakeKeychain({
  Map<String, String> initial = const <String, String>{},
}) {
  final data = Map<String, String>.of(initial);
  FlutterSecureStorage.setMockInitialValues(data);
  return data;
}

const ManagedPushConfig _managed = ManagedPushConfig(
  relayUrl: 'https://managed.example.com',
  instanceId: 'inst-managed',
  deviceCode: 'MANAGED-CODE',
  entitlement: 'v1.payload.sig',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fakeKeychain();
  });

  Future<({PushFacade facade, PushService push, PrefsStore prefs, Map<String, String> keychain})>
      harness({
    Map<String, Object> prefs = const <String, Object>{},
    Map<String, String> keychain = const <String, String>{},
    Future<ManagedPushConfig?> Function()? readManagedConfig,
    _FakeAdapter? adapter,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final store = await PrefsStore.open();
    final keys = fakeKeychain(initial: keychain);
    final tokens = TokenStore();
    final push = PushService(
      prefs: store,
      tokens: tokens,
      readProfiles: () async => <Profile>[_profile('p-1')],
      readMailboxes: (_) async => <MailboxAccount>[_mailbox('a@b.com')],
      readManagedConfig: readManagedConfig,
      forceAvailable: true,
      clientFactory: adapter == null
          ? null
          : (baseUrl) => RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
    );
    return (
      facade: PushFacadeImpl(push: push, prefs: store, tokens: tokens),
      push: push,
      prefs: store,
      keychain: keys,
    );
  }

  group('status', () {
    test('把平台 / 配置 / 设备号 / 已登记邮箱一次报全', () async {
      final adapter = _FakeAdapter(
        respond: (path) => path == '/devices'
            ? const <String, Object?>{
                'code': 200,
                'data': <String, Object?>{
                  'mailboxes': <Object?>[
                    <String, Object?>{'mailboxEmail': 'a@b.com'},
                    <String, Object?>{'mailboxEmail': 'c@d.com'},
                  ],
                },
              }
            : null,
      );
      final h = await harness(
        readManagedConfig: () async => _managed,
        adapter: adapter,
      );

      final status = await h.facade.status();

      expect(status.available, isTrue);
      expect(status.configured, isTrue);
      expect(status.deviceId, startsWith('inst-managed-'));
      expect(status.deviceIdValid, isTrue);
      expect(status.mailboxes, <String>['a@b.com', 'c@d.com']);
      expect(adapter.headers.single[RelayClient.entitlementHeader],
          'v1.payload.sig');
    });

    test('中转端判定订阅失效时不抛，只是 mailboxes 为空', () async {
      final adapter = _FakeAdapter(
        respond: (_) => const <String, Object?>{
          'code': 401,
          'message': '订阅已失效，推送已改为手动配置',
          'data': <String, Object?>{'reason': 'entitlement_expired'},
        },
      );
      final h = await harness(
        readManagedConfig: () async => _managed,
        adapter: adapter,
      );

      final status = await h.facade.status();

      expect(status.configured, isTrue, reason: '配置本身还在，只是订阅失效');
      expect(status.mailboxes, isEmpty);
    });

    test('没配置时如实报没配置（不打网络）', () async {
      final h = await harness();
      final status = await h.facade.status();
      expect(status.configured, isFalse);
      expect(status.mailboxes, isEmpty);
    });
  });

  group('开关', () {
    test('打开 = 落 prefs 的开关 + 登记一次', () async {
      final h = await harness(readManagedConfig: () async => _managed);

      final result = await h.facade.setEnabled(true);

      expect(h.facade.enabled, isTrue);
      expect(h.prefs.pushEnabled, isTrue);
      // 这台测试机没有 Firebase 配置文件，登记会停在 FCM 那一步 —— 门面要
      // 如实把原因说出来，而不是假装成功。
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
      expect(result.subscriptionRequired, isFalse);
    });

    test('关掉 = 落 prefs 的开关 + 退订（别留着注册继续推）', () async {
      final adapter = _FakeAdapter();
      final h = await harness(
        prefs: const <String, Object>{'cm_push_enabled': true},
        readManagedConfig: () async => _managed,
        adapter: adapter,
      );

      final result = await h.facade.setEnabled(false);

      expect(h.facade.enabled, isFalse);
      expect(h.prefs.pushEnabled, isFalse);
      expect(result.ok, isTrue);
      expect(adapter.requests.single.path, '/unregister');
      expect(adapter.requests.single.body['deviceToken'], 'MANAGED-CODE');
    });

    test('登记动作失败也算结果，不抛', () async {
      final h = await harness(readManagedConfig: () async => _managed);
      final result = await h.facade.register();
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
    });
  });

  group('登记 / 退订', () {
    test('register 没配置时给一句人话', () async {
      final h = await harness();
      final result = await h.facade.register();
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
    });

    test('unregister 未登记时也是成功（本来就没登记）', () async {
      final h = await harness();
      final result = await h.facade.unregister();
      expect(result.ok, isTrue);
      expect(result.message, isNotEmpty);
    });

    test('unregister 把结果里的 subscriptionRequired 透出来', () async {
      final adapter = _FakeAdapter(
        respond: (_) => const <String, Object?>{
          'code': 401,
          'message': '订阅已失效，推送已改为手动配置',
          'data': <String, Object?>{'reason': 'entitlement_expired'},
        },
      );
      final h = await harness(
        readManagedConfig: () async => _managed,
        adapter: adapter,
      );

      final result = await h.facade.unregister();

      expect(result.ok, isFalse);
      expect(result.subscriptionRequired, isTrue);
    });
  });

  group('检查链路', () {
    _FakeAdapter healthy({
      bool fcmConfigured = true,
      bool? codeOk = true,
      bool? urlOk = true,
      String? lastEventAt,
    }) =>
        _FakeAdapter(
          respond: (path) => switch (path) {
            '/health' => <String, Object?>{
                'code': 200,
                'data': <String, Object?>{
                  'instances': 1,
                  'fcmConfigured': fcmConfigured,
                  'adminConfigured': true,
                },
              },
            '/verify-webhook' => <String, Object?>{
                'code': 200,
                'data': <String, Object?>{
                  'instanceId': 'inst-managed',
                  'name': 'box',
                  'webhookUrl': 'https://managed.example.com/inst-managed/webhook',
                  'webhookPath': '/inst-managed/webhook',
                  'codeOk': codeOk,
                  'urlOk': urlOk,
                  'lastEventAt': lastEventAt,
                },
              },
            _ => null,
          },
        );

    test('全对 → ok，并给出明细', () async {
      final h = await harness(
        readManagedConfig: () async => _managed,
        adapter: healthy(lastEventAt: '2026-11-01T10:00:00Z'),
      );

      final result = await h.facade.checkChain();

      expect(result.ok, isTrue);
      expect(result.message, contains('链路检查通过'));
      expect(result.message, contains('2026-11-01T10:00:00Z'));
      final chain = result.chain;
      expect(chain, isNotNull);
      expect(chain!.relayReachable, isTrue);
      expect(chain.fcmConfigured, isTrue);
      expect(chain.codeOk, isTrue);
      expect(chain.urlOk, isTrue);
      expect(chain.lastEventAt, '2026-11-01T10:00:00Z');
    });

    test('中转端没配 FCM → 不算通过（那种「全绿」最误导人）', () async {
      final h = await harness(
        readManagedConfig: () async => _managed,
        adapter: healthy(fcmConfigured: false),
      );

      final result = await h.facade.checkChain();

      expect(result.ok, isFalse);
      expect(result.chain?.fcmConfigured, isFalse);
      expect(result.message, contains('FCM'));
    });

    test('配对码不对 → 指出是哪一项', () async {
      final h = await harness(
        readManagedConfig: () async => _managed,
        adapter: healthy(codeOk: false),
      );

      final result = await h.facade.checkChain();

      expect(result.ok, isFalse);
      expect(result.message, contains('配对码'));
    });

    test('地址路径不对 → 指出是哪一项', () async {
      final h = await harness(
        readManagedConfig: () async => _managed,
        adapter: healthy(urlOk: false),
      );

      final result = await h.facade.checkChain();

      expect(result.ok, isFalse);
      expect(result.message, contains('地址'));
    });

    test('没有可用的中转地址 → 直接说清楚（不去连一个空地址）', () async {
      final h = await harness();
      final result = await h.facade.checkChain();
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
      expect(result.chain, isNull);
    });

    test('订阅失效 → subscriptionRequired，而不是普通失败', () async {
      final adapter = _FakeAdapter(
        respond: (path) => path == '/health'
            ? <String, Object?>{
                'code': 200,
                'data': <String, Object?>{'instances': 1, 'fcmConfigured': true},
              }
            : <String, Object?>{
                'code': 401,
                'message': '订阅已失效，推送已改为手动配置',
                'data': <String, Object?>{'reason': 'entitlement_expired'},
              },
      );
      final h = await harness(
        readManagedConfig: () async => _managed,
        adapter: adapter,
      );

      final result = await h.facade.checkChain();

      expect(result.ok, isFalse);
      expect(result.subscriptionRequired, isTrue);
    });
  });

  group('清掉手填配置', () {
    test('清地址 / 实例位 / 对应钥匙串项，保留开关与设备号', () async {
      final h = await harness(
        prefs: const <String, Object>{
          'cm_push_relay_url': 'https://hand.example.com',
          'cm_push_instance_id': 'inst-hand',
          'cm_push_device_id': 'inst-hand-abc',
          'cm_push_enabled': true,
        },
        keychain: <String, String>{'push_inst-hand': 'HAND-CODE'},
      );

      await h.facade.clearManualConfig();

      expect(h.prefs.pushRelayUrl, isEmpty);
      expect(h.prefs.pushInstanceId, isEmpty);
      expect(h.keychain.containsKey('push_inst-hand'), isFalse);
      expect(h.prefs.pushEnabled, isTrue, reason: '开关是用户的意愿，不是三条值');
      expect(h.prefs.pushDeviceId, 'inst-hand-abc',
          reason: '设备号是本机身份，不清 —— 清了下次冷启动就注销不掉旧注册');
    });
  });
}

/// 只回预设信封的适配器，记下每个请求的路径与 body。
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
