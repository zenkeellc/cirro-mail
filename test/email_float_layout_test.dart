import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/mail_detail/html_body_view.dart';

/// 正文里 `float: left/right` 的**纵向溢出**。
///
/// 疼点是火山引擎那种页脚导航行：
///
/// ```html
/// <div style="float: left; height:32px; padding-top: 16px; font-size: 14px">
///   产品
/// </div>
/// ```
///
/// `fwfh_core` 不认 `float`（`internal/core_ops.dart` 里连常量都没有，
/// `internal/ops/style_display.dart` 只有 block/inline/inline-block/flex/none），
/// 于是这些 `div` 退化成**块级**：每个都独占一行。行里的 `height:32px` 是
/// **固定高**（`style_sizing.dart` 把它读成 preferred，并且
/// `min = max = preferred`，见 `_RenderCssSizing._applyContraints`），
/// 而块级孩子各自占一行、堆起来自然比 32px 高 —— 普通 `RenderFlex` 就在
/// 底部裁掉 7px（调试态是黄黑斜条，`assert` 里画的）。
///
/// 修法在 `HtmlBodyView._customStyles`：带 `float` 的元素补一条
/// `display: inline-block`，把它们从「一人一行」掰回文档流里排一行，
/// 容器高度随内容长。
///
/// 这一组用例钉住：
/// 1. 那个固定高度的 float 行不再溢出；
/// 2. float 的孩子真的排到了同一行（不是靠别的方式把溢出藏掉）；
/// 3. 放不进时换行，而不是硬撑；
/// 4. **没** float 的元素仍是块级，没被这条改动带歪。
Future<void> pumpBody(
  WidgetTester tester,
  String html, {
  double width = 400,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: HtmlBodyView(html: html, ossBase: '', shrinkWrap: true),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 有没有任何一个 `RenderFlex` 正报着溢出。
///
/// 读 render object 自己的状态（非 release 下 `toStringShort()` 带
/// `OVERFLOWING`），不去抓 `FlutterError.onError` —— 后者会被
/// `flutter_test` 的 `takeException` 接管，容易把别的错混进来。
bool hasOverflow(WidgetTester tester) {
  var found = false;
  void visit(RenderObject node) {
    if (!kReleaseMode && node.toStringShort().contains('OVERFLOWING')) {
      found = true;
    }
    node.visitChildren(visit);
  }

  visit(tester.binding.rootElement!.renderObject!);
  return found;
}

/// 正文里那段文字（`RenderParagraph`）左上角的全局坐标。
Offset paragraphTopLeft(WidgetTester tester, String text) {
  RenderParagraph? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderParagraph && node.text.toPlainText().trim() == text) {
      found = node;
      return;
    }
    node.visitChildren(visit);
  }

  visit(tester.binding.rootElement!.renderObject!);
  final paragraph = found;
  if (paragraph == null) {
    throw StateError('正文里找不到文字「$text」');
  }
  return paragraph.localToGlobal(Offset.zero);
}

void main() {
  group('float 不再纵向溢出', () {
    testWidgets('固定高度盒里的左右 float（火山引擎页脚那行）', (tester) async {
      // 修复前：两个 float 各占一行，撑破 height:32px，底部溢出。
      await pumpBody(
        tester,
        '<div style="height:32px;font-size:14px">'
        '<div style="float:left">kz</div>'
        '<div style="float:left">rm</div></div>',
      );
      expect(hasOverflow(tester), isFalse);
    });

    testWidgets('float 的图片 + float 的文字（页脚logo + 导航）', (tester) async {
      // 这条同时压住 fwfh 的另一个坑：默认 `PlaceholderAlignment.baseline`
      // 会让孩子走 `RenderImage.computeDryBaseline`，而 fwfh 的
      // `_RenderCssSizing` 在 dry baseline 里读了实参布局后的 size ——
      // 断言 `renderBoxDoingDryBaseline == null` 崩掉，**整封正文渲染失败**。
      // 所以带 float 的元素还要补 `vertical-align: middle`（见 `_customStyles`）。
      await pumpBody(
        tester,
        '<div style="height:40px;padding-top:16px">'
        '<div style="float:left"><img src="data:image/gif;base64,'
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" '
        'style="height:32px"></div>'
        '<div style="float:left;margin-left:28px">nav</div></div>',
      );
      expect(hasOverflow(tester), isFalse);
    });

    testWidgets('float: right 也认（只认 left 的话半边的行照旧溢出）', (
      tester,
    ) async {
      await pumpBody(
        tester,
        '<div style="height:32px;font-size:14px">'
        '<div style="float:left">l</div>'
        '<div style="float:right">r</div></div>',
      );
      expect(hasOverflow(tester), isFalse);
    });
  });

  group('float 的孩子真的排到了同一行', () {
    testWidgets('两个 float 左对齐并排，起点相同、横向依次靠右', (tester) async {
      await pumpBody(
        tester,
        '<div style="height:32px;font-size:14px">'
        '<div style="float:left">left</div>'
        '<div style="float:left">right</div></div>',
      );
      final left = paragraphTopLeft(tester, 'left');
      final right = paragraphTopLeft(tester, 'right');
      expect(right.dy, left.dy, reason: '应当并排在同一行');
      expect(right.dx, greaterThan(left.dx), reason: '第二个在第一个右边');
    });

    testWidgets('放不下的 float 换行，而不是硬撑出溢出', (tester) async {
      // 两个 300px 挤在 400px 里 —— `inline-block` 会像文字一样换行。
      // 注意别给外层写 `width:200px`：fwfh 的块级元素宽度优先，那个声明
      // 不一定真把盒子收窄，用例就成了空跑。
      await pumpBody(
        tester,
        '<div style="font-size:14px">'
        '<div style="float:left;width:300px">a</div>'
        '<div style="float:left;width:300px">b</div></div>',
      );
      expect(hasOverflow(tester), isFalse);
      final a = paragraphTopLeft(tester, 'a');
      final b = paragraphTopLeft(tester, 'b');
      expect(b.dy, greaterThan(a.dy));
    });
  });

  group('不受影响的部分', () {
    testWidgets('没 float 的 div 仍是块级（自己占一行，不被误改成 inline-block）', (
      tester,
    ) async {
      await pumpBody(
        tester,
        '<div><div>aaa</div><div>bbb</div></div>',
      );
      // 块级 → 竖着排；若这条规则漏出去了，会变成并排。
      expect(paragraphTopLeft(tester, 'bbb').dy,
          greaterThan(paragraphTopLeft(tester, 'aaa').dy));
      expect(hasOverflow(tester), isFalse);
    });

    testWidgets('float 与普通块级元素混排时互不干扰', (tester) async {
      await pumpBody(
        tester,
        '<div style="font-size:14px">'
        '<div style="float:left">fl</div>'
        '<div>plain</div></div>',
      );
      // float 那位排在上面一行，块级的跟在它后面（同处一个块流里）。
      expect(paragraphTopLeft(tester, 'plain').dy,
          greaterThanOrEqualTo(paragraphTopLeft(tester, 'fl').dy));
      expect(hasOverflow(tester), isFalse);
    });
  });
}
