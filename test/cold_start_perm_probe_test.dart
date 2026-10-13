// 冷启动「补探权限」这条链路的端到端用例。
//
// 现场：`probe()` 只在登录时跑一次，而 `hasAccountDelete` / `hasAccountRename`
// 的 UI 判据是 `== ProbeState.available`（悲观）—— 一个**已经登录**的用户，
// 升级 App 之后冷启动，那两格还是 `unknown`，于是「删除 / 改名」两个菜单项
// 永远不出现，直到他重新登录一次。`UserInfo` 又不落库，「添加」走乐观判据
// 所以当场就有 —— 这个不对称正是本 bug 的样子。
//
// 这一组走**真链路**：`container.read(syncControllerProvider)` → 调度 → app
// 层 `probePermsInBackground` → `/my/loginUserInfo` → `applyPerms` 写库。
//
// 三个必须照做的细节，少一个都会让用例以**错误的原因**通过：
// 1. **Dio 必须由 `DioFactory.build` 建**（再换掉 `httpClientAdapter`）。
//    裸 `Dio(BaseOptions(...))` 没有 `EnvelopeInterceptor`，服务端回的
//    `{code:401}` 会被当成一个 HTTP 200 的正常响应体交给调用方，
//    `UserInfo.fromJson` 会从中抠出一个空的 userInfo（0 权限）→
//    `applyPerms` 把三格写成 `denied`，于是「401 走既有链路」那条会**假过**。
// 2. **token 预置在钥匙串 mock 里**（key 是 `token_<id>`）：冷启动时内存里
//    没有 token，补探必须先 `warmUp` —— 不预热就发请求会**不带 Authorization**，
//    换来一个凭空 401，把好端端的登录态标成「需重登」。第 1/2 条就靠这个前提。
// 3. **必须挂监听者、而且 `container.read(...)` 不够**：`ProviderContainer`
//    没有 Widget 树，`Notifier`/`StreamProvider` 都是**惰性**的 —— 只 read
//    一次只会把 notifier 建出来，`SyncController.build` 根本不会跑；
//    而 `profilesProvider` 是流，没人听时连第一帧都不推（`syncCandidates`
//    永远是空表，整个链路的入口条件是假的）。见 `_Harness.start` 里那两行
//    `container.listen(..., fireImmediately: true)`。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/network/dio_factory.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/instance_capabilities.dart';
import 'package:mail_app/data/repositories/capability_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const loginUserInfo = '/my/loginUserInfo';

  /// 带权限的那种 `/my/loginUserInfo` 响应。
  const permsBody = <String, Object?>{
    'code': 200,
    'data': <String, Object?>{
      'userId': 42,
      'email': 'admin@example.net',
      'permKeys': <String>['account:add', 'account:delete', 'email:send'],
    },
  };

  test('冷启动补探一次 /my/loginUserInfo，并把删除 / 改名写活', () async {
    final h = await _Harness.start(userInfoBody: permsBody);

    await h.settleUntil(
      () async =>
          (await h.caps.of(h.profileId)).hasAccountDelete ==
          ProbeState.available,
    );

    expect(
      h.countOf(loginUserInfo),
      1,
      reason: '冷启动要补一次权限（一个请求），否则老用户看不到删 / 改名',
    );
    final caps = await h.caps.of(h.profileId);
    expect(caps.hasAccountDelete, ProbeState.available);
    expect(caps.hasAccountRename, ProbeState.available);
    // 「添加」走乐观判据，本来就该有；这里顺带钉住它没被补探写坏。
    expect(caps.hasAccountAdd, ProbeState.available);
    expect(caps.hasSend, ProbeState.available);
  });

  test('补探不重复：profiles 流再推一次也还是只请求一次', () async {
    final h = await _Harness.start(userInfoBody: permsBody);
    await h.settleUntil(() => h.countOf(loginUserInfo) >= 1);
    expect(h.countOf(loginUserInfo), 1);

    // 把 `profiles` 表推一次（每轮同步成功都会发生这件事）——
    // `SyncController.build` 会重算，但 signature 与 `_permProbed` 两道闸
    // 都该拦住重复补探。
    await h.profiles.setLastSyncAt(h.profileId, DateTime.now().toUtc());
    await h.settleUntil(() => false, rounds: 30);

    expect(
      h.countOf(loginUserInfo),
      1,
      reason: '每个实例每次 App 运行最多补探一次 —— 心跳/流更新不该反复打它',
    );
  });

  test('补探失败（500）静默：不抛，三格保持 unknown', () async {
    final h = await _Harness.start(
      userInfoBody: const <String, Object?>{'code': 500, 'message': 'boom'},
    );
    await h.settleUntil(() => h.countOf(loginUserInfo) >= 1);
    await h.settleUntil(() => false, rounds: 30);

    // 「不抛」由用例本身不红来证 —— 这里钉的是**没有误写结论**。
    final caps = await h.caps.of(h.profileId);
    expect(caps.hasAccountDelete, ProbeState.unknown);
    expect(caps.hasAccountRename, ProbeState.unknown);
    expect(caps.hasAccountAdd, ProbeState.unknown);
  });

  test('401 交回既有链路：needs_login 落库', () async {
    final h = await _Harness.start(
      userInfoBody: const <String, Object?>{'code': 401, 'message': '未登录'},
    );
    await h.settleUntil(() async => (await h.profiles.find(h.profileId))!.needsLogin);
    await h.settleUntil(() => false, rounds: 30);

    expect(
      (await h.profiles.find(h.profileId))!.needsLogin,
      isTrue,
      reason: '补探没有绕开既有 401 收尾（RuntimeRegistry._onAuthExpired → 落库）',
    );
  });

  test('没有 token 时不打网络（hasToken 闸门）', () async {
    // 钥匙串里没有 token → 补探必须**在预热之后**判空返回，一个请求都不发。
    // 不预热就发请求的话，服务端会回 401，把一个「其实只是还没预热」的
    // 登录态凭空标成「需重登」。
    final h = await _Harness.start(token: null, userInfoBody: permsBody);
    await h.settleUntil(() => false, rounds: 30);

    expect(h.adapter.paths, isEmpty, reason: '没有 token 时一个请求都不该发出去');
  });
}

/// 一个只记 path / method、按 path 分发的假适配器。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.reply});

  /// 按 path 给响应体（`{code,message,data}` 信封）。
  final Object Function(String path) reply;

  final List<String> paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // `DioFactory` 的 baseUrl 带 `/api`，剥掉才是适配器层面的业务路径。
    final path = options.uri.path.replaceFirst('/api', '');
    paths.add(path);
    return ResponseBody.fromString(
      jsonEncode(reply(path)),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Harness {
  _Harness._({
    required this.db,
    required this.profiles,
    required this.caps,
    required this.adapter,
    required this.container,
    required this.registry,
    required this.authEvents,
    required this.profileId,
  });

  /// 造一个「已登录、token 在钥匙串里」的实例，然后按冷启动的方式读一次
  /// `syncControllerProvider`（它会把整条同步链路带起来）。
  static Future<_Harness> start({
    String? token = 'fake-jwt',
    required Object userInfoBody,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final tokens = TokenStore();
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);

    final created = await profiles.create(baseUrl: 'https://mail.example.net');
    await profiles.markLoggedIn(
      created.id,
      userId: 42,
      email: 'admin@example.net',
      userName: 'admin',
    );
    // token 预置在**钥匙串**里（内存缓存是冷的）—— 补探必须先 warmUp。
    if (token != null) {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        TokenStore.keyFor(created.id): token,
      });
    }

    final authEvents = AuthEvents();
    final adapter = _FakeAdapter(
      reply: (path) {
        if (path == '/my/loginUserInfo') return userInfoBody;
        // 调度器顺带跑的收信/邮箱列表：给一个空而合法的响应，
        // 别让它们抛出一堆与本用例无关的失败。
        if (path == '/account/list') {
          return const <String, Object?>{'code': 200, 'data': <Object?>[]};
        }
        return const <String, Object?>{'code': 200, 'data': null};
      },
    );

    final registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      onAuthExpired: (id) {
        unawaited(profiles.markNeedsLogin(id));
      },
      buildApiDio: (profile) => DioFactory.build(
        userApi: profile.baseUrl,
        profileId: profile.id,
        authEvents: authEvents,
        readToken: () => tokens.readCached(profile.id),
        readLanguage: () => 'zh',
      )..httpClientAdapter = adapter,
    );

    final container = ProviderContainer(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: tokens, prefs: prefs),
        ),
        onlineProvider.overrideWith((ref) => Stream<bool>.value(true)),
        runtimeRegistryProvider.overrideWith((ref) => registry),
      ],
    );

    final h = _Harness._(
      db: db,
      profiles: profiles,
      caps: CapabilityRepository(db),
      adapter: adapter,
      container: container,
      registry: registry,
      authEvents: authEvents,
      profileId: created.id,
    );

    // 收干净：容器一销毁，provider 的 onDispose 会关掉 registry 的订阅；
    // registry / authEvents 自己不归容器管，得手动收，否则挂着的订阅会跨用例。
    addTearDown(() async {
      container.dispose();
      await registry.dispose();
      await authEvents.dispose();
      await db.close();
    });

    // **两个监听者都必须挂，而且都要 `fireImmediately`**：`ProviderContainer`
    // 里没有 Widget 树，`Notifier` / `StreamProvider` 都是**惰性**的 ——
    // `container.read(syncControllerProvider)` 只会把 notifier 建出来，
    // 它的 `build()` 根本不会跑；而 `profilesProvider` 是流，没人听时连
    // 第一帧都不推（`syncCandidates` 永远是空表，整条链路的入口条件是假的）。
    // 真机上 `app_shell.dart` 一直听着这两个，所以这两行只在测试里才需要。
    //
    // 先让 `SyncController` 听上 `profiles` 流，再 `listen` 一次
    // `profilesProvider` 把那一帧推出来（`profiles` 表里本来就有这一行）。
    container.listen(syncControllerProvider, (_, _) {}, fireImmediately: true);
    container.listen(profilesProvider, (_, _) {}, fireImmediately: true);
    await container.read(profilesProvider.future);
    await h.settleUntil(() => false, rounds: 20);
    return h;
  }

  final AppDatabase db;
  final ProfileRepository profiles;
  final CapabilityRepository caps;
  final _FakeAdapter adapter;
  final ProviderContainer container;
  final RuntimeRegistry registry;
  final AuthEvents authEvents;
  final String profileId;

  int countOf(String path) => adapter.paths.where((p) => p == path).length;

  /// 反复清空事件队列直到 [done] 为真（或轮数用尽）。
  ///
  /// 一条链路要跨好几个 await（build → start → warmUp → 引擎 → HTTP →
  /// 写库），单次 `pumpEventQueue()` 不够。做成轮询而不是「睡固定几轮」：
  /// 慢就多等、快就不等。
  ///
  /// 每轮**两件事都做**：`pumpEventQueue()` 清微任务，一毫秒的真延时让
  /// drift 那条流（它内部走 timer）也能把新的一帧推出来。
  Future<void> settleUntil(
    FutureOr<bool> Function() done, {
    int rounds = 200,
  }) async {
    for (var i = 0; i < rounds; i++) {
      if (await done()) return;
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

}
