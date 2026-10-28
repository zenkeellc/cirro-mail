import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/network/auth_events.dart';
import 'package:mail_app/core/network/dio_factory.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/data/repositories/email_repository.dart';
import 'package:mail_app/data/repositories/profile_repository.dart';
import 'package:mail_app/features/mail_list/mail_list_view.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/instance/runtime_registry.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:mail_app/providers/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 收件箱底部「还有 N 封未同步 · 点击继续加载」的回归测试。
///
/// 用户报的现象是：点这一行之后，邮件并没有同步进客户端。根因有三层，
/// 每一层都能单独让这一下白点：
///
/// 1. **列表窗口写死 200 条**（`watchMailboxSet` / `watchStarred` 的默认
///    limit）。`loadOlder` 把更旧的一页写进库，它们按 `createTime desc` 正好
///    落在第 200 行之外 —— 库长了、屏幕一动不动。修法：窗口随加载增长
///    （`mailListWindowProvider` + `MailListController.loadMore`）。
/// 2. **`backfillDone` 是粘的快照**。置位之后 `loadMore` 第一句就早退，而占位
///    行仍旧渲染成可点的 `InkWell` —— 点下去零请求、零反馈。修法：用户主动
///    点时传 `retryExhausted: true`，重新给服务端一次机会（顺手把
///    `remote_total` 刷成真值，假数字随之消失），并且加载中有转圈。
/// 3. **`remote_total` 是快照**。常规同步走 `/email/latest`（响应里没有
///    total），删信也不更新它；占位数字 = `remote_total − 本地计数`，于是
///    本地删过信之后会凭空多出「未同步」。修法：打开列表 / 下拉刷新 / 删信
///    之后重探一次（TTL `AppDefaults.mailboxTotalTtl`），并且以
///    `remoteTotalAt != null` 作为「已知」的唯一判据（total = 0 也是一条
///    正经结论）。
///
/// 另外钉一条口径 bug：单邮箱请求过去「allReceive=false 就不带这个参数」，
/// 服务端会回落成该账户的「合并接收」开关，于是翻回来的是**整个账号**的邮件
/// 与总数。现在一律显式传 0/1（见 `EmailApi.list`）。
///
/// 内存库 + 假 `HttpClientAdapter`，形状照 `mailbox_totals_probe_test.dart`
/// 的 `_Harness`：不发真请求，但走真的 `EmailRepository` / 真的 drift。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 每个用例一个全新的内存库是有意的；drift 的「多实例」警告只针对共享
  // QueryExecutor 的情形，这里每个用例各自持有一份，不适用。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // 删信会顺手清磁盘上的附件目录（`EmailRepository.delete` 的 `onDiskPurge`），
  // 那条路会问 path_provider 要临时目录 —— 单测里没有插件实现，给个假的。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp',
  );

  late _Harness h;

  setUp(() async => h = await _Harness.create());
  tearDown(() async => h.dispose());

  // ---------------------------------------------------------------- ① 基线

  test('① 基线：120 封 / 本地 50 → 占位 70；点两次拉完，数字归零', () async {
    final q = h.query;
    h.serveMailbox(_ids(1, 120), total: 120);
    await h.seedLocal(first: 71, last: 120, total: 120, cursor: 120);

    final probe = _Placeholder(h.container, q);
    addTearDown(probe.close);
    await probe.untilValue(70);
    final controller = h.controller(q);
    expect(controller.hasMore, isTrue);

    final visibleBefore = await h.visibleIds(q, expectLength: 50);
    expect(visibleBefore.toSet(), _idSet(71, 120));

    // ---- 第一次点 ----
    await controller.loadMore();

    expect(h.adapter.listRequests, hasLength(1));
    final first = h.adapter.listRequests.single.query;
    expect(h.adapter.listRequests.single.method, 'GET');
    expect(first['accountId'], 3);
    expect(first['type'], MailType.receive);
    expect(first['size'], 50);
    // 游标 = 本地最老那一封（`lt(emailId)`，服务端取更旧的）。
    expect(first['emailId'], 71);
    // timeSort=0 = 往下翻旧；不是往上翻新。
    expect(first['timeSort'], 0);
    // 单邮箱请求**必须显式**带 0：不带的话服务端会回落成账户的「合并接收」
    // 开关，返回整个账号的页（见 `EmailApi.list` 的注释）。
    expect(first['allReceive'], 0);
    // prefs.prefetchFull 默认 true → full=1。
    expect(first['full'], 1);

    await probe.untilValue(20);
    expect(await h.localCount(), 100, reason: '本地 50 + 服务端 50');
    expect(await h.visibleIds(q, expectLength: 100), hasLength(100));

    // ---- 第二次点：服务端只剩 20 封更旧的，这一页不满 → 到底 ----
    await controller.loadMore();
    expect(h.adapter.listRequests, hasLength(2));
    expect(h.adapter.listRequests[1].query['emailId'], 21);

    await probe.untilValue(0);
    expect(await h.localCount(), 120);
    expect(await h.visibleIds(q, expectLength: 120), hasLength(120));
    expect(controller.hasMore, isFalse, reason: '不满一页 = 到底了');

    final state = (await h.syncState())!;
    expect(state.backfillDone, isTrue);

    // ---- 滚动触发的第三次：已经到底，不该再发请求 ----
    await controller.loadMore();
    expect(h.adapter.listRequests, hasLength(2),
        reason: '滚到底后不重复发「已经到底」的请求（用户主动点另算，见③）');
  });

  // ------------------------------------------------------ ② 窗口随加载增长

  test('② 本地 ≥200 封时，继续加载要让新邮件真的出现在列表里，而不是只长库', () async {
    final q = h.query;
    // 服务端 300 封；本地已缓存最新 250 封（51..300）。
    h.serveMailbox(_ids(1, 300), total: 300);
    await h.seedLocal(first: 51, last: 300, total: 300, cursor: 300);

    final probe = _Placeholder(h.container, q);
    addTearDown(probe.close);
    await probe.untilValue(50);

    final visibleBefore = await h.visibleIds(q, expectLength: 200);
    expect(visibleBefore, hasLength(200),
        reason: '窗口默认 200 条（watchMailboxSet 的默认 limit）');
    expect(visibleBefore.toSet(), _idSet(101, 300),
        reason: '按 createTime desc 取最新 200');

    final controller = h.controller(q);
    final requestsBefore = h.adapter.listRequests.length;

    // ---- 第一次点：窗口外面还有 50 封本地已缓存的邮件 ----
    // 这一下**不该发请求**：先把本地已经有的放出来，用户立刻多看到一页。
    await controller.loadMore();
    expect(h.adapter.listRequests.length, requestsBefore,
        reason: '先放本地窗口，不该花一个网络请求');
    final visibleAfterReveal = await h.visibleIds(q, expectLength: 250);
    expect(visibleAfterReveal, hasLength(250),
        reason: '窗口长一页 → 本地已缓存的 51..300 全部可见');
    expect(visibleAfterReveal.toSet(), _idSet(51, 300));

    // ---- 第二次点：本地已经放完，这才去服务端拉更旧的一页 ----
    await controller.loadMore();
    expect(h.adapter.listRequests.length, requestsBefore + 1);
    expect(h.adapter.listRequests.last.query['emailId'], 51);

    // 关键断言：写进库的 1..50 必须**看得见**（以前它们落在 200 行窗口外）。
    await probe.untilValue(0);
    final visibleAfterFetch = await h.visibleIds(q, expectLength: 300);
    expect(visibleAfterFetch, hasLength(300),
        reason: '窗口跟着长到装下新拉下来的 50 封');
    expect(visibleAfterFetch.toSet(), _idSet(1, 300),
        reason: '库里有 300 封，列表就该能看到 300 封');
  });

  // ------------------------------------------- ③ backfillDone 之后仍能推进

  test('③ 已经翻到底（backfillDone）时用户主动点：真的发请求、数字往下掉', () async {
    final q = h.query;
    // 服务端明明还有 1..70 更旧的，但库里记着「已经翻到底了」。
    h.serveMailbox(_ids(1, 120), total: 120);
    await h.seedLocal(
      first: 71,
      last: 120,
      total: 120,
      cursor: 120,
      backfillDone: true,
    );

    final controller = h.controller(q);
    // `_hydrate()` 是构造函数里 unawaited 起的，等它把 backfillDone 读回来。
    await h.until(() => !controller.hasMore,
        because: '_hydrate 没把 backfill_done 读回 _hasMore');

    final probe = _Placeholder(h.container, q);
    addTearDown(probe.close);
    await probe.untilValue(70);

    final localBefore = await h.localCount();
    final requestsBefore = h.adapter.listRequests.length;

    // 用户主动点了底部那一行（widget 层在 onTap 里就是这么调的）。
    await controller.loadMore(retryExhausted: true);

    expect(h.adapter.listRequests.length, requestsBefore + 1,
        reason: '到底之后用户主动点也要再问服务端一次，不能零请求早退');
    expect(h.adapter.listRequests.last.query['emailId'], 71,
        reason: '游标仍然是本地最老那一封');

    await probe.untilValue(20);
    expect(await h.localCount(), localBefore + 50, reason: '这一页真的写进库了');
    expect(await h.visibleIds(q, expectLength: localBefore + 50),
        hasLength(localBefore + 50),
        reason: '而且真的显示出来了');
  });

  testWidgets('③b 占位行是可点的 InkWell，点一下会发请求、数字跟着变', (tester) async {
    final q = h.query;
    h.serveMailbox(_ids(1, 120), total: 120);
    // 本地只留 2 封，占位行落在首屏（不必滚动）。
    await h.seedLocal(
      first: 119,
      last: 120,
      total: 120,
      cursor: 120,
      backfillDone: true,
    );

    // 先在**同一个 container** 上把 controller 建好、等 hydrate 完 ——
    // 否则 `_primeFirstPage`（首帧后那一跳）会抢在 hydrate 之前发一次请求，
    // 把「打开页面就有请求」和「点击有请求」混在一起。
    //
    // `testWidgets` 的 zone 里 `Future.delayed` 走的是**假时钟**，不 pump 就
    // 永远不醒 —— 所以这里必须用 `runAsync` 才等得到 drift 的那个查询。
    final controller = h.controller(q);
    await tester.runAsync(
      () => h.until(() => !controller.hasMore, because: 'hydrate 没完成'),
    );
    expect(h.adapter.listRequests, isEmpty, reason: '打开页面时就已经知道到底了');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: MailListView(query: q)),
      ),
    ));
    // 不用 `pumpAndSettle`：列表里挂着 drift 的流，取消/重订阅会一直排微任务，
    // settle 不下来的风险比这样有界地推几帧大。
    await _pumpFrames(tester);

    final label = find.text('还有 118 封未同步 · 点击继续加载');
    expect(label, findsOneWidget);
    // `canAdvance == true` 时这一行是 InkWell（否则是 Padding，没有 onTap）。
    expect(find.ancestor(of: label, matching: find.byType(InkWell)),
        findsWidgets,
        reason: '单邮箱 → 渲染成可点的 InkWell');

    await tester.tap(label);
    await _pumpFrames(tester, frames: 40);

    expect(h.adapter.listRequests, hasLength(1),
        reason: '用户真点了一下：请求发出去了');
    expect(h.adapter.listRequests.single.query['emailId'], 119);

    // 本地 +50 → 剩余 68；这一页拉满了，所以还能继续翻（不会变成「没有更多了」）。
    // 注意：占位行现在被 52 行邮件挤到屏幕外了（懒构建），所以这里断言
    // provider 的值而不是 find.text —— 屏幕上那一行由同一个值渲染。
    final counter = _Placeholder(h.container, q);
    addTearDown(counter.close);
    await tester.runAsync(() => counter.untilValue(68));

    // 拆树再推一帧：drift 的流在取消订阅时排了零延时定时器。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 5));
  });

  // ------------------------------------------- ④ total 写回与流的重发时机

  test('④ 翻页会把 total 写回（列级更新 + 新时间戳），watchSyncState 会重发', () async {
    final q = h.query;
    // 服务端说还有 120 封，但没有比本地更旧的页（返回空页）。
    h.serveMailbox(const <int>[], total: 120);
    // 时间戳比「刚刚」早两分钟：在 TTL 之内（不会触发打开列表时的重探），
    // 又足以让「翻页写回的新时间戳」严格晚于它 —— drift 的 DateTime 落库
    // 只到秒，同一秒里比较不出先后。
    await h.seedLocal(
      first: 71,
      last: 120,
      total: 120,
      cursor: 120,
      totalAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
    );

    final probe = _Placeholder(h.container, q);
    addTearDown(probe.close);
    await probe.untilValue(70);

    final before = (await h.syncState())!;
    expect(before.remoteTotal, 120);
    expect(before.remoteTotalAt, isNotNull);
    expect(before.backfillDone, isFalse);

    // 直接盯 `watchSyncState` 这条原始 drift 流：问的是「写同值 total 会不会
    // 重发」，那就别让 riverpod 那层（它会对**相等**的 AsyncData 去重）掺进来。
    final raw = <DbSyncState?>[];
    final rawSub = h.db.mailDao
        .watchSyncState(h.profile.id, h.scope)
        .listen(raw.add);
    addTearDown(rawSub.cancel);
    await h.until(() => raw.isNotEmpty, because: 'watchSyncState 首个值没到');
    final rawBefore = raw.length;

    final controller = h.controller(q);
    await controller.loadMore();

    final after = (await h.syncState())!;
    expect(after.remoteTotal, 120, reason: '服务端还是 120，写的是同值');
    expect(after.remoteTotalAt!.isAfter(before.remoteTotalAt!), isTrue,
        reason: '翻页的 _saveRemoteTotal 会带上新时间戳');
    // 翻页不碰游标，只碰 remote_total / remote_total_at / backfill_done。
    expect(after.cursorEmailId, 120);
    expect(after.oldestEmailId, 71);
    expect(after.backfillDone, isTrue, reason: '空页 = 翻到底');

    // total 两列被重写 → watchSyncState 会重发（先新时间戳、再 backfill_done）。
    await h.until(() => raw.length > rawBefore,
        because: 'remote_total_at 变了但 watchSyncState 没重发');
    expect(raw.last!.remoteTotal, 120);
    expect(raw.last!.remoteTotalAt!.isAfter(before.remoteTotalAt!), isTrue);
    expect(raw.last!.backfillDone, isTrue);

    // 数字没变（total 与本地计数都没变），所以屏幕上的 70 不该被算成别的值。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(probe.value, 70);
  });

  // ---------------------------------- ⑤ 单邮箱请求显式 allReceive=0（口径）

  test('⑤ 账户开了「合并接收」时，单邮箱请求仍只看这个邮箱', () async {
    final q = h.query;
    // 这个账户在服务端开了「合并接收」（`all_receive = 1`）：过去 App 不带
    // `allReceive` 参数，worker 会回落成账户开关，返回**整个账号**的邮件
    // （行里带各自的 accountId，这里模拟成 4）。现在必须显式传 0。
    h.serveMailbox(_ids(21, 70), total: 120, mergedAccount: 4);
    await h.seedLocal(first: 71, last: 120, total: 120, cursor: 120);

    final probe = _Placeholder(h.container, q);
    addTearDown(probe.close);
    await probe.untilValue(70);

    final controller = h.controller(q);
    await controller.loadMore();

    expect(h.adapter.listRequests, hasLength(1));
    expect(h.adapter.listRequests.single.query['allReceive'], 0,
        reason: '显式 0 才不会让服务端回落成「整账号」口径');
    // 服务端按 0 口径返回本邮箱的页 → 行挂 account 3，本地计数真的涨。
    expect(
      await h.db.mailDao.countMailbox(h.profile.id, 3, type: MailType.receive),
      100,
      reason: '拉回来的 50 封属于这个邮箱',
    );
    expect(
      await h.db.mailDao.countMailbox(h.profile.id, 4, type: MailType.receive),
      0,
      reason: '不该把别的邮箱的信算进本列表的本地计数',
    );
    await probe.untilValue(20);

    // ---- 第二次点：游标真的往前走了（以前会重发同一个 emailId） ----
    await controller.loadMore();
    expect(h.adapter.listRequests, hasLength(2));
    expect(h.adapter.listRequests[1].query['emailId'], 21,
        reason: 'oldestEmailIdOf(account 3) 跟着本地数据推进了');
  });

  // --------------------------------------------- ⑥ 未读视图不给假数字

  test('⑥ 未读视图不显示「还有 N 封未同步」（分子分母都不是未读口径）', () async {
    h.serveMailbox(_ids(1, 120), total: 120);
    await h.seedLocal(first: 71, last: 120, total: 120, cursor: 120);

    final unread = h.unreadQuery;
    final probe = _Placeholder(h.container, unread);
    addTearDown(probe.close);

    await h.until(() => probe.emissions.isNotEmpty,
        because: '未读占位没有发出任何值');
    expect(probe.value, isNull,
        reason: '本地计数是「全部收件」、服务端 total 也是全量 —— 这个数不代表未读缺口');
  });

  // ------------------------------------------------- ⑦ 删信之后数字会自愈

  test('⑦ 删信之后重探总数：不再凭空多出「未同步」', () async {
    final q = h.query;
    // 服务端 100 封、本地全有 → 占位 0（不显示）。
    h.serveMailbox(_ids(1, 100), total: 100);
    await h.seedLocal(first: 1, last: 100, total: 100, cursor: 100);

    final probe = _Placeholder(h.container, q);
    addTearDown(probe.close);
    await probe.untilValue(0);

    final controller = h.controller(q);
    final probesBefore = h.probeRequests.length;

    // 在 App 里删掉 10 封：服务端总数变成 90。
    h.serveMailbox(_ids(11, 100), total: 90);
    await controller.delete(h.refsFor(1, 10));

    expect(h.probeRequests.length, probesBefore + 1,
        reason: '删信之后必须重探一次总数，否则底部会一直挂着旧快照算出来的假数字');

    final state = (await h.syncState())!;
    expect(state.remoteTotal, 90,
        reason: '删完立刻重探过总数（不再是那个 100 的快照）');
    expect(await h.localCount(), 90);
    // 100（旧快照）− 90（本地）会显示「还有 10 封未同步」；重探之后是 90 − 90 = 0。
    await probe.untilValue(0);
    expect(probe.value, 0);
  });

  // ------------------------------------- ⑧ 列表打开时刷新过期的 remote_total

  test('⑧ 打开列表会重探过期总数：旧快照算出来的数字第一次就被纠正', () async {
    final q = h.query;
    h.serveMailbox(_ids(1, 120), total: 120);
    // 库里躺着一个**过期**的快照：total = 100、时间戳是几个月前。
    // 本地缓存 71..120（50 封）→ 旧快照会算出「还有 50 封未同步」。
    await h.seedLocal(
      first: 71,
      last: 120,
      total: 100,
      cursor: 120,
      totalAt: DateTime.utc(2026, 7, 1),
    );

    final probe = _Placeholder(h.container, q);
    addTearDown(probe.close);

    // 打开列表（读 controller 就会触发 `_hydrate` → TTL 判据 → 重探）。
    h.controller(q);

    await h.until(() => h.probeRequests.isNotEmpty,
        because: '打开列表时没有按 TTL 重探总数');
    final probeRequest = h.probeRequests.single;
    expect(probeRequest.query['size'], 1);
    expect(probeRequest.query['full'], 0);
    expect(probeRequest.query['allReceive'], 0);

    // 真值是 120（不是库里那个 100）→ 120 − 50 = 70。
    await probe.untilValue(70);
    final state = (await h.syncState())!;
    expect(state.remoteTotal, 120);
    expect(state.remoteTotalAt!.isAfter(DateTime.utc(2026, 7, 2)), isTrue);
  });
}

// ---------------------------------------------------------------- 工具

/// `testWidgets` 里推有限几帧：drift / riverpod 的更新走的是真实异步，
/// 每推一帧给它一点时间（假时钟会被 `pump(duration)` 推进）。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
}

List<int> _ids(int from, int to) => <int>[for (var i = from; i <= to; i++) i];
Set<int> _idSet(int from, int to) => _ids(from, to).toSet();

/// 一个能发真请求、但不碰网络的假适配器（照 `mailbox_totals_probe_test.dart`）。
class _Harness {
  _Harness._({
    required this.db,
    required this.tokens,
    required this.prefs,
    required this.profile,
    required this.registry,
    required this.adapter,
    required this.authEvents,
    required this.container,
    required this.profilesSub,
  });

  static Future<_Harness> create() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final tokens = TokenStore();
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final profiles = ProfileRepository(db: db, tokens: tokens, prefs: prefs);
    final authEvents = AuthEvents();
    final adapter = _FakeAdapter();

    final registry = RuntimeRegistry(
      authEvents: authEvents,
      tokens: tokens,
      prefs: prefs,
      buildApiDio: (profile) {
        final dio = DioFactory.build(
          userApi: profile.baseUrl,
          profileId: profile.id,
          authEvents: authEvents,
          readToken: () => tokens.readCached(profile.id),
          readLanguage: () => 'zh',
        );
        dio.httpClientAdapter = adapter;
        return dio;
      },
    );

    final created = await profiles.create(baseUrl: 'https://mail.example.net');
    await profiles.markLoggedIn(
      created.id,
      userId: 42,
      email: 'me@example.net',
      userName: 'me',
    );
    await tokens.write(created.id, 'fake-jwt');
    // account 3 = 这个列表在看的那一格；account 4 = 同账号下的另一个邮箱
    // （⑤ 里服务端把「别的邮箱的信」返回过来时，行会挂到它名下）。
    await db.profileDao.upsertMailboxes(created.id, <MailboxAccount>[
      const MailboxAccount(accountId: 3, email: 'me@example.net', name: '我'),
      const MailboxAccount(accountId: 4, email: 'alias@example.net', name: '别名'),
    ]);
    final profile = (await profiles.find(created.id))!;
    // 鉴权那一步：`ProfileRuntime.hasToken` 读的是内存缓存。
    await registry.ensure(profile).warmUp();

    final container = ProviderContainer(overrides: [
      bootstrapProvider.overrideWithValue(
        BootstrapData(db: db, tokens: tokens, prefs: prefs),
      ),
      runtimeRegistryProvider.overrideWithValue(registry),
    ]);

    // riverpod 的流是懒订阅的：`read` 一次拿不到值（见
    // `mailbox_totals_read_test.dart` 同一句注释）。`loadMore` 里
    // `ref.read(profileByIdProvider)` 拿到 null 会静默早退，所以这里挂一条
    // 常驻订阅，让实例列表真的流出来。
    final profilesSub = container.listen(
      profilesProvider,
      (_, _) {},
      fireImmediately: true,
    );

    final h = _Harness._(
      db: db,
      tokens: tokens,
      prefs: prefs,
      profile: profile,
      registry: registry,
      adapter: adapter,
      authEvents: authEvents,
      container: container,
      profilesSub: profilesSub,
    );
    // `loadMore` 里 `ref.read(profileByIdProvider)` 拿到 null 会静默早退 ——
    // 真实 App 里列表页一直在 watch 实例列表，测试里得自己等它先到。
    await h.until(
      () => h.container.read(profileByIdProvider(profile.id)) != null,
      because: 'profilesProvider 一直没发出实例',
    );
    return h;
  }

  final AppDatabase db;
  final TokenStore tokens;
  final PrefsStore prefs;
  final Profile profile;
  final RuntimeRegistry registry;
  final _FakeAdapter adapter;
  final AuthEvents authEvents;
  final ProviderContainer container;

  /// 常驻订阅，只为让 `profilesProvider` 这条流一直有人听（见 create）。
  final ProviderSubscription<AsyncValue<List<Profile>>> profilesSub;

  MailListQuery get query => MailListQuery(
        mailboxes: <MailboxFilter>[
          MailboxFilter(profileId: profile.id, accountId: 3),
        ],
        folder: MailFolder.receive,
      );

  /// 同一个物理列表上的「未读」筛法 —— 占位行在上面必须闭嘴。
  MailListQuery get unreadQuery => MailListQuery(
        mailboxes: <MailboxFilter>[
          MailboxFilter(profileId: profile.id, accountId: 3),
        ],
        folder: MailFolder.receive,
        unreadOnly: true,
      );

  String get scope => EmailRepository.mailboxScope(3, MailType.receive);

  MailListController controller(MailListQuery q) =>
      container.read(mailListControllerProvider(q));

  /// 只有 `size = 1 & full = 0` 的探测请求（`probeMailboxTotal`）。
  List<_SentRequest> get probeRequests => adapter.listRequests
      .where((r) => r.query['size'] == 1 && r.query['full'] == 0)
      .toList(growable: false);

  Map<String, Object?> ok({Object? data}) =>
      <String, Object?>{'code': 200, 'message': 'success', 'data': data};

  /// 服务端「这台邮箱」里有哪些 emailId，以及 `/email/list` 回什么。
  ///
  /// [accountId] 是响应行里带的 `accountId`（`full=1` 的 `emailListColumns`
  /// 带这一列）；默认就是本邮箱。
  ///
  /// [mergedAccount] 模拟「这个账户开了合并接收」的服务端：**只有请求显式带
  /// `allReceive=1` 时**才返回整账号的邮件（行挂到 [mergedAccount] 名下）；
  /// 带 0（或缺失，按上游的回落逻辑视为账户开关 = 1）就照旧返回本邮箱。
  void serveMailbox(
    List<int> ids, {
    required int total,
    int accountId = 3,
    int? mergedAccount,
  }) {
    final oracle = <int>[...ids]..sort();
    adapter.respond((options, body) {
      if (!options.path.contains('/email/list')) {
        // 删信等其它接口：只要一个成功信封。
        return ok(data: null);
      }
      final q = options.queryParameters;
      final allReceive = (q['allReceive'] as num?)?.toInt();
      final rowAccount =
          mergedAccount != null && allReceive != 0 ? mergedAccount : accountId;
      final before = (q['emailId'] as num?)?.toInt();
      final size = (q['size'] as num?)?.toInt() ?? 50;
      // 本文件只用 `timeSort = 0`（往下翻旧）：`lt(emailId)` + `desc` + limit。
      final page = oracle
          .where((id) => before == null || id < before)
          .toList(growable: false)
          .reversed // oracle 已升序：倒过来就是 desc
          .take(size)
          .toList(growable: false);
      return ok(data: <String, Object?>{
        'list': <Object?>[
          for (final id in page) _jsonRow(id, accountId: rowAccount),
        ],
        'total': total,
        'latestEmail': <String, Object?>{
          'emailId': oracle.isEmpty ? 0 : oracle.last,
        },
      });
    });
  }

  Map<String, Object?> _jsonRow(int emailId, {required int accountId}) =>
      <String, Object?>{
        'emailId': emailId,
        'accountId': accountId,
        'userId': 42,
        'type': MailType.receive,
        'status': MailStatus.receive,
        'unread': UnreadState.unread,
        'isDel': 0,
        'isStar': 0,
        'subject': 'm$emailId',
        'sendEmail': 'noreply@example.net',
        'name': 'sender',
        'toEmail': 'me@example.net',
        'createTime': _serverTime(emailId),
        'content': '<p>m$emailId</p>',
        'text': 'm$emailId',
      };

  /// 与 [emailId] 同序的服务端时间（id 越大越新，单位为分钟）。
  String _serverTime(int emailId) {
    final t = DateTime.utc(2026, 9, 1).add(Duration(minutes: emailId));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// 造本地缓存：`first..last` 这 [last-first+1] 封，并写 `sync_states` 那一行。
  ///
  /// [totalAt] 默认是「刚刚」—— 这样 `_hydrate` 里的 TTL 判据会跳过重探，
  /// 用例要数请求时不会被打开列表那一次探测搅进来。要测新鲜度就显式传旧时间。
  Future<void> seedLocal({
    required int first,
    required int last,
    required int total,
    required int cursor,
    bool backfillDone = false,
    DateTime? totalAt,
  }) async {
    final rows = <MailRow>[
      for (var id = first; id <= last; id++)
        MailRow(
          emailId: id,
          profileId: profile.id,
          accountId: 3,
          type: MailType.receive,
          status: MailStatus.receive,
          subject: 'm$id',
          sendEmail: 'noreply@example.net',
          name: 'sender',
          toEmail: 'me@example.net',
          unread: UnreadState.unread,
          createTime: DateTime.utc(2026, 9, 1).add(Duration(minutes: id)),
          content: '<p>m$id</p>',
          text: 'm$id',
          hasFullBody: true,
        ),
    ];
    await db.mailDao.upsertPage(rows, cachedAt: DateTime.utc(2026, 10, 1));
    // 先写 total（会盖上 remote_total_at），再写游标 —— `saveSyncState`
    // 是「null = 保留旧值」，所以这一步不会把 total 抹掉。
    await db.mailDao.saveRemoteTotal(
      profileId: profile.id,
      scope: scope,
      total: total,
      at: totalAt ?? DateTime.now().toUtc(),
    );
    await db.mailDao.saveSyncState(
      profileId: profile.id,
      scope: scope,
      cursorEmailId: cursor,
      oldestEmailId: first,
      backfillDone: backfillDone,
      lastSyncAt: DateTime.utc(2026, 10, 1, 8),
    );
  }

  Future<int> localCount() =>
      db.mailDao.countMailbox(profile.id, 3, type: MailType.receive);

  List<MailRef> refsFor(int first, int last) => <MailRef>[
        for (var id = first; id <= last; id++)
          MailRef(profileId: profile.id, emailId: id),
      ];

  /// 列表真正能看到的行（走 `mailListProvider` 本身，窗口/provider 的接线
  /// 有错这条也会跟着错 —— 这正是要测的）。
  Future<List<int>> visibleIds(MailListQuery q, {int? expectLength}) async {
    final sub = container.listen(
      mailListProvider(q),
      (_, _) {},
      fireImmediately: true,
    );
    try {
      for (var i = 0; i < 600; i++) {
        final value = container.read(mailListProvider(q)).value;
        if (value != null &&
            (expectLength == null || value.length == expectLength)) {
          return value.map((r) => r.emailId).toList(growable: false);
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final value = container.read(mailListProvider(q)).value;
      fail('mailListProvider 没等到 $expectLength 行（实际 ${value?.length}）');
    } finally {
      sub.close();
    }
  }

  Future<DbSyncState?> syncState() => db.mailDao.syncState(profile.id, scope);

  /// riverpod / drift 的更新都是异步的：轮询到条件成立为止。
  Future<void> until(bool Function() ready, {required String because}) async {
    for (var i = 0; i < 400; i++) {
      if (ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('等了 2 秒还没等到：$because');
  }

  Future<void> dispose() async {
    profilesSub.close();
    container.dispose();
    registry.dispose();
    await authEvents.dispose();
    await db.close();
  }
}

/// 占位数字的探针：订阅一次 `unsyncedPlaceholderProvider`，把每次发出来的值
/// 记下来（用来断言「数字变了 / 值一直是 null」）。
class _Placeholder {
  _Placeholder(ProviderContainer container, MailListQuery query) {
    _sub = container.listen(
      unsyncedPlaceholderProvider(query),
      (_, next) {
        if (next.hasValue) emissions.add(next.value);
      },
      fireImmediately: true,
    );
  }

  final List<int?> emissions = <int?>[];
  ProviderSubscription<AsyncValue<int?>>? _sub;

  int? get value => emissions.isEmpty ? null : emissions.last;
  int get count => emissions.length;

  Future<void> untilValue(int? expected) async {
    for (var i = 0; i < 600; i++) {
      if (emissions.isNotEmpty && emissions.last == expected) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('占位数字没变成 $expected（历史：$emissions）');
  }

  void close() => _sub?.close();
}

class _SentRequest {
  _SentRequest({required this.path, required this.method, required this.query});

  final String path;
  final String method;
  final Map<String, dynamic> query;

  @override
  String toString() => '$method $path $query';
}

class _FakeAdapter implements HttpClientAdapter {
  FutureOr<Object?> Function(RequestOptions, List<int>)? _handler;

  final List<_SentRequest> listRequests = <_SentRequest>[];

  void respond(FutureOr<Object?> Function(RequestOptions, List<int>) handler) {
    _handler = handler;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    if (options.path.contains('/email/list')) {
      listRequests.add(_SentRequest(
        path: options.path,
        method: options.method,
        query: Map<String, dynamic>.from(options.queryParameters),
      ));
    }

    final handler = _handler;
    final payload = handler == null
        ? <String, Object?>{'code': 200, 'message': 'success', 'data': null}
        : await handler(options, bytes);
    final encoded = utf8.encode(jsonEncode(payload));
    return ResponseBody(
      Stream<Uint8List>.fromIterable(<Uint8List>[Uint8List.fromList(encoded)]),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json;charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
