import 'package:cirro_mail_ext/cirro_mail_ext.dart';

import '../../data/models/enums.dart';
import '../../data/models/mail_row.dart';

/// 「这一行该不该弹通知」的**唯一**判定点。
///
/// 两个调用方都从这里走：
/// - 前台闸门 `NotificationGate.select`（每一轮轮询、每一次推送触发）；
/// - 后台兜底 `BackgroundSyncTask.countNotifiable`（Android 周期任务）。
///
/// 两边以前各自抄了一份 `row.isUnread && row.type == MailType.receive`，
/// 注释里写着「刻意保持一致」。现在它们**物理上**是同一个函数 —— 扩展规则
/// 接进来之后，再让两处各写一遍就等于让「静默通知的数字」和「横幅的内容」
/// 有机会对不上，而用户是拿这两个当同一件事看的。
///
/// ## 两道判定的顺序是有意的
///
/// 先判**通用条件**（未读 + 收件方向），再问扩展。通用条件是免费的、扩展要
/// 构造 `NotificationCandidate`，而绝大多数行都过不了第一道 —— 顺序反了就是
/// 给每一行都白算一次摘要文本。
///
/// 另外：**注册表为空时直接返回，连候选都不构造**。公开版走的就是这条路，
/// 整条链路除了一次 `isUnread` 判断之外没有任何新开销。
bool isNotifiable(MailRow row) {
  // 发件方向的行也会走这条总线（「已发送」补偿轮询时会带出来），给自己发出去
  // 的信弹通知没有意义；已读的（别的设备上刚读完）也一样。
  if (!row.isUnread || row.type != MailType.receive) return false;

  final registry = AppExtensionRegistry.instance;
  if (registry.extensions.isEmpty) return true;
  return registry.allowsNotification(notificationCandidateOf(row));
}

/// `MailRow` → 扩展看得见的那个数据袋。
///
/// `hasCode` 取的是 **`code` 非空**，而不是「正文里找得到六位数字」：那个码是
/// 服务端 Workers AI 抽好、跟着摘要列一起下来的，不受本地有没有拉到完整正文
/// 影响。真去正文里找的话，「只弹验证码」这个开关在正文还没补拉的邮件上会
/// 静默失灵。
NotificationCandidate notificationCandidateOf(MailRow row) =>
    NotificationCandidate(
      profileId: row.profileId,
      emailId: row.emailId,
      accountId: row.accountId,
      type: row.type,
      unread: row.unread,
      hasCode: row.code.isNotEmpty,
      sendEmail: row.sendEmail,
      name: row.name,
      subject: row.subject,
      // `preview` 优先 `text`、没有就从 HTML 粗剥 —— 正是扩展要的那点上下文。
      bodyPreview: row.preview,
    );

/// [isNotifiable] 的形状。存在的意义是让 `NotificationGate` 能被注入一个假的
/// 判定：闸门自己的测试只关心**游标语义**（基线什么时候推进），不该被「当前
/// 进程里恰好注册了哪些扩展」影响。
typedef NotifiablePredicate = bool Function(MailRow row);
