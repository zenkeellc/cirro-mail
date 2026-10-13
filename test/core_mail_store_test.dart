// `MailStore` 的 drift 适配器。
//
// 这层是扩展侧（搜索索引的灌水器）**唯一**的数据来源，所以它的契约比它看起来
// 重要：`pageAfter` 的键序、`updatedSince` 的水位线语义、`existingEmailIds` 的
// 对账用途。契约本身写在 `cirro_mail_ext` 的 `mail_store.dart` 里，这里逐条
// 对着**真 drift 库**验一遍。
//
// 另有一条是**刻意钉住的缺口**：`markRead` / `markStar` 这类局部 UPDATE 不刷
// `cachedAt`，所以 `updatedSince` 看不到它们。这一点必须有人写下来，
// 否则「顺手把它修好」（比如让 markRead 也刷 cachedAt）会让增量水位线
// 退化成全量重扫，而那是搜索卡顿的根因。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/core_mail_store.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late CoreMailStore store;

  const p1 = 'p1';
  const p2 = 'p2';

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = CoreMailStore(db);
  });

  tearDown(() => db.close());

  Future<void> put(
    int id, {
    String profileId = p1,
    String subject = '标题',
    String? bodyText,
    String? content,
    String code = '',
    int unread = UnreadState.unread,
    DateTime? cachedAt,
  }) =>
      db.mailDao.upsertPage(
        <MailRow>[
          MailRow(
            emailId: id,
            profileId: profileId,
            subject: subject,
            code: code,
            type: MailType.receive,
            unread: unread,
            text: bodyText,
            content: content,
            // `cachedAt` 是我们自己传的，用来把「水位线之前 / 之后」摆开。
            // `upsertPage` 的 `cachedAt` 是**整批**共用的（那是它的真实语义：
            // 一页同一时刻落库）。
          ),
        ],
        cachedAt: cachedAt,
      );

  group('pageAfter', () {
    test('按 (profileId, emailId) 严格升序', () async {
      await put(30);
      await put(10);
      await put(20);

      final page = await store.pageAfter();
      expect(page.map((m) => m.emailId), <int>[10, 20, 30]);
    });

    test('跨实例时先比 profileId', () async {
      await put(2, profileId: p1);
      await put(9, profileId: p2);
      await put(1, profileId: p1);

      final page = await store.pageAfter();
      expect(
        page.map((m) => '${m.profileId}/${m.emailId}'),
        <String>['p1/1', 'p1/2', 'p2/9'],
      );
    });

    /// 键是**二元组**：`emailId` 只在同一个实例内有序，所以「翻到下一页」
    /// 必须把上一页最后一行的两个值都带回来。
    ///
    /// 布置成最容易露馅的形状：p1 里那封的 id **比** p2 里最小的那封大。
    /// 只按 `emailId` 比大小的话，翻到第二页时 `id > 5` 会把 `p2/1` 整条跳过
    /// （它确实「小」，但它排在 p1/5 **后面**）—— 而它不会报错，只是少一封。
    test('翻页游标是二元组：不漏别的实例的行', () async {
      await put(5, profileId: p1);
      await put(1, profileId: p2);
      await put(9, profileId: p2);

      final first = await store.pageAfter(limit: 1);
      expect(first.single.profileId, p1);
      expect(first.single.emailId, 5);

      final second = await store.pageAfter(
        afterProfileId: first.single.profileId,
        afterEmailId: first.single.emailId,
        limit: 1,
      );
      expect(
        second.single.profileId,
        p2,
        reason: 'p1 里没有别的行了，下一页该轮到 p2 —— 只按 emailId 比大小'
            '会让 p2/1 被跳过',
      );
      expect(second.single.emailId, 1);

      final third = await store.pageAfter(
        afterProfileId: second.single.profileId,
        afterEmailId: second.single.emailId,
        limit: 1,
      );
      expect(third.single.emailId, 9);
    });

    test('profileId 过滤只看那一个实例', () async {
      await put(1, profileId: p1);
      await put(2, profileId: p2);
      final page = await store.pageAfter(profileId: p1);
      expect(page.map((m) => m.profileId), everyElement(p1));
    });

    /// 契约里明写：不存在的 key **不是错误**。
    ///
    /// 灌水器就是靠这个从「上次扫到哪儿」续跑的 —— 那些行可能早被删了。
    test('游标落在已不存在的行上不报错，返回它之后的那些', () async {
      await put(10);
      await put(20);
      final page = await store.pageAfter(afterProfileId: p1, afterEmailId: 5);
      expect(page.map((m) => m.emailId), <int>[10, 20]);
    });

    test('游标超过全部行时返回空', () async {
      await put(10);
      expect(
        await store.pageAfter(afterProfileId: p1, afterEmailId: 999),
        isEmpty,
      );
    });

    test('limit 生效', () async {
      for (var i = 1; i <= 5; i++) {
        await put(i);
      }
      expect((await store.pageAfter(limit: 2)).map((m) => m.emailId), <int>[1, 2]);
    });

    /// `withContent: false` 省掉的是**正文**，不是「整行都空」——
    /// 元信息（主题、发件人、验证码）照给。扩展的「只读元信息」那种扫法用它。
    test('withContent 为 false 时不带正文，其余字段照给', () async {
      await put(10, subject: '发票', bodyText: '正文内容', code: '123456');

      final withContent = (await store.pageAfter()).single;
      expect(withContent.bodyText, '正文内容');
      expect(withContent.subject, '发票');

      final without = (await store.pageAfter(withContent: false)).single;
      expect(without.bodyText, isNull);
      expect(without.content, isNull);
      expect(without.subject, '发票');
      expect(without.code, '123456');
    });

    /// 字段映射本身也要钉 —— 适配器写错一个字段名，症状是「搜索里搜发件人
    /// 搜不到」这种极难定位的事。
    test('字段映射：一行满配的行原样折过来', () async {
      await db.mailDao.upsertPage(<MailRow>[
        MailRow(
          emailId: 7,
          profileId: p1,
          accountId: 3,
          mailboxEmail: 'box@example.com',
          subject: '你的验证码',
          code: '839201',
          sendEmail: 'noreply@shop.com',
          name: 'Shop',
          toEmail: 'me@example.com',
          toName: '我',
          type: MailType.receive,
          unread: UnreadState.unread,
          isStar: 1,
          text: '验证码 839201',
          content: '<p>验证码 839201</p>',
          createTime: DateTime.utc(2026, 10, 1, 8),
          // 正常来路是 `MailRow.fromJson`（服务端载荷里带 `content` 时它自己
          // 置 true）；这里手工构造，得显式给。
          hasFullBody: true,
        ),
      ]);

      final mail = (await store.pageAfter()).single;
      expect(mail.profileId, p1);
      expect(mail.emailId, 7);
      expect(mail.accountId, 3);
      expect(mail.mailboxEmail, 'box@example.com');
      expect(mail.subject, '你的验证码');
      expect(mail.code, '839201');
      expect(mail.sendEmail, 'noreply@shop.com');
      expect(mail.name, 'Shop');
      expect(mail.toEmail, 'me@example.com');
      expect(mail.toName, '我');
      expect(mail.type, LocalMail.kTypeReceive);
      expect(mail.unread, LocalMail.kUnread);
      expect(mail.isStar, 1);
      expect(mail.bodyText, '验证码 839201');
      expect(mail.content, '<p>验证码 839201</p>');
      // drift 的 `DateTimeColumn` 存的是 epoch、读回来是**本地**时间 ——
      // 比时刻，不比时区表示。
      expect(mail.sentAt!.toUtc(), DateTime.utc(2026, 10, 1, 8));
      expect(mail.hasFullBody, isTrue);
      expect(mail.cachedAt, isNotNull);
    });

    /// 真机库实测：`full=1` 下服务端有时**只给 HTML、不给 text**
    /// （106 行里 28 行如此）。所以「有 `content`、`bodyText` 为 null」
    /// 是必须原样传出去的一种形态 —— 扩展那边靠它决定要不要剥标签。
    test('只有 HTML 没有纯文本时，bodyText 为 null 而 content 在', () async {
      await put(10, content: '<p>只有 HTML</p>');
      final mail = (await store.pageAfter()).single;
      expect(mail.bodyText, isNull);
      expect(mail.content, '<p>只有 HTML</p>');
      expect(mail.hasAnyBody, isTrue);
    });
  });

  group('count', () {
    test('没有实例过滤时数全部', () async {
      await put(1, profileId: p1);
      await put(2, profileId: p1);
      await put(3, profileId: p2);
      expect(await store.count(), 3);
    });

    test('带实例过滤时只数那一个', () async {
      await put(1, profileId: p1);
      await put(2, profileId: p2);
      expect(await store.count(profileId: p1), 1);
    });

    test('空库是 0', () async {
      expect(await store.count(), 0);
    });
  });

  group('existingEmailIds', () {
    test('只回还在的那些', () async {
      await put(1);
      await put(2);
      expect(await store.existingEmailIds(p1, <int>[1, 2, 3]), <int>{1, 2});
    });

    test('空入参不发查询、返回空集', () async {
      await put(1);
      expect(await store.existingEmailIds(p1, const <int>[]), isEmpty);
    });

    test('不跨实例捞（同 id 的不同实例不算数）', () async {
      await put(5, profileId: p1);
      expect(await store.existingEmailIds(p2, <int>[5]), isEmpty);
    });
  });

  group('updatedSince', () {
    test('按 cachedAt 升序，且只给水位线之后的', () async {
      await put(1, cachedAt: DateTime.utc(2026, 10, 1));
      await put(2, cachedAt: DateTime.utc(2026, 10, 3));
      await put(3, cachedAt: DateTime.utc(2026, 10, 2));

      final rows = await store.updatedSince(DateTime.utc(2026, 10, 1));
      expect(rows.map((m) => m.emailId), <int>[3, 2]);
    });

    test('水位线之外的（更早的）不出现', () async {
      await put(1, cachedAt: DateTime.utc(2026, 9, 1));
      expect(await store.updatedSince(DateTime.utc(2026, 10, 1)), isEmpty);
    });

    test('带实例过滤', () async {
      await put(1, profileId: p1, cachedAt: DateTime.utc(2026, 10, 5));
      await put(2, profileId: p2, cachedAt: DateTime.utc(2026, 10, 5));
      final rows = await store.updatedSince(
        DateTime.utc(2026, 10, 1),
        profileId: p2,
      );
      expect(rows.map((m) => m.profileId), <String>[p2]);
    });

    /// **刻意钉住的缺口**（契约里写过，见 `mail_store.dart` 的
    /// `MailStore.updatedSince`）：
    ///
    /// `markRead` / `markStar` 是局部 `UPDATE`，不刷 `cachedAt`。所以批量标已读
    /// 不会让整库看起来「都变了」—— 这正是增量水位线成立的前提。
    ///
    /// 反过来，谁要是「顺手」让 `markRead` 也写 `cachedAt`，增量就退化成
    /// 全量重扫：每读一封信都触发一次索引重写。这条用例会在那时红。
    test('markRead / markStar 不算「更新过」', () async {
      final past = DateTime.utc(2026, 1, 1);
      await put(1, cachedAt: past);

      final since = past.add(const Duration(seconds: 1));
      expect(await store.updatedSince(since), isEmpty);

      await db.mailDao.markRead(
        <MailRef>[const MailRef(profileId: p1, emailId: 1)],
        read: true,
      );
      await db.mailDao.markStar(
        const MailRef(profileId: p1, emailId: 1),
        starred: true,
      );

      expect(
        await store.updatedSince(since),
        isEmpty,
        reason: '局部 UPDATE 不刷 cachedAt —— 这是水位线成立的前提，不是 bug',
      );
      // 但那些变化确实落库了：拿的是同一行，只是水位线看不见它。
      final mail = (await store.pageAfter()).single;
      expect(mail.unread, LocalMail.kRead);
      expect(mail.isStar, 1);
    });

    /// `upsertFull`（补正文）**会**刷 `cachedAt` —— 这正是「补齐后再搜」
    /// 那条回路能闭合的原因。
    test('upsertFull 会刷 cachedAt，于是水位线捞得到它', () async {
      final past = DateTime.utc(2026, 1, 1);
      await put(1, cachedAt: past);
      final since = past.add(const Duration(seconds: 1));
      expect(await store.updatedSince(since), isEmpty);

      await db.mailDao.upsertFull(
        MailRow(
          emailId: 1,
          profileId: p1,
          subject: '标题',
          content: '<p>补来的正文</p>',
        ),
      );

      final rows = await store.updatedSince(since);
      expect(rows.map((m) => m.emailId), <int>[1]);
      expect(rows.single.content, '<p>补来的正文</p>');
    });
  });

  group('changes', () {
    /// 适配器把这个口原样接到核心的发布点上 —— 不另开一条自己的流。
    /// 两条流的话，`CoreMailStore` 与 `MailDao` 会各自发一份，订阅方收到两次。
    test('与 mailStoreChanges 是同一个流（发一次收到一次）', () async {
      final seen = <MailStoreEvent>[];
      final sub = store.changes().listen(seen.add);
      addTearDown(sub.cancel);

      await put(1);
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
    });
  });
}
