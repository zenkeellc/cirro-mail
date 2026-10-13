import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/mail_ref.dart';
import '../../providers/core_providers.dart';

/// 手动把**一封**邮件补齐：正文 + 附件。
///
/// 与自动队列（`SyncEngine.syncOnce`）的关系是**互补**而不是替代：自动那轮
/// 按 `createTime desc` 取最新的一批补，用户看到的最上面几行会先变实；
/// 而这个入口解决的是「我就等着这一封，它在列表第 40 行」。
///
/// 做成顶层函数（而不是某个类的方法）：它没有状态，状态在
/// `ManualSyncController` 那个 `Notifier` 里，硬凑一个类只是多一层壳。
///
/// 返回补到哪一步 —— 界面据此给一句话（「正文已补上，还有 2 个附件」）。
class ManualSyncResult {
  const ManualSyncResult({
    required this.bodyFilled,
    required this.filled,
    required this.total,
    this.skipped = false,
  });

  /// 正文这一趟有没有真的拿到东西。
  final bool bodyFilled;

  /// 附件下好了几个 / 一共几个。
  final int filled;
  final int total;

  /// 这一封**根本没被碰过**：没有可用的登录态（没 token、runtime 没了、
  /// 实例被删）。
  ///
  /// 与「试过了但一个都没补到」（`filled == 0 && total >= 0`）必须分开 ——
  /// 两者的返回值在数值上一模一样，但一句话的差别是「已经同步好了」与
  /// 「这台实例现在收不了信」。批量补拉要靠它决定**要不要继续**：没登录态
  /// 是实例级的，后面每一封都会得到同一个结论，硬跑完剩下的 199 封只是把
  /// 「一直转圈」拖得更久。
  final bool skipped;

  /// 全部附件都在本地（没有附件时也算）。
  bool get complete => filled >= total;
}

/// 把一封邮件同步到「已同步」。**幂等**，可以重复点。
///
/// 两段都做，而不是只做缺的那一段：调用方（面板的行）已经知道缺什么，
/// 但让它自己分支意味着「缺附件」的行永远补不上正文（正文那趟顺带带回的
/// 附件列表可能正是缺的那些的元数据）。两段各自的实现本来就是先查后做的
/// —— 已齐的那一段是**免费**的（`ensureFull` 看到 `hasFullBody` 直接返回，
/// `ensureLocal` 看到文件还在直接返回路径），所以「都做」不会多打网络。
Future<ManualSyncResult> syncOneMail(
  Ref ref, {
  required MailRef mail,
  void Function()? onProgress,
}) async {
  final emails = ref.read(emailRepositoryProvider);
  final attachments = ref.read(attachmentRepositoryProvider);
  final profiles = ref.read(profileRepositoryProvider);
  final runtime = ref.read(runtimeRegistryProvider);
  final dao = ref.read(databaseProvider).mailDao;

  // 2. 附件。拿的是**这一封的全部附件行**（含已下好的），`ensureLocal`
  //    对已下好的会直接返回路径、不打网络。
  final rows = await dao.attachmentsOf(mail.profileId, mail.emailId);

  // 没有可用的登录态：这一封既补不了正文也下不了附件。
  //
  // 必须在这里判：逐行同步是一条**纯 UI 的路径**，它绕过了调度器，
  // 而「没 token 就不建 engine」那道闸在 `SyncScheduler` 里 —— 这里没有。
  // 不判的话用户点一下会打出一串必然 401 的请求，然后得到一个
  // 「补好了 0 个」的、看起来像「同步没坏，只是没东西可同步」的结果。
  final live = runtime.peek(mail.profileId);
  if (live == null || live.isDisposed || !live.hasToken) {
    return ManualSyncResult(
      bodyFilled: false,
      filled: 0,
      total: rows.length,
      skipped: true,
    );
  }

  // 1. 正文。
  //
  // 包 try 是必须的：正文与附件是**两件各自独立**的事，一封信完全可能
  // 正文那一趟吃了 500（服务端对某些 `allReceive` 视图会 500），而附件
  // 照样能下。以前这里没有 try，一个异常就让整封在碰附件之前退出，
  // 表现是「点了同步，那一行纹丝不动」。
  var bodyFilled = false;
  try {
    bodyFilled = await emails.ensureFull(mail);
  } catch (_) {
    // 失败不报错：下一轮它还在待同步清单里。
  }

  final profile = await profiles.find(mail.profileId);
  if (profile == null) {
    // 实例已经没了 —— 正文那一趟能补上就补上了，附件无从谈起。
    return ManualSyncResult(
      bodyFilled: bodyFilled,
      filled: 0,
      total: rows.length,
    );
  }

  var filled = 0;
  for (final row in rows) {
    if (row.isDownloaded) {
      filled++;
      continue;
    }
    try {
      await attachments.ensureLocal(row, profileId: profile.id);
      filled++;
    } catch (_) {
      // 单个附件失败不阻断其余 —— 一个 500MB 的附件超时不该让另外两个
      // 下好的白下。失败的那几个下一轮还在清单里。
    }
    onProgress?.call();
  }

  return ManualSyncResult(
    bodyFilled: bodyFilled,
    filled: filled,
    total: rows.length,
  );
}
