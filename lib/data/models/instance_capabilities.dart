import 'package:flutter/foundation.dart';

/// 一个实例「探测出来的能力」。
///
/// 目的：面对不同版本 / 分支的 cloud-mail 实例，缺端点或字段时**降级而不是崩**。
/// 每个 profile 一行，结果落本地库（见 `core/db` 的 `capabilities` 表）。
///
/// 探测原则：
/// - 只调**免鉴权**或**低风险**的端点，且都带最小 `size`；
/// - 把「端点不存在」与「有端点但无权限」严格分开 —— 前者要隐藏入口，
///   后者只是当前账号看不到，换个账号/换个角色就有了；
/// - `unknown` 表示还没探测（冷启动、离线），UI 按「乐观可用」处理，
///   等真正调到 403/501 再降级，避免离线时功能全灰。
@immutable
class InstanceCapabilities {
  const InstanceCapabilities({
    this.hasStar = ProbeState.unknown,
    this.hasAccountQuery = ProbeState.unknown,
    this.hasSend = ProbeState.unknown,
    this.hasLatest = ProbeState.unknown,
    this.hasFullFlag = ProbeState.unknown,
    this.hasAttListEndpoint = ProbeState.unknown,
    this.hasAutoRefresh = ProbeState.unknown,
    this.hasR2Domain = ProbeState.unknown,
    this.hasAccountAdd = ProbeState.unknown,
    this.hasAccountDelete = ProbeState.unknown,
    this.hasAccountRename = ProbeState.unknown,
    this.sendDisabledByConfig = false,
    this.registerDisabledByConfig = false,
    this.addMailboxDisabledByConfig = false,
    this.serverTitle = '',
    this.r2Domain,
    this.domainList = const <String>[],
    this.probedAt,
  });

  /// `GET /star/list` 是否可用（缺失 → 隐藏星标入口与星标按钮）。
  final ProbeState hasStar;

  /// `GET /account/list` 是否可用（403 → 邮箱管理降级为主邮箱一个）。
  final ProbeState hasAccountQuery;

  /// 是否允许发信（`websiteConfig.send == 0` **且** 有 `email:send` 权限）。
  final ProbeState hasSend;

  /// `GET /email/latest` 是否可用（缺失 → 用列表首页比对游标做增量）。
  final ProbeState hasLatest;

  /// `full=1` 是否真的返回 `content` / `attList`（缺失 → 逐封补拉或用摘要）。
  final ProbeState hasFullFlag;

  /// `GET /email/attList` 是否可用（缺失 → 附件只能从 `full=1` 的 `attList` 拿）。
  final ProbeState hasAttListEndpoint;

  /// 服务端是否给了可用的 `autoRefresh`（> 1）。**不是能力缺失**，
  /// 只是说明「轮询间隔用客户端自己的」，Web 端线上就是 0。
  final ProbeState hasAutoRefresh;

  /// `websiteConfig.r2Domain` 是否有值（决定 OSS 前缀走 CDN 还是 `/api/oss/`）。
  final ProbeState hasR2Domain;

  /// `POST /account/add` 是否可用（perm `account:add`）。**不含**站点开关 ——
  /// 那个是 [addMailboxDisabledByConfig]，两者分开是为了让提示能说实话。
  final ProbeState hasAccountAdd;

  /// `DELETE /account/delete` 是否可用（perm `account:delete`）。
  final ProbeState hasAccountDelete;

  /// `PUT /account/setName` 是否可用。
  ///
  /// **这是纯客户端约定**：服务端 `/account/setName` **不在** `requirePerms`
  /// 里（谁都能改自己的命名），这一条只是照抄网页端的
  /// `v-if="hasPerm('email:send')"`，让两个界面的动作集合一致。
  final ProbeState hasAccountRename;

  /// 站点配置里明确关掉了发信（`send == 1`）。与 [hasSend] 的 `absent` 区分开：
  /// 这是「服务端说不行」，不是「端点没有」。
  final bool sendDisabledByConfig;

  /// 站点配置里明确关掉了注册。
  final bool registerDisabledByConfig;

  /// 站点配置里明确关掉了「添加邮箱」（`addEmail == 1 || manyEmail == 1`）。
  ///
  /// 与 [hasAccountAdd] 分开的理由见 [InstanceCapabilities.hasAccountAdd]：
  /// 服务端 `accountService.add` 开头的判据就是它，与权限无关。
  final bool addMailboxDisabledByConfig;

  final String serverTitle;

  /// 原样保留，供诊断页与 [ossBase] 使用。
  final String? r2Domain;

  final List<String> domainList;

  /// 上次探测时间（UTC）。
  final DateTime? probedAt;

  /// 星标入口要不要显示。`unknown` 时按可用处理，真正拿到 501/403 再降级。
  bool get starEnabled => hasStar != ProbeState.absent;

  bool get accountQueryEnabled => hasAccountQuery != ProbeState.absent;

  /// 能不能加邮箱。**站点开关优先** —— 服务端 `add()` 开头就是
  /// `addEmail !== OPEN || manyEmail !== OPEN → addAccountDisabled`，
  /// 这时候有没有权限都没意义，提示也该说「实例关掉了」而不是「你没权限」。
  bool get accountAddEnabled =>
      !addMailboxDisabledByConfig && hasAccountAdd == ProbeState.available;

  bool get accountDeleteEnabled => hasAccountDelete == ProbeState.available;

  bool get accountRenameEnabled => hasAccountRename == ProbeState.available;

  /// 写邮件入口。任何一处说不行就不行。
  bool get sendEnabled =>
      !sendDisabledByConfig &&
      hasSend != ProbeState.absent &&
      hasSend != ProbeState.denied;

  bool get latestEnabled => hasLatest != ProbeState.absent;

  bool get fullFlagEnabled => hasFullFlag != ProbeState.absent;

  bool get attListEndpointEnabled => hasAttListEndpoint == ProbeState.available;

  /// 附件 URL 前缀是否落到 CDN（而不是 `https://<host>/api/oss/`）。
  bool get usesCdnForOss => hasR2Domain == ProbeState.available;

  InstanceCapabilities copyWith({
    ProbeState? hasStar,
    ProbeState? hasAccountQuery,
    ProbeState? hasSend,
    ProbeState? hasLatest,
    ProbeState? hasFullFlag,
    ProbeState? hasAttListEndpoint,
    ProbeState? hasAutoRefresh,
    ProbeState? hasR2Domain,
    ProbeState? hasAccountAdd,
    ProbeState? hasAccountDelete,
    ProbeState? hasAccountRename,
    bool? sendDisabledByConfig,
    bool? registerDisabledByConfig,
    bool? addMailboxDisabledByConfig,
    String? serverTitle,
    String? r2Domain,
    List<String>? domainList,
    DateTime? probedAt,
  }) =>
      InstanceCapabilities(
        hasStar: hasStar ?? this.hasStar,
        hasAccountQuery: hasAccountQuery ?? this.hasAccountQuery,
        hasSend: hasSend ?? this.hasSend,
        hasLatest: hasLatest ?? this.hasLatest,
        hasFullFlag: hasFullFlag ?? this.hasFullFlag,
        hasAttListEndpoint: hasAttListEndpoint ?? this.hasAttListEndpoint,
        hasAutoRefresh: hasAutoRefresh ?? this.hasAutoRefresh,
        hasR2Domain: hasR2Domain ?? this.hasR2Domain,
        hasAccountAdd: hasAccountAdd ?? this.hasAccountAdd,
        hasAccountDelete: hasAccountDelete ?? this.hasAccountDelete,
        hasAccountRename: hasAccountRename ?? this.hasAccountRename,
        sendDisabledByConfig: sendDisabledByConfig ?? this.sendDisabledByConfig,
        registerDisabledByConfig:
            registerDisabledByConfig ?? this.registerDisabledByConfig,
        addMailboxDisabledByConfig:
            addMailboxDisabledByConfig ?? this.addMailboxDisabledByConfig,
        serverTitle: serverTitle ?? this.serverTitle,
        r2Domain: r2Domain ?? this.r2Domain,
        domainList: domainList ?? this.domainList,
        probedAt: probedAt ?? this.probedAt,
      );

  /// 序列化到本地 `capabilities` 表。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'hasStar': hasStar.name,
        'hasAccountQuery': hasAccountQuery.name,
        'hasSend': hasSend.name,
        'hasLatest': hasLatest.name,
        'hasFullFlag': hasFullFlag.name,
        'hasAttListEndpoint': hasAttListEndpoint.name,
        'hasAutoRefresh': hasAutoRefresh.name,
        'hasR2Domain': hasR2Domain.name,
        'hasAccountAdd': hasAccountAdd.name,
        'hasAccountDelete': hasAccountDelete.name,
        'hasAccountRename': hasAccountRename.name,
        'sendDisabledByConfig': sendDisabledByConfig,
        'registerDisabledByConfig': registerDisabledByConfig,
        'addMailboxDisabledByConfig': addMailboxDisabledByConfig,
        'serverTitle': serverTitle,
        'r2Domain': r2Domain,
        'domainList': domainList,
        'probedAt': probedAt?.toIso8601String(),
      };

  factory InstanceCapabilities.fromJson(Map<String, dynamic> json) {
    final rawProbedAt = json['probedAt']?.toString();
    final rawDomains = json['domainList'];
    return InstanceCapabilities(
      hasStar: ProbeState.parse(json['hasStar']),
      hasAccountQuery: ProbeState.parse(json['hasAccountQuery']),
      hasSend: ProbeState.parse(json['hasSend']),
      hasLatest: ProbeState.parse(json['hasLatest']),
      hasFullFlag: ProbeState.parse(json['hasFullFlag']),
      hasAttListEndpoint: ProbeState.parse(json['hasAttListEndpoint']),
      hasAutoRefresh: ProbeState.parse(json['hasAutoRefresh']),
      hasR2Domain: ProbeState.parse(json['hasR2Domain']),
      // 老行没有这三个键 → `parse(null)` = unknown（乐观可用），
      // 与 `ProbeState` 的既有原则一致：重新登录或诊断页刷新即补齐。
      hasAccountAdd: ProbeState.parse(json['hasAccountAdd']),
      hasAccountDelete: ProbeState.parse(json['hasAccountDelete']),
      hasAccountRename: ProbeState.parse(json['hasAccountRename']),
      sendDisabledByConfig: json['sendDisabledByConfig'] == true ||
          json['sendDisabledByConfig'] == 1,
      registerDisabledByConfig: json['registerDisabledByConfig'] == true ||
          json['registerDisabledByConfig'] == 1,
      addMailboxDisabledByConfig:
          json['addMailboxDisabledByConfig'] == true ||
              json['addMailboxDisabledByConfig'] == 1,
      serverTitle: json['serverTitle']?.toString() ?? '',
      r2Domain: json['r2Domain']?.toString(),
      domainList: rawDomains is List
          ? rawDomains.map((e) => e.toString()).toList(growable: false)
          : const <String>[],
      probedAt: rawProbedAt == null || rawProbedAt.isEmpty
          ? null
          : DateTime.tryParse(rawProbedAt)?.toUtc(),
    );
  }

  /// 诊断页用的可读摘要。
  Map<String, String> toDiagnosticRows() => <String, String>{
        'star': hasStar.label,
        'account:query': hasAccountQuery.label,
        'account:add': addMailboxDisabledByConfig
            ? '实例已关闭'
            : hasAccountAdd.label,
        'account:delete': hasAccountDelete.label,
        'account:rename': hasAccountRename.label,
        'send': sendEnabled ? '可用' : '不可用',
        'latest': hasLatest.label,
        'full': hasFullFlag.label,
        'attList': hasAttListEndpoint.label,
        'autoRefresh': hasAutoRefresh.label,
        'r2Domain': hasR2Domain == ProbeState.available
            ? '$r2Domain'
            : '缺失（走 /api/oss/）',
      };

  @override
  String toString() => 'InstanceCapabilities(star=$hasStar, send=$sendEnabled, '
      'latest=$hasLatest, r2=$hasR2Domain)';
}

/// 单个能力的探测结果。
///
/// 把 `absent`（端点/字段不存在 → 隐藏）与 `denied`（存在但当前账号无权限 → 提示）
/// 分开，是「尽力兼容」里最容易含混的一点。
enum ProbeState {
  /// 还没探测过。UI 按「可用」处理，避免冷启动/离线时功能全灰。
  unknown,

  /// 明确可用。
  available,

  /// 端点不存在，或返回里根本没有这个字段（老版本/分支）。要隐藏入口。
  absent,

  /// 端点存在，但当前账号没权限（403）。不要隐藏，要提示「请联系管理员」。
  denied;

  bool get isAvailable => this == ProbeState.available;
  bool get isAbsent => this == ProbeState.absent;
  bool get isDenied => this == ProbeState.denied;

  String get label => switch (this) {
        ProbeState.unknown => '未探测',
        ProbeState.available => '可用',
        ProbeState.absent => '不支持',
        ProbeState.denied => '无权限',
      };

  static ProbeState parse(Object? raw) {
    if (raw is ProbeState) return raw;
    final text = raw?.toString() ?? '';
    for (final state in ProbeState.values) {
      if (state.name == text) return state;
    }
    return ProbeState.unknown;
  }

  /// 从一次探测的结果码推断。502/501 视为「端点不存在」，
  /// 403 视为「有端点但无权限」，网络错误保持 `unknown`（下次再探）。
  static ProbeState fromCode(int? code) {
    if (code == null) return ProbeState.unknown;
    if (code == 200) return ProbeState.available;
    if (code == 403) return ProbeState.denied;
    if (code == 401) return ProbeState.unknown;
    return ProbeState.absent;
  }
}
