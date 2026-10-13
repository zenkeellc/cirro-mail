import 'package:cirro_mail_ext/cirro_mail_ext.dart';

/// 本构建注册的扩展。
///
/// ## 为什么单独放一个文件，而不是写在 `main()` 里
///
/// 因为**后台 isolate 不会执行 `main()`**。Android 的兜底轮询跑在
/// `workmanager` 自己起的那个 Flutter 引擎里（它自建 `FlutterEngine` 再
/// `executeDartCallback`，见 `background_sync_task.dart`），那里收不到
/// `main()` 里注册的任何东西。
///
/// 而那个 isolate 也需要看到扩展 —— 免打扰规则要在后台那一轮通知里生效，否则
/// 「静音了这个发件人，结果 App 退到后台它又弹了」。
///
/// 把它做成**顶层 const** 就等于给两个入口提供了同一个事实来源：
/// `main()` 读它、后台入口也读它。副作用是 `main.dart` 两个检出**逐字节相同** ——
/// 以后公开版与商业版合并时，`main.dart` 永远不会冲突。
///
/// ## 这是公开版与商业版唯一允许不同的核心文件
///
/// 商业版把这一行换成 `const <AppExtension>[CirroMailPro()]`（外加
/// `pubspec.yaml` 里那条 path 依赖）。`main.dart` 不动。
///
/// `const` 是硬要求：它必须能在没有任何初始化逻辑的情况下被读到 ——
/// 后台 isolate 起来时是「先读这个常量、再建库」，中间没有可以做初始化
/// 的地方。
const List<AppExtension> kAppExtensions = <AppExtension>[];
