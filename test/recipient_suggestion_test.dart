import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/recipient_field.dart';

/// 回车该收下什么（`suggestionForCommit`）。
///
/// 这一段错了的表现是「回车之后地址凭空变了一个」或「明明看着有补全却
/// 报地址不合法」—— 两种都只在键盘操作下才出现，而它没有别的手段能观察到。
void main() {
  const suggestions = <({String address, String name})>[
    (address: 'zhang@example.com', name: 'Zhang'),
    (address: 'zhao@example.com', name: 'Zhao'),
  ];

  test('输入框里已经是完整地址 → 不动补全，原样提交', () {
    // 粘贴一行地址再回车是最常见的用法，这时用户没在看建议条。
    expect(suggestionForCommit('someone@example.com', suggestions), isNull);
    // 前后有空格也算完整地址：提交那边会 trim。
    expect(suggestionForCommit('  someone@example.com ', suggestions), isNull);
  });

  test('半截文字 + 有建议 → 收下第一条', () {
    expect(suggestionForCommit('zh', suggestions), 'zhang@example.com');
  });

  test('空输入 + 有建议 → 也收下第一条', () {
    expect(suggestionForCommit('', suggestions), 'zhang@example.com');
  });

  test('半截文字 + 没有建议 → 交回提交流程（该报错就报错）', () {
    expect(suggestionForCommit('zh', const []), isNull);
  });

  test('完整地址优先于建议 —— 即使建议条非空', () {
    // 这一条是上面第一条的哨兵：判据的顺序反过来的话，用户粘贴的地址
    // 会被替换成「最近联系人」里的第一个，而他没要那个。
    expect(suggestionForCommit('someone@example.com', suggestions), isNull);
  });
}
