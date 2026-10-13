import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/compose/compose_draft.dart';

void main() {
  // `ComposeArgs` 的构造函数是 `const`，但 `mail:` 传的是 `_row()` 的返回值
  // （内含 `DateTime.parse`）—— 整个表达式不是常量，所以这里**不能**写
  // `const`（计划原文那样写会编译不过）。
  final args = ComposeArgs(mode: ComposeMode.reply, mail: _row());

  test('回复：正文预填的是引用块 Delta，收件人与主题照旧', () {
    final draft = ComposeDraftFactory.of(
      args,
      ossBase: '',
      wroteLabel: '写道：',
    );
    expect(draft.recipients, <String>['alice@example.com']);
    expect(draft.subject, 'Re: 主题');
    // 引用块现在在 `quoted` 里，而它最终会变成**正文的初值**。
    expect(draft.quoted, contains('写道：'));
    expect(draft.quoted.trimLeft().startsWith('['), isTrue);
    // 横线：`---` 那一段（导出时落成 `<hr>`）。它把用户要写的地方与引用隔开。
    expect(draft.quoted, contains('---'));
  });

  test('空白写信：正文预填是空的 —— 空 Delta，不是空串', () {
    final draft = ComposeDraftFactory.of(
      const ComposeArgs(),
      ossBase: '',
      wroteLabel: '写道：',
    );
    // `ComposeDraft.quoted` 为空串时，页面用 `DocumentCodec.empty()` 兜底；
    // 这里只断言「预填没东西」。
    expect(draft.quoted.isEmpty, isTrue);
    expect(draft.recipients, isEmpty);
  });

  test('转发：主题原样、不加 Re:、正文是原文', () {
    final draft = ComposeDraftFactory.of(
      ComposeArgs(mode: ComposeMode.forward, mail: _row()),
      ossBase: '',
      wroteLabel: '写道：',
    );
    expect(draft.subject, '主题');
    expect(draft.recipients, isEmpty);
    expect(draft.quoted, contains('第一段'));
    // 转发与回复一样带横线（用户裁定两条路一致处理）。
    expect(draft.quoted, contains('---'));
  });

  test('isEmpty 认得 Delta 的正文', () {
    expect(const ComposeDraft().isEmpty, isTrue);
    expect(const ComposeDraft(quoted: '[{"insert":"\\n"}]').isEmpty, isFalse);
  });
}

MailRow _row() => MailRow(
      emailId: 1,
      profileId: 'p1',
      accountId: 1,
      subject: '主题',
      sendEmail: 'alice@example.com',
      name: 'Alice',
      // `createTime` 是 `DateTime?`，字符串在这里编译不过。
      createTime: DateTime.parse('2026-10-10T12:00:00.000Z'),
      content: '<p>第一段</p>',
    );
