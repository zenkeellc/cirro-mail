import 'package:drift/drift.dart';

import '../../../data/models/instance_capabilities.dart';
import '../../../data/models/mail_attachment.dart';
import '../../../data/models/mail_row.dart';
import '../../../data/models/mailbox_account.dart';
import '../../../data/models/profile.dart';
import '../database.dart';
import '../mappers.dart';
import '../tables.dart';

part 'profile_dao.g.dart';

/// 实例 / 能力 / 邮箱 的本地读写。
///
/// 这三张表都是「实例级」的 —— 删实例时要连它们一起清干净。
@DriftAccessor(tables: [Profiles, Capabilities, Mailboxes])
class ProfileDao extends DatabaseAccessor<AppDatabase> with _$ProfileDaoMixin {
  ProfileDao(super.db);

  // ---- profiles ----

  /// 所有实例，按 `sort` 升序（同序时按创建时间）。
  Future<List<Profile>> allProfiles() async {
    final rows = await (select(profiles)
          ..orderBy([
            (t) => OrderingTerm(expression: t.sort),
            (t) => OrderingTerm(expression: t.createdAt),
          ]))
        .get();
    return rows.map(profileFromDb).toList(growable: false);
  }

  Stream<List<Profile>> watchProfiles() {
    final query = select(profiles)
      ..orderBy([
        (t) => OrderingTerm(expression: t.sort),
        (t) => OrderingTerm(expression: t.createdAt),
      ]);
    return query.watch().map(
          (rows) => rows.map(profileFromDb).toList(growable: false),
        );
  }

  Future<Profile?> findProfile(String id) async {
    final row = await (select(profiles)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : profileFromDb(row);
  }

  /// 插入或整行覆盖。
  Future<void> upsertProfile(Profile profile) =>
      into(profiles).insertOnConflictUpdate(profileToDb(profile));

  /// 只更新局部字段（登录成功回写 email/userId 等）。
  ///
  /// 传 null 表示「不动这一列」—— 所以这里**没有办法把某一列写回 null**
  /// （`lastSyncAt` 之类也不需要这么做）。
  Future<void> updateProfileFields(
    String id, {
    String? name,
    int? sort,
    int? colorIndex,
    String? email,
    String? serverTitle,
    String? userName,
    int? userId,
    String? ossBase,
    bool? needsLogin,
    DateTime? lastSyncAt,
    DateTime? lastActiveAt,
  }) async {
    await (update(profiles)..where((t) => t.id.equals(id))).write(
      ProfilesCompanion(
        name: name == null ? const Value.absent() : Value(name),
        sort: sort == null ? const Value.absent() : Value(sort),
        colorIndex:
            colorIndex == null ? const Value.absent() : Value(colorIndex),
        email: email == null ? const Value.absent() : Value(email),
        serverTitle:
            serverTitle == null ? const Value.absent() : Value(serverTitle),
        userName: userName == null ? const Value.absent() : Value(userName),
        userId: userId == null ? const Value.absent() : Value(userId),
        ossBase: ossBase == null ? const Value.absent() : Value(ossBase),
        needsLogin:
            needsLogin == null ? const Value.absent() : Value(needsLogin),
        lastSyncAt:
            lastSyncAt == null ? const Value.absent() : Value(lastSyncAt),
        lastActiveAt:
            lastActiveAt == null ? const Value.absent() : Value(lastActiveAt),
      ),
    );
  }

  /// 删实例：连本地缓存、能力、邮箱、邮件、附件、同步状态一起清。
  ///
  /// **token 不在这里清** —— 那是 `TokenStore` 的事，由调用方负责，
  /// 因为 dao 不该知道密钥库的存在。
  Future<void> deleteProfileCascade(String id) async {
    await transaction(() async {
      await _clearDataOf(id);
      await (delete(profiles)..where((t) => t.id.equals(id))).go();
    });
  }

  /// 清掉某个实例的**全部本地数据，但保留 profile 行本身**。
  ///
  /// 「退出登录但保留服务器」用这个：用户只是想换个账号登回来，
  /// 服务器地址与备注名还有价值，但上一个账号的邮件缓存必须清干净。
  Future<void> clearProfileData(String id) async {
    await transaction(() async {
      await _clearDataOf(id);
      await updateProfileFields(id, userId: 0, needsLogin: true);
    });
  }

  Future<void> _clearDataOf(String id) async {
    await (delete(db.mails)..where((t) => t.profileId.equals(id))).go();
    await (delete(db.attachments)..where((t) => t.profileId.equals(id))).go();
    await (delete(db.mailboxes)..where((t) => t.profileId.equals(id))).go();
    await (delete(db.syncStates)..where((t) => t.profileId.equals(id))).go();
    await (delete(db.outboxEntries)..where((t) => t.profileId.equals(id))).go();
    await (delete(db.recipientsHistory)..where((t) => t.profileId.equals(id)))
        .go();
    await (delete(db.drafts)..where((t) => t.profileId.equals(id))).go();
    await (delete(db.reminders)..where((t) => t.profileId.equals(id))).go();
    await (delete(capabilities)..where((t) => t.profileId.equals(id))).go();
  }

  // ---- capabilities ----

  Future<InstanceCapabilities?> loadCapabilities(String profileId) async {
    final row = await (select(capabilities)
          ..where((t) => t.profileId.equals(profileId)))
        .getSingleOrNull();
    return row == null ? null : capabilitiesFromDb(row);
  }

  Stream<InstanceCapabilities?> watchCapabilities(String profileId) =>
      (select(capabilities)..where((t) => t.profileId.equals(profileId)))
          .watchSingleOrNull()
          .map((row) => row == null ? null : capabilitiesFromDb(row));

  Future<void> saveCapabilities(
    String profileId,
    InstanceCapabilities caps,
  ) =>
      into(capabilities).insertOnConflictUpdate(
        capabilitiesToDb(profileId, caps),
      );

  /// 只删能力表里那一行（`_clearDataOf` 是「清空整个实例」，这里只要一格）。
  ///
  /// 用在**临时探针**上：「测试连接」会用一个不落库的 `__probe__` profile
  /// 去打一次接口，顺手把站点标题写进能力表 —— 那次写入对用户毫无价值，
  /// 却会在设置页留下一个不存在的实例条目。用完就删。
  Future<void> deleteCapabilities(String profileId) async {
    await (delete(capabilities)..where((t) => t.profileId.equals(profileId)))
        .go();
  }

  // ---- mailboxes ----

  Future<List<MailboxAccount>> mailboxesOf(String profileId) async {
    final rows = await (select(mailboxes)
          ..where((t) => t.profileId.equals(profileId))
          // 与服务端 `accountService.list` 的排序**逐字对齐**：
          // `desc(sort), asc(accountId)`。
          //
          // `sort` 列只有置顶语义，唯一的写者是 `upsertMailboxes`（服务端行
          // 整行覆盖），而服务端从不写 0 以外的值（加邮箱走列默认 0，只有
          // `setAsTop` 写非 0）。所以这里改方向不会动到「本来就对」的顺序：
          // sort 全为 0 的一堆仍然按 accountId 升序，那正是服务端对同 sort
          // 的第二关键字。
          //
          // 改之前本地是 `asc(sort)` —— 与服务端相反，用户点一次「置顶」
          // 网页端跳到最前、App 里跳到最末（规格 §7.2）。
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.sort,
                  mode: OrderingMode.desc,
                ),
            (t) => OrderingTerm(expression: t.accountId),
          ]))
        .get();
    return rows.map(_mailboxFromDb).toList(growable: false);
  }

  Stream<List<MailboxAccount>> watchMailboxes(String profileId) {
    final query = select(mailboxes)
      ..where((t) => t.profileId.equals(profileId))
      // 与服务端 `accountService.list` 的排序**逐字对齐**：
      // `desc(sort), asc(accountId)`。
      //
      // `sort` 列只有置顶语义，唯一的写者是 `upsertMailboxes`（服务端行
      // 整行覆盖），而服务端从不写 0 以外的值（加邮箱走列默认 0，只有
      // `setAsTop` 写非 0）。所以这里改方向不会动到「本来就对」的顺序：
      // sort 全为 0 的一堆仍然按 accountId 升序，那正是服务端对同 sort
      // 的第二关键字。
      //
      // 改之前本地是 `asc(sort)` —— 与服务端相反，用户点一次「置顶」
      // 网页端跳到最前、App 里跳到最末（规格 §7.2）。
      ..orderBy([
        (t) => OrderingTerm(
              expression: t.sort,
              mode: OrderingMode.desc,
            ),
        (t) => OrderingTerm(expression: t.accountId),
      ]);
    return query.watch().map(
          (rows) => rows.map(_mailboxFromDb).toList(growable: false),
        );
  }

  Future<void> upsertMailboxes(
    String profileId,
    Iterable<MailboxAccount> list,
  ) async {
    await batch((b) {
      for (final account in list) {
        b.insert(
          mailboxes,
          mailboxToDb(profileId, account),
          onConflict: DoUpdate(
            (_) => mailboxToDb(profileId, account),
            target: [mailboxes.profileId, mailboxes.accountId],
          ),
        );
      }
    });
  }

  /// 删掉本地有、而这次服务端没返回的邮箱行。**只动 `mailboxes` 这一张表。**
  ///
  /// 这个方法以前是「大删」：连带把那些邮箱的 mails / attachments /
  /// syncStates 也清了。它有一条**够得着**的坏路径 —— `AccountRepository.refresh`
  /// 在服务端**成功但返回空列表**时会把结果换成 `_fallbackOnly`（只有主邮箱），
  /// 而 `cameFromServer` 已经是 true，于是这里把其他所有邮箱判成「服务端没有」、
  /// 连邮件一起清掉（还绕过 `EmailRepository.delete` 的取消 / 重试，也不调
  /// `purgeMail` 清磁盘，留下的是孤儿文件）。
  ///
  /// 现在清空本地痕迹只剩**一个**入口：`MailDao.purgeMailbox`，而它只在
  /// `AccountRepository.remove` 里被调用（服务端已经确认删成功）。
  /// 于是「本地有邮件、服务端没有这个邮箱」这种残留不会再被误伤。
  ///
  /// 调用方（`AccountRepository.refresh`）仍然只在**真的从 `/account/list`
  /// 拿到完整列表**时才调它 —— 那是对「这一页就是全部」的信心问题，
  /// 与这个方法删多少是两件事。
  Future<void> removeMailboxesNotIn(
    String profileId,
    Set<int> keepAccountIds,
  ) async {
    await (delete(mailboxes)
          ..where((t) =>
              t.profileId.equals(profileId) &
              t.accountId.isNotIn(keepAccountIds.isEmpty ? <int>[-1] : keepAccountIds)))
        .go();
  }

  static MailboxAccount _mailboxFromDb(DbMailbox row) => MailboxAccount(
        accountId: row.accountId,
        email: row.email,
        name: row.name,
        status: row.status,
        allReceive: row.allReceive,
        sort: row.sort,
        latestEmailTime: row.latestEmailTime,
      );
}

/// 供上层判断某封邮件是否属于某个邮箱（聚合视图分组用）。
bool mailboxMatches(MailRow row, MailboxAccount account) =>
    row.accountId == account.accountId ||
    (row.mailboxEmail.isNotEmpty && row.mailboxEmail == account.email);

/// 附件归属判断（附件行里只带 `attId`，靠 emailId 关联）。
bool attachmentBelongsTo(MailAttachment att, MailRow row) =>
    att.emailId == row.emailId;
