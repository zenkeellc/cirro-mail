import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_defaults.dart';
import 'update_manifest.dart';

/// 一次更新检查失败的原因分类。
///
/// 分类本身不直接展示给用户（界面上只有「检查失败」+ 重试），但**测试与
/// 诊断**要能区分「网断了」和「清单坏了」：前者再点一次就好，后者说明官网
/// 那边有问题，重试没有意义。
enum UpdateFailureKind {
  /// 连不上 / DNS / TLS / 被中断。
  network,

  /// 超时。与 [network] 分开是因为它通常值得原样重试一次。
  timeout,

  /// HTTP 状态码不是 2xx。
  http,

  /// 响应不是合法清单（JSON 解析失败、schema 不认识、渠道缺失等）。
  ///
  /// 静态站对未知路径回 `200 + HTML`，那种响应**只能**走到这里 —— 这就是
  /// 为什么本服务从不拿状态码当「有没有清单」的判据。
  malformed,

  /// 清单是好的，但没有当前构建所属的那个渠道。
  channelMissing,
}

/// 更新检查失败。
class UpdateException implements Exception {
  const UpdateException(this.kind, this.message, {this.statusCode});

  final UpdateFailureKind kind;
  final String message;

  /// 只有 [UpdateFailureKind.http] 有值。
  final int? statusCode;

  @override
  String toString() =>
      'UpdateException(${kind.name}${statusCode == null ? '' : ', HTTP $statusCode'}): '
      '$message';
}

/// 读官网的版本清单（`app-version.json`），回答「有没有新版本」。
///
/// ## 为什么单独一条 Dio
///
/// 清单在官网静态站上，跟用户的 mail 实例**没有任何关系**：不需要实例的
/// JWT、不该被实例的 401 链路牵连、也不该跟着实例的 UA / 超时走。照
/// `RelayClient` 的取舍，这里是一条干净、短超时的独立连接。
///
/// **只做「取」这一件事**：不弹提示、不写 prefs、不改 UI 状态。状态机在
/// `update_controller.dart`，提示在 `features/update/update_host.dart`。
class UpdateService {
  UpdateService({
    String? manifestUrl,
    String? channel,
    Dio? dio,
  })  : _manifestUrl = (manifestUrl ?? AppDefaults.updateManifestUrl).trim(),
        _channel = (channel ?? AppDefaults.updateChannel).trim(),
        _dio = dio ??
            Dio(
              BaseOptions(
                // 清单是个几 KB 的小文件，8 秒足够；它挡在启动路径上，
                // 不能等成 15 秒。
                connectTimeout: requestTimeout,
                receiveTimeout: requestTimeout,
                responseType: ResponseType.plain,
                // 状态码不是判据（静态站的 200 也可能是 HTML），下面自己判。
                validateStatus: (_) => true,
                headers: <String, dynamic>{
                  'Accept': Headers.jsonContentType,
                  'User-Agent': AppDefaults.userAgent,
                },
              ),
            );

  /// 清单请求的超时。比实例的 connectTimeout 短：更新检查是后台锦上添花，
  /// 不该在冷启动时占着网络不放。
  static const Duration requestTimeout = Duration(seconds: 8);

  final String _manifestUrl;
  final String _channel;
  final Dio _dio;

  /// 清单地址。空串 = 这个构建不做更新检查（`--dart-define` 关掉）。
  String get manifestUrl => _manifestUrl;

  /// 当前构建所属的渠道（公开版 `public`，商业版由构建参数定义）。
  String get channel => _channel;

  /// 清单地址为空时整个更新检查都是关闭的 —— 关于页据此隐藏整块 UI，
  /// 而不是显示一个永远失败的按钮。
  bool get isConfigured => _manifestUrl.isNotEmpty;

  /// 取当前渠道的最新版本。
  ///
  /// 失败抛 [UpdateException]。**不吞异常**：调用方（controller）要把失败
  /// 展示成「检查失败 + 重试」，静默返回 null 会让用户以为「已经是最新」。
  Future<UpdateRelease> fetchLatest() async {
    if (!isConfigured) {
      throw const UpdateException(
        UpdateFailureKind.malformed,
        '没有配置版本清单地址',
      );
    }

    final uri = _cacheBusted(Uri.parse(_manifestUrl));
    Response<String> response;
    try {
      response = await _dio.getUri<String>(
        uri,
        // 显式声明：注入进来的 Dio（测试）可能没配 plain，而这里要的是
        // 「原样的响应文本」去交给解析器 —— 让 Dio 按 JSON 预解码会把
        // 「200 + HTML」变成一个看不懂的转换异常。
        // `validateStatus` 也一样要在这里盖住：状态码不是判据（静态站的
        // 200 也可能是 HTML），由下面自己判，别让 Dio 先抛 badResponse。
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        throw UpdateException(
          UpdateFailureKind.timeout,
          '版本清单请求超时：${error.message ?? ''}',
        );
      }
      throw UpdateException(
        UpdateFailureKind.network,
        '版本清单请求失败：${error.message ?? error.type.name}',
      );
    }

    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw UpdateException(
        UpdateFailureKind.http,
        '检查更新失败（错误 $status），稍后重试',
        statusCode: status,
      );
    }

    final body = response.data ?? '';
    final UpdateManifest manifest;
    try {
      manifest = UpdateManifest.parse(body);
    } on UpdateManifestException catch (error) {
      // 走到这里最常见的原因是「静态站把未知路径回成了 HTML」——
      // 状态码明明是 200，但内容根本不是 JSON。必须按坏响应处理。
      throw UpdateException(
        UpdateFailureKind.malformed,
        '版本清单解析失败：${error.message}',
      );
    }

    final release = manifest.releaseFor(channel);
    if (release == null) {
      throw UpdateException(
        UpdateFailureKind.channelMissing,
        '版本清单里没有渠道 $channel',
      );
    }
    return release;
  }

  /// 给请求加一个 cache-buster。
  ///
  /// 官网前面有 CDN，而且 `app-version.json` 是「文件名固定、内容会变」的
  /// 那种资源：不加这个参数时，刚发布的新版本可能被边缘缓存按住几小时，
  /// 用户看到的还是「已是最新」。
  static Uri _cacheBusted(Uri uri) {
    final query = Map<String, String>.from(uri.queryParameters);
    query['_'] = '${DateTime.now().millisecondsSinceEpoch}';
    return uri.replace(queryParameters: query);
  }
}

/// 全局唯一的更新检查客户端。
///
/// 做成 provider 是为了测试能 override 一个假 service（`update_controller_test`
/// 就是这么做的），生产路径上不读任何可变状态。
final Provider<UpdateService> updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService(),
  name: 'updateService',
);
