/// CSV / TSV 解析：RFC 4180，外加一点点宽容。
///
/// 纯函数：吃字符串，吐中性模型。**不 import `dart:io`、不 import widget**
/// —— 解码那一步（BOM / GBK 那些）在 `text_codec.dart` 里，这一层只管
/// 「一串字符怎么切成格子」。这样拆分是为了两边都能单测，而且 GBK 的 CSV
/// 自动跟着文本那套解码兜底一起被覆盖到。
///
/// ## 宽容在哪、不宽容在哪
///
/// 宽容的（现实里到处都是，不认就没法看）：
/// - **换行**：`\r\n` / `\n` / 单个 `\r` 都当行结束（Excel 导出、老 Mac）。
/// - **引号**：字段内可以含分隔符与换行；`""` 是转义的一个引号；字段里的
///   引号位置不合法时（比如 `a"b"c`）当普通字符，不报错 —— 报错对用户没有
///   任何帮助，他改不了发件人的文件。
/// - **空行**：整行为空的一行不算数据（`a,b\n\n` 那个空行、以及文件末尾
///   多出来的换行，都不该多出一行「一个空字符串」）。但用户**明写的**
///   空字段（`""`）要留着 —— 两者在界面上是完全不同的意思。
/// - **行尾不齐**：某一行少几个字段就少几个，不补空 —— 补了会伪造数据。
///   补到满列是**表格视图**的事（它是显示需要），不是解析的事。
///
/// 不宽容的：上限。一份 20MB 的机器导出的 CSV 可以有几十万行，那是
/// 表格式浏览的 100 倍以上，建出来只会把内存吃光。超限截断**并如实说明**，
/// 不是悄悄丢数据。
abstract final class CsvCodec {
  const CsvCodec._();

  /// 最多保留的行数（含表头）。
  static const int maxRows = 5000;

  /// 最多保留的列数。
  ///
  /// 5000 × 100 = 50 万个格子，已经是这个量级下 `ListView.builder` 能
  /// 顺畅滚动的上限了。
  static const int maxColumns = 100;

  /// 候选分隔符，**顺序即优先级**（打分相同时靠前的胜出）。
  static const List<String> candidates = <String>[',', ';', '\t', '|'];

  /// 嗅探时最多看几行。
  ///
  /// 看全部没有收益：真实表里分隔符的规律在前几行就已经定了，而一份
  /// 20 万字符的文本每多扫一遍都是白花的。
  static const int sniffLines = 20;

  /// 解析一份 CSV。
  ///
  /// 不传 [delimiter] 时先嗅探（见 [sniffDelimiter]）。返回的
  /// [CsvDocument.rows] **第一行就是表头** —— 不做「首行是不是表头」的
  /// 智能判断（见文件头）。
  static CsvDocument parse(String source, {String? delimiter}) {
    final text = _stripBom(source);
    final sep = _separatorOf(delimiter ?? sniffDelimiter(text));

    final rows = <List<String>>[];
    var row = <String>[];
    var columns = 0;
    var truncated = false;
    var quoted = false;
    var started = false;

    final buf = StringBuffer();
    final length = text.length;
    var i = 0;

    /// 收一个字段。超列时不收，但**照样把字节走下去** —— 半路停下会把
    /// 这一行剩下的分隔符误当成下一行的开始。
    void takeField() {
      if (row.length < maxColumns) {
        row.add(buf.toString());
      } else {
        truncated = true;
      }
      buf.clear();
      started = false;
    }

    /// 收一行。返回 true 表示行数已经攒到上限（**不代表一定被截断了** ——
    /// 调用方还要看后面有没有内容，见解析循环里的注释）。
    bool takeRow() {
      // 整行空 —— 跳过。`started` 在开引号时就置位，所以 `""`（用户明写的
      // 空字段）不会走到这里来。
      if (!(row.isEmpty && buf.isEmpty && !started)) {
        if (row.length < maxColumns) {
          row.add(buf.toString());
        } else {
          truncated = true;
        }
        if (row.length > columns) columns = row.length;
        rows.add(row);
        row = <String>[];
      }
      buf.clear();
      started = false;
      return rows.length >= maxRows;
    }

    while (i < length) {
      final ch = text[i];

      if (quoted) {
        if (ch == _quote) {
          if (i + 1 < length && text[i + 1] == _quote) {
            buf.write(_quote); // `""` → 一个字面引号
            i += 2;
            continue;
          }
          quoted = false;
          i++;
          continue;
        }
        buf.write(ch);
        i++;
        continue;
      }

      if (ch == _quote && buf.isEmpty && !started) {
        // 只有字段**开头**的引号才是引用。`a"b` 里那个不是 —— 见文件头。
        quoted = true;
        started = true;
        i++;
        continue;
      }
      if (ch == sep) {
        takeField();
        i++;
        continue;
      }
      if (ch == _cr || ch == _lf) {
        final full = takeRow();
        // `\r\n` 是一行，不是两行。
        final next =
            i + ((ch == _cr && i + 1 < length && text[i + 1] == _lf) ? 2 : 1);
        // **只有后面还真的有内容才算截断**。攒够 [maxRows] 行就收手是不够
        // 精确的：一份正好 5000 行、末尾带换行的文件会走到这里，而它一个
        // 字节都没被丢掉 —— 那种文件不该看到「已截断」的提示。
        if (full && _hasMore(text, next)) {
          truncated = true;
          break;
        }
        i = next;
        continue;
      }

      buf.write(ch);
      started = true;
      i++;
    }

    // 最后一行没有换行结尾 —— 也要收（`a,b` 这份文件就一行）。
    if (i >= length && (quoted || started || row.isNotEmpty || buf.isNotEmpty)) {
      // 这里**不看** `takeRow()` 的返回值：它返回 true 只说明「刚好攒够
      // [maxRows] 行」，而循环已经走到末尾、后面**确实没有内容了** ——
      // 一份正好 5000 行的文件不是被截断的，不该给用户看那句提示。
      // 循环里那一处不同：那里返回 true 意味着后面还有没读完的字节。
      takeRow();
    }

    return CsvDocument(
      rows: rows,
      delimiter: sep,
      columns: columns,
      truncated: truncated,
    );
  }

  /// 猜分隔符，返回 [candidates] 里的一个（都猜不出来时是 `,`）。
  ///
  /// 判据不是「谁出现的次数最多」而是**「谁切出来的列数在每行都一样」**：
  /// 一份 `;` 分隔的表，它的正文里常常有逗号（比如地址、千分位），按出现
  /// 次数数会选错，而按「切成几列」数不会 —— 认错的那个分隔符切出来的
  /// 列数在不同行之间是飘的。
  ///
  /// 打分 = 众数列数一致的行数 × 1000 + 众数列数。所以先比一致性，再比
  /// 列数（都一致时，切出更多列的那个信息量更大）。全部行都只切出 1 列的
  /// 候选直接淘汰 —— 那说明这个分隔符在正文里压根没出现。
  static String sniffDelimiter(String source) {
    final lines = _probeLines(_stripBom(source));
    var best = candidates.first;
    var bestScore = -1;

    for (final candidate in candidates) {
      final counts = <int>[];
      for (final line in lines) {
        final fields = _countFields(line, candidate);
        if (fields > 1) counts.add(fields);
      }
      if (counts.isEmpty) continue;

      final modal = _mode(counts);
      var agree = 0;
      for (final c in counts) {
        if (c == modal) agree++;
      }
      final score = agree * 1000 + modal;
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  // ---------------------------------------------------------------- 内部

  static const String _bom = '﻿';
  static const String _quote = '"';
  static const String _cr = '\r';
  static const String _lf = '\n';

  /// [from] 之后还有没有会变成数据的内容。
  ///
  /// 用来区分「正好 5000 行」与「后面还有一万行」：末尾那一个换行、或者
  /// 一串空行，都不是被丢掉的数据。
  static bool _hasMore(String text, int from) {
    for (var i = from; i < text.length; i++) {
      final ch = text[i];
      if (ch != _cr && ch != _lf) return true;
    }
    return false;
  }

  static String _stripBom(String source) =>
      source.startsWith(_bom) ? source.substring(1) : source;

  /// 分隔符归一到一个字符。传进来多字符（或空）时取第一个，取不到就 `,`。
  static String _separatorOf(String delimiter) {
    if (delimiter.isEmpty) return candidates.first;
    return delimiter[0];
  }

  /// 前 [sniffLines] 行的**原始**内容（未做引号展开 —— 只数分隔符用）。
  ///
  /// 整行为空的略过：它切不出列，参与打分只会把一致性算歪。
  static List<String> _probeLines(String text) {
    final out = <String>[];
    var start = 0;
    while (start <= text.length && out.length < sniffLines) {
      var end = text.indexOf(_lf, start);
      if (end < 0) end = text.length;
      var line = text.substring(start, end);
      if (line.endsWith(_cr)) line = line.substring(0, line.length - 1);
      if (line.trim().isNotEmpty) out.add(line);
      start = end + 1;
    }
    return out;
  }

  /// 一行在某分隔符下切出几个字段 —— **引号内的分隔符不算**。
  static int _countFields(String line, String delimiter) {
    var fields = 1;
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == _quote) {
        if (quoted && i + 1 < line.length && line[i + 1] == _quote) {
          i++;
          continue;
        }
        quoted = !quoted;
        continue;
      }
      if (!quoted && ch == delimiter) fields++;
    }
    return fields;
  }

  static int _mode(List<int> values) {
    var best = values.first;
    var bestCount = 0;
    for (final value in values) {
      var count = 0;
      for (final other in values) {
        if (other == value) count++;
      }
      // 次数相同时取小的：列数少的那种往往才是「真正的表结构」，
      // 「多出来的一列」多半是正文里混进的同分隔符。
      if (count > bestCount || (count == bestCount && value < best)) {
        bestCount = count;
        best = value;
      }
    }
    return best;
  }
}

/// 解析结果。
class CsvDocument {
  const CsvDocument({
    required this.rows,
    required this.delimiter,
    required this.columns,
    required this.truncated,
  });

  /// 全部行，**第一行是表头**。
  final List<List<String>> rows;

  /// 实际用的分隔符（一个字符）。
  final String delimiter;

  /// 最宽那一行的字段数（已受 [CsvCodec.maxColumns] 约束）。
  ///
  /// 行尾不齐时用它给表格补空格 —— 但那是视图的事，[rows] 里保持原样。
  final int columns;

  /// 内容被上限截断过，界面要说明。
  final bool truncated;

  bool get isEmpty => rows.isEmpty;

  /// 表头（没有行时是空表）。
  List<String> get header => rows.isEmpty ? const <String>[] : rows.first;

  /// 表格要从哪一行开始显示（即跳过表头）。
  List<List<String>> get body => rows.length <= 1 ? const <List<String>>[] : rows.sublist(1);

  /// 分隔符的显示名 —— 制表符要写出来，否则底部那条说明上会是一块空白。
  String get delimiterLabel =>
      delimiter == '\t' ? 'Tab' : delimiter;
}
