import 'package:flutter/foundation.dart';

import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';

/// 一封邮件在同步流程里的位置（spec §2.5 那张表）。
enum SyncStage {
  /// 元数据 + 正文 + 附件都齐。
  synced,

  /// 此刻正在拉它（**内存态**，不在库里 —— 由 `SyncEngine.inFlight` 提供）。
  syncing,

  /// 缺正文（`hasFullBody = false`）。
  pendingBody,

  /// 正文齐了，但有附件还没下载。
  pendingAttachment;

  /// 面板默认只列没同步完的（spec §2.5）：待同步 + 正在同步。
  bool get isPending => this != SyncStage.synced;

  /// 这一行右侧按钮该显示什么。
  SyncAction actionOf({required bool inFlight}) {
    if (this == SyncStage.synced) return SyncAction.none;
    return inFlight ? SyncAction.syncing : SyncAction.sync;
  }
}

/// 行上那个按钮的形态。
enum SyncAction {
  /// 不显示按钮。
  none,

  /// 可点的「同步」。
  sync,

  /// 不可点的「同步中」（转圈）。
  syncing,
}

/// 判定一封邮件处在哪个阶段。
///
/// [attachmentTotal] / [attachmentMissing] 由调用方从 `attachments` 表数出来
/// —— **正文齐不齐与附件多少无关**：`upsertFull` 落库时就把 `attList` 一起
/// 写进了 `attachments` 表（见 `EmailRepository.backfillBodies`），所以
/// 「有附件但一条都没下」和「这封信根本没有附件」必须靠这两个数区分。
///
/// 顺序有意为之：**在飞 > 缺正文 > 缺附件 > 已同步**。
/// - 在飞压过一切：用户点了「同步这一封」之后那一刻该看到转圈，而不是
///   仍然是「待同步（缺正文）」；
/// - 缺正文压过缺附件：补正文那一趟请求顺带会把附件列表带回来，所以正文
///   优先，界面上也只说一件事。
SyncStage syncStageOf({
  required MailRow row,
  required int attachmentTotal,
  required int attachmentMissing,
  bool inFlight = false,
}) {
  if (inFlight) return SyncStage.syncing;
  // `hasFullBody` 是 bool（`MailRow` 里那一处与库里的 `int` 不同，见列定义）。
  if (!row.hasFullBody) return SyncStage.pendingBody;
  // 判的是**缺不缺**，不是「下好了几个」。写成 `attachmentTotal > missing`
  // 会把它反过来：3 个附件下好 3 个（total=3, missing=0）那种写法会说
  // 「还缺附件」。
  if (attachmentMissing > 0) return SyncStage.pendingAttachment;
  return SyncStage.synced;
}

/// 面板里的一行。
///
/// 单独一个值对象（而不是直接把 `MailRow` 递给界面）：列表要的是
/// 「这封是谁的、什么阶段、附件下到哪儿了」，而这些字段来自两张表，
/// 界面不该自己去拼。
@immutable
class SyncItem {
  const SyncItem({
    required this.row,
    required this.stage,
    required this.attachmentTotal,
    required this.attachmentMissing,
  });

  final MailRow row;
  final SyncStage stage;

  /// 这封信一共有几个附件、其中几个还没落盘。
  ///
  /// 一行摘要用：「3 个附件，还差 2 个」。
  final int attachmentTotal;
  final int attachmentMissing;

  MailRef get ref => MailRef(profileId: row.profileId, emailId: row.emailId);

  /// 附件已下全（没有附件时也算）。
  bool get attachmentsComplete => attachmentMissing == 0;

  /// 换一份附件计数，阶段跟着重算（`inFlight` 由调用方给）。
  SyncItem withCounts({
    required int total,
    required int missing,
    bool inFlight = false,
  }) =>
      SyncItem(
        row: row,
        stage: syncStageOf(
          row: row,
          attachmentTotal: total,
          attachmentMissing: missing,
          inFlight: inFlight,
        ),
        attachmentTotal: total,
        attachmentMissing: missing,
      );

  /// 只换阶段（附件计数不变）—— 面板里用来把「正在飞」标上去。
  SyncItem withStage(SyncStage stage) => SyncItem(
        row: row,
        stage: stage,
        attachmentTotal: attachmentTotal,
        attachmentMissing: attachmentMissing,
      );
}
