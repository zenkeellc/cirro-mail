import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_settings.dart';
import 'package:mail_app/features/ai/preflight.dart';

void main() {

  List<String> msg(List<PreflightFinding> f) => f.map((e) => e.message).toList();

  test('提到附件却没有附件 → 报', () {
    final f = AiPreflight.checkLocal(
      subject: '周报',
      bodyText: '详见附件，谢谢。',
      attachmentCount: 0,
      inlineImageCount: 0,
    );
    expect(msg(f), contains('正文里提到了附件，但这一封没有附件'));
  });

  test('提到附件且确实带了附件 → 不报', () {
    final f = AiPreflight.checkLocal(
      subject: '周报',
      bodyText: '详见附件，谢谢。',
      attachmentCount: 1,
      inlineImageCount: 0,
    );
    expect(msg(f), isNot(contains('正文里提到了附件，但这一封没有附件')));
  });

  test('英文说法也认', () {
    final f = AiPreflight.checkLocal(
      subject: 'Report',
      bodyText: 'Please see attached.',
      attachmentCount: 0,
      inlineImageCount: 0,
    );
    expect(msg(f), contains('正文里提到了附件，但这一封没有附件'));
  });

  test('只有内联图、没有附件 → 仍然算「没有附件」', () {
    final f = AiPreflight.checkLocal(
      subject: '图',
      bodyText: '见附件里的图。',
      attachmentCount: 0,
      inlineImageCount: 3,
    );
    expect(msg(f), contains('正文里提到了附件，但这一封没有附件'));
  });

  test('空主题 / 空正文各自报一条', () {
    final f = AiPreflight.checkLocal(
      subject: '   ',
      bodyText: '  ',
      attachmentCount: 0,
      inlineImageCount: 0,
    );
    expect(msg(f), contains('主题是空的'));
    expect(msg(f), contains('正文是空的'));
  });

  test('一切正常 → 一条都不报', () {
    final f = AiPreflight.checkLocal(
      subject: '你好',
      bodyText: '周末愉快。',
      attachmentCount: 0,
      inlineImageCount: 0,
    );
    expect(f, isEmpty);
  });

  test('「差点忘记加附件了」也命中（它确实提到了附件）', () {
    final f = AiPreflight.checkLocal(
      subject: 'x',
      bodyText: '差点忘记加附件了',
      attachmentCount: 0,
      inlineImageCount: 0,
    );
    expect(msg(f), contains('正文里提到了附件，但这一封没有附件'));
  });

  // ---- M-1：附件关键词的误报与漏报 ----
  List<PreflightFinding> check(String body) => AiPreflight.checkLocal(
        subject: 'x',
        bodyText: body,
        attachmentCount: 0,
        inlineImageCount: 0,
      );
  final hit = '正文里提到了附件，但这一封没有附件';

  test('M-1：裸子串误报不再报（随附近/已附近/已附言）', () {
    expect(msg(check('随附近的车一起送')), isNot(contains(hit)));
    expect(msg(check('已附近期行程安排')), isNot(contains(hit)));
    expect(msg(check('已附言如下')), isNot(contains(hit)));
  });

  test('M-1：真实说法要报（另附/附表/附图/附文件/附件如下）', () {
    for (final s in [
      '另附说明一份',
      '附表见下',
      '附图为现场照片',
      '附文件一份',
      '附件如下',
    ]) {
      expect(msg(check(s)), contains(hit), reason: s);
    }
  });

  test('M-1：英文说法与缩写要报（attach/enclosed/enc./see attached）', () {
    for (final s in [
      'please attach the report',
      'see attached for details',
      'the attachments are ready',
      'the file is enclosed',
      'enc. resume', // 常见英文缩写，不能漏
      'please see attached.',
    ]) {
      expect(msg(check(s)), contains(hit), reason: s);
    }
  });

  test('M-1：英文词边界不切掉 ed/ing（attached/attaching 都算）', () {
    expect(msg(check('I have attached it')), contains(hit));
    expect(msg(check('I am attaching it')), contains(hit));
  });

  test('M-1：正文正面写「不用带附件」仍然报（计划接受的行为）', () {
    // 刻意保留：那句话里**确实**出现了「附件」，模型/用户看到提示不亏；
    // 这一项是零成本提示，宁可多报一次也不放过「说了附件却没附件」。
    expect(msg(check('不用带附件，谢谢')), contains(hit));
  });

  test('local 标记：本地规则一律 local=true（用来说明「这些不花钱」）', () {
    final f = AiPreflight.checkLocal(
      subject: '',
      bodyText: '',
      attachmentCount: 0,
      inlineImageCount: 0,
    );
    expect(f.every((e) => e.local), isTrue);
  });

  test('设置里 preflightEnabled 关掉 → 整个不跑', () {
    expect(AiPreflight.shouldRun(const AiSettings(preflightEnabled: false)), isFalse);
    expect(AiPreflight.shouldRun(const AiSettings()), isTrue);
  });
}
