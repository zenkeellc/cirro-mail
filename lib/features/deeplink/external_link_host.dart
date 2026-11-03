import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../router.dart';

/// 把「外部进来的 URI」接到路由器上的那一层。
///
/// 形状与 `NotificationHost` / `UpdateHost` 相同：包一层 `child` 原样返回，
/// 自己不画任何东西、不持有任何 UI 状态；只做一件事 —— 订阅每个扩展的
/// [AppExtension.externalUriStream]，收到 URI 后问扩展「这条该去哪」
/// （[AppExtension.routeForExternalUri]），拿到地址就 `GoRouter.go` 过去。
///
/// ## 为什么在这一层（`app.dart` 的 `builder` 里）
///
/// 接线点只有这里同时满足三件事：
///
/// - **要 `ref`**：跳转用的是 `routerProvider`，只有 `ProviderScope` 之内才
///   读得到。`main.dart` 在 `ProviderScope` 建起来之前就跑了，扩展的注册
///   （`AppExtensionRegistry`）更早 —— 所以接线不可能放在 `main.dart`；
/// - **要 router 已经在树里**：`MaterialApp.router` 的 `builder` 正是这棵树里
///   第一个「router 已经落地、`ProviderScope` 又在外面」的位置。`MailApp`
///   自己（`build` 里）也能读 `ref`，但那边只该管主题 / 语言 / 路由三件事
///   （见 `app.dart` 的类注释），而这条接缝只属于「外部链接」这一件事；
/// - **要活得够久**：链接不只在冷启动时来 —— App 已经在前台时，用户从浏览器
///   点链接同样会送进来一条。所以订阅必须挂在一个**常驻**的 widget 上，
///   而不是某个页面的 `initState`（页面随时会被回收）。
///
/// ## 公开版为什么一点都没变
///
/// 公开版不注册任何扩展：注册表为空 ⇒ 这里一个流都不订阅（`const
/// Stream.empty()` 连监听都只是个空操作）、一个像素都不多画。scheme 的注册、
/// URI 的解析、落地页的实现全在扩展里 —— 核心**不认识任何一个 scheme**。
///
/// ## 契约（详见 `AppExtension` 那两段文档）
///
/// - **第一个非 null 的赢**：与 [AppExtension.appDisplayName]、
///   [AppExtension.rewriteExternalResourceUrl] 同一口径，按注册顺序问；
/// - 没人认领的链接只 `debugPrint` 一行，**不弹 UI**：来路太杂，为它打断
///   用户不值；
/// - 流上的错误只 `debugPrint`：启动期一条坏链接不该把 App 打红；
/// - 订阅持续到这一层被拆掉为止（`dispose` 里逐个取消）。
class ExternalLinkHost extends ConsumerStatefulWidget {
  const ExternalLinkHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ExternalLinkHost> createState() => _ExternalLinkHostState();
}

class _ExternalLinkHostState extends ConsumerState<ExternalLinkHost> {
  final List<StreamSubscription<Uri>> _subscriptions =
      <StreamSubscription<Uri>>[];

  @override
  void initState() {
    super.initState();
    // 订阅**每一个**扩展的流，而不只是「最终认领了某个 scheme」的那一个：
    // 谁发出来的 URI 与「谁认得它」是两件独立的事（冷启动时补发的那条往往
    // 由一个包装层送来，解析却在别的扩展里）。
    for (final extension in AppExtensionRegistry.instance.extensions) {
      final subscription = _subscribe(extension);
      if (subscription != null) _subscriptions.add(subscription);
    }
  }

  /// 订一条流。失败时返回 null（不往列表里塞半个订阅）。
  ///
  /// 两处都可能出问题，都只记一行：
  /// - 建流就抛（插件没初始化、读不到 scheme 配置……）；
  /// - 流上冒错。
  ///
  /// 理由同注册表里那个逐个 try 的循环（`prepareNotificationPolicies`）：
  /// 一个扩展坏了不该拖累另一个，更不该拖累 App 启动。
  StreamSubscription<Uri>? _subscribe(AppExtension extension) {
    try {
      return extension.externalUriStream().listen(
        _open,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('扩展 ${extension.id} 的外部链接流出错：$error');
        },
      );
    } catch (error) {
      debugPrint('扩展 ${extension.id} 的外部链接流建不起来：$error');
      return null;
    }
  }

  /// 一条外部 URI 到了。
  void _open(Uri uri) {
    // 可能在这一层被拆掉之后才轮到（流是异步的）—— 那就不该再碰 ref。
    if (!mounted) return;
    final route = _routeOf(uri);
    if (route == null) {
      debugPrint('没有扩展认领这条外部链接：$uri');
      return;
    }
    // 用 `go` 而不是 `push`：外部链接送来的是一个**地址**，不是「从当前页再
    // 压一页」。用户可能正停在任意页面，返回键该回到 App 的常规层级，而不是
    // 回一条他刚点过的链接 —— 与 `search_action.dart`、通知那条同一口径。
    ref.read(routerProvider).go(route);
  }

  /// 按注册顺序问每个扩展「这条该去哪」，第一个非 null 的赢。
  String? _routeOf(Uri uri) {
    for (final extension in AppExtensionRegistry.instance.extensions) {
      final route = extension.routeForExternalUri(uri);
      if (route != null) return route;
    }
    return null;
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
