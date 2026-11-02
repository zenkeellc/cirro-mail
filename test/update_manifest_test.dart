// 版本清单的解析 / 校验 / 平台选择，以及 UpdateService 对「坏响应」的处理。
//
// 这一组钉住的是**外部输入**的边界：清单来自官网静态文件，可能是旧版、
// 被手改、或者（最常见）静态站把未知路径回成了 `200 + HTML`。客户端不能
// 拿 HTTP 状态码当判据，解析失败必须是一条可展示的失败，而不是「已是最新」。
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/update/update_manifest.dart';
import 'package:mail_app/core/update/update_service.dart';
import 'package:mail_app/core/version/app_version.dart';

/// 一份合法的清单。`notes` / `downloads` 按需覆盖。
String _manifestJson({
  String channel = 'public',
  String version = '0.2.0',
  int buildNumber = 132,
  String? releaseUrl = 'https://cirro.zenkee.com/download',
  Map<String, String?> downloads = const <String, String?>{
    'macos': 'https://cdn.example.com/CirroMail.dmg',
    'linux': 'https://cdn.example.com/CirroMail.AppImage',
    'windows': null,
    'android': null,
    'ios': null,
  },
  String? notes = '修了几个问题',
}) {
  String downloadsJson() {
    if (downloads.isEmpty) return '{}';
    return '{${downloads.entries.map((entry) => '"${entry.key}": ${entry.value == null ? 'null' : '"${entry.value}"'}').join(',')}}';
  }

  return '{"schema":1,"updatedAt":"2026-11-02T00:00:00Z","channels":'
      '{"$channel":{"version":"$version","buildNumber":$buildNumber,'
      '"publishedAt":"2026-11-01T12:00:00Z",'
      '"notes":"${notes ?? ''}",'
      '"releaseUrl":"${releaseUrl ?? ''}",'
      '"downloads":${downloadsJson()}}}}';
}

UpdateRelease _release() => UpdateManifest.parse(_manifestJson()).releaseFor('public')!;

void main() {
  group('UpdateManifest.parse', () {
    test('解析合法清单：渠道、版本、备注、下载地址、时间', () {
      final manifest = UpdateManifest.parse(_manifestJson());

      expect(manifest.schema, 1);
      expect(manifest.updatedAt, DateTime.utc(2026, 11, 2));
      final release = manifest.releaseFor('public');
      expect(release, isNotNull);
      expect(release!.version, '0.2.0');
      expect(release.buildNumber, 132);
      expect(release.display, '0.2.0+132');
      expect(release.notes, '修了几个问题');
      expect(release.releaseUrl, 'https://cirro.zenkee.com/download');
      expect(release.publishedAt, DateTime.utc(2026, 11, 1, 12));
      expect(release.downloads['macos'], 'https://cdn.example.com/CirroMail.dmg');
      // null / 空串的下载项不进表：界面据此知道「这个平台没有直链」。
      expect(release.downloads.containsKey('windows'), isFalse);
    });

    test('渠道名来自 channels 的键，没请求的渠道返回 null', () {
      final manifest = UpdateManifest.parse(
        _manifestJson(channel: 'pro', version: '0.1.0-pro.3'),
      );
      expect(manifest.releaseFor('pro')?.version, '0.1.0-pro.3');
      expect(manifest.releaseFor('public'), isNull);
    });

    test('坏数据一律抛 UpdateManifestException（不崩、也不当成功）', () {
      final bad = <String>[
        '', // 空响应
        '<!doctype html><html>404</html>', // 静态站 200 + HTML
        '[]', // 顶层不是对象
        '{"channels":{}}', // 缺 schema
        '{"schema":2,"channels":{"public":{"version":"1.0.0"}}}', // 不认识的 schema
        '{"schema":1}', // 缺 channels
        '{"schema":1,"channels":{}}', // 一个渠道都没有
        '{"schema":1,"channels":{"public":{"buildNumber":1}}}', // 缺 version
        '{"schema":1,"channels":{"public":{"version":"  "}}}', // 空 version
        '{"schema":1,"channels":{"public":"0.2.0"}}', // 渠道不是对象
      ];
      for (final body in bad) {
        expect(
          () => UpdateManifest.parse(body),
          throwsA(isA<UpdateManifestException>()),
          reason: '这份响应应该被当成坏数据：$body',
        );
        expect(UpdateManifest.tryParse(body), isNull);
      }
    });

    test('展示字段坏掉不抛：notes / 下载地址 / 时间只是缺失', () {
      final manifest = UpdateManifest.parse(
        '{"schema":1,"channels":{"public":{"version":"0.2.0",'
        '"buildNumber":"132","notes":123,'
        '"releaseUrl":null,"downloads":{"macos":42},'
        '"publishedAt":"不是时间"}}}',
      );
      final release = manifest.releaseFor('public')!;
      expect(release.version, '0.2.0');
      // build 号写成字符串也收下（int 解析），这是对旧清单的宽容。
      expect(release.buildNumber, 132);
      expect(release.notes, isEmpty);
      expect(release.releaseUrl, isEmpty);
      expect(release.downloads, isEmpty);
      expect(release.publishedAt, isNull);
    });
  });

  group('平台下载地址：先找直链，缺失回退 releaseUrl', () {
    test('五个平台各自的键', () {
      expect(downloadPlatformKey(TargetPlatform.android), 'android');
      expect(downloadPlatformKey(TargetPlatform.iOS), 'ios');
      expect(downloadPlatformKey(TargetPlatform.macOS), 'macos');
      expect(downloadPlatformKey(TargetPlatform.windows), 'windows');
      expect(downloadPlatformKey(TargetPlatform.linux), 'linux');
      expect(downloadPlatformKey(TargetPlatform.fuchsia), isNull);
    });

    test('直链存在时用直链', () {
      final release = _release();
      expect(
        release.downloadUrlFor(TargetPlatform.macOS),
        'https://cdn.example.com/CirroMail.dmg',
      );
      expect(
        release.downloadUrlFor(TargetPlatform.linux),
        'https://cdn.example.com/CirroMail.AppImage',
      );
    });

    test('该平台没有直链（null / 缺键）时回退 releaseUrl', () {
      final release = _release();
      expect(
        selectDownloadUrl(release, TargetPlatform.windows),
        'https://cirro.zenkee.com/download',
      );
      // Fuchsia 不在清单的键里，同样回退。
      expect(
        selectDownloadUrl(release, TargetPlatform.fuchsia),
        'https://cirro.zenkee.com/download',
      );
    });

    test('直链与 releaseUrl 都没有时返回 null（界面不画下载按钮）', () {
      final release = UpdateManifest.parse(
        _manifestJson(releaseUrl: null, downloads: const <String, String?>{}),
      ).releaseFor('public')!;
      expect(release.downloadUrlFor(TargetPlatform.macOS), isNull);
      expect(selectDownloadUrl(release, TargetPlatform.macOS), isNull);
    });
  });

  group('UpdateRelease.isNewerThan', () {
    const current = AppVersion(name: '0.1.0', buildNumber: 131);

    test('主体版本更高就是更新（build 号不参与跨版本比较）', () {
      final newer = UpdateManifest.parse(
        _manifestJson(version: '0.2.0', buildNumber: 1),
      ).releaseFor('public')!;
      expect(newer.isNewerThan(current), isTrue);
    });

    test('同名版本比 build 号', () {
      final newer = UpdateManifest.parse(
        _manifestJson(version: '0.1.0', buildNumber: 132),
      ).releaseFor('public')!;
      final same = UpdateManifest.parse(
        _manifestJson(version: '0.1.0', buildNumber: 131),
      ).releaseFor('public')!;
      final older = UpdateManifest.parse(
        _manifestJson(version: '0.1.0', buildNumber: 130),
      ).releaseFor('public')!;
      expect(newer.isNewerThan(current), isTrue);
      expect(same.isNewerThan(current), isFalse);
      expect(older.isNewerThan(current), isFalse);
    });

    test('当前版本未知时不做判断（一律不算更新）', () {
      final newer = _release();
      expect(newer.isNewerThan(AppVersion.unknown), isFalse);
    });
  });

  group('UpdateService', () {
    test('清单地址为空 = 不做更新检查', () async {
      final service = UpdateService(manifestUrl: '');
      expect(service.isConfigured, isFalse);
      await expectLater(
        service.fetchLatest(),
        throwsA(isA<UpdateException>()),
      );
    });

    test('请求带 cache-buster，返回当前渠道的版本', () async {
      late Uri requested;
      final service = UpdateService(
        manifestUrl: 'https://cirro.zenkee.com/app-version.json',
        dio: _dioReturning((options) {
          requested = options.uri;
          return ResponseBody.fromString(
            _manifestJson(),
            200,
            headers: _jsonHeaders,
          );
        }),
      );

      final release = await service.fetchLatest();
      expect(release.display, '0.2.0+132');
      expect(requested.path, '/app-version.json');
      expect(requested.queryParameters, contains('_'));
      // cache-buster 是毫秒时间戳，能解析成整数就说明不是随便拼的字符串。
      expect(int.tryParse(requested.queryParameters['_']!), isNotNull);
    });

    test('200 + HTML 必须按坏数据处理（静态站对未知路径就是这么回的）', () async {
      final service = UpdateService(
        manifestUrl: 'https://cirro.zenkee.com/app-version.json',
        dio: _dioReturning(
          (_) => ResponseBody.fromString(
            '<!doctype html><html><body>Not Found</body></html>',
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['text/html'],
            },
          ),
        ),
      );
      await expectLater(
        service.fetchLatest(),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.kind,
            'kind',
            UpdateFailureKind.malformed,
          ),
        ),
      );
    });

    test('非 2xx 折成 http 失败', () async {
      final service = UpdateService(
        manifestUrl: 'https://cirro.zenkee.com/app-version.json',
        dio: _dioReturning(
          (_) => ResponseBody.fromString('oops', 500),
        ),
      );
      await expectLater(
        service.fetchLatest(),
        throwsA(
          isA<UpdateException>()
              .having((error) => error.kind, 'kind', UpdateFailureKind.http)
              .having((error) => error.statusCode, 'statusCode', 500),
        ),
      );
    });

    test('清单里没有当前渠道 → channelMissing', () async {
      final service = UpdateService(
        manifestUrl: 'https://cirro.zenkee.com/app-version.json',
        dio: _dioReturning(
          (_) => ResponseBody.fromString(
            _manifestJson(channel: 'pro'),
            200,
            headers: _jsonHeaders,
          ),
        ),
      );
      await expectLater(
        service.fetchLatest(),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.kind,
            'kind',
            UpdateFailureKind.channelMissing,
          ),
        ),
      );
    });

    test('网络错误折成 network 失败', () async {
      final service = UpdateService(
        manifestUrl: 'https://cirro.zenkee.com/app-version.json',
        dio: _dioReturning(
          (options) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            message: '没网',
          ),
        ),
      );
      await expectLater(
        service.fetchLatest(),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.kind,
            'kind',
            UpdateFailureKind.network,
          ),
        ),
      );
    });

    test('数据映射失败不抛 Dio 之外的异常', () async {
      // 空响应体（200 但什么都没有）也要落成 malformed，而不是崩在解析里。
      final service = UpdateService(
        manifestUrl: 'https://cirro.zenkee.com/app-version.json',
        dio: _dioReturning((_) => ResponseBody.fromString('', 200)),
      );
      await expectLater(
        service.fetchLatest(),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.kind,
            'kind',
            UpdateFailureKind.malformed,
          ),
        ),
      );
    });
  });
}

const Map<String, List<String>> _jsonHeaders = <String, List<String>>{
  Headers.contentTypeHeader: <String>['application/json'],
};

Dio _dioReturning(ResponseBody Function(RequestOptions) handler) {
  final dio = Dio();
  dio.httpClientAdapter = _FakeAdapter(handler);
  return dio;
}

/// 不碰网络的 Dio 适配器：每个用例自己决定回什么（或抛什么）。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._handler);

  final ResponseBody Function(RequestOptions) _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      _handler(options);

  @override
  void close({bool force = false}) {}
}
