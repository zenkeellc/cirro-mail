import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'app_extension.dart';
import 'mail_store.dart';
import 'notification_policy.dart';
import 'settings_section.dart';

/// 已注册扩展的**只读**清单。
///
/// 全局单例而不是 Riverpod provider：注册发生在 `runApp` 之前（那时
/// `ProviderScope` 还不存在），而读取发生在 UI 里 —— 让注册与读取共用同一个
/// 静态清单最直接，也不用为了「一个启动前就定好、之后不再变」的列表引一层
/// 状态管理。
///
/// 不变式：**启动完成后只读**。真要动态注册，核心需要自己重建相关页面 ——
/// 注册表不替调用方做这件事，也没有可监听的信号。
class AppExtensionRegistry {
  AppExtensionRegistry._();

  static final AppExtensionRegistry instance = AppExtensionRegistry._();

  final List<AppExtension> _extensions = <AppExtension>[];

  /// 已注册的扩展，按注册顺序。返回不可修改的快照 —— 想加就调
  /// [registerAll]，别绕过 `id` 去重。
  List<AppExtension> get extensions =>
      List<AppExtension>.unmodifiable(_extensions);

  /// 批量注册。`id` 重复的会被忽略（后面的不覆盖前面的），注册顺序即调用顺序。
  void registerAll(Iterable<AppExtension> extensions) {
    for (final ext in extensions) {
      if (_extensions.any((e) => e.id == ext.id)) continue;
      _extensions.add(ext);
    }
  }

  /// 清空。**只给测试用** —— 单例在同一个测试进程里跨用例存活，不清会串味。
  @visibleForTesting
  void reset() {
    _extensions.clear();
    _mailStore = null;
    _mailStoreReady = Completer<MailStore>();
  }

  // ---- 本地邮件读取 ----

  MailStore? _mailStore;

  /// 核心挂上来的本地邮件读取口。没有（公开版、或者核心还没挂）时是 null ——
  /// 消费方要能安静降级，别抛。
  MailStore? get mailStore => _mailStore;

  Completer<MailStore> _mailStoreReady = Completer<MailStore>();

  /// 「store 挂上来了」这个时刻。给**启动期就要用它**的扩展晒太阳。
  ///
  /// ## 为什么需要一个 Future，而不是只看 [mailStore] 是不是 null
  ///
  /// 因为两者的时序**必然错开**：扩展的启动钩子（[bootstrapAll]，由 `main()`
  /// 在 `runApp` 之前发起）跑在核心建好本地库之前 ——
  /// 库是 `bootstrap.dart` 里建的，那是一段异步流程，要等
  /// `BootstrapGate` 的第一帧才会开始。
  ///
  /// 于是「我要建索引」这种一启动就干活的扩展，在那个时刻看 [mailStore]
  /// 必然是 null。靠轮询或者 `Future.delayed` 去猜「差不多好了吧」是最难查的
  /// 一类 bug（本机跑得好好的，慢一点的机器上索引就永远没建）。
  ///
  /// **注意它可能永远不完成**：公开版没人读它；库打不开时核心也不会挂 store。
  /// 所以只该在「确实需要它」的地方 await，不要拿它当启动同步点。
  Future<MailStore> get mailStoreReady => _mailStoreReady.future;

  /// 由核心在本地库建好之后调用一次。
  ///
  /// **第二次是空操作**：`BootstrapGate` 的重试会重建整棵
  /// `ProviderScope`，同一个进程里可能走第二次；而两个 store 意味着扩展侧
  /// 起两个索引线程（同一份数据灌两遍、互相抢锁），那比「不生效」难查得多。
  void attachMailStore(MailStore store) {
    if (_mailStore != null) return;
    _mailStore = store;
    if (!_mailStoreReady.isCompleted) _mailStoreReady.complete(store);
  }

  // ---- 路由 / UI ----

  /// 所有扩展的路由，按注册顺序拼接。
  List<RouteBase> routes() => <RouteBase>[
        for (final ext in _extensions) ...ext.routes(),
      ];

  /// 所有扩展往**邮件那一支**（壳里）加的路由，按注册顺序拼接。
  ///
  /// 与 [routes] 分开两条出口是有意的：两者渲染在**不同的 Navigator** 上
  /// （见 [AppExtension.mailBranchRoutes]），核心的接线点也是两处。合成
  /// 一条的话，调用方拿到的列表里混着两种形态，而形状差异看不出来。
  List<RouteBase> mailBranchRoutes() => <RouteBase>[
        for (final ext in _extensions) ...ext.mailBranchRoutes(),
      ];

  /// 所有扩展往「关于」页加的块，按注册顺序拼接。
  List<Widget> aboutExtras(BuildContext context) => <Widget>[
        for (final ext in _extensions) ...ext.aboutExtras(context),
      ];

  /// 所有扩展往顶栏加的图标按钮，按注册顺序拼接。
  List<Widget> shellActions(BuildContext context) => <Widget>[
        for (final ext in _extensions) ...ext.shellActions(context),
      ];

  /// 所有扩展往「设置」页加的分类，按注册顺序拼接。
  ///
  /// **插在内置分类之后、「关于」之前**这条规矩由调用方
  /// （`settings_screen.dart`）落实 —— 注册表只负责按顺序拼平。
  List<SettingsSection> settingsSections(BuildContext context) => <SettingsSection>[
        for (final ext in _extensions) ...ext.settingsSections(context),
      ];

  // ---- 启动 / 通知 ----

  /// 启动钩子。逐个调用，**不等待任何一个**（见 [AppExtension.onBootstrap]）。
  void bootstrapAll() {
    for (final ext in _extensions) {
      unawaited(ext.onBootstrap());
    }
  }

  /// 逐个把扩展的通知规则读进内存。**等待**。
  ///
  /// 与 [bootstrapAll] 的「不 await」不同：这个是**判定前的就绪条件** ——
  /// 规则没读进来就开始判断，等于第一轮通知按「没有规则」放行。前台那条路
  /// 无所谓（首帧之后才可能来信），但 Android 后台 isolate 一共只活那么几秒，
  /// 必须等。
  ///
  /// 单个扩展读失败**不拖累其他扩展**：通知是尽力而为的事。
  Future<void> prepareNotificationPolicies() async {
    for (final ext in _extensions) {
      try {
        await ext.prepareNotificationPolicy();
      } catch (e) {
        debugPrint('扩展 ${ext.id} 的通知规则读取失败：$e');
      }
    }
  }

  /// 所有扩展都同意才返回 true（见 [AppExtension.allowsNotification] 的语义）。
  ///
  /// 空注册表恒为 true —— 这就是公开版的既有行为。
  bool allowsNotification(NotificationCandidate candidate) {
    for (final ext in _extensions) {
      if (!ext.allowsNotification(candidate)) return false;
    }
    return true;
  }
}
