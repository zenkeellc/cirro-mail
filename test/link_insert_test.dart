import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/editor/link_insert.dart';

/// 纯函数那一半：`normalize` 是「用户敲进来的东西」与「写进文档的 URL」之间
/// 唯一的关口，三种拒绝理由（空、危险协议、认不出的 scheme）都要能分辨。
///
/// 落地那一半（`apply` / `clear`）在 `compose_toolbar_test.dart` 里跟着真实
/// 的 controller 走。
void main() {
  group('normalize：补 scheme', () {
    test('光秃秃的域名补上 https://', () {
      expect(LinkInsert.normalize('example.com'), 'https://example.com');
    });

    test('带路径的也补', () {
      expect(
        LinkInsert.normalize('example.com/a/b?q=1'),
        'https://example.com/a/b?q=1',
      );
    });

    test('两侧空白先 trim 掉', () {
      expect(LinkInsert.normalize('  example.com  '), 'https://example.com');
    });

    test('已经带了 scheme 的不动它', () {
      expect(LinkInsert.normalize('http://example.com'), 'http://example.com');
      expect(LinkInsert.normalize('https://example.com'), 'https://example.com');
    });

    test('大写 scheme 也认（判据先转小写）', () {
      expect(LinkInsert.normalize('HTTPS://example.com'), 'HTTPS://example.com');
    });

    test('mailto / tel 原样放行', () {
      expect(LinkInsert.normalize('mailto:a@b.com'), 'mailto:a@b.com');
      expect(LinkInsert.normalize('tel:+8613800138000'), 'tel:+8613800138000');
    });
  });

  group('normalize：拒绝', () {
    test('空输入返回 null（调用方把它当「用户没填」）', () {
      expect(LinkInsert.normalize(''), isNull);
      expect(LinkInsert.normalize('   '), isNull);
    });

    test('危险协议一律拦下', () {
      expect(LinkInsert.normalize('javascript:alert(1)'), isNull);
      expect(LinkInsert.normalize('data:text/html,<script>'), isNull);
      expect(LinkInsert.normalize('vbscript:msgbox(1)'), isNull);
      expect(LinkInsert.normalize('file:///etc/passwd'), isNull);
    });

    test('替别人背书的 cid: 也不放行（那是服务端内嵌图用的）', () {
      expect(LinkInsert.normalize('cid:image001'), isNull);
    });

    test('用空白/控制字符拆开 scheme 的绕法也要拦住', () {
      // `java\nscript:` 这类在邮件 HTML 里是真实存在的绕法；sanitizer 的
      // `_cleanUrlForStorage` 也是先删空白再判 —— 两边判据必须一致。
      expect(LinkInsert.normalize('java\nscript:alert(1)'), isNull);
      expect(LinkInsert.normalize('java script:alert(1)'), isNull);
      expect(LinkInsert.normalize('java\u0000script:alert(1)'), isNull);
    });

    test('「冒号在路径里」不算有 scheme，照常补 https', () {
      // `example.com/a:b` 被判成「不认识的 scheme」而拒掉的话，一个完全正常
      // 的地址就发不出去了。判据是「第一个冒号之前没有 /」。
      expect(
        LinkInsert.normalize('example.com/a:b'),
        'https://example.com/a:b',
      );
    });

    test('协议相对地址（//host）补 https，不补成三条斜杠', () {
      expect(LinkInsert.normalize('//example.com/x'), 'https://example.com/x');
    });
  });

  group('isRejected', () {
    test('与 normalize 的判据一致', () {
      expect(LinkInsert.isRejected(''), isTrue);
      expect(LinkInsert.isRejected('javascript:alert(1)'), isTrue);
      expect(LinkInsert.isRejected('example.com'), isFalse);
      expect(LinkInsert.isRejected('https://example.com'), isFalse);
    });
  });

  group('apply / clear', () {
    q.QuillController holder(String text) => q.QuillController(
          document: q.Document.fromJson([
            {'insert': text},
          ]),
          selection: TextSelection.collapsed(offset: text.length - 1),
        );

    String? linkOf(q.QuillController controller) {
      for (final op in controller.document.toDelta().toJson()) {
        final attrs = op['attributes'];
        if (attrs is Map && attrs['link'] != null) return attrs['link'] as String;
      }
      return null;
    }

    test('选中一段 → 那一段带上 link', () {
      final controller = holder('点这里\n');
      LinkInsert.apply(
        controller,
        const TextSelection(baseOffset: 0, extentOffset: 3),
        'https://example.com',
      );
      expect(linkOf(controller), 'https://example.com');
      // 文字不变 —— 只是挂了个属性。
      expect(controller.document.toPlainText(), '点这里\n');
      controller.dispose();
    });

    test('没选中 → 把地址本身当文字插进去再挂链接', () {
      final controller = holder('开头\n');
      LinkInsert.apply(
        controller,
        const TextSelection.collapsed(offset: 0),
        'https://example.com',
      );
      expect(controller.document.toPlainText(), contains('https://example.com'));
      expect(linkOf(controller), 'https://example.com');
      controller.dispose();
    });

    test('clear 去掉链接但留着文字', () {
      final controller = holder('点这里\n');
      const selection = TextSelection(baseOffset: 0, extentOffset: 3);
      LinkInsert.apply(controller, selection, 'https://example.com');
      expect(linkOf(controller), isNotNull);

      LinkInsert.clear(controller, selection);
      expect(linkOf(controller), isNull);
      expect(controller.document.toPlainText(), '点这里\n');
      controller.dispose();
    });

    test('选区越界（弹窗期间文档被改短了）不抛，也不挂错地方', () {
      final controller = holder('短\n');
      // 弹窗之前记下的选区，回来时已经比文档还长。
      LinkInsert.apply(
        controller,
        const TextSelection(baseOffset: 2, extentOffset: 99),
        'https://example.com',
      );
      expect(controller.document.toPlainText(), contains('短'));
      controller.dispose();
    });

    test('折叠选区上 clear 什么都不做', () {
      final controller = holder('点这里\n');
      LinkInsert.clear(controller, const TextSelection.collapsed(offset: 1));
      expect(linkOf(controller), isNull);
      controller.dispose();
    });
  });
}
