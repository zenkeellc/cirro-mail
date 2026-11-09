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
import 'package:mail_app/features/notifications/push_service.dart';
import 'package:mail_app/features/notifications/relay_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录每一次请求体的适配器 —— 这里要断的正是「发出去的 body 长什么样」。
class _RecordingAdapter implements HttpClientAdapter {
  final List<({
    String path,
    Map<String, dynamic> body,
    Map<String, dynamic> headers,
  })> requests = <({
    String path,
    Map<String, dynamic> body,
    Map<String, dynamic> headers,
  })>[];

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
    requests.add((
      path: options.uri.path,
      body: decoded,
      headers: Map<String, dynamic>.of(options.headers),
    ));
    final encoded = utf8.encode(
      jsonEncode(<String, Object?>{'code': 200, 'data': <String, Object?>{}}),
    );
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

Future<RelayClient> _client(_RecordingAdapter adapter) async => RelayClient(
      baseUrl: 'https://push.example.com',
      dio: adapter.dio(),
    );

/// `register` 的既有六项（少一项都说明形状变了）。
const Map<String, dynamic> _oldShape = <String, dynamic>{
  'instanceId': 'inst-1',
  'deviceToken': 'device-code-1',
  'deviceId': 'inst-1-abc',
  'mailboxEmail': 'a@b.com',
  'token': 'fcm-token-1',
  'platform': 'macos',
};

/// 三条推送配置都填好、开关也开着的 prefs —— `syncAll` 要过 `isConfigured`
/// 与 `enabled` 两道闸门才会走到登记循环。
const Map<String, Object> _configuredPrefs = <String, Object>{
  'cm_push_relay_url': 'https://push.example.com',
  'cm_push_instance_id': 'inst-1',
  'cm_push_device_id': 'inst-1-abc',
  'cm_push_enabled': true,
};

/// 一个给出订阅绑定的扩展（商业版的替身）。
class _BindingExt extends AppExtension {
  const _BindingExt({
    required this.licenseId,
    required this.licenseDeviceId,
  });

  final String licenseId;
  final String licenseDeviceId;

  @override
  String get id => 'binding-ext';

  @override
  ({String licenseId, String licenseDeviceId})? get pushLicenseBinding =>
      (licenseId: licenseId, licenseDeviceId: licenseDeviceId);
}

/// 装了扩展、但这一轮拿不到绑定（= 「实现还没就绪」）。
class _NotReadyExt extends AppExtension {
  const _NotReadyExt();

  @override
  String get id => 'not-ready-ext';
}

Profile _profile() => const Profile(
      id: 'p-1',
      baseUrl: 'https://mail.example.com/api',
      name: 'p-1',
      email: 'a@b.com',
      userId: 1,
      needsLogin: false,
    );

MailboxAccount _mailbox(String email) => MailboxAccount(
      accountId: email.hashCode & 0xffff,
      email: email,
      name: '',
    );

/// 一台配好推送、FCM token 也已经「拿到」的服务，所有请求都落在 [adapter]。
///
/// `forceFcmToken` 是测试专用的口子：真实路径要碰 Firebase 插件（平台通道），
/// 在 `flutter test` 里永远拿不到 token，也就永远走不到 `/register` ——
/// 那样「请求体长什么样」根本断言不了（那正是这次要补的盲区）。
Future<PushService> _push(_RecordingAdapter adapter) async => PushService(
      prefs: await PrefsStore.open(),
      tokens: TokenStore(),
      readProfiles: () async => <Profile>[_profile()],
      readMailboxes: (_) async => <MailboxAccount>[_mailbox('a@b.com')],
      forceAvailable: true,
      forceFcmToken: 'fcm-token-1',
      clientFactory: (baseUrl) => RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(_configuredPrefs);
    // 设备配对码在钥匙串里（`push_<instanceId>`），没有它 `syncAll` 会停在
    // 「缺少设备配对码」那一步。
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'push_inst-1': 'device-code-1',
    });
    AppExtensionRegistry.instance.reset();
  });

  tearDown(AppExtensionRegistry.instance.reset);

  group('/register 的 license 绑定透传', () {
    test('传了两个字段时 body 里原样带着 licenseId / licenseDeviceId', () async {
      final adapter = _RecordingAdapter();
      final client = await _client(adapter);

      await client.register(
        instanceId: 'inst-1',
        deviceToken: 'device-code-1',
        deviceId: 'inst-1-abc',
        mailboxEmail: 'a@b.com',
        fcmToken: 'fcm-token-1',
        platform: 'macos',
        entitlement: null,
        licenseId: 'CM-1234',
        licenseDeviceId: '11111111-2222-4333-8444-555555555555',
      );

      final body = adapter.requests.single.body;
      expect(body['licenseId'], 'CM-1234');
      expect(body['licenseDeviceId'], '11111111-2222-4333-8444-555555555555');
      expect(body['mailboxEmail'], 'a@b.com',
          reason: '既有的六项一个都不能少');
    });

    test('不传两个字段时 body 与旧形状逐字一致（老实例兼容）', () async {
      final adapter = _RecordingAdapter();
      final client = await _client(adapter);

      await client.register(
        instanceId: 'inst-1',
        deviceToken: 'device-code-1',
        deviceId: 'inst-1-abc',
        mailboxEmail: 'a@b.com',
        fcmToken: 'fcm-token-1',
        platform: 'macos',
      );

      final body = adapter.requests.single.body;
      // 整个 map 相等：多一个 key、少一个 key、值改了都算不兼容。
      expect(body, _oldShape);
      expect(body.containsKey('licenseId'), isFalse);
      expect(body.containsKey('licenseDeviceId'), isFalse);
    });

    test('显式传空串等于没传（不往 body 里塞空值）', () async {
      final adapter = _RecordingAdapter();
      final client = await _client(adapter);

      await client.register(
        instanceId: 'inst-1',
        deviceToken: 'device-code-1',
        deviceId: 'inst-1-abc',
        mailboxEmail: 'a@b.com',
        fcmToken: 'fcm-token-1',
        platform: 'macos',
        licenseId: '',
        licenseDeviceId: '',
      );

      expect(adapter.requests.single.body, _oldShape);
    });

    test('带了 license 也不影响既有的订阅凭证头', () async {
      final adapter = _RecordingAdapter();
      final client = await _client(adapter);

      await client.register(
        instanceId: 'inst-1',
        deviceToken: 'device-code-1',
        deviceId: 'inst-1-abc',
        mailboxEmail: 'a@b.com',
        fcmToken: 'fcm-token-1',
        platform: 'macos',
        entitlement: 'ent-1',
        licenseId: 'CM-1234',
        licenseDeviceId: 'dev-1',
      );

      final headers = adapter.requests.single.headers;
      expect(headers[RelayClient.entitlementHeader], 'ent-1');
    });
  });

  /// 上面那组只验到 `RelayClient.register` 的入参透传；这一组补的是
  /// **`syncAll → RelayClient.register` 那一跳** —— 注册表读到的绑定有没有
  /// 被真的送进请求体，以及「绑定未就绪时不许发」那道守卫。之前这一跳没有
  /// 任何测试（FCM token 在 `flutter test` 里拿不到，循环根本走不到）。
  group('syncAll → /register 的 license 绑定透传', () {
    test('扩展给了绑定：body 原样带两个字段，既有六项一个不少', () async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _BindingExt(licenseId: 'CM-1234', licenseDeviceId: 'dev-1'),
      ]);
      final adapter = _RecordingAdapter();
      final push = await _push(adapter);

      final result = await push.syncAll();

      expect(result.ok, isTrue, reason: result.message);
      final request = adapter.requests.single;
      expect(request.path, '/register');
      expect(request.body['licenseId'], 'CM-1234');
      expect(request.body['licenseDeviceId'], 'dev-1');
      // 既有那几项仍然在（透传不是替换）。
      expect(request.body['instanceId'], 'inst-1');
      expect(request.body['deviceToken'], 'device-code-1');
      expect(request.body['deviceId'], 'inst-1-abc');
      expect(request.body['mailboxEmail'], 'a@b.com');
      expect(request.body['token'], 'fcm-token-1');
    });

    /// 装了扩展却读不到绑定 → **一条都不发**。`/register` 是 UPSERT，不带
    /// license 的那次会把中转端既有的 `license_id` 冲掉，本机于是从云草稿的
    /// 跨设备路由里被摘掉，而且请求回 200、没有任何错误可见。
    test('装了扩展但绑定为 null：跳过本轮登记，不碰中转端', () async {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        const _NotReadyExt(),
      ]);
      final adapter = _RecordingAdapter();
      final push = await _push(adapter);

      final result = await push.syncAll();

      expect(result.ok, isFalse);
      expect(result.message, contains('跳过本轮登记'));
      expect(adapter.requests, isEmpty, reason: '不带 license 的 UPSERT 会清掉既有绑定');
    });

    /// 公开版（空注册表）没有任何东西会给出绑定 —— 必须**照旧登记**，
    /// 行为与加这条接缝之前逐字相同。
    test('没有扩展（公开版）：照旧登记，body 不带 license 字段', () async {
      final adapter = _RecordingAdapter();
      final push = await _push(adapter);

      final result = await push.syncAll();

      expect(result.ok, isTrue, reason: result.message);
      final body = adapter.requests.single.body;
      expect(body.containsKey('licenseId'), isFalse);
      expect(body.containsKey('licenseDeviceId'), isFalse);
      expect(body['mailboxEmail'], 'a@b.com');
    });
  });
}
