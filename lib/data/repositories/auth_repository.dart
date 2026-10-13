import '../../core/error/app_exception.dart';
import '../../core/storage/prefs_store.dart';
import '../../core/storage/token_store.dart';
import '../../core/util/url_utils.dart';
import '../../instance/profile_runtime.dart';
import '../../instance/runtime_registry.dart';
import '../api/auth_api.dart';
import '../api/setting_api.dart';
import '../models/profile.dart';
import '../models/user_info.dart';
import '../models/website_config.dart';
import 'account_repository.dart';
import 'config_repository.dart';
import 'profile_repository.dart';

/// 登录流程的编排。
///
/// 顺序是**刻意的**，每一步都在为下一步铺路：
/// 1. `GET /setting/websiteConfig`（免鉴权）—— 先确认地址能通、拿到站点标题，
///    这一步失败说明地址填错了，不需要打扰用户输密码；
/// 2. `POST /login` → token；
/// 3. token 写进密钥库 + 内存缓存（**必须在任何带鉴权请求之前**）；
/// 4. `GET /my/loginUserInfo` —— 拿 userId / 主邮箱 / 权限；
/// 5. 回写 profile（userId、email、serverTitle、ossBase）；
/// 6. **再拉一次** `websiteConfig` —— 带 token 时 `domainList` 才有内容
///    （`loginDomain == 1` 的实例未登录时返回空数组），顺便拿到 `r2Domain`
///    算出正确的 `ossBase`。
///
/// 第 3 步的顺序最容易写错：`AuthInterceptor` 是同步读缓存的，token 没进缓存
/// 就直接发 userInfo，会稳定地拿到一个 401。
class AuthRepository {
  AuthRepository({
    required this.runtime,
    required this.tokens,
    required this.prefs,
    required this.registry,
    required this.profiles,
    required this.accounts,
    required this.configs,
    this.onLoggedIn,
  });

  final ProfileRuntime runtime;
  final TokenStore tokens;
  final PrefsStore prefs;
  final RuntimeRegistry registry;

  /// 登录成功后要回写的三张表 —— 见 [loginAndApply]。
  final ProfileRepository profiles;
  final AccountRepository accounts;
  final ConfigRepository configs;

  /// 登录落库完成后的钩子（目前用来在后台跑一轮能力探测）。
  ///
  /// 做成回调而不是直接持有 `CapabilityRepository`：探测要拿 db、要在
  /// provider 层决定「失败了也保持乐观」，那些都属于装配的事，
  /// repository 只该知道「登录成功了」这一个事实。
  final void Function(UserInfo user, WebsiteConfig config)? onLoggedIn;

  String get profileId => runtime.profileId;

  SettingApi get _setting => runtime.settingApi;
  AuthApi get _auth => runtime.authApi;

  /// 登录流程的产物。UI 只关心「成功/失败 + 落库后的 profile」。
  Future<({Profile profile, UserInfo user, WebsiteConfig config})> login({
    required String email,
    required String password,
  }) async {
    // 1. 连通性 + 站点信息（免鉴权）。
    final preConfig = await _setting.websiteConfig();

    // 2. 换 token。
    final token = await _auth.login(email: email, password: password);

    // 3. 先落 token，再发任何带鉴权的请求。
    await runtime.saveToken(token);
    registry.clearNeedsLogin(profileId);

    // 4. 身份 / 权限 / 主邮箱。
    final user = await runtime.myApi.loginUserInfo();

    // 5. 带 token 再拉一次配置（`domainList`、`r2Domain` 这时才可信）。
    //
    // `authenticated: true` 是这个第 5 步**存在的全部理由**：服务端
    // `loginDomain === 1` 时不带 token 的 `domainList` 恒为空数组
    // （`setting-service.js:209`）。此前这里没传，于是这一次「再拉一次」
    // 与第 1 步拿到的是**完全一样**的东西 —— 一句注释描述了一个没发生的事。
    var config = preConfig;
    try {
      config = await _setting.websiteConfig(authenticated: true);
    } on AppException {
      // 这一次失败不影响登录成功 —— 用免鉴权那次的结论。
    }

    final updated = runtime.profile.copyWith(
      userId: user.userId,
      email: user.email.isNotEmpty ? user.email : email,
      userName: user.primaryAccountName,
      serverTitle: config.title,
      ossBase: UrlUtils.ossBase(
        userApi: runtime.baseUrl,
        r2Domain: config.r2Domain,
      ),
      needsLogin: false,
      lastActiveAt: DateTime.now().toUtc(),
    );

    return (profile: updated, user: user, config: config);
  }

  /// 登录 + **落库**，一步到位。
  ///
  /// 为什么登录的「落库」必须和 [login] 挨在一起、而不是留给 UI 去做：
  /// 登录成功后要写的东西散在四处（profiles 行的 userId/email/ossBase、
  /// mailboxes 的主邮箱种子、config 缓存、最近活跃时间），少写一处就会
  /// 出现「登录成功但界面还是登录页」——`redirect` 只看 `Profile.isLoggedIn`，
  /// 而它取决于 `userId > 0 && !needsLogin && email != ''`。
  ///
  /// 失败时**抛异常且不留半截状态**：`login()` 内部已经把 token 写进密钥库了，
  /// 但 profile 行不会被改成「已登录」，所以用户看到的是登录页 + 一条错误，
  /// 重新输一次即可（token 会被覆盖）。
  ///
  /// 能力探测是**后台**跑的：它要打四五个端点，登录不该为它多等两三秒。
  /// 探测结果出来后 `capabilitiesProvider` 会自动让界面收敛（缺的功能隐藏）。
  Future<void> loginAndApply({
    required String email,
    required String password,
  }) async {
    final result = await login(email: email, password: password);
    final profile = result.profile;

    await profiles.markLoggedIn(
      profileId,
      userId: result.user.userId,
      email: profile.email,
      userName: result.user.primaryAccountName,
      serverTitle: result.config.title,
      ossBase: profile.ossBase,
    );

    // 缺 `account:query` 权限的实例拉不到邮箱列表，所以这里先用
    // `loginUserInfo.account` 播一个主邮箱进去 —— 聚合视图和发件人选择
    // 在探测结果回来之前就有东西可用。
    await accounts.seedPrimary(result.user, profile);
    configs.seed(profileId, result.config);
    await profiles.setActive(profileId);

    onLoggedIn?.call(result.user, result.config);
  }

  /// 退出登录。
  ///
  /// `DELETE /logout` 只移除**当前** token；即使它失败（token 早已无效、
  /// 或实例不支持这个端点），本地也必须清干净，不能把用户卡在登不出的状态。
  Future<void> logout({bool callServer = true}) async {
    if (callServer) {
      try {
        await _auth.logout();
      } on AppException {
        // 忽略：本地清理才是这一趟的目的。
      }
    }
    await runtime.clearToken();
    registry.discard(profileId);
  }

  /// 只清本地 token，不打扰服务端（例如 token 已失效的实例）。
  Future<void> forgetLocalToken() async {
    await runtime.clearToken();
    registry.discard(profileId);
  }
}
