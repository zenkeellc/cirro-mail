import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/mailbox_totals_probe.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `MailboxTotalsProbe` 的**策略**（仓库那一层只发一次请求，策略全在这里）。
///
/// 三条都是「不做也不会有人发现」的：不判 TTL 就是每次展开都重打一遍请求
/// （几十个邮箱 × 每次展开）；不判在飞就是「展开、收起、再展开」打两遍；
/// 不判合并项就是替 `all:type:0` 白探一次，而那个 scope 归同步引擎管。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
      ({
        ProviderContainer container,
        _FakeRepo repo,
        AppDatabase db,
        Profile profile,
      })> harness({bool online = true}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final tokens = TokenStore();
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);
    final created = await profiles.create(baseUrl: 'https://x/api');
    await profiles.markLoggedIn(created.id, userId: 7, email: 'a@x.com', userName: 'a');
    final repo = _FakeRepo(
      db: db,
      profiles: profiles,
      prefs: prefs,
      tokens: tokens,
    );
    final container = ProviderContainer(overrides: [
      bootstrapProvider.overrideWithValue(
        BootstrapData(db: db, tokens: tokens, prefs: prefs),
      ),
      emailRepositoryProvider.overrideWithValue(repo),
      onlineProvider.overrideWith((ref) => Stream<bool>.value(online)),
    ]);
    final profile = (await profiles.find(created.id))!;
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    // 断网那一条要等流先发出 `false`，否则 `value` 还是 null，判据会
    // 走到「拿不到结论时按在线处理」那一支 —— 那样这条用例验的东西就变了。
    final sub = container.listen(onlineProvider, (_, _) {}, fireImmediately: true);
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);
    return (container: container, repo: repo, db: db, profile: profile);
  }

  List<MailboxFilter> boxes(String profileId, List<int> ids) => <MailboxFilter>[
        for (final id in ids) MailboxFilter(profileId: profileId, accountId: id),
      ];

  MailboxTotalsProbe probeOf(ProviderContainer c) =>
      c.read(mailboxTotalsProbeProvider);

  test('批量探测每个邮箱时，一个邮箱一个请求（不含合并项）', () async {
    final h = await harness();

    await probeOf(h.container).ensure(
      profile: h.profile,
      boxes: boxes(h.profile.id, <int>[1, 2, kAllMailboxes]),
    );

    // 合并项（`accountId == 0`）不探：那个 scope 是 `all:type:0`，同步引擎
    // 的冷启动基线一直在维护它；而且 `accountId = 0` 要服务端收到
    // `allReceive: 1` 才不会被当成「某个具体账户」。
    expect(h.repo.probed, <int>[1, 2]);
  });

  test('TTL 之内再展开不重探', () async {
    final h = await harness();

    await probeOf(h.container).ensure(
      profile: h.profile,
      boxes: boxes(h.profile.id, <int>[1]),
    );
    expect(h.repo.probed, <int>[1]);

    // 把「拿到总数」这件事落进库（真身是探测自己写的，这里假装它写过）。
    await h.db.mailDao.recordMailboxTotal(
      profileId: h.profile.id,
      scope: EmailRepository.mailboxScope(1, MailType.receive),
      total: 12,
      at: DateTime.now().toUtc(),
    );
    // 让上面那条流把新值推出来（TTL 判据读的是那条流）。
    final sub = h.container.listen(
      profileMailboxTotalsProvider(h.profile.id),
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(sub.close);
    await _until(
      () => h.container
              .read(profileMailboxTotalsProvider(h.profile.id))
              .value
              ?.isNotEmpty ??
          false,
      because: '总数没进流',
    );

    await probeOf(h.container).ensure(
      profile: h.profile,
      boxes: boxes(h.profile.id, <int>[1]),
    );
    expect(h.repo.probed, <int>[1], reason: 'TTL 之内不该再发一发');
  });

  test('同一个邮箱在两次展开之间只发一发（在飞去重）', () async {
    final h = await harness();
    h.repo.hold();

    final first = probeOf(h.container).ensure(
      profile: h.profile,
      boxes: boxes(h.profile.id, <int>[1]),
    );
    // 第一发还挂在半空中时再展开一次 —— 库里仍然没有这一行，光靠 TTL
    // 挡不住这个：收起再展开是一两秒内做得完的动作，而一个往返可能更久。
    final second = probeOf(h.container).ensure(
      profile: h.profile,
      boxes: boxes(h.profile.id, <int>[1]),
    );

    h.repo.release();
    await first;
    await second;

    expect(h.repo.probed, <int>[1]);
  });

  test('同一批里最多 3 个请求同时在飞', () async {
    final h = await harness();
    h.repo.hold();

    final pending = probeOf(h.container).ensure(
      profile: h.profile,
      boxes: boxes(h.profile.id, <int>[1, 2, 3, 4, 5, 6, 7]),
    );
    // 等第一批真的发出去（`hold` 让它们停在那儿）。
    await _until(() => h.repo.inFlight == 3, because: '第一批没发满 3 发');
    expect(h.repo.inFlight, 3, reason: '档位是 3，不该一次打 7 发');

    h.repo.release();
    await pending;
    expect(h.repo.probed, hasLength(7));
  });

  test('离线时整个跳过（探出来的只是给侧栏看的一个数字）', () async {
    final h = await harness(online: false);

    await probeOf(h.container).ensure(
      profile: h.profile,
      boxes: boxes(h.profile.id, <int>[1, 2]),
    );

    expect(h.repo.probed, isEmpty);
  });

  test('探测抛异常时不炸，而且下一次还能再探这个邮箱', () async {
    final h = await harness();
    h.repo.throwNext();

    // 不该抛出去 —— 这一格数字坏掉不该让整棵侧栏崩。
    await probeOf(h.container).ensure(
      profile: h.profile,
      boxes: boxes(h.profile.id, <int>[1]),
    );
    expect(h.repo.probed, <int>[1]);

    // 在飞那一项必须已经在 `finally` 里撤掉了，否则这个邮箱在本次会话里
    // 再也探不动了（后续的展开会被当成「已经有一发在飞」）。
    await probeOf(h.container).ensure(
      profile: h.profile,
      boxes: boxes(h.profile.id, <int>[1]),
    );
    expect(h.repo.probed, <int>[1, 1]);
  });
}

Future<void> _until(bool Function() ready, {required String because}) async {
  for (var i = 0; i < 200; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('等了 1 秒还没等到：$because');
}

/// 只记「被探了哪些 accountId」的仓库替身 —— 真身的请求形状另有
/// `mailbox_totals_probe_test.dart` 用假适配器钉。
///
/// 唯一被覆盖的方法就是 `probeMailboxTotal`，所以那个 registry 一次都不会
/// 被碰到；但还是要把真的建出来（它是 `final` 字段，构造器要它）。
class _FakeRepo extends EmailRepository {
  _FakeRepo({
    required super.db,
    required super.profiles,
    required super.prefs,
    required TokenStore tokens,
  }) : super(
          registry: _registry(tokens: tokens, prefs: prefs),
          capabilities: CapabilityRepository(db),
        );

  static RuntimeRegistry _registry({
    required TokenStore tokens,
    required PrefsStore prefs,
  }) =>
      RuntimeRegistry(authEvents: AuthEvents(), tokens: tokens, prefs: prefs);

  final List<int> probed = <int>[];

  /// 请求停在半空（在飞 / 并发两条用例要看这个瞬间）。
  bool _held = false;
  final List<Completer<void>> _gates = <Completer<void>>[];

  int get inFlight => _gates.where((g) => !g.isCompleted).length;

  bool _shouldThrow = false;

  void hold() => _held = true;

  void release() {
    _held = false;
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  void throwNext() => _shouldThrow = true;

  @override
  Future<int?> probeMailboxTotal({
    required Profile profile,
    required int accountId,
    int type = MailType.receive,
    bool allReceive = false,
    CancelToken? cancelToken,
  }) async {
    probed.add(accountId);
    if (_held) {
      final gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
    }
    if (_shouldThrow) {
      _shouldThrow = false;
      throw StateError('测试注入的异常');
    }
    return 1;
  }
}
