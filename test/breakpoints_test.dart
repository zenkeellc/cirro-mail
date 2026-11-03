import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/theme/breakpoints.dart';

/// 分栏几何。
///
/// 这里只测 [Breakpoints.clampListWidth]：它是分栏形态里**唯一一处会崩的
/// 纯计算**。`num.clamp` 在 `lower > upper` 时会抛异常，而窗口被拖到刚够
/// 分栏的宽度时，上界 `available - 分隔条 - 阅读区最小宽` 会掉到 `listMinWidth`
/// 以下 —— 那是一次拖拽拖到一半直接崩掉，靠肉眼点不出来（要正好停在那个宽度）。
///
/// 布局本身、拖动条的手感、`?sel=` 导航后列表滚动位置是否保住，都需要真机
/// 验证（本仓库没有 `testWidgets` 设施），不在这个文件里假装覆盖。
void main() {
  group('clampListWidth', () {
    test('窄窗口下不会低于列表最小宽', () {
      expect(Breakpoints.clampListWidth(100, 1200), Breakpoints.listMinWidth);
    });

    test('宽窗口下不超过列表最大宽', () {
      expect(
        Breakpoints.clampListWidth(9999, 2400),
        Breakpoints.listMaxWidth,
      );
    });

    test('中等窗口由「阅读区最小宽」封顶，而不是列表最大宽', () {
      // 1200 - 6 - 420 = 774 > listMaxWidth(480)，所以还是被 480 封顶。
      expect(Breakpoints.clampListWidth(9999, 1200), Breakpoints.listMaxWidth);
      // 900 - 6 - 420 = 474 < 480，这次由阅读区封顶。
      expect(Breakpoints.clampListWidth(9999, 900), closeTo(474, 0.001));
    });

    test('窗口窄到上界低于下界时不抛异常（兜底到最小宽）', () {
      // 320 + 6 + 420 = 746 是「刚好放得下」的宽度，再窄上界就低于下界了。
      expect(
        () => Breakpoints.clampListWidth(400, 700),
        returnsNormally,
      );
      expect(Breakpoints.clampListWidth(400, 700), Breakpoints.listMinWidth);
      expect(Breakpoints.clampListWidth(400, 0), Breakpoints.listMinWidth);
    });

    test('区间内原样返回', () {
      expect(Breakpoints.clampListWidth(360, 1600), 360);
    });
  });

  group('panesAt', () {
    test('与 isExpanded 同一条线', () {
      expect(Breakpoints.panesAt(Breakpoints.medium), isTrue);
      expect(Breakpoints.panesAt(Breakpoints.medium - 1), isFalse);
      // 平板宽度仍然单栏 —— 分栏的门槛是 1024，不是 600。
      expect(Breakpoints.panesAt(Breakpoints.compact), isFalse);
    });
  });

  group('一级导航宽度预算', () {
    test('最窄的分栏窗口仍然放得下三栏（侧栏加宽后只剩几像素余地）', () {
      // 这条是 railWidth 的上界：1024 - 272 = 752，刚好比
      // 320 + 6 + 420 = 746 多 6px。侧栏再宽就得连 `medium` 一起改。
      final content = Breakpoints.medium - Breakpoints.railWidth;
      final panes = Breakpoints.listMinWidth +
          Breakpoints.paneHandleWidth +
          Breakpoints.readerMinWidth;
      expect(content, greaterThanOrEqualTo(panes));
      expect(Breakpoints.clampListWidth(9999, content),
          greaterThanOrEqualTo(Breakpoints.listMinWidth));
    });

    test('侧栏标题行给产品名留够宽度（Cirro Mail Pro + 三颗图标按钮）', () {
      // 标题行的固定开支：两侧内边距 24 + 写邮件 48 + 同步状态 36 +
      // 扩展按钮 48 = 156。`Cirro Mail Pro` 在 16sp/w700 下约 100px（SF Pro
      // 实测 97px），108 是「留 8px 余量」的那条线 —— 232 的旧宽度只剩 76，
      // 会在标题行里被 ellipsis 截成 `Cirro M…`。
      const chrome = 24 + 48 + 36 + 48;
      expect(Breakpoints.railWidth - chrome, greaterThanOrEqualTo(108));
    });
  });
}
