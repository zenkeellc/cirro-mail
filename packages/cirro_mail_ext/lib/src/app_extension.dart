import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// 一个扩展模块（商业版、第三方插件、内部实验功能……）。
///
/// 实现方**只依赖 `cirro_mail_ext`**，不依赖核心 App。核心在启动时把实例交给
/// [AppExtensionRegistry]，之后按需调用下面这几个钩子。
///
/// ## 钩子的密度是刻意的
///
/// 只有三个：路由、关于页附加块、启动钩子。每多一个钩子，公开 API 的面就大一分
/// 而稳定性要求高一档 —— 扩展模块越多，改动这个接口的代价越大。**按真实需要
/// 长**，不要预先设计。
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
  List<RouteBase> routes() => const <RouteBase>[];


  /// 追加进「设置 → 关于」页的附加块（logo、授权标签、版本徽章……）。
  ///
  /// 核心会把这些 widget 依次追加在「App 名 + 版本号」那一行**之后**，同一个
  /// `ListView` 里。**不要返回自带滚动容器的 widget** —— 那会套出两层滚动。
  /// 返回空列表即「什么都不加」。
  List<Widget> aboutExtras(BuildContext context) => const <Widget>[];

  /// 启动时调一次。核心**不 await**：扩展的初始化不该拖慢首帧；真需要等待的
  /// 扩展自己在内部排队。
  Future<void> onBootstrap() async {}
}
