// 草稿的跨设备身份（drift v6）：`drafts.uid` / `drafts.rev` + 删除墓碑。
//
// 这一层盯的是**同步层的三个前提**，它们在 UI 上完全看不出来：
// 1. 每条草稿都有非空、互异、写进去就不再变的 `uid`；
// 2. `rev` 每次落库 +1（新建 1，删除时墓碑 = 删除前 +1）；
// 3. 老库（v5）升上来之后，既有的草稿行被回填，且新库 / 升级库的结构一致
//    （唯一索引 `drafts_uid_unique` 两边都有）。
//
// 第 3 条单独用一个「声称自己是 v5 的库」来测：`NativeDatabase.memory(setup:)`
// 先手写 v5 的 `drafts` 表与一行数据、把 `user_version` 设成 5，
// 再让 `AppDatabase` 正常打开 —— 它就会走 `onUpgrade`，而不是 `onCreate`。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';

/// v5（未加 uid/rev）的 `drafts`，外加 v5 就有的 `compose_pages`：列与默认值
/// 照当时 drift 生成的 DDL 抄。
///
/// `compose_pages` 必须一起建：`deleteDraft` 在同一个事务里删「打开中」标记，
/// 少了这张表，这条用例测到的是「表不存在」而不是迁移结果。别的表不建 ——
/// `from < 6` 这一段只碰这两张表，多建会把「迁移只做了自己该做的事」变糊。
const String _v5DraftsDdl = '''
CREATE TABLE drafts (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  profile_id TEXT NOT NULL,
  account_email TEXT NOT NULL DEFAULT '',
  recipients_json TEXT NOT NULL DEFAULT '',
  subject TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  attachment_paths_json TEXT NOT NULL DEFAULT '[]',
  updated_at INTEGER NOT NULL
);
CREATE TABLE compose_pages (
  draft_id INTEGER NOT NULL,
  opened_at INTEGER NOT NULL,
  PRIMARY KEY (draft_id)
);
''';

/// v6 的 DDL 全部做完、却还没写 `user_version` 时库里的样子（进程正好在
/// 最后一步之前被杀）。列 / 墓碑表 / 唯一索引的形状与 `onCreate` 逐字一致。
const String _v6DdlAfterInterruption = '''
ALTER TABLE drafts ADD COLUMN uid TEXT NOT NULL DEFAULT '';
ALTER TABLE drafts ADD COLUMN rev INTEGER NOT NULL DEFAULT 1;
CREATE TABLE draft_tombstones (
  profile_id TEXT NOT NULL,
  uid TEXT NOT NULL,
  rev INTEGER NOT NULL,
  deleted_at INTEGER NOT NULL,
  PRIMARY KEY (profile_id, uid)
);
CREATE UNIQUE INDEX IF NOT EXISTS drafts_uid_unique
  ON drafts (uid) WHERE uid != '';
''';

const String _insertV5DraftSql = 'INSERT INTO drafts '
    '(profile_id, account_email, subject, content, updated_at) '
    'VALUES (?, ?, ?, ?, ?)';

/// 从 `PRAGMA index_list` 里捞某条索引的形状（`unique` / `partial`）。
Future<List<Object?>> _indexShape(AppDatabase db, String name) async {
  final rows = await db.customSelect('PRAGMA index_list(drafts)').get();
  final hit = rows.where((r) => r.read<String>('name') == name).toList();
  expect(hit, hasLength(1), reason: '$name 应该存在');
  return <Object?>[
    hit.single.read<int>('unique'),
    hit.single.read<int>('partial'),
  ];
}

Future<bool> _tableExists(AppDatabase db, String table) async {
  final rows = await db.customSelect(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '$table'",
  ).get();
  return rows.isNotEmpty;
}

void main() {
  group('新库（onCreate，v6）', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('saveDraft 两次：uid 非空且互异，rev 都从 1 起', () async {
      final dao = db.localDao;
      final a = await dao.saveDraft(
        profileId: 'p1',
        accountEmail: 'me@example.com',
        recipientsJson: '[]',
        subject: 'A',
        content: '[{"insert":"a\\n"}]',
      );
      final b = await dao.saveDraft(
        profileId: 'p1',
        accountEmail: 'me@example.com',
        recipientsJson: '[]',
        subject: 'B',
        content: '[{"insert":"b\\n"}]',
      );

      final da = (await dao.findDraft(a))!;
      final dbb = (await dao.findDraft(b))!;
      expect(da.uid, isNotEmpty);
      expect(dbb.uid, isNotEmpty);
      expect(da.uid, isNot(dbb.uid), reason: '同一秒、同一 profile 也不能撞身份');
      expect(da.rev, 1);
      expect(dbb.rev, 1);
    });

    test('更新（saveDraft(id:)）rev +1，uid 不变', () async {
      final dao = db.localDao;
      final id = await dao.saveDraft(
        profileId: 'p1',
        accountEmail: 'me@example.com',
        recipientsJson: '[]',
        subject: 'A',
        content: 'x',
      );
      final before = (await dao.findDraft(id))!;

      await dao.saveDraft(
        id: id,
        profileId: 'p1',
        accountEmail: 'me@example.com',
        recipientsJson: '[]',
        subject: 'A2',
        content: 'y',
      );
      await dao.saveDraft(
        id: id,
        profileId: 'p1',
        accountEmail: 'me@example.com',
        recipientsJson: '[]',
        subject: 'A3',
        content: 'z',
      );

      final after = (await dao.findDraft(id))!;
      expect(after.rev, before.rev + 2, reason: '两次整行更新 = rev 加二');
      expect(after.uid, before.uid, reason: '身份永不变');
      expect(after.subject, 'A3');
    });

    test('updateDraftFields（按列增量）同样 rev +1', () async {
      final dao = db.localDao;
      final id = await dao.createComposeDraft(profileId: 'p1', subject: '旧');
      final before = (await dao.findDraft(id))!;
      expect(before.uid, isNotEmpty, reason: 'createComposeDraft 也走同一套身份');
      expect(before.rev, 1);

      expect(await dao.updateDraftFields(id, subject: '新'), 1);
      final after = (await dao.findDraft(id))!;
      expect(after.rev, before.rev + 1);
      expect(after.uid, before.uid);
    });

    test('updateDraftFields 行已删：写 0 行，也不写墓碑（不复活）', () async {
      final dao = db.localDao;
      final id = await dao.createComposeDraft(profileId: 'p1');
      await dao.deleteDraft(id);

      expect(await dao.updateDraftFields(id, content: '迟到的内容'), 0);
      expect(await db.select(db.drafts).get(), isEmpty);
      expect(await db.select(db.draftTombstones).get(), hasLength(1));
    });

    test('findDraftByUid 按 (profileId, uid) 命中；listAllDrafts 跨 profile', () async {
      final dao = db.localDao;
      final a = await dao.saveDraft(
        profileId: 'p1',
        accountEmail: '',
        recipientsJson: '',
        subject: '甲',
        content: '',
      );
      final b = await dao.saveDraft(
        profileId: 'p2',
        accountEmail: '',
        recipientsJson: '',
        subject: '乙',
        content: '',
      );
      final da = (await dao.findDraft(a))!;

      final found = await dao.findDraftByUid('p1', da.uid);
      expect(found?.id, a);
      expect(await dao.findDraftByUid('p2', da.uid), isNull,
          reason: 'uid 全局唯一，但查询要按 profile 收窄');

      final all = await dao.listAllDrafts();
      expect(all.map((d) => d.id).toSet(), <int>{a, b});
      expect(all, hasLength(2));
      expect(all.first.id, b, reason: '按最近修改倒序（同秒用 id 倒序兜底）');
    });

    test('listAllDrafts 跳过空 uid 脏行；findDraftByUid 对空 uid 返回 null', () async {
      final dao = db.localDao;
      final clean = await dao.saveDraft(
        profileId: 'p1',
        accountEmail: '',
        recipientsJson: '',
        subject: '有身份',
        content: '',
      );
      // 手工造一条「迁移没回填」的脏行（uid 走列默认值，空串）。
      final dirty = await db.into(db.drafts).insert(DraftsCompanion.insert(
            profileId: 'p1',
            updatedAt: DateTime.now().toUtc(),
          ));
      final dirtyRow = (await dao.findDraft(dirty))!;
      expect(dirtyRow.uid, isEmpty);

      // 空串不是身份：不能拿它命中脏行。
      expect(await dao.findDraftByUid('p1', ''), isNull);
      // 首轮全量推送不带脏行，干净的那条照常出现。
      final all = await dao.listAllDrafts();
      expect(all.map((d) => d.id), <int>[clean]);
      expect(all.map((d) => d.id), isNot(contains(dirty)));
    });

    test('唯一索引：非空 uid 不能重复；空串可以有多条（部分索引）', () async {
      DraftsCompanion row(String uid) => DraftsCompanion.insert(
            profileId: 'p1',
            uid: Value(uid),
            updatedAt: DateTime.now().toUtc(),
          );

      await db.into(db.drafts).insert(row('same-uid'));
      await expectLater(
        db.into(db.drafts).insert(row('same-uid')),
        throwsA(predicate((e) => e.toString().contains('UNIQUE'))),
      );

      // 迁移前的旧行形态（uid 取默认空串）不受唯一索引约束：这条索引是
      // 部分索引（`WHERE uid != ''`），空串可以先有多条、等回填。
      await db.into(db.drafts).insert(DraftsCompanion.insert(
            profileId: 'p1',
            updatedAt: DateTime.now().toUtc(),
          ));
      await db.into(db.drafts).insert(DraftsCompanion.insert(
            profileId: 'p1',
            updatedAt: DateTime.now().toUtc(),
          ));
      expect(await db.select(db.drafts).get(), hasLength(3));

      // 结构：UNIQUE + partial（`WHERE uid != ''`）。
      expect(await _indexShape(db, 'drafts_uid_unique'), <Object?>[1, 1]);
    });

    test('deleteDraft 写墓碑：rev = 删除前 + 1，草稿行没了', () async {
      final dao = db.localDao;
      final id = await dao.saveDraft(
        profileId: 'p1',
        accountEmail: 'me@example.com',
        recipientsJson: '',
        subject: '要删的',
        content: 'x',
      );
      // 先改一次，让 rev 不是 1 —— 墓碑必须基于「删除那一刻的 rev」。
      await dao.updateDraftFields(id, subject: '要删的（改过）');
      final before = (await dao.findDraft(id))!;

      final tombstone = await dao.deleteDraft(id);
      expect(tombstone, isNotNull);
      expect(tombstone!.profileId, 'p1');
      expect(tombstone.uid, before.uid);
      expect(tombstone.rev, before.rev + 1);

      expect(await dao.findDraft(id), isNull);
      final stored = await db.select(db.draftTombstones).get();
      expect(stored, hasLength(1));
      expect(stored.single.uid, before.uid);
      expect(stored.single.rev, before.rev + 1);
      expect(stored.single.deletedAt.isAfter(DateTime.utc(2000)), isTrue);
    });

    test('deleteDraft 墓碑 rev 取 max：已有墓碑更高时，旧副本不能把它降级', () async {
      final dao = db.localDao;
      final id = await dao.saveDraft(
        profileId: 'p1',
        accountEmail: '',
        recipientsJson: '',
        subject: 's',
        content: 'x',
      );
      // 把行的 rev 推到 3（两次按列更新）：删除时算出来的是 3 + 1 = 4。
      await dao.updateDraftFields(id, subject: 's2');
      await dao.updateDraftFields(id, subject: 's3');
      final row = (await dao.findDraft(id))!;
      expect(row.rev, 3);

      // 云端已经见过 rev = 5 的墓碑（同一 uid 在别处删过更晚的版本）。
      await db.into(db.draftTombstones).insert(DraftTombstonesCompanion.insert(
            profileId: 'p1',
            uid: row.uid,
            rev: 5,
            deletedAt: DateTime.utc(2026, 1, 1),
          ));

      final tombstone = await dao.deleteDraft(id);
      expect(tombstone, isNotNull);
      expect(tombstone!.rev, 5, reason: '4 < 5：账本只前进，不能退回旧版本');
      final stored = (await db.select(db.draftTombstones).get()).single;
      expect(stored.rev, 5);
      expect(stored.deletedAt.isAfter(DateTime.utc(2026, 1, 1)), isTrue,
          reason: '删除时间仍然更新成这一次');
    });

    test('deleteDraft 墓碑 rev 取 max：行比已有墓碑新时，用行 rev + 1', () async {
      final dao = db.localDao;
      final id = await dao.saveDraft(
        profileId: 'p1',
        accountEmail: '',
        recipientsJson: '',
        subject: 's',
        content: 'x',
      );
      await dao.updateDraftFields(id, subject: 's2');
      final row = (await dao.findDraft(id))!;
      expect(row.rev, 2);

      await db.into(db.draftTombstones).insert(DraftTombstonesCompanion.insert(
            profileId: 'p1',
            uid: row.uid,
            rev: 2,
            deletedAt: DateTime.utc(2026, 1, 1),
          ));

      final tombstone = await dao.deleteDraft(id);
      expect(tombstone!.rev, 3, reason: '这次删除基于 rev 2，删除后是 3');
      expect((await db.select(db.draftTombstones).get()).single.rev, 3);
    });

    test('deleteDraft 行不存在：返回 null（幂等），不写墓碑', () async {
      expect(await db.localDao.deleteDraft(999999), isNull);
      expect(await db.select(db.draftTombstones).get(), isEmpty);
    });

    test('deleteProfileLocal 连墓碑一起清（只清这个实例）', () async {
      final dao = db.localDao;
      final p1 = await dao.createComposeDraft(profileId: 'p1');
      final p2 = await dao.createComposeDraft(profileId: 'p2');
      await dao.deleteDraft(p1);
      await dao.deleteDraft(p2);
      expect(await db.select(db.draftTombstones).get(), hasLength(2));

      await dao.deleteProfileLocal('p1');
      final left = await db.select(db.draftTombstones).get();
      expect(left, hasLength(1));
      expect(left.single.profileId, 'p2', reason: '别把另一个实例的账本一起清了');
    });

    test('删实例（cascade）连墓碑一起清', () async {
      final dao = db.localDao;
      final id = await dao.createComposeDraft(profileId: 'p1');
      await dao.deleteDraft(id);
      expect(await db.select(db.draftTombstones).get(), hasLength(1));

      await db.profileDao.deleteProfileCascade('p1');
      expect(await db.select(db.draftTombstones).get(), isEmpty);
    });
  });

  group('v5 → v6 升级', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(
        NativeDatabase.memory(
          setup: (raw) {
            raw.execute(_v5DraftsDdl);
            raw.execute(
              _insertV5DraftSql,
              ['p1', 'me@example.com', '旧草稿甲', 'x', 1762650000],
            );
            raw.execute(
              _insertV5DraftSql,
              ['p1', 'me@example.com', '旧草稿乙', 'y', 1762650060],
            );
            // 关键：声称自己是 v5，drift 才会走 `onUpgrade` 而不是 `onCreate`。
            raw.execute('PRAGMA user_version = 5');
          },
        ),
      );
    });

    tearDown(() => db.close());

    test('既有行被回填 uid/rev，行数与内容不变', () async {
      final rows = await db.select(db.drafts).get();
      expect(rows, hasLength(2), reason: '迁移不能丢用户草稿');
      expect(rows.map((r) => r.subject).toSet(), {'旧草稿甲', '旧草稿乙'});
      for (final r in rows) {
        expect(r.uid, isNotEmpty);
        expect(r.rev, 1);
      }
      expect(rows[0].uid, isNot(rows[1].uid), reason: '每行各生一个，不能批量同值');
      expect(rows[0].accountEmail, 'me@example.com');
    });

    test('升级库有 draft_tombstones 与同形状的唯一索引', () async {
      expect(await _tableExists(db, 'draft_tombstones'), isTrue);
      // 与新库那条断言完全相同：新库 / 老库结构必须一致。
      expect(await _indexShape(db, 'drafts_uid_unique'), <Object?>[1, 1]);
    });

    test('升级库的唯一索引真生效：再插一条同 uid 抛 UNIQUE', () async {
      final existing = (await db.select(db.drafts).get()).first.uid;
      await expectLater(
        db.into(db.drafts).insert(
              DraftsCompanion.insert(
                profileId: 'p1',
                uid: Value(existing),
                updatedAt: DateTime.now().toUtc(),
              ),
            ),
        throwsA(predicate((e) => e.toString().contains('UNIQUE'))),
      );
      // 冲突那行没写进去。
      expect(await db.select(db.drafts).get(), hasLength(2));
    });

    test('升级后的行能正常走 DAO：删掉时墓碑带着回填出来的 uid', () async {
      final dao = db.localDao;
      final old = (await db.select(db.drafts).get()).first;
      final tombstone = await dao.deleteDraft(old.id);
      expect(tombstone, isNotNull);
      expect(tombstone!.uid, old.uid);
      expect(tombstone.rev, old.rev + 1);
      expect(await db.select(db.drafts).get(), hasLength(1));
    });
  });

  // 进程（或另一个 isolate）在 `onUpgrade` 中途被杀：`user_version` 还是 5，
  // 库里却已经有一部分 v6 的 DDL。下次启动会从同一段开头重跑 —— 这些用例
  // 就是那两个「半完成」状态的快照，要求重跑不抛、回填与索引照做。
  group('中断后重试（onUpgrade 可重入）', () {
    test('已有 uid 列、user_version 仍是 5：打开不抛，回填与索引照做', () async {
      final db = AppDatabase.forTesting(
        NativeDatabase.memory(
          setup: (raw) {
            raw.execute(_v5DraftsDdl);
            // 上次死在第一条 addColumn 之后：uid 有了，rev / 墓碑表还没有。
            raw.execute(
              "ALTER TABLE drafts ADD COLUMN uid TEXT NOT NULL DEFAULT ''",
            );
            raw.execute(
              _insertV5DraftSql,
              ['p1', 'me@example.com', '旧草稿甲', 'x', 1762650000],
            );
            raw.execute(
              _insertV5DraftSql,
              ['p1', 'me@example.com', '旧草稿乙', 'y', 1762650060],
            );
            raw.execute('PRAGMA user_version = 5');
          },
        ),
      );
      addTearDown(db.close);

      // 能正常打开、能查，就证明 addColumn 没有二次执行（否则这里是
      // `duplicate column name: uid`）。
      final rows = await db.select(db.drafts).get();
      expect(rows, hasLength(2));
      for (final r in rows) {
        expect(r.uid, isNotEmpty);
        expect(r.rev, 1, reason: '补上的 rev 列走默认值 1，回填也写 1');
      }
      expect(rows[0].uid, isNot(rows[1].uid));
      expect(await _tableExists(db, 'draft_tombstones'), isTrue);
      expect(await _indexShape(db, 'drafts_uid_unique'), <Object?>[1, 1]);
    });

    test('DDL 全做完、user_version 仍为 5：再跑一遍不炸，已回填的 uid 不变', () async {
      const keptUid = 'migrated-uid-kept';
      final db = AppDatabase.forTesting(
        NativeDatabase.memory(
          setup: (raw) {
            raw.execute(_v5DraftsDdl);
            raw.execute(_v6DdlAfterInterruption);
            // 上次已经回填过一行、另一行还没轮到就被杀了。
            raw.execute(
              'INSERT INTO drafts '
              '(profile_id, account_email, subject, content, updated_at, uid, rev) '
              'VALUES (?, ?, ?, ?, ?, ?, ?)',
              ['p1', 'me@example.com', '已回填', 'x', 1762650000, keptUid, 1],
            );
            raw.execute(
              _insertV5DraftSql,
              ['p1', 'me@example.com', '没回填', 'y', 1762650060],
            );
            raw.execute('PRAGMA user_version = 5');
          },
        ),
      );
      addTearDown(db.close);

      final rows = await db.select(db.drafts).get();
      expect(rows, hasLength(2), reason: '重跑不能丢行、也不能重复建表');
      expect(rows.map((r) => r.uid), contains(keptUid),
          reason: '已经有 uid 的行不能再改身份');
      expect(rows.every((r) => r.uid.isNotEmpty), isTrue,
          reason: '上次没轮到的行这次回填');
      expect(rows.every((r) => r.rev == 1), isTrue);
      // 唯一索引仍然只有一条（`CREATE ... IF NOT EXISTS`）。
      expect(await _indexShape(db, 'drafts_uid_unique'), <Object?>[1, 1]);
    });
  });
}
