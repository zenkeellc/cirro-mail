/// Server-Sent Events 的**纯解析**层。
///
/// 与网络分开：`dio` 那部分只负责把字节流喂进来，解析规则（分帧、`data:` 拼接、
/// `[DONE]`）全在这里，于是它可以脱离 HTTP 单测 —— 流式解析错了的表现是
/// 「回答缺字/多字/永远不结束」，这类 bug 在 UI 上很难看出来，必须靠单测钉住。
///
/// 规则按 WHATWG 的 EventSource（只取我们需要的子集）：
/// - 一行以 `data:` 开头 → 该行内容进当前事件的载荷（去掉一个前导空格）；
/// - 空行 → **一个事件结束**（多个 `data:` 行用 `\n` 连接）；
/// - 以 `:` 开头 → 注释，忽略（厂商用它做心跳）；
/// - `event:` / `id:` / `retry:` → 记录，本项目不用但也不该当数据；
/// - 末尾若还有没被空行收尾的事件，**流结束时要吐出来**（OpenAI 兼容端点
///   常在最后一个 `data:` 后直接关流）。
class SseEvent {
  const SseEvent({required this.data, this.event});

  final String data;
  final String? event;

  bool get isDone => data.trim() == '[DONE]';
}

class SseDecoder {
  SseDecoder();

  final StringBuffer _data = StringBuffer();
  String? _event;
  String _pending = '';

  /// 喂一段字节（可能是半个事件）。产出**完整**的事件。
  List<SseEvent> add(String chunk) {
    _pending += chunk;
    final events = <SseEvent>[];
    while (true) {
      final breakAt = _indexOfLineBreak(_pending);
      if (breakAt == null) break;
      final line = _pending.substring(0, breakAt.index);
      _pending = _pending.substring(breakAt.index + breakAt.length);
      final event = _consumeLine(line);
      if (event != null) events.add(event);
    }
    return events;
  }

  /// 流结束：把没有空行收尾的最后一个事件补出来。
  ///
  /// 末尾可能残留一个**孤立的 `\r`**（它后面没有 `\n`，所以上面按 `\n` 找行尾
  /// 的逻辑从没把它当终止符）。CR 是 CRLF 的一半，同样该是行终止符 —— 不处理
  /// 的话它会留在最后一个事件的 data 尾部，下游 `jsonDecode` 失败、**最后一段
  /// 文本被静默丢掉**。所以收尾时先把它从缓冲区踢掉。
  SseEvent? finish() {
    if (_pending.endsWith('\r')) {
      _pending = _pending.substring(0, _pending.length - 1);
    }
    // 末尾可能是一个不带换行的完整行。
    if (_pending.isNotEmpty) {
      final event = _consumeLine(_pending);
      _pending = '';
      if (event != null) return event;
    }
    return _flush();
  }

  SseEvent? _consumeLine(String line) {
    if (line.isEmpty) return _flush();
    if (line.startsWith(':')) return null;
    if (line.startsWith('data:')) {
      var value = line.substring(5);
      if (value.startsWith(' ')) value = value.substring(1);
      if (_data.isNotEmpty) _data.write('\n');
      _data.write(value);
      return null;
    }
    if (line.startsWith('event:')) {
      _event = line.substring(6).trim();
      return null;
    }
    // id: / retry: / 其他字段一律忽略。
    return null;
  }

  SseEvent? _flush() {
    if (_data.isEmpty && _event == null) return null;
    final data = _data.toString();
    final event = _event;
    _data.clear();
    _event = null;
    return SseEvent(data: data, event: event);
  }

  static ({int index, int length})? _indexOfLineBreak(String raw) {
    final lf = raw.indexOf('\n');
    if (lf < 0) return null;
    // CRLF 也算一行的结束，且不能把 \r 留进数据里。
    if (lf > 0 && raw.codeUnitAt(lf - 1) == 0x0D) {
      return (index: lf - 1, length: 2);
    }
    return (index: lf, length: 1);
  }
}
