// 七项 AI 能力 → 托管通道协议（`AiCall`）的翻译层。
//
// 这一层的输出**直接就是网关的请求体片段**（设计稿 §3.4），所以测试不是
// 「测行为」而是**钉契约**：字段名、稳定码、截断长度一个字母都不能漂。字段名
// 漂了网关回 400 `bad_input`；码值漂了模板选错措辞；截断长度漂了客户端与服务端
// 对「多大算太大」各说各话。
//
// 所以下面大量用 `jsonEncode` 快照：它同时钉住**键名、键序、值类型**。
import 'dart:convert';

import 'package:cirro_mail_ext/cirro_mail_ext.dart' show AiCall;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_prompts.dart';
import 'package:mail_app/features/ai/ai_task.dart';

/// `input` 的 JSON 快照 —— 键序也是契约的一部分（服务端按字段读，但人和 diff
/// 读键序；顺序漂了说明有人重排过整张表，值得停下来看一眼）。
String snapshot(AiCall call) => jsonEncode(call.input);

/// 造一串指定字数的中文。用「字」而不是字节：§3.4 的上限是**字数**。
String chars(int count) => '字' * count;

void main() {
  group('七个 map 的快照（字段名与类型）', () {
    test('rewrite：selection + tone', () {
      final call = AiTask.rewrite(selection: '原文', tone: RewriteTone.polish);
      expect(call.task, 'rewrite');
      expect(snapshot(call), '{"selection":"原文","tone":"polish"}');
    });

    test('draft：points + tone + length + 可选 subject/recipient', () {
      final call = AiTask.draft(
        points: '要点',
        tone: RewriteTone.formal,
        length: DraftLength.short,
        subject: '主题',
        recipient: 'a@example.com',
      );
      expect(call.task, 'draft');
      expect(
        snapshot(call),
        '{"points":"要点","tone":"formal","length":"short",'
        '"subject":"主题","recipient":"a@example.com"}',
      );
    });

    test('continuation：context + 可选 subject', () {
      final call = AiTask.continuation(context: '前半【光标位置】后半');
      expect(call.task, 'continuation');
      expect(snapshot(call), '{"context":"前半【光标位置】后半"}');
    });

    test('subject：body + 可选 current', () {
      final call = AiTask.subject(body: '正文');
      expect(call.task, 'subject');
      expect(snapshot(call), '{"body":"正文"}');
    });

    test('review：subject + body + attachmentCount（int）', () {
      final call = AiTask.review(subject: '', body: '正文', attachmentCount: 0);
      expect(call.task, 'review');
      expect(snapshot(call), '{"subject":"","body":"正文","attachmentCount":0}');
    });

    test('reply_suggestions：incoming + count（int）', () {
      final call = AiTask.replySuggestions(incoming: '来信', count: 3);
      expect(call.task, 'reply_suggestions');
      expect(snapshot(call), '{"incoming":"来信","count":3}');
    });

    test('suggest：input + actionIds（string[]）', () {
      final call = AiTask.suggest(
        input: '来信',
        actionIds: const <String>['reply', 'none'],
      );
      expect(call.task, 'suggest');
      expect(snapshot(call), '{"input":"来信","actionIds":["reply","none"]}');
    });
  });

  group('枚举 → 稳定码', () {
    test('六个 tone 码与网关一致，且与界面文案无关', () {
      const expected = <RewriteTone, String>{
        RewriteTone.polish: 'polish',
        RewriteTone.formal: 'formal',
        RewriteTone.friendly: 'friendly',
        RewriteTone.concise: 'concise',
        RewriteTone.translateEn: 'translateEn',
        RewriteTone.translateZh: 'translateZh',
      };
      expect(expected.keys.toSet(), RewriteTone.values.toSet());
      for (final entry in expected.entries) {
        final call = AiTask.rewrite(selection: '原文', tone: entry.key);
        expect(call.input['tone'], entry.value, reason: '${entry.key}');
      }
    });

    test('三个 length 码与网关一致', () {
      const expected = <DraftLength, String>{
        DraftLength.short: 'short',
        DraftLength.medium: 'medium',
        DraftLength.long: 'long',
      };
      expect(expected.keys.toSet(), DraftLength.values.toSet());
      for (final entry in expected.entries) {
        final call = AiTask.draft(
          points: '要点',
          tone: RewriteTone.polish,
          length: entry.key,
        );
        expect(call.input['length'], entry.value, reason: '${entry.key}');
      }
    });
  });

  group('可选字段：空串 / 空白 = 不带这个字段', () {
    test('rewrite 的 extraInstruction', () {
      expect(
        AiTask.rewrite(selection: '原文', tone: RewriteTone.polish)
            .input
            .containsKey('extraInstruction'),
        isFalse,
      );
      expect(
        AiTask.rewrite(
          selection: '原文',
          tone: RewriteTone.polish,
          extraInstruction: '   ',
        ).input.containsKey('extraInstruction'),
        isFalse,
      );
      expect(
        AiTask.rewrite(
          selection: '原文',
          tone: RewriteTone.polish,
          extraInstruction: '  短一点 ',
        ).input['extraInstruction'],
        '短一点',
        reason: '取值前先去首尾空白',
      );
    });

    test('draft 的 subject / recipient / continuation 的 subject / '
        'subject 的 current', () {
      expect(
        AiTask.draft(
          points: '要点',
          tone: RewriteTone.polish,
          length: DraftLength.medium,
        ).input.keys,
        <String>['points', 'tone', 'length'],
      );
      expect(
        AiTask.continuation(context: '正文', subject: '  ')
            .input
            .containsKey('subject'),
        isFalse,
      );
      expect(
        AiTask.subject(body: '正文', current: '')
            .input
            .containsKey('current'),
        isFalse,
      );
    });
  });

  group('字数截断（§3.4 的上限）', () {
    test('rewrite：selection ≤8000、extraInstruction ≤200', () {
      final call = AiTask.rewrite(
        selection: chars(8001),
        tone: RewriteTone.polish,
        extraInstruction: chars(201),
      );
      expect((call.input['selection']! as String).runes.length, 8000);
      expect((call.input['extraInstruction']! as String).runes.length, 200);
    });

    test('draft：points ≤4000', () {
      final call = AiTask.draft(
        points: chars(4001),
        tone: RewriteTone.polish,
        length: DraftLength.medium,
      );
      expect((call.input['points']! as String).runes.length, 4000);
    });

    test('continuation：context ≤6000', () {
      final call = AiTask.continuation(context: chars(6001));
      expect((call.input['context']! as String).runes.length, 6000);
    });

    test('subject：body ≤8000、current ≤200', () {
      final call = AiTask.subject(body: chars(8001), current: chars(201));
      expect((call.input['body']! as String).runes.length, 8000);
      expect((call.input['current']! as String).runes.length, 200);
    });

    test('review：subject ≤200、body ≤8000', () {
      final call = AiTask.review(
        subject: chars(201),
        body: chars(8001),
        attachmentCount: 2,
      );
      expect((call.input['subject']! as String).runes.length, 200);
      expect((call.input['body']! as String).runes.length, 8000);
    });

    test('reply_suggestions：incoming ≤8000', () {
      final call = AiTask.replySuggestions(incoming: chars(8001));
      expect((call.input['incoming']! as String).runes.length, 8000);
    });

    test('suggest：input ≤8000', () {
      final call = AiTask.suggest(input: chars(8001), actionIds: const ['none']);
      expect((call.input['input']! as String).runes.length, 8000);
    });

    test('没超长时**原样**（不 trim 正文，不多截一个字）', () {
      final text = '  ${chars(10)}  ';
      final call = AiTask.rewrite(selection: text, tone: RewriteTone.polish);
      expect(call.input['selection'], text);
    });

    test('按码点截断，不拆代理对（emoji 不会变成半个乱码）', () {
      // 🚀 是代理对（UTF-16 两个 code unit）。按 code unit 切会切出半个字符，
      // 界面上是一个替换符；按 runes 切是 8000 个完整字符。
      final call = AiTask.rewrite(selection: '🚀' * 8001, tone: RewriteTone.polish);
      final truncated = call.input['selection']! as String;
      expect(truncated.runes.length, 8000);
      expect(truncated.length, 16000, reason: '每个 emoji 仍占两个 code unit');
      expect(truncated.runes.last, 0x1F680, reason: '最后一个字符必须完整');
      expect(truncated, '🚀' * 8000);
    });
  });

  group('边界：条数 / 项数夹取', () {
    test('reply_suggestions 的 count 夹到 1–5', () {
      int countFor(int raw) =>
          AiTask.replySuggestions(incoming: '来信', count: raw)
              .input['count']! as int;
      expect(countFor(0), 1);
      expect(countFor(-3), 1);
      expect(countFor(1), 1);
      expect(countFor(3), 3);
      expect(countFor(5), 5);
      expect(countFor(9), 5);
    });

    test('suggest 的 actionIds 最多 12 项', () {
      final ids = <String>[for (var i = 0; i < 13; i++) 'action$i'];
      final call = AiTask.suggest(input: '来信', actionIds: ids);
      expect((call.input['actionIds']! as List<String>), hasLength(12));
      expect((call.input['actionIds']! as List<String>).first, 'action0');
    });

    test('suggest 的 actionIds 原样保序（解析器用同一份当白名单）', () {
      const ids = <String>['reply', 'star', 'none'];
      final call = AiTask.suggest(input: '来信', actionIds: ids);
      expect(call.input['actionIds'], ids);
    });
  });
}
