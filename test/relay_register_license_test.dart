import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/notifications/relay_client.dart';

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

void main() {
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
}
