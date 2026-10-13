import 'package:drift/drift.dart';

import '../../../core/config/app_defaults.dart';
import '../../../core/util/email_address.dart';
import '../../../data/models/enums.dart';
import '../../../data/models/mail_attachment.dart';
import '../../../data/models/mail_ref.dart';
import '../../../data/models/mail_row.dart';
// `core/` 反向引 `features/` 的值对象是本次新引入的一处方向。它换来的是
// 「谓词只写一遍」：`MailboxFilter` 同时是 prefs 的存储形态与 DAO 的入参，
// 拆成两份镜像类型才是真的脏。
import '../../../features/mail_list/mailbox_filter.dart';
import '../../../providers/profile_providers.dart' show kAllMailboxes;
import '../database.dart';
import '../mail_store_events.dart';
import '../mappers.dart';
import '../tables.dart';

part 'mail_dao.g.dart';

/// 邮件的本地缓存读写。
///
/// 三条要点：
/// 1. **主键是 `(profileId, emailId)`**：聚合视图里不同实例的 `emailId` 会重号，
///    任何按 `emailId` 的查询都必须同时带 `profileId`。写操作的入参统一用
///    [MailRef]，避免把裸 int 传错实例。
/// 2. **写操作要保住本地字段**：服务端返回的行里没有 `localPath`/`cachedAt`，
///    用它覆盖会把附件下载记录抹掉，所以 `upsert` 只覆盖邮件本身那部分
///    （附件单独走 `AttachmentDao`）。
/// 3. **`hasFullBody` 不能倒退**：摘要行（`full=0`）不能把已经拿到的完整正文
///    覆盖掉 —— 否则每次刷新列表都会把详情页的正文清空。
/// 4. **`unread` 不能倒退**（0 未读 / 1 已读，语义与字段名相反）：
///    服务端行只能把本地抬成已读，不能打回未读。理由见 [_merge]。
@DriftAccessor(tables: [Mails, Attachments, SyncStates])
class MailDao extends DatabaseAccessor<AppDatabase> with _$MailDaoMixin {
  MailDao(super.db);

  // ------------------------------------------------------------ 单条读写

  Future<MailRow?> find(String profileId, int emailId) async {
    final row = await (select(mails)
          ..where((t) => t.profileId.equals(profileId) & t.emailId.equals(emailId)))
        .getSingleOrNull();
    return row == null ? null : mailFromDb(row);
  }

  Stream<MailRow?> watch(String profileId, int emailId) =>
      (select(mails)
            ..where(
                (t) => t.profileId.equals(profileId) & t.emailId.equals(emailId)))
          .watchSingleOrNull()
          .map((row) => row == null ? null : mailFromDb(row));

  /// 批量插入/合并一页邮件。
  ///
  /// [accountId]/[mailboxEmail] 由调用方补：列表接口不返回「投递到哪个邮箱」，
  /// 但同一次请求是按某个 accountId 查的，所以调用方知道答案。
  ///
  /// 合并逻辑刻意放在 Dart 里（先读一次旧行再写），而不是用 `DoUpdate` 的表达式：
  /// - `hasFullBody` **只允许 false → true**：摘要行重新刷进来时不能把已拿到的
  ///   完整正文标记打回去，否则每次刷新列表都会清空详情页的正文；
  /// - 摘要行不带 `content`/`bodyText`，不能覆盖掉已有的完整正文；
  /// - `/email/latest` 的响应里**没有 `isStar`**，不能把用户标的星标抹掉
  ///   （靠 [MailRow.starKnown] 区分「字段缺失」与「值为 0」）。
  ///
  /// 读旧行是一次 `SELECT ... WHERE (profile_id, email_id) IN (...)`，
  /// 一页 ≤50 行，比 N 次条件 UPDATE 便宜且显然正确。
  Future<void> upsertPage(
    Iterable<MailRow> rows, {
    DateTime? cachedAt,
  }) async {
    final now = cachedAt ?? DateTime.now().toUtc();
    final incoming = rows.toList(growable: false);
    if (incoming.isEmpty) return;

    final existing = await _existingRows(incoming);

    await batch((b) {
      for (final row in incoming) {
        final old = existing[row.emailId];
        b.insert(
          mails,
          _merge(row, old, cachedAt: now),
          onConflict: DoUpdate(
            (_) => _merge(row, old, cachedAt: now),
            target: [mails.profileId, mails.emailId],
          ),
        );
      }
    });

    // 扩展的增量水位线建在这上面（见 `mail_store_events.dart`）。
    // 放在 `batch` 之后：事务没提交就发事件，订阅方可能读到旧数据。
    publishMailsUpserted(
      incoming.first.profileId,
      incoming.map((r) => r.emailId),
    );
  }

  /// 按 `emailId` 读同一页里已存在的行。`profileId` 从第一个元素取 ——
  /// 一页永远只属于一个实例（聚合视图是从本地库读的，不会走这里写）。
  Future<Map<int, DbMail>> _existingRows(List<MailRow> rows) async {
    final profileId = rows.first.profileId;
    final ids = rows.map((r) => r.emailId).toList(growable: false);
    final found = await (select(mails)
          ..where((t) => t.profileId.equals(profileId) & t.emailId.isIn(ids)))
        .get();
    return <int, DbMail>{for (final row in found) row.emailId: row};
  }

  DbMail _merge(MailRow row, DbMail? old, {required DateTime cachedAt}) {
    final fresh = mailToDb(row, cachedAt: cachedAt);
    if (old == null) return fresh;

    // 星标：服务端没给这个字段就保留本地值。
    final isStar = row.starKnown ? fresh.isStar : old.isStar;
    final starKnown = old.starKnown || row.starKnown;

    // 列表接口不返回「投递到哪个邮箱」，靠本地 mailboxes 表补。
    // 补不上时不能把已有的值抹成空串。
    final mailboxEmail =
        fresh.mailboxEmail.isEmpty ? old.mailboxEmail : fresh.mailboxEmail;
    final accountId = fresh.accountId == 0 ? old.accountId : fresh.accountId;

    // 已读状态**单调**：服务端行只能把本地从未读抬成已读，不能打回未读。
    //
    // 服务端的 `unread` 本来就是单调的 —— 全仓只有一处写它
    // （`mail-worker/src/service/email-service.js` 的 `read()`，写死 `READ`），
    // 三处 INSERT 都不带该列、用实体默认 0。所以「本地已读」永远不会比
    // 服务端更超前。
    //
    // 反过来做会回弹：一个「取页早于 `PUT /email/read` 返回」的陈旧页
    // （`backfillBodies` 每轮轮询都跑，见 `sync_engine.dart`）会把刚标上的
    // 已读盖回未读。Web 端为同一个坑专门写了 `keepRead`
    // （`mail-vue/src/store/email.js`）。
    //
    // 代价：**本地要回未读只剩「显式本地写」一条路** —— `markRead(read: false)`
    // 的菜单项、以及标已读失败后的回滚。而服务端只会给 1，所以本地标的未读
    // 下次被服务端页拉回已读是**预期行为**。
    final unread =
        old.unread > fresh.unread ? old.unread : fresh.unread;

    // 正文：只有拿到完整版才覆盖，否则保留已有的。
    if (!row.hasFullBody) {
      return fresh.copyWith(
        content: Value(old.content),
        bodyText: Value(old.bodyText),
        hasFullBody: old.hasFullBody,
        unread: unread,
        isStar: isStar,
        starKnown: starKnown,
        mailboxEmail: mailboxEmail,
        accountId: accountId,
      );
    }

    return fresh.copyWith(
      hasFullBody: true,
      unread: unread,
      isStar: isStar,
      starKnown: starKnown,
      mailboxEmail: mailboxEmail,
      accountId: accountId,
    );
  }

  /// 用 `full=1` 的行补全正文（详情页拿到完整数据后调用）。
  ///
  /// 与 [upsertPage] 的区别：这里**信任**传进来的行就是完整版，直接覆盖正文；
  /// 但仍然保住本地的星标（`/email/latest` 之后本地可能更新过）与
  /// `has_full_body`（恒为 true）。
  Future<void> upsertFull(MailRow row) async {
    final old = await _existingRows(<MailRow>[row]);
    await into(mails).insertOnConflictUpdate(
      _merge(
        row.copyWith(hasFullBody: true),
        old[row.emailId],
        cachedAt: DateTime.now().toUtc(),
      ),
    );
    // 正文补齐走的就是这条路 —— 内容变了，扩展的索引必须跟着动。
    publishMailsUpserted(row.profileId, <int>[row.emailId]);
  }

  /// 把本地已有的行按「投递地址 → accountId」重新归位。
  ///
  /// 只动 `account_id = 0` 的行：0 在本地是「归属未知」的哨兵值（服务端的
  /// `emailBriefColumns` 不带 `accountId`，历史版本同步下来的收信全是 0），
  /// 非 0 的归属一律不碰。
  ///
  /// 之所以需要一次显式的 UPDATE：`_merge` 里「`fresh.accountId == 0` 就保留
  /// 旧值」把 0 锁死了 —— 摘要行永远给不出非 0 的 `accountId`，0 和 0 合并
  /// 还是 0。没有这一步，老数据的空白邮箱列表永远好不了。
  ///
  /// 撮合规则复用 [accountIdForEmail]（与写库时同一份），这里不重复实现。
  ///
  /// 返回被改写的行数。
  Future<int> reassignAccountIds(
    String profileId,
    AccountIdByEmail byEmail,
  ) async {
    if (byEmail.isEmpty) return 0;

    final orphaned = await (select(mails)
          ..where((t) =>
              t.profileId.equals(profileId) &
              t.accountId.equals(0) &
              t.isDel.equals(0)))
        .get();
    if (orphaned.isEmpty) return 0;

    final repaired = <int, int>{};
    for (final row in orphaned) {
      // 发信看「从哪个邮箱发出」，收信看「投递到哪个邮箱」。
      final address =
          row.type == MailType.send ? row.sendEmail : row.toEmail;
      final accountId = accountIdForEmail(byEmail, address);
      if (accountId != null && accountId != 0) {
        repaired[row.emailId] = accountId;
      }
    }
    if (repaired.isEmpty) return 0;

    // `byEmail` 的键已归一化，但显示用的邮箱要原始大小写 —— 先按 accountId
    // 记下任意一个原样地址（同一个 accountId 在表里只有一行）。
    final mailboxOf = <int, String>{};
    for (final entry in byEmail.entries) {
      mailboxOf.putIfAbsent(entry.value, () => entry.key);
    }

    await batch((b) {
      for (final entry in repaired.entries) {
        b.update(
          mails,
          MailsCompanion(
            accountId: Value(entry.value),
            mailboxEmail: Value(mailboxOf[entry.value] ?? ''),
          ),
          where: (t) =>
              t.profileId.equals(profileId) & t.emailId.equals(entry.key),
        );
      }
    });
    return repaired.length;
  }

  /// 只改已读状态。**不要去写整行** —— 并发的列表刷新会把状态改回去。
  ///
  /// 这里是**唯一**能把本地行改回未读的地方（[upsertPage] / [upsertFull]
  /// 走的 [_merge] 让 `unread` 单调，服务端只会给 1）。调用方：
  /// - `EmailRepository.markRead(read: false)`（详情菜单「标记未读」）；
  /// - 标已读失败后的回滚。
  ///
  /// 标未读**本地留不住**：服务端的 `unread = 1` 下次同步回来就把它盖回已读，
  /// 这是预期行为，不是 bug。
  Future<void> markRead(Iterable<MailRef> refs, {required bool read}) async {
    final value = read ? UnreadState.read : UnreadState.unread;
    await batch((b) {
      for (final ref in refs) {
        b.update(
          mails,
          MailsCompanion(unread: Value(value)),
          where: (t) =>
              t.profileId.equals(ref.profileId) & t.emailId.equals(ref.emailId),
        );
      }
    });
  }

  Future<void> markStar(MailRef ref, {required bool starred}) async {
    await (update(mails)
          ..where((t) =>
              t.profileId.equals(ref.profileId) & t.emailId.equals(ref.emailId)))
        .write(MailsCompanion(isStar: Value(starred ? 1 : 0)));
  }

  /// 星标是按用户维度存的（`star` 表），列表之外的邮件的 `isStar` 只能靠这个
  /// 补 —— `star/list` 只返回被标星的邮件。
  Future<void> setStarByEmailIds(String profileId, Iterable<int> emailIds) async {
    final ids = emailIds.toList(growable: false);
    if (ids.isEmpty) return;
    await (update(mails)
          ..where((t) => t.profileId.equals(profileId) & t.emailId.isIn(ids)))
        .write(const MailsCompanion(isStar: Value(1)));
  }

  /// 删除：物理删本地行（服务端已经删了）。附件记录一起清，
  /// 但**磁盘上的文件留给 `AttachmentCache` 决定**（可能被其他邮件共用）。
  Future<void> deleteRefs(Iterable<MailRef> refs) async {
    final refList = refs.toList(growable: false);
    if (refList.isEmpty) return;
    await transaction(() async {
      for (final ref in refList) {
        await (delete(attachments)
              ..where((t) =>
                  t.profileId.equals(ref.profileId) &
                  t.emailId.equals(ref.emailId)))
            .go();
        // 「稍后提醒」跟着邮件走：那封信不在了，提醒也不该留着。
        // 在同一个事务里，所以不会出现「邮件删了、提醒还在」的中间态。
        // 这里用 `db.reminders` 而不是改 @DriftAccessor 的 tables 列表：
        // `DatabaseAccessor.db` 就是 AppDatabase（`ProfileDao._clearDataOf`
        // 那 8 张表用的是同一个写法）。
        await (delete(db.reminders)
              ..where((t) =>
                  t.profileId.equals(ref.profileId) &
                  t.emailId.equals(ref.emailId)))
            .go();
        await (delete(mails)
              ..where((t) =>
                  t.profileId.equals(ref.profileId) &
                  t.emailId.equals(ref.emailId)))
            .go();
      }
    });
    // 本仓唯一允许按 profileId 分组的地方（`MailRef` 自带 profileId）。
    _byProfile(refList).forEach(publishMailsDeleted);
  }

  /// 把一批 ref 按 `profileId` 分组 —— 事件是「一个实例一批 id」的形状。
  Map<String, List<int>> _byProfile(Iterable<MailRef> refs) {
    final out = <String, List<int>>{};
    for (final ref in refs) {
      (out[ref.profileId] ??= <int>[]).add(ref.emailId);
    }
    return out;
  }

  /// 删掉一个邮箱在本地的**全部痕迹**。服务端删邮箱是物理删除
  /// （`physicsDelete`：删附件记录 + `DELETE FROM email WHERE account_id = ?`），
  /// 所以本地这批邮件也一样不存在了 —— 这里**不按 `isDel` 过滤**，
  /// 软删的行在物理删除面前同样没了（而且 [_mailboxPredicate] 带着
  /// `isDel = 0`，留下它们等于留下永远查不出来的垃圾）。
  ///
  /// 与 [deleteRefs] 是**同一组表、同一个顺序**（附件 → 提醒 → 邮件）——
  /// 它是本仓库本地删除的唯一漏斗，新方法必须与它一致，否则「删了邮件、
  /// 提醒还在」这类中间态会以新的形状回来。
  ///
  /// 返回被删掉的 `emailId` 列表：调用方要用它逐封清**磁盘上的**附件
  /// （`AttachmentRepository.purgeMail`）。这里只清库记录 ——
  /// 与 `deleteRefs` 的注释同一条分工，「磁盘上的文件留给 `AttachmentCache` 决定」。
  ///
  /// 刻意**不碰** `all:type:*` 的同步游标：那是实例级的聚合游标，`SyncEngine`
  /// 每轮都在维护它，删了会让整台实例从头全量拉一遍。
  /// 刻意**不碰** `drafts`：草稿是用户自己写的东西，与邮箱还在不在无关
  /// （它只是个 `accountEmail` 字符串，发信时另选发件人即可）。
  Future<List<int>> purgeMailbox(String profileId, int accountId) async {
    // scope 前缀手写而不是调 `EmailRepository.mailboxScope` ——
    // `core/db` → `data/repositories` 会成环（与文件顶部那段
    // `features/mail_list/mailbox_filter.dart` 的注释同一条分寸）。
    // 走散的风险由 `test/mail_dao_purge_test.dart` 最后一条用例钉住。
    final scopePrefix = 'mailbox:$accountId:type:';
    final emailIds = await transaction(() async {
      final rows = await (select(mails)
            ..where((t) =>
                t.profileId.equals(profileId) &
                t.accountId.equals(accountId)))
          .get();

      // 「归属未知」的老信兜底（`account_id = 0`）。
      //
      // 根因：同步永远走 `allReceive: true`，服务端的摘要列
      // （`emailBriefColumns`）**不带 `accountId`**，写库时只能拿投递地址
      // （`toEmail` / `sendEmail`）去本地 `mailboxes` 反查归属；反查不到就落成
      // 0。而 [_merge] 只在入参非 0 时才覆盖 `accountId`，于是 0 一旦落下就
      // **粘住**了 —— 后续同步同样给不出非 0 值。这些行按 `account_id` 是删不掉的
      // （下面那条按 accountId 的批量 delete 够不着它们），它们的 attachments /
      // reminders 与**磁盘上的附件目录**（调用方靠返回的 emailId 触发
      // `onDiskPurge`）也就永远留着。
      //
      // 所以这里按**地址**再捞一次：只把「地址反查落在被删邮箱上」的 0 行
      // 并进来，别的一概不碰。
      final knownIds =
          rows.map((r) => r.emailId).toList(growable: false);
      final orphans = await (select(mails)
            ..where((t) =>
                t.profileId.equals(profileId) &
                t.accountId.equals(0) &
                // 已经在 `rows` 里的不重复捞（belt-and-braces：accountId 既是
                // 入参，正常不会与 0 的行重叠）。
                t.emailId.isNotIn(knownIds.isEmpty ? <int>[-1] : knownIds)))
          .get();
      if (orphans.isNotEmpty) {
        // 被删邮箱的地址：从 `mailboxes` 里按 accountId 找。
        // **找不到行、或地址为空就整段跳过** —— 没有权威地址时不许凭 air
        // 把任何一行当成「属于它」（宁可留下垃圾也不误删别的邮箱的信）。
        final mailboxRows = await (select(db.mailboxes)
              ..where((t) => t.profileId.equals(profileId)))
            .get();
        final doomed = mailboxRows
            .where((m) => m.accountId == accountId)
            .toList(growable: false);
        final doomedEmail = doomed.isEmpty ? '' : doomed.first.email;
        if (doomedEmail.isNotEmpty) {
          // 反查表：别的、还在的邮箱 → 各自的真实 accountId（空地址跳过，
          // 空串进表只会污染 `accountIdForEmail`）；被删邮箱 → 哨兵。
          //
          // 用**现成的** [accountIdForEmail]（`core/util/email_address.dart`）
          // 而不是在这里重写一遍 `+tag` / 大小写规则：那套规则必须只有一处
          // 实现（库顶部那段注释），写库（`EmailRepository._persist`）与历史
          // 回填（[reassignAccountIds]）用的就是它，两处一旦走散，归属会得出
          // 两个答案，那种 bug 极难看出来。
          //
          // 哨兵取 -1：真实的 `accountId` 全是正数（全仓没有「负 accountId」
          // 这个约定），所以 -1 不会与任何一个真邮箱撞上。
          //
          // 已知取舍：别的邮箱若与被删邮箱**共基址**（`a@x.com` vs
          // `a+b@x.com`），`accountIdForEmail` 的精确命中优先，会落到那个
          // 邮箱的真实 id（≠ 哨兵），于是这封 0 行**不会被清**。这是故意的
          // 「宁可少删、不可误删」——留一点残留好过删掉别的邮箱的信。
          const sentinel = -1;
          final byEmail = <String, int>{
            for (final m in mailboxRows)
              if (m.email.isNotEmpty && m.accountId != accountId)
                normalizeEmail(m.email): m.accountId,
            normalizeEmail(doomedEmail): sentinel,
          };
          final matched = <DbMail>[
            for (final row in orphans)
              if (accountIdForEmail(
                      byEmail,
                      // 发信看「从哪个邮箱发出」，收信看「投递到哪个邮箱」
                      // —— 与 [reassignAccountIds] 同一份判据。
                      row.type == MailType.send ? row.sendEmail : row.toEmail) ==
                  sentinel)
                row,
          ];
          if (matched.isNotEmpty) {
            rows.addAll(matched);
          }
        }
      }

      final emailIds =
          rows.map((r) => r.emailId).toList(growable: false);

      for (final id in emailIds) {
        await (delete(attachments)
              ..where((t) =>
                  t.profileId.equals(profileId) & t.emailId.equals(id)))
            .go();
        await (delete(db.reminders)
              ..where((t) =>
                  t.profileId.equals(profileId) & t.emailId.equals(id)))
            .go();
      }
      // 邮件行一次性按 accountId 删（不必逐封）—— 上面那个循环只为拿到
      // emailId 列表去删附件与提醒，这两张表没有 accountId 这一列。
      await (delete(mails)
            ..where((t) =>
                t.profileId.equals(profileId) &
                t.accountId.equals(accountId)))
          .go();
      // 归属 0 的老信按 accountId 删不到（它们就是 0），只能按 emailId 补一刀。
      // 没匹配上就不执行 —— `isIn([])` 在 SQLite 里恒假，但空分支徒增一次
      // 事务内的删除语句（与 `removeMailboxesNotIn` 用 `-1` 兜空表同一条理）。
      final matchedIds =
          rows.where((r) => r.accountId == 0).map((r) => r.emailId).toList();
      if (matchedIds.isNotEmpty) {
        await (delete(mails)
              ..where((t) =>
                  t.profileId.equals(profileId) & t.emailId.isIn(matchedIds)))
            .go();
      }
      await (delete(syncStates)
            ..where((t) =>
                t.profileId.equals(profileId) &
                t.scope.like('$scopePrefix%')))
          .go();
      await (delete(db.mailboxes)
            ..where((t) =>
                t.profileId.equals(profileId) &
                t.accountId.equals(accountId)))
          .go();
      return emailIds;
    });
    // 事务之后才发：订阅方读库时删已经落定，否则会读回一批正要消失的行。
    publishMailsDeleted(profileId, emailIds);
    return emailIds;
  }

  // ---------------------------------------------------------- 列表查询

  /// 单实例某个邮箱的列表（收件 / 发件）。游标 [beforeEmailId] 为 null 时取最新页。
  Future<List<MailRow>> pageOfMailbox(
    String profileId,
    int accountId, {
    int? beforeEmailId,
    int size = 50,
    int? type,
    bool allReceive = false,
  }) async {
    final query = _mailboxQuery(
      profileId,
      accountId,
      beforeEmailId: beforeEmailId,
      type: type,
      allReceive: allReceive,
    );
    final rows = await (query
          ..orderBy([(t) => OrderingTerm(expression: t.emailId, mode: OrderingMode.desc)])
          ..limit(size))
        .get();
    return rows.map(mailFromDb).toList(growable: false);
  }

  /// 单实例某个邮箱的**响应式**列表（列表页直接 watch，发信/同步写库后自动刷新）。
  Stream<List<MailRow>> watchMailbox(
    String profileId,
    int accountId, {
    int? type,
    bool allReceive = false,
    int limit = 200,
  }) {
    final query = _mailboxQuery(
      profileId,
      accountId,
      type: type,
      allReceive: allReceive,
    );
    return (query
          ..orderBy([
            (t) => OrderingTerm(expression: t.createTime, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.emailId, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .watch()
        .map((rows) => rows.map(mailFromDb).toList(growable: false));
  }

  /// 当前已缓存的**最老**一封的 `emailId`（往上翻页的游标）。
  ///
  /// 返回 0 表示本地还没有数据，调用方应直接拉第一页。
  /// 注意这里按 `emailId` 取最小而不是按 `createTime` —— 服务端游标就是
  /// `lt(emailId)`，两者口径必须一致，否则会重复拉同一页。
  Future<int> oldestEmailIdOf(
    String profileId,
    int accountId, {
    int? type,
    bool allReceive = false,
  }) async {
    final minExp = mails.emailId.min();
    final query = selectOnly(mails)
      ..addColumns([minExp])
      ..where(_mailboxPredicate(
        profileId,
        accountId,
        type: type,
        allReceive: allReceive,
      ));
    final row = await query.getSingle();
    return row.read(minExp) ?? 0;
  }

  /// 本地已缓存多少封（**同一过滤口径**）。
  ///
  /// 不能用列表行数代替：`watchMailbox` 封顶 200 条，本地超过 200 封之后
  /// 行数就永远追不上服务端的 `total` 了，而「还剩几封没同步」正要用这两个数相减。
  Future<int> countMailbox(
    String profileId,
    int accountId, {
    int? type,
    bool allReceive = false,
  }) async {
    final countExp = mails.emailId.count();
    final query = selectOnly(mails)
      ..addColumns([countExp])
      ..where(_mailboxPredicate(
        profileId,
        accountId,
        type: type,
        allReceive: allReceive,
      ));
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  Stream<int> watchMailboxCount(
    String profileId,
    int accountId, {
    int? type,
    bool allReceive = false,
  }) {
    final countExp = mails.emailId.count();
    final query = selectOnly(mails)
      ..addColumns([countExp])
      ..where(_mailboxPredicate(
        profileId,
        accountId,
        type: type,
        allReceive: allReceive,
      ));
    return query.watchSingle().map((row) => row.read(countExp) ?? 0);
  }

  /// 每个实例已缓存多少封**收件**（同步面板「已同步 N 封」用）。
  ///
  /// 按实例分组返回，与 `/email/latest` 的口径一致（只算收件、不算已删）。
  Stream<Map<String, int>> watchReceiveCountByProfile() {
    final countExp = mails.emailId.count();
    final query = selectOnly(mails)
      ..addColumns([mails.profileId, countExp])
      ..where(mails.type.equals(MailType.receive) & mails.isDel.equals(0))
      ..groupBy([mails.profileId]);
    return query.watch().map(
          (rows) => <String, int>{
            for (final row in rows)
              if (row.read(mails.profileId) != null)
                row.read(mails.profileId)!: row.read(countExp) ?? 0,
          },
        );
  }

  /// 正文还没补拉的最新的若干封（`hasFullBody = false`），新的在前。
  ///
  /// 这是「正文补拉」的待办队列。按 `createTime desc, emailId desc` 取 ——
  /// 用户看得见的是列表最上面那几封，先补它们，灰点才会一眼可见地消失。
  Future<List<MailRow>> newestMissingBody(
    String profileId,
    int accountId, {
    int? type,
    bool allReceive = false,
    int limit = 20,
  }) async {
    final query = _mailboxQuery(
      profileId,
      accountId,
      type: type,
      allReceive: allReceive,
    );
    final rows = await (query
          ..where((t) => t.hasFullBody.equals(false))
          ..orderBy([
            (t) => OrderingTerm(expression: t.createTime, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.emailId, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .get();
    return rows.map(mailFromDb).toList(growable: false);
  }

  /// 某个邮箱里已缓存的最新一封的 `emailId`（用 `latest` 做增量时校验游标用）。
  Future<int> newestEmailIdOf(
    String profileId,
    int accountId, {
    int? type,
    bool allReceive = false,
  }) async {
    final maxExp = mails.emailId.max();
    final query = selectOnly(mails)
      ..addColumns([maxExp])
      ..where(_mailboxPredicate(
        profileId,
        accountId,
        type: type,
        allReceive: allReceive,
      ));
    final row = await query.getSingle();
    return row.read(maxExp) ?? 0;
  }

  SimpleSelectStatement<$MailsTable, DbMail> _mailboxQuery(
    String profileId,
    int accountId, {
    int? beforeEmailId,
    int? type,
    bool allReceive = false,
  }) {
    // 游标与基础条件合成一个 where —— 分两次 `..where()` 也能工作，
    // 但合成一个更容易核对（drift 会 AND 起来，可读性差）。
    return select(mails)
      ..where((t) {
        var predicate = _mailboxPredicate(
          profileId,
          accountId,
          type: type,
          allReceive: allReceive,
        );
        if (beforeEmailId != null && beforeEmailId > 0) {
          predicate = predicate & t.emailId.isSmallerThanValue(beforeEmailId);
        }
        return predicate;
      });
  }

  Expression<bool> _mailboxPredicate(
    String profileId,
    int accountId, {
    int? type,
    bool allReceive = false,
  }) {
    var predicate =
        mails.profileId.equals(profileId) & mails.isDel.equals(0);
    // `allReceive` 时忽略 accountId —— 与服务端 `emailListFilters` 一致
    // （合并视图就是靠这个实现，而不是把每个邮箱的 allReceive 打开）。
    if (!allReceive) {
      predicate = predicate & mails.accountId.equals(accountId);
    }
    if (type != null) {
      predicate = predicate & mails.type.equals(type);
    }
    return predicate;
  }

  /// **按 (实例, 邮箱) 集合过滤**的时间线（收件箱多选邮箱之后的主力查询）。
  ///
  /// 为什么不能复用另外两条：
  /// - [watchTimeline] 按实例过滤但**不看邮箱** —— 多选邮箱的语义它表达不了；
  /// - [watchMailbox] 是「一个实例、一个邮箱」—— 跨实例的组合它表达不了。
  ///
  /// 集合为空 = **全部**（聚合语义，与 `profileIds` 为空的 [watchTimeline]
  /// 一致）。这点很关键：它让「没筛过」与「全勾上」走同一条路径，不必在
  /// 上游先 materialize 出一份完整邮箱清单。
  ///
  /// 每一项折成一个 `OR` 分支（SQLite 没有元组 `IN`，只能这样）。分支内部：
  /// - `accountId == kAllMailboxes` → 只要 `profile_id` 对上。这是「这个实例
  ///   的全部邮箱」，**含** `account_id = 0` 的归属未知老行 —— 合并视图的
  ///   口径（见 [watchMailbox] 里 `allReceive` 那段注释）；
  /// - 具体邮箱 → `profile_id` 与 `account_id` 都要对上。0 的老行**不**混进来：
  ///   它完全可能属于别的邮箱，混进来就是脏数据。
  Stream<List<MailRow>> watchMailboxSet({
    List<MailboxFilter> mailboxes = const <MailboxFilter>[],
    int? type,
    bool unreadOnly = false,
    int limit = 200,
  }) {
    final query = select(mails)
      ..where(
        (t) => _mailboxSetPredicate(
          t,
          mailboxes,
          type: type,
          unreadOnly: unreadOnly,
        ),
      );
    // 列表行要显示附件标记，附件数用子查询一起带出来（见 [_attachmentCountExp]）。
    final countExp = _attachmentCountExp;
    final joined = query.join(<Join>[])..addColumns(<Expression<Object>>[countExp]);
    return (joined
          ..orderBy([
            OrderingTerm(expression: mails.createTime, mode: OrderingMode.desc),
            OrderingTerm(expression: mails.emailId, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .watch()
        .map((rows) => rows
            .map((row) => _mailFromJoined(row, countExp))
            .toList(growable: false));
  }

  /// [watchMailboxSet] 谓词的具名版本。
  ///
  /// 单独抽出来是为了让聚合查询（[countMailboxSet] 用的是 `selectOnly`，
  /// 那里没有 `select(mails)` 这个句柄）与列表查询**共用同一份口径** ——
  /// 「还剩几封没同步」是拿两个数相减的，两边口径但凡差一点，数字就是错的。
  Expression<bool> _mailboxSetPredicate(
    $MailsTable t,
    List<MailboxFilter> mailboxes, {
    int? type,
    bool unreadOnly = false,
  }) {
    Expression<bool> predicate = t.isDel.equals(0);
    if (mailboxes.isNotEmpty) {
      Expression<bool>? any;
      for (final box in mailboxes) {
        final term = box.accountId == kAllMailboxes
            ? t.profileId.equals(box.profileId)
            : (t.profileId.equals(box.profileId) &
                t.accountId.equals(box.accountId));
        any = any == null ? term : (any | term);
      }
      predicate = predicate & any!;
    }
    if (type != null) {
      predicate = predicate & t.type.equals(type);
    }
    if (unreadOnly) {
      // `unread` 的语义与字段名相反：0 才是未读。未读只对收件方向有意义。
      predicate = predicate &
          t.unread.equals(UnreadState.unread) &
          t.type.equals(MailType.receive);
    }
    return predicate;
  }

  /// 与 [watchMailboxSet] **同一口径**的计数（「还剩几封」用两个数相减，
  /// 口径必须一模一样，所以谓词共用一份）。
  Future<int> countMailboxSet({
    List<MailboxFilter> mailboxes = const <MailboxFilter>[],
    int? type,
    bool unreadOnly = false,
  }) async {
    final countExp = mails.emailId.count();
    final query = selectOnly(mails)
      ..addColumns([countExp])
      ..where(
        _mailboxSetPredicate(
          mails,
          mailboxes,
          type: type,
          unreadOnly: unreadOnly,
        ),
      );
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  /// **聚合时间线**：不带 profileId 过滤，按时间倒序。
  ///
  /// [profileIds] 为空表示「全部实例」；收起「只看某几个实例」时传进来。
  /// 时间用 `createTime` 排、同秒再按 `emailId` 兜底 —— 服务端时间戳精度只到秒，
  /// 同一秒收到多封时纯按时间排会乱序。
  Stream<List<MailRow>> watchTimeline({
    List<String> profileIds = const <String>[],
    List<int> types = const <int>[],
    int limit = 200,
  }) {
    var query = select(mails)..where((t) => t.isDel.equals(0));
    if (profileIds.isNotEmpty) {
      query = query..where((t) => t.profileId.isIn(profileIds));
    }
    if (types.isNotEmpty && types.length < 2) {
      query = query..where((t) => t.type.equals(types.first));
    }
    return (query
          ..orderBy([
            (t) => OrderingTerm(expression: t.createTime, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.emailId, mode: OrderingMode.desc),
          ])
          ..limit(limit))
      .watch()
        .map((rows) => rows.map(mailFromDb).toList(growable: false));
  }

  /// 星标文件夹（本地口径：任何带 `isStar=1` 的行）。
  Stream<List<MailRow>> watchStarred({
    List<String> profileIds = const <String>[],
    int limit = 200,
  }) {
    var query = select(mails)
      ..where((t) => t.isStar.equals(1) & t.isDel.equals(0));
    if (profileIds.isNotEmpty) {
      query = query..where((t) => t.profileId.isIn(profileIds));
    }
    final countExp = _attachmentCountExp;
    final joined =
        query.join(<Join>[])..addColumns(<Expression<Object>>[countExp]);
    return (joined
          ..orderBy([
            OrderingTerm(expression: mails.emailId, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .watch()
        .map((rows) => rows
            .map((row) => _mailFromJoined(row, countExp))
            .toList(growable: false));
  }

  // ---------------------------------------------------------- 未读计数

  /// 每个实例的未读数。
  ///
  /// **服务端没有未读计数接口**，只能本地算；冷启动第一次同步完成前这个值
  /// 是不准的，UI 应显示「同步中」而不是一个错误的 0。
  Future<Map<String, int>> unreadCountByProfile() async {
    final countExp = mails.emailId.count();
    final query = selectOnly(mails)
      ..addColumns([mails.profileId, countExp])
      ..where(mails.unread.equals(UnreadState.unread) &
          mails.isDel.equals(0) &
          mails.type.equals(MailType.receive))
      ..groupBy([mails.profileId]);
    final rows = await query.get();
    return <String, int>{
      for (final row in rows)
        if (row.read(mails.profileId) != null)
          row.read(mails.profileId)!: row.read(countExp) ?? 0,
    };
  }

  Stream<Map<String, int>> watchUnreadByProfile() {
    final countExp = mails.emailId.count();
    final query = selectOnly(mails)
      ..addColumns([mails.profileId, countExp])
      ..where(mails.unread.equals(UnreadState.unread) &
          mails.isDel.equals(0) &
          mails.type.equals(MailType.receive))
      ..groupBy([mails.profileId]);
    return query.watch().map(
          (rows) => <String, int>{
            for (final row in rows)
              if (row.read(mails.profileId) != null)
                row.read(mails.profileId)!: row.read(countExp) ?? 0,
          },
        );
  }

  /// 单个邮箱的未读数（聚合视图里按收件邮箱分组），**一次性**查询。
  ///
  /// UI 已经改走 [watchUnreadByMailbox]（读掉一封信要立刻看到数字变小）——
  /// 留在这里是给「只要一个数、不需要订阅」的调用方，以及它与那条流的口径
  /// 必须一致（都只算收件方向、都排除已删）。
  Future<int> unreadCountOfMailbox(String profileId, int accountId) async {
    final countExp = mails.emailId.count();
    final query = selectOnly(mails)
      ..addColumns([countExp])
      ..where(mails.profileId.equals(profileId) &
          mails.accountId.equals(accountId) &
          mails.unread.equals(UnreadState.unread) &
          mails.isDel.equals(0) &
          mails.type.equals(MailType.receive));
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  /// **每个邮箱**的未读数，一条流覆盖全部 —— 键与 `unreadCountOfMailbox`
  /// 的入参同形：`profileId` → `accountId` → 未读数。
  ///
  /// 与 [watchUnreadByProfile] 分开的原因：那个按实例分组（侧栏一级项用），
  /// 这个按邮箱分组（侧栏二级项、筛选面板用）。两者都只算收件方向。
  ///
  /// 做成**一条流**而不是每个邮箱一条 `Future`：侧栏展开时同时有几十个邮箱，
  /// 每个邮箱各挂一个订阅就是几十条查询（见 `sidebar_mailboxes.dart` 的
  /// 那段注释）。一条 `groupBy` 查询天然覆盖全部邮箱，写一次库也只重建一次。
  ///
  /// 没有未读的邮箱**不在 Map 里**（`groupBy` 不产生 0 行），取值方要按
  /// `?? 0` 处理。
  Stream<Map<String, Map<int, int>>> watchUnreadByMailbox() {
    final countExp = mails.emailId.count();
    final query = selectOnly(mails)
      ..addColumns([mails.profileId, mails.accountId, countExp])
      ..where(mails.unread.equals(UnreadState.unread) &
          mails.isDel.equals(0) &
          mails.type.equals(MailType.receive))
      ..groupBy([mails.profileId, mails.accountId]);
    return query.watch().map((rows) {
      final result = <String, Map<int, int>>{};
      for (final row in rows) {
        final profileId = row.read(mails.profileId);
        final accountId = row.read(mails.accountId);
        if (profileId == null || accountId == null) continue;
        result.putIfAbsent(profileId, () => <int, int>{})[accountId] =
            row.read(countExp) ?? 0;
      }
      return result;
    });
  }

  // ------------------------------------------------------------ 同步状态

  /// 游标与退避状态。`scope` 形如 `type:0`（收件）或 `mailbox:12:type:0`。
  Future<DbSyncState?> syncState(String profileId, String scope) =>
      (select(syncStates)
            ..where((t) => t.profileId.equals(profileId) & t.scope.equals(scope)))
          .getSingleOrNull();

  /// 写一行同步状态。
  ///
  /// **这是整行 replace（`insertOnConflictUpdate`）**，没传的列会被写成默认值 ——
  /// `remoteTotal` / `backfillDone` / `oldestEmailId` 这类「本轮不关心」的列，
  /// 调用方一旦忘了传就会被清零。所以这里把参数语义定成
  /// **null = 保留旧值**，并在开头读一次旧行。下面的 `advanceCursor` /
  /// `recordFailure` / `invalidateCursor` 都依赖这个语义。
  ///
  /// [clearError] 为 true 表示显式清掉 `lastError`（成功路径），
  /// 否则用 [lastError]（同样是 null = 保留）。
  Future<void> saveSyncState({
    required String profileId,
    required String scope,
    int? cursorEmailId,
    int? oldestEmailId,
    int? remoteTotal,
    DateTime? remoteTotalAt,
    bool? backfillDone,
    DateTime? lastSyncAt,
    int? failCount,
    String? lastError,
    bool clearError = false,
  }) async {
    final existing = await syncState(profileId, scope);
    final companion = SyncStatesCompanion.insert(
      profileId: profileId,
      scope: scope,
      cursorEmailId: Value(cursorEmailId ?? existing?.cursorEmailId ?? 0),
      oldestEmailId: Value(oldestEmailId ?? existing?.oldestEmailId ?? 0),
      remoteTotal: Value(remoteTotal ?? existing?.remoteTotal ?? 0),
      remoteTotalAt: Value(remoteTotalAt ?? existing?.remoteTotalAt),
      backfillDone: Value(backfillDone ?? existing?.backfillDone ?? false),
      lastSyncAt: Value(lastSyncAt ?? existing?.lastSyncAt),
      failCount: Value(failCount ?? existing?.failCount ?? 0),
      lastError: Value(
        clearError ? null : (lastError ?? existing?.lastError),
      ),
    );
    await into(syncStates).insertOnConflictUpdate(companion);
  }

  /// 只记这一行**总数与拿到它的时刻**（侧栏那个「未读 / 总数」要它）。
  ///
  /// **按列 UPDATE，刻意不走 [saveSyncState]**：那个是「读旧行 → 整行 replace」
  /// 的形状，与同步引擎的 [advanceCursor] 交叉时会互相丢字段 —— 轻则总数闪回
  /// 未知，重则被一次 `advanceCursor` 抹掉，而且这两种都不会有测试变红。
  /// 这里只碰 `remote_total` 与 `remote_total_at` 两列，谁来并发写都只影响这两列。
  ///
  /// **0 也照写**：`remote_total` 的 0 表示「还不知道」，但这一列不是那个意思 ——
  /// 它是**服务端真的回了 0**，配上非 null 的 [at] 就是「这个邮箱是空的」这条
  /// 正经结论（见 `SyncStates.remoteTotalAt`）。
  Future<void> recordMailboxTotal({
    required String profileId,
    required String scope,
    required int total,
    required DateTime at,
  }) async {
    final changed = await (update(syncStates)
          ..where((t) => t.profileId.equals(profileId) & t.scope.equals(scope)))
        .write(SyncStatesCompanion(
      remoteTotal: Value(total),
      remoteTotalAt: Value(at),
    ));
    if (changed > 0) return;
    // 还没有这一行：插一行只带这两个字段的。其余列走默认值，而
    // `cursorEmailId = 0` / `backfillDone = false` / `failCount = 0` /
    // `lastSyncAt = null` 与「根本没有这一行」在 `syncMailbox` 与 `_hydrate`
    // 的读法里完全等价 —— 所以这是安全的。用 `insertOnConflictUpdate` 兜住
    // 「两个 isolate 同时发现没有这一行」那种并发插入。
    await into(syncStates).insertOnConflictUpdate(SyncStatesCompanion.insert(
      profileId: profileId,
      scope: scope,
      remoteTotal: Value(total),
      remoteTotalAt: Value(at),
    ));
  }

  /// 只更新游标，不动退避计数（增量拉取成功时用）。
  ///
  /// **`cursorEmailId` 单调递增**（只在变大时才写）。这是「断点续传」的底线：
  /// 一轮并发的旧响应回来时不能把游标推回去，否则下一轮会重拉已经落盘的那一段。
  Future<void> advanceCursor({
    required String profileId,
    required String scope,
    required int cursorEmailId,
    DateTime? at,
  }) async {
    final existing = await syncState(profileId, scope);
    final next = cursorEmailId > (existing?.cursorEmailId ?? 0)
        ? cursorEmailId
        : existing?.cursorEmailId ?? 0;
    await saveSyncState(
      profileId: profileId,
      scope: scope,
      cursorEmailId: next,
      lastSyncAt: at ?? DateTime.now().toUtc(),
      failCount: 0,
      clearError: true,
    );
  }

  /// 记录一次失败并按指数退避递增（调度器读 `failCount` 算下一次间隔）。
  Future<int> recordFailure({
    required String profileId,
    required String scope,
    required String error,
  }) async {
    final existing = await syncState(profileId, scope);
    final next = (existing?.failCount ?? 0) + 1;
    await saveSyncState(
      profileId: profileId,
      scope: scope,
      lastSyncAt: existing?.lastSyncAt,
      failCount: next,
      lastError: error,
    );
    return next;
  }

  /// 游标之前发现了缺口（收到了 `emailId < cursor` 的新信）→ 需要全量重扫。
  Future<void> invalidateCursor(String profileId, String scope) async {
    await saveSyncState(
      profileId: profileId,
      scope: scope,
      cursorEmailId: 0,
      oldestEmailId: 0,
      failCount: 0,
      clearError: true,
    );
  }

  /// 服务端 `total` 落库（「还有 N 封未同步」的减数）。见 [SyncStates.remoteTotal]。
  ///
  /// 顺手盖上时间戳：侧栏那个「未知 / 已知」的判据看的是 `remoteTotalAt`
  /// 而不是 `remoteTotal`（见 [SyncStates.remoteTotalAt]），同步顺手拿到的
  /// 这个数与探测拿到的是**同一个数**，不给它盖时间戳的话，一次正常的同步
  /// 之后侧栏仍然显示占位符，然后白白再探一次。
  Future<void> saveRemoteTotal({
    required String profileId,
    required String scope,
    required int total,
    DateTime? at,
  }) async {
    if (total <= 0) return; // 0 = 还不知道，不要用一个假的 0 去覆盖已知值。
    await saveSyncState(
      profileId: profileId,
      scope: scope,
      remoteTotal: total,
      remoteTotalAt: at ?? DateTime.now().toUtc(),
    );
  }

  /// 更旧的方向翻到底了。
  Future<void> markBackfillDone(String profileId, String scope) =>
      saveSyncState(profileId: profileId, scope: scope, backfillDone: true);

  /// 同步状态的响应式版本（面板/占位行要随着每轮同步自动更新）。
  Stream<DbSyncState?> watchSyncState(String profileId, String scope) =>
      (select(syncStates)
            ..where((t) =>
                t.profileId.equals(profileId) & t.scope.equals(scope)))
          .watchSingleOrNull();

  /// 一个实例**全部** scope 的同步状态：`scope` → 它的那一行。
  ///
  /// 侧栏那个「未读 / 总数」是逐邮箱一格，但底层只开**一条**流 ——
  /// 与 `watchUnreadByMailbox` 同一条理由：几十个邮箱就有几十格，
  /// 每格各开一条查询的话，写一次库要唤醒几十个订阅（而它们读的是同一张表）。
  /// 返回 Map 而不是 List：调用方要找的是某一个 scope，不是遍历。
  Stream<Map<String, DbSyncState>> watchSyncStatesOfProfile(String profileId) =>
      (select(syncStates)..where((t) => t.profileId.equals(profileId)))
          .watch()
          .map((rows) => <String, DbSyncState>{
                for (final row in rows) row.scope: row,
              });

  // ------------------------------------------------------------ 附件关联

  /// 「这封邮件有几个附件」的相关子查询，挂在列表查询上带出来。
  ///
  /// 为什么不给 `mails` 加一列 `attachment_count`：那是 denormalize，附件表
  /// 的每一处写入/删除都得跟着维护它（`upsertAttachments`、`deleteRefs`、
  /// 缓存清理……），漏一处那个数字就永远错着。子查询是这个数的**唯一来源**，
  /// 不可能走散。
  ///
  /// 用**相关子查询**而不是 `join`：join 回来的是「邮件 × 附件」的笛卡尔行，
  /// 列表要的是邮件，还得在 Dart 里再去重。
  ///
  /// 响应式不用额外接流：drift 在 `writeInto` 时会把子查询读的表也登记进
  /// `watchedTables`（`drift/lib/src/runtime/query_builder/helpers.dart` 的
  /// `WriteDefinition.writeResultSet`），所以附件行变化时这两条 `watch()`
  /// 会自己重新发一次。
  ///
  /// 不按 `type == 0` 过滤，与详情页数「全部附件行」的口径一致
  /// （`attachments` 表本来就只会有普通附件，见 `tables.dart` 的表注释）。
  Expression<int> get _attachmentCountExp =>
      subqueryExpression<int>(selectOnly(attachments)
        ..addColumns([attachments.attId.count()])
        ..where(attachments.profileId.equalsExp(mails.profileId) &
            attachments.emailId.equalsExp(mails.emailId)));

  /// 把「邮件行 + 那行子的附件数」拼回 [MailRow]。
  ///
  /// 挂子查询的列表查询拿到的已经是 `TypedResult`，整行要用 `readTable`
  /// 取回来 —— 不能再 `rows.map(mailFromDb)`（那一步拿不到子查询的列）。
  MailRow _mailFromJoined(TypedResult row, Expression<int> countExp) =>
      mailFromDb(row.readTable(mails)!).copyWith(
        attachmentCount: row.read(countExp) ?? 0,
      );

  Future<List<MailAttachment>> attachmentsOf(String profileId, int emailId) async {
    final rows = await (select(attachments)
          ..where((t) =>
              t.profileId.equals(profileId) & t.emailId.equals(emailId))
          ..orderBy([(t) => OrderingTerm(expression: t.attId)]))
        .get();
    return rows.map(attachmentFromDb).toList(growable: false);
  }

  /// 附件的响应式版本。附件是**先补拉正文、再写附件**（见 `upsertFull`），
  /// 详情页要能在这之后自动把附件列表补上，所以这里必须 watch 而不是一次性读。
  Stream<List<MailAttachment>> watchAttachments(
    String profileId,
    int emailId,
  ) =>
      (select(attachments)
            ..where((t) =>
                t.profileId.equals(profileId) & t.emailId.equals(emailId))
            ..orderBy([(t) => OrderingTerm(expression: t.attId)]))
          .watch()
          .map((rows) => rows.map(attachmentFromDb).toList(growable: false));

  /// 写入服务端给的附件行。
  ///
  /// **只覆盖服务端那部分字段**，`localPath`/`downloadedAt` 是本地下载记录，
  /// 用服务端数据整行覆盖会把「已下载」抹掉，导致缓存管理页丢条目、
  /// 附件又要重下一次。所以先读旧行再在 Dart 里合并。
  Future<void> upsertAttachments(
    String profileId,
    int emailId,
    Iterable<MailAttachment> list,
  ) async {
    final incoming = list.toList(growable: false);
    if (incoming.isEmpty) return;

    final ids = incoming.map((a) => a.attId).toList(growable: false);
    final existing = await (select(attachments)
          ..where((t) => t.profileId.equals(profileId) & t.attId.isIn(ids)))
        .get();
    final byId = <int, DbAttachment>{for (final row in existing) row.attId: row};

    await batch((b) {
      for (final att in incoming) {
        final old = byId[att.attId];
        final fresh = attachmentToDb(profileId, emailId, att);
        final merged = old == null
            ? fresh
            : fresh.copyWith(
                localPath: Value(old.localPath),
                downloadedAt: Value(old.downloadedAt),
              );
        b.insert(
          attachments,
          merged,
          onConflict: DoUpdate(
            (_) => merged,
            target: [attachments.profileId, attachments.attId],
          ),
        );
      }
    });
  }

  Future<void> markAttachmentDownloaded(
    String profileId,
    int attId, {
    required String localPath,
    DateTime? at,
  }) async {
    await (update(attachments)
          ..where((t) => t.profileId.equals(profileId) & t.attId.equals(attId)))
        .write(AttachmentsCompanion(
      localPath: Value(localPath),
      downloadedAt: Value(at ?? DateTime.now().toUtc()),
    ));
  }

  Future<void> clearAttachmentLocal(
    String profileId,
    int attId,
  ) async {
    await (update(attachments)
          ..where((t) => t.profileId.equals(profileId) & t.attId.equals(attId)))
        .write(const AttachmentsCompanion(
      localPath: Value(null),
      downloadedAt: Value(null),
    ));
  }

  /// 缓存管理页用：所有已下载的附件。
  Future<List<MailAttachment>> downloadedAttachments({String? profileId}) async {
    var query = select(attachments)..where((t) => t.localPath.isNotNull());
    if (profileId != null) {
      query = query..where((t) => t.profileId.equals(profileId));
    }
    final rows = await (query
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.downloadedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .get();
    return rows.map(attachmentFromDb).toList(growable: false);
  }

  /// 缓存淘汰 / 「按实例清理」用。只清库记录，磁盘文件由调用方删。
  Future<void> forgetLocalPaths(String profileId, Iterable<int> attIds) async {
    final ids = attIds.toList(growable: false);
    if (ids.isEmpty) return;
    await (update(attachments)
          ..where((t) => t.profileId.equals(profileId) & t.attId.isIn(ids)))
        .write(const AttachmentsCompanion(
      localPath: Value(null),
      downloadedAt: Value(null),
    ));
  }

  /// `emailId` → 该实例里已知的最小 / 最大游标（空洞检测用）。
  Future<({int min, int max})> idRange(String profileId, {int? accountId}) async {
    final minExp = mails.emailId.min();
    final maxExp = mails.emailId.max();
    var query = selectOnly(mails)
      ..addColumns([minExp, maxExp])
      ..where(mails.profileId.equals(profileId) & mails.isDel.equals(0));
    if (accountId != null) {
      query = query..where(mails.accountId.equals(accountId));
    }
    final row = await query.getSingle();
    return (min: row.read(minExp) ?? 0, max: row.read(maxExp) ?? 0);
  }

  // ---------------------------------------------------------- 同步阶段

  /// 这个实例里**正文还没补拉**的邮件，新的在前。
  ///
  /// 与 [newestMissingBody] 的差别：那个要 `accountId` + `allReceive`，
  /// 是「一轮补拉该拉哪一段」的取数；这个**跨该实例的全部邮箱**，
  /// 是「面板要列哪些行」的清单。两者不能合并 —— 前者的 `limit` 是每轮
  /// 的预算（20），后者的 `limit` 是界面上一次能看多少行（200）。
  ///
  /// `type` 传 null 表示收件与发件都要：草稿/发件方向的正文补拉在别处，
  /// 但「待同步」这个清单的语义是「本地这封信还不完整」，与方向无关。
  Stream<List<MailRow>> watchMissingBody(
    String profileId, {
    int? type = MailType.receive,
    int limit = 200,
  }) {
    var query = select(mails)
      ..where((t) =>
          t.profileId.equals(profileId) &
          t.isDel.equals(0) &
          t.hasFullBody.equals(false));
    if (type != null) query = query..where((t) => t.type.equals(type));
    return (query
          ..orderBy([
            (t) => OrderingTerm(expression: t.createTime, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.emailId, mode: OrderingMode.desc),
          ])
          ..limit(limit))
      .watch()
        .map((rows) => rows.map(mailFromDb).toList(growable: false));
  }

  /// 这个实例里**正文齐了但有附件没下**的邮件，新的在前。
  ///
  /// 判据是「这封信有附件行，且至少一条 `local_path is null`」。
  /// 用 `existsQuery`（一个 `exists` 子查询）而不是 join：join 回来的是
  /// 「邮件 × 附件」的笛卡尔行，界面上要的是邮件列表，还得在 Dart 里再去重。
  ///
  /// 已经下好的那些附件**不参与判定** —— 一封 3 个附件的信下好 2 个之后
  /// 仍然留在这个清单里（还缺 1 个），这是对的：它确实还没同步完。
  Stream<List<MailRow>> watchMissingAttachments(
    String profileId, {
    int? type = MailType.receive,
    int limit = 200,
  }) {
    var query = select(mails)
      ..where((t) =>
          t.profileId.equals(profileId) &
          t.isDel.equals(0) &
          t.hasFullBody.equals(true) &
          existsQuery(
            selectOnly(attachments)
              ..addColumns([attachments.attId])
              // 这里是**列与列**比较（相关子查询的外层列），所以用
              // `equalsExp`；`equals` 收的是值，传一列进去编译不过。
              ..where(attachments.profileId.equalsExp(t.profileId) &
                  attachments.emailId.equalsExp(t.emailId) &
                  attachments.localPath.isNull()),
          ));
    if (type != null) query = query..where((t) => t.type.equals(type));
    return (query
          ..orderBy([
            (t) => OrderingTerm(expression: t.createTime, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.emailId, mode: OrderingMode.desc),
          ])
          ..limit(limit))
      .watch()
        .map((rows) => rows.map(mailFromDb).toList(growable: false));
  }

  /// 这个实例「还没同步完」的邮件（缺正文 **或** 有附件没下），新的在前。
  ///
  /// 谓词必须与 [watchMissingBody] / [watchMissingAttachments] **逐字对应**
  /// —— 那两条是面板**列出来**的清单，这一条是「立即全部同步」照着**补**的
  /// 清单。两份走散时的表现很难查：面板里列着 12 行，点全部同步只补了 8 行，
  /// 剩下 4 行永远留在那儿，而界面上没有任何东西说明它们为什么被略过。
  ///
  /// 与那两条 watch 的差别只有取数方式（一次性读 vs 订阅）与返回形态
  /// （[MailRef] 而不是整行）：批量补拉只需要 ref，只有界面那一侧要整行。
  ///
  /// `limit` 默认取 [AppDefaults.syncBatchLimit] —— 与那两条 watch 的 200
  /// 是同一个数（界面上一次能看多少行 / 一次批量最多补多少封），但语义不同，
  /// 各写各的，不要互相引用。
  Future<List<MailRef>> pendingSyncRefs(
    String profileId, {
    int? type = MailType.receive,
    int limit = AppDefaults.syncBatchLimit,
  }) async {
    var query = select(mails)
      ..where((t) =>
          t.profileId.equals(profileId) &
          t.isDel.equals(0) &
          // 两个谓词的**并集**，不是交集：缺正文的那封附件表里可能什么都
          // 没有（正文那趟顺带会把附件列表带回来），有附件没下的那封正文
          // 一定已经齐了。交集永远是空集。
          (t.hasFullBody.equals(false) |
              existsQuery(
                selectOnly(attachments)
                  ..addColumns([attachments.attId])
                  ..where(attachments.profileId.equalsExp(t.profileId) &
                      attachments.emailId.equalsExp(t.emailId) &
                      attachments.localPath.isNull()),
              )));
    if (type != null) query = query..where((t) => t.type.equals(type));
    final rows = await (query
          ..orderBy([
            (t) => OrderingTerm(expression: t.createTime, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.emailId, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .get();
    return rows
        .map((row) => MailRef(profileId: profileId, emailId: row.emailId))
        .toList(growable: false);
  }

  /// 一个实例「还没同步完」的邮件数（缺正文 **或** 有附件没下）。
  ///
  /// 谓词逐字对应 [pendingSyncRefs]，只是数个数而不是取回来：
  /// 「立即全部同步」按下之后要立刻让用户看见「要补 200 封」，而不必等
  /// 逐封都跑完 —— 补 200 封按每封一个请求的节奏是好几分钟，那几分钟里
  /// 界面上必须有一个会动的数字，否则看起来就是卡住了。
  ///
  /// 不设 `limit`：`pendingSyncRefs` 的 limit 是**这一批最多补多少**，
  /// 而这个数是「一共有多少」—— 两个数在超过上限时**故意不相等**
  /// （200 / 348 那一眼就是「这一轮补不完，还有下一轮」）。
  Future<int> pendingSyncCount(
    String profileId, {
    int? type = MailType.receive,
  }) async {
    final countExp = mails.emailId.count();
    var query = selectOnly(mails)
      ..addColumns([countExp])
      ..where(mails.profileId.equals(profileId) &
          mails.isDel.equals(0) &
          (mails.hasFullBody.equals(false) |
              existsQuery(
                selectOnly(attachments)
                  ..addColumns([attachments.attId])
                  ..where(attachments.profileId.equalsExp(mails.profileId) &
                      attachments.emailId.equalsExp(mails.emailId) &
                      attachments.localPath.isNull()),
              )));
    if (type != null) {
      query = query..where(mails.type.equals(type));
    }
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  /// 一批邮件的附件统计（总数 / 未下载数）。
  ///
  /// 面板的一行要有「3 个附件，还差 2 个」这句话，而 [watchMissingAttachments]
  /// 只给得出邮件。
  ///
  /// 一次查一批（而不是每行一个查询）：`IN` 的成员本该是
  /// `(profileId, emailId)` 对，而 SQLite 没有元组 `IN` —— 所以这里按
  /// **emailId 集合**查（清单本来就是一个实例内的，emailId 在实例内唯一）。
  ///
  /// `emailIds` 里的号如果没有附件行，就不会出现在返回的 map 里 ——
  /// 调用方按「查不到 = 没有附件」处理。
  Stream<Map<int, ({int total, int missing})>> watchAttachmentStats(
    String profileId,
    List<int> emailIds,
  ) {
    if (emailIds.isEmpty) {
      return Stream<Map<int, ({int total, int missing})>>.value(
        const <int, ({int total, int missing})>{},
      );
    }
    final totalExp = attachments.attId.count();
    // 未下载的计数：`SUM(local_path IS NULL)`。Dart 侧的 `isNull()` 是一个
    // `Expression<bool>`，SQLite 里布尔就是 0/1，所以能直接求和 ——
    // 这是 SQLite 的既成事实，不是 drift 的扩展。
    final missingExp = attachments.localPath.isNull().cast<int>().sum();
    final query = selectOnly(attachments)
      ..addColumns([attachments.emailId, totalExp, missingExp])
      ..where(attachments.profileId.equals(profileId) &
          attachments.emailId.isIn(emailIds))
      ..groupBy([attachments.emailId]);

    return query.watch().map(
          (rows) => <int, ({int total, int missing})>{
            for (final row in rows)
              if (row.read(attachments.emailId) != null)
                row.read(attachments.emailId)!: (
                  total: row.read(totalExp) ?? 0,
                  missing: row.read(missingExp) ?? 0,
                ),
          },
        );
  }
}
