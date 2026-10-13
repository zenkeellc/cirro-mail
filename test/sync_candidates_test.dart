import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/providers/profile_providers.dart';

/// 这一组钉的是「**谁该被同步调度考虑**」这个名单。
///
/// 名单在三处被读：`SyncController.build`（决定开不开心跳、给哪些实例建
/// engine）、`ManualSyncController.syncAll`（「立即全部同步」遍历谁）、
/// `sync_status_screen.dart`（同步面板列哪几张卡）。以前它是一道
/// `userId > 0 && email.isNotEmpty` 的过滤，而 `ProfileRepository.create()`
/// 恰好把新实例留成 `userId = 0` / `email = ''` —— 于是「刚加了一台实例、
/// 还没走完登录」这一整段里，用户在设置页看得见它、在同步页却整台找不到，
/// 自动调度也完全不管它。用户报的「新添加一个实例后同步还是只处理旧的」
/// 就是这条。
///
/// 所以判据从「库里那两列写没写全」换成**「手里有没有可用的 token」**，
/// 而那件事由 `SyncScheduler._ensureEngineFor` / `SyncEngine.syncOnce`
/// 在预热之后判 —— 这一层只负责「名单要宽」，把不满足条件的实例也列出来，
/// 界面上显示成「需要重新登录 / 已停止」，而不是让整台实例凭空消失。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Profile profile({
    required String id,
    int userId = 0,
    String email = '',
    bool needsLogin = false,
  }) =>
      Profile(
        id: id,
        baseUrl: 'https://$id.example.com/api',
        userId: userId,
        email: email,
        needsLogin: needsLogin,
      );

  /// 一份「四种形态都占全」的实例表：
  /// - `logged-in`：正常的已登录实例；
  /// - `brand-new`：`create()` 之后、登录之前（userId = 0、email = 空）；
  /// - `token-but-no-user`：`login()` 第 3 步已经把 token 写进钥匙串、
  ///   第 4 步 `loginUserInfo` 还没回来/失败了 —— **能收信，但那两列还是空的**；
  /// - `needs-login`：401 后被落库标了 `needs_login`。
  final all = <Profile>[
    profile(id: 'logged-in', userId: 1, email: 'a@x.com'),
    profile(id: 'brand-new'),
    profile(id: 'token-but-no-user'),
    profile(id: 'needs-login', userId: 2, email: 'b@x.com', needsLogin: true),
  ];

  /// riverpod 的流是**懒订阅**的：`container.read` 一个没人听的
  /// `StreamProvider` 拿回来的永远是「加载中」。这不是被测行为的一部分，
  /// 但它是真的存在，所以显式挂上监听再等它发（抄
  /// `mailbox_totals_read_test.dart` 的做法）。
  Future<ProviderContainer> container() async {
    final c = ProviderContainer.test(
      overrides: [
        profilesProvider.overrideWith((ref) => Stream.value(all)),
      ],
    );
    final sub = c.listen(profilesProvider, (_, _) {}, fireImmediately: true);
    addTearDown(() {
      sub.close();
      c.dispose();
    });
    for (var i = 0; i < 200; i++) {
      if (c.read(syncCandidatesProvider).isNotEmpty) return c;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('等了 1 秒实例列表还是空的');
  }

  test('syncCandidates 一个不筛：新建 / 待重登的实例都在名单里', () async {
    final c = await container();

    expect(
      c.read(syncCandidatesProvider).map((p) => p.id),
      <String>['logged-in', 'brand-new', 'token-but-no-user', 'needs-login'],
      reason: '这道名单是同步调度的作用域，宽是**想要**的 —— '
          '窄了就等于新加的实例永远进不来（也永远没机会自愈）',
    );
  });

  test('activeProfiles 仍然只认已登录的实例', () async {
    final c = await container();

    // 聚合视图 / 侧栏邮箱树读的是它：把一台还没登录或已下线的实例的信
    // 混进聚合时间线，会让「这台实例下线了」这件事彻底看不见。
    expect(
      c.read(activeProfilesProvider).map((p) => p.id),
      <String>['logged-in'],
    );
  });

  test('两份名单的分工：candidates 是超集，active 是它的子集', () async {
    final c = await container();

    final candidates = c.read(syncCandidatesProvider).map((p) => p.id).toSet();
    final active = c.read(activeProfilesProvider).map((p) => p.id).toSet();
    expect(active.difference(candidates), isEmpty,
        reason: 'active 里出现 candidates 没有的实例 = 有实例能看却不能同步');
  });
}
