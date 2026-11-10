import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/mail_detail/mail_detail_screen.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/features/notifications/notification_service.dart';
import 'package:mail_app/l10n/app_localizations.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/mail_providers.dart';
import 'package:mail_app/providers/notification_providers.dart';
import 'package:mail_app/providers/profile_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「未读列表里正在预览的那一封不许消失」的回归测试。
///
/// 用户报的现象：在「未读邮件」列表点开一封邮件预览 —— 打开即标已读 ——
/// 这一行失去「未读」这个筛选条件，**当场从未读列表消失**，而用户还开着
/// 这封信，看起来像邮件被删了。
///
/// 修法分两层，本文件把两层都钉住：
///
/// 1. **DAO**（`MailDao.watchMailboxSet` 的 `keep`）：unreadOnly 的 SQL 谓词从
///    「未读」放宽成「未读 **OR** 就是 keep 这一封」。但 keep 只是「放过
///    已读」这一条例外，**仍然要满足同一份 scope**（邮箱集合、收件方向、
///    未删除）—— 否则从别的实例 / 别的邮箱 / 已删除的信打开一封，会把
///    不相干的行塞进这个未读列表。
/// 2. **接线**（`previewedMailProvider` + 详情页 `initState` / `dispose`）：
///    详情页挂载期间按 token 登记「用户还开着这一封」，`mailListProvider`
///    在 unreadOnly 时把它作为 `keep` 传给 DAO；详情页卸载后解除，那一行
///    按正常口径消失。
///
/// 还有一条独立确认的竞态：宽屏换信时**新页的 hold 先到、旧页的 release
/// 后到**（换 key 重挂）。若 `release` 只按「当前是哪一封」抹状态，旧页
/// 那一下就会把新一封的按住一起解除 —— 用户换到下一封，列表上它又立刻
/// 消失。所以 controller 必须按 token 记账（⑦）。
///
/// 只用内存库 + 真 drift（不碰网络、不起运行时）。widget 那一条（⑨）会把
/// 真详情页挂起来，端到端钉住「帧后 hold / dispose 帧后 release」这段
/// 风险最高的接线。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 每个用例各自一份全新内存库是有意的；drift 的「多实例」警告只针对共享
  // QueryExecutor 的情形，这里互不共享，不适用。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  const profileA = 'A';
  const profileB = 'B';

  List<MailboxFilter> boxesOf(String profileId, int accountId) =>
      <MailboxFilter>[MailboxFilter(profileId: profileId, accountId: accountId)];

  // ------------------------------------------------------------------ DAO

  test('① 未读视图 + keep 指向已读的同 scope 邮件：它留在原位；不传 keep 就消失', () async {
    final boxes = boxesOf(profileA, 1);
    await db.mailDao.upsertPage(<MailRow>[
      _row(1), // 未读，最旧
      _row(2, unread: UnreadState.read), // 正在预览的那封：已经被标成已读
      _row(3), // 未读，最新
    ]);
    const keep = MailRef(profileId: profileA, emailId: 2);

    // 对照：同一份数据、不传 keep —— 预览中的那封已读邮件不该出现。
    final withoutKeep = await db.mailDao
        .watchMailboxSet(
          mailboxes: boxes,
          type: MailType.receive,
          unreadOnly: true,
        )
        .first;
    expect(_idsOf(withoutKeep), <int>[3, 1],
        reason: '不传 keep 时已读邮件本来就要被 unreadOnly 筛掉');

    final withKeep = await db.mailDao
        .watchMailboxSet(
          mailboxes: boxes,
          type: MailType.receive,
          unreadOnly: true,
          keep: keep,
        )
        .first;
    expect(_idsOf(withKeep), <int>[3, 2, 1],
        reason: 'keep 那一封要保留，且和未读行一起按 createTime desc 排序');
    expect(
      withKeep.firstWhere((r) => r.emailId == 2).isUnread,
      isFalse,
      reason: '保留的是它真实的状态（已读），不是假造一行未读',
    );
  });

  test('② keep 指向同实例的另一个邮箱：不塞进这个列表', () async {
    final boxes = boxesOf(profileA, 1);
    await db.mailDao.upsertPage(<MailRow>[
      _row(1), // A/1 未读，在列表里
      _row(2, account: 2, unread: UnreadState.read), // A/2 已读，不在这个列表
    ]);

    final rows = await db.mailDao
        .watchMailboxSet(
          mailboxes: boxes,
          type: MailType.receive,
          unreadOnly: true,
          keep: const MailRef(profileId: profileA, emailId: 2),
        )
        .first;

    expect(_idsOf(rows), <int>[1],
        reason: 'keep 只是「放过已读」，不能把别的邮箱的邮件拉进这个邮箱的列表');
  });

  test('③ keep 指向另一个实例的邮件：不出现（emailId 相同也不行）', () async {
    final boxes = boxesOf(profileA, 1);
    await db.mailDao.upsertPage(<MailRow>[
      _row(1), // A/1 未读
      _row(1, profile: profileB, account: 3, unread: UnreadState.read),
    ]);

    final rows = await db.mailDao
        .watchMailboxSet(
          mailboxes: boxes,
          type: MailType.receive,
          unreadOnly: true,
          keep: const MailRef(profileId: profileB, emailId: 1),
        )
        .first;

    expect(_idsOf(rows), <int>[1],
        reason: '实例 A 与 B 的 emailId 是各自独立的序列；B 的那封不能借 keep 混进来');
  });

  test('④ keep 指向 type=send 的邮件：收件方向的未读视图里不出现', () async {
    final boxes = boxesOf(profileA, 1);
    await db.mailDao.upsertPage(<MailRow>[
      _row(1), // 收件、未读
      _row(2, type: MailType.send, unread: UnreadState.read), // 已发送、已读
    ]);

    // **故意不传 `type`**：未读视图本身恒为收件方向，方向不能只靠调用方传
    // `type` 来保证。这正是 keep 分支自带 `type = MailType.receive` 的那条
    // 防线 —— 少了它，这里会变成 `[2, 1]`（已发送的邮件被 keep 拉进未读）。
    final rows = await db.mailDao
        .watchMailboxSet(
          mailboxes: boxes,
          unreadOnly: true,
          keep: const MailRef(profileId: profileA, emailId: 2),
        )
        .first;

    expect(_idsOf(rows), <int>[1],
        reason: 'keep 不能把发件方向的邮件带进「收件未读」视图');
  });

  test('⑤ keep 指向 isDel=1 的邮件：不出现', () async {
    final boxes = boxesOf(profileA, 1);
    await db.mailDao.upsertPage(<MailRow>[
      _row(1), // 未读，在列表里
      // `isDel` 不在 `copyWith` 里（服务端字段，本地只做覆盖），直接构造。
      _row(2, unread: UnreadState.read, isDel: 1),
    ]);

    final rows = await db.mailDao
        .watchMailboxSet(
          mailboxes: boxes,
          type: MailType.receive,
          unreadOnly: true,
          keep: const MailRef(profileId: profileA, emailId: 2),
        )
        .first;

    expect(_idsOf(rows), <int>[1],
        reason: '已删除的行连 keep 都救不回来 —— 详情页这时也该关了');
  });

  test('⑥ unreadOnly=false 时传 keep 不改变结果（全量列表本来就不按已读筛）', () async {
    final boxes = boxesOf(profileA, 1);
    await db.mailDao.upsertPage(<MailRow>[
      _row(1),
      _row(2, unread: UnreadState.read),
      _row(3),
    ]);
    const keep = MailRef(profileId: profileA, emailId: 2);

    final withoutKeep = await db.mailDao
        .watchMailboxSet(mailboxes: boxes, type: MailType.receive)
        .first;
    final withKeep = await db.mailDao
        .watchMailboxSet(
          mailboxes: boxes,
          type: MailType.receive,
          keep: keep,
        )
        .first;

    expect(_idsOf(withKeep), _idsOf(withoutKeep),
        reason: 'keep 只对 unreadOnly 有意义；非未读列表传了也必须一模一样');
    expect(_idsOf(withKeep), <int>[3, 2, 1], reason: '全部行都在');
  });

  // ------------------------------------------------------------- Controller

  test('⑦ Controller：按 token 记账的 hold/release（宽屏换信的竞态）', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(previewedMailProvider.notifier);

    const a = MailRef(profileId: profileA, emailId: 1);
    const b = MailRef(profileId: profileA, emailId: 2);
    final token1 = Object();
    final token2 = Object();

    expect(container.read(previewedMailProvider), isNull, reason: '初始没有预览');

    notifier.hold(token1, a);
    expect(container.read(previewedMailProvider), a);
    notifier.hold(token2, b);
    expect(container.read(previewedMailProvider), b,
        reason: '最后登记的那一封就是用户最后打开的那封');

    // 关键竞态：宽屏换信时新页（token2）先挂载，旧页（token1）后卸载。
    notifier.release(token1);
    expect(container.read(previewedMailProvider), b,
        reason: '旧页的 release 只能撤自己那次登记，不能把新页的按住一起抹掉');

    notifier.release(token2);
    expect(container.read(previewedMailProvider), isNull);

    // 同一个 token 再 hold 新邮件 = 同一页内换了一封（`didUpdateWidget` 路径）。
    notifier.hold(token1, a);
    expect(container.read(previewedMailProvider), a);
    notifier.hold(token1, b);
    expect(container.read(previewedMailProvider), b,
        reason: '同 token 覆盖：状态要跟着换成新的一封');

    // 撤销一次从未登记过的 token：什么都不该变。
    notifier.release(Object());
    expect(container.read(previewedMailProvider), b,
        reason: '未登记的 token 撤销是空操作');
  });

  // ------------------------------------------------------- Provider 集成

  test('⑧ Provider 集成：hold 期间标已读，该行仍留在未读列表；release 后消失', () async {
    // 不写 `<Override>[]`：`Override` 在 riverpod 3 里是 `sealed` 且没有对外导出。
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);

    const profileId = profileA;
    const emailId = 7;
    const ref = MailRef(profileId: profileId, emailId: emailId);
    final query = MailListQuery(
      mailboxes: boxesOf(profileId, 1),
      unreadOnly: true,
    );

    await db.mailDao.upsertPage(<MailRow>[_row(emailId)]);

    // riverpod 的流是懒订阅的：不 listen 的话 `read` 拿不到数据。
    final sub = container.listen(mailListProvider(query), (_, _) {});
    addTearDown(sub.close);

    await _until(
      () => _listHas(container, query, emailId, unread: true),
      because: '未读列表没先把这封未读邮件发出来',
    );

    final token = Object();
    container.read(previewedMailProvider.notifier).hold(token, ref);

    // 真 App 里这一步发生在 `EmailRepository.openMail`：本地先标已读。
    await db.mailDao.markRead(<MailRef>[ref], read: true);

    await _until(
      () => _listHas(container, query, emailId, unread: false),
      because: 'hold 期间标已读，该行还是被 unreadOnly 抽走了（正是用户报的 bug）',
    );
    final held = _listRows(container, query);
    expect(held.map((r) => r.emailId), contains(emailId));
    expect(
      held.firstWhere((r) => r.emailId == emailId).isUnread,
      isFalse,
      reason: '留在列表里的是它真实的已读状态',
    );

    // 用户离开这一封：按住解除，下一帧按正常口径消失。
    container.read(previewedMailProvider.notifier).release(token);
    await _until(
      () {
        final rows = container.read(mailListProvider(query)).value;
        return rows != null && rows.every((r) => r.emailId != emailId);
      },
      because: 'release 之后已读行没有被未读列表收走',
    );
  });

  // ------------------------------------------------- 详情页挂载/卸载接线

  testWidgets('⑨ 详情页挂载即 hold、卸载即 release（端到端接线）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const profileId = 'p1';
    const emailId = 12;
    const ref = MailRef(profileId: profileId, emailId: emailId);
    final query = MailListQuery.forProfile(profileId, unreadOnly: true);

    await db.mailDao.upsertPage(<MailRow>[
      _row(
        emailId,
        profile: profileId,
        // 详情页要能直接渲染：正文已齐 → `_ensureSynced` 不会去碰网络。
        hasFullBody: true,
        subject: '未读的预览',
      ),
    ]);

    // 不写 `<Override>[]`：`Override` 在 riverpod 3 里是 `sealed` 且没有对外导出。
    final container = ProviderContainer(overrides: [
      bootstrapProvider.overrideWithValue(BootstrapData(
        db: db,
        tokens: TokenStore(),
        prefs: PrefsStore(await SharedPreferences.getInstance()),
      )),
      notificationServiceProvider.overrideWithValue(_SilentNotifications()),
    ]);

    // 常驻订阅：让未读列表在详情页拆掉之后仍然活着（⑨ 最后两条断言要在
    // **树已经拆掉**之后读它）。树里那个 `_UnreadCount` 是「真实 App 的
    // 订阅形状」的那一份。
    final sub = container.listen(mailListProvider(query), (_, _) {});

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: <Widget>[
              _UnreadCount(query: query),
              Expanded(
                child: MailDetailScreen(
                  profileId: profileId,
                  emailId: emailId,
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    // initState 里排的帧后回调（hold + _openOnce）在这几帧里跑完；详情页
    // 那条 drift 流与列表流也会在这里发出第一个值。
    await tester.pumpAndSettle();

    expect(container.read(previewedMailProvider), ref,
        reason: '详情页挂载后没有登记「用户正开着这一封」（帧后 hold 没生效）');

    // 等 `_openOnce` 真的把已读写进本地库、未读列表的重发跑完。
    await _pumpUntil(
      tester,
      () => _listHas(container, query, emailId, unread: false),
      because: '打开详情后本地标已读没有体现到未读列表流里',
    );

    final held = _listRows(container, query);
    expect(held.map((r) => r.emailId), contains(emailId),
        reason: '用户还开着这封信，它不该从未读列表消失');
    expect(held.firstWhere((r) => r.emailId == emailId).isUnread, isFalse,
        reason: '列表显示的是真实状态：已读');

    // 拆树 = 用户关掉详情（返回列表 / 关右栏 / 删掉这封）。
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const SizedBox.shrink(),
    ));
    // `dispose` 里排的 release 也是帧后回调；多推一帧再加一点真实时间，
    // 保证它和列表流的重发都跑到。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));

    expect(container.read(previewedMailProvider), isNull,
        reason: '详情页卸载后没有解除按住（dispose 帧后 release 没生效）');

    await _pumpUntil(
      tester,
      () {
        final rows = container.read(mailListProvider(query)).value;
        return rows != null && rows.every((r) => r.emailId != emailId);
      },
      because: 'release 之后未读列表没把已读行收走',
    );

    // 收尾必须在用例体里做：drift 取消订阅会排一个零延时定时器，而
    // flutter_test 检查「还有没有挂着的定时器」发生在用例体返回时 ——
    // 放进 `addTearDown` 就晚了一步（与 `mail_detail_header_test.dart` 同理）。
    sub.close();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 5));
  });

  testWidgets('⑩ 宽屏换信重挂：旧页 dispose 的帧后 release 不许抹掉新页的 hold', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const profileId = 'p1';
    const emailId12 = 12;
    const emailId13 = 13;
    const ref12 = MailRef(profileId: profileId, emailId: emailId12);
    const ref13 = MailRef(profileId: profileId, emailId: emailId13);
    final query = MailListQuery.forProfile(profileId, unreadOnly: true);

    // 用户先打开第 12 封（未读）。
    await db.mailDao.upsertPage(<MailRow>[
      _row(emailId12, profile: profileId, hasFullBody: true, subject: '十二'),
    ]);

    // 不写 `<Override>[]`：`Override` 在 riverpod 3 里是 `sealed` 且没有对外导出。
    final container = ProviderContainer(overrides: [
      bootstrapProvider.overrideWithValue(BootstrapData(
        db: db,
        tokens: TokenStore(),
        prefs: PrefsStore(await SharedPreferences.getInstance()),
      )),
      notificationServiceProvider.overrideWithValue(_SilentNotifications()),
    ]);
    final sub = container.listen(mailListProvider(query), (_, _) {});

    // 详情页固定在同一个位置上（`MailPanes` 的右栏就是这样），换信用 key
    // 重挂：同一帧里旧页 dispose、新页 initState。
    Widget buildTree(Widget detail) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  _UnreadCount(query: query),
                  Expanded(child: detail),
                ],
              ),
            ),
          ),
        );

    Widget detailOf(int emailId) => MailDetailScreen(
          key: ValueKey<String>('$profileId#$emailId'),
          profileId: profileId,
          emailId: emailId,
        );

    await tester.pumpWidget(buildTree(detailOf(emailId12)));
    await tester.pumpAndSettle();
    expect(container.read(previewedMailProvider), ref12,
        reason: '第一封挂载后应该登记的是 12');

    // 列表里又来了一封新的（13 未读），用户从右栏换过去。
    await db.mailDao.upsertPage(<MailRow>[
      _row(emailId13, profile: profileId, hasFullBody: true, subject: '十三'),
    ]);
    await tester.pump();

    // **同一帧内**旧页（12）被拆、新页（13）被建：两个帧后回调都会登记到
    // 同一个 event loop 尾。token 记账必须让「旧页 release 后到」只撤自己
    // 那次登记，否则 13 的 hold 会被抹成 null（或留在 12）。
    await tester.pumpWidget(buildTree(detailOf(emailId13)));
    await tester.pumpAndSettle();

    expect(container.read(previewedMailProvider), ref13,
        reason: '旧页的帧后 release 不许抹掉新页的 hold：状态必须是 13，不能是 null 或 12');

    // 顺带钉住列表侧：13 被标已读但仍留在未读列表（它正被按住），
    // 12 已经不是未读、也不再被按住，按正常口径离开。
    await _pumpUntil(
      tester,
      () {
        final rows = _listRows(container, query);
        return rows.any((r) => r.emailId == emailId13 && !r.isUnread) &&
            rows.every((r) => r.emailId != emailId12);
      },
      because: '换信后未读列表没跟上：13 该留着，12 该走了',
    );

    // 拆树 = 关掉右栏：按住解除。
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const SizedBox.shrink(),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));
    expect(container.read(previewedMailProvider), isNull,
        reason: '拆树后必须解除按住');

    // 收尾照 ⑨：定时器检查发生在用例体返回时，关闭动作要留在体内。
    sub.close();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 5));
  });

  test('⑪ 聚合视图（mailboxes 为空 = 全部实例）：keep 指向别的实例的已读邮件也要保留', () async {
    await db.mailDao.upsertPage(<MailRow>[
      _row(1, profile: profileA), // A#1 未读
      _row(2, profile: profileB, account: 3), // B#2 未读
      _row(3, profile: profileB, account: 3, unread: UnreadState.read), // B#3 已读，正在预览
    ]);
    const keep = MailRef(profileId: profileB, emailId: 3);

    // 空集合 = 全部实例。此时没有邮箱集合可约束，keep 只受方向 / 未删除
    // 约束，所以**别的实例**的已读邮件也要被保留，它的未读同伙照常出现。
    final rows =
        await db.mailDao.watchMailboxSet(unreadOnly: true, keep: keep).first;
    expect(_idsOf(rows), <int>[3, 2, 1],
        reason: '聚合视图下 keep 跨实例也要保留，且仍按 createTime desc 排序');
    expect(rows.firstWhere((r) => r.emailId == 3).isUnread, isFalse,
        reason: '保留的是真实状态：已读');

    // 对照：同一份数据不传 keep 时它不在。
    final withoutKeep =
        await db.mailDao.watchMailboxSet(unreadOnly: true).first;
    expect(_idsOf(withoutKeep), <int>[2, 1],
        reason: '不传 keep 时已读的 B#3 不该出现在聚合未读视图里');
  });
}

// ---------------------------------------------------------------- 工具

/// 与 `mail_dao_mailbox_set_test.dart` 同形的行：createTime 与 emailId 同序，
/// 便于断言「按 createTime desc」。
MailRow _row(
  int id, {
  String profile = 'A',
  int account = 1,
  int type = MailType.receive,
  int isDel = 0,
  int unread = UnreadState.unread,
  bool hasFullBody = false,
  String subject = '',
}) =>
    MailRow(
      emailId: id,
      profileId: profile,
      accountId: account,
      type: type,
      isDel: isDel,
      unread: unread,
      subject: subject.isEmpty ? 's$id' : subject,
      text: '正文 $id',
      content: '<p>正文 $id</p>',
      hasFullBody: hasFullBody,
      createTime: DateTime.utc(2026, 10, 9, 0, 0, id),
    );

List<int> _idsOf(List<MailRow> rows) => rows.map((r) => r.emailId).toList();

List<MailRow> _listRows(ProviderContainer container, MailListQuery query) =>
    container.read(mailListProvider(query)).value ?? const <MailRow>[];

bool _listHas(
  ProviderContainer container,
  MailListQuery query,
  int emailId, {
  required bool unread,
}) {
  final rows = container.read(mailListProvider(query)).value;
  return rows != null &&
      rows.any((r) => r.emailId == emailId && r.isUnread == unread);
}

/// riverpod / drift 的更新都是异步的：轮询到条件成立为止（不用裸 sleep 蒙，
/// 但也不再依赖「猜一个刚好的延迟」）。
Future<void> _until(bool Function() ready, {required String because}) async {
  for (var i = 0; i < 600; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('等了 3 秒还没等到：$because');
}

/// `testWidgets` 里推有限几帧：每推一帧先给真实异步（drift 的内存库执行器、
/// microtask 链）一点时间，再推进假时钟把帧后回调 / 定时器跑掉。
///
/// 与 `mail_list_footer_sync_test.dart` 的 `_pumpFrames` 同一手法。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String because,
}) async {
  for (var i = 0; i < 200; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 5));
  }
  fail('等了 1 秒还没等到：$because');
}

/// 详情页 `_openOnce` 会撤掉通知；真实现会去建平台插件（测试里没有），
/// 日志里会留一行无关的「通知：撤销失败」。换成空实现。
///
/// 用 `implements` + `noSuchMethod` 而不是 `extends`：继承会跑插件对象的
/// 构造函数，而那正是那行日志的来源。`cancelFor` 必须给一个真的
/// `Future` —— 调用方是 `unawaited(...)`，默认的 `null` 会当场抛类型错误。
class _SilentNotifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #cancelFor) return Future<void>.value();
    return null;
  }
}

/// 一个一直 watch 未读列表的小 widget —— 让 `mailListProvider` 这条 drift
/// 流在树里真的有人听（与真实 App 的订阅形状一致）。
class _UnreadCount extends ConsumerWidget {
  const _UnreadCount({required this.query});

  final MailListQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(mailListProvider(query)).value;
    return Text('未读 ${rows?.length ?? 0}');
  }
}
