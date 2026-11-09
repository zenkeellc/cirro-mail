import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../mappers.dart';
import '../tables.dart';

part 'local_dao.g.dart';

/// 发件箱 / 草稿 / 收件人历史。
///
/// 这三张表的共同点：**纯本地**，服务端没有对应实体（Web 端的草稿在浏览器
/// IndexedDB 里，App 读不到，两边不互通，UI 要说明）。
///
/// 例外是 v6 起的草稿身份：`drafts.uid` / `drafts.rev` 与
/// [DraftTombstones] 是给云端同步准备的本机锚点（云端实体在服务端，
/// 这里只负责「换设备还认得同一份草稿」）。
@DriftAccessor(
  tables: [
    OutboxEntries, Drafts, DraftTombstones, ComposePages, RecipientsHistory,
  ],
)
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

  /// 本机生成草稿 `uid`。UUIDv4，全局唯一，写入后**永不变**（换设备认同一份
  /// 草稿靠的就是它，见 [Drafts.uid]）。
  static const Uuid _uuid = Uuid();

  /// 落一条草稿。`id == null` 是新建，否则在原行上更新。
  ///
  /// v6 起每次落库都要维护 `rev`：新建是 1，更新是「当前 rev + 1」。
  /// **读-改-写在一个事务里**：`rev` 是云端 CAS 的依据，跳号或倒退都会让
  /// 同步层把新版本当成旧版本。更新路径上如果行已经不在了（发出去的瞬间
  /// 迟到的保存），照旧写 0 行、返回 `id`，**绝不 INSERT 复活**。
  Future<int> saveDraft({
    required String profileId,
    required String accountEmail,
    required String recipientsJson,
    required String subject,
    required String content,
    List<String> attachmentPaths = const <String>[],
    int? id,
  }) {
    // 这里**不预先 mint uid**：新建分支在 insert 前才生成，更新分支用原行的
    // uid（只有迁移没回填的空行才补一个）。先 mint 再覆盖的写法看上去等价，
    // 但「uid 永不变」就成了「靠后面那行 copyWith 兜住」，任何提前 return
    // 都可能把新身份写进老行。
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
      return transaction(() async {
        final current =
            await (select(drafts)..where((t) => t.id.equals(id)))
                .getSingleOrNull();
        // 行不在了：仍然走 UPDATE（写 0 行），保持「迟到保存不复活」的语义。
        final rev = (current?.rev ?? 0) + 1;
        // uid 为空只可能是迁移没回填的脏行：顺手补一个（否则这一行永远
        // 进不了同步），正常路径永远是「原样写回」。
        final uid = (current == null || current.uid.isEmpty)
            ? _uuid.v4()
            : current.uid;
        await (update(drafts)..where((t) => t.id.equals(id))).write(
          companion.copyWith(uid: Value(uid), rev: Value(rev)),
        );
        return id;
      });
    }
    return into(drafts).insert(
      companion.copyWith(uid: Value(_uuid.v4()), rev: const Value(1)),
    );
  }

  Future<DbDraft?> findDraft(int id) =>
      (select(drafts)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 按跨设备身份找草稿（同步层用）。[uid] 全局唯一，仍带 `profileId` 是
  /// 为了**防御性收窄**：冲突副本/远端应用都只会落在同一个实例里。
  ///
  /// 空 `uid` 直接当找不到：空串是「迁移还没回填」的脏行，不是任何一份
  /// 草稿的身份。放它进去匹配，调用方会拿空串命中任意一条脏行（唯一索引
  /// 的部分谓词 `WHERE uid != ''` 也放过多条空串）。
  Future<DbDraft?> findDraftByUid(String profileId, String uid) async {
    if (uid.isEmpty) return null;
    return (select(drafts)
          ..where((t) => t.profileId.equals(profileId) & t.uid.equals(uid)))
        .getSingleOrNull();
  }

  /// 全部草稿，**跨实例**，按最近修改倒序。
  ///
  /// 供同步层首轮全量推送用（`listAll()`）：这里不按 `profileId` 过滤，
  /// 因为一次推送要覆盖所有已登录实例。同毫秒时用自增 `id` 兜底，保证
  /// 两次查询顺序稳定。
  ///
  /// **跳过空 `uid` 的脏行**：那是「迁移还没回填」的历史行，云端认不出它
  /// 们，推上去只会变成一堆无法区分的草稿。它们留在本地，等下一次
  /// `saveDraft` / 回填补上身份。
  Future<List<DbDraft>> listAllDrafts() => (select(drafts)
        ..where((t) => t.uid.isNotValue(''))
        ..orderBy([
          (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
          (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
        ]))
      .get();

  /// 新建一条「正在编辑」的草稿（撰写页的空白底稿）。
  ///
  /// **一个事务写两张表**：草稿行 + 打开标记。分开写的话，崩在中间会留下一条
  /// 只出现在草稿箱、却永远进不了「邮件撰写」的半行。
  ///
  /// 空行是刻意先插的：左侧「邮件撰写」要在用户点「写邮件」的**那一刻**就出现
  /// 这一页（否则新页面在列表里不存在，切走就再也回不去），同时它的
  /// `updated_at` 就是「新邮件在最前」的排序依据。用户什么都没写就关掉时由
  /// `deleteDraft` 把这一行连同标记一起删掉 —— 空信不进草稿箱那条规矩不破。
  Future<int> createComposeDraft({
    required String profileId,
    String accountEmail = '',
    String recipientsJson = '',
    String subject = '',
    String content = '',
    List<String> attachmentPaths = const <String>[],
  }) {
    final now = DateTime.now().toUtc();
    return transaction(() async {
      final id = await into(drafts).insert(
        DraftsCompanion.insert(
          profileId: profileId,
          // 与 `saveDraft` 同一套身份规则：新行一定要有 uid、rev 从 1 起。
          uid: Value(_uuid.v4()),
          rev: const Value(1),
          accountEmail: Value(accountEmail),
          recipientsJson: Value(recipientsJson),
          subject: Value(subject),
          content: Value(content),
          attachmentPathsJson: Value(encodeAttachmentPaths(attachmentPaths)),
          updatedAt: now,
        ),
      );
      await into(composePages).insert(
        ComposePagesCompanion.insert(draftId: Value(id), openedAt: now),
      );
      return id;
    });
  }

  /// 把一条草稿标记成「打开中」。
  ///
  /// 幂等：从草稿箱反复点开同一封、或深链进来两次，都不该炸主键。
  /// `insertOnConflictUpdate` 顺手刷新 `opened_at`。
  Future<void> markComposeOpen(int draftId) =>
      into(composePages).insertOnConflictUpdate(
        ComposePagesCompanion.insert(
          draftId: Value(draftId),
          openedAt: DateTime.now().toUtc(),
        ),
      );

  /// 取消「打开中」标记：页从左侧「邮件撰写」消失，草稿内容仍在草稿箱里。
  Future<void> closeComposePage(int draftId) =>
      (delete(composePages)..where((t) => t.draftId.equals(draftId))).go();

  /// 左侧「邮件撰写」的数据源：**打开中**的草稿，按最后编辑时间倒序。
  ///
  /// 排序就是需求：最后编辑的在上、新邮件在最前。`drafts.id` 那一级是同毫秒
  /// 时的稳定兜底（自增 id 越大越新）—— 少了它，两条同一毫秒写进来的草稿
  /// 在两次查询里顺序可能互换，侧栏会闪一下。
  Stream<List<DbDraft>> watchOpenDrafts({String? profileId}) {
    final query = select(drafts).join(<Join<HasResultSet, dynamic>>[
      innerJoin(composePages, composePages.draftId.equalsExp(drafts.id)),
    ]);
    if (profileId != null) {
      query.where(drafts.profileId.equals(profileId));
    }
    query.orderBy(<OrderingTerm>[
      OrderingTerm(expression: drafts.updatedAt, mode: OrderingMode.desc),
      OrderingTerm(expression: drafts.id, mode: OrderingMode.desc),
    ]);
    return query.watch().map(
          (rows) => <DbDraft>[
            for (final row in rows) row.readTable(drafts),
          ],
        );
  }

  /// 打开中的草稿 id 集合（草稿箱页给行加「编辑中」标记用）。
  Stream<Set<int>> watchOpenDraftIds() => watchOpenDrafts().map(
        (drafts) => <int>{for (final draft in drafts) draft.id},
      );

  /// 保存器的**按列增量更新**：null = 这一列没变。
  ///
  /// 为什么不是整行重写：正文 Delta 里可能内联着数 MB 的 base64 图片，
  /// 用户只改了个主题却把 content 整列重写一遍，就是纯写放大。
  ///
  /// **只 UPDATE、绝不 INSERT**：行已经被删掉（发送成功 / 放弃 / 关闭空页）时
  /// 这一步会写到 0 行 —— 这正是「迟到的防抖保存绝不能复活已删草稿」的实现，
  /// 不靠任何内存里的标记，也不怕进程换个 isolate。
  ///
  /// v6：除了改列，`rev` 也要 +1（这也是「内容变过」的唯一可靠计数 ——
  /// 保存器只写变了的列，没写的列不代表内容没变）。为了不出现「读了旧 rev
  /// 又覆盖回去」，读-改-写放在同一个事务里；行不在就提前返回 0，保持
  /// 上面的 UPDATE-only 语义。
  ///
  /// 返回值是影响行数，调用方据此判定「行已不在」。
  Future<int> updateDraftFields(
    int id, {
    String? accountEmail,
    String? recipientsJson,
    String? subject,
    String? content,
    List<String>? attachmentPaths,
  }) {
    final companion = DraftsCompanion(
      accountEmail:
          accountEmail == null ? const Value.absent() : Value(accountEmail),
      recipientsJson: recipientsJson == null
          ? const Value.absent()
          : Value(recipientsJson),
      subject: subject == null ? const Value.absent() : Value(subject),
      content: content == null ? const Value.absent() : Value(content),
      attachmentPathsJson: attachmentPaths == null
          ? const Value.absent()
          : Value(encodeAttachmentPaths(attachmentPaths)),
      updatedAt: Value(DateTime.now().toUtc()),
    );
    return transaction(() async {
      final current = await (select(drafts)..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (current == null) return 0;
      return (update(drafts)..where((t) => t.id.equals(id)))
          .write(companion.copyWith(rev: Value(current.rev + 1)));
    });
  }

  /// 启动清理：删掉指向**已经不存在的草稿**的「打开中」标记。
  ///
  /// 正常路径不会留下孤儿（`deleteDraft` 在同一个事务里删标记），但进程可能
  /// 在「草稿已删、标记还没删」之间被杀掉 —— 启动时兜一次，成本是一条
  /// 单表 DELETE，不碰数据行。
  Future<void> pruneComposePages() => customStatement(
        'DELETE FROM compose_pages '
        'WHERE draft_id NOT IN (SELECT id FROM drafts)',
      );

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

  /// 删草稿：**连同它的「打开中」标记一起删**，一个事务；并在同一个事务里
  /// 落一条墓碑 [DraftTombstones]。
  ///
  /// 这个方法是草稿本地删除的**唯一**入口（发送成功、放弃草稿、草稿箱删除都
  /// 走它）—— 在这里收口，就不会在某条路径上漏删标记、留下一条永远点不开的
  /// 侧栏行；也不会漏写墓碑、让同步层把「本机删了」当成「还没见过」。
  ///
  /// 墓碑的 `rev = 草稿删除前的 rev + 1`（删除本身是一次内容变更）；同一个
  /// `(profileId, uid)` 已有墓碑时取**两者中较大的 rev** —— 删除 → 远端/冲突
  /// 副本把同一 uid 写回来 → 再删，第二次可能是基于一个更旧的副本（rev 更小）。
  /// 墓碑是「云端该删到哪一版」的账本，只前进不后退，否则会把云端已经见过
  /// 的高版本墓碑降级成一个旧的删除。
  ///
  /// 返回值给同步层发云端墓碑用；**调用方忽略返回值不影响**本地行为，所以
  /// UI 那几处 `await dao.deleteDraft(id)` 不用改。
  ///
  /// 行不存在返回 null（幂等：重复删除、或行已被发送链路删掉）。
  Future<DbDraftTombstone?> deleteDraft(int id) => transaction(() async {
        final row =
            await (select(drafts)..where((t) => t.id.equals(id)))
                .getSingleOrNull();
        await (delete(composePages)..where((t) => t.draftId.equals(id))).go();
        if (row == null) return null;
        // 只给「有身份」的草稿写墓碑：uid 为空的是迁移没回填的脏行，
        // 拿空串写墓碑会让同一个 profile 的所有空 uid 草稿共用一条墓碑
        // （主键是 profileId + uid）。
        if (row.uid.isEmpty) {
          await (delete(drafts)..where((t) => t.id.equals(id))).go();
          return null;
        }
        final existing = await (select(draftTombstones)
              ..where((t) =>
                  t.profileId.equals(row.profileId) & t.uid.equals(row.uid)))
            .getSingleOrNull();
        final nextRev = row.rev + 1;
        // 已有墓碑的 rev 更大时保留它：这条删除不能把账本改回旧版本。
        final rev =
            existing != null && existing.rev > nextRev ? existing.rev : nextRev;
        final now = DateTime.now().toUtc();
        final tombstone = DraftTombstonesCompanion.insert(
          profileId: row.profileId,
          uid: row.uid,
          rev: rev,
          deletedAt: now,
        );
        // 同一 (profileId, uid) 可能已有墓碑：用 upsert 保留这次算出来的
        // rev（= max(旧墓碑, 本次删除 + 1)）与最新的删除时间。
        await into(draftTombstones).insertOnConflictUpdate(tombstone);
        await (delete(drafts)..where((t) => t.id.equals(id))).go();
        return DbDraftTombstone(
          profileId: row.profileId,
          uid: row.uid,
          rev: rev,
          deletedAt: now,
        );
      });

  // ------------------------------------------------------ 云端同步写回

  /// 应用一份**远端**草稿：按 `(profileId, uid)` 精确落库，**不改 rev**。
  ///
  /// 与 [saveDraft] / [updateDraftFields] 的差别只有一条，但它决定了同步层
  /// 能不能收敛：那两个方法把 `rev` 当成「本地内容版本」+1，而这里写进去的
  /// `rev` 来自远端（服务端 CAS 的依据）。混用的话，每拉一次就凭空多出一个
  /// 本地版本 —— 冲突判定会把「其实没改过」判成「改过」，然后无限生成冲突
  /// 副本。所以这里**必须**走独立的写路径，不能复用 `saveDraft`。
  ///
  /// 行为：行存在 → 整行覆盖（主题/正文/收件人/附件/发件邮箱/更新时间都按
  /// 远端的来）；不存在 → 插入（`uid`/`rev` 用远端的）。同一事务里**清掉该
  /// uid 的墓碑**：远端把这条又写回来了，说明「本机删过」这件事已经过期，
  /// 留着它会让同步层再把删除推一次、把刚拉下来的草稿又抹掉。
  ///
  /// 冲突判定不在这一层：本地脏且 rev 更高时，调用方根本不该调到这里
  /// （见父仓 spec §6.5）。这里只负责「按你说的落库」。
  ///
  /// 空 `uid` 直接返回：那是「迁移还没回填」的脏行身份，写进来也进不了任何
  /// 同步视图（与 [findDraftByUid] 的口径一致）。
  Future<void> applyRemoteDraft({
    required String profileId,
    required String uid,
    required int rev,
    required String accountEmail,
    required String recipientsJson,
    required String subject,
    required String content,
    required List<String> attachmentPaths,
    required DateTime updatedAt,
  }) {
    if (uid.isEmpty) return Future<void>.value();
    final companion = DraftsCompanion(
      profileId: Value(profileId),
      uid: Value(uid),
      rev: Value(rev),
      accountEmail: Value(accountEmail),
      recipientsJson: Value(recipientsJson),
      subject: Value(subject),
      content: Value(content),
      attachmentPathsJson: Value(encodeAttachmentPaths(attachmentPaths)),
      updatedAt: Value(updatedAt.toUtc()),
    );
    return transaction(() async {
      final existing = await (select(drafts)
            ..where((t) => t.profileId.equals(profileId) & t.uid.equals(uid)))
          .getSingleOrNull();
      if (existing != null) {
        await (update(drafts)..where((t) => t.id.equals(existing.id)))
            .write(companion);
      } else {
        await into(drafts).insert(companion);
      }
      await (delete(draftTombstones)
            ..where((t) => t.profileId.equals(profileId) & t.uid.equals(uid)))
          .go();
    });
  }

  /// 应用**服务端删除**：删本机行（连同「打开中」标记），并且**不写墓碑**。
  ///
  /// 为什么不写墓碑：墓碑的含义是「本机删了、要推到云端」。把远端删除记成
  /// 本机墓碑，下次推送就会把这条删除再发回去 —— 两台设备各删一次、互相
  /// 触发，永远删不完。同理，同一事务里把已有墓碑也清掉：云端已经确认删了，
  /// 这个账号键下不再有「欠一次删除」的账。
  ///
  /// 行不存在是幂等的空操作（远端墓碑可能被重复拉到）。
  Future<void> deleteRemoteDraft(String profileId, String uid) =>
      transaction(() async {
        if (uid.isEmpty) return;
        final row = await (select(drafts)
              ..where(
                  (t) => t.profileId.equals(profileId) & t.uid.equals(uid)))
            .getSingleOrNull();
        if (row != null) {
          await (delete(composePages)
                ..where((t) => t.draftId.equals(row.id)))
              .go();
          await (delete(drafts)..where((t) => t.id.equals(row.id))).go();
        }
        await (delete(draftTombstones)
              ..where((t) => t.profileId.equals(profileId) & t.uid.equals(uid)))
            .go();
      });

  /// 全部墓碑，按删除时间升序（同步层补发时先删的先发）。
  Future<List<DbDraftTombstone>> listDraftTombstones() =>
      (select(draftTombstones)
            ..orderBy([
              (t) => OrderingTerm(expression: t.deletedAt),
            ]))
          .get();

  /// 删掉这些墓碑（云端已确认收到 `deleted=true`）。
  ///
  /// 空集合直接返回：`IN ()` 在 SQLite 里是语法错误，而「一个都没推成功」
  /// 是正常状态，不该让调用方先判空。
  Future<void> deleteTombstones(String profileId, Iterable<String> uids) async {
    final list = uids.toList(growable: false);
    if (list.isEmpty) return;
    await (delete(draftTombstones)
          ..where((t) => t.profileId.equals(profileId) & t.uid.isIn(list)))
        .go();
  }

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
    await (delete(draftTombstones)
          ..where((t) => t.profileId.equals(profileId)))
        .go();
    await (delete(recipientsHistory)
          ..where((t) => t.profileId.equals(profileId)))
        .go();
  }
}
