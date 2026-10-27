import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/widgets/email_address_text.dart';

/// 列表里那一串 `xxxx@xxx.com` 的显示规则：**本地部分加粗，`@` 与域名常规**。
///
/// 这条规则**只在样式上可见**，肉眼复查一张列表几乎看不出哪一段被切错了
/// （`@` 少加粗一个字符、域名跟着一起重）——所以切出来的 span 边界必须由
/// 用例钉住，而不是靠截图。
void main() {
  /// 一段文字切出来的一小段：内容 + 这一段自己挂的字重（null = 继承外层）。
  List<({String text, FontWeight? weight})> partsOf(
    String text, {
    FontWeight localWeight = FontWeight.w700,
  }) =>
      emailAddressSpans(text, localWeight: localWeight)
          .cast<TextSpan>()
          .map((span) => (
                text: span.text ?? '',
                weight: span.style?.fontWeight,
              ))
          .toList(growable: false);

  group('切地址', () {
    test('单个地址：本地部分加粗，`@域名` 原样', () {
      expect(partsOf('box@example.net'), [
        (text: 'box', weight: FontWeight.w700),
        (text: '@example.net', weight: null),
      ]);
    });

    test('`+tag` 地址：tag 属于本地部分，一起加粗', () {
      expect(partsOf('news+abc@x.com'), [
        (text: 'news+abc', weight: FontWeight.w700),
        (text: '@x.com', weight: null),
      ]);
    });

    test('不是地址的文案整段原样，不加粗', () {
      expect(partsOf('全部邮箱'), [(text: '全部邮箱', weight: null)]);
      expect(partsOf('张三'), [(text: '张三', weight: null)]);
    });

    test('`a@b`（没有顶级域）不当地址：否则随手写的显示名会被加粗', () {
      expect(partsOf('a@b'), [(text: 'a@b', weight: null)]);
    });

    test('中文紧挨着地址：中文留在常规段里，只认 ASCII 的用户名', () {
      expect(partsOf('的邮箱box@example.net'), [
        (text: '的邮箱', weight: null),
        (text: 'box', weight: FontWeight.w700),
        (text: '@example.net', weight: null),
      ]);
    });

    test('带显示名的收件人：只把 `< >` 里的地址用户名加粗', () {
      expect(partsOf('张三 <a@x.com>'), [
        (text: '张三 <', weight: null),
        (text: 'a', weight: FontWeight.w700),
        (text: '@x.com>', weight: null),
      ]);
    });

    test('一串地址（发件行用「、」拼）：每个用户名各自加粗', () {
      expect(partsOf('a@x.com、b@y.com'), [
        (text: 'a', weight: FontWeight.w700),
        (text: '@x.com、', weight: null),
        (text: 'b', weight: FontWeight.w700),
        (text: '@y.com', weight: null),
      ]);
    });

    test('空串给出空 span 列表，不抛异常', () {
      expect(emailAddressSpans(''), isEmpty);
    });
  });

  group('控件', () {
    Future<void> pump(WidgetTester tester, String text, {TextStyle? style}) {
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EmailAddressText(text, style: style, maxLines: 1),
        ),
      ));
    }

    testWidgets('整段文字仍按原文整串取到（列表里到处是 find.text）', (tester) async {
      await pump(tester, 'box@example.net');

      // 换成 Text.rich 之后 `data` 是 null，`find.text` 走的是
      // `textSpan.toPlainText()` —— 这条要一直成立，否则侧栏/设置里几十条
      // 按地址找行的用例会一起红。
      expect(find.text('box@example.net'), findsOneWidget);
    });

    testWidgets('外层样式（颜色/字号）照旧生效，本地部分只多一个字重', (tester) async {
      const base = TextStyle(fontSize: 13, color: Colors.red);
      await pump(tester, 'box@example.net', style: base);

      final widget = tester.widget<Text>(find.descendant(
        of: find.byType(EmailAddressText),
        matching: find.byType(Text),
      ));
      expect(widget.style?.fontSize, 13);
      expect(widget.style?.color, Colors.red);

      final spans =
          (widget.textSpan! as TextSpan).children!.cast<TextSpan>().toList();
      expect(spans.first.style?.fontWeight, FontWeight.w700);
      // `@域名` 不自己带样式 = 继承外层那一档，不会被顺带加粗。
      expect(spans.last.style, isNull);
      expect(spans.map((s) => s.text).join(), 'box@example.net');
    });
  });
}
