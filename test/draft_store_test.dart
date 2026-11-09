// `DraftStore` 的**核心实现**（`CoreDraftStore`）。
//
// 这一层盯的是同步层真正依赖的四件事，它们在 UI 上完全看不出来：
// 1. `watchAll()` 在草稿新增/修改时推**全量**快照，且 `rev` 跟着本地落库 +1；
// 2. `listAll()` / `byUid()` 的口径：uid 为空的脏行不算草稿（云端认不出它），
//    `byUid` 用 `profileKey` 而不是 `profileId` 定位——后者换设备就变了；
// 3. `applyRemote()` 写的 `rev` **就是远端给的**，不是 +1（+1 会让冲突判定把
//    「没改过」当「改过」，然后无限生成冲突副本），并且会清掉同 uid 的墓碑；
// 4. 删除本地草稿留下的墓碑能被 `listTombstones()` 读到，推成功后
//    `clearTombstones()` 清得掉。
//
// `profileKey` 的归一化单独钉一条（大小写/空格），因为它是**服务端认账号的
// 唯一键** —— 两边算得不一样，用户换台设备就找不到自己的草稿。
import 'dart:convert';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/core/db/draft_store_impl.dart';
import 'package:mail_app/data/models/profile.dart';

/// 测试实例：站点根是 `https://mail.example.com`（`baseUrl` 带 `/api`，
/// `Profile.host` 会去掉它），登录邮箱故意写成大小写混合 —— 归一化要吃掉它。
const Profile _p1 = Profile(
  id: 'p1',
  baseUrl: 'https://mail.example.com/api',
  email: 'Me@Example.com',
);

/// 由核心规则手算出来的期望值：`sha256("host\n" + lowercase(email))`。
///
/// 这里**独立算一遍**而不是调 `draftProfileKey`：那样测的是「函数等于自己」，
/// 改了算法也照样绿。手算不是「神谕」，但它钉住了「服务端看到的那串东西」。
String _expectedKey(String host, String email) => sha256
    .convert(
        utf8.encode('${host.toLowerCase()}\n${email.trim().toLowerCase()}'))
    .toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late CoreDraftStore store;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = CoreDraftStore(db);
    await db.profileDao.upsertProfile(_p1);
  });

  tearDown(() async {
    await db.close();
  });

  /// 草稿的落库走真实 DAO（`saveDraft`），不自造 `DbDraft`：`rev` / `uid`
  /// 的语义就在那个方法里，绕过去测出来的东西跟线上不是一回事。
  Future<int> save({
    String profileId = 'p1',
    String accountEmail = 'me@example.com',
    String recipientsJson = '["a@example.com"]',
    String subject = '第一版',
    String content = '[{"insert":"正文\\n"}]',
    List<String> attachmentPaths = const <String>['/tmp/one.pdf'],
    int? id,
  }) =>
      db.localDao.saveDraft(
        profileId: profileId,
        accountEmail: accountEmail,
        recipientsJson: recipientsJson,
        subject: subject,
        content: content,
        attachmentPaths: attachmentPaths,
        id: id,
      );

  test('watchAll：新增/修改推全量快照，rev 跟着本地落库 +1', () async {
    final emissions = <List<DraftSnapshot>>[];
    final sub = store.watchAll().listen(emissions.add);
    // 每次订阅立刻收到一次当前值（空库 → 空列表）。「先冷扫、再订阅」不会
    // 丢变更，靠的就是这个。
    await pumpEventQueue();
    expect(emissions, isNotEmpty);
    expect(emissions.last, isEmpty);

    final id = await save();
    await pumpEventQueue();
    expect(emissions.last, hasLength(1));

    final created = emissions.last.single;
    expect(created.profileId, 'p1');
    expect(created.profileKey,
        _expectedKey('https://mail.example.com', 'Me@Example.com'));
    expect(created.uid, isNotEmpty);
    expect(created.rev, 1);
    expect(created.deleted, isFalse);
    expect(created.subject, '第一版');
    expect(created.recipients, <String>['a@example.com']);
    expect(created.body, contains('正文'));
    expect(created.attachmentPaths, <String>['/tmp/one.pdf']);
    final firstUid = created.uid;

    await save(id: id, subject: '第二版', content: '[{"insert":"改过了\\n"}]');
    await pumpEventQueue();
    expect(emissions.last, hasLength(1));

    final updated = emissions.last.single;
    // uid 永不变（换设备认同一份草稿靠它），rev 是「本地第几次落库」。
    expect(updated.uid, firstUid);
    expect(updated.rev, 2);
    expect(updated.subject, '第二版');

    await sub.cancel();
  });

  test('listAll 过滤 uid 空行；byUid 命中/未命中', () async {
    final id = await save(subject: '有身份的');

    // 模拟「迁移没回填」的脏行：直接插一条 uid 为空的行。它不是任何一份草稿的
    // 身份（唯一索引对空串放行），推上云端只会变成一条认不出来的东西。
    await db.into(db.drafts).insert(
          DraftsCompanion.insert(
            profileId: 'p1',
            subject: const Value('脏行'),
            updatedAt: DateTime.now().toUtc(),
          ),
        );

    final all = await store.listAll();
    expect(all, hasLength(1), reason: 'uid 为空的脏行不该进快照列表');
    expect(all.single.subject, '有身份的');

    final key = _expectedKey('https://mail.example.com', 'Me@Example.com');
    final hit = await store.byUid(key, all.single.uid);
    expect(hit, isNotNull);
    expect(hit!.subject, '有身份的');
    expect(hit.rev, 1);

    expect(await store.byUid(key, 'no-such-uid'), isNull);
    // profileKey 对不上（另一个账号/实例）也是「没有」，而不是去别的 profile 里捞。
    expect(await store.byUid('not-a-profile-key', all.single.uid), isNull);
    // 空 uid 永远不命中（与 `findDraftByUid` 的口径一致）。
    expect(await store.byUid(key, ''), isNull);

    // `saveDraft` 的返回 id 仍能查到那一行，说明上面「脏行」没把它顶掉。
    expect(await db.localDao.findDraft(id), isNotNull);
  });

  test('applyRemote：新 uid 插入；同 uid 覆盖后 rev 等于远端给的（不是 +1）', () async {
    const key = 'https://mail.example.com';
    final keyHash = _expectedKey(key, 'Me@Example.com');
    final now = DateTime.utc(2026, 11, 9, 8, 30);

    await store.applyRemote(
      DraftSnapshot(
        profileId: 'p1',
        accountEmail: 'me@example.com',
        profileKey: keyHash,
        uid: 'uid-remote-1',
        rev: 7,
        deleted: false,
        subject: '远端第一版',
        recipients: const <String>['b@example.com'],
        body: '[{"insert":"远端\\n"}]',
        attachmentPaths: const <String>['/tmp/remote.pdf'],
        updatedAt: now,
      ),
    );

    var snap = await store.byUid(keyHash, 'uid-remote-1');
    expect(snap, isNotNull);
    expect(snap!.rev, 7);
    expect(snap.subject, '远端第一版');
    expect(snap.recipients, <String>['b@example.com']);
    expect(snap.attachmentPaths, <String>['/tmp/remote.pdf']);
    // drift 把 `DateTime` 存成 Unix 秒、读回来是**本地时区**的同一个瞬间
    // （本库的既有约定，见 `tables.dart`），比较前统一回 UTC。
    expect(snap.updatedAt.toUtc(), now);

    // 同一 uid 的第二版：rev 必须**等于**远端给的 12。+1 的话这里会是 8，
    // 而那正是「每拉一次就多一个本地版本」的病灶。
    await store.applyRemote(
      DraftSnapshot(
        profileId: 'p1',
        accountEmail: 'me@example.com',
        profileKey: keyHash,
        uid: 'uid-remote-1',
        rev: 12,
        deleted: false,
        subject: '远端第二版',
        recipients: const <String>['b@example.com', 'c@example.com'],
        body: '[{"insert":"远端二\\n"}]',
        attachmentPaths: const <String>[],
        updatedAt: now.add(const Duration(minutes: 5)),
      ),
    );

    snap = await store.byUid(keyHash, 'uid-remote-1');
    expect(snap!.rev, 12);
    expect(snap.subject, '远端第二版');
    expect(snap.recipients, hasLength(2));
    expect(snap.attachmentPaths, isEmpty);

    // 没有因为「两次 applyRemote」多出一行（uid 是身份，不是新草稿）。
    expect(await store.listAll(), hasLength(1));
  });

  test('applyRemote 清掉同 uid 的本地墓碑；重复应用是幂等的（不产生回环数据）', () async {
    final keyHash = _expectedKey('https://mail.example.com', 'Me@Example.com');

    // 本机先有一条草稿，然后删掉 → 墓碑。
    final id = await save(subject: '本机删掉的');
    final uid = (await db.localDao.findDraft(id))!.uid;
    await db.localDao.deleteDraft(id);
    expect(
      (await store.listTombstones()).map((t) => t.uid),
      contains(uid),
    );

    // 远端把同一个 uid 又写回来：墓碑要清掉，否则同步层会把这个 uid 的删除
    // 再推一次，把刚拉下来的草稿又抹掉。
    for (var i = 0; i < 5; i++) {
      await store.applyRemote(
        DraftSnapshot(
          profileId: 'p1',
          accountEmail: 'me@example.com',
          profileKey: keyHash,
          uid: uid,
          rev: 3,
          deleted: false,
          subject: '远端恢复',
          recipients: const <String>[],
          body: '',
          attachmentPaths: const <String>[],
          updatedAt: DateTime.utc(2026, 11, 9),
        ),
      );
    }

    expect(await store.listTombstones(), isEmpty);
    final all = await store.listAll();
    expect(all, hasLength(1), reason: '重复 applyRemote 不该堆出多行');
    expect(all.single.rev, 3, reason: '反复应用同一份远端快照，rev 停在远端值');
    expect(all.single.subject, '远端恢复');
  });

  test('applyRemote(deleted: true)：删本机行、不留墓碑（服务端删除不回推）', () async {
    final keyHash = _expectedKey('https://mail.example.com', 'Me@Example.com');
    final id = await save(subject: '云端删掉的');
    final uid = (await db.localDao.findDraft(id))!.uid;
    // 先让它有一个「打开中」标记，验证会被一起清掉。
    await db.localDao.markComposeOpen(id);

    await store.applyRemote(
      DraftSnapshot(
        profileId: 'p1',
        accountEmail: 'me@example.com',
        profileKey: keyHash,
        uid: uid,
        rev: 9,
        deleted: true,
        subject: '',
        recipients: const <String>[],
        body: '',
        attachmentPaths: const <String>[],
        updatedAt: DateTime.utc(2026, 11, 9),
      ),
    );

    expect(await db.localDao.findDraft(id), isNull);
    // **不留墓碑**：墓碑的语义是「本机删了、要推到云端」，把远端删除也记一笔，
    // 两台设备就会互相把删除推来推去。
    expect(await store.listTombstones(), isEmpty);
    expect(await store.listAll(), isEmpty);
    expect(await db.localDao.watchOpenDrafts().first, isEmpty);
  });

  test('deleteDraft 后 listTombstones 有一条 deleted=true；clearTombstones 清空',
      () async {
    final id = await save(subject: '要删的');
    final row = (await db.localDao.findDraft(id))!;
    expect(row.rev, 1);

    final tomb = await db.localDao.deleteDraft(id);
    expect(tomb, isNotNull);

    final tombstones = await store.listTombstones();
    expect(tombstones, hasLength(1));
    final t = tombstones.single;
    expect(t.deleted, isTrue);
    expect(t.uid, row.uid);
    // 墓碑 rev = 删除前的 rev + 1（删除本身也是一次内容变更）。
    expect(t.rev, 2);
    expect(t.rev, tomb!.rev);
    expect(t.profileKey,
        _expectedKey('https://mail.example.com', 'Me@Example.com'));
    expect(t.accountEmail, _p1.email);
    // 行已经删了，内容字段不该再被读出来。
    expect(t.subject, isEmpty);
    expect(t.body, isEmpty);
    expect(t.recipients, isEmpty);
    expect(t.attachmentPaths, isEmpty);

    final key = _expectedKey('https://mail.example.com', 'Me@Example.com');
    // 未知 profileKey / 空集合都是安静的空操作（同步层不该为此先判空）。
    await store.clearTombstones('not-a-key', <String>[row.uid]);
    await store.clearTombstones(key, const <String>[]);
    expect(await store.listTombstones(), hasLength(1));

    await store.clearTombstones(key, <String>[row.uid]);
    expect(await store.listTombstones(), isEmpty);
  });

  group('多 profile', () {
    const p2 = Profile(
      id: 'p2',
      baseUrl: 'https://other.example.com/api',
      email: 'other@example.com',
      sort: 1,
    );

    test('两个 profile 的草稿都在 listAll / watchAll 里', () async {
      await db.profileDao.upsertProfile(p2);
      await save(subject: 'p1 的草稿');
      await save(
        profileId: 'p2',
        accountEmail: 'other@example.com',
        subject: 'p2 的草稿',
      );

      final emissions = <List<DraftSnapshot>>[];
      final sub = store.watchAll().listen(emissions.add);
      await pumpEventQueue();

      final all = await store.listAll();
      expect(all, hasLength(2));
      expect(all.map((s) => s.profileId).toSet(), <String>{'p1', 'p2'});
      expect(
        emissions.last.map((s) => s.profileId).toSet(),
        <String>{'p1', 'p2'},
        reason: 'watchAll 推的是**所有** profile 的全量，不是当前实例',
      );

      // 每个 profile 各自算各自的 key，不会串。
      final keyOf = <String, String>{
        for (final s in all) s.profileId: s.profileKey,
      };
      expect(
        keyOf['p1'],
        _expectedKey('https://mail.example.com', 'Me@Example.com'),
      );
      expect(
        keyOf['p2'],
        _expectedKey('https://other.example.com', 'other@example.com'),
      );

      await sub.cancel();
    });

    /// profile 行没了、草稿行还留着 = 「清到一半被杀」的残行（正常路径
    /// `_clearDataOf` 会连草稿一起清）。这种行的 profileKey 算不出来，推上去
    /// 服务端也无处归档，所以读路径必须跳过它们，而不是拿空 key 去同步。
    test('profile 行被删掉之后，它的草稿行被跳过', () async {
      await db.profileDao.upsertProfile(p2);
      await save(
        profileId: 'p2',
        accountEmail: 'other@example.com',
        subject: '孤儿行',
      );
      // 只删 profile 行、不级联清 drafts。
      await (db.delete(db.profiles)..where((t) => t.id.equals('p2'))).go();

      expect(await store.listAll(), isEmpty);
      expect(await store.profiles(), hasLength(1));

      // watchAll 推的新全量里也只剩活 profile 的草稿。
      final emissions = <List<DraftSnapshot>>[];
      final sub = store.watchAll().listen(emissions.add);
      await save(subject: 'p1 的活草稿');
      await pumpEventQueue();
      expect(emissions.last, hasLength(1));
      expect(emissions.last.single.subject, 'p1 的活草稿');

      await sub.cancel();
    });
  });

  group('profileKey', () {
    test('host 与 email 归一化：大小写、首尾空白都吃掉，算法可手算', () {
      final base =
          draftProfileKey('https://mail.example.com', 'Me@Example.com');
      expect(
        base,
        sha256
            .convert(
              utf8.encode('https://mail.example.com\nme@example.com'),
            )
            .toString(),
      );
      expect(
        draftProfileKey('https://MAIL.example.com', '  me@example.com '),
        base,
      );
      // 任一维度不同就是另一个账号键。
      expect(
        draftProfileKey('https://mail.example.com', 'other@example.com'),
        isNot(base),
      );
      expect(
        draftProfileKey('https://other.example.com', 'me@example.com'),
        isNot(base),
      );
    });

    test('快照里的 profileKey 用 Profile.host（去掉 /api）算，大小写不敏感', () async {
      // 第二个 profile：同一个云端账号，只是填写的大小写/空白不同。
      await db.profileDao.upsertProfile(
        const Profile(
          id: 'p2',
          baseUrl: 'https://MAIL.example.com/api',
          email: '  me@example.com ',
          sort: 1,
        ),
      );
      final id = await db.localDao.saveDraft(
        profileId: 'p2',
        accountEmail: 'me@example.com',
        recipientsJson: '',
        subject: '别名实例',
        content: '',
      );
      expect(id, greaterThan(0));

      final all = await store.listAll();
      expect(all, hasLength(1));
      expect(
        all.single.profileKey,
        _expectedKey('https://mail.example.com', 'me@example.com'),
      );
    });
  });

  group('profiles() / profileIdFor()', () {
    const p2 = Profile(
      id: 'p2',
      baseUrl: 'https://other.example.com/api',
      email: 'other@example.com',
      sort: 1,
    );

    /// 这个出口存在的理由：`listAll()` 只给**有草稿的** profile，本机零草稿的
    /// 账号在里面根本不存在 —— 同步层必须能枚举「所有已登录账号」才能为它们
    /// 各拉一次云端草稿。
    test('profiles() 列出所有已登录账号（含本机零草稿的那个）', () async {
      await db.profileDao.upsertProfile(p2);
      await save(); // 只有 p1 有草稿

      final refs = await store.profiles();
      expect(
        refs.map((r) => r.profileId).toList(),
        <String>['p1', 'p2'],
        reason: '顺序沿用核心的实例排序（sort 升序）',
      );

      final first = refs.first;
      expect(
        first.profileKey,
        _expectedKey('https://mail.example.com', 'Me@Example.com'),
      );
      expect(first.accountEmail, 'Me@Example.com', reason: '登录邮箱原样返回');
      expect(
        first.instanceHost,
        'https://mail.example.com',
        reason: 'Profile.host 去掉了结尾 /api',
      );
      expect(
        refs[1].profileKey,
        _expectedKey('https://other.example.com', 'other@example.com'),
      );

      // 对照：p2 在 listAll 里没有（本地零草稿），只能靠 profiles() 发现。
      expect(
        (await store.listAll()).map((s) => s.profileId).toList(),
        <String>['p1'],
      );
    });

    test('profileIdFor：入参归一化；未知 key / 空串返回 null', () async {
      final key = _expectedKey('https://mail.example.com', 'Me@Example.com');
      expect(await store.profileIdFor(key), 'p1');
      // 服务端 JSON / 配置文件里的大小写与空白不该决定「找不找得到账号」。
      expect(await store.profileIdFor('  ${key.toUpperCase()}  '), 'p1');
      expect(await store.profileIdFor('not-a-profile-key'), isNull);
      expect(await store.profileIdFor(''), isNull);
      expect(await store.profileIdFor('   '), isNull);
    });

    test('byUid 同样归一化入参（大写/带空白也命中）', () async {
      final id = await save();
      final uid = (await db.localDao.findDraft(id))!.uid;
      final key = _expectedKey('https://mail.example.com', 'Me@Example.com');
      final hit = await store.byUid(' ${key.toUpperCase()} ', uid);
      expect(hit, isNotNull);
      expect(hit!.uid, uid);
    });
  });

  group('applyRemote 的 profile 解析', () {
    /// 一份「长得像云端拉下来」的快照。默认落在 p1。
    DraftSnapshot remote({
      String profileId = 'p1',
      String? profileKey,
      String uid = 'uid-remote-1',
      int rev = 4,
      bool deleted = false,
      String subject = '远端草稿',
    }) =>
        DraftSnapshot(
          profileId: profileId,
          accountEmail: 'me@example.com',
          profileKey: profileKey ??
              _expectedKey('https://mail.example.com', 'Me@Example.com'),
          uid: uid,
          rev: rev,
          deleted: deleted,
          subject: subject,
          recipients: const <String>['b@example.com'],
          body: '[{"insert":"远端\\n"}]',
          attachmentPaths: const <String>[],
          updatedAt: DateTime.utc(2026, 11, 9),
        );

    /// **不能插孤儿行**：草稿表的 `uid` 是全局唯一索引（`WHERE uid != ''`），
    /// 一条 profileKey 解析不出来的行会永久占住那个 uid —— 真正的 profile 后来
    /// 再想落地同一份草稿就只会撞索引失败。
    test('profileKey 匹配不到任何 profile → no-op，且不占 uid', () async {
      final ghostKey =
          _expectedKey('https://ghost.example.com', 'ghost@example.com');
      await store.applyRemote(
        remote(profileId: '', profileKey: ghostKey, uid: 'uid-orphan'),
      );

      expect(await store.listAll(), isEmpty);
      expect(await store.byUid(ghostKey, 'uid-orphan'), isNull);

      // uid 没被占：同一 uid 用正确 profile 再落一次能插进去（若第一次插了
      // 孤儿行，这里会撞 `drafts_uid_unique`）。
      await store.applyRemote(remote(uid: 'uid-orphan'));
      final all = await store.listAll();
      expect(all, hasLength(1));
      expect(all.single.profileId, 'p1');
      expect(all.single.uid, 'uid-orphan');
    });

    /// profileId 在本机存在，但快照的 key 是**另一个账号**的：调用方拿错了
    /// 快照。绝不能按 id 落库（会把 A 的草稿写进 B），也不该按 key 落到第三个
    /// 账号 —— 这就是「校验不一致 → no-op」。
    test('profileId 存在但 profileKey 不一致 → no-op', () async {
      final otherKey =
          _expectedKey('https://other.example.com', 'other@example.com');
      await store.applyRemote(
        remote(profileId: 'p1', profileKey: otherKey, uid: 'uid-mismatch'),
      );

      expect(await store.listAll(), isEmpty);
      expect(
        await store.byUid(
          _expectedKey('https://mail.example.com', 'Me@Example.com'),
          'uid-mismatch',
        ),
        isNull,
      );
    });

    /// 「profile 存在但传错 profileId」：id 指到 p2、key 却是 p1 的 —— 这是
    /// 调用方搞错了，不是「p2 换了邮箱」。不写任何一边。
    test('profile 存在但传错 profileId → 不写（也不回落到 key 落地）', () async {
      await db.profileDao.upsertProfile(
        const Profile(
          id: 'p2',
          baseUrl: 'https://other.example.com/api',
          email: 'other@example.com',
          sort: 1,
        ),
      );
      await store.applyRemote(remote(profileId: 'p2', uid: 'uid-wrong-id'));
      expect(await store.listAll(), isEmpty);
    });

    /// 反过来：id 为空、或本机已经没有这个 id（退登/删实例/别的设备的旧 id）
    /// 时，key 是唯一还能认回账号的证据 —— 按 key 落到 p1。
    test('profileId 为空或本机不存在时按 profileKey 反查落地', () async {
      await store.applyRemote(remote(profileId: '', uid: 'uid-by-key-1'));
      await store.applyRemote(
        remote(profileId: 'stale-from-other-device', uid: 'uid-by-key-2'),
      );

      final all = await store.listAll();
      expect(all, hasLength(2));
      expect(all.map((s) => s.profileId).toSet(), <String>{'p1'});
      expect(
        all.map((s) => s.uid).toSet(),
        <String>{'uid-by-key-1', 'uid-by-key-2'},
      );
    });

    /// applyRemote 是一次普通的本地写入，所以 watchAll 会推一次新全量 ——
    /// 同步层必须自己防回环（核心分不出「这是不是我自己写的」）。这里只断言
    /// 「推了」，不判回环。
    test('applyRemote 之后 watchAll 推一次新全量', () async {
      final emissions = <List<DraftSnapshot>>[];
      final sub = store.watchAll().listen(emissions.add);
      await pumpEventQueue();
      final before = emissions.length;

      await store.applyRemote(remote(uid: 'uid-emit', rev: 6));
      await pumpEventQueue();

      expect(emissions.length, greaterThan(before));
      expect(emissions.last, hasLength(1));
      expect(emissions.last.single.uid, 'uid-emit');
      expect(emissions.last.single.rev, 6);

      await sub.cancel();
    });
  });

  group('快照不可变 / 隐私', () {
    /// 同步层经常把快照塞进队列延后处理：如果这里留着核心传进来的可变 list，
    /// 一条迟到的 `add` 就能改掉「已经发出去的那份快照」。
    test('recipients / attachmentPaths 是副本，且不可修改', () {
      final recipients = <String>['a@example.com'];
      final paths = <String>['/tmp/a.pdf'];
      final snap = DraftSnapshot(
        profileId: 'p1',
        accountEmail: 'me@example.com',
        profileKey: _expectedKey('https://mail.example.com', 'Me@Example.com'),
        uid: 'uid-immutable',
        rev: 3,
        deleted: false,
        subject: '主题',
        recipients: recipients,
        body: '',
        attachmentPaths: paths,
        updatedAt: DateTime.utc(2026, 11, 9),
      );

      recipients.add('b@example.com');
      paths.add('/tmp/b.pdf');

      expect(snap.recipients, <String>['a@example.com']);
      expect(snap.attachmentPaths, <String>['/tmp/a.pdf']);
      expect(() => snap.recipients.add('c@example.com'), throwsUnsupportedError);
      expect(() => snap.attachmentPaths.add('/tmp/c.pdf'), throwsUnsupportedError);
    });

    /// spec §7：快照会被同步层整条丢进 debug 日志，而它装的是用户的信内容。
    /// 日志里只留定位信息（uid / rev / profileKey 前缀）。
    test('toString 不含 subject / 正文 / 收件人 / 附件路径', () {
      final key = _expectedKey('https://mail.example.com', 'Me@Example.com');
      final snap = DraftSnapshot(
        profileId: 'p1',
        accountEmail: 'me@example.com',
        profileKey: key,
        uid: 'uid-log',
        rev: 9,
        deleted: false,
        subject: '并购意向书',
        recipients: const <String>['secret@example.com'],
        body: '[{"insert":"机密正文"}]',
        attachmentPaths: const <String>['/Users/me/机密.pdf'],
        updatedAt: DateTime.utc(2026, 11, 9),
      );

      final text = snap.toString();
      expect(text, isNot(contains('并购意向书')));
      expect(text, isNot(contains('机密正文')));
      expect(text, isNot(contains('secret@example.com')));
      expect(text, isNot(contains('/Users/me')));
      // 定位信息还在，够查问题。
      expect(text, contains('uid-log'));
      expect(text, contains('rev=9'));
      expect(text, contains(key.substring(0, 8)));
      expect(text, isNot(contains(key)), reason: '整个 profileKey 不进日志');
    });
  });
}
