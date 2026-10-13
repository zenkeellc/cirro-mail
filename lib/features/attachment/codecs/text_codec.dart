import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';

/// 一次预览最多解码出的字符数。
///
/// 一个 `.txt` / `.log` 附件里值得看的就那么几行；20 万字符（约 4000 行）
/// 远超「看一眼」的需要，而整份解码的代价是实打实的 —— 实测 20MB 的 GBK
/// 文本要 320ms，并且会临时造出一个 2100 万字符的字符串（约 40MB 堆）。
/// 超过这个数的部分不显示，界面底部如实说明。
const int kTextPreviewMaxChars = 200000;

/// 「只解前 [kTextPreviewMaxChars] 个字符」折算成的字节数，也是解码实际
/// 会碰的字节上限。
///
/// 按 **UTF-8 最坏情况** 算：4 个字节解出 1 个码点、也就是 2 个码元
/// （4 字节序列在 UTF-16 里是代理对），所以 80 万字节最少也能解出 40 万个
/// 码元 —— 比 20 万字符的上限宽一倍。GB18030 最坏是 2 字节 1 字符，余量更大。
/// **公开**是为了让测试能按它构造「刚好被截断」的输入 —— 这个值一旦和
/// [kTextPreviewMaxChars] 脱钩（比如有人改成 1024 而没改上面），这里的用例
/// 会直接失败，而不是悄悄留下一个只解了前 256 个字符的预览。
const int kTextProbeBytes = kTextPreviewMaxChars * 4;

/// 文本附件解码的结果：正文 + 「我们是怎么猜的」。
///
/// 把猜测结果一并返回而不是只返回字符串：界面要按它决定要不要提示
/// 「编码可能不对，个别字符显示为 ?」。只给最终字符串的话，那种提示
/// 就只能靠再猜一次。
class DecodedText {
  const DecodedText({
    required this.text,
    required this.encoding,
    this.truncated = false,
  });

  final String text;

  /// 实际用的编码名（`utf-8` / `utf-16le` / `gb18030` / `utf-8-lossy`）。
  /// 展示用，不是标准 MIME 名。
  final String encoding;

  /// 是否没把整份内容都拿出来（见 [decodeText] 的 `maxChars`）。
  final bool truncated;

  /// 内容里有解不出来的字节，显示出来的可能有个别 `?`。
  bool get isLossy => encoding == 'utf-8-lossy';
}

/// 把一份字节解成文本。
///
/// 顺序是刻意的，**每一步为什么排在它那个位置都要紧**：
///
/// 1. **BOM 最先**。BOM 就是文件自己的声明，不该再猜：UTF-16LE 开头的
///    `FF FE` 拿严格 UTF-8 去解会抛，于是落到后面的 GBK，解出一整篇乱码 ——
///    明明文件第一行就说清了自己是 UTF-16。
/// 2. **严格 UTF-8 第二**。GBK 文本里出现合法 UTF-8 序列的概率极低，
///    而反过来（把合法 UTF-8 当 GBK 解）**一定会出乱码但不报错** ——
///    「中文」的 UTF-8 字节 `E4B8AD E69687` 用 GBK 解恰好是合法序列，
///    会安静地变成「涓枃」。所以严格 UTF-8 必须先试，不能靠有没有抛来判。
/// 3. **GB18030 第三**。它向后兼容 GBK 与 GB2312，一个解码器覆盖三档。
///    排在这里意味着「不是合法 UTF-8 才算它」。
/// 4. **宽容 UTF-8 兜底**。到这一步说明前三种都不成立（半截文件？二进制
///    被当成文本？），仍然给用户看点东西，并标记 [isLossy]。
///
/// 不用 `CharsetDetector` 作第一判据：它是统计式的，对短文件（一封邮件里
/// 的 `.txt` 常常只有十几行）经常猜反，而且会把合法的 UTF-8 判成 GBK。
///
/// **只看前 [kTextProbeBytes] 个字节**，不是整份（见该常量的说明）。这顺带修正
/// 了一个判断：整份文件里只要有一处非法字节，旧写法就会否掉 UTF-8；只看
/// 前缀时，前面能正常显示的部分不会被后面那一处带偏 —— 而我们要显示的
/// 本来就只有前面这一小段。
DecodedText decodeText(
  List<int> bytes, {
  int maxChars = kTextPreviewMaxChars,
}) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  // 前缀本身被切过 —— 不管解出多少字符，内容都已经不是全部了。
  final cut = data.length > kTextProbeBytes;
  final probe = cut ? Uint8List.sublistView(data, 0, kTextProbeBytes) : data;

  String text;
  String encoding;

  final bom = _bomOf(probe);
  if (bom != null) {
    text = bom.decode(Uint8List.sublistView(probe, bom.length));
    encoding = bom.name;
  } else {
    final strict = _strictUtf8(probe, cut: cut);
    if (strict != null) {
      text = strict;
      encoding = 'utf-8';
    } else {
      final gb = _gb18030(probe, cut: cut);
      if (gb != null) {
        text = gb;
        encoding = 'gb18030';
      } else {
        text = const Utf8Decoder(allowMalformed: true).convert(probe);
        encoding = 'utf-8-lossy';
      }
    }
  }

  // 去掉解码残留的 NUL：UTF-16 判错时、或文件本身带填充时会有一串。
  if (text.contains('\u0000')) {
    text = text.replaceAll('\u0000', '');
  }

  final truncated = cut || text.length > maxChars;
  if (text.length > maxChars) {
    text = text.substring(0, maxChars);
  }

  return DecodedText(text: text, encoding: encoding, truncated: truncated);
}

/// 严格 UTF-8；不是 UTF-8 就返回 null。
///
/// [cut] 为真时末尾可能是被截断劈成两半的多字节序列，先回退几个字节再试
/// —— UTF-8 与 GB18030 的最长序列都是 4 字节，最多回退 3 个字节一定能落回
/// 字符边界。回退后才失败的，才是真的不是 UTF-8（非法字节在更前面）。
String? _strictUtf8(Uint8List data, {required bool cut}) {
  for (final back in _backoffs(cut, data.length)) {
    try {
      return const Utf8Decoder(allowMalformed: false)
          .convert(Uint8List.sublistView(data, 0, data.length - back));
    } on FormatException {
      continue;
    }
  }
  return null;
}

/// 同 [_strictUtf8]，只是换 GB18030。它接得住 GBK / GB2312 的字节。
///
/// 悬空的半个字（末尾只剩首字节）会让它抛，所以也要同样的回退。
String? _gb18030(Uint8List data, {required bool cut}) {
  for (final back in _backoffs(cut, data.length)) {
    try {
      return gbk.decode(
        Uint8List.sublistView(data, 0, data.length - back),
      );
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// 截断时依次回退 0..3 个字节，否则只试一次。
Iterable<int> _backoffs(bool cut, int length) sync* {
  yield 0;
  if (!cut) return;
  for (var back = 1; back <= 3 && back < length; back++) {
    yield back;
  }
}

/// 认 BOM。返回 null 表示没有。
_Bom? _bomOf(Uint8List data) {
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    return const _Bom('utf-8', 3);
  }
  if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
    return const _Bom('utf-16le', 2);
  }
  if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF) {
    return const _Bom('utf-16be', 2);
  }
  return null;
}

class _Bom {
  const _Bom(this.name, this.length);

  final String name;

  /// BOM 占几个字节 —— `decode` 用它把 BOM 本身从正文前面切掉。
  /// 名字更像「长度」，实际用途是「跳过多少字节」，单独注一句。
  final int length;

  String decode(Uint8List rest) {
    switch (name) {
      case 'utf-8':
        // 有 BOM 就说明作者认为是 UTF-8；个别坏字节不值得整篇变成乱码。
        return const Utf8Decoder(allowMalformed: true).convert(rest);
      case 'utf-16le':
        return _decodeUtf16(rest, littleEndian: true);
      case 'utf-16be':
      default:
        return _decodeUtf16(rest, littleEndian: false);
    }
  }

  String _decodeUtf16(Uint8List data, {required bool littleEndian}) {
    final codeUnits = <int>[];
    // 末尾多出来的单字节直接丢掉（截断劈开的半个码元）。
    for (var i = 0; i + 1 < data.length; i += 2) {
      codeUnits.add(
        littleEndian
            ? data[i] | (data[i + 1] << 8)
            : (data[i] << 8) | data[i + 1],
      );
    }
    // `fromCharCodes` 会正确合并代理对（emoji 这类在 UTF-16 里占两个码元）。
    return String.fromCharCodes(codeUnits);
  }
}
