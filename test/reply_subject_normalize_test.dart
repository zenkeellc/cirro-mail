// 回复主题的归一化：把见过的前缀剥干净，再套**本地化模板**。
//
// 这一组单独成文件（而不是塞进 `compose_reply_draft_test.dart`）：前缀识别
// 是纯字符串逻辑，边界（大小写、全角冒号、前缀链、空主题、幂等）比回复页
// 其它行为多得多，混在一起看不住。真实模板来自 ARB，所以最后一条用例直接
// 用生成的 `AppLocalizations` 验「ARB 与归一化对得上」。
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/compose_draft.dart';
import 'package:mail_app/l10n/app_localizations.dart';

/// 中文模板（`app_zh.arb` 的 `replySubject` = `答复 {subject}`）。
String zh(String subject) => '答复 $subject';

/// 英文模板（`app_en.arb` 的 `replySubject` = `Re: {subject}`）。
String en(String subject) => 'Re: $subject';

String normalized(String original, String Function(String) template) =>
    ComposeDraftFactory.replySubject(original, template);

void main() {
  group('套模板', () {
    test('没有前缀：直接套', () {
      expect(normalized('主题', zh), '答复 主题');
      expect(normalized('主题', en), 'Re: 主题');
    });

    test('两端空白先 trim（主题里不留「答复  主题」）', () {
      expect(normalized('  主题  ', zh), '答复 主题');
      expect(normalized('\t主题\n', zh), '答复 主题');
    });

    test('空主题也套模板（与改造前的 `Re: ` 同形）', () {
      expect(normalized('', zh), '答复 ');
      expect(normalized('   ', zh), '答复 ');
      expect(normalized('', en), 'Re: ');
    });
  });

  group('剥前缀', () {
    test('Web 端那四种都认（含全角冒号）', () {
      for (final subject in <String>[
        'Re: 主题',
        'Re：主题',
        '回复：主题',
        '回复: 主题',
      ]) {
        expect(normalized(subject, zh), '答复 主题', reason: '输入：$subject');
      }
    });

    test('我们自己写出来的「答复」也认（带空格与冒号两种）', () {
      for (final subject in <String>[
        '答复 主题',
        '答复：主题',
        '答复: 主题',
      ]) {
        expect(normalized(subject, zh), '答复 主题', reason: '输入：$subject');
      }
    });

    test('大小写不敏感：`re:` / `RE:` 一样算回复', () {
      expect(normalized('re: 主题', zh), '答复 主题');
      expect(normalized('RE:主题', zh), '答复 主题');
      expect(normalized('Re: 主题', en), 'Re: 主题');
    });

    test('前缀链（别人叠了好几层）也剥到只剩主题', () {
      expect(normalized('Re: Re: 主题', zh), '答复 主题');
      expect(normalized('Re: 回复：主题', zh), '答复 主题');
      expect(normalized('答复 Re: 主题', zh), '答复 主题');
      expect(normalized('答复：Re：回复: 主题', zh), '答复 主题');
      expect(normalized('Re: Re: Re: 主题', en), 'Re: 主题');
    });

    test('中英混着切界面也不叠前缀', () {
      // 中文界面里答复了一封英文前缀的信，再切英文界面答复同一封。
      final once = normalized('Re: 主题', zh); // 答复 主题
      expect(once, '答复 主题');
      expect(normalized(once, en), 'Re: 主题');
      expect(normalized(normalized(once, en), zh), '答复 主题');
    });
  });

  group('幂等', () {
    test('「答复 xxx」再答复仍是「答复 xxx」', () {
      final once = normalized('主题', zh);
      expect(normalized(once, zh), once);
      expect(normalized(normalized(once, zh), zh), once);
    });

    test('「Re: xxx」再答复仍是「Re: xxx」', () {
      final once = normalized('主题', en);
      expect(normalized(once, en), once);
      expect(normalized(normalized(once, en), en), once);
    });

    test('空主题答复两次不会变成「答复 答复 」', () {
      final once = normalized('', zh);
      expect(once, '答复 ');
      expect(normalized(once, zh), '答复 ');
    });
  });

  test('生成的 ARB 模板与归一化对得上', () async {
    final zhL10n = await AppLocalizations.delegate.load(const Locale('zh'));
    final enL10n = await AppLocalizations.delegate.load(const Locale('en'));

    // 模板本身：中文是「答复 xxx」、英文还是「Re: xxx」。
    expect(zhL10n.replySubject('主题'), '答复 主题');
    expect(enL10n.replySubject('主题'), 'Re: 主题');

    // 真实调用点传的就是这两个函数（`ComposeController.build` /
    // `MailActionRunner`），归一化结果必须与上面直接套模板一致。
    expect(
      ComposeDraftFactory.replySubject('Re: 主题', zhL10n.replySubject),
      '答复 主题',
    );
    expect(
      ComposeDraftFactory.replySubject('答复 主题', enL10n.replySubject),
      'Re: 主题',
    );
  });
}
