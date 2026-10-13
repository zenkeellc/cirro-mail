/// Cirro Mail 的**扩展接缝**。
///
/// 核心 App（根包 `mail_app`）只做两件事：启动时把扩展注册进
/// [AppExtensionRegistry]，然后在几个固定位置把注册表里的东西取出来用。
/// 它**不认识任何一个具体的扩展** —— 商业版与第三方模块各自实现
/// [AppExtension] 接口，核心一行都不用改。
///
/// ## 为什么这个包是独立的一个包名
///
/// Dart 里**根包不能作为自己的依赖**。如果扩展模块声明
/// `dependencies: mail_app`，而根包名恰好就是 `mail_app`、又反过来依赖这个
/// 扩展模块，pub 会以自依赖为由直接拒绝解析。把共享 API 拆成**另一个包名**
/// （这个包）之后，扩展模块只认 `cirro_mail_ext`，整条依赖链就通了。
///
/// 代价（也是纪律）：扩展模块要用到核心的能力（比如「当前选中的实例」「读一封
/// 邮件」），必须先在**这个包里**定义成接口，由核心侧实现并注册。**不许**从
/// 扩展模块反向 `import 'package:mail_app/...'` —— 那会把商业代码与公开核心
/// 焊死，也破坏「核心不依赖扩展」的方向。
library;

import 'package:flutter/widgets.dart';

export 'src/app_extension.dart' show AppExtension;
export 'src/app_extension_registry.dart' show AppExtensionRegistry;
export 'src/mail_store.dart'
    show LocalMail, MailDeleted, MailStore, MailStoreEvent, MailStoreReset, MailUpserted;
export 'src/notification_policy.dart' show NotificationCandidate;
export 'src/settings_section.dart' show SettingsSection;

/// 扩展往 UI 里插一块内容时的统一入口签名（「关于」页的附加块用它）。
///
/// 放在这里只是让使用方少 import 一个 `flutter/widgets.dart`；不 re-export
/// `go_router` —— 路由相关的类型由 [AppExtension] 的签名直接带出来。
typedef ExtensionWidgets = List<Widget> Function(BuildContext context);
