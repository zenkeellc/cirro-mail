import 'package:drift/drift.dart';

import '../database.dart';
import '../mappers.dart';
import '../tables.dart';

part 'local_dao.g.dart';

/// 发件箱 / 草稿 / 收件人历史。
///
/// 这三张表的共同点：**纯本地**，服务端没有对应实体（Web 端的草稿在浏览器
/// IndexedDB 里，App 读不到，两边不互通，UI 要说明）。
@DriftAccessor(tables: [OutboxEntries, Drafts, RecipientsHistory])
class LocalDao extends DatabaseAccessor<AppDatabase> with _$LocalDaoMixin {
  LocalDao(super.db);

  // ------------------------------------------------------------ 发件箱

  /// 入队一封待发邮件。[payloadJson] 里只放**附件路径**，不放 base64。
  ///
  /// [status] 默认 `pending`（= 下次 `flush` 时发出去）。传 `unknown` 的只有一种
  /// 情况：发送请求**超时了**，服务端可能已经收到 —— 这种条目**绝不能**自动
  /// 重发（`nextPending` 只挑 `pending`），要等用户自己确认。
  ///
  /// [attempts] 只在「这条其实已经试过一次了」时由调用方传进来。入库时就有
  /// 一个非零的尝试次数，是告诉 [resetStuckSending] 的一件事：进程若是**在
  /// 一次发送途中**被杀掉，`status` 会停在 `sending`，恢复时不能把它当成
  /// 「从没试过」退回 `pending` —— 那等于静默重发一封可能已经送达的信。
  Future<int> enqueue({
    required String profileId,
    required String payloadJson,
    String status = 'pending',
    int attempts = 0,
    DateTime? createdAt,
    DateTime? scheduledAt,
  }) =>
      into(outboxEntries).insert(
        OutboxEntriesCompanion.insert(
          profileId: profileId,
          payloadJson: payloadJson,
          status: Value(status),
          attempts: Value(attempts),
          createdAt: createdAt ?? DateTime.now().toUtc(),
          scheduledAt: Value(scheduledAt?.toUtc()),
        ),
      );

  /// 某个实例最早的一条**现在就该发**的待发（一个实例同时只发一封，串行发送）。
  ///
  /// **只挑 `pending`**。`sending` 一律不挑：那条意味着一份请求可能已经
  /// 到了服务端，而 `/email/send` 没有幂等键，再发一次就是重复投递。
  /// 上一次进程死掉留下的 `sending` 孤儿由 [resetStuckSending] 在启动时
  /// 一次性判死，交给用户决定。
  ///
  /// [now] 之后的 `scheduledAt` 会被跳过 —— 那就是「发送后还能反悔一分钟」
  /// 的实现：到点之前这封信只是本地的一行，一个字节都不会发出去。
  /// null 的 `scheduledAt` 表示立刻可发（旧数据与「确定没送达后重试入队」都是这个语义）。
  Future<DbOutboxEntry?> nextPending(String profileId, {DateTime? now}) {
    final at = now ?? DateTime.now().toUtc();
    return (select(outboxEntries)
          ..where((t) =>
              t.profileId.equals(profileId) &
              t.status.equals('pending') &
              (t.scheduledAt.isNull() | t.scheduledAt.isSmallerOrEqualValue(at)))
          ..orderBy([(t) => OrderingTerm(expression: t.id)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// 把某条的计划发送时间清掉，让它立刻可发（队列面板的「立即发出」）。
  Future<void> clearScheduledAt(int id) => (update(outboxEntries)
        ..where((t) => t.id.equals(id)))
      .write(const OutboxEntriesCompanion(scheduledAt: Value(null)));

  /// 还有多少条排在「未来」等着发（队列微标签用）。
  ///
  /// 与 [attentionCount] 的口径**刻意不同**：这里只数 `pending` + 未到点的，
  /// 回答的是「队列里排着几封」；那个数的是「发件箱里有几封要留意」，
  /// 含判死与结果不明的。两个数在界面上出现在不同地方，混用会让用户对不上账。
  Future<int> scheduledCount({DateTime? now}) async {
    final at = now ?? DateTime.now().toUtc();
    final countExp = outboxEntries.id.count();
    final query = selectOnly(outboxEntries)
      ..addColumns([countExp])
      ..where(outboxEntries.status.equals('pending') &
          outboxEntries.scheduledAt.isNotNull() &
          outboxEntries.scheduledAt.isBiggerThanValue(at));
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  /// 最近一次计划发送时间（微标签上的「N 秒后发送」）。
  Future<DateTime?> nextScheduledAt({DateTime? now}) async {
    final at = now ?? DateTime.now().toUtc();
    final minExp = outboxEntries.scheduledAt.min();
    final query = selectOnly(outboxEntries)
      ..addColumns([minExp])
      ..where(outboxEntries.status.equals('pending') &
          outboxEntries.scheduledAt.isNotNull() &
          outboxEntries.scheduledAt.isBiggerThanValue(at));
    final row = await query.getSingle();
    return row.read(minExp);
  }

  Future<DbOutboxEntry?> findById(int id) =>
      (select(outboxEntries)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<DbOutboxEntry>> allPending({String? profileId}) {
    var query = select(outboxEntries)..where((t) => t.status.equals('pending'));
    if (profileId != null) {
      query = query..where((t) => t.profileId.equals(profileId));
    }
    return (query..orderBy([(t) => OrderingTerm(expression: t.id)])).get();
  }

  /// 发件箱页面用：**所有**状态的条目，pending 在前、同状态按时间。
  ///
  /// 刻意**不筛状态**：只列 `pending` 的话，一封被判死的信（附件被清了、
  /// 服务端拒绝）会从界面上**凭空消失**，而用户明明看到过它躺在发件箱里；
  /// 超时的那类（`unknown`，可能已经送达）更不该消失。判死的条目要留在原地、
  /// 带着原因，由用户自己决定重发还是删掉。
  Stream<List<DbOutboxEntry>> watchOutbox({String? profileId}) {
    var query = select(outboxEntries);
    if (profileId != null) {
      query = query..where((t) => t.profileId.equals(profileId));
    }
    return (query
          ..orderBy([
            // 串行发送的队列顺序：正在处理的排在最前，然后是待发，最后是失败的。
            (t) => OrderingTerm(
                  expression: t.status.equals('failed'),
                ),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .watch();
  }

  /// 标记为「发送中」。这只是给 UI 用的瞬时态，进程被杀后下次启动会看到
  /// `sending` 的孤儿条目 —— 由 [resetStuckSending] 收拾。
  Future<void> markSending(int id) => (update(outboxEntries)
        ..where((t) => t.id.equals(id)))
      .write(const OutboxEntriesCompanion(status: Value('sending')));

  /// 启动时收拾上次异常退出留下的 `sending` 孤儿。
  ///
  /// 分两拨处理，因为这两种孤儿的安全做法**恰好相反**：
  ///
  /// - `attempts = 0` —— 请求多半还没发出去（在入队与首次请求之间被杀是
  ///   常事）→ 退回 `pending`，下次同步照常发出；
  /// - `attempts > 0` —— 进程是**在一次发送的途中**死的。这条请求可能已经
  ///   到达服务端，而 `/email/send` 没有幂等键，自动重发就是重复投递。
  ///   判成 `failed`，把决定权交回用户（发件箱里会带着原因显示）。
  ///
  /// 返回被处理的总条数。
  Future<int> resetStuckSending() async {
    final safe = await (update(outboxEntries)
          ..where((t) => t.status.equals('sending') & t.attempts.equals(0)))
        .write(const OutboxEntriesCompanion(status: Value('pending')));
    final risky = await (update(outboxEntries)
          ..where((t) =>
              t.status.equals('sending') & t.attempts.isBiggerThanValue(0)))
        .write(
      const OutboxEntriesCompanion(
        status: Value('failed'),
        lastError: Value('发送过程中 App 退出，是否已送达未知'),
      ),
    );
    return safe + risky;
  }

  /// 发送成功 → 删掉条目。
  ///
  /// 「发送成功」= 服务端返回了邮件行。这一条**不给重试保障**：
  /// `/email/send` 没有幂等键，超时不代表没发出去，自动重试可能重复投递，
  /// 所以超时归类为「需要用户确认」而不是静默重试（UI 在发件箱里提示）。
  Future<void> markSent(int id) =>
      (delete(outboxEntries)..where((t) => t.id.equals(id))).go();

  /// 失败 → 记一笔并递增尝试次数；[permanent] 为 true 时置成 `failed`（不再自动重试）。
  Future<void> markFailed(int id, String error, {bool permanent = false}) async {
    final row = await (select(outboxEntries)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    await (update(outboxEntries)..where((t) => t.id.equals(id)))
        .write(OutboxEntriesCompanion(
      status: Value(permanent ? 'failed' : 'pending'),
      attempts: Value(row.attempts + 1),
      lastError: Value(error),
      lastAttemptAt: Value(DateTime.now().toUtc()),
    ));
  }

  /// 只记一笔原因，**不动状态、不加尝试次数**。
  ///
  /// 给 `status = 'unknown'` 这类「状态已经定了，只是还要带上一句解释」的
  /// 条目用；[markFailed] 会顺手把状态改成 `pending`/`failed`，不适合这些场景。
  Future<void> recordLastError(int id, String error) =>
      (update(outboxEntries)..where((t) => t.id.equals(id)))
          .write(OutboxEntriesCompanion(lastError: Value(error)));

  /// 用户点「重试」：放回待发队列。
  ///
  /// 顺带清掉 `last_error` —— 上一次失败的原因留在条目上，用户看到的会是
  /// 「正在重试」旁边挂着一句已经过时的报错。重试再失败时会重新写一份。
  Future<void> requeue(int id) => (update(outboxEntries)
        ..where((t) => t.id.equals(id)))
      .write(
    const OutboxEntriesCompanion(
      status: Value('pending'),
      lastError: Value(null),
    ),
  );

  Future<void> deleteOutboxEntry(int id) =>
      (delete(outboxEntries)..where((t) => t.id.equals(id))).go();

  /// 发件箱角标：**所有还没出去的信**，不按状态筛。
  ///
  /// `pending`（会自己发出去）、`unknown`（超时，服务端可能已收到）、
  /// `failed`（判死，等用户决定）都要算进去 —— 这个数字的语义是
  /// 「发件箱里有几封信需要你留意」，只数 `pending` 会让一封超时的信
  /// 在界面上完全没有存在感。
  ///
  /// **不按实例过滤**：发件箱页面（[watchOutbox]）列的就是全部实例，
  /// 角标若只数「能用的实例」，一封属于掉线实例的信会两处对不上。
  Future<int> attentionCount() async {
    final countExp = outboxEntries.id.count();
    final query = selectOnly(outboxEntries)..addColumns([countExp]);
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  // -------------------------------------------------------------- 草稿

  Future<int> saveDraft({
    required String profileId,
    required String accountEmail,
    required String recipientsJson,
    required String subject,
    required String content,
    List<String> attachmentPaths = const <String>[],
    int? id,
  }) {
    final companion = DraftsCompanion.insert(
      profileId: profileId,
      accountEmail: Value(accountEmail),
      recipientsJson: Value(recipientsJson),
      subject: Value(subject),
      content: Value(content),
      attachmentPathsJson: Value(encodeAttachmentPaths(attachmentPaths)),
      updatedAt: DateTime.now().toUtc(),
    );
    if (id != null) {
      return (update(drafts)..where((t) => t.id.equals(id)))
          .write(companion)
          .then((_) => id);
    }
    return into(drafts).insert(companion);
  }

  Future<DbDraft?> findDraft(int id) =>
      (select(drafts)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 草稿箱页面的数据源。按最近修改排序 —— 草稿列表里「最近改的那封」
  /// 几乎总是用户想找的那封。
  Stream<List<DbDraft>> watchDrafts({String? profileId}) {
    var query = select(drafts);
    if (profileId != null) {
      query = query..where((t) => t.profileId.equals(profileId));
    }
    return (query
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.updatedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .watch();
  }

  Future<void> deleteDraft(int id) =>
      (delete(drafts)..where((t) => t.id.equals(id))).go();

  // --------------------------------------------------------- 收件人历史

  /// 记一次收件人使用。已存在则次数 +1 并刷新时间（自动补全按热度+最近排）。
  Future<void> recordRecipients(
    String profileId,
    Iterable<({String address, String name})> recipients,
  ) async {
    final now = DateTime.now().toUtc();
    for (final r in recipients) {
      final address = r.address.trim();
      if (address.isEmpty) continue;
      final existing = await (select(recipientsHistory)
            ..where((t) =>
                t.profileId.equals(profileId) & t.address.equals(address)))
          .getSingleOrNull();
      await into(recipientsHistory).insertOnConflictUpdate(
        RecipientsHistoryCompanion.insert(
          profileId: profileId,
          address: address,
          name: Value(r.name),
          usedAt: Value(now),
          useCount: Value((existing?.useCount ?? 0) + 1),
        ),
      );
    }
  }

  /// 自动补全候选：先按使用次数，再按最近使用。
  Future<List<DbRecipientHistory>> suggestRecipients(
    String profileId, {
    String query = '',
    int limit = 8,
  }) {
    var selectQuery = select(recipientsHistory)
      ..where((t) => t.profileId.equals(profileId));
    if (query.isNotEmpty) {
      selectQuery = selectQuery
        ..where((t) => t.address.like('%$query%') | t.name.like('%$query%'));
    }
    return (selectQuery
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.useCount,
                  mode: OrderingMode.desc,
                ),
            (t) => OrderingTerm(
                  expression: t.usedAt,
                  mode: OrderingMode.desc,
                ),
          ])
          ..limit(limit))
        .get();
  }

  /// 只保留每个实例最近 [keep] 条，避免历史无限增长。
  Future<void> pruneRecipients(String profileId, {int keep = 200}) async {
    final rows = await (select(recipientsHistory)
          ..where((t) => t.profileId.equals(profileId))
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.usedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .get();
    if (rows.length <= keep) return;
    final drop = rows.skip(keep).map((r) => r.address).toList(growable: false);
    await (delete(recipientsHistory)
          ..where((t) => t.profileId.equals(profileId) & t.address.isIn(drop)))
        .go();
  }

  /// 删实例时一起清（`ProfileDao.deleteProfileCascade` 也做了，这里给单测用）。
  Future<void> deleteProfileLocal(String profileId) async {
    await (delete(outboxEntries)..where((t) => t.profileId.equals(profileId)))
        .go();
    await (delete(drafts)..where((t) => t.profileId.equals(profileId))).go();
    await (delete(recipientsHistory)
          ..where((t) => t.profileId.equals(profileId)))
        .go();
  }
}
