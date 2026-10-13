import 'package:dio/dio.dart';

import '../core/network/api_client.dart';
import '../core/network/auth_events.dart';
import '../core/network/dio_factory.dart';
import '../core/storage/prefs_store.dart';
import '../core/storage/token_store.dart';
import '../data/api/account_api.dart';
import '../data/api/auth_api.dart';
import '../data/api/email_api.dart';
import '../data/api/my_api.dart';
import '../data/api/oss_api.dart';
import '../data/api/setting_api.dart';
import '../data/api/star_api.dart';
import '../data/models/profile.dart';

/// **一个实例的全部运行时状态**。
///
/// 多实例架构的落点：每个 profile 有自己的 Dio、ApiClient、API 门面、
/// 自己的 token（走全局密钥库但按 profileId 分 key）、自己的能力结论、
/// 自己的退避节奏。它们共用同一张 drift 库，但**不共用任何网络对象** ——
/// 这是「A 实例的 token 失效不影响 B 实例」能成立的前提。
///
/// 生命周期：`RuntimeRegistry` 在 profile 首次被用到时创建，实例被删除或
/// baseUrl 变更时 [dispose]。dispose 会 `close(force: true)` 掉 Dio，
/// 取消在途请求 —— 切实例后旧请求不该再回来改状态。
class ProfileRuntime {
  ProfileRuntime._({
    required this.profile,
    required this.authEvents,
    required this._tokens,
    required Dio apiDio,
    required Dio downloadDio,
    bool enableLog = false,
  })  : _apiDio = apiDio,
        _downloadDio = downloadDio,
        apiClient = ApiClient(apiDio) {
    authApi = AuthApi(apiClient);
    settingApi = SettingApi(apiClient);
    myApi = MyApi(apiClient);
    accountApi = AccountApi(apiClient);
    emailApi = EmailApi(apiClient);
    starApi = StarApi(apiClient);
    // 附件下载用**另一条**裸 Dio（无 Authorization、长超时、bytes 响应）。
    ossApi = OssApi(downloadDio);

    // 诊断日志**只在这里挂一次**（不在 `DioFactory.build` 里挂）——
    // 两条 Dio 都从这里经过，包括测试注入的那条。挂两处的话同一请求会打两遍。
    // `DiagLog.enabled` 自己会判掉 release，这里不必再判一次。
    if (enableLog) {
      DioFactory.attachDiagLogger(_apiDio, scope: 'http[$profileId]');
      DioFactory.attachDiagLogger(_downloadDio, scope: 'http[$profileId]');
    }
  }

  /// 为一个 profile 构造运行时。
  ///
  /// [profile.baseUrl] 必须已经是最终值 —— 换服务器要**重建** runtime
  /// （见 `RuntimeRegistry.ensure` 的 baseUrl 比对），而不是改这个对象的字段。
  factory ProfileRuntime.create({
    required Profile profile,
    required AuthEvents authEvents,
    required TokenStore tokens,
    required PrefsStore prefs,
    bool enableLog = false,
    Dio? apiDio,
    Dio? downloadDio,
  }) {
    Dio buildApiDio() => DioFactory.build(
          userApi: profile.baseUrl,
          profileId: profile.id,
          authEvents: authEvents,
          // **同步**读缓存：拦截器是同步的，这里不能 await。
          // 首次请求之前必须 await 过一次 warmUp()，否则首个请求会静默地
          // 不带 token（readCached 返回 null），换来一个 401。
          readToken: () => tokens.readCached(profile.id),
          readLanguage: () => prefs.localeCode ?? 'zh',
          enableLog: enableLog,
        );

    return ProfileRuntime._(
      profile: profile,
      authEvents: authEvents,
      tokens: tokens,
      // 允许注入：发信链路的单测要能看到 dio **真正发出去的字节**
      // （`Content-Length` 与流式 body 是否一致），而真实的
      // `IOHttpClientAdapter` 会拉起真的 socket。
      apiDio: apiDio ?? buildApiDio(),
      downloadDio: downloadDio ?? DioFactory.buildDownloadDio(enableLog: enableLog),
      enableLog: enableLog,
    );
  }

  final Profile profile;
  final AuthEvents authEvents;

  final TokenStore _tokens;

  /// 带鉴权的 Dio（内部保留引用，dispose 时要 close）。
  final Dio _apiDio;

  /// 无鉴权的下载 Dio。
  final Dio _downloadDio;

  final ApiClient apiClient;

  late final AuthApi authApi;
  late final SettingApi settingApi;
  late final MyApi myApi;
  late final AccountApi accountApi;
  late final EmailApi emailApi;
  late final StarApi starApi;
  late final OssApi ossApi;

  final CancelToken _cancelToken = CancelToken();
  bool _disposed = false;

  String get profileId => profile.id;
  String get baseUrl => profile.baseUrl;
  bool get isDisposed => _disposed;

  /// 把 token 读进内存缓存，使后续请求能带上 Authorization。
  ///
  /// 冷启动时这里常常会读到「空」—— 但那有两种含义：真的没登录过，或者
  /// 用户**还没重新登录**（`needs_login = 1` 的实例就停在那个状态）。
  /// 两者都不能让 `hasToken` 就此定格：同步引擎一见 `hasToken == false`
  /// 就报「未登录」并停掉循环，于是那个实例永远等不到用户重登 ——
  /// 即便 token 后来写回来了，本轮循环也已经停了，要等下一次 `isDue`
  /// 才会再走一遍（而 `_stopped` 是粘的）。
  ///
  /// 所以读空之后再问一次钥匙串（只一次，见 `TokenStore.wantsRefresh`）。
  Future<String?> warmUp() async {
    final value = await _tokens.read(profile.id);
    if (value != null && value.isNotEmpty) return value;
    if (!_tokens.wantsRefresh(profile.id)) return value;
    return _tokens.readFresh(profile.id);
  }

  Future<void> saveToken(String token) => _tokens.write(profile.id, token);

  Future<void> clearToken() => _tokens.delete(profile.id);

  /// 当前是否持有 token（只看缓存 —— 调用方一般先 [warmUp]）。
  bool get hasToken => (_tokens.readCached(profile.id) ?? '').isNotEmpty;

  /// 请求级取消令牌。切实例 / 用户下拉刷新覆盖上一次请求时用。
  CancelToken get cancelToken => _cancelToken;

  void cancelAll() {
    if (!_cancelToken.isCancelled) _cancelToken.cancel('runtime cancelled');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelAll();
    // 下载 Dio 通常在流式写盘，必须 force，否则要等它自然结束。
    _apiDio.close(force: true);
    _downloadDio.close(force: true);
  }

  /// 本地缓存的 OSS 前缀（来自上次探测的 `websiteConfig.r2Domain`）。
  ///
  /// [Profile.ossBase] 是探测时算好存下的；这里给兜底 ——
  /// 还没探测过时按「无 r2Domain」的形态推（走 `/api/oss/`）。
  String get ossBase => profile.ossBase.isNotEmpty
      ? profile.ossBase
      : profile.resolveOssBase(null);

  @override
  String toString() =>
      'ProfileRuntime($profileId, $baseUrl, disposed=$_disposed)';
}
