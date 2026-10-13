import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:drift/drift.dart';

import 'database.dart';
import 'mail_store_events.dart';

/// [MailStore] 的 drift 实现 —— 核心对扩展暴露「本地有什么邮件」的唯一窗口。
///
/// ## 它只读
///
/// 这个类里没有一条写语句。扩展拿到它只能翻本地已有的东西；要改数据得回核心
/// （而核心目前没有为扩展开任何写口 —— 真到需要时再按 [AppExtension] 的规矩
/// 加钩子，别在这里偷偷加）。
///
/// ## 它不做过滤
///
/// 「只要收件」「只要未读」这类筛选交给扩展自己做 —— `LocalMail.type` /
/// `.unread` 都带出来了。核心在这里加条件，等于把某一类扩展的需求写死进接缝。
class CoreMailStore implements MailStore {
  CoreMailStore(this._db);

  final AppDatabase _db;

  @override
  Future<List<LocalMail>> pageAfter({
    String? profileId,
    String? afterProfileId,
    int afterEmailId = 0,
    int limit = 500,
    bool withContent = true,
  }) async {
    final query = _db.select(_db.mails);

    if (profileId != null) {
      query.where((t) => t.profileId.equals(profileId));
    }
    if (afterProfileId != null) {
      // 键是 `(profileId, emailId)` 的**二元组**序：先比 profile，同 profile 再
      // 比 id。写成「profile > X 或 (profile = X 且 id > Y)」而不是只比 id ——
      // 不同实例的 emailId 会重号，只比 id 会把别的实例的行漏掉或者捞重。
      query.where(
        (t) =>
            t.profileId.isBiggerThanValue(afterProfileId) |
            (t.profileId.equals(afterProfileId) &
                t.emailId.isBiggerThanValue(afterEmailId)),
      );
    }
    query
      ..orderBy([
        (t) => OrderingTerm(expression: t.profileId),
        (t) => OrderingTerm(expression: t.emailId),
      ])
      ..limit(limit);

    final rows = await query.get();
    return <LocalMail>[
      for (final row in rows) _toLocalMail(row, withContent: withContent),
    ];
  }

  @override
  Future<int> count({String? profileId}) async {
    final countExp = _db.mails.emailId.count();
    final query = _db.selectOnly(_db.mails)..addColumns([countExp]);
    if (profileId != null) {
      query.where(_db.mails.profileId.equals(profileId));
    }
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  @override
  Future<Set<int>> existingEmailIds(
    String profileId,
    Iterable<int> emailIds,
  ) async {
    final ids = emailIds.toList(growable: false);
    if (ids.isEmpty) return const <int>{};
    final rows = await (_db.selectOnly(_db.mails)
          ..addColumns([_db.mails.emailId])
          ..where(_db.mails.profileId.equals(profileId) &
              _db.mails.emailId.isIn(ids)))
        .get();
    return <int>{for (final row in rows) row.read(_db.mails.emailId)!};
  }

  @override
  Future<List<LocalMail>> updatedSince(
    DateTime since, {
    String? profileId,
  }) async {
    final query = _db.select(_db.mails)
      // `cachedAt` 只在整行被写时刷新（`upsertPage` / `upsertFull`）——
      // 标已读、标星标、归位邮箱都是局部 UPDATE，不动它。所以这个水位线之后
      // 的行必然带着**新的正文**，而只改了已读/星标的行不会出现。见
      // [MailStore.updatedSince] 的文档。
      ..where((t) => t.cachedAt.isBiggerThanValue(since));
    if (profileId != null) {
      query.where((t) => t.profileId.equals(profileId));
    }
    final rows = await (query
          ..orderBy([(t) => OrderingTerm(expression: t.cachedAt)]))
        .get();
    return <LocalMail>[for (final row in rows) _toLocalMail(row)];
  }

  @override
  Stream<MailStoreEvent> changes() => mailStoreChanges();

  LocalMail _toLocalMail(DbMail row, {bool withContent = true}) => LocalMail(
        profileId: row.profileId,
        emailId: row.emailId,
        accountId: row.accountId,
        type: row.type,
        unread: row.unread,
        isStar: row.isStar,
        sendEmail: row.sendEmail,
        name: row.name,
        subject: row.subject,
        toEmail: row.toEmail,
        toName: row.toName,
        mailboxEmail: row.mailboxEmail,
        code: row.code,
        bodyText: withContent ? row.bodyText : null,
        content: withContent ? row.content : null,
        hasFullBody: row.hasFullBody,
        sentAt: row.createTime,
        cachedAt: row.cachedAt,
      );
}
