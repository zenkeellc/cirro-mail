// 切发件人的**连锁反应**：换了实例就换了用户，配额、草稿归属、回复线程
// 跟着一起走。这一组不开 UI，直接读 `composeControllerProvider` 的状态
// 与 `buildPayload()` 的产物 —— 那两处才是真正决定「信从哪台发出去」的地方。
//
// import 只写**这一步**用到的那几条：这个文件会被 Task 2 / 4 / 5 / 10 反复
// 追加内容，各自补自己那几条。提前把后面才用到的 import 写上，这一步会有
// 十来条 `unused_import`，而仓库的标准是 analyze 零输出。
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/instance_capabilities.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/compose/compose_controller.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/features/compose/compose_sender.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Profile _profileA = Profile(
  id: 'p1',
  baseUrl: 'https://a.example/api',
  email: 'me@a.example',
  userName: '甲',
  userId: 7,
);

const Profile _profileB = Profile(
  id: 'p2',
  baseUrl: 'https://b.example/api',
  email: 'me@b.example',
  userName: '乙',
  userId: 8,
);

const MailboxAccount _boxA3 = MailboxAccount(
  accountId: 3,
  email: 'me@a.example',
  name: '甲',
);

const MailboxAccount _boxB3 = MailboxAccount(
  accountId: 3,
  email: 'me@b.example',
  name: '乙',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('SenderOption.label：有名字时是「名字 <地址>」，没有就是裸地址', () {
    expect(
      const SenderOption(profile: _profileA, mailbox: _boxA3).label,
      '甲 <me@a.example>',
    );
    expect(
      const SenderOption(
        profile: _profileA,
        mailbox: MailboxAccount(accountId: 3, email: 'me@a.example'),
      ).label,
      'me@a.example',
    );
  });

  test('SenderOption 相等：只看实例 id 与 accountId / 地址，不看 Profile 整份', () {
    final option = const SenderOption(profile: _profileA, mailbox: _boxA3);
    // 同一个实例的同一行，但名字被改过（一次同步之后常见）—— 仍然相等。
    final renamed = SenderOption(
      profile: _profileA.copyWith(serverTitle: '换了个标题'),
      mailbox: const MailboxAccount(
        accountId: 3,
        email: 'me@a.example',
        name: '甲',
      ),
    );
    expect(option, renamed);
    // 不同实例的同号邮箱**不相等** —— 这正是今天会撞车的那一对。
    expect(
      option,
      isNot(const SenderOption(profile: _profileB, mailbox: _boxB3)),
    );
  });

  test('SenderOption 相等：同号同址但不同实例**不相等**，hashCode 分得开', () {
    // 上面那条用例里 A / B 的地址是**不同**的（`me@a.example` vs
    // `me@b.example`），所以把 `==` 里 `profile.id` 那一项删掉它照样绿 ——
    // 「实例参与身份判定」这件事它其实没钉住。这里刻意让两份**只有
    // `profile.id` 不同**：同 `accountId`、同 `email`。这才是真会撞车的一对
    // （`accountId` 只在实例内有意义，A 的 #3 与 B 的 #3 是两个不相干的邮箱）。
    const sameId = MailboxAccount(
      accountId: 3,
      email: 'me@x.example',
      name: '甲',
    );
    const a = SenderOption(profile: _profileA, mailbox: sameId);
    const b = SenderOption(profile: _profileB, mailbox: sameId);
    expect(a, isNot(b));
    expect(a.hashCode, isNot(b.hashCode), reason: 'hashCode 与 == 同一口径');

    // 契约里唯一能测的那半：**相等 ⇒ 同 hash**（不等 ⇒ 不同 hash 只是碰巧，
    // 这里能断言是因为本实现是 `Object.hash(profile.id, accountId, email)`）。
    const renamed = SenderOption(
      profile: _profileA,
      mailbox: MailboxAccount(
        accountId: 3,
        email: 'me@x.example',
        name: '换了个名字',
      ),
    );
    expect(a, renamed, reason: '名字不在身份判据里');
    expect(a.hashCode, renamed.hashCode);
  });

  /// 一个只给「实例列表 / 邮箱 / 能力」三样的小容器 ——
  /// `composeSendersProvider` 只读这三个 provider。
  ProviderContainer senderContainer({
    required List<Profile> profiles,
    required Map<String, List<MailboxAccount>> mailboxes,
    Map<String, bool> sendEnabled = const <String, bool>{},
  }) {
    final container = ProviderContainer.test(
      overrides: [
        profilesProvider.overrideWith((ref) => Stream.value(profiles)),
        mailboxesProvider.overrideWith(
          (ref, profileId) =>
              Stream.value(mailboxes[profileId] ?? const <MailboxAccount>[]),
        ),
        capabilitiesProvider.overrideWith(
          (ref, profileId) => Stream.value(
            InstanceCapabilities(
              hasSend: (sendEnabled[profileId] ?? true)
                  ? ProbeState.available
                  : ProbeState.absent,
            ),
          ),
        ),
      ],
    );
    return container;
  }

  /// 把候选读出来 —— **这一行看着多余，其实不能少**。
  ///
  /// 三个上游都是 `Stream.value`：值排在微任务里，而
  /// `composeSendersProvider` 是 `Provider`（**不是** autoDispose，见「开工
  /// 之前」那条），第一帧读它时 `profilesProvider` / `mailboxesProvider`
  /// 的 `.value` **都还是 null** —— 于是它返回空表，而 `.value` 是 null 的
  /// 那一刻**不会有任何重建**（要等值真的到了才通知），所以「读早了」只会
  /// 静默地拿到一个空表。
  ///
  /// 实测三条路（`flutter test` 里跑的探针）：
  /// - `await container.read(profilesProvider.future)` 之后直接读 → **空**；
  /// - `container.listen(composeSendersProvider, ...)` 把订阅建起来
  ///   （这一步才会去 watch `mailboxesProvider`）再 `await pumpEventQueue()`
  ///   → 几组候选全都到位；
  /// - 只 `await xxxProvider.future` **一个都不 listen** → 那条 future
  ///   **永远不完成**，直接用会挂到用例超时（30 s）。
  ///
  /// 所以：**先 `listen` 再 `pumpEventQueue`**，别用 `await xxx.future`。
  Future<List<SenderGroup>> sendersOf(ProviderContainer container) async {
    final sub = container.listen(composeSendersProvider, (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    return sub.read();
  }

  /// 取控制器 —— **先 listen 把它钉住，再取 notifier**。
  ///
  /// `composeControllerProvider` 是 `isAutoDispose` 的 family：只 `read` 一次、
  /// 没有人 listen 的话，它在下一个微任务就被回收 —— 随后
  /// `syncSenderGroups` 里的 `state = …` 会撞上「用已销毁的 Ref」而抛错。
  /// 屏幕平时是 `ref.watch` 着它的，所以只有测试会踩这个坑，
  /// 而且**每条用例都会踩**。
  ComposeController controllerOf(
    ProviderContainer container, [
    ComposeArgs args = const ComposeArgs(),
  ]) {
    final sub = container.listen(composeControllerProvider(args), (_, _) {});
    addTearDown(sub.close);
    return container.read(composeControllerProvider(args).notifier);
  }

  /// 两台实例、各一个邮箱的容器 —— 后续几条用例都用它。
  Future<ProviderContainer> twoInstanceContainer() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        currentProfileIdProvider.overrideWithValue('p1'),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[_profileA, _profileB]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(
            profileId == 'p1'
                ? const <MailboxAccount>[_boxA3]
                : const <MailboxAccount>[_boxB3],
          ),
        ),
        capabilitiesProvider.overrideWith(
          (ref, profileId) =>
              Stream.value(const InstanceCapabilities(hasSend: ProbeState.available)),
        ),
      ],
    );
    // 同样**不 await 那条 future**（见本文件的 `sendersOf`）。候选不在这里
    // 取 —— 各条用例自己调 `sendersOf(container)`，那一步顺带把订阅建起来。
    return container;
  }

  test('候选跨实例：两台实例的邮箱都在，按实例分成两组', () async {
    final container = senderContainer(
      profiles: const <Profile>[_profileA, _profileB],
      mailboxes: const <String, List<MailboxAccount>>{
        'p1': <MailboxAccount>[_boxA3],
        'p2': <MailboxAccount>[_boxB3],
      },
    );

    final groups = await sendersOf(container);
    expect(groups.map((g) => g.profile.id).toList(), <String>['p1', 'p2']);
    expect(groups.first.mailboxes.single.accountId, 3);
    expect(groups.last.mailboxes.single.email, 'me@b.example');
  });

  test('发不了信的实例整组不出现', () async {
    final container = senderContainer(
      profiles: const <Profile>[_profileA, _profileB],
      mailboxes: const <String, List<MailboxAccount>>{
        'p1': <MailboxAccount>[_boxA3],
        'p2': <MailboxAccount>[_boxB3],
      },
      sendEnabled: const <String, bool>{'p2': false},
    );

    final groups = await sendersOf(container);
    expect(groups.map((g) => g.profile.id).toList(), <String>['p1']);
  });

  test('候选里不带 accountId <= 0 的邮箱（降级兜底造出来的那个发不出去）', () async {
    final container = senderContainer(
      profiles: const <Profile>[_profileA],
      mailboxes: const <String, List<MailboxAccount>>{
        'p1': <MailboxAccount>[
          MailboxAccount(accountId: 0, email: 'fallback@a.example'),
        ],
      },
    );

    expect(await sendersOf(container), isEmpty);
  });

  test('跨实例：把发件人换成 B 的邮箱，报文里的 accountId 就是 B 的', () async {
    final container = await twoInstanceContainer();
    final controller = controllerOf(container);

    // 先让候选流出来（屏幕平时是通过 ref.listen 递进来的，这里手动递一次）。
    // **用本文件那个 `sendersOf`**：`container.read(composeSendersProvider)`
    // 在订阅建起来之前读只会拿到空表（见它的注释）。
    controller.syncSenderGroups(await sendersOf(container));
    expect(controller.state.sender, isNotNull);
    expect(controller.state.sendProfileId, 'p1');

    // 换到 B 实例的邮箱。
    final groupB = (await sendersOf(container))
        .firstWhere((g) => g.profile.id == 'p2');
    controller.setSender(groupB.options.single);

    final payload = controller.buildPayload();
    expect(payload.accountId, 3, reason: 'B 的邮箱 id');
    expect(payload.sendEmail, 'me@b.example');
    expect(
      controller.state.sendProfileId,
      'p2',
      reason: '这一页的其余部分（配额/草稿/补全）也跟着走',
    );
  });

  test('换实例之后存草稿：落在**新**实例名下，而且仍然只有一条', () async {
    final container = await twoInstanceContainer();
    final controller = controllerOf(container);
    controller.syncSenderGroups(await sendersOf(container));

    controller.setSubject('主题');
    controller.setBody('[{"insert":"正文\\n"}]');
    await controller.saveDraftOnExit();
    final groupB = (await sendersOf(container))
        .firstWhere((g) => g.profile.id == 'p2');
    controller.setSender(groupB.options.single);
    await controller.saveDraftOnExit();

    // **用普通查询而不是 `watchDrafts(...).first`**：后者是 drift 的流查询，
    // 在用例结束之后订阅还挂着，`db.close()` 会因此等不到头。这里要的只是
    // 「库里现在有什么」。
    final drafts = await container.read(databaseProvider).select(
          container.read(databaseProvider).drafts,
        ).get();
    expect(drafts, hasLength(1), reason: '换发件人不该在草稿箱里多出一条');
    expect(drafts.single.profileId, 'p2', reason: '归属跟着发件人走');
  });

  test('回复模式：不换实例时带 replyToEmailId，换了实例就丢掉', () async {
    final container = await twoInstanceContainer();
    final row = MailRow(
      emailId: 42,
      profileId: 'p1',
      sendEmail: 'from@x.com',
      subject: '原信',
      text: '正文',
      content: '<p>正文</p>',
      hasFullBody: true,
    );
    final args = ComposeArgs(mode: ComposeMode.reply, mail: row);
    final controller = controllerOf(container, args);
    controller.syncSenderGroups(await sendersOf(container));

    expect(
      controller.buildPayload().replyToEmailId,
      42,
      reason: '没换实例时那条 emailId 在原实例上是有效的',
    );

    final groupB = (await sendersOf(container))
        .firstWhere((g) => g.profile.id == 'p2');
    controller.setSender(groupB.options.single);

    expect(
      controller.buildPayload().replyToEmailId,
      0,
      reason: '服务端 selectById 不按 userId 过滤，拿 A 的 emailId 去 B 发信'
          '会把线程挂到另一封信上 —— 不报错，所以必须在这里拦住',
    );
  });

  test('换实例之后补全跟着换区：建议条里只留新实例的收件人历史', () async {
    final container = await twoInstanceContainer();
    final controller = controllerOf(container);
    final dao = container.read(databaseProvider).localDao;
    // 两边各记一条 —— 只记 p2 的话「到底有没有换区」看不出来。
    await dao.recordRecipients('p1', const <({String address, String name})>[
      (address: 'old@a.example', name: ''),
    ]);
    await dao.recordRecipients('p2', const <({String address, String name})>[
      (address: 'new@b.example', name: ''),
    ]);

    controller.syncSenderGroups(await sendersOf(container));
    expect(controller.state.sendProfileId, 'p1', reason: '默认发件人是入口实例那个');

    final groupB = (await sendersOf(container))
        .firstWhere((g) => g.profile.id == 'p2');
    controller.setSender(groupB.options.single);
    // `setSender` 里那次 `_refreshSuggestions` 是 unawaited 的。
    await pumpEventQueue();

    final addresses =
        controller.state.recipientSuggestions.map((r) => r.address).toList();
    expect(addresses, contains('new@b.example'), reason: '换成 B 之后该查 B 的历史');
    expect(
      addresses,
      isNot(contains('old@a.example')),
      reason: 'A 的收件人不该还留在建议条里',
    );
  });

  test('候选里当前那个消失了：落到第一组第一个，不落到同号的另一个实例', () async {
    final container = await twoInstanceContainer();
    final controller = controllerOf(container);
    final groups = await sendersOf(container);
    controller.syncSenderGroups(groups);

    // 先选 B 的那个（accountId 也是 3，与 A 的撞号）。
    controller.setSender(
      groups.firstWhere((g) => g.profile.id == 'p2').options.single,
    );
    expect(controller.state.sender!.profile.id, 'p2');

    // B 下线了：候选里只剩 A。
    controller.syncSenderGroups(
      groups.where((g) => g.profile.id == 'p1').toList(growable: false),
    );

    expect(
      controller.state.sender!.profile.id,
      'p1',
      reason: '回落必须落进新候选：改造前按 accountId 匹配、又把旧对象原样返回，'
          'B 下线（只剩 A 的 #3）时选中项仍指向已下线的 B',
    );
    expect(controller.state.sender!.mailbox.accountId, 3);
  });

  test('候选整个空了：sender 置 null（界面据此显示红字）', () async {
    final container = await twoInstanceContainer();
    final controller = controllerOf(container);
    controller.syncSenderGroups(await sendersOf(container));

    controller.syncSenderGroups(const <SenderGroup>[]);
    expect(controller.state.sender, isNull);
  });

  // 上一条用例给的新候选里**只剩 A 的组**：「按 accountId 匹配」与「落到第一组
  // 第一个」在那里落在同一个对象上 —— 把 `_resolveSender` 简化成只比
  // accountId 它照样绿，分辨不出身份里到底有没有 `profile.id`。这条把撞号的
  // 实例排到前面：选中的 A#3 仍在候选里，但排第一的是同号的 B#3；两件事各有
  // 各的答案，才真正把两条路分开。
  test('候选里选中的那个还在，但同号的另一个实例排到了前面：仍然选它', () async {
    final container = await twoInstanceContainer();
    final controller = controllerOf(container);
    final groups = await sendersOf(container);
    controller.syncSenderGroups(groups);

    // 选中 A 的 #3（与 B 的 #3 撞号）。
    controller.setSender(
      groups.firstWhere((g) => g.profile.id == 'p1').options.single,
    );
    expect(controller.state.sender!.profile.id, 'p1');

    // 候选重排：B 的组排到前面（里面那个 #3 与选中的撞号），A 的组退到第二。
    controller.syncSenderGroups(<SenderGroup>[
      groups.firstWhere((g) => g.profile.id == 'p2'),
      groups.firstWhere((g) => g.profile.id == 'p1'),
    ]);

    expect(
      controller.state.sender!.profile.id,
      'p1',
      reason: '只认第一个撞号的 accountId 就会跳到 B 去 —— 身份里必须有 profile.id',
    );
    expect(controller.state.sender!.mailbox.email, 'me@a.example');
  });

  // 第一条同步到位之前控制器只能给 null（它的两条上游也是 `Stream.value`），
  // 所以**真正定下默认发件人的是这次同步的兜底**，不是 `build()` 里那次。
  // 这里钉住兜底的口径：入口实例不是候选第一个时，得落到**入口实例**那一组，
  // 而不是按 `sort` 排第一的实例 —— 后者是拿另一个账号的身份发信。
  test('入口实例排在候选第二位：默认发件人仍是入口实例那一组，不是列表第一个', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        // 当前实例是 p2，但候选顺序（= `profilesProvider` 的 sort 顺序）是 [p1, p2]。
        currentProfileIdProvider.overrideWithValue('p2'),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[_profileA, _profileB]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(
            profileId == 'p1'
                ? const <MailboxAccount>[_boxA3]
                : const <MailboxAccount>[_boxB3],
          ),
        ),
        capabilitiesProvider.overrideWith(
          (ref, profileId) => Stream.value(
            const InstanceCapabilities(hasSend: ProbeState.available),
          ),
        ),
      ],
    );

    final controller = controllerOf(container);
    // 第一帧：上游还没吐值，兜底值就是 null（这正是「同步那次才是权威」的原因）。
    expect(controller.state.sender, isNull);

    final groups = await sendersOf(container);
    expect(
      groups.map((g) => g.profile.id).toList(),
      <String>['p1', 'p2'],
      reason: '构造前提：入口实例 p2 排在候选第二位',
    );
    controller.syncSenderGroups(groups);

    expect(
      controller.state.sendProfileId,
      'p2',
      reason: '落到 groups.first 就是拿 p1 的账号发信；兜底必须看入口实例',
    );
    expect(controller.state.sender!.profile.id, 'p2');
  });

  test('入口实例排在候选第二位 + 回复模式：默认发件人不换实例，线程不丢', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = PrefsStore(await SharedPreferences.getInstance());
    final container = ProviderContainer.test(
      overrides: [
        bootstrapProvider.overrideWithValue(
          BootstrapData(db: db, tokens: TokenStore(), prefs: prefs),
        ),
        currentProfileIdProvider.overrideWithValue('p2'),
        profilesProvider.overrideWith(
          (ref) => Stream.value(const <Profile>[_profileA, _profileB]),
        ),
        mailboxesProvider.overrideWith(
          (ref, profileId) => Stream.value(
            profileId == 'p1'
                ? const <MailboxAccount>[_boxA3]
                : const <MailboxAccount>[_boxB3],
          ),
        ),
        capabilitiesProvider.overrideWith(
          (ref, profileId) => Stream.value(
            const InstanceCapabilities(hasSend: ProbeState.available),
          ),
        ),
      ],
    );

    final row = MailRow(
      emailId: 42,
      profileId: 'p2',
      sendEmail: 'from@y.com',
      subject: '原信',
      text: '正文',
      content: '<p>正文</p>',
      hasFullBody: true,
    );
    final args = ComposeArgs(profileId: 'p2', mode: ComposeMode.reply, mail: row);
    final controller = controllerOf(container, args);
    controller.syncSenderGroups(await sendersOf(container));

    expect(
      controller.state.sendProfileId,
      'p2',
      reason: '默认发件人落到 p2 才谈得上「没换实例」',
    );
    expect(
      controller.buildPayload().replyToEmailId,
      42,
      reason: '兜底若落到 p1，`_useReplyThread` 会判成「换了实例」而把线程丢掉 ——'
          ' 用户从 p2 回复，线程却没了',
    );
  });
}
