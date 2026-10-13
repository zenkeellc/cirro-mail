import '../../router.dart';

/// 「这一屏是不是钉在某个邮箱上的」—— 左侧菜单邮箱下级菜单的落点。
///
/// 判据是**两条**，缺一不可：
///
/// 1. 路径的节点是一个**实例**（`/mail/all` 不算）。聚合节点上的 `account`
///    语义本来就是模糊的（`MailListQuery` 只按 `profileId` 匹配），而且
///    `/mail/all` 是收件箱 / 未读邮件 / 已发送三个一级入口共用的路径段 ——
///    把 `account` 当标志会让它们全体沦陷。
/// 2. 查询串里**出现** [`Routes.accountParam`]。**只管在不在，值是什么无关**：
///    `0`（[kAllMailboxes]，缺 `account:query` 权限那个实例的合并项）也是一个
///    正经的落点。写出与读回成对，见 `Routes.mailOf` / `Routes.parseAccountId`。
///
/// **为什么不只看 `account` 这一个参数**：一级入口落的是 `/mail/all?…`，
/// 天然不带它；但要有这条守卫测试钉住 —— 「一级入口永不写 account」一旦被
/// 破坏，收件箱自己就会被判成下级菜单，把筛选按钮藏掉（这一轮的两件事同时坏）。
///
/// 抽成独立函数（而不是写在路由 builder 里）是为了可测：这条判断错了的表现是
/// 「筛选按钮时有时无」「侧栏高亮跑偏」，两样在界面上都看不出是判断错了。
({String profileId, int accountId})? pinnedMailboxOf(Uri uri) {
  final segments = uri.pathSegments;
  // `/mail/<实例>`（列表）或 `/mail/<实例>/<emailId>`（详情）。
  // 别的形状（`/starred`、`/settings/...`、聚合节点）一律不是。
  if (segments.length != 2 && segments.length != 3) return null;
  // `Routes.mail` 是 `'/mail'`（带前导斜杠），而 `pathSegments` 给的是
  // `'mail'` —— 直接比会永远不相等，于是**这条判据静默失效**（副作用是
  // 「钉住」永远不成立：筛选按钮一直在、下级菜单点了不变）。所以拼回带
  // 斜杠的形状再比，与 `isDetailRoute` 里的 `'/${segments.first}'` 同一写法。
  if ('/${segments.first}' != Routes.mail) return null;

  final profileId = Routes.parseProfileId(segments[1]);
  if (profileId == null) return null;

  if (!uri.queryParameters.containsKey(Routes.accountParam)) return null;
  final accountId = Routes.parseAccountId(uri.queryParameters[Routes.accountParam]);
  if (accountId == null) return null;

  return (profileId: profileId, accountId: accountId);
}

/// 地址是不是停在**某一台实例的实例级列表**上（`/mail/<实例>`，含它的详情页
/// `/mail/<实例>/<emailId>`）。命中时返回那台实例的 id。
///
/// 与 [pinnedMailboxOf] **成对且互斥**：那条认「钉在某个邮箱上」（查询串里
/// **有** `account`），这条认「就在这台实例上」（查询串里**没有** `account`）。
/// 两条判据的路径形状完全一样，唯一的差别就是最后这一条 —— 所以它们写在
/// 同一个文件里、用同一组用例镜像着测。
///
/// 为什么必须另立一条而不能让 [pinnedMailboxOf] 兼职：`/mail/<实例>` 是一个
/// **正经的落点**（侧栏的实例行点下去就是它，语义是「这台实例的所有收件箱」），
/// 而 `pinnedMailboxOf` 要求 `account` 出现，对它必然返回 null。
///
/// `null` = 不是实例级：聚合节点（`all`）、星标 / 设置 / 发件箱那几支、
/// 以及比 `/mail/<p>/<e>` 更深的路径，一律不算（边界与 [pinnedMailboxOf]
/// 和 `isDetailRoute` 保持一致）。
String? instanceNodeOf(Uri uri) {
  final segments = uri.pathSegments;
  // `/mail/<实例>`（列表）或 `/mail/<实例>/<emailId>`（详情）。
  if (segments.length != 2 && segments.length != 3) return null;
  if ('/${segments.first}' != Routes.mail) return null;

  // 聚合节点（`all`）不是实例 —— 与 `parseProfileId` 同口径。
  final profileId = Routes.parseProfileId(segments[1]);
  if (profileId == null) return null;

  // **这一段是它与 `pinnedMailboxOf` 唯一的分岔**：有 `account` 就是「钉在
  // 某个邮箱上」，归那条判据管。
  if (uri.queryParameters.containsKey(Routes.accountParam)) return null;
  return profileId;
}
