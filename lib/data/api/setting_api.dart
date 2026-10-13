import '../../core/network/api_client.dart';
import '../../core/network/endpoints.dart';
import '../models/website_config.dart';

/// `GET /setting/websiteConfig`。
///
/// 三个用途：
/// 1. 「服务器设置」页的「测试连接」：能拿到这个就说明地址填对了（**免鉴权**）；
/// 2. 登录前后拿站点配置（发信开关、域名列表、r2Domain、autoRefresh）；
/// 3. 「添加邮箱」的表单要 `domainList` / `needsTurnstile` / `minEmailPrefix`。
///
/// ## 为什么有一个 [websiteConfig] 的 `authenticated` 开关
///
/// 服务端 `setting-service.js:209` 是：
///
/// ```js
/// domainList: settingRow.loginDomain === 1 && !token ? [] : settingRow.domainList
/// ```
///
/// 线上实例 `login_domain = 1`。**这个端点免鉴权，但带不带 token 拿到的
/// 结果不一样** —— 不带时 `domainList` 恒为空数组。
///
/// 本类此前写死了 `skipAuth: true`，于是「域名后缀」这个功能在 App 里
/// 从来没有可用过（规格 §1.3）。修法不是去掉 `skipAuth`（登录页那次必须
/// 免鉴权：那时候还没有 token），而是让**调用方自己说**这一次要不要带。
class SettingApi {
  const SettingApi(this._client);

  final ApiClient _client;

  /// [authenticated] 为 true 时带上当前 token（有 token 才真的带）。
  ///
  /// 默认 false = 免鉴权：登录页「测试连接」与登录流程的**第 1 步**必须用它
  /// —— 那时候 `TokenStore` 里还没有这个实例的 token。
  Future<WebsiteConfig> websiteConfig({bool authenticated = false}) async {
    final data = await _client.request<Object?>(
      Endpoints.websiteConfig,
      skipAuth: !authenticated,
    );
    if (data is Map) {
      return WebsiteConfig.fromJson(data.cast<String, dynamic>());
    }
    return const WebsiteConfig();
  }
}
