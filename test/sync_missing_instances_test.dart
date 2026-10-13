import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_attachment.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「待同步」这两份清单的**取数口径**（真库，不画 widget）。
///
/// 用户报的「同步面板没有列出新实例 / 点了同步没反应」一路追下来就落在这几条
/// SQL 上：
///
/// 1. 清单是**按实例分开**的 —— 新实例一进来就有自己的一份，不会因为库里
///    已经有旧实例的行而被漏掉或算错；
/// 2. `pendingSyncRefs`（这一轮补哪些）与 `pendingSyncCount`（一共有多少）
///    必须是**同一个谓词**。两份走散时的表现是「清单里 2 行、点全部同步只补
///    1 行」，而界面上没有任何东西解释剩下那行为什么被略过 —— 这类 bug
///    查起来最费劲，所以在这里钉死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedProfile(String id) => db.profileDao.upsertProfile(
        Profile(
          id: id,
          baseUrl: 'https://$id.example.com/api',
          userId: 1,
          email: '$id@x.com',
        ),
      );

  Future<void> seedMail(
    String profileId,
    int emailId, {
    required bool hasFullBody,
  }) =>
      db.mailDao.upsertPage(<MailRow>[
        MailRow(
          profileId: profileId,
          emailId: emailId,
          accountId: 0,
          type: MailType.receive,
          subject: 's$emailId',
          hasFullBody: hasFullBody,
          createTime: DateTime.utc(2026, 1, 1).add(Duration(minutes: emailId)),
        ),
      ]);

  test('待同步清单按实例分开：新实例不会因为库里已有旧实例而漏掉', () async {
    await seedProfile('old');
    await seedProfile('new');
    // 旧的已同步，新的两封都缺正文。
    await seedMail('old', 1, hasFullBody: true);
    await seedMail('new', 1, hasFullBody: false);
    await seedMail('new', 2, hasFullBody: false);

    final body = await db.mailDao.watchMissingBody('new').first;
    expect(body.map((r) => r.emailId), <int>[2, 1]);
    expect(await db.mailDao.watchMissingBody('old').first, isEmpty);

    expect(await db.mailDao.pendingSyncCount('new'), 2);
    expect(await db.mailDao.pendingSyncCount('old'), 0);
  });

  test('pendingSyncRefs 与 pendingSyncCount 是同一个谓词：封数对得上', () async {
    await seedProfile('p');
    await seedMail('p', 1, hasFullBody: false); // 缺正文 → 在清单
    await seedMail('p', 2, hasFullBody: true); // 正文齐、无附件 → 不在清单
    await seedMail('p', 3, hasFullBody: true); // 正文齐 + 附件没下 → 在清单
    await db.mailDao.upsertAttachments('p', 3, <MailAttachment>[
      const MailAttachment(attId: 30, emailId: 3, key: 'k3', filename: 'a.pdf'),
    ]);

    final refs = await db.mailDao.pendingSyncRefs('p');
    expect(refs.map((r) => r.emailId).toSet(), <int>{1, 3});
    expect(
      await db.mailDao.pendingSyncCount('p'),
      refs.length,
      reason: '两份谓词走散 = 「清单里 2 行、点全部同步只补 1 行」',
    );
  });

  test('正文与附件都齐的行不出现在待同步里', () async {
    await seedProfile('p');
    await seedMail('p', 9, hasFullBody: true);
    expect(await db.mailDao.pendingSyncCount('p'), 0);
    expect(await db.mailDao.pendingSyncRefs('p'), isEmpty);
  });

  test('一封都没轮到时，「本来就没有」与「实例被跳过」分得开', () {
    expect(const SyncBatchResult().empty, isTrue);
    expect(
      const SyncBatchResult().blocked,
      isFalse,
      reason: '没有跳过的实例 → 结论是「本来就没有待同步的」',
    );
    expect(
      const SyncBatchResult(skippedInstances: 1).blocked,
      isTrue,
      reason: '有实例被跳过 → 那句「收不了信、请重登」才是对的',
    );
  });

  test('没有 token 时 syncOneMail 报 skipped，而不是「补了 0 封」', () async {
    await seedProfile('p');
    await seedMail('p', 1, hasFullBody: false);
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer(
      overrides: [
        bootstrapProvider
            .overrideWithValue(BootstrapData(db: db, tokens: TokenStore(), prefs: prefs)),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(profilesProvider, (_, _) {},
        fireImmediately: true);
    addTearDown(sub.close);
    for (var i = 0; i < 200; i++) {
      if (container.read(profilesProvider).value?.isNotEmpty ?? false) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final result = await container
        .read(manualSyncProvider.notifier)
        .sync(const MailRef(profileId: 'p', emailId: 1));
    expect(result, isNotNull);
    expect(
      result!.skipped,
      isTrue,
      reason: '没有 runtime / 没有 token → 这一封根本没被碰过，'
          '那种情况下说「已同步 0 封」是把用户往错的方向带',
    );
  });
}
