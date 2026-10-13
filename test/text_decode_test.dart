import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/attachment/codecs/text_codec.dart';

/// UTF-16 的字节，手工拼 —— 不用 `charset` 的编码器。
///
/// 用「自家编码器写、自家解码器读」的往返测试，在两个方向共用一张
/// 映射表时会**同时错**而测出绿；这里手写出字节，测的是解码这一侧。
Uint8List _utf16(String text, {required bool littleEndian}) {
  final out = <int>[];
  for (final unit in text.codeUnits) {
    out.add(littleEndian ? unit & 0xFF : unit >> 8);
    out.add(littleEndian ? unit >> 8 : unit & 0xFF);
  }
  return Uint8List.fromList(out);
}

void main() {
  group('BOM', () {
    test('UTF-8 BOM 被切掉，正文不带 U+FEFF', () {
      final bytes = <int>[
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('hello 世界'),
      ];
      final decoded = decodeText(bytes);
      expect(decoded.encoding, 'utf-8');
      expect(decoded.text, 'hello 世界');
      expect(decoded.text.contains('﻿'), isFalse);
    });

    test('UTF-16LE BOM', () {
      final bytes = <int>[
        0xFF, 0xFE,
        ..._utf16('中文 ab', littleEndian: true),
      ];
      final decoded = decodeText(bytes);
      expect(decoded.encoding, 'utf-16le');
      expect(decoded.text, '中文 ab');
    });

    test('UTF-16BE BOM', () {
      final bytes = <int>[
        0xFE, 0xFF,
        ..._utf16('中文 ab', littleEndian: false),
      ];
      final decoded = decodeText(bytes);
      expect(decoded.encoding, 'utf-16be');
      expect(decoded.text, '中文 ab');
    });

    test('BOM 与正文之间多一个空行也不会串位', () {
      final bytes = <int>[
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('\nline'),
      ];
      expect(decodeText(bytes).text, '\nline');
    });
  });

  group('无 BOM', () {
    test('合法 UTF-8 走严格解码，不当成 GBK', () {
      // 「中文」的 UTF-8 是 E4B8AD E69687。若先试 GBK，会解成「涓枃」这类
      // 乱码但**不报错** —— 所以顺序必须是严格 UTF-8 在前。
      final decoded = decodeText(utf8.encode('中文档'));
      expect(decoded.encoding, 'utf-8');
      expect(decoded.text, '中文档');
      expect(decoded.isLossy, isFalse);
    });

    test('纯 ASCII 也是 utf-8', () {
      expect(decodeText(utf8.encode('plain')).encoding, 'utf-8');
    });

    test('GBK 字节走 GB18030', () {
      // 「中文」的 GBK：中=D6D0 文=CEC4（手写死值，不用编码器）。
      final decoded = decodeText(<int>[0xD6, 0xD0, 0xCE, 0xC4]);
      expect(decoded.encoding, 'gb18030');
      expect(decoded.text, '中文');
    });

    test('GBK 里夹 ASCII 也认', () {
      final decoded = decodeText(<int>[
        0x41, // 'A'
        0xB2, 0xE2, // 测
        0xCA, 0xD4, // 试
        0x2E, // '.'
      ]);
      expect(decoded.encoding, 'gb18030');
      expect(decoded.text, 'A测试.');
    });

    test('既不是 UTF-8 也不是 GBK → 宽容 UTF-8 并标记 lossy', () {
      // 0xFF 在 UTF-8 里是非法首字节，在 GBK 里又是个悬空的半个字。
      final decoded = decodeText(<int>[0x41, 0xFF, 0x42]);
      expect(decoded.encoding, 'utf-8-lossy');
      expect(decoded.isLossy, isTrue);
      // 仍然给出能看的字符，不是空串也不是抛异常。
      expect(decoded.text.startsWith('A'), isTrue);
      expect(decoded.text.endsWith('B'), isTrue);
    });

    test('空输入不炸', () {
      final decoded = decodeText(const <int>[]);
      expect(decoded.text, '');
      expect(decoded.encoding, 'utf-8');
      expect(decoded.truncated, isFalse);
    });
  });

  group('只看前缀（20 万字符那一档）', () {
    test('超长 UTF-8 在截断处劈开多字节序列，仍判成 utf-8', () {
      // 让前缀的**最后一个字节**正好是「中」的第二个字节：00 02 遍
      // 三字节序列（E4 B8 AD）会在整除处被劈开。
      final unit = utf8.encode('中'); // [0xE4, 0xB8, 0xAD]
      final total = kTextProbeBytes;
      final bytes = Uint8List((total ~/ 3 + 1) * 3);
      for (var i = 0; i + 2 < bytes.length; i += 3) {
        bytes[i] = unit[0];
        bytes[i + 1] = unit[1];
        bytes[i + 2] = unit[2];
      }
      expect(bytes.length % 3, 0);
      final decoded = decodeText(bytes);
      expect(decoded.encoding, 'utf-8');
      expect(decoded.truncated, isTrue);
      // 劈开的那半个字被回退掉了，不会有 U+FFFD。
      expect(decoded.text.contains('�'), isFalse);
    });

    test('前缀合法、坏字节在很后面 —— 仍按前缀判成 utf-8', () {
      final bytes = <int>[
        ...utf8.encode('前面都是好的' * 10),
        ...List<int>.filled(kTextProbeBytes, 0x61), // 把坏字节推到前缀之外
        0xFF, 0xFF,
      ];
      final decoded = decodeText(bytes);
      expect(decoded.encoding, 'utf-8');
      expect(decoded.isLossy, isFalse);
    });

    test('超长 GBK 也走前缀，不乱码也不报错', () {
      final unit = <int>[0xD6, 0xD0]; // 「中」
      final bytes = Uint8List((kTextProbeBytes ~/ 2 + 1) * 2);
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        bytes[i] = unit[0];
        bytes[i + 1] = unit[1];
      }
      final decoded = decodeText(bytes, maxChars: 64);
      expect(decoded.encoding, 'gb18030');
      expect(decoded.text, '中' * 64);
    });
  });

  group('清洗与截断', () {
    test('NUL 被去掉（UTF-16 判错时会有）', () {
      final decoded = decodeText(utf8.encode('a\u0000b\u0000c'));
      expect(decoded.text, 'abc');
    });

    test('超过 maxChars 截断并标记', () {
      final decoded = decodeText(
        utf8.encode('x' * 100),
        maxChars: 10,
      );
      expect(decoded.text.length, 10);
      expect(decoded.truncated, isTrue);
    });

    test('刚好等于 maxChars 不算截断', () {
      final decoded = decodeText(utf8.encode('x' * 10), maxChars: 10);
      expect(decoded.truncated, isFalse);
    });
  });
}
