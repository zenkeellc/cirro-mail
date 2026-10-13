import '../../core/util/url_utils.dart';

/// 一个「实例 + 账号」profile。
///
/// 多实例的核心：每个 profile 有自己的 baseUrl、自己的 token
/// （token 不入库，存 `flutter_secure_storage` 的 `token_<id>`），
/// 但**共用同一张 drift 库**，靠 `profileId` 区分数据。
///
/// [ossBase] 是**缓存值**：附件/内嵌图前缀由 `websiteConfig.r2Domain` 决定，
/// 每次探测成功都会重算。缓存它只为渲染时不依赖 config provider。
class Profile {
  const Profile({
    required this.id,
    required this.baseUrl,
    this.name = '',
    this.email = '',
    this.serverTitle = '',
    this.userName = '',
    this.userId = 0,
    this.ossBase = '',
    this.sort = 0,
    this.colorIndex = 0,
    this.needsLogin = false,
    this.lastSyncAt,
    this.createdAt,
    this.lastActiveAt,
  });

  /// UUID。所有本地行的外键，也是 secure storage 的 key 后缀。
  final String id;

  /// 规范化过、**含 `/api`** 的地址，直接用作 Dio 的 baseUrl。
  final String baseUrl;

  /// 用户起的备注名（默认用实例标题或邮箱）。
  final String name;

  /// 登录账号（用户表 email）。
  final String email;

  /// 实例自报的标题（`websiteConfig.title`）。
  final String serverTitle;

  /// 主邮箱显示名（`loginUserInfo.name`）。
  final String userName;

  final int userId;

  /// 附件/内嵌图前缀，见 [UrlUtils.ossBase]。空串表示还没探测出来。
  final String ossBase;

  final int sort;

  /// 实例色标（聚合时间线里区分来源），取 `instance_colors` 的下标。
  final int colorIndex;

  /// token 被服务端判 401 后置位 —— 该实例的同步循环会停下等用户重登，
  /// **不影响其他实例**。
  final bool needsLogin;

  final DateTime? lastSyncAt;
  final DateTime? createdAt;
  final DateTime? lastActiveAt;

  /// 站点根（去掉 `/api`）。
  String get host => UrlUtils.hostRoot(baseUrl);

  String get displayName {
    if (name.isNotEmpty) return name;
    if (serverTitle.isNotEmpty) return serverTitle;
    if (email.isNotEmpty) return email;
    return host;
  }

  /// 侧栏/聚合行的第二行小字。
  String get subtitle => email.isNotEmpty ? email : host;

  bool get isLoggedIn => userId > 0 && !needsLogin && email.isNotEmpty;

  /// 从已探测到的配置算出最新的 ossBase。
  String resolveOssBase(String? r2Domain) =>
      UrlUtils.ossBase(userApi: baseUrl, r2Domain: r2Domain);

  Profile copyWith({
    String? name,
    String? email,
    String? serverTitle,
    String? userName,
    int? userId,
    String? ossBase,
    int? sort,
    int? colorIndex,
    bool? needsLogin,
    DateTime? lastSyncAt,
    DateTime? lastActiveAt,
  }) =>
      Profile(
        id: id,
        baseUrl: baseUrl,
        name: name ?? this.name,
        email: email ?? this.email,
        serverTitle: serverTitle ?? this.serverTitle,
        userName: userName ?? this.userName,
        userId: userId ?? this.userId,
        ossBase: ossBase ?? this.ossBase,
        sort: sort ?? this.sort,
        colorIndex: colorIndex ?? this.colorIndex,
        needsLogin: needsLogin ?? this.needsLogin,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        createdAt: createdAt,
        lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      );

  /// 落库用。注意 **`ossBase` 也缓存**：渲染时不该再去等 config 请求。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'baseUrl': baseUrl,
        'name': name,
        'email': email,
        'serverTitle': serverTitle,
        'userName': userName,
        'userId': userId,
        'ossBase': ossBase,
        'sort': sort,
        'colorIndex': colorIndex,
        'needsLogin': needsLogin,
        'lastSyncAt': lastSyncAt?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
        'lastActiveAt': lastActiveAt?.toIso8601String(),
      };

  factory Profile.fromJson(Map<String, dynamic> json) {
    final baseUrl = UrlUtils.normalizeApiBase(json['baseUrl']?.toString() ?? '');
    return Profile(
      id: json['id']?.toString() ?? '',
      baseUrl: baseUrl,
      name: json['name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      serverTitle: json['serverTitle']?.toString() ?? '',
      userName: json['userName']?.toString() ?? '',
      userId: _int(json['userId']),
      ossBase: _stringOr(json['ossBase'], UrlUtils.ossBase(userApi: baseUrl)),
      sort: _int(json['sort']),
      colorIndex: _int(json['colorIndex']),
      needsLogin: json['needsLogin'] == true || json['needsLogin'] == 1,
      lastSyncAt: _time(json['lastSyncAt']),
      createdAt: _time(json['createdAt']),
      lastActiveAt: _time(json['lastActiveAt']),
    );
  }

  static int _int(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse('${raw ?? ''}') ?? 0;
  }

  static String _stringOr(Object? raw, String fallback) {
    final text = raw?.toString() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static DateTime? _time(Object? raw) {
    final text = raw?.toString() ?? '';
    if (text.isEmpty) return null;
    return DateTime.tryParse(text)?.toUtc();
  }

  @override
  String toString() => 'Profile($id, $baseUrl, $email)';
}
