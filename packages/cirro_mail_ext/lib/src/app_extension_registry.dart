import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'app_extension.dart';

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
  void reset() => _extensions.clear();

  /// 所有扩展的路由，按注册顺序拼接。
  List<RouteBase> routes() => <RouteBase>[
        for (final ext in _extensions) ...ext.routes(),
      ];

  /// 所有扩展往「关于」页加的块，按注册顺序拼接。
  List<Widget> aboutExtras(BuildContext context) => <Widget>[
        for (final ext in _extensions) ...ext.aboutExtras(context),
      ];

  /// 启动钩子。逐个调用，**不等待任何一个**（见 [AppExtension.onBootstrap]）。
  void bootstrapAll() {
    for (final ext in _extensions) {
      unawaited(ext.onBootstrap());
    }
  }
}
