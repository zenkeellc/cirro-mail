import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'notification_policy.dart';
import 'settings_section.dart';

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
/// | [aboutExtras] | `about_section.dart` 的「关于」页 |
/// | [shellActions] | 宽屏侧栏标题行 / 窄屏列表页 `AppBar.actions` |
/// | [settingsSections] | `settings_screen.dart` 的分类列表 |
/// | [prepareNotificationPolicy] | 前台启动钩子、后台 isolate 显式 await |
/// | [allowsNotification] | `NotificationGate.select` / `countNotifiable` |
/// | [onBootstrap] | `main.dart`，`runApp` 之前，**不 await** |
abstract class AppExtension {
  const AppExtension();

  /// 稳定标识，用于去重与日志。约定用反向域名（`com.example.feature`）。
  String get id;

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
  /// 核心会把这些 widget 依次追加在「App 名 + 版本号」那一行**之后**，同一个
  /// `ListView` 里。**不要返回自带滚动容器的 widget** —— 那会套出两层滚动。
  /// 返回空列表即「什么都不加」。
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
  /// 核心把它们排在**内置九栏之后**、**「关于」之前**（「关于」永远是最后一栏）。
  /// 载体与内置分类完全相同（宽屏分类栏 + 右栏、窄屏分类列表 + 分类页），
  /// 所以不要自己搭 `Scaffold`。
  ///
  /// 文案由 [SettingsSection.title] 自带，按 `Localizations.localeOf(context)`
  /// 现选 —— 核心的 ARB 是公开仓库的资产，不会为扩展加词条。
  List<SettingsSection> settingsSections(BuildContext context) =>
      const <SettingsSection>[];

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

  /// 启动时调一次。核心**不 await**：扩展的初始化不该拖慢首帧；真需要等待的
  /// 扩展自己在内部排队。
  Future<void> onBootstrap() async {}
}
