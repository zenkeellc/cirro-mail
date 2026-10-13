/// 推送设置的七页向导：**纯逻辑**，没有 Flutter、没有网络。
///
/// 抽成单独一个文件是为了能直接单测「这一页算不算做完了」—— 那是这个
/// 向导里唯一有分支的地方。界面那一侧只负责把结果画出来。
///
/// 之所以沿用「一份有序清单 + 一组判据」而不是写七套页面脚本：七页之间
/// 是**依赖顺序**，不是七条并列的路径。多出来的只有「下一步该去哪」这
/// 一个问题，而那是个纯函数。
library;

/// 向导的七页。**顺序就是向导顺序**，遍历就用枚举自带的 `PushPage.values`。
enum PushPage {
  /// ① 现在通没通：平台 / 配置 / 登记三条状态 + 已登记邮箱。
  status,

  /// ② 中转地址、实例位、配对码三条值的填写与保存。
  ///
  /// 名字不叫 `values`：那个名字在 enum 上是**保留的**（隐式的
  /// `PushPage.values` 列表），声明同名成员会让「按顺序遍历所有页」没法写。
  threeValues,

  /// ③ 「后台推送」总开关。
  enable,

  /// ④ 把邮箱登记到这台设备上（也是系统问通知权限的地方）。
  register,

  /// ⑤ 把两条值填进**实例后台**（唯一的手工步骤）。
  instance,

  /// ⑥ 一次问清整条链路：中转通不通、配对码对不对、地址对不对、
  /// 最近有没有真的收到过信。
  check,

  /// ⑦ 四条限制、怎么关掉、以及指向仓库文档。
  limits,
}

/// 本机**查得出来**的那几件事实。
///
/// 刻意只放查得出来的：「实例后台那个开关开了没有」不在里面 —— 那只有
/// 中转端知道（它的 `last_event_at`），是 [PushService.verifyWebhook]
/// 的一次往返，而那次往返的结果由调用方折成 [instanceConfirmed] /
/// [chainEventAt] 两个值喂进来。
class PushFacts {
  const PushFacts({
    required this.available,
    required this.hasFirebaseConfig,
    required this.relayUrl,
    required this.instanceId,
    required this.hasPairingCode,
    required this.deviceIdValid,
    required this.enabled,
    required this.enrolledMailboxes,
    this.instanceConfirmed = false,
    this.chainEventAt,
  });

  /// 这个平台有没有 FCM 实现（**只有 Linux / Windows 没有**）。
  ///
  /// macOS 从 `firebase_messaging` 16.x 起就有原生实现了，所以这里返回
  /// true —— 但它还额外需要带 `com.apple.developer.aps-environment` 的
  /// entitlements 与 Mac 描述文件，缺了会在 `getToken()` 那一步失败（文案
  /// 见 `PushService` 的 `PushInitFailure.apnsUnavailable`）。这一层判断
  /// 只看「插件有没有这个平台」，查不到权利配没配。
  final bool available;

  /// 这份构建里有没有 Firebase 配置文件。
  final bool hasFirebaseConfig;

  final String relayUrl;
  final String instanceId;

  /// 配对码在密钥库里，读出来才知道有没有。
  final bool hasPairingCode;

  /// 设备号有没有带对的实例位前缀。它对不上时中转端会 401。
  final bool deviceIdValid;

  final bool enabled;

  /// 中转端记着这台设备的几个邮箱。
  final int enrolledMailboxes;

  /// 第 ⑤ 页（去实例后台开 Webhook）**由用户确认过**。
  ///
  /// 这一页 App 完全验证不了，所以判据只能是「用户说了他做了」——
  /// 但那个确认**绑定在他当时填的三条值上**（见 `TokenStore` 里那份
  /// 见证值的说明）：改了地址或配对码，这份确认就该作废，因为要重新
  /// 在实例后台填一遍。
  final bool instanceConfirmed;

  /// 第 ⑤ 页那件事的**客观证据**：中转端最近一次真的收到 webhook 的时间。
  ///
  /// 与 [instanceConfirmed] 的区别是「用户说」和「中转端记着」。
  /// 还没收到过外部来信时它必然是空 —— 那不代表没配好，所以两件事分开。
  final String? chainEventAt;

  /// 三条值齐了没有。与 `PushService.isConfigured` **同一口径** ——
  /// 同一个问题在两处各写一遍，迟早会漂。
  bool get hasThreeValues =>
      available && relayUrl.isNotEmpty && instanceId.isNotEmpty && hasPairingCode;
}

/// 第 ⑤ 页那件事「做完了没有」。
///
/// 三条路任一条走通就算：用户自己确认过、或者中转端真的收到过事件
/// （唯一一个不靠自述的证据）。返回 `null` 表示**本机查不出来**——
/// 那时页面上显示「待你自己确认」而不是一个假的红叉。
bool? instanceStepDone(PushFacts facts) {
  if (facts.instanceConfirmed) return true;
  return (facts.chainEventAt ?? '').isEmpty ? null : true;
}

/// 一页算不算做完了。
///
/// 返回 `null` 表示**本机查不出来**（那件事发生在另一个网站上），而不是
/// 「没做」——页面上据此显示「待你自己确认」而不是一个假的红叉。
///
/// [chainVerified] 只对 [PushPage.check] 有意义：它是「这一次真的问过
/// 中转端、而且问出来的结论没问题」。没问过就是 `null`。
bool? pageDone(PushPage page, PushFacts facts, {bool? chainVerified}) =>
    switch (page) {
      // 「平台支不支持」是这份构建天生的属性，用户什么都不用做；不支持时
      // 也没得确认，所以同样是「查不出来」。
      PushPage.status => facts.available ? true : null,
      // 三条值齐了**还不算数**：设备号对不上实例位时，这个配置填了也
      // 注册不上（中转端会 401），把它算成「已完成」会让人去查网络。
      PushPage.threeValues => facts.hasThreeValues && facts.deviceIdValid,
      PushPage.enable => facts.enabled,
      PushPage.register => facts.enrolledMailboxes > 0,
      // 「实例后台的那个开关拨开了没有」App 在本地无从判断。曾经这一页
      // 永远返回 null，于是它**永远显示成一个没做的步骤**——用户真的去
      // 配好了，再进来还是「待确认」。现在两条路都记：用户显式确认过，
      // 或者中转端真的收到过事件（见 [instanceStepDone]）。
      PushPage.instance => instanceStepDone(facts),
      PushPage.check => chainVerified,
      // 读一遍就算数。
      PushPage.limits => true,
    };

/// 这一页在向导里的序号（从 0 数），用于进度条。
int pageIndexOf(PushPage page) => page.index;

/// 一共几页。
int get pushPageCount => PushPage.values.length;
