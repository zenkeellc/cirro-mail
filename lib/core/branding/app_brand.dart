import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../config/app_defaults.dart';

/// 本构建的产品名 —— 「App 自己叫什么」的唯一出处。
///
/// 两档来源，按顺序取：
///
/// 1. **扩展接缝** [AppExtension.appDisplayName] —— 商业版把它设成
///    `Cirro Mail Pro`；
/// 2. **核心默认值**：界面文字用 ARB 的 `appTitle`（[AppLocalizations.appTitle]），
///    拿不到 `BuildContext` 的场景（原生窗口标题）用
///    [AppDefaults.appDisplayName]。
///
/// 空注册表（公开版）时两条都落到 `Cirro Mail`，与从前逐字相同。
///
/// ## 为什么要有这一层，而不是每个调用点各读一次注册表
///
/// 「App 叫什么」现在出现在四处：侧栏左上角、桌面窗口标题、关于页那一行、
/// Android 通知渠道名。每个地方自己 `?? 'Cirro Mail'` 的话，接缝只覆盖到其中
/// 几个，用户会在两个屏里看到两个名字；而且默认值有两个来源（本地化 ARB 与
/// 常量），散开写必然有人选错。集中到一处之后，多一个显示位只是多调一次
/// [displayName]。
///
/// ## 为什么产品名不随语言翻译
///
/// 产品名是商标，`Cirro Mail Pro` 在中文界面里也还是 `Cirro Mail Pro`。ARB 里
/// 那条 `appTitle` 只是**公开版的默认值**：有扩展认领名字时整个让位，不是
/// 「换一种语言的翻译」。
///
/// ## 名字是整串的
///
/// 扩展给什么就原样显示什么（见 [AppExtension.appDisplayName] 的说明）——
/// 这里**不拼接**后缀、不加大写、不加分隔符。`Pro` 是 `Cirro Mail Pro`
/// 的一部分，不是可以拆出来单独挂的标签。
class AppBrand {
  const AppBrand._();

  /// 扩展接缝声明的产品名。没有扩展认领时是 null。
  static String? get extensionName =>
      AppExtensionRegistry.instance.appDisplayName;

  /// 界面文字里用的产品名（侧栏左上角、关于页）。
  ///
  /// 只在**有 `BuildContext`** 的地方用；模板层（原生窗口标题）用
  /// [windowName]。
  static String displayName(BuildContext context) =>
      extensionName ?? AppLocalizations.of(context).appTitle;

  /// 原生窗口标题里那个前缀（`WindowTitleHost` 用，拿不到本地化）。
  ///
  /// 默认值是 [AppDefaults.appDisplayName] 而不是 ARB：窗口标题由原生侧
  /// 拼装，那一层没有 `BuildContext`，也不必为一个不随语言变的商标名引
  /// 本地化。两个默认值在公开版上是同一个字符串（`Cirro Mail`）。
  static String get windowName => extensionName ?? AppDefaults.appDisplayName;
}
