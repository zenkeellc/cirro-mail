import 'package:dio/dio.dart';

import '../../core/config/app_defaults.dart';
import '../../core/error/app_exception.dart';
import '../../core/network/api_envelope.dart';

/// `mail-push` 中转端的客户端。
///
/// ## 为什么单独一条 Dio，不复用实例的 `ApiClient`
///
/// 中转端跟实例**没有任何关系**：它不认识实例的 JWT（每个实例有自己的
/// `jwt_secret`），也不该被实例的 401 处理链路牵连（实例 token 过期
/// 不该让推送注册也失败，反过来也一样）。所以这里是一条干净的短超时
/// 连接，只在「注册设备 / 注销 / 补拉事件」三个地方用。
///
/// 响应形状跟实例**保持一致**（HTTP 200 + `{code,message,data}`），
/// 所以复用同一个 [ApiEnvelope] 拆包逻辑 —— 只有 webhook 那一条路径
/// 返回真实状态码，而那条路径只有实例端会调，App 碰不到。
class RelayClient {
  RelayClient({required String baseUrl, Dio? dio})
      : _baseUrl = _normalize(baseUrl),
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: _normalize(baseUrl),
                connectTimeout: AppDefaults.connectTimeout,
                receiveTimeout: AppDefaults.receiveTimeout,
                contentType: Headers.jsonContentType,
                responseType: ResponseType.json,
                // 跟实例一样：真实状态在信封里，不是 HTTP 状态码。
                validateStatus: (_) => true,
                headers: <String, dynamic>{
                  'Accept': Headers.jsonContentType,
                  'User-Agent': AppDefaults.userAgent,
                },
              ),
            );

  final String _baseUrl;
  final Dio _dio;

  String get baseUrl => _baseUrl;

  /// 没配中转地址时不能构造请求 —— 上层据此跳过整条推送链路，
  /// 而不是打一个 baseUrl 是空串的请求然后收到一个看不懂的异常。
  bool get isConfigured => _baseUrl.isNotEmpty;

  /// 中转端地址归一化：补上 https、去掉尾部 `/`。
  ///
  /// 用户多半会从浏览器地址栏复制，末尾那个 `/` 会让拼出来的路径
  /// 变成 `//register` —— 有些边缘会把它当另一个路径处理。
  static String _normalize(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// `GET /health` —— 不鉴权，用来在「测试连接」时确认这是个 mail-push。
  Future<RelayHealth> health() async {
    final data = await _get('/health');
    final map = (data is Map) ? data : const <String, dynamic>{};
    return RelayHealth(
      instances: _asInt(map['instances']),
      fcmConfigured: map['fcmConfigured'] == true,
      adminConfigured: map['adminConfigured'] == true,
    );
  }

  /// 注册（或更新）这台设备在某个收件邮箱上的推送。
  Future<void> register({
    required String instanceId,
    required String deviceToken,
    required String deviceId,
    required String mailboxEmail,
    required String fcmToken,
    required String platform,
  }) async {
    await _post('/register', <String, dynamic>{
      'instanceId': instanceId,
      'deviceToken': deviceToken,
      'deviceId': deviceId,
      'mailboxEmail': mailboxEmail,
      'token': fcmToken,
      'platform': platform,
    });
  }

  /// 注销。不传 [mailboxEmail] 就是「这台设备在这个实例下的全部邮箱」。
  Future<int> unregister({
    required String instanceId,
    required String deviceToken,
    required String deviceId,
    String? mailboxEmail,
  }) async {
    final data = await _post('/unregister', <String, dynamic>{
      'instanceId': instanceId,
      'deviceToken': deviceToken,
      'deviceId': deviceId,
      if (mailboxEmail != null && mailboxEmail.isNotEmpty)
        'mailboxEmail': mailboxEmail,
    });
    final map = (data is Map) ? data : const <String, dynamic>{};
    return _asInt(map['removed']);
  }

  /// 中转端记着这台设备订阅了哪些邮箱（用来在设置页回显）。
  Future<List<String>> devices({
    required String instanceId,
    required String deviceToken,
    required String deviceId,
  }) async {
    final data = await _post('/devices', <String, dynamic>{
      'instanceId': instanceId,
      'deviceToken': deviceToken,
      'deviceId': deviceId,
    });
    final map = (data is Map) ? data : const <String, dynamic>{};
    final list = map['mailboxes'];
    if (list is! List) return const <String>[];
    return list
        .whereType<Map>()
        .map((item) => item['mailboxEmail']?.toString() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  /// 部署者一键开通：在**自己的**中转端上开一个实例位，拿回配对码。
  ///
  /// ## 为什么这条要单独拿出来说
  ///
  /// 「配对码在哪获取」是这个功能上最容易卡死的一步：配对码 = `instances.secret`，
  /// 它**只在中转位被创建的那一刻回显一次**，之后两端都读不回来（`/setting/query`
  /// 把它 mask 成 `******`）。用户自己的实例后台里那个字段是空的，他没有任何
  /// 地方能「查」到它 —— 只能由 Endpoint 端生成。
  ///
  /// 所以真正意义上的「自动获取」只有这一条路：部署者（也就是能碰到
  /// `ADMIN_TOKEN` 的那个人）在这里现开一个位。开完实例位 id 与配对码
  /// 两边都拿到了，不需要用户去别处复制粘贴。
  ///
  /// ## 关于 [adminToken]
  ///
  /// 它**只作为请求头发出**：不落 prefs、不进 `TokenStore`、不写任何日志。
  /// 调用方（设置页那个受控输入框）负责在页面销毁时清掉它。
  /// 中转端没配 `ADMIN_TOKEN` 时管理面是关闭的，会拿到
  /// 「没有配置 ADMIN_TOKEN」这句话，而不是一个静默的 404。
  Future<RelayInstance> createInstance({
    required String adminToken,
    String name = '',
  }) async {
    final data = await _unwrap(
      () => _dio.post<Object?>(
        '/admin/instances',
        data: <String, dynamic>{
          if (name.trim().isNotEmpty) 'name': name.trim(),
        },
        options: Options(
          headers: <String, dynamic>{'Authorization': 'Bearer ${adminToken.trim()}'},
        ),
      ),
    );
    return RelayInstance.fromJson(
      (data is Map) ? data : const <String, dynamic>{},
    );
  }

  /// 自检：拿**配对码**问中转端「实例后台该怎么填、我填的对不对」。
  ///
  /// 这条存在的理由是失败长得太安静：webhook 填错之后，实例那边只有当
  /// **真的收到一封外部来信**时才会去打它，打不通也只在自己的日志里留
  /// 一行。用户在这一头什么都看不到，只能一直等一封不会来的通知。
  ///
  /// [webhookUrl] 是用户在实例后台**准备粘贴**的地址；传空串表示只验配对码。
  Future<RelayVerifyResult> verifyWebhook({
    required String instanceId,
    required String webhookSecret,
    String webhookUrl = '',
  }) async {
    final data = await _post('/verify-webhook', <String, dynamic>{
      'instanceId': instanceId,
      if (webhookSecret.isNotEmpty) 'webhookSecret': webhookSecret,
      if (webhookUrl.isNotEmpty) 'webhookUrl': webhookUrl,
    });
    return RelayVerifyResult.fromJson(
      (data is Map) ? data : const <String, dynamic>{},
    );
  }

  /// 补拉事件（推送丢了之后的兜底）。游标是 `emailId`。
  Future<RelayEventsPage> events({
    required String instanceId,
    required String deviceToken,
    required int since,
    String? mailboxEmail,
    int limit = 50,
  }) async {
    final query = <String, dynamic>{
      'instanceId': instanceId,
      'since': '$since',
      'limit': '$limit',
      if (mailboxEmail != null && mailboxEmail.isNotEmpty)
        'mailboxEmail': mailboxEmail,
    };
    // 配对码走 header 而不是 query：它会出现在边缘的访问日志里，
    // 而这条是真正常规用的那条路（curl 调试时可以用 query 版）。
    final data = await _get(
      '/events',
      query: query,
      headers: <String, dynamic>{'Authorization': deviceToken},
    );
    final map = (data is Map) ? data : const <String, dynamic>{};
    final list = map['events'];
    return RelayEventsPage(
      events: list is List
          ? list.whereType<Map>().map(RelayEvent.fromJson).toList(growable: false)
          : const <RelayEvent>[],
      cursor: _asInt(map['cursor']),
      hasMore: map['hasMore'] == true,
    );
  }

  // ------------------------------------------------------------------ 内部

  Future<Object?> _get(
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    return _unwrap(() => _dio.get<Object?>(
          path,
          queryParameters: query,
          options: headers == null ? null : Options(headers: headers),
        ));
  }

  Future<Object?> _post(String path, Map<String, dynamic> body) async {
    return _unwrap(() => _dio.post<Object?>(path, data: body));
  }

  /// 把「网络异常 / 信封错误」统一折成 [AppException]。
  ///
  /// 这里不做任何静默兜底：推送注册失败必须让调用方知道，否则用户会
  /// 一直以为「我明明开了推送」。降级是调用方的事（比如设置页把开关
  /// 弹回去并显示原因）。
  Future<Object?> _unwrap(Future<Response<Object?>> Function() request) async {
    Response<Object?> response;
    try {
      response = await request();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        throw TimeoutException(detail: '推送中转超时：${e.message ?? ''}');
      }
      if (e.type == DioExceptionType.cancel) {
        throw const RequestCancelledException();
      }
      throw NetworkException(detail: '推送中转连接失败：${e.message ?? e.type.name}');
    }

    final envelope = ApiEnvelope.tryParse(response.data);
    if (envelope == null) {
      // 不是信封 —— 多半是打到了别的服务上（比如把实例地址当成了中转地址）。
      throw ServerException(
        message: '推送中转的响应看不懂（HTTP ${response.statusCode}）—— 地址是不是填成了实例地址？',
        statusCode: response.statusCode,
        body: response.data?.toString(),
      );
    }
    if (!envelope.isOk) {
      // 401 在这里**不**走 AuthExpiredException：中转端的 401 是「配对码
      // 不对」，跟实例登录没有任何关系。当成普通 ApiException 让调用方
      // 去提示用户重新配对。
      throw ApiException(code: envelope.code, message: envelope.message, data: envelope.data);
    }
    return envelope.data;
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }
}

class RelayHealth {
  const RelayHealth({
    required this.instances,
    required this.fcmConfigured,
    required this.adminConfigured,
  });

  /// 这个中转上开了多少个实例位。
  final int instances;

  /// 中转端是否配了 FCM 服务账号。**没配的话推送一条也发不出去**，
  /// 设置页必须把这件事显出来，否则用户会以为是自己的问题。
  final bool fcmConfigured;

  /// 是否配了管理口令（没配的话部署者开不了实例位）。
  final bool adminConfigured;
}

/// `/admin/instances` 开出来的一个实例位。
///
/// [webhookSecret] 是**唯一一次**能拿到它的机会（中转端落库后连管理员也读不回来），
/// 调用方拿到之后必须立刻存进 `TokenStore`，不能只留在内存里 ——
/// 用户关掉这一页再进来，这个值就永久丢失了，只能轮换一个新的。
class RelayInstance {
  const RelayInstance({
    required this.instanceId,
    required this.name,
    required this.webhookSecret,
    required this.webhookPath,
    required this.usingInstanceFcm,
  });

  final String instanceId;
  final String name;
  final String webhookSecret;
  final String webhookPath;
  final bool usingInstanceFcm;

  factory RelayInstance.fromJson(Map<dynamic, dynamic> json) => RelayInstance(
        instanceId: json['instanceId']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        webhookSecret: json['webhookSecret']?.toString() ?? '',
        webhookPath: json['webhookPath']?.toString() ?? '',
        usingInstanceFcm: json['usingInstanceFcm'] == true,
      );
}

/// `/verify-webhook` 的结论。
///
/// 三个字段各自是**独立的一件事实**，不要合成一个 bool：「配对码对不对」
/// 和「地址填得对不对」是两次不同的手滑，用户得知道该改哪一个。
class RelayVerifyResult {
  const RelayVerifyResult({
    required this.instanceId,
    required this.name,
    required this.webhookUrl,
    required this.webhookPath,
    required this.secretOk,
    required this.urlOk,
    required this.lastEventAt,
  });

  final String instanceId;

  /// 中转端上这个位的备注名（部署者起的）。
  final String name;

  /// 该填进实例后台的完整地址。已经带上了 `/<instanceId>/webhook`。
  final String webhookUrl;

  /// 只要路径部分（相对中转地址）。
  final String webhookPath;

  /// 配对码是不是这个位的 secret。null = 这次没送 secret 过来。
  final bool? secretOk;

  /// 送过来的地址路径对不对。null = 这次没送地址。
  final bool? urlOk;

  /// 这个位最近一次真的收到 webhook 的时间。
  ///
  /// 「静态检查全过」和「链路真的通」是两件事 —— 全都对但从未收到过，
  /// 说明用户还没把配置存进实例后台（或者实例那边开关没开）。
  final String? lastEventAt;

  factory RelayVerifyResult.fromJson(Map<dynamic, dynamic> json) =>
      RelayVerifyResult(
        instanceId: json['instanceId']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        webhookUrl: json['webhookUrl']?.toString() ?? '',
        webhookPath: json['webhookPath']?.toString() ?? '',
        secretOk: json['secretOk'] is bool ? json['secretOk'] as bool : null,
        urlOk: json['urlOk'] is bool ? json['urlOk'] as bool : null,
        lastEventAt: json['lastEventAt']?.toString(),
      );

  /// 两个已知的检查项是不是都过了。
  ///
  /// `null`（没送那一项）**不算通过**：这个 getter 是拿来做 UI 判断的，
  /// 「没问」和「问过且对」不是一回事。
  bool get allOk => secretOk == true && urlOk == true;
}

class RelayEventsPage {
  const RelayEventsPage({
    required this.events,
    required this.cursor,
    required this.hasMore,
  });

  final List<RelayEvent> events;
  final int cursor;
  final bool hasMore;
}

/// 中转端补拉回来的一条事件（**只有元数据**，正文在实例那边）。
class RelayEvent {
  const RelayEvent({
    required this.instanceId,
    required this.emailId,
    required this.mailboxEmail,
    required this.sendEmail,
    required this.sendName,
    required this.subject,
    required this.code,
    required this.createTime,
  });

  final String instanceId;
  final int emailId;
  final String mailboxEmail;
  final String sendEmail;
  final String sendName;
  final String subject;
  final String code;
  final String createTime;

  factory RelayEvent.fromJson(Map<dynamic, dynamic> json) => RelayEvent(
        instanceId: json['instanceId']?.toString() ?? '',
        emailId: RelayClient._asInt(json['emailId']),
        mailboxEmail: json['mailboxEmail']?.toString() ?? '',
        sendEmail: json['sendEmail']?.toString() ?? '',
        sendName: json['sendName']?.toString() ?? '',
        subject: json['subject']?.toString() ?? '',
        code: json['code']?.toString() ?? '',
        createTime: json['createTime']?.toString() ?? '',
      );
}
