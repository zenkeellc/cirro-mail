import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'ai_transport.dart';
import 'notification_policy.dart';
import 'push_defaults.dart';
import 'push_managed.dart';
import 'settings_section.dart';
import 'theme_pack.dart';

/// 一个扩展模块（商业版、第三方插件、内部实验功能……）。
///
/// 实现方**只依赖 `cirro_mail_ext`**，不依赖核心 App。核心在启动时把实例交给
/// [AppExtensionRegistry]，之后按需调用下面这些钩子。
///
/// ## 钩子的密度是刻意的
///
/// 每多一个钩子，公开 API 的面就大一分，而稳定性要求高一档 —— 扩展模块越多，
/// 改动这个接口的代价越大。**按真实需要长，不要预先设计。**
///
/// 现有这些（连同各自对应的**那一处**核心接线）：
///
/// | 钩子 | 核心在哪用 |
/// |---|---|
/// | [routes] | `router.dart` 根部，核心路由**之后** |
/// | [mailBranchRoutes] | `router.dart` 邮件那一支的末尾（壳**里面**） |
/// | [appDisplayName] | `AppBrand`（侧栏标题 / 原生窗口标题 / 关于页 / 任务切换器 / 推送的实例名默认值） |
/// | [aboutExtras] | `about_section.dart` 的「关于」页 |
/// | [shellActions] | 宽屏侧栏标题行 / 窄屏列表页 `AppBar.actions` |
/// | [settingsSections] | `settings_screen.dart` 的分类列表 |
/// | [themes] | `app.dart`（`MaterialApp` 的 theme / darkTheme + 背板）、`appearance_section.dart`（主题画廊） |
/// | [aiUsageExtras] | `ai_section.dart`（「设置 → AI」页「用量」分组末尾） |
/// | [aiChannelCard] | `ai_section.dart`（「设置 → AI」页顶部，隐私声明之后） |
/// | [aiNoticeExtras] | `ai_stream_view.dart`（AI 失败 / 未配置提示的下方） |
/// | [aiEntryAlwaysVisible] | `compose_screen.dart` / `suggest_flow.dart`（AI 入口可见性） |
/// | [securityExtras] | `security_section.dart`（「设置 → 安全」页的正文末尾） |
/// | [aiTransport] | `ai_providers.dart`（AI 能力改走托管通道）/ `ai_section.dart`（设置页「通道」行） |
/// | [pushDefaults] | `push_section.dart#_prefillFromBuild`（「设置 → 后台推送」的预填） |
/// | [managedPushConfig] | `push_service.dart#refreshManagedConfig`（推送三条值优先从哪来） |
/// | [pushLicenseBinding] | `push_service.dart#syncAll`（`/register` 请求体里的两个 license 字段） |
/// | [onDraftChanged] | `push_service.dart`（`kind=draft_changed` 的静默推送：前台 / 后台入口 / 点开推送） |
/// | [pushSettings] | `settings_screen.dart#_pushBody`（「设置 → 后台推送」整块正文） |
/// | [autoLoadExternalResources] / [rewriteExternalResourceUrl] | `external_resource_banner.dart#_HtmlBodyViewState` / `html_body_view.dart`（读信页外联资源） |
/// | [prepareNotificationPolicy] | 前台启动钩子、后台 isolate 显式 await |
/// | [allowsNotification] | `NotificationGate.select` / `countNotifiable` |
/// | [externalUriStream] / [routeForExternalUri] | `external_link_host.dart`（App 根，`MaterialApp.router` 的 `builder` 里） |
/// | [onBootstrap] | `main.dart`，`runApp` 之前，**不 await** |
/// | [onComposeClosed] | `compose_screen.dart#_leave`（退出写信页、最后一次保存之后） |
abstract class AppExtension {
  const AppExtension();

  /// 稳定标识，用于去重与日志。约定用反向域名（`com.example.feature`）。
  String get id;

  /// 本扩展代表的**产品名**（整串，例如 `Cirro Mail Pro`）。
  ///
  /// 核心在「App 自己叫什么」的每一处先问它：侧栏左上角的标题、桌面窗口
  /// 标题、关于页那一行、任务切换器（`MaterialApp.title`）、后台推送里的
  /// 实例名默认值。返回 `null` / 空白 = 不参与
  /// 命名，回落到核心自己的默认名（ARB 的 `appTitle`、`AppDefaults.appDisplayName`）
  /// —— 空注册表（公开版）逐字不变。
  ///
  /// ## 为什么是整串，而不是「后缀」或「徽章」
  ///
  /// `Pro` 是产品名的一部分（`Cirro Mail Pro`），不是可以拆出来挂在名字
  /// 后面的独立标签。核心**不拼接**、不放大写、不加分隔符：拿到的字符串
  /// 原样显示。想要一个视觉徽章是 UI 的事，别把品牌名拆碎塞进接口 ——
  /// 那样每个调用点都得自己拼一遍，拼错一个字就是三个平台上三个不同的名字。
  ///
  /// 多个扩展都返回时，注册表按注册顺序取**第一个**（与
  /// [rewriteExternalResourceUrl] 同一口径）—— 产品名只能有一个。
  ///
  /// ## 只管 App 内的名字，管不到包名
  ///
  /// 原生侧的显示名（macOS 的 `CFBundleDisplayName`、Android 的
  /// `app_name`……）在各自的 runner 工程里，Dart 改不到 —— 那是发行方
  /// 构建配置的事，见商业版自己的说明。
  String? get appDisplayName => null;

  /// 追加进 `GoRouter` 的路由。
  ///
  /// 核心把它们**并列**加在核心路由之后，所以扩展路由不能抢占核心路径。
  /// 返回空列表即「不注册路由」。
  ///
  /// **刻意不收 `BuildContext`**：路由表是在 `routerProvider` 里一次性建好的，
  /// 那一刻还没有任何 `BuildContext`（`MaterialApp` 自己都还没建）。路由真的
  /// 需要 context 时，`builder` 的回调里会拿到，在那里用就行。
  ///
  /// **形态提醒**：这些路由是**顶层**的（与 `/compose` 同形），渲染出来没有
  /// 侧栏、没有底部导航；核心那几条一等入口都在 `StatefulShellRoute` 里面。
  /// 从扩展页面点进核心页面用 `context.go`，返回键回的是上一个**地址**。
  ///
  /// ## 想 `push` 进核心页面，就别挂在这里
  ///
  /// 顶层路由与壳里的页面**不在同一个 `Navigator`**（壳是根 Navigator 上的
  /// 一页，壳内页面挂在它自己那个 Navigator 上）。所以从这里
  /// `context.push('/mail/<节点>/<id>')` —— 往一个壳内地址压栈 —— 会让
  /// go_router 在根 Navigator 上再挂一个**同 pageKey 的状态壳**
  /// （`match.dart` 的 `RouteMatchList.push` 克隆的是传入的那一支），
  /// Navigator 的重复 pageKey 断言当场把整屏打成红框。
  ///
  /// 要「压栈进核心页面、返回键回到自己这一页」的扩展页面，挂
  /// [mailBranchRoutes]。
  List<RouteBase> routes() => const <RouteBase>[];

  /// 追加进**邮件那一支**（壳里的 branch 0）的路由，排在核心路由之后。
  ///
  /// 与 [routes] 的两点不同，正是它存在的理由：
  ///
  /// 1. 它渲染在**壳里面** —— 侧栏 / 底部导航一直在（与 `/drafts`、
  ///    `/outbox`、`/attachment-cache` 同形）。[routes] 挂在根部，是全屏的；
  /// 2. 它与 `/mail/<节点>` 共用**同一个 `Navigator`**，所以从这里
  ///    `context.push('/mail/<节点>/<id>')` 是正常的压栈：详情页有返回箭头、
  ///    系统返回键可用、返回后这一页原样还在（见 [routes] 里那段红屏的成因）。
  ///
  /// 反过来，**代价也要照单收下**，它跟核心那三个同支页面是同一份：
  ///
  /// - 进过 `indexedStack` 就不会被回收（与 `/drafts` 一样，见
  ///   `Routes.drafts` 的注释）。所以只该挂「开着不费什么」的页面，
  ///   别挂常驻查询 / 定时器 / 大列表；
  /// - 从别的分支（比如设置页）点过来时，底部导航会跟着跳到「邮件」那一项
  ///   —— 这一支现在是前台那一支。核心那三个入口本来就从主屏菜单进，
  ///   所以没有这个问题；扩展得自己想清楚「我算不算邮件这一支的」。
  ///
  /// `path` 是**根路径**（`/search` 这样带前导斜杠的绝对路径），与核心
  /// branch 内那几条的写法一致；带动态段的子路由挂在自己下面即可，
  /// 与普通的 `GoRoute` 没有区别。
  ///
  /// 挂进来的路由**不能抢占核心路径**（`/mail/...` / `/home` / `/drafts`
  /// / `/outbox` / `/attachment-cache`）—— 与 [routes] 同一条规矩。
  List<RouteBase> mailBranchRoutes() => const <RouteBase>[];

  /// 追加进「设置 → 关于」页的附加块（logo、授权标签、版本徽章……）。
  ///
  /// 核心会把这些 widget 依次铺在「App 名 + 版本号」那一行**之后**、内置的
  /// 「版本信息」「更新」「开源项目」分组**之前**，同一个 `ListView` 里 ——
  /// 它们属于「这个产品是谁」这一层，紧跟在主标识下面。**不要返回自带滚动
  /// 容器的 widget** —— 那会套出两层滚动。返回空列表即「什么都不加」。
  List<Widget> aboutExtras(BuildContext context) => const <Widget>[];

  /// 插进顶栏的那几颗图标按钮。
  ///
  /// 落点有三处，宽窄各一支：
  /// - 宽屏：侧栏标题行（[`_SidebarHeader`]）的尾部，紧挨着写邮件与同步状态
  ///   那两颗；
  /// - 窄屏：主屏（菜单网格那一页）的 `AppBar`，以及**邮件列表页**的 `AppBar`
  ///   —— 后者是绝大多数时候用户待着的地方。
  ///
  /// **只给图标按钮**：那一行的高度是固定的，塞进带文字的控件会把标题挤掉。
  /// 需要更复杂的东西就挂一条 [routes] 路由，从这里点进去。
  ///
  /// 导航由扩展自己做（`context.go(...)`）—— 核心不知道这些按钮通向哪儿。
  List<Widget> shellActions(BuildContext context) => const <Widget>[];

  /// 追加进「设置」页的**分类**。
  ///
  /// 核心把它们排在**内置分类之后**、**「安全」与「关于」之前** —— 「关于」
  /// 永远是最后一栏，「安全」是倒数第二栏（见
  /// `settings_screen.dart#SettingsCategory` 的排序说明）。载体与内置分类完全
  /// 相同（宽屏分类栏 + 右栏、窄屏分类列表 + 分类页），所以不要自己搭
  /// `Scaffold`。
  ///
  /// 文案由 [SettingsSection.title] 自带，按 `Localizations.localeOf(context)`
  /// 现选 —— 核心的 ARB 是公开仓库的资产，不会为扩展加词条。
  List<SettingsSection> settingsSections(BuildContext context) =>
      const <SettingsSection>[];

  /// 本扩展提供的可选主题（「设置 → 外观」里的主题画廊）。
  ///
  /// 核心在**两处**用它：
  /// - `app.dart`：当前选中的那套覆盖 `MaterialApp.theme` / `darkTheme`，
  ///   并把它 [ThemePack.buildBackdrop] 的背板铺在最底下；
  /// - `appearance_section.dart`：注册表非空时在「外观」页画一排主题卡片
  ///   （选中即生效，选择按 [ThemePack.id] 存进 prefs）。
  ///
  /// 返回空列表（公开版）时两处都**逐字退回原状**：仍然是核心内置的那套蓝，
  /// 外观页仍然只有「跟随系统 / 浅色 / 深色」一个下拉。这条对公开版零影响
  /// 是硬要求 —— 商业版与公开版共用同一份核心代码。
  ///
  /// 内置的默认主题没有 id，也不需要在这里出现：它是「没有选中任何扩展主题」
  /// 时的兜底。
  List<ThemePack> themes() => const <ThemePack>[];

  /// 追加进「设置 → AI」页「用量」分组末尾的块。
  ///
  /// 落点是每天上限滑杆**之后**、同一个 `ListView` 里。核心的 AI 设置
  /// 只认「调用次数」这种本地口径；托管通道（扩展自己的订阅 / 积分）要怎么
  /// 展示、点进去看什么，由扩展自己决定 —— 典型做法是返回一行
  /// 「查看订阅与用量」的 [ListTile]，导航也由扩展自己做（`context.push(...)`）。
  ///
  /// 与 [aboutExtras] 的约定相同：**不要返回自带滚动容器的 widget** —— 那会
  /// 套出两层滚动。返回空列表即「什么都不加」—— 公开版（空注册表）的 AI
  /// 设置页因此逐字不变。
  List<Widget> aiUsageExtras(BuildContext context) => const <Widget>[];

  /// 插入「设置 → AI」页顶部的**通道卡**（隐私声明之后、通道/服务商分组之前）。
  ///
  /// 存在的理由只有一条：`aiTransport == null` 时核心分不清「公开版没有这种
  /// 东西」与「商业版没开通 / 已到期 / 旧偏好选了自带 Key」—— 在核心眼里后几
  /// 种情形长得一模一样（都是自己的 AI 表单）。商业实现方于是用这张卡自己讲
  /// 通道的故事：身份（哪种通道）+ 状态（胶囊 + 一句话）+ 动作（去订阅 /
  /// 重新登录 / 切回订阅通道）。
  ///
  /// **有通道生效时不要在卡里做「AI 来源切换」**：核心页顶部已经有一组
  /// 「AI 来源」单选（通道 / 自己的 AI，立即生效），这张卡只负责「通道不存在」
  /// 那一段。
  ///
  /// 返回 `null`（公开版的默认）= 不插入，这一页逐像素不变。
  ///
  /// 与 [aboutExtras] 的约定相同：**不要返回自带滚动容器的 widget**。
  Widget? aiChannelCard(BuildContext context) => null;

  /// 追加进 AI **失败 / 未配置提示下方**的动作块。
  ///
  /// 核心的 AI 面板在出错时只显示一句 `message`（可能是实现方给的，也可能是
  /// BYOK 的「去设置里填 Key」）。商业实现方在这里补「去订阅 / 续订 / 重新
  /// 登录」这类按钮 —— 错误旁边要有一条能往下走的路，而不是让用户自己找设置。
  ///
  /// 返回空列表即「什么都不加」（公开版），失败提示的外观逐字不变。
  List<Widget> aiNoticeExtras(BuildContext context) => const <Widget>[];

  /// AI 入口是否**常驻**：即使当前既没有托管通道、也没配好 BYOK，也要画出来。
  ///
  /// 公开版（默认 `false`）沿用「没配好就不画入口」的既有口径；商业版返回
  /// `true` —— 它的规矩是「入口不藏，点下去说明原因并给自救路径」（与免打扰 /
  /// 全文搜索 / 外联代理一致）：用户得能点到一个 AI 按钮，才知道「为什么
  /// 不能用、去哪儿开」。
  bool get aiEntryAlwaysVisible => false;

  /// 追加进「设置 → 安全」页的附加块。
  ///
  /// 核心会把这些 widget 依次铺在这一页正文的**末尾**、与内置的「外联资源
  /// 白名单」同一个 `ListView` 里（白名单之后）。这一页管的是「邮件正文里能
  /// 发生什么」，所以与该主题相关、但只属于某个扩展的开关（例如商业版的
  /// 「外部资源代理」）该合到这一页，而不是在分类栏里再占一栏。
  ///
  /// 与 [aboutExtras] 的约定相同：**不要返回自带滚动容器的 widget** —— 那会
  /// 套出两层滚动。返回空列表即「什么都不加」—— 公开版（空注册表）的这一页
  /// 因此逐字不变。
  List<Widget> securityExtras(BuildContext context) => const <Widget>[];

  /// 构建期内置的「后台推送」三条值（中转地址 / 实例位 / 设备配对码）。
  ///
  /// 核心在「设置 → 后台推送」首次进页时用它预填输入框，**只在字段为空时补**
  /// —— 用户手填过的值不会被盖掉。返回 `null` 即「不提供」（公开版的既有
  /// 行为：三条值留空，由用户或 `--dart-define-from-file` 提供）。
  ///
  /// ## 为什么是扩展钩子，而不是构建参数
  ///
  /// 这份值原本只能靠 `--dart-define-from-file` 在打包那一刻注入，于是
  /// **从 IDE / Xcode 直接点运行**的调试构建是空的、忘了带参数的构建也是空的。
  /// 做成扩展之后，值就是编译进包里的常量 —— 怎么启动都自带。构建期
  /// `--dart-define` 仍然优先（临时覆盖不用改包），这里是兜底。
  ///
  /// ## 只许放设备配对码，不许放 webhookSecret
  ///
  /// 设备配对码是 App 自己的凭证（只够登记设备、只看得到自己订阅过的邮箱），
  /// 可以公开、可以编进客户端；能伪造 webhook 的 `webhookSecret` **绝不**从
  /// 这里进来（它在实例后台那一侧）。见 [PushDefaults] 的注释。
  PushDefaults? get pushDefaults => null;

  /// **托管推送配置**：中转地址 / 实例位 / 设备配对码在运行时到手，而不是
  /// 编译进包里（见 [ManagedPushConfig]）。
  ///
  /// 返回非 null 且 [ManagedPushConfig.usable] 时，核心的推送链路改用它：
  /// 三条值优先取这里，回落才是 prefs / 钥匙串里的手填值；订阅凭证随四个
  /// 请求（register / unregister / devices / events）透传。
  ///
  /// ## 拿到了也**不落盘**
  ///
  /// 核心**不会**把这三条写进 prefs / 钥匙串（落盘与否是扩展自己的事，
  /// 典型做法是把**密文**存进自己的 secret 存储）。核心只维护两样本机的值：
  /// 推送开关（`cm_push_enabled`）与设备号（`cm_push_device_id`，带实例位
  /// 前缀、需要跟着它变）。
  ///
  /// ## 只该返回**内存里已经解好的**那一份
  ///
  /// 核心在每次推送操作前问一次（30 秒节流），所以这里**不要**做网络往返：
  /// 取回 / 解密 / 续期是扩展自己的生命周期（典型在 [onBootstrap] 与登录、
  /// 续期的节点上做），这里只要把现成的那一份交出来。
  ///
  /// 返回 `null`（公开版的默认）= 没有托管配置，核心按手填值走 —— 空注册表
  /// 时推送链路与加这条接缝之前逐字相同。
  ///
  /// 多个扩展都返回非 null 时，注册表按注册顺序取**第一个**（与
  /// [aiTransport] 同一口径：一个进程里只该有一条托管配置）。
  Future<ManagedPushConfig?> managedPushConfig() async => null;

  /// 本机 Pro 订阅的**设备身份**：`(licenseId, licenseDeviceId)`。
  ///
  /// 核心在推送注册（`PushService.syncAll` → `POST /register`）时把它原样带给
  /// `mail-push`，中转端据此给这台设备打上 `license_id` —— 云草稿的跨设备事件
  /// （`kind=draft_changed`）就是按这个 license 路由的。
  ///
  /// 返回 `null`（公开版的默认，或者用户确实没登录 / 没订阅）= 不参与，注册
  /// 请求体与没有这条接缝时**逐字相同**：老中转端、开源版都不受影响。
  ///
  /// ## ⚠️ 返回 null 会**清掉**中转端既有的绑定
  ///
  /// `/register` 在中转端是 UPSERT：一次「不带 license」的登记会把这台设备
  /// 在这一行上的 `license_id` 覆盖成 null，它从此不在云草稿的事件路由里 ——
  /// 而请求本身是 200，客户端看不到任何错误。所以：
  ///
  /// - 实现**必须**在核心第一次 `syncAll` 之前就绪（典型时机是 [onBootstrap]，
  ///   或者 [managedPushConfig] 第一次给得出配置的那一刻）；
  /// - **没就绪时不要返回 `null` 去糊弄**：核心会按「装了扩展、但这一轮没有
  ///   绑定」处理，**跳过本轮登记**（保留中转端既有绑定），等下一轮再登记。
  ///   也就是说 null 只该表示「这台设备真的没有订阅」，不是「我还没读到」。
  ///
  /// ## 是 **getter**，而且只查内存
  ///
  /// **商业实现必须 override 这个 getter** —— 写成同名方法
  /// `pushLicenseBinding()` 只是个普通方法，**不会覆盖**这里，注册表读到的
  /// 永远是这个 null（于是注册请求永远不带 license，而且没有任何报错）。
  ///
  /// 核心每轮 `syncAll` 只读**一次**（见 `PushService.syncAll`），同一轮里每个
  /// 收件邮箱带的都是同一份身份 —— 典型实现在登录 / 续期时就把这两个值解好
  /// 放在内存里；这里做网络往返会把一次登记拖成 N 次往返。
  ///
  /// 多个扩展都给得出时，注册表按注册顺序取**第一个非空**（与
  /// [appDisplayName] 同一口径：设备身份只能有一个）。`licenseId` 是路由键，
  /// **空白串按「不认领」处理**（继续问下一个）；`licenseDeviceId` 允许为空。
  ({String licenseId, String licenseDeviceId})? get pushLicenseBinding => null;

  /// 收到 `kind=draft_changed` 的**静默推送**时调用。
  ///
  /// 这是「别的设备改了云草稿」的信号，服务端发的是 data-only 消息（没有
  /// `notification` 字段），核心**不会**为它构造通知事件、不会弹横幅 ——
  /// 这里只需要「拉一轮增量」，什么时候弹提示是扩展自己的事。
  ///
  /// ## 每个入口都可能走到这里，但不是同一处代码
  ///
  /// 前台 `Messaging#onMessage`、用户点开推送 `onMessageOpenedApp`、冷启动
  /// `getInitialMessage` 都收口在 `PushService._decode` 的 `kind` 分派里；
  /// **后台入口 `pushServiceBackgroundEntry` 是独立的一条** —— 它不构造
  /// `PushMailEvent`、也不经过 `_decode`，`draft_changed` 在那里就地交给这个
  /// 钩子（见该函数的注释）。后台那一侧（尤其 Android 另起的 FlutterEngine）
  /// 不会执行 `main()`，注册表得由入口自己先注册好。
  ///
  /// 所以实现必须**幂等**：同一条事件到达两次（比如 iOS 的后台唤醒 + 前台
  /// 恢复）只能安排一次拉取，不能变成两轮请求。
  ///
  /// ## 实现必须快
  ///
  /// 核心用 `unawaited` 发起它（FCM 回调不能被挂住），所以这里只该「置标志 /
  /// 丢进队列」，不要 await 网络。iOS 的静默推送可能被系统延迟或丢弃，前台
  /// 恢复时的拉取仍然是兜底真相。
  ///
  /// 单个扩展抛错不影响其它扩展（注册表逐个 await、吞异常只留日志）。
  Future<void> onDraftChanged() async {}

  /// 画「设置 → 后台推送」的**替身 UI**。
  ///
  /// 返回非 null 时核心用它替换掉自带的七页向导（[PushSection]）；返回
  /// `null`（公开版的默认）或所有扩展都返回 null 时，核心**原样构造**那套
  /// 七页向导 —— 公开版行为因此逐字不变。
  ///
  /// ## 参数
  ///
  /// - [facade]：核心对推送能力的门面（开关 / 登记 / 退订 / 检查链路）。
  ///   扩展**不要**依赖核心的 `PushService`，从这里走；
  /// - [fallback]：自带向导的构造器。扩展自己决定「这一块现在轮不到我画」
  ///   时（订阅到期、没有托管配置）调用它，把七页向导要回去 —— **别自己
  ///   搭一个简化版**，用户得有手填三条值的路可走。
  ///
  /// ## 文案里不许出现三条值
  ///
  /// 托管模式下这三条值本来就是「用户不必知道」的东西，因此**不要**在界面、
  /// 日志或 `toString` 里显示中转地址 / 实例位 / 配对码（见
  /// [ManagedPushConfig] 的注释）。要显示「在不在」就显示状态，不显示值。
  Widget? pushSettings(
    BuildContext context,
    PushFacade facade,
    Widget Function() fallback,
  ) =>
      null;

  /// AI 能力的**托管通道**（见 [AiTransport]）。
  ///
  /// 返回非 null 只说明**通道存在**，不代表它在被使用：设置 → AI 顶部会多一组
  /// 「AI 来源」（通道 / 自己的 AI），用户选 `managed` 时核心那七项 AI 能力
  /// （改写 / 成文 / 续写 / 标题 / 检查 / 回复建议 / 邮件建议）才改走这个实现
  /// —— 入参由核心翻成 [AiCall] 交过去，拿回来的是一段文本增量；选 `byok`
  /// 时走用户自己的端点与 Key，**不**经过这里。通道的可用性由
  /// [AiTransport.state] 表达。地址 / Key / 模型表单**始终可见**（用户要能
  /// 先配好自己的那套再切过去）。
  ///
  /// 返回 `null`（公开版的默认）时，AI 一切照旧走用户自己的端点与 Key，设置页
  /// 一个字都不变。**公开仓库里没有实现方** —— 开源版的行为因此逐字不变，
  /// 这正是这条接缝存在的形状：商业代码不改核心，核心只需要在若干处问一次
  /// 注册表。
  ///
  /// 多个扩展都返回非 null 时，注册表按注册顺序取**第一个** —— 一个进程里
  /// 只该有一条托管通道（与 [appDisplayName] / [rewriteExternalResourceUrl]
  /// 同一口径）。
  AiTransport? get aiTransport => null;

  /// 把通知规则的**内存快照**准备好（读一次配置，之后 [allowsNotification]
  /// 就只查内存）。
  ///
  /// 核心在两处 await 它：前台启动时（经 [onBootstrap]），以及 **Android 后台
  /// isolate 建库之后** —— 后台那个引擎不会执行 `main()`，[onBootstrap] 也跑不到，
  /// 所以那一轮的通知判定必须由核心显式地在这里准备一次。
  ///
  /// 失败**不要抛**：通知判定是尽力而为的事，读不到配置就当作「没有规则」。
  Future<void> prepareNotificationPolicy() async {}

  /// 这一封信要不要弹通知。
  ///
  /// ## 为什么是同步的
  ///
  /// 两个调用点都是同步函数（前台闸门 `NotificationGate.select`、后台计数
  /// `BackgroundSyncTask.countNotifiable`），而底层的数据源
  /// （`SharedPreferences` 的 getter）本来就是同步的。做成 async 会把调用链上
  /// 几十处测试改成异步，换不来任何东西。
  ///
  /// 所以契约是：**这里只许查内存**。要读盘先在
  /// [prepareNotificationPolicy] 里读好。
  ///
  /// ## 语义
  ///
  /// 返回 `false` = 这次不弹（**只影响通知**：邮件照常入库、照常计入未读角标、
  /// 照常出现在列表里）。核心已经做完它自己的通用判定（未读 + 收件方向），
  /// 这里只需管扩展自己的规则。多个扩展之间是 **AND** —— 任何一个说别弹，
  /// 就不弹（「静音」在用户心里的语义是「别打扰我」，让另一个扩展把它翻回来
  /// 说不过去）。
  ///
  /// 空注册表时恒为 `true`，也就是公开版的既有行为。
  bool allowsNotification(NotificationCandidate candidate) => true;

  /// 默认是否放行邮件正文里的**外联资源**（外链图片、背景图、媒体）。
  ///
  /// 核心的默认行为是**一律拦截**：外联图片可以当追踪像素用，发件人能据此
  /// 知道你什么时候、从哪里打开了邮件。扩展返回 `true` 表示「我替用户接管
  /// 这件事」—— 典型做法是配合 [rewriteExternalResourceUrl] 走隐私代理，让
  /// 资源能显示、又拿不到用户的真实 IP。
  ///
  /// 注意语义仍然是「默认放行、但用户可以在 Banner 里逐项/全部屏蔽」：核心
  /// 的 UI 会把每一项都列出来，用户按下的屏蔽优先于这个默认值。
  ///
  /// 空注册表时恒为 `false` —— 公开版保持默认拦截。
  bool get autoLoadExternalResources => false;

  /// 把外联资源地址改写成实际要加载的地址（云端代理、CDN……）。
  ///
  /// 只在**外联资源确实要加载时**调用（自家 OSS 的图不会走到这里），入参是
  /// 规范化后的绝对 URL。返回 `null` 表示不改写，按原地址加载。
  ///
  /// 多个扩展都返回非 null 时，注册表按注册顺序取**第一个**。
  String? rewriteExternalResourceUrl(String url) => null;

  // ---- 入站外部链接（自定义 scheme 深链） ----

  /// 外部进来的 URI 流（自定义 scheme 深链、「在 App 里打开」……）。
  ///
  /// 核心在 UI 起来之后把**每一个**扩展的这条流都订阅一次（`external_link_host.dart`），
  /// 收到 URI 就问 [routeForExternalUri] 「这条该去哪」，非 null 就
  /// `GoRouter.go` 过去。核心自己不认识任何 scheme —— 注册与解析全在扩展里。
  ///
  /// ## 契约
  ///
  /// - **公开版（空注册表）这条流是空的**，也就是行为逐字节不变；
  /// - 订阅只发生一次、持续到进程结束，可以返回 broadcast 流；
  /// - **冷启动那一条必须补发**：App 没在跑时被链接拉起，链接往往早于这里被
  ///   订阅（引擎在 `application:openURLs:` 那一刻就收到了）。用 `app_links`
  ///   的实现天然满足 —— `uriLinkStream` 会把 initial link 补给第一个监听者。
  ///   自己写平台通道的扩展要自己做这层缓存，别指望核心轮询。
  /// - 流上**不要**抛未捕获的错误：那是启动期，一条坏链接不该把 App 打红。
  Stream<Uri> externalUriStream() => const Stream.empty();

  /// 一条外部 URI 该落到哪个地址（`/activate-subscription?code=…` 这样带前导
  /// 斜杠的地址，参数由扩展自己编码）。
  ///
  /// 核心按注册顺序问，**第一个非 null 的赢**（与 [appDisplayName] 同一口径），
  /// 然后原样交给 `GoRouter.go` —— 所以这个地址必须在
  /// [routes] 或核心路由里真实存在，否则 go_router 会抛 `no routes for location`。
  ///
  /// 返回 `null` = 这条链接不归本扩展管（别的扩展还有机会）；所有扩展都返回
  /// null 时核心只写一行 `debugPrint`，不弹 UI —— 协议不认识的链接来路太杂，
  /// 为它打断用户不值。
  String? routeForExternalUri(Uri uri) => null;

  /// 启动时调一次。核心**不 await**：扩展的初始化不该拖慢首帧；真需要等待的
  /// 扩展自己在内部排队。
  Future<void> onBootstrap() async {}

  /// 写信页关闭（最后一次保存完成之后）调用。`draftUid` 为 null = 空信未落库。
  ///
  /// 核心**只在一处**调它：`compose_screen.dart` 的 `_leave` —— `X` 按钮、
  /// `Esc`、系统返回手势都会走那一个出口，且在那之前草稿已经落盘（或已被
  /// 判成空信删掉）。所以这里的时序保证是「页面正在关、库里的草稿行已经是
  /// 最终状态」，**不要**再自己去读一遍草稿内容，更不要 await 它把页面关掉
  /// 的过程拖长。
  ///
  /// ## 实现必须快（只标脏 / 入队）
  ///
  /// 核心用 `unawaited` 发起它，页面不会等 —— 但它毕竟跑在 UI 正在退场的
  /// 那一帧里。在这里做网络请求或长时间扫库，会跟退场动画抢同一段主线程。
  /// 正确姿势是「记下来 / 丢进队列，后台自己再慢慢同步」。
  ///
  /// `draftUid` 来自退出时那条草稿行（`Drafts.uid`，v6 起的跨设备稳定身份）。
  /// 空信（什么都没写、草稿行已被删掉、或者这一页根本没有草稿行）时为
  /// `null` —— 扩展可以据此什么都不做。
  ///
  /// 单个扩展抛错不影响其它扩展，也不会影响页面退出（注册表逐个 await 并
  /// 吞掉异常，只留一行日志）。
  Future<void> onComposeClosed({
    required String profileId,
    String? draftUid,
  }) async {}
}
