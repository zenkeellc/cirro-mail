/// 端点常量。路径都是**相对 API base** 的（base 已含 `/api`）。
class Endpoints {
  const Endpoints._();

  // ---- 登录 / 会话 ----
  static const String login = '/login';
  static const String logout = '/logout';

  // ---- 站点配置（免鉴权）----
  static const String websiteConfig = '/setting/websiteConfig';

  // ---- 当前用户 ----
  static const String loginUserInfo = '/my/loginUserInfo';
  static const String resetPassword = '/my/resetPassword';
  static const String deleteMyAccount = '/my/delete';

  // ---- 邮箱（accounts）----
  static const String accountList = '/account/list';
  static const String accountAdd = '/account/add';
  static const String accountDelete = '/account/delete';
  static const String accountSetName = '/account/setName';
  static const String accountSetAllReceive = '/account/setAllReceive';
  static const String accountSetAsTop = '/account/setAsTop';

  // ---- 邮件 ----
  static const String emailList = '/email/list';
  static const String emailLatest = '/email/latest';

  /// 附件单查。**注意返回里只有 `type=0` 且 `contentId` 为空的普通附件**
  /// （`attService.list` 的 where 条件），内嵌图拿不到。
  static const String emailAttList = '/email/attList';
  static const String emailRead = '/email/read';
  static const String emailDelete = '/email/delete';
  static const String emailSend = '/email/send';

  // ---- 星标 ----
  static const String starAdd = '/star/add';
  static const String starCancel = '/star/cancel';
  static const String starList = '/star/list';

  /// 附件下载路由（相对站点根，不是相对 API base）。
  static const String ossPrefix = '/api/oss/';
}
