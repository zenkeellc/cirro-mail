/// 构建期内置的「后台推送」三条值。
///
/// 谁提供：实现了 [AppExtension.pushDefaults] 的扩展（商业版把三条值编进
/// 自己的包里）。谁消费：核心的 `push_section.dart#_prefillFromBuild` ——
/// 只在输入框**为空**时补，用户手填过的值不会被盖掉。
///
/// ## 为什么要为它开一条接缝
///
/// 这三条值原本只能靠 `--dart-define-from-file` 在**打包那一刻**注入。那条路
/// 只对 CLI 打包有效：从 IDE / Xcode 直接点运行、或者忘了带参数的构建，三条值
/// 都是空的 —— 装好后用户得自己找地址、实例位、配对码，找不到就登记不上。
/// 做成扩展钩子之后，值就是**编译进包里的常量**，怎么启动都自带。
///
/// ## 为什么设备配对码可以内置、webhookSecret 不可以
///
/// 设备配对码（中转端的 `instances.device_code`）是 **App 自己的凭证**：只够
/// 登记设备、只读得到自己设备订阅过的邮箱的事件，设计上就是可公开的。
/// 能伪造 webhook 的 `webhookSecret` 权限大得多，**绝不**从这里进来（它在
/// 实例后台那一侧，由发行方保管）。
class PushDefaults {
  const PushDefaults({
    required this.relayUrl,
    required this.instanceId,
    required this.pairingCode,
  });

  /// 中转端地址，形如 `https://push.example.com`（不带尾斜杠）。
  final String relayUrl;

  /// 中转端上的实例位 id，形如 `inst-<hex>`。
  final String instanceId;

  /// 该实例位的**设备配对码**，形如 `XXXX-XXXX-XXXX-XXXX-XXXX`。
  /// 它是 `deviceCode`，**不是** `webhookSecret`。
  final String pairingCode;
}
