// 撰写页草稿保存器：防写风暴 + 防复活。
//
// 这组用例盯的是**写库次数与写哪些列** —— 单靠 widget 测试看不出来（UI 上
// 「保存了」与「保存了一百次」长得一模一样），而写放大在正文带内联图片时
// 是每秒几 MB 的磁盘量。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/db/database.dart';
import 'package:mail_app/features/compose/compose_draft_saver.dart';

void main() {
  late AppDatabase db;
  late int draftId;

  ComposeDraftSaver saver({Duration debounce = const Duration(milliseconds: 60)}) =>
      ComposeDraftSaver(
        dao: db.localDao,
        draftId: draftId,
        debounce: debounce,
      );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    draftId = await db.localDao.createComposeDraft(profileId: 'p1');
  });

  tearDown(() async {
    await db.close();
  });

  test('防抖：停手之后只写一次，且写的是最后那一份', () async {
    final s = saver();
    s.markSaved(const ComposeDraftSnapshot());

    s.schedule(const ComposeDraftSnapshot(subject: '一'));
    s.schedule(const ComposeDraftSnapshot(subject: '一二'));
    s.schedule(const ComposeDraftSnapshot(subject: '一二三', content: 'body'));

    expect(s.writeCount, 0, reason: '打字期间不能写库');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(s.writeCount, 1, reason: '三次变化合并成一次写');
    final draft = await db.localDao.findDraft(draftId);
    expect(draft!.subject, '一二三');
    expect(draft.content, 'body');
  });

  test('指纹去重：内容没变的 schedule 不写库', () async {
    final s = saver();
    s.markSaved(const ComposeDraftSnapshot());

    s.schedule(const ComposeDraftSnapshot(subject: '同样的'));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(s.writeCount, 1);

    s.schedule(const ComposeDraftSnapshot(subject: '同样的'));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(s.writeCount, 1, reason: '重复快照必须被丢弃');
    expect(s.skippedCount, greaterThanOrEqualTo(1));
  });

  test('首次装载的基线：打开草稿后一个字没改，切走时不重写一遍', () async {
    final s = saver();
    const loaded = ComposeDraftSnapshot(
      subject: '旧信',
      content: '[{"insert":"几 MB 的正文\\n"}]',
    );
    s.markSaved(loaded);

    s.schedule(loaded);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(s.writeCount, 0, reason: '基线 = 库里已有内容，不该有写');
  });

  test('按列增量：只改主题时，content 不进 patch', () {
    const previous = ComposeDraftSnapshot(
      subject: '旧',
      content: 'BODY',
      recipientsJson: '["a@x.com"]',
      attachmentPaths: <String>['/tmp/a.pdf'],
    );
    const next = ComposeDraftSnapshot(
      subject: '新',
      content: 'BODY',
      recipientsJson: '["a@x.com"]',
      attachmentPaths: <String>['/tmp/a.pdf'],
    );

    final patch = changedDraftColumns(previous, next);
    expect(patch, isNotNull);
    expect(patch!.subject, '新');
    expect(patch.content, isNull, reason: '改主题不该重写正文那几 MB');
    expect(patch.recipientsJson, isNull);
    expect(patch.attachmentPaths, isNull);

    // 完全一样 → null（一个字段都不写）。
    expect(changedDraftColumns(previous, previous), isNull);
  });

  test('行被删之后迟到的保存：写 0 行、进死态、绝不复活', () async {
    final s = saver();
    s.markSaved(const ComposeDraftSnapshot());
    await db.localDao.deleteDraft(draftId);

    s.schedule(const ComposeDraftSnapshot(subject: '迟到'));
    await s.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(s.isDead, isTrue, reason: 'UPDATE 影响到 0 行就该判死');
    expect(await db.localDao.watchDrafts().first, isEmpty,
        reason: '已删的草稿不能被迟到的防抖写复活');
  });

  test('abandon 之后任何 schedule 都不再写', () async {
    final s = saver();
    s.markSaved(const ComposeDraftSnapshot());
    s.abandon();

    s.schedule(const ComposeDraftSnapshot(subject: '不该写'));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(s.writeCount, 0);
    expect((await db.localDao.findDraft(draftId))!.subject, '');
  });

  test('dispose 收尾：用页面最后拍的那份快照落盘', () async {
    final s = saver();
    s.markSaved(const ComposeDraftSnapshot());

    // 模拟「最后一次正文防抖还没烧完，页面就被切走了」。
    s.dispose(
      const ComposeDraftSnapshot(subject: '最后一句', content: 'FINAL'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final draft = await db.localDao.findDraft(draftId);
    expect(draft!.subject, '最后一句');
    expect(draft.content, 'FINAL');
  });

  test('上限兜底：一直不停手也至少落一次', () async {
    final s = ComposeDraftSaver(
      dao: db.localDao,
      draftId: draftId,
      debounce: const Duration(milliseconds: 20),
      maxWait: const Duration(milliseconds: 120),
    );
    s.markSaved(const ComposeDraftSnapshot());

    // 每 20ms 变一次，防抖永远烧不完；靠 maxWait 兜底。
    for (var i = 0; i < 10; i++) {
      s.schedule(ComposeDraftSnapshot(subject: '$i'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(s.writeCount, greaterThanOrEqualTo(1));
    expect((await db.localDao.findDraft(draftId))!.subject, '9');
  });
}
