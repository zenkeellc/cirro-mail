import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:mail_app/features/mail_detail/html_body_view.dart';

/// 正文里 `display:flex` 的**横向溢出**。
///
/// 疼点在「有一封营销邮件正文出现黄黑斜条」：`fwfh_core` 只认
/// `display:flex` 本身，`flex-grow`/`flex-shrink`/`flex-wrap` 全不支持，
/// 孩子按自然宽度排一行 —— 于是「孩子总宽 > 容器宽」就溢出
/// （`RenderHtmlFlex.paint` 画的 `renderOverflowIndicator`）。
///
/// 修法在 `_MailWidgetFactory.buildFlex`：横向 flex 的每个孩子包一层
/// `Flexible(fit: loose)`。这一组用例逐条钉住：
/// 1. 原来溢出的行不再溢出（斜条消失）；
/// 2. 原来**放得下**的行版式没被改坏（这是 `loose` 相对 `tight` 的意义）；
/// 3. 纵向 flex 与 `customStylesBuilder` 那几条默认样式不受牵连。
///
/// 容器宽度固定 400，`SizedBox` 卡死 —— 否则 `CustomPaint` 那种无界宽度
/// 下 `RenderHtmlFlex` 永远不会认为自己在水平方向溢出，测试就成了空跑。
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

/// 有没有 `RenderHtmlFlex` 正报着溢出。
///
/// 读的是 render object 自己的状态（`toStringShort()` 在非 release 下带
/// `OVERFLOWING`），而不是去抓 `FlutterError.onError` —— 后者在
/// `flutter_test` 里被 `takeException` / 用例结束时的检查接管，容易把
/// 「本用例真想要的溢出」和「框架自己报的别的错」混在一起。
bool hasOverflowingFlex(WidgetTester tester) {
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

/// 找到（第一个）`RenderHtmlFlex`，以及它每个孩子在主轴上的
/// `宽度@起点`（逻辑像素，取整）。
List<String> flexChildren(WidgetTester tester) {
  RenderHtmlFlex? flex;
  void visit(RenderObject node) {
    if (node is RenderHtmlFlex && flex == null) flex = node;
    node.visitChildren(visit);
  }

  visit(tester.binding.rootElement!.renderObject!);
  final box = flex;
  if (box == null) return const <String>[];
  final out = <String>['w=${box.size.width.toStringAsFixed(0)}'];
  for (RenderBox? child = box.firstChild;
      child != null;
      child = box.childAfter(child)) {
    final data = child.parentData! as FlexParentData;
    out.add('${child.size.width.toStringAsFixed(0)}'
        '@${data.offset.dx.toStringAsFixed(0)}');
  }
  return out;
}

void main() {
  group('横向 flex 不再溢出', () {
    testWidgets('两个固定宽子项撑不进容器', (tester) async {
      // 修复前：kids=[300,300]，RenderHtmlFlex overflowed by 200 pixels。
      await pumpBody(
        tester,
        '<div style="display:flex">'
        '<div style="width:300px">a</div>'
        '<div style="width:300px">b</div></div>',
      );
      expect(hasOverflowingFlex(tester), isFalse);
    });

    testWidgets('两列 flex:1 长文本（营销邮件的经典两栏）', (tester) async {
      await pumpBody(
        tester,
        '<div style="display:flex">'
        '<div style="flex:1">left column text here</div>'
        '<div style="flex:1">right column text here</div></div>',
      );
      expect(hasOverflowingFlex(tester), isFalse);
    });

    testWidgets('「图标 + flex:1 文案 + 按钮」徽标行', (tester) async {
      await pumpBody(
        tester,
        '<div style="display:flex;align-items:center">'
        '<div style="flex:1">New comment on your post</div>'
        '<div style="width:80px">Reply</div></div>',
      );
      expect(hasOverflowingFlex(tester), isFalse);
    });

    testWidgets('纯文字两列（没有任何宽度声明）', (tester) async {
      await pumpBody(
        tester,
        '<div style="display:flex">'
        '<div>AAAAAAAAAA BBBBBBBBBB</div>'
        '<div>CCCCCCCCCC DDDDDDDDDD</div></div>',
      );
      expect(hasOverflowingFlex(tester), isFalse);
    });

    testWidgets('窄窗口下同样的两栏（320 逻辑像素）', (tester) async {
      await pumpBody(
        tester,
        '<div style="display:flex">'
        '<div style="width:150px">a</div>'
        '<div style="width:150px">b</div></div>',
        width: 320,
      );
      expect(hasOverflowingFlex(tester), isFalse);
    });
  });

  group('横向 flex 的版式不被改坏', () {
    testWidgets('放得下的两栏：小徽章仍是自然尺寸，不被撑开', (tester) async {
      // 这条是选 `FlexFit.loose` 而不是 `Expanded`（tight）的原因：
      // 一旦紧约束，两个 16px 的图标会各被撑成 200px。
      await pumpBody(
        tester,
        '<div style="display:flex">'
        '<div style="width:16px">a</div>'
        '<div style="width:16px">b</div></div>',
      );
      expect(flexChildren(tester), <String>['w=400', '16@0', '16@16']);
    });

    testWidgets('space-between 的两端仍顶到两边', (tester) async {
      await pumpBody(
        tester,
        '<div style="display:flex;justify-content:space-between">'
        '<div style="width:40px">a</div>'
        '<div style="width:40px">b</div></div>',
      );
      expect(flexChildren(tester), <String>['w=400', '40@0', '40@360']);
    });

    testWidgets('子项超出容器时按份额收缩，而不是各留各的自然宽度', (tester) async {
      // `loose` 的份额是上限：两个 300px 在 400px 容器里各让到 200px。
      await pumpBody(
        tester,
        '<div style="display:flex">'
        '<div style="width:300px">a</div>'
        '<div style="width:300px">b</div></div>',
      );
      expect(flexChildren(tester), <String>['w=400', '200@0', '200@200']);
    });
  });

  group('不受影响的部分', () {
    testWidgets('纵向 flex 原样交给 fwfh（本来就是 Column，无关主轴溢出）', (
      tester,
    ) async {
      await pumpBody(
        tester,
        '<div style="display:flex;flex-direction:column">'
        '<div>one</div><div>two</div></div>',
      );
      expect(hasOverflowingFlex(tester), isFalse);
      // 纵向那条**不**经过我们的 `Flexible` 包装：孩子只有两个、没有多出来的
      // 份额可伸，宽度就是容器的宽（纵向 flex 铺满交叉轴），这里只钉住
      // 「没被横向那套改动带歪」——数量对上、没有溢出即可。
      expect(flexChildren(tester), hasLength(3));
    });

    testWidgets('宽表格仍走横向滚动（与 flex 无关，别被这次改动带歪）', (
      tester,
    ) async {
      await pumpBody(
        tester,
        '<table><tr>'
        '<td style="width:600px">aaaaaaaaaa</td>'
        '<td style="width:600px">bbbbbbbbbb</td></tr></table>',
      );
      expect(hasOverflowingFlex(tester), isFalse);
      expect(find.byType(SingleChildScrollView), findsWidgets);
    });
  });
}
