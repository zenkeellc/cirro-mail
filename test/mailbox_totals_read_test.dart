import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 侧栏那两格数字的**读取链路**（provider 层，不画 widget）。
///
/// 这一层最容易出的错是把「未知」和「零」混起来：
/// - `profileMailboxTotalsProvider` **只收 `remoteTotalAt != null` 的行**，
///   查不到就等于未知。少了这个过滤，一个 `remote_total = 0` 的
///   「还没探过」会被当成「空邮箱」，侧栏就会显示 `0` 而不是 `—`；
/// - `mailboxTotalProvider` 对合并项（`accountId == kAllMailboxes`）必须
///   返回 `null` —— 那个 scope 是 `all:type:0`，不是「这个邮箱的总数」；
/// - `instanceTotalProvider` 读的是 `all:type:0` 那一行，**不是**各邮箱相加
///   （`allReceive` 口径覆盖归属未知的那些，相加必然对不上）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profile = 'p1';
  const aggregateScope = 'all:type:0';

  /// riverpod 的流是**懒订阅**的：`container.read` 一个没人听的
  /// `StreamProvider` 拿回来的永远是「加载中」，而 `mailboxTotalsMapProvider`
  /// 是拿 `activeProfilesProvider`（也是流）乘出来的 —— 不挂监听就整个是空的。
  /// 这不是被测行为的一部分，但它是真的存在，所以显式挂上并等它发。
  Future<void> until(bool Function() ready, {required String because}) async {
    for (var i = 0; i < 200; i++) {
      if (ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('等了 1 秒还没等到：$because');
  }

  Future<({ProviderContainer container, AppDatabase db})> harness() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    // 实例表要有一行：`mailboxTotalsMapProvider` 是按
    // `activeProfilesProvider` 把逐实例那条流乘出来的，没有实例就整张空。
    await db.profileDao.upsertProfile(const Profile(
      id: profile,
      baseUrl: 'https://x/api',
      email: 'a@x.com',
      userId: 7,
    ));
    final container = ProviderContainer(overrides: [
      bootstrapProvider.overrideWithValue(
        BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
      ),
    ]);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    // 挂上监听（见 [until]），并等实例列表先到齐。两条订阅是
    // `mailboxTotalsMapProvider` 的全部输入：逐实例的总数流 + 实例列表。
    final subs = <ProviderSubscription<Object?>>[
      container.listen(profileMailboxTotalsProvider(profile), (_, _) {},
          fireImmediately: true),
      container.listen(profilesProvider, (_, _) {}, fireImmediately: true),
    ];
    addTearDown(() {
      for (final sub in subs) {
        sub.close();
      }
    });
    await until(
      () => container.read(activeProfilesProvider).isNotEmpty,
      because: '实例列表一直是空的',
    );
    return (container: container, db: db);
  }

  int? mailboxTotal(ProviderContainer c, int accountId) => c.read(
        mailboxTotalProvider((profileId: profile, accountId: accountId)),
      );

  test('没探过的 scope 查不到 = 未知（不是 0）', () async {
    final h = await harness();

    // 库里连这一行都没有。
    expect(mailboxTotal(h.container, 1), isNull);
    expect(h.container.read(instanceTotalProvider(profile)), isNull);
  });

  test('探过之后（含 total = 0）查得到，0 也是真值', () async {
    final h = await harness();

    await h.db.mailDao.recordMailboxTotal(
      profileId: profile,
      scope: EmailRepository.mailboxScope(1, MailType.receive),
      total: 0,
      at: DateTime.utc(2026, 10, 12, 9),
    );
    await until(
      () => h.container
          .read(profileMailboxTotalsProvider(profile))
          .value!
          .isNotEmpty,
      because: '总数那一格一直是未知',
    );

    // 0 这条**是结论**：查得到，而且就是 0（不是 null）。
    expect(mailboxTotal(h.container, 1), 0);
  });

  test('合并项不借邮箱口径：accountId = 0 永远返回 null', () async {
    final h = await harness();

    // 就算库里真有一个 `mailbox:0:type:0` 的行，合并项也不许读它 ——
    // 那是「accountId 恰好为 0 的某个邮箱」，与「这个实例的全部邮箱」是
    // 两件事（后者的 scope 是 `all:type:0`）。
    await h.db.mailDao.recordMailboxTotal(
      profileId: profile,
      scope: 'mailbox:0:type:0',
      total: 42,
      at: DateTime.utc(2026, 10, 12, 9),
    );
    await until(
      () => h.container
          .read(profileMailboxTotalsProvider(profile))
          .value!
          .containsKey('mailbox:0:type:0'),
      because: '那一行没进流',
    );

    expect(mailboxTotal(h.container, kAllMailboxes), isNull);
  });

  test('实例合计读的是 all:type:0 那一行，不跟各邮箱相加', () async {
    final h = await harness();

    await h.db.mailDao.recordMailboxTotal(
      profileId: profile,
      scope: EmailRepository.mailboxScope(1, MailType.receive),
      total: 3,
      at: DateTime.utc(2026, 10, 12, 9),
    );
    await h.db.mailDao.recordMailboxTotal(
      profileId: profile,
      scope: EmailRepository.mailboxScope(2, MailType.receive),
      total: 4,
      at: DateTime.utc(2026, 10, 12, 9),
    );
    await h.db.mailDao.recordMailboxTotal(
      profileId: profile,
      scope: aggregateScope,
      total: 99,
      at: DateTime.utc(2026, 10, 12, 9),
    );
    await until(
      () => h.container.read(instanceTotalProvider(profile)) != null,
      because: '实例合计没跟上',
    );

    // 3 + 4 = 7 会「看着也挺像」，但真值是 99 —— 相加那条路上，
    // 归属未知（account_id = 0）的收件一封都算不进去。
    expect(h.container.read(instanceTotalProvider(profile)), 99);
  });

  test('别的实例的数据不会串进来', () async {
    final h = await harness();

    // 先把 p1 的一行写进去，作为「流确实在发」的锚点 —— 否则「p2 的数据
    // 没串进来」这条断言在流压根还没发的时候也会绿，等于什么都没验。
    await h.db.mailDao.recordMailboxTotal(
      profileId: profile,
      scope: EmailRepository.mailboxScope(9, MailType.receive),
      total: 1,
      at: DateTime.utc(2026, 10, 12, 9),
    );
    await h.db.mailDao.recordMailboxTotal(
      profileId: 'p2',
      scope: EmailRepository.mailboxScope(1, MailType.receive),
      total: 7,
      at: DateTime.utc(2026, 10, 12, 9),
    );
    await until(
      () => mailboxTotal(h.container, 9) != null,
      because: 'p1 的锚点没进流',
    );

    expect(mailboxTotal(h.container, 1), isNull);
  });
}
