import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/data/models/mail_attachment.dart';
import 'package:mail_app/data/models/mail_row.dart';

/// 阶段查询的 SQL 结果。**必须用真库** —— 这里要验的正是
/// 「`exists` 子查询写得对不对」「`SUM(local_path IS NULL)` 在 SQLite 里
/// 到底算出来什么」，这些都不是纯 Dart 能覆盖的。
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> mail(
    int id, {
    int hasFullBody = 1,
    int isDel = 0,
    String profile = 'P',
    int type = 0,
  }) =>
      db.mailDao.upsertPage(<MailRow>[
        MailRow(
          profileId: profile,
          emailId: id,
          accountId: 1,
          mailboxEmail: 'a@example.net',
          type: type,
          status: 0,
          hasFullBody: hasFullBody == 1,
          isDel: isDel,
          subject: 's$id',
          createTime: DateTime.utc(2026, 10, 9, 0, 0, id),
        ),
      ]);

  Future<void> att(int emailId, int attId, {String? path, String profile = 'P'}) =>
      db.mailDao.upsertAttachments(profile, emailId, <MailAttachment>[
        MailAttachment(
          attId: attId,
          emailId: emailId,
          filename: 'f$attId.pdf',
          size: 10,
          localPath: path,
        ),
      ]);

  test('缺正文的清单：只列 hasFullBody=0 且没删的', () async {
    await mail(1, hasFullBody: 0);
    await mail(2, hasFullBody: 1);
    await mail(3, hasFullBody: 0, isDel: 1);
    final list = await db.mailDao.watchMissingBody('P').first;
    expect(list.map((r) => r.emailId), <int>[1]);
  });

  test('缺附件的清单：正文齐、且有附件行 localPath 为空', () async {
    await mail(1);
    await mail(2);
    await att(1, 11); // 没下
    await att(2, 21, path: '/tmp/x'); // 下好了
    final list = await db.mailDao.watchMissingAttachments('P').first;
    expect(list.map((r) => r.emailId), <int>[1]);
  });

  test('部分下好仍然算缺（3 个里下了 2 个）', () async {
    await mail(1);
    await att(1, 11, path: '/tmp/a');
    await att(1, 12, path: '/tmp/b');
    await att(1, 13);
    final list = await db.mailDao.watchMissingAttachments('P').first;
    expect(list.map((r) => r.emailId), <int>[1]);
  });

  test('全部下好之后从缺附件清单里消失', () async {
    await mail(1);
    await att(1, 11, path: '/tmp/a');
    await att(1, 12);
    expect(
      (await db.mailDao.watchMissingAttachments('P').first)
          .map((r) => r.emailId),
      <int>[1],
    );
    // 走**真实的落盘入口**（`markAttachmentLocal`），而不是再 upsert 一遍
    // 附件行 —— `upsertAttachments` 刻意保住旧 `localPath`，用它来「下好一个
    // 附件」是假的。
    await db.mailDao.markAttachmentDownloaded(
      'P',
      12,
      localPath: '/tmp/b',
    );
    expect(await db.mailDao.watchMissingAttachments('P').first, isEmpty);
  });

  test('正文没齐的不算缺附件（它先在缺正文那一档）', () async {
    await mail(1, hasFullBody: 0);
    await att(1, 11);
    final list = await db.mailDao.watchMissingAttachments('P').first;
    expect(list, isEmpty);
  });

  test('附件统计：总数与未下载数', () async {
    await mail(1);
    await att(1, 11, path: '/tmp/a');
    await att(1, 12);
    await att(1, 13);
    final stats = await db.mailDao.watchAttachmentStats('P', <int>[1]).first;
    expect(stats[1]?.total, 3);
    expect(stats[1]?.missing, 2);
  });

  test('附件统计：没有附件行的邮件不出现（调用方按「没有附件」处理）', () async {
    await mail(1);
    await mail(2);
    await att(2, 21);
    final stats = await db.mailDao.watchAttachmentStats('P', <int>[1, 2]).first;
    expect(stats.containsKey(1), isFalse);
    expect(stats[2]?.total, 1);
  });

  test('附件统计：空 emailIds 不发查询', () async {
    final stats =
        await db.mailDao.watchAttachmentStats('P', const <int>[]).first;
    expect(stats, isEmpty);
  });

  test('别的实例的同号邮件不串', () async {
    await mail(1, hasFullBody: 0);
    await mail(1, hasFullBody: 0, profile: 'Q');
    final list = await db.mailDao.watchMissingBody('P').first;
    expect(list.map((r) => r.profileId), <String>['P']);
  });

  test('别的实例的同号附件不串（统计按实例隔离）', () async {
    await mail(1);
    await att(1, 11, path: '/tmp/a');
    await att(1, 11, profile: 'Q');
    final stats = await db.mailDao.watchAttachmentStats('P', <int>[1]).first;
    expect(stats[1]?.total, 1);
    expect(stats[1]?.missing, 0);
  });

  test('发件方向的正文补拉也在这份清单里（type=null 时两个方向都要）', () async {
    await mail(1, hasFullBody: 0, type: 0);
    await mail(2, hasFullBody: 0, type: 1);
    expect(
      (await db.mailDao.watchMissingBody('P').first).map((r) => r.emailId),
      <int>[1],
    );
    expect(
      (await db.mailDao
              .watchMissingBody('P', type: null)
              .first)
          .map((r) => r.emailId)
          .toSet(),
      <int>{1, 2},
    );
  });

  group('pendingSyncRefs（「立即全部同步」照它补）', () {
    /// 与面板**列出来**的那两份清单逐字对应 —— 这一条才是本查询的存在理由。
    ///
    /// 界面上看不出来的走散长这样：面板列着 12 行，点「立即全部同步」只补了
    /// 8 行，剩下 4 行永远留在那儿。所以这里不逐条钉谓词，而是直接拿两份
    /// watch 的结果求并集来对。
    Future<Set<int>> panelIds() async {
      final body = await db.mailDao.watchMissingBody('P').first;
      final att = await db.mailDao.watchMissingAttachments('P').first;
      return <int>{
        ...body.map((r) => r.emailId),
        ...att.map((r) => r.emailId),
      };
    }

    test('并集就是面板那两档（缺正文 ∪ 缺附件）', () async {
      await mail(1, hasFullBody: 0); // 缺正文
      await mail(2, hasFullBody: 0);
      await att(2, 21); // 缺正文**且**有附件没下：仍只算一封
      await mail(3); // 正文齐
      await att(3, 31); // 缺附件
      await mail(4);
      await att(4, 41, path: '/tmp/a'); // 齐了
      await mail(5, hasFullBody: 0, isDel: 1); // 删掉的不补

      final pending = await db.mailDao.pendingSyncRefs('P');
      expect(pending.map((r) => r.emailId).toSet(), <int>{1, 2, 3});
      expect(
        pending.map((r) => r.emailId).toSet(),
        await panelIds(),
      );
    });

    test('只为这一台实例补（别的实例同号邮件不串）', () async {
      await mail(1, hasFullBody: 0);
      await mail(1, hasFullBody: 0, profile: 'Q');
      final pending = await db.mailDao.pendingSyncRefs('P');
      expect(pending, hasLength(1));
      expect(pending.single.profileId, 'P');
    });

    test('默认只看收信方向（待同步面板的口径）', () async {
      await mail(1, hasFullBody: 0, type: 0);
      await mail(2, hasFullBody: 0, type: 1);
      expect(
        (await db.mailDao.pendingSyncRefs('P')).map((r) => r.emailId).toSet(),
        <int>{1},
      );
      expect(
        (await db.mailDao.pendingSyncRefs('P', type: null))
            .map((r) => r.emailId)
            .toSet(),
        <int>{1, 2},
      );
    });

    test('新的在前，且受 limit 限制', () async {
      for (var id = 1; id <= 5; id++) {
        await mail(id, hasFullBody: 0);
      }
      final pending = await db.mailDao.pendingSyncRefs('P', limit: 3);
      expect(pending.map((r) => r.emailId).toList(), <int>[5, 4, 3]);
    });

    test('补完之后它就不再是候选（真库上走一遍落盘入口）', () async {
      await mail(1);
      await att(1, 11);
      expect(await db.mailDao.pendingSyncRefs('P'), hasLength(1));
      await db.mailDao.markAttachmentDownloaded('P', 11, localPath: '/tmp/a');
      expect(await db.mailDao.pendingSyncRefs('P'), isEmpty);
    });
  });
}
