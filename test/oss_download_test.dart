import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/error/app_exception.dart';
import 'package:mail_app/data/api/oss_api.dart';

/// `/api/oss/*` 的下载必须**嗅探**，不能见到 HTTP 200 就写盘。
///
/// 这条是 cloud-mail 的一个真实坑：对象不存在时服务端返回的是
/// **HTTP 200 + `{"code":500,"message":"Cannot read properties of null …"}`**，
/// `validateStatus` 放行一切的话，一个只会看状态码的下载器会把这 72 字节的
/// JSON 存成 `合同.pdf` —— 用户点开发现「文件坏了」，而真相是附件根本没传上去。
///
/// 所以这里对着三种响应断言：真文件能落盘、JSON 信封被拦下且**不留文件**、
/// 网络错误被翻成人话。
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oss_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('正常附件：字节落盘，返回写入长度', () async {
    final payload = List<int>.generate(4096, (i) => i % 256);
    final api = OssApi(_dioWith(_bytesResponse(payload)));

    final target = File('${temp.path}/report.bin');
    var written = 0;
    final result = await api.downloadTo(
      url: 'https://mail.example.com/api/oss/attachments/abc.bin',
      savePath: target.path,
      writeTo: (stream, expected) async {
        final sink = target.openWrite();
        await for (final chunk in stream) {
          sink.add(chunk);
          written += chunk.length;
        }
        await sink.close();
      },
    );

    expect(result, payload.length);
    expect(written, payload.length);
    expect(await target.readAsBytes(), payload);
  });

  test('对象不存在（HTTP 200 + JSON 信封）→ 抛 AttachmentNotAvailable，不写盘', () async {
    final api = OssApi(
      _dioWith(
        _jsonResponse(<String, Object?>{
          'code': 500,
          'message': "Cannot read properties of null (reading 'body')",
        }),
      ),
    );

    final target = File('${temp.path}/missing.pdf');
    var sinkOpened = false;

    await expectLater(
      api.downloadTo(
        url: 'https://mail.example.com/api/oss/attachments/gone.pdf',
        savePath: target.path,
        writeTo: (stream, expected) async {
          // 这一步**不该被调用** —— 调用方一旦开写，文件就已经生成了。
          sinkOpened = true;
        },
      ),
      throwsA(isA<AttachmentNotAvailableException>()),
    );

    expect(sinkOpened, isFalse, reason: '拦在写盘之前');
    expect(await target.exists(), isFalse);
  });

  test('键为空 → 直接拒绝，不发请求', () async {
    var requested = false;
    final api = OssApi(
      _dioWith(_bytesResponse(const <int>[1]), onRequest: () => requested = true),
    );

    await expectLater(
      api.downloadTo(
        url: '',
        savePath: '${temp.path}/x',
        writeTo: (stream, expected) async {},
      ),
      throwsA(isA<AttachmentNotAvailableException>()),
    );
    expect(requested, isFalse);
  });

  test('连不上 → NetworkException（而不是「附件不可用」）', () async {
    final dio = Dio(BaseOptions(validateStatus: (_) => true));
    dio.httpClientAdapter = _FakeAdapter(
      (_) async => throw DioException.connectionError(
        requestOptions: RequestOptions(path: '/'),
        reason: 'connection refused',
      ),
    );
    final api = OssApi(dio);

    await expectLater(
      api.downloadTo(
        url: 'https://mail.example.com/api/oss/a.bin',
        savePath: '${temp.path}/a.bin',
        writeTo: (stream, expected) async {},
      ),
      throwsA(isA<NetworkException>()),
    );
  });

  test('下载被取消 → RequestCancelledException（UI 不该弹错）', () async {
    final dio = Dio(BaseOptions(validateStatus: (_) => true));
    dio.httpClientAdapter = _FakeAdapter(
      (_) async => throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: '/'),
        reason: 'user left',
      ),
    );
    final api = OssApi(dio);

    await expectLater(
      api.downloadTo(
        url: 'https://mail.example.com/api/oss/a.bin',
        savePath: '${temp.path}/a.bin',
        writeTo: (stream, expected) async {},
      ),
      throwsA(isA<RequestCancelledException>()),
    );
  });
}

// ------------------------------------------------------------------ 测试替身

Dio _dioWith(ResponseBody body, {void Function()? onRequest}) {
  final dio = Dio(BaseOptions(validateStatus: (_) => true));
  dio.httpClientAdapter = _FakeAdapter((options) async {
    onRequest?.call();
    return body;
  });
  return dio;
}

/// 一个「服务器说它是 JSON」的响应 —— 正是对象缺失时的那副样子。
ResponseBody _jsonResponse(Map<String, Object?> data) {
  final bytes = utf8.encode(jsonEncode(data));
  return _body(bytes, contentType: 'application/json;charset=utf-8');
}

ResponseBody _bytesResponse(List<int> data) =>
    _body(data, contentType: 'application/octet-stream');

ResponseBody _body(List<int> data, {required String contentType}) => ResponseBody(
      Stream<Uint8List>.fromIterable(<Uint8List>[Uint8List.fromList(data)]),
      200, // 关键：HTTP 状态**恒为 200**，包括「对象不存在」那条路径。
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[contentType],
        // dio 的 `contentLength` 只认这个头，不看构造参数。
        Headers.contentLengthHeader: <String>['${data.length}'],
      },
    );

/// 只回一个固定响应的适配器。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}
