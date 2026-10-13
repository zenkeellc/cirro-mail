import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/drafts_screen.dart';
import 'package:mail_app/features/compose/html/document_codec.dart';

void main() {
  test('Delta 草稿的摘要显示的是文字，不是 JSON', () {
    final stored = DocumentCodec.encode(DocumentCodec.decode('你好\n\n再见'));
    final preview = DraftsScreen.previewForTest(stored);
    expect(preview, contains('你好'));
    expect(preview, contains('再见'));
    expect(preview, isNot(contains('insert')), reason: '摘要里出现了 Delta 的键名');
  });

  test('**旧草稿**（纯文本）照样能读 —— 本轮之前存的那些还在库里', () {
    expect(DraftsScreen.previewForTest('很久以前写的正文'), '很久以前写的正文');
  });

  test('坏数据不崩 —— 一条坏草稿不该让整个草稿箱打不开', () {
    expect(DraftsScreen.previewForTest('{"broken":'), isNotEmpty);
  });

  test('空草稿给空串', () {
    expect(DraftsScreen.previewForTest(''), '');
  });

  test('**畸形 Delta** 也不显示 JSON —— 建不出来的那份，摘要给空串', () {
    // 这三条都能过 `DocumentCodec` 的嗅探（元素含 insert、末 op 以 \n 收尾），
    // 但 `Document.fromJson` 会在类型 cast 上抛，于是 `decode` 退回「当纯文本」，
    // 摘要就会把原始 JSON 原样显示出来 —— 那正是这个任务要消灭的东西。
    for (final broken in <String>[
      '[{"insert":123},{"insert":"\\n"}]',
      '[{"insert":null},{"insert":"\\n"}]',
      '[{"insert":"a\\n","attributes":"x"}]',
    ]) {
      final preview = DraftsScreen.previewForTest(broken);
      expect(
        preview,
        isNot(contains('insert')),
        reason: '摘要里出现了 Delta 的键名（输入：$broken）',
      );
      expect(preview, isNot(contains('{')), reason: '摘要里出现了 JSON 结构');
    }
  });

  test('但**真正**的 Delta 草稿照旧出文字（别把这半边一起误伤）', () {
    final stored = DocumentCodec.encode(DocumentCodec.decode('你好'));
    expect(DraftsScreen.previewForTest(stored), '你好');
  });
}
