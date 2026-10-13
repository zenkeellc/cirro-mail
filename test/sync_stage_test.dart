import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/sync/sync_stage.dart';

/// 一封邮件处在哪个同步阶段。
///
/// 这一段是纯函数，而它恰好是面板上几组列表**唯一**的分组依据 ——
/// 判错了用户会看到「已同步」的名单里躺着一封正文都没拉下来的信。
///
/// 判据来自 spec §2.5 那张表：
/// - 已同步 = 元数据 + 正文（`hasFullBody`）+ 附件（`localPath`）都齐；
/// - 待同步 = 本地有这封，但正文没补拉，或附件没下载；
/// - 正在同步 = 此刻正在拉它（**内存态**，不在库里，所以由调用方传进来）。
void main() {
  MailRow row({int hasFullBody = 1, int status = 0}) => MailRow(
        profileId: 'P',
        emailId: 1,
        accountId: 1,
        mailboxEmail: 'a@example.net',
        type: 0,
        status: status,
        hasFullBody: hasFullBody == 1,
      );

  test('正文齐 + 没有附件 → 已同步', () {
    expect(
      syncStageOf(row: row(), attachmentTotal: 0, attachmentMissing: 0),
      SyncStage.synced,
    );
  });

  test('正文齐 + 附件都下好了 → 已同步', () {
    expect(
      syncStageOf(row: row(), attachmentTotal: 2, attachmentMissing: 0),
      SyncStage.synced,
    );
    // 这一条是上面那条的**反向哨兵**：判据必须是「还缺几个」而不是
    // 「一共有几个」。写成 `total > missing` 的写法在这里会给出
    // 「还缺附件」—— 一封信的附件下得越全，反而越像没下完。
    expect(
      syncStageOf(row: row(), attachmentTotal: 3, attachmentMissing: 0),
      SyncStage.synced,
    );
  });

  test('缺正文 → 待同步（即使附件都齐）', () {
    expect(
      syncStageOf(
          row: row(hasFullBody: 0), attachmentTotal: 2, attachmentMissing: 0),
      SyncStage.pendingBody,
    );
  });

  test('正文齐但附件缺 → 待同步（缺附件那一档）', () {
    expect(
      syncStageOf(row: row(), attachmentTotal: 2, attachmentMissing: 1),
      SyncStage.pendingAttachment,
    );
  });

  test('正文和附件都缺 → 先算缺正文', () {
    // 正文是大头：补完正文之后这一趟请求顺带就把附件列表带回来了，
    // 所以顺序上正文优先，界面上也只说一件事。
    expect(
      syncStageOf(
          row: row(hasFullBody: 0), attachmentTotal: 2, attachmentMissing: 2),
      SyncStage.pendingBody,
    );
  });

  test('在飞 → 正在同步（压过一切）', () {
    expect(
      syncStageOf(
        row: row(hasFullBody: 0),
        attachmentTotal: 0,
        attachmentMissing: 0,
        inFlight: true,
      ),
      SyncStage.syncing,
    );
    expect(
      syncStageOf(
        row: row(),
        attachmentTotal: 0,
        attachmentMissing: 0,
        inFlight: true,
      ),
      SyncStage.syncing,
    );
  });

  test('一封信在不在面板的默认列表里', () {
    expect(SyncStage.synced.isPending, isFalse);
    expect(SyncStage.syncing.isPending, isTrue);
    expect(SyncStage.pendingBody.isPending, isTrue);
    expect(SyncStage.pendingAttachment.isPending, isTrue);
  });

  test('按钮的文案：停着的待同步是「同步」，在飞的是「同步中」', () {
    expect(SyncStage.pendingBody.actionOf(inFlight: false), SyncAction.sync);
    expect(SyncStage.pendingBody.actionOf(inFlight: true), SyncAction.syncing);
    // 已同步的行没有可点的动作。
    expect(SyncStage.synced.actionOf(inFlight: false), SyncAction.none);
  });

  test('在飞的判定：同一封信的两次调用是一致的（按 MailRef 而不是按行）', () {
    const ref = MailRef(profileId: 'P', emailId: 1);
    expect(ref, const MailRef(profileId: 'P', emailId: 1));
    expect(ref == const MailRef(profileId: 'Q', emailId: 1), isFalse);
  });
}
