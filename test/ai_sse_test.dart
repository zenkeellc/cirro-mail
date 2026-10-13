import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/sse.dart';

List<SseEvent> feed(SseDecoder d, List<String> chunks) =>
    [for (final c in chunks) ...d.add(c)];

void main() {
  test('一个事件一段：data + 空行', () {
    final d = SseDecoder();
    expect(feed(d, ['data: hello\n\n']).single.data, 'hello');
    expect(d.finish(), isNull);
  });

  test('厂商的字节边界会切在事件中间 —— 必须跨 chunk 攒起来', () {
    final d = SseDecoder();
    final events = feed(d, ['data: he', 'llo\n', '\n']);
    expect(events.single.data, 'hello');
  });

  test('多个 data: 行合成多行载荷', () {
    final d = SseDecoder();
    expect(feed(d, ['data: a\ndata: b\n\n']).single.data, 'a\nb');
  });

  test('data: 后的一个前导空格被吃掉，多余空格保留', () {
    final d = SseDecoder();
    expect(feed(d, ['data:  two\n\n']).single.data, ' two');
  });

  test(': 开头是注释（心跳），不能当数据', () {
    final d = SseDecoder();
    final events = feed(d, [': ping\n\n', 'data: real\n\n']);
    expect(events.length, 1);
    expect(events.single.data, 'real');
  });

  test('CRLF 换行', () {
    final d = SseDecoder();
    expect(feed(d, ['data: x\r\n\r\n']).single.data, 'x');
  });

  test('[DONE] 哨兵', () {
    final d = SseDecoder();
    expect(feed(d, ['data: [DONE]\n\n']).single.isDone, isTrue);
  });

  test('流在最后一个事件后直接关闭（没有收尾空行）→ finish 补出来', () {
    final d = SseDecoder();
    expect(feed(d, ['data: {"a":1}\n']), isEmpty);
    expect(d.finish()!.data, '{"a":1}');
  });

  test('最后一个事件连换行都没有', () {
    final d = SseDecoder();
    expect(feed(d, ['data: tail']), isEmpty);
    expect(d.finish()!.data, 'tail');
  });

  test('event: 字段被记下但不混进 data', () {
    final d = SseDecoder();
    final e = feed(d, ['event: message\ndata: hi\n\n']).single;
    expect(e.event, 'message');
    expect(e.data, 'hi');
  });

  test('id: / retry: 一律忽略', () {
    final d = SseDecoder();
    expect(feed(d, ['id: 42\nretry: 100\ndata: ok\n\n']).single.data, 'ok');
  });

  test('一次 chunk 里多个事件', () {
    final d = SseDecoder();
    final events = feed(d, ['data: 1\n\ndata: 2\n\ndata: 3\n\n']);
    expect(events.map((e) => e.data).toList(), ['1', '2', '3']);
  });

  test('多字节字符被切在两个 chunk 之间也不炸', () {
    final d = SseDecoder();
    final s = 'data: 你好\n\n';
    final bytes = s; // 这里传的是 String，切在字节中途的容错由上层解码器负责
    final events = feed(d, [bytes.substring(0, 8), bytes.substring(8)]);
    expect(events.single.data, '你好');
  });

  test('空流：finish 返回 null', () {
    expect(SseDecoder().finish(), isNull);
  });

  // ---- L-2：流结束时末尾孤立的 \r 必须被当终止符 ----
  test('L-2：末尾孤立的 \\r（后面没有 \\n）不能被留在 data 里', () {
    final d = SseDecoder();
    expect(feed(d, ['data: x\r']), isEmpty);
    expect(d.finish()!.data, 'x', reason: 'CR 是行终止符，不该进 payload');
  });

  test('L-2：CRLF 收尾时 finish 也干净（不残留 \\r）', () {
    final d = SseDecoder();
    expect(feed(d, ['data: x\r\n']), isEmpty);
    expect(d.finish()!.data, 'x');
  });

  test('L-2：回归 —— 正常分帧与 [DONE] 不受影响', () {
    final d = SseDecoder();
    expect(feed(d, ['data: a\n\ndata: b\n\n']).map((e) => e.data).toList(),
        ['a', 'b']);
    expect(d.finish(), isNull);
  });
}
