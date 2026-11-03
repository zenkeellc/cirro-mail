import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';

/// `.eml` 附件（RFC 822 + MIME）→ 「把它当一封信看」需要的东西。
///
/// 只做预览要的那一半：把头、正文（含 `multipart/*`、传输编码、字符集）解出来，
/// 够 `EmlViewerScreen` 画成邮件，而**不**落库、也**不**把信里带的附件解出来
/// （那要写盘 + 另存为入口，是另一件事；预览只列名字与大小）。
///
/// ## 为什么自己写，不引一个 MIME 库
///
/// 需要的只有三件：拆 multipart、两种传输编码（base64 / quoted-printable）、
/// 字符集换算。`postal-mime` 那类库会把整封信按对象树建出来、把每个附件都
/// 解成 base64 字符串 —— 我们不看那个，却要付一份依赖与五个平台的差异。
/// 而字符集换算本仓已经有 `package:charset`（`charset` 在 pubspec 里，
/// `text_codec.dart` 用它解 GB18030），不必再要第二套。
///
/// 与 `text_codec.dart` 的分工：那边面向**整份文件**（没有任何声明，只能嗅探），
/// 这边面向**单个 MIME 部件**（部件自己声明了 `charset`，就该听它的）。
/// 只有在没声明（或声明了本仓解不了的编码）时，两者的兜底顺序才一致：
/// 严格 UTF-8 → GB18030 → 宽容 UTF-8。
///
/// ## 已知的取舍
///
/// - `cid:` 内嵌图**不**转成 data URI：`HtmlBodyView` 那条渲染链（`fwfh_*`）
///   没有 data URI 支持，转出来也是一张破图。正文里留着 `cid:`，看起来就是
///   一个没加载出来的图 —— 与本仓「外部资源默认拦截」的既有观感一致。
/// - 时区只认 `+0800` 这种数字偏移与 `GMT/UTC/UT/Z`；`EST` 这类字母缩写按
///   UTC 处理（RFC 5322 早就不建议用缩写，实际邮件里也几乎见不到）。
/// - 信里带子邮件（`message/rfc822`）只列成附件，不递归渲染。

/// 邮件头里的一个地址。
class EmlAddress {
  const EmlAddress({required this.address, this.name = ''});

  /// `foo@example.com`。畸形头里可能是空串。
  final String address;

  /// 显示名（已解掉 RFC 2047 编码），可能为空。
  final String name;

  /// `名字 <地址>`；缺哪一半就只显示另一半。
  String get display {
    if (name.isEmpty) return address;
    if (address.isEmpty) return name;
    return '$name <$address>';
  }
}

/// 信里带的附件 —— **只读信息**（预览不解它的字节）。
class EmlAttachment {
  const EmlAttachment({
    required this.filename,
    required this.mimeType,
    required this.size,
  });

  /// 可能为空：很多信把附件名写在 `name=` / `filename=` 里，但也有什么都不写的。
  /// 界面上的兜底文案由调用方决定（这一层不认 l10n）。
  final String filename;
  final String mimeType;
  final int size;
}

/// 解析结果。
class EmlMessage {
  const EmlMessage({
    this.subject = '',
    this.from = const <EmlAddress>[],
    this.to = const <EmlAddress>[],
    this.cc = const <EmlAddress>[],
    this.date,
    this.html,
    this.text,
    this.attachments = const <EmlAttachment>[],
  });

  /// 已解掉 RFC 2047 编码。空串表示没有主题（界面显示「（无主题）」）。
  final String subject;
  final List<EmlAddress> from;
  final List<EmlAddress> to;
  final List<EmlAddress> cc;

  /// UTC 时刻；头里没有 `Date` 或解析不出来时是 null。
  final DateTime? date;

  /// 正文的两个候选。`html` 有就优先渲染它（`multipart/alternative` 里的
  /// 排版版本），否则退回 `text`。
  final String? html;
  final String? text;

  final List<EmlAttachment> attachments;

  /// 有没有能显示出来的正文。
  bool get hasBody => (html?.trim().isNotEmpty ?? false) ||
      (text?.trim().isNotEmpty ?? false);
}

/// 解析一份 `.eml`。
///
/// **返回 null 表示「这不是一封能认出来的邮件」**（没有可识别的头部）。
/// 调用方据此退回「看原文」——把一份普通文本当成 `.eml` 打开是有的（发给
/// 自己的 .txt 被误标成 `message/rfc822`），那时给一句人话比画一个空邮件好。
EmlMessage? parseEml(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final split = _splitHead(data);
  if (split == null) return null;
  final headers = _parseHeaderBlock(split.headerText);
  if (!_looksLikeMessage(headers)) return null;

  final collector = _Collector();
  _walk(_MimePart(headers: headers, body: split.body), collector);

  return EmlMessage(
    subject: _decodeHeader(_first(headers, 'subject') ?? '').trim(),
    from: _parseAddresses(_first(headers, 'from') ?? ''),
    to: _parseAddresses(_first(headers, 'to') ?? ''),
    cc: _parseAddresses(_first(headers, 'cc') ?? ''),
    date: _parseDate(_first(headers, 'date') ?? ''),
    html: collector.html,
    text: collector.text,
    attachments: collector.attachments,
  );
}

/// 认得出的「这确实是一封信」的头部。
///
/// 挡掉「一份普通文本，第一行恰好是 `key: value`」这种误判：那种输入既没有
/// From/To/Subject/Date，也没有任何 MIME 头，画出来会是一个四不像的空邮件，
/// 比老老实实退回「看原文」还差。
const Set<String> _recognizableHeaders = <String>{
  'from',
  'to',
  'cc',
  'bcc',
  'sender',
  'reply-to',
  'subject',
  'date',
  'message-id',
  'mime-version',
  'content-type',
};

bool _looksLikeMessage(Map<String, List<String>> headers) => headers.keys
    .any(_recognizableHeaders.contains);

// ------------------------------------------------------------------ 结构拆分

/// 一段「头部 + 正文」的字节。
class _Split {
  const _Split(this.headerText, this.body);

  final String headerText;
  final Uint8List body;
}

/// 把一份字节切成「头部文本 + 正文字节」。
///
/// 整个结构扫描都在 `latin1.decode` 出来的字符串上做：那是一次**逐字节、
/// 码元等于字节值**的映射（0–255 → 0–255），所以字符串下标与字节偏移一一对应，
/// 拿 `substring` 找到的位置去 `sublistView` 字节数组不会错位。反过来先 `utf8`
/// 解再找空行是不行的：非法字节会被替换成 U+FFFD，索引就漂了。
_Split? _splitHead(Uint8List data) {
  final latin = latin1.decode(data);
  final index = _headerEnd(latin);
  if (index == null) {
    // 没有空行。如果第一行像 `键: 值`，当「只有头、没有正文」；
    // 否则（比如一份随手的 .txt）直接判「不是邮件」。
    final first = latin.split(RegExp(r'\r\n|\n|\r')).first;
    if (!_looksLikeHeaderLine(first)) return null;
    return _Split(latin, Uint8List(0));
  }
  return _Split(
    latin.substring(0, index.$1),
    Uint8List.sublistView(data, index.$2),
  );
}

/// 头部结束的位置 → `(头部文本长度, 正文起点)`。
///
/// 认 `\r\n\r\n` / `\n\n` / `\r\n\n` / `\n\r\n` 这几种混排（历史上真的见得到：
/// 有的客户端把内嵌部件的换行写成裸 CRLF、外层写成裸 LF）。
(int, int)? _headerEnd(String latin) {
  for (var i = 0; i < latin.length; i++) {
    final ch = latin[i];
    if (ch != '\r' && ch != '\n') continue;
    var cursor = i;
    if (latin[cursor] == '\r') cursor++;
    if (cursor < latin.length && latin[cursor] == '\n') cursor++;
    // `cursor` = 下一行开头。到文件尾说明整份都是头部。
    if (cursor >= latin.length) return (i, cursor);
    if (latin[cursor] == '\r' || latin[cursor] == '\n') {
      var after = cursor;
      if (latin[after] == '\r') after++;
      if (after < latin.length && latin[after] == '\n') after++;
      return (i, after);
    }
  }
  return null;
}

bool _looksLikeHeaderLine(String line) {
  final colon = line.indexOf(':');
  if (colon <= 0) return false;
  final name = line.substring(0, colon).trim();
  if (name.isEmpty) return false;
  // 头部字段名只能是标准 token；带空格的多半是正文里的一句 `时间: 12:00`。
  return !name.contains(' ') && !name.contains('\t');
}

Map<String, List<String>> _parseHeaderBlock(String text) {
  final out = <String, List<String>>{};
  String? lastName;
  for (final rawLine in text.split(RegExp(r'\r\n|\n|\r'))) {
    if (rawLine.isEmpty) continue;
    // 折行：以空格 / Tab 开头的行是上一个头部的续行。
    if (rawLine.startsWith(' ') || rawLine.startsWith('\t')) {
      if (lastName == null) continue;
      final values = out[lastName]!;
      values[values.length - 1] = '${values.last} ${rawLine.trim()}';
      continue;
    }
    final colon = rawLine.indexOf(':');
    if (colon <= 0) {
      lastName = null;
      continue;
    }
    final name = rawLine.substring(0, colon).trim().toLowerCase();
    if (name.isEmpty || name.contains(' ')) {
      lastName = null;
      continue;
    }
    (out[name] ??= <String>[]).add(rawLine.substring(colon + 1).trim());
    lastName = name;
  }
  return out;
}

String? _first(Map<String, List<String>> headers, String name) {
  final values = headers[name];
  if (values == null || values.isEmpty) return null;
  return values.first;
}

// ------------------------------------------------------------------ MIME 递归

class _MimePart {
  const _MimePart({required this.headers, required this.body});

  final Map<String, List<String>> headers;
  final Uint8List body;

  String? first(String name) => _first(headers, name);
}

class _Collector {
  String? html;
  String? text;
  final List<EmlAttachment> attachments = <EmlAttachment>[];
}

void _walk(_MimePart part, _Collector out) {
  final type = _parseHeaderParams(part.first('content-type'));
  final mime = type.value.isEmpty ? 'text/plain' : type.value;

  if (mime.startsWith('multipart/')) {
    final boundary = type.params['boundary'];
    if (boundary == null || boundary.isEmpty) return;
    for (final child in _splitMultipart(part.body, boundary)) {
      _walk(child, out);
    }
    return;
  }

  final disposition = _parseHeaderParams(part.first('content-disposition'));
  final isAttachment = disposition.value == 'attachment';
  final isInline = disposition.value == 'inline' ||
      part.first('content-id') != null;

  // 子邮件（转发出去的那封）与显式标了 attachment 的部件：只记信息。
  if (mime == 'message/rfc822' || isAttachment) {
    out.attachments.add(_describeAttachment(part, mime, type, disposition));
    return;
  }

  if (mime == 'text/html' || mime == 'text/plain') {
    final decoded = _decodeCharset(
      _decodeTransfer(part.body, part.first('content-transfer-encoding')),
      type.params['charset'],
    );
    // 空正文不算「有正文」：很多客户端会往 `multipart/alternative` 里塞一个
    // 空的 text/plain，占了候选位就会把真正的 html 挡在门外。
    if (decoded.trim().isEmpty) return;
    if (mime == 'text/html') {
      // `multipart/alternative` 的分部顺序是「从最不像到最像」，
      // 同一个容器里后面的 html 才是首选，所以这里**后写覆盖前写**。
      out.html = decoded;
    } else {
      out.text = decoded;
    }
    return;
  }

  // 内嵌资源（cid: 图片、字体）：不列成附件，用户也不会想在这里看见它。
  if (isInline) return;

  out.attachments.add(_describeAttachment(part, mime, type, disposition));
}

EmlAttachment _describeAttachment(
  _MimePart part,
  String mime,
  _HeaderParams type,
  _HeaderParams disposition,
) {
  final rawName = disposition.params['filename'] ?? type.params['name'] ?? '';
  return EmlAttachment(
    filename: _decodeHeader(rawName).trim(),
    mimeType: mime,
    size: _decodedSize(part.body, part.first('content-transfer-encoding')),
  );
}

/// 附件的**解码后**大小。
///
/// base64 用「数非填充字符 × 3/4」估，不真的解一遍：一个 10MB 的附件解出来
/// 只是为了报一个数字，内存不值。误差在 ±2 字节（base64 填充），对
/// 「1.5 MB」这种显示没有影响。
int _decodedSize(Uint8List body, String? contentTransferEncoding) {
  final mode = (contentTransferEncoding ?? '').trim().toLowerCase();
  if (mode != 'base64') return body.length;
  var count = 0;
  for (final byte in body) {
    // 空白与填充不算有效字节。
    if (byte == 0x0A || byte == 0x0D || byte == 0x20 || byte == 0x09) continue;
    if (byte == 0x3D) continue; // '='
    count++;
  }
  return (count * 3) ~/ 4;
}

/// 按 boundary 拆 multipart 正文。
///
/// 分隔行是 `--<boundary>`（结束那行是 `--<boundary>--`），**必须独占一行**，
/// 行尾可以有空白、可以有 `\r`。切出来的每一段再各自当一封信解析（它自己
/// 也有头 + 正文）。
List<_MimePart> _splitMultipart(Uint8List body, String boundary) {
  final latin = latin1.decode(body);
  final pattern = RegExp(
    '^--${RegExp.escape(boundary)}(--)?[ \\t]*\\r?\$',
    multiLine: true,
  );
  final matches = pattern.allMatches(latin).toList(growable: false);
  final parts = <_MimePart>[];

  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    if (match.group(1) != null) break; // 结束分隔线之后不再有部件
    final start = _afterLineBreak(latin, match.end);
    if (start >= latin.length) break;
    var end = i + 1 < matches.length ? matches[i + 1].start : latin.length;
    // 下一个分隔线前那一处换行属于分隔线，不属于这一段正文。
    end = _trimLineBreak(latin, start, end);
    if (end <= start) {
      parts.add(_MimePart(headers: const <String, List<String>>{}, body: Uint8List(0)));
      continue;
    }
    final section = latin.substring(start, end);
    final head = _headerEnd(section);
    if (head == null) {
      parts.add(_MimePart(
        headers: const <String, List<String>>{},
        body: Uint8List.sublistView(body, start, end),
      ));
      continue;
    }
    parts.add(_MimePart(
      headers: _parseHeaderBlock(section.substring(0, head.$1)),
      body: Uint8List.sublistView(body, start + head.$2, end),
    ));
  }
  return parts;
}

/// `end` 可能正好停在 `\n` 上（`$` 在它前面匹配），跳过这一个换行符。
int _afterLineBreak(String latin, int end) {
  if (end < latin.length && latin[end] == '\n') return end + 1;
  return end;
}

int _trimLineBreak(String latin, int start, int end) {
  var cursor = end;
  if (cursor > start && latin[cursor - 1] == '\n') cursor--;
  if (cursor > start && latin[cursor - 1] == '\r') cursor--;
  return cursor;
}

// ------------------------------------------------------------------ 编码解码

/// 传输编码（base64 / quoted-printable）。7bit / 8bit / binary / 没写 → 原样。
List<int> _decodeTransfer(Uint8List body, String? contentTransferEncoding) {
  final mode = (contentTransferEncoding ?? '').trim().toLowerCase();
  switch (mode) {
    case 'base64':
      return _decodeBase64(body);
    case 'quoted-printable':
      return _decodeQuotedPrintable(body);
    default:
      return body;
  }
}

List<int> _decodeBase64(List<int> body) {
  // base64 正文里允许任意换行与缩进，先把非字母表字符剔掉。
  final buffer = StringBuffer();
  for (final byte in body) {
    final isBase64 = (byte >= 0x41 && byte <= 0x5A) || // A-Z
        (byte >= 0x61 && byte <= 0x7A) || // a-z
        (byte >= 0x30 && byte <= 0x39) || // 0-9
        byte == 0x2B || // +
        byte == 0x2F || // /
        byte == 0x3D; // =
    if (isBase64) buffer.writeCharCode(byte);
  }
  final clean = buffer.toString();
  if (clean.isEmpty) return const <int>[];
  final padded = clean.length % 4 == 0
      ? clean
      : clean.padRight(clean.length + (4 - clean.length % 4), '=');
  try {
    return base64.decode(padded);
  } on FormatException {
    return const <int>[];
  }
}

/// quoted-printable：`=XX` 是字节，行尾的 `=` 是软换行（下一行接着来）。
List<int> _decodeQuotedPrintable(List<int> body) {
  final out = <int>[];
  for (var i = 0; i < body.length; i++) {
    final byte = body[i];
    if (byte != 0x3D) {
      out.add(byte);
      continue;
    }
    // `=` + `\n` 或 `=` + `\r\n`：软换行，两个/三个字节一起去掉。
    if (i + 1 < body.length && body[i + 1] == 0x0A) {
      i += 1;
      continue;
    }
    if (i + 2 < body.length && body[i + 1] == 0x0D && body[i + 2] == 0x0A) {
      i += 2;
      continue;
    }
    if (i + 2 < body.length) {
      final hi = _hexValue(body[i + 1]);
      final lo = _hexValue(body[i + 2]);
      if (hi >= 0 && lo >= 0) {
        out.add((hi << 4) | lo);
        i += 2;
        continue;
      }
    }
    // 孤零零的 `=`：原样留着，比悄悄吃掉一个字符好。
    out.add(byte);
  }
  return out;
}

int _hexValue(int byte) {
  if (byte >= 0x30 && byte <= 0x39) return byte - 0x30; // 0-9
  if (byte >= 0x41 && byte <= 0x46) return byte - 0x41 + 10; // A-F
  if (byte >= 0x61 && byte <= 0x66) return byte - 0x61 + 10; // a-f
  return -1;
}

/// 按声明解字符集；没声明（或解不了）时走嗅探。
String _decodeCharset(List<int> bytes, String? charset) {
  final name = (charset ?? '').trim().toLowerCase();
  if (name.isNotEmpty) {
    final encoding = Charset.getByName(name);
    if (encoding != null) {
      try {
        return encoding.decode(bytes);
      } catch (_) {
        // 声明与实际字节对不上（发件方写错 charset 很常见）：落到嗅探。
      }
    }
  }
  return _decodeSniffed(Uint8List.fromList(bytes));
}

/// 没有可信声明时的兜底，**顺序与 `text_codec.decodeText` 一致**（理由见
/// 那个文件：合法 UTF-8 用 GBK 解一定出乱码且不报错，所以严格 UTF-8 必须先试；
/// GB18030 向后兼容 GBK / GB2312；最后宽容 UTF-8 至少给点东西看）。
String _decodeSniffed(Uint8List data) {
  try {
    return const Utf8Decoder(allowMalformed: false).convert(data);
  } on FormatException {
    // 继续往下试。
  }
  try {
    return gbk.decode(data);
  } catch (_) {
    // 继续往下试。
  }
  return const Utf8Decoder(allowMalformed: true).convert(data);
}

// ------------------------------------------------------------------ 头部解析

/// RFC 2047 编码词：`=?UTF-8?B?xxxx?=`。
final RegExp _encodedWord = RegExp(r'=\?([^?*]+)\?([bBqQ])\?([^?]*)\?=');

String _decodeHeader(String raw) {
  if (!raw.contains('=?')) return raw;
  final out = StringBuffer();
  var cursor = 0;
  var encodedBefore = false;
  for (final match in _encodedWord.allMatches(raw)) {
    final between = raw.substring(cursor, match.start);
    // RFC 2047：两个相邻编码词之间的空白要丢掉，否则一个中文主题会多出空格。
    if (!(encodedBefore && between.trim().isEmpty)) out.write(between);
    out.write(_decodeWord(
      match.group(1)!,
      match.group(2)!,
      match.group(3)!,
    ));
    cursor = match.end;
    encodedBefore = true;
  }
  if (cursor == 0) return raw;
  out.write(raw.substring(cursor));
  return out.toString();
}

String _decodeWord(String charset, String encoding, String payload) {
  if (encoding == 'B' || encoding == 'b') {
    return _decodeCharset(_decodeBase64(latin1.encode(payload)), charset);
  }
  // Q 编码里 `_` 代表空格。
  return _decodeCharset(
    _decodeQuotedPrintable(latin1.encode(payload.replaceAll('_', ' '))),
    charset,
  );
}

/// `text/html; charset=utf-8` 这种头的拆解结果。
class _HeaderParams {
  const _HeaderParams(this.value, this.params);

  /// 主值（小写）：`text/html`、`attachment`、`multipart/alternative`。
  final String value;
  final Map<String, String> params;
}

_HeaderParams _parseHeaderParams(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const _HeaderParams('', <String, String>{});
  }
  final segments = _splitParams(raw);
  final params = <String, String>{};
  for (final segment in segments.skip(1)) {
    final eq = segment.indexOf('=');
    if (eq <= 0) continue;
    final key = segment.substring(0, eq).trim().toLowerCase();
    var value = segment.substring(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    params[key] = value.replaceAll(r'\"', '"');
  }
  return _HeaderParams(segments.first.trim().toLowerCase(), params);
}

/// 按 `;` 切，引号里的不切（`boundary="a;b"` 是合法的）。
List<String> _splitParams(String raw) {
  final out = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == '"') quoted = !quoted;
    if (ch == ';' && !quoted) {
      out.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(ch);
  }
  out.add(buffer.toString());
  return out;
}

List<EmlAddress> _parseAddresses(String raw) {
  if (raw.trim().isEmpty) return const <EmlAddress>[];
  final out = <EmlAddress>[];
  for (final item in _splitAddressList(raw)) {
    final text = item.trim();
    if (text.isEmpty) continue;
    final open = text.lastIndexOf('<');
    final close = open < 0 ? -1 : text.indexOf('>', open + 1);
    var name = '';
    var address = text;
    if (open >= 0 && close > open) {
      name = text.substring(0, open).trim();
      address = text.substring(open + 1, close).trim();
    }
    name = _decodeHeader(name).replaceAll(RegExp(r'^"|"$'), '').trim();
    address = _decodeHeader(address).trim();
    if (address.toLowerCase().startsWith('mailto:')) {
      address = address.substring('mailto:'.length);
    }
    // `undisclosed-recipients:;` 这种组名不是地址，但当名字显示比丢掉强。
    if (!address.contains('@') && address.contains(':')) {
      name = name.isEmpty ? address : name;
      address = '';
    }
    if (name.isEmpty && address.isEmpty) continue;
    out.add(EmlAddress(address: address, name: name));
  }
  return out;
}

/// 按**顶层**逗号切地址串：引号里的、`<>` 里的逗号不算。
List<String> _splitAddressList(String raw) {
  final out = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  var angle = 0;
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == '"') quoted = !quoted;
    if (!quoted && ch == '<') angle++;
    if (!quoted && ch == '>' && angle > 0) angle--;
    if (ch == ',' && !quoted && angle == 0) {
      out.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(ch);
  }
  out.add(buffer.toString());
  return out;
}

const Map<String, int> _months = <String, int>{
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// `Tue, 03 Nov 2026 05:36:47 +0000` → UTC 时刻。
///
/// 不用 `HttpDate.parse`：它只认 RFC 1123 的 `GMT`，而邮件里普遍是 `+0800`
/// 这种数字偏移（Gmail 导出的 `.eml` 就是）。
DateTime? _parseDate(String raw) {
  final cleaned = raw
      .replaceAll(RegExp(r'\([^)]*\)'), ' ') // 注释（时区名常写在这里）
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return null;
  final match = RegExp(
    r'^(?:[A-Za-z]{2,4},?\s+)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+'
    r'(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s*([+-]\d{4}|[A-Za-z]{1,5}))?',
  ).firstMatch(cleaned);
  if (match == null) return null;
  final month = _months[match.group(2)!.toLowerCase()];
  if (month == null) return null;

  var year = int.parse(match.group(3)!);
  if (year < 100) year += year < 50 ? 2000 : 1900;

  final local = DateTime.utc(
    year,
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.tryParse(match.group(6) ?? '') ?? 0,
  );

  final zone = match.group(7) ?? '';
  var offsetMinutes = 0;
  if (zone.length == 5 && (zone.startsWith('+') || zone.startsWith('-'))) {
    final digits = int.tryParse(zone.substring(1)) ?? 0;
    final minutes = (digits ~/ 100) * 60 + digits % 100;
    offsetMinutes = zone.startsWith('-') ? -minutes : minutes;
  }
  // 字母缩写（GMT / UTC / UT / Z / EST …）：前三个按 UTC，其余也按 UTC
  // 处理 —— RFC 5322 早就不建议用缩写，实际邮件里几乎见不到。
  return local.subtract(Duration(minutes: offsetMinutes));
}
