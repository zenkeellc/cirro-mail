import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/send_payload.dart';
import 'package:mail_app/features/compose/stream_body_builder.dart';

/// 流式组装器的**唯一验收标准**：产出的字节流与
/// `jsonEncode(payload.toJson())` 逐字节相等。
///
/// 计划里点名了这条：
/// > **流式 body 组装器的字节流与 `jsonEncode` 结果逐字节相等**
///
/// 为什么值得单开一个文件：手拼 JSON 是那种「平时都对、出错就整封发不出去」
/// 的代码。字节差一个位置，服务端就是一句 `JSON.parse` 失败的 500，
/// 而用户看到的是「发送失败」，没有任何线索指向组装器。
void main() {
  group('与 jsonEncode 逐字节相等', () {
    test('无附件 → 直接就是 jsonEncode 的结果', () async {
      final payload = _payload();
      expect(await _collect(_build(payload)), _bytes(payload));
    });

    test('一个附件（含 base64 内容）', () async {
      final payload = _payload(
        attachments: <SendAttachment>[
          const SendAttachment(
            path: '/tmp/a.png',
            filename: 'a.png',
            size: 5,
            mimeType: 'image/png',
            contentBase64: 'AAECAwQ=',
          ),
        ],
      );
      expect(await _collect(_build(payload)), _bytes(payload));
    });

    test('多个附件 —— 逗号只在附件之间', () async {
      final payload = _payload(
        attachments: <SendAttachment>[
          const SendAttachment(
            path: '/tmp/1.bin',
            filename: '1.bin',
            size: 3,
            mimeType: 'application/octet-stream',
            contentBase64: 'AQID',
          ),
          const SendAttachment(
            path: '/tmp/2.bin',
            filename: '2.bin',
            size: 0,
            mimeType: 'application/octet-stream',
            contentBase64: '',
          ),
          const SendAttachment(
            path: '/tmp/3.bin',
            filename: '3.bin',
            size: 1,
            mimeType: 'text/plain',
            contentBase64: 'QQ==',
          ),
        ],
      );
      expect(await _collect(_build(payload)), _bytes(payload));
    });

    test('需要转义的字段（引号 / 换行 / 反斜杠 / 中文 / emoji）', () async {
      // 正文里出现引号和换行是常态（HTML 属性 + 富文本），
      // 手工拼串最容易在这里崩。
      final payload = _payload(
        name: '张三 "老板"',
        subject: '报价单：A\\B\n第二行',
        text: '第一行\r\n第二行\t带 tab',
        content: '<div class="x">引号 &amp; 反斜杠 \\ 结束</div>\n',
        recipients: <String>['a+b@example.com', '中文@example.com'],
      );
      expect(await _collect(_build(payload)), _bytes(payload));
    });

    test('reply / forward 的 sendType 与 emailId', () async {
      for (final kind in SendKind.values) {
        final payload = _payload(sendKind: kind, replyToEmailId: 4242);
        expect(
          await _collect(_build(payload)),
          _bytes(payload),
          reason: '${kind.wire} 也要逐字节相等',
        );
      }
    });

    test('上游按 1 字节给块，结果也不变（base64 余数跨块保留）', () async {
      // 真实文件读取不会这么碎，但网络文件系统可能。这条钉住的是
      // 「分块大小不需要是 3 的倍数」—— 编码器必须自己保存余数。
      final raw = Uint8List.fromList(List<int>.generate(1000, (i) => i % 251));
      final payload = _payload(
        attachments: <SendAttachment>[
          SendAttachment(
            path: '/tmp/big.bin',
            filename: 'big.bin',
            size: raw.length,
            mimeType: 'application/octet-stream',
            contentBase64: base64.encode(raw),
          ),
        ],
      );

      final body = StreamBodyBuilder.build(
        payload,
        openFile: (_) => Stream<List<int>>.fromIterable(
          raw.map((b) => <int>[b]),
        ),
      );
      expect(await _collect(body), _bytes(payload));
    });
  });

  group('contentLength', () {
    test('精确等于真实字节数（带附件，含各种长度）', () async {
      // 长度覆盖 base64 的三种填充情形：n%3 == 0 / 1 / 2。
      for (final size in <int>[0, 1, 2, 3, 4, 5, 1024, 1025]) {
        final payload = _payload(
          attachments: <SendAttachment>[
            SendAttachment(
              path: '/tmp/f',
              filename: 'f.bin',
              size: size,
              mimeType: 'application/octet-stream',
              contentBase64: base64.encode(Uint8List(size)),
            ),
          ],
        );
        final actual = (await _collect(_build(payload))).length;
        expect(
          StreamBodyBuilder.contentLength(payload),
          actual,
          reason: 'size=$size 时长度算错，Content-Length 会与真实 body 不符',
        );
      }
    });

    test('无附件时也精确', () {
      final payload = _payload(subject: '中文标题带引号"');
      expect(
        StreamBodyBuilder.contentLength(payload),
        _bytes(payload).length,
      );
    });
  });

  test('附件的 `content` 是裸 base64（服务端会自己解码，带 data: 前缀会解出垃圾）', () async {
    final payload = _payload(
      attachments: <SendAttachment>[
        const SendAttachment(
          path: '/tmp/a.png',
          filename: 'a.png',
          size: 3,
          mimeType: 'image/png',
          contentBase64: 'AQID',
        ),
      ],
    );
    final text = utf8.decode(await _collect(_build(payload)));
    expect(text, contains('{"content":"AQID","filename":"a.png","size":3,'
        '"contentType":"image/png","type":"image/png"}'));
    expect(text, isNot(contains('data:image')));
  });

  test('两个 mime 字段都要发（缺一个服务端另一条路径会拿到 undefined）', () async {
    final payload = _payload(
      attachments: <SendAttachment>[
        const SendAttachment(
          path: '/tmp/x.pdf',
          filename: 'x.pdf',
          size: 1,
          mimeType: 'application/pdf',
          contentBase64: 'QQ==',
        ),
      ],
    );
    final text = utf8.decode(await _collect(_build(payload)));
    expect(text, contains('"contentType":"application/pdf"'));
    expect(text, contains('"type":"application/pdf"'));

    // 而且解析出来确实是个合法 JSON 对象。
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    expect(decoded['attachments'], hasLength(1));
  });

  test('openFile 少了 / 抛错时不去静默发一封没有附件的信', () async {
    final payload = _payload(
      attachments: <SendAttachment>[
        const SendAttachment(
          path: '/tmp/gone.bin',
          filename: 'gone.bin',
          size: 10,
          mimeType: 'application/octet-stream',
        ),
      ],
    );

    await expectLater(
      _collect(
        StreamBodyBuilder.build(
          payload,
          openFile: (_) => Stream<List<int>>.error(
            const FileSystemException('文件不见了'),
          ),
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  // ------------------------------------------------------ 大附件（M3 验收）

  group('15MB 附件（M3 的验收条件）', () {
    late Directory dir;
    late File file;
    const size = 15 * 1024 * 1024;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('stream_body_big');
      file = File('${dir.path}/大附件.bin');
      // 分块写而不是一次 `writeAsBytes(List.generate(15MB))`：这条测试要看的
      // 就是「不把文件整体读进内存」，造数据这一步先自己破功就没意思了。
      final sink = file.openWrite();
      final pattern = List<int>.generate(4096, (i) => (i * 7 + 13) % 251);
      for (var written = 0; written < size; written += pattern.length) {
        sink.add(pattern);
      }
      await sink.close();
    });

    tearDownAll(() => dir.delete(recursive: true));

    test('真实文件：长度精确、内容正确、每个分块都有界', () async {
      final payload = _payload(
        attachments: <SendAttachment>[
          const SendAttachment(
            path: '',
            filename: '大附件.bin',
            size: size,
            mimeType: 'application/octet-stream',
          ),
        ],
      );
      final body = StreamBodyBuilder.build(
        payload,
        // 真实路径：文件流。
        openFile: (_) => file.openRead(),
      );

      var total = 0;
      var maxChunk = 0;
      final collected = BytesBuilder(copy: false);
      await for (final chunk in body) {
        total += chunk.length;
        if (chunk.length > maxChunk) maxChunk = chunk.length;
        collected.add(chunk);
      }

      expect(
        total,
        StreamBodyBuilder.contentLength(payload),
        reason: 'Content-Length 算错的话服务端会截断请求体，症状是「JSON 解析失败」',
      );

      // 峰值内存的下界由「单个分块多大」决定。附件是 15MB，若组装器把整份
      // base64 攒成一个 chunk，这里就会看到 20MB —— 那正是要避免的。
      expect(
        maxChunk,
        lessThan(96 * 1024),
        reason: '分块失去了上界，等于把整个附件读进了内存',
      );

      final decoded =
          jsonDecode(utf8.decode(collected.takeBytes())) as Map<String, dynamic>;
      final attachment =
          (decoded['attachments'] as List<dynamic>).single as Map<String, dynamic>;
      expect(attachment['filename'], '大附件.bin');
      expect(attachment['size'], size);
      expect(attachment['contentType'], 'application/octet-stream');
      expect(attachment['type'], 'application/octet-stream');

      final bytes = base64.decode(attachment['content']! as String);
      expect(bytes.length, size);
      expect(bytes, equals(await file.readAsBytes()));
    });
  });
}

// ------------------------------------------------------------------ 辅助

SendPayload _payload({
  String name = '发件人',
  String subject = '标题',
  String text = '正文',
  String content = '<p>正文</p>',
  List<String> recipients = const <String>['to@example.com'],
  SendKind sendKind = SendKind.normal,
  int replyToEmailId = 0,
  List<SendAttachment> attachments = const <SendAttachment>[],
}) =>
    SendPayload(
      accountId: 7,
      sendEmail: 'me@example.net',
      name: name,
      subject: subject,
      text: text,
      content: content,
      recipients: recipients,
      sendKind: sendKind,
      replyToEmailId: replyToEmailId,
      attachments: attachments,
    );

/// 基准：`contentBase64` 都用真实编码结果填好了，`toJson` 就是标准答案。
List<int> _bytes(SendPayload payload) => utf8.encode(jsonEncode(payload.toJson()));

/// 用**假的文件读取**跑组装：真实实现是 `File(path).openRead()`，
/// 这里喂回 `contentBase64` 解出来的字节 —— 于是「组装器的输出」和
/// 「`jsonEncode` 的输出」用的是同一份内容，可以逐字节比。
Stream<List<int>> _build(
  SendPayload payload, {
  Stream<List<int>> Function(SendAttachment attachment)? openFile,
}) =>
    StreamBodyBuilder.build(
      payload,
      openFile: openFile ??
          (attachment) async* {
            final raw = base64.decode(attachment.contentBase64 ?? '');
            yield raw;
          },
    );

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return out;
}
