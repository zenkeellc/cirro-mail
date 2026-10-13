import '../../core/util/json_utils.dart';

/// `GET /setting/websiteConfig` 的响应（免鉴权）。
///
/// 字段会随实例版本增减，所以这里只挑客户端真正用到的，
/// 其余原样保留在 [raw] 里给诊断页看。
class WebsiteConfig {
  const WebsiteConfig({
    this.title = 'Cloud Mail',
    this.register = 1,
    this.send = 0,
    this.autoRefresh = 0,
    this.r2Domain,
    this.domainList = const <String>[],
    this.addEmail = 1,
    this.manyEmail = 1,
    this.siteKey,
    this.background,
    this.loginOpacity = 1.0,
    this.loginDomain = 0,
    this.minEmailPrefix = 1,
    this.notice = 1,
    this.noticeTitle,
    this.noticeContent,
    this.noticeType,
    this.addEmailVerify = 1,
    this.addVerifyOpen = false,
    this.registerVerify = 1,
    this.regKey = 1,
    this.projectLink = true,
    this.raw = const <String, dynamic>{},
  });

  /// 实例标题（登录页/侧栏用）。
  final String title;

  /// 0 = 开放注册，1 = 关闭。
  final int register;

  /// 0 = 开放发信，1 = 关闭。**注意 0 才是可用**。
  final int send;

  /// 服务端建议的自动刷新秒数；<= 1 视为「未配置」。
  /// 多数实例这里是 0，即 Web 端完全不轮询。
  final int autoRefresh;

  /// 附件/内嵌图的 CDN 前缀。线上实测为 null。
  final String? r2Domain;

  /// 可注册的域名，形如 `['@example.com', ...]`；
  /// `loginDomain == 1` 且未带 token 时服务端会返回空数组。
  final List<String> domainList;

  /// 0 = 允许添加邮箱，1 = 关闭。
  final int addEmail;

  /// 0 = 允许多邮箱，1 = 关闭。
  final int manyEmail;

  final String? siteKey;
  final String? background;
  final double loginOpacity;
  final int loginDomain;
  final int minEmailPrefix;
  final int notice;
  final String? noticeTitle;
  final String? noticeContent;
  final String? noticeType;
  final int addEmailVerify;

  /// 「本 IP 已经用完免验证的添加次数」这个**快照**。
  ///
  /// 只在 `addEmailVerify == 2`（COUNT）时有意义 —— 服务端
  /// `setting-service.js` 拿 `verifyRecordType.ADD` 的计数与 `addVerifyCount`
  /// 比出来，是个**随后会过期**的值（用户在别的设备上又加了一个就变了）。
  /// 所以 §5.5 把 `/account/add` 的返回值里那个 `addVerifyOpen` 也写回来。
  final bool addVerifyOpen;

  final int registerVerify;
  final int regKey;
  final bool projectLink;

  /// 原始 JSON，诊断页原样展示。
  final Map<String, dynamic> raw;

  factory WebsiteConfig.fromJson(Map<String, dynamic> json) {
    return WebsiteConfig(
      title: JsonUtils.string(json, 'title', 'Cloud Mail'),
      register: JsonUtils.intValue(json, 'register', 1),
      send: JsonUtils.intValue(json, 'send', 1),
      autoRefresh: JsonUtils.intValue(json, 'autoRefresh'),
      r2Domain: JsonUtils.stringOrNull(json, 'r2Domain'),
      domainList: JsonUtils.stringList(json, 'domainList'),
      addEmail: JsonUtils.intValue(json, 'addEmail', 1),
      manyEmail: JsonUtils.intValue(json, 'manyEmail', 1),
      siteKey: JsonUtils.stringOrNull(json, 'siteKey'),
      background: JsonUtils.stringOrNull(json, 'background'),
      loginOpacity:
          double.tryParse('${json['loginOpacity']}')?.clamp(0.0, 1.0) ?? 1.0,
      loginDomain: JsonUtils.intValue(json, 'loginDomain'),
      minEmailPrefix: JsonUtils.intValue(json, 'minEmailPrefix', 1),
      notice: JsonUtils.intValue(json, 'notice', 1),
      noticeTitle: JsonUtils.stringOrNull(json, 'noticeTitle'),
      noticeContent: JsonUtils.stringOrNull(json, 'noticeContent'),
      noticeType: JsonUtils.stringOrNull(json, 'noticeType'),
      addEmailVerify: JsonUtils.intValue(json, 'addEmailVerify', 1),
      // 服务端回的是 JSON bool，但不同版本/分支可能回 0/1 甚至 "1" ——
      // `JsonUtils.intValue` 三种都认（`bool` → 0/1，字符串走 tryParse）。
      addVerifyOpen: JsonUtils.intValue(json, 'addVerifyOpen') != 0,
      registerVerify: JsonUtils.intValue(json, 'registerVerify', 1),
      regKey: JsonUtils.intValue(json, 'regKey', 1),
      projectLink: json['projectLink'] != false,
      raw: json,
    );
  }

  /// 服务端 `send === 0` 表示允许发信。
  bool get sendEnabled => send == 0;

  bool get registerEnabled => register == 0;

  bool get addMailboxEnabled => addEmail == 0 && manyEmail == 0;

  /// 加邮箱时服务端会不会要 Turnstile token。
  ///
  /// 判据**逐字照抄**网页端 `mail-vue/src/layout/account/index.vue` 的 `submit()`：
  ///
  /// - `addEmailVerify == 0`（OPEN）→ 恒要；
  /// - `addEmailVerify == 1`（CLOSE）→ 不要；
  /// - `addEmailVerify == 2`（COUNT）→ 看 [addVerifyOpen] 这个 per-IP 快照。
  ///
  /// 判错的代价是不对称的：误判成「要」= 用户平白被赶去网页端（功能白做），
  /// 误判成「不要」= 用户点「添加」吃一个 `400 emptyBotToken`。App 还是接了
  /// 那个 400（§5.4 的两条错误走同一条降级告示），所以缺字段时倒向「不要」。
  bool get needsTurnstile =>
      addEmailVerify == 0 || (addEmailVerify == 2 && addVerifyOpen);

  /// 服务端是否明示了轮询间隔（> 1 秒才有意义，见 Web 端的 `autoRefresh > 1`）。
  bool get hasConfiguredAutoRefresh => autoRefresh > 1;

  /// 登录页是否可以显示域名后缀选择器。
  bool get canPickDomainOnLogin =>
      loginDomain != 1 && domainList.isNotEmpty;

  WebsiteConfig copyWith({List<String>? domainList}) => WebsiteConfig(
        title: title,
        register: register,
        send: send,
        autoRefresh: autoRefresh,
        r2Domain: r2Domain,
        domainList: domainList ?? this.domainList,
        addEmail: addEmail,
        manyEmail: manyEmail,
        siteKey: siteKey,
        background: background,
        loginOpacity: loginOpacity,
        loginDomain: loginDomain,
        minEmailPrefix: minEmailPrefix,
        notice: notice,
        noticeTitle: noticeTitle,
        noticeContent: noticeContent,
        noticeType: noticeType,
        addEmailVerify: addEmailVerify,
        addVerifyOpen: addVerifyOpen,
        registerVerify: registerVerify,
        regKey: regKey,
        projectLink: projectLink,
        raw: raw,
      );
}
