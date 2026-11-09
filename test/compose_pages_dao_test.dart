// 「正在编辑的撰写页」这一层的数据行为：打开标记与草稿行的 1:1、排序、
// 以及**迟到的保存不能复活已删草稿**。
//
// 这一层是三件事的共同地基：
// - 左侧「邮件撰写」列表（`watchOpenDrafts`）；
// - 草稿箱行上的「编辑中」标记（`watchOpenDraftIds`）；
// - 保存器的增量写（`updateDraftFields` 的 UPDATE-only 语义）。
// 任何一条在纯 widget 测试里都看不出来（它们只看到 UI 结果）。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('新建撰写页 = 一条草稿行 + 一个打开标记（草稿箱也看得到）', () async {
    final dao = db.localDao;
    final id = await dao.createComposeDraft(
      profileId: 'p1',
      subject: '写了一半',
    );

    final open = await dao.watchOpenDrafts().first;
    expect(open.map((d) => d.id), <int>[id]);
    expect(open.single.subject, '写了一半');

    // 草稿箱列的是**全部**草稿：打开中的这条当然也在里面。
    expect((await dao.watchDrafts().first).map((d) => d.id), <int>[id]);
    expect(await dao.watchOpenDraftIds().first, <int>{id});
  });

  test('排序：最后编辑时间倒序，同一毫秒按 id 倒序（新邮件在最前）', () async {
    final dao = db.localDao;
    final a = await dao.createComposeDraft(profileId: 'p1', subject: 'A');
    final b = await dao.createComposeDraft(profileId: 'p1', subject: 'B');
    final c = await dao.createComposeDraft(profileId: 'p1', subject: 'C');

    expect(
      (await dao.watchOpenDrafts().first).map((d) => d.id),
      <int>[c, b, a],
      reason: '新开的页面必须排在最前',
    );

    // 改一下最老那条的主题 → `updated_at` 刷新，它应该跑到最前。
    //
    // 隔 1.1s：drift 默认把 DateTime 存成**秒**（`drift_options` 没开
    // `storeDateTimeAsText`），同一秒内的两次写时间戳相同，排序会退到
    // 「id 倒序」那条兜底上。
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await dao.updateDraftFields(a, subject: 'A2');

    expect(
      (await dao.watchOpenDrafts().first).map((d) => d.id),
      <int>[a, c, b],
      reason: '最后编辑的那一封要在最前',
    );
  });

  test('markComposeOpen 幂等：反复从草稿箱点开同一封不会炸主键', () async {
    final dao = db.localDao;
    final id = await dao.createComposeDraft(profileId: 'p1');
    await dao.closeComposePage(id);
    expect(await dao.watchOpenDrafts().first, isEmpty);

    await dao.markComposeOpen(id);
    await dao.markComposeOpen(id);
    expect((await dao.watchOpenDrafts().first).map((d) => d.id), <int>[id]);
  });

  test('关闭撰写页只去标记，草稿内容留着', () async {
    final dao = db.localDao;
    final id = await dao.createComposeDraft(profileId: 'p1', subject: '留着');
    await dao.closeComposePage(id);

    expect(await dao.watchOpenDrafts().first, isEmpty);
    final draft = await dao.findDraft(id);
    expect(draft, isNotNull);
    expect(draft!.subject, '留着');
  });

  test('删草稿连打开标记一起删（一个事务，不留孤儿行）', () async {
    final dao = db.localDao;
    final id = await dao.createComposeDraft(profileId: 'p1');
    await dao.deleteDraft(id);

    expect(await dao.findDraft(id), isNull);
    expect(await dao.watchOpenDrafts().first, isEmpty);
    expect(
      await (db.select(db.composePages)
            ..where((t) => t.draftId.equals(id)))
          .get(),
      isEmpty,
    );
  });

  test('updateDraftFields 是 UPDATE-only：行被删之后写 0 行（不复活）', () async {
    final dao = db.localDao;
    final id = await dao.createComposeDraft(profileId: 'p1');
    await dao.deleteDraft(id);

    final rows = await dao.updateDraftFields(id, content: '迟到的内容');
    expect(rows, 0, reason: '保存器靠这个 0 判「行已不在」，绝不能 INSERT 回去');
    expect((await dao.watchDrafts().first), isEmpty);
  });

  test('updateDraftFields 只动传进来的列', () async {
    final dao = db.localDao;
    final id = await dao.createComposeDraft(
      profileId: 'p1',
      subject: '旧主题',
      content: '[{"insert":"正文\\n"}]',
    );

    await dao.updateDraftFields(id, subject: '新主题');

    final draft = await dao.findDraft(id);
    expect(draft!.subject, '新主题');
    // 没传 content：正文必须原样保留（否则就是「改主题把几 MB 的正文重写了
    // 一遍」那条写放大的另一面 —— 内容被意外清掉）。
    expect(draft.content, '[{"insert":"正文\\n"}]');
  });

  test('pruneComposePages 清掉指向已删草稿的孤儿标记', () async {
    final dao = db.localDao;
    final live = await dao.createComposeDraft(profileId: 'p1');
    // 直接造一个孤儿（正常路径不会，但进程可能死在两步之间）。
    await db.into(db.composePages).insert(
          ComposePagesCompanion.insert(
            draftId: const Value(99999),
            openedAt: DateTime.now().toUtc(),
          ),
        );

    await dao.pruneComposePages();

    final left = await db.select(db.composePages).get();
    expect(left.map((p) => p.draftId), <int>[live]);
  });
}
