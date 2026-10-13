import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/image_insert.dart';
import 'package:mail_app/features/compose/editor/mail_image_embed.dart';

void main() {
  group('toDataUri', () {
    test('认得的类型原样写进去', () {
      final uri = ImageInsert.toDataUri(
        Uint8List.fromList([1, 2, 3]),
        mimeType: 'image/jpeg',
      );
      expect(uri, 'data:image/jpeg;base64,${base64Encode([1, 2, 3])}');
    });

    test('认不出的类型按 png 处理（用户拖进来的多半是截图）', () {
      final uri = ImageInsert.toDataUri(Uint8List.fromList([1]), mimeType: 'image/tiff');
      expect(uri, startsWith('data:image/png;base64,'));
    });

    test('SVG 被排除（各客户端支持不一，且能带脚本）', () {
      expect(ImageInsert.allowedMime, isNot(contains('image/svg+xml')));
      final uri = ImageInsert.toDataUri(Uint8List(0), mimeType: 'image/svg+xml');
      expect(uri, startsWith('data:image/png;base64,'));
    });
  });

  group('isInlineImage', () {
    test('有 mimeType 时以它为准', () {
      expect(
        ImageInsert.isInlineImage(mimeType: 'image/png', name: '没有后缀'),
        isTrue,
      );
      expect(
        ImageInsert.isInlineImage(mimeType: 'application/pdf', name: 'x.png'),
        isFalse,
      );
    });

    test('mimeType 为 null（桌面拖放就是）时退回文件名后缀', () {
      expect(ImageInsert.isInlineImage(mimeType: null, name: 'a.PNG'), isTrue);
      expect(ImageInsert.isInlineImage(mimeType: null, name: 'a.pdf'), isFalse);
    });

    test('没有后缀 → 不是图', () {
      expect(ImageInsert.isInlineImage(mimeType: null, name: 'README'), isFalse);
    });
  });

  group('canInsert', () {
    test('正常一张 → ok', () {
      expect(
        ImageInsert.canInsert(used: 0, bytes: 1024),
        ImageInsertDecision.ok,
      );
    });

    test('超过单张上限 → tooLarge（先判大小，再判张数）', () {
      expect(
        ImageInsert.canInsert(used: 0, bytes: ImageInsert.maxBytes + 1),
        ImageInsertDecision.tooLarge,
      );
    });

    test('额度用完 → tooMany', () {
      expect(
        ImageInsert.canInsert(used: ImageInsert.maxInlineImages, bytes: 10),
        ImageInsertDecision.tooMany,
      );
    });

    test('两个都不满足时先报大小（那是用户能自己解决的）', () {
      expect(
        ImageInsert.canInsert(
          used: ImageInsert.maxInlineImages,
          bytes: ImageInsert.maxBytes + 1,
        ),
        ImageInsertDecision.tooLarge,
      );
    });

    test('remainingSlots 不会给负数', () {
      expect(ImageInsert.remainingSlots(0), ImageInsert.maxInlineImages);
      expect(ImageInsert.remainingSlots(ImageInsert.maxInlineImages + 5), 0);
    });
  });

  group('insertDataImage', () {
    q.QuillController doc(String plain) => q.QuillController(
          document: q.Document.fromJson([
            {'insert': plain},
          ]),
          selection: TextSelection.collapsed(offset: plain.length - 1),
        );

    /// 「块级嵌入独占一行」那条不变量 —— **只判「紧接着的那个 op 是不是
    /// '\n'」是不够的**。
    ///
    /// 探针实测：在 `前|后` 的行中间插图，紧跟嵌入的 op 是 `'\n后\n'`，
    /// 也就是第 2 行里**嵌入和「后」共处一行** —— 这正是要拦的样子，而
    /// 「下一个 op 以 \n 开头」这种断言会放它过去（`'\n后\n'` 确实以 \n
    /// 开头）。真正要判的是**渲染出来的行**：含嵌入的那一行，除它自己
    /// 以外什么都不许有。
    void expectEmbedAloneOnLine(q.QuillController controller) {
      final lines =
          controller.document.root.children.map((n) => n.toPlainText()).toList();
      final withEmbed = lines.where((t) => t.contains('￼')).toList();
      expect(withEmbed, hasLength(1), reason: '含嵌入的行不唯一：$lines');
      expect(
        withEmbed.single,
        '￼\n',
        reason: '嵌入必须独占一行，实际每行是 $lines',
      );
    }

    test('插到光标处，并且**独占一行**（不独占就会白屏）', () {
      final controller = doc('前\n后\n');
      controller.updateSelection(
        const TextSelection.collapsed(offset: 1),
        q.ChangeSource.local,
      );
      final ok = ImageInsert.insertDataImage(
        controller,
        dataUri: 'data:image/png;base64,AA==',
        used: 0,
        byteLength: 100,
      );
      expect(ok, isTrue);
      expectEmbedAloneOnLine(controller);
      controller.dispose();
    });

    test('光标在行尾、段首、段尾、空行上都能独占一行', () {
      for (final (plain, at) in <(String, int)>[
        ('甲乙\n丙丁\n', 0), // 行首
        ('甲乙\n丙丁\n', 2), // 行尾
        ('甲乙\n丙丁\n', 3), // 段首（下一段）
        ('甲乙\n丙丁\n', 5), // 段尾（下一段）
        ('甲\n\n乙\n', 2), // 本来就在空行上：不该再劈
        ('\n', 0), // 空文档
      ]) {
        final controller = q.QuillController(
          document: q.Document.fromJson([
            {'insert': plain},
          ]),
          selection: TextSelection.collapsed(offset: at),
        );
        final ok = ImageInsert.insertDataImage(
          controller,
          dataUri: 'data:image/png;base64,AA==',
          used: 0,
          byteLength: 100,
        );
        expect(ok, isTrue);
        expectEmbedAloneOnLine(controller);
        // 拆行换来的新行有上限 —— 每次插图都多冒出好几行的话，
        // 用户插十张图正文就散架了。
        final result = controller.document.toPlainText().replaceAll('￼', '');
        expect(
          result.replaceAll('\n', ''),
          plain.replaceAll('\n', ''),
          reason: '$plain@$at 丢了非换行字符',
        );
        expect(
          '\n'.allMatches(result).length - '\n'.allMatches(plain).length,
          lessThanOrEqualTo(2),
          reason: '$plain@$at 多出了太多空行',
        );
        controller.dispose();
      }
    });

    test('行内样式（粗体）不会跟到新行上 —— 否则插图之后就一直在写粗体', () {
      final controller = q.QuillController(
        document: q.Document.fromJson([
          {'insert': '粗'},
          {
            'insert': '体',
            'attributes': {'bold': true},
          },
          {'insert': '\n'},
        ]),
        selection: const TextSelection.collapsed(offset: 2),
      );
      ImageInsert.insertDataImage(
        controller,
        dataUri: 'data:image/png;base64,AA==',
        used: 0,
        byteLength: 100,
      );
      final embedOp = controller.document
          .toDelta()
          .toJson()
          .cast<Map>()
          .firstWhere((op) => op['insert'] is Map);
      // 嵌入本身可以是粗体（那是它原来所在位置的行内样式），但**它后面那个
      // 换行**不能是 —— 带样式的话光标落上去就继承了粗体标签。
      expect(embedOp['attributes'], anyOf(isNull, {'bold': true}));
      final ops = controller.document.toDelta().toJson().cast<Map>();
      final embedIndex = ops.indexWhere((op) => op['insert'] is Map);
      final after = ops[embedIndex + 1];
      expect(after['attributes'], isNull, reason: '嵌入后面那个换行不该带行内样式');
      controller.dispose();
    });

    test('超额度 → 不插，返回 false', () {
      final controller = doc('前\n');
      final ok = ImageInsert.insertDataImage(
        controller,
        dataUri: 'data:image/png;base64,AA==',
        used: ImageInsert.maxInlineImages,
        byteLength: 100,
      );
      expect(ok, isFalse);
      expect(controller.document.toPlainText(), '前\n');
      controller.dispose();
    });

    test('太大 → 不插', () {
      final controller = doc('前\n');
      final ok = ImageInsert.insertDataImage(
        controller,
        dataUri: 'data:image/png;base64,AA==',
        used: 0,
        byteLength: ImageInsert.maxBytes + 1,
      );
      expect(ok, isFalse);
      controller.dispose();
    });

    // F-3：光标偏移越界时不能抛。
    //
    // 病因：`at = controller.selection.extentOffset` 没夹取，而 `Document.length`
    // **含末尾那个 `\n`** —— 合法的“内容偏移”上界是 `length - 1`，可
    // `extentOffset == length` 是个真实会出现的值（选区刚在文末时）。
    // 越界后 `_breakLineAt` 里 `indexOf('\n', cursor)` 返回 -1、
    // `lineEnd = plain.length`，于是 `replaceText` 被调到文档之外，
    // `container.dart:137` 的断言直接炸。
    test('穷举每一个光标偏移（含越界的 length）都不抛，嵌入仍独占一行', () {
      for (final plain in <String>['\n', 'abc\n', 'ab\ncd\n', '<E>\n']) {
        for (var at = 0; at <= plain.length; at++) {
          final controller = q.QuillController(
            document: q.Document.fromJson([
              {'insert': plain},
            ]),
            selection: TextSelection.collapsed(offset: at),
          );
          // 越界不能抛 —— 这是本用例的核心。
          final ok = ImageInsert.insertDataImage(
            controller,
            dataUri: 'data:image/png;base64,AA==',
            used: 0,
            byteLength: 100,
          );
          expect(ok, isTrue, reason: '$plain@$at 应当插入成功');
          // 嵌入必须独占一行：含它的那一行恰好是 `'￼\n'`。
          final lines =
              controller.document.root.children.map((n) => n.toPlainText());
          final embedLines = lines.where((t) => t.contains('￼')).toList();
          expect(embedLines, hasLength(1), reason: '$plain@$at 行数不对：$lines');
          expect(embedLines.single, '￼\n', reason: '$plain@$at 嵌入没独占一行：$lines');
          // 非换行字符一个都不能丢（把嵌入那一格与换行都去掉再比）。
          expect(
            controller.document.toPlainText().replaceAll('￼', '').replaceAll('\n', ''),
            plain.replaceAll('\n', ''),
            reason: '$plain@$at 丢了非换行字符',
          );
          controller.dispose();
        }
      }
    });
  });

  group('countInlineImages', () {
    test('只数 data: 开头的图，http 链接的不算（那些不吃额度）', () {
      final delta = <dynamic>[
        {'insert': '文字\n'},
        {
          'insert': {q.BlockEmbed.imageType: 'data:image/png;base64,AA=='},
        },
        {'insert': '\n'},
        {
          'insert': {q.BlockEmbed.imageType: 'https://example.com/a.png'},
        },
        {'insert': '\n'},
      ];
      expect(ImageInsert.countInlineImages(delta), 1);
    });

    test('空文档 → 0', () {
      expect(ImageInsert.countInlineImages(<dynamic>[]), 0);
    });

    test('形状奇怪的 op 不会让它崩', () {
      expect(
        ImageInsert.countInlineImages(<dynamic>[
          '不是 map',
          {'insert': '文字'},
          {'insert': null},
        ]),
        0,
      );
    });
  });

  // 这一组用的是 `test()` 而**不是** `testWidgets()`。`readAsBytes()` 是真 IO，
  // 在 `testWidgets` 的假时钟里**不会返回** —— 进程会一直挂着直到被 kill
  // （实测 exit 124/144）。凡是真读文件的用例，一律用 `test()`。
  group('readFileAsDataUri', () {
    test('读得到、类型认得 → data URI', () async {
      final dir = await Directory.systemTemp.createTemp('imginst');
      final file = File('${dir.path}/shot.png');
      // PNG 文件头（8 字节魔数）—— `lookupMimeType` 靠它认类型。
      await file.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0]);
      final uri = await ImageInsert.readFileAsDataUri(file.path);
      expect(uri, startsWith('data:image/png;base64,'));
      await dir.delete(recursive: true);
    });

    test('文件不存在 → null，不抛', () async {
      expect(await ImageInsert.readFileAsDataUri('/nope/missing.png'), isNull);
    });

    test('不是图片 → null', () async {
      final dir = await Directory.systemTemp.createTemp('imginst2');
      final file = File('${dir.path}/note.txt');
      await file.writeAsString('hello');
      expect(await ImageInsert.readFileAsDataUri(file.path), isNull);
      await dir.delete(recursive: true);
    });

    test('超过单张上限 → null（在**插入前**拦住，别等发送时才发现）', () async {
      final dir = await Directory.systemTemp.createTemp('imginst3');
      final file = File('${dir.path}/big.png');
      await file.writeAsBytes([
        137, 80, 78, 71, 13, 10, 26, 10,
        ...List<int>.filled(ImageInsert.maxBytes, 0),
      ]);
      expect(await ImageInsert.readFileAsDataUri(file.path), isNull);
      await dir.delete(recursive: true);
    });
  });

  group('MailImage.decodeDataImage', () {
    // 一张**真的** 1×1 PNG（魔数 + IHDR + IDAT + IEND）—— 魔数校验要放行的样本。
    const tinyPngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

    test('真的 PNG → 字节', () {
      final bytes = MailImage.decodeDataImage('data:image/png;base64,$tinyPngBase64');
      expect(bytes, isNotNull);
      expect(bytes!.take(4), [137, 80, 78, 71]);
    });

    test('http 链接 → null（那条路走 Image.network）', () {
      expect(MailImage.decodeDataImage('https://example.com/a.png'), isNull);
    });

    test('base64 坏了 → null，不抛（这里是渲染路径，抛一次就白屏）', () {
      expect(
        MailImage.decodeDataImage('data:image/png;base64,****不是 base64****'),
        isNull,
      );
    });

    test('缺逗号 → null', () {
      expect(MailImage.decodeDataImage('data:image/png;base64'), isNull);
    });

    test('不是 base64 声明的 data URI → null', () {
      expect(
        MailImage.decodeDataImage('data:image/png,abcdef'),
        isNull,
      );
    });

    // F-6：任何 decode 成功、**内容却不是图片**的 data URI 都会走到
    // `Image.memory` 并抛 `Exception: Invalid image data`。魔数校验把它们挡在
    // 渲染之前（返回 null），这样渲染路径只会看到真图片或占位。
    test('空 payload → null（不是图片）', () {
      expect(MailImage.decodeDataImage('data:image/png;base64,'), isNull);
    });

    test('解得出但内容不是图片（AA== → 单个 0 字节）→ null', () {
      expect(MailImage.decodeDataImage('data:image/png;base64,AA=='), isNull);
    });

    test('解得出但魔数不对（纯文本）→ null', () {
      final junk = base64Encode(utf8.encode('这不是图片，只是一段文字'));
      expect(MailImage.decodeDataImage('data:image/png;base64,$junk'), isNull);
    });

    test('各图片格式的魔数都认', () {
      final ok = {
        'image/png': [137, 80, 78, 71, 13, 10, 26, 10],
        'image/jpeg': [0xFF, 0xD8, 0xFF, 0xE0],
        'image/gif': [0x47, 0x49, 0x46, 0x38, 0x39, 0x61],
        'image/bmp': [0x42, 0x4D],
        'image/webp': [
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
        ],
      };
      ok.forEach((mime, bytes) {
        expect(
          MailImage.decodeDataImage('data:$mime;base64,${base64Encode(bytes)}'),
          isNotNull,
          reason: '$mime 应当被放行',
        );
      });
    });

    test('超过大小上限 → null（别把巨图整个解出来）', () {
      // 魔数正确、但字节数超过上限：不能光靠魔数放行。
      final big = <int>[137, 80, 78, 71, ...List<int>.filled(MailImage.maxDataImageBytes, 0)];
      expect(
        MailImage.decodeDataImage('data:image/png;base64,${base64Encode(big)}'),
        isNull,
      );
    });
  });

  group('MailImage 渲染路径', () {
    const tinyPngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

    Future<void> render(WidgetTester tester, String source) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MailImage(source: source)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('空 payload 的 data URI → 占位，不抛', (tester) async {
      await render(tester, 'data:image/png;base64,');
      expect(find.text('图片无法显示'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('坏内容（AA==）的 data URI → 占位，不抛', (tester) async {
      await render(tester, 'data:image/png;base64,AA==');
      expect(find.text('图片无法显示'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 关键：**不能**退回去把 data: URI 当网络地址拉（那更荒唐）。
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('真 PNG → 走 Image.memory，不抛', (tester) async {
      await render(tester, 'data:image/png;base64,$tinyPngBase64');
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('图片无法显示'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
