import 'dart:convert';

import '../../data/models/send_payload.dart';

/// 把一封待发的信组装成 `/email/send` 的 JSON 请求体，**以字节流的形式**。
///
/// ## 为什么必须流式（而不是 `jsonEncode(payload.toJson())`）
///
/// 附件在这个接口上只能是 base64 字符串（约束 14：没有通用上传端点）。
/// 走 `jsonEncode` 的话，一个 15MB 附件的峰值内存大致是：
///
/// ```text
///   文件字节 15MB
///     → base64 字符串 20MB（Dart 的 String 是 UTF-16，这 20M 个 ASCII
///       字符实际占 40MB）
///     → jsonEncode 的输出缓冲 20MB（又是 40MB）
///     → dio 写 body 时的又一次拷贝
/// ```
///
/// 也就是「15MB 的附件要 100MB+」。改成逐块读文件、逐块 base64、逐块扔进
/// 请求流之后，峰值只剩**一个分块**（[chunkSize]，默认 64KB）。
///
/// ## 正确性靠什么保证
///
/// 手拼 JSON 最容易出的三个错，都在这里用结构消掉了：
///
/// 1. **转义**：所有字符串字段一律走 [jsonEncode]，绝不手工加引号 ——
///    否则正文里的引号/换行会拼出非法 JSON。
/// 2. **字节边界**：base64 的输入每 3 字节一组。余数由 [_base64Chunks]
///    显式跨块带着走（见那个方法的注释：`dart:convert` 的流式转换器在这条
///    嵌套路径上会抛 `Stream is already closed`）。
/// 3. **首尾逗号**：逗号写在每个附件**之前**，尾部不留多余的逗号。
///
/// 字段顺序刻意与 [SendPayload.toJson] 完全一致，于是
/// `test/stream_body_builder_test.dart` 可以直接断言
/// **字节流与 `jsonEncode(payload.toJson())` 逐字节相等** —— 这是计划里
/// 「验证方式」点名的最关键一条。顺序一致还有个好处：将来有人做 diff 时，
/// 看到的是「某个值不同」而不是「一大片错位」。
class StreamBodyBuilder {
  const StreamBodyBuilder._();

  /// 附件分块大小。
  ///
  /// **必须是 3 的倍数**（65538 = 3 × 21846）：base64 一次吃 3 个字节，
  /// 余数在这里是由本文件自己跨块带着走的，取 3 的倍数可以让绝大多数块
  /// 直接编码、不必等待下一个块 —— 这是唯一的目的，正确性不依赖它。
  static const int chunkSize = 64 * 1024 + 2;

  /// 组装整个请求体。
  ///
  /// [openFile] 由调用方注入（真实环境是 `File(path).openRead()`），
  /// 这样组装器本身不依赖 `dart:io`，测试也能用内存字节流跑同一份逻辑。
  static Stream<List<int>> build(
    SendPayload payload, {
    Stream<List<int>> Function(SendAttachment attachment)? openFile,
  }) async* {
    final attachments = payload.attachments;
    final opener = openFile ?? _rejectFileAccess;

    if (attachments.isEmpty) {
      yield utf8.encode(jsonEncode(payload.toJson()));
      return;
    }

    yield _header(payload);

    for (var i = 0; i < attachments.length; i++) {
      final attachment = attachments[i];
      // 逗号在**每个附件之前**发，而不是每个之后 —— 尾部不留多余的逗号。
      if (i > 0) yield const <int>[0x2C]; // ,

      // `{"content":"`
      yield utf8.encode('{"content":"');

      // 逐块读、逐块 base64。**不要**在这里用
      // `base64.encoder.bind(...)` / `.fuse(...)`：在「async* 里嵌一层
      // 转换过的流」这个形态下它会抛 `Bad state: Stream is already closed`
      // 或直接挂住（`dart:convert` 的 `_SinkTransformerStreamSubscription`
      // 在外层生成器暂停时会把内层订阅也暂停，两边的暂停语义打架）。
      // 组装器是「一封大附件的信」这条路径的核心，不能依赖这种细节，
      // 所以余数由 [_base64Chunks] 自己带着走。
      await for (final encoded in _base64Chunks(opener(attachment))) {
        yield encoded;
      }

      // `","filename":...,"size":...,"contentType":...,"type":...}`
      yield utf8.encode(_attachmentTail(attachment));
    }

    yield utf8.encode(']}');
  }

  /// 精确算出请求体长度，用于显式带上 `Content-Length`。
  ///
  /// body 是 `Stream` 时 dio 推断不出长度，而后面的 Cloudflare 链路更愿意
  /// 收带长度的请求。
  ///
  /// **base64 的填充不能按块分别算**：3 字节一组，只有全文件最后不足一组的
  /// 余数才补 `=`。所以这里按**文件总量**算一次
  /// （`4 * ((n + 2) ~/ 3)`）—— 分块只是读取方式，不改变输出长度。
  ///
  /// 无附件时直接量一遍 `jsonEncode` 的结果 —— 那条路上没有内存顾虑
  /// （附件才是大头），而且这样最不容易算错。
  static int contentLength(SendPayload payload) {
    final attachments = payload.attachments;
    if (attachments.isEmpty) {
      return utf8.encode(jsonEncode(payload.toJson())).length;
    }

    var total = _header(payload).length + 2; // + `]}`
    for (var i = 0; i < attachments.length; i++) {
      final attachment = attachments[i];
      if (i > 0) total += 1; // ,
      // `{"content":"` + base64 + tail
      total += '{"content":"'.length;
      total += 4 * ((attachment.size + 2) ~/ 3);
      total += utf8.encode(_attachmentTail(attachment)).length;
    }
    return total;
  }

  // ------------------------------------------------------------ 组装片段

  /// `{...},"attachments":[`
  ///
  /// 字段顺序与 [SendPayload.toJson] 一致。
  static List<int> _header(SendPayload payload) => utf8.encode(
        '{'
        '"accountId":${payload.accountId},'
        '"name":${jsonEncode(payload.name)},'
        '"sendEmail":${jsonEncode(payload.sendEmail)},'
        '"receiveEmail":${jsonEncode(payload.recipients)},'
        '"subject":${jsonEncode(payload.subject)},'
        '"content":${jsonEncode(payload.content)},'
        '"text":${jsonEncode(payload.text)},'
        '"sendType":${jsonEncode(payload.sendKind.wire)},'
        '"emailId":${payload.replyToEmailId},'
        '"attachments":[',
      );

  /// `","filename":...,"size":...,"contentType":...,"type":...}`
  ///
  /// 与 [SendAttachment.toJson] 一致：`content` 在最前，其余按序在后。
  /// 「两个 mime 字段都要」是服务端的硬要求（Resend/CF Email 路径读
  /// `contentType`，`saveSendAtt` 读 `type`）。
  static String _attachmentTail(SendAttachment attachment) => '","filename":'
      '${jsonEncode(attachment.filename)},"size":${attachment.size},'
      '"contentType":${jsonEncode(attachment.mimeType)},'
      '"type":${jsonEncode(attachment.mimeType)}}';

  /// 把一个文件流变成 base64 字节流，**峰值内存只有一个分块**。
  ///
  /// 自己维护余数（[carry]）而不是交给 `base64.encoder.bind`：
  /// 每凑满 3 的倍数就编码一批，剩下的 0–2 个字节留到下一块。
  /// 「不完整的一批」绝不编码 —— 那会多出一个 `=` 填充，
  /// 而真实文件到底有多少字节是编码时才知道的。
  ///
  /// [base64.encode] 用 `utf8` 编出来的 ASCII 是安全的，直接 `utf8.encode`
  /// 回字节即可（base64 输出只含 `A-Za-z0-9+/=`，全是单字节字符）。
  static Stream<List<int>> _base64Chunks(Stream<List<int>> source) async* {
    var carry = <int>[];
    await for (final chunk in source) {
      final data = carry.isEmpty ? chunk : (<int>[...carry, ...chunk]);
      final usable = data.length - (data.length % 3);

      var offset = 0;
      while (usable - offset >= chunkSize) {
        yield utf8.encode(
          base64.encode(data.sublist(offset, offset + chunkSize)),
        );
        offset += chunkSize;
      }
      if (usable - offset > 0) {
        yield utf8.encode(base64.encode(data.sublist(offset, usable)));
      }

      carry = usable < data.length ? data.sublist(usable) : <int>[];
    }
    // 文件尾部落单的 1–2 个字节 —— 这里才该出现 `=` 填充。
    if (carry.isNotEmpty) yield utf8.encode(base64.encode(carry));
  }

  static Stream<List<int>> _rejectFileAccess(SendAttachment attachment) =>
      throw StateError(
        '带附件的组装必须提供 openFile（${attachment.filename}）',
      );
}
