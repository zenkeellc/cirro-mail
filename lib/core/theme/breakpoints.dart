import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 布局断点。
///
/// 三种形态（对齐计划里的「界面与导航」）：
/// - **< 600** 手机：底部导航，详情 / 写邮件全屏 push；
/// - **600–1023** 平板：左侧左导航（`NavigationRail`），内容区仍是单栏；
/// - **>= 1024** 桌面：左导航 + **列表栏 + 阅读区**（中间的分隔条可拖动）。
///
/// 判据用**宽度**而不是平台 —— 横过来的手机、分屏的平板、
/// 拖得很窄的桌面窗口都该按实际空间决定布局。
class Breakpoints {
  const Breakpoints._();

  static const double compact = 600;
  static const double medium = 1024;

  /// 一级导航侧栏的固定宽度（`NavSidebar.width` 与之保持一致）。
  ///
  /// 232 = 「附件缓存」四个汉字 + 图标 + 角标 + 两侧内边距倒推出来的。
  /// 加宽之前它是一条 72px 的图标条，只能靠 hover 300ms 的 Tooltip 认字 ——
  /// 而这个宽度下侧栏是**唯一**的一级导航（主屏那张 icon 网格只在窄屏出现），
  /// 靠猜是不行的（spec §2.2）。
  ///
  /// 宽度够不够的验算：窗口拖到刚够分栏的 1024 时，内容区还有
  /// `1024 - 232 = 792`，而分栏至少需要 `listMinWidth 320 + paneHandleWidth 6
  /// + readerMinWidth 420 = 746`。只余 46 的余地，所以 [clampListWidth] 的下限
  /// 兜底（宁可挤阅读区也不能崩）是必需的，不是保险起见。
  ///
  /// 注意：这个数**不是** `NavigationRail` 的真实宽度（那个由 Material 自己
  /// 定，约 80，本仓库已经不用它了）。真正需要「内容区有多宽」时一律用
  /// `LayoutBuilder` 的 `constraints.maxWidth`，不要拿窗口宽去减这个值。
  static const double railWidth = 232;

  /// 两栏布局里列表栏的宽度范围（可用 `Flexible` 或拖动调整）。
  static const double listMinWidth = 320;
  static const double listMaxWidth = 480;

  /// 设置页里那条**分类栏**的固定宽度。
  ///
  /// 与 [railWidth] 是**两级**导航，所以刻意不复用那个值：
  ///
  /// - 232 是被「附件缓存」四个汉字 + 图标 + 角标 + 内边距倒推出来的；
  ///   设置页的分类最长只有「诊断」两个字，用 232 就是白留一条空。
  /// - 更重要的：两级同宽会让「一级导航 / 二级分类」在视觉上消失 ——
  ///   一列 232 的侧栏旁边再来一列 232 的菜单，看起来像两个并列的一级导航。
  ///
  /// 宽度够不够的验算：窗口拖到刚够分栏的 1024、且一级导航在时，内容区还有
  /// `1024 - 232(一级) - 200(分类栏) - 1(分隔线) = 591`，装得下 AI 那一页的
  /// 输入框与下拉。
  static const double settingsRailWidth = 200;

  /// 阅读区的最小宽度。
  ///
  /// 窗口刚够三栏时阅读区不能被列表栏挤没（[clampListWidth] 用它算上界）。
  ///
  /// **这里曾经还有一个 `readerMaxWidth = 900` 的封顶值**，用来把超宽屏幕上
  /// 的正文挡住。它已经删掉了：正文现在两个形态都占满可用宽度 —— 分栏右栏
  /// 的宽度本来就是用户拖出来的，再自作主张留一道留白等于把那个拖动条作废。
  static const double readerMinWidth = 420;

  /// 列表栏与阅读区之间那条可拖动分隔条的命中宽度。
  ///
  /// 比视觉上的 1px 粗得多：1px 几乎点不中，而拖动条又必须画得细才好看。
  static const double paneHandleWidth = 6;

  static bool isCompact(double width) => width < compact;
  static bool isMedium(double width) => width >= compact && width < medium;
  static bool isExpanded(double width) => width >= medium;

  /// 是否走「列表 + 阅读区」的分栏形态。
  ///
  /// 传的必须是**窗口宽度**，不是内容区宽度：路由的 `redirect`（把
  /// `/mail/<p>/<e>` 折成 `?sel=`）只能拿到窗口宽，若这里用内容宽，
  /// 两者会在临界宽度上得出相反的结论 —— 跳转到了 `?sel=`，宿主却认为
  /// 不够宽、把它咽掉，用户点开邮件什么都不会发生。
  static bool panesAt(double windowWidth) => isExpanded(windowWidth);

  /// 用 MediaQuery 的便捷版本。
  static bool compactOf(BuildContext context) =>
      isCompact(MediaQuery.sizeOf(context).width);

  static bool expandedOf(BuildContext context) =>
      isExpanded(MediaQuery.sizeOf(context).width);

  /// 当前窗口该不该分栏。`context` 只要在 `MaterialApp` 之下即可
  /// （`MediaQuery` 由 `View` 建立，`Router` 也在它之下，所以路由的
  /// `redirect` 里同样能读到）。
  static bool panesOf(BuildContext context) =>
      panesAt(MediaQuery.sizeOf(context).width);

  /// 把「想要的列表栏宽度」夹进合法区间。
  ///
  /// **必须是纯函数，而且不能直接用 `clamp(lower, upper)`**：`num.clamp` 在
  /// `lower > upper` 时**抛异常**，而窗口被拖到刚够分栏的宽度时，
  /// `available - 分隔条 - 阅读区最小宽` 会掉到 `listMinWidth` 以下 ——
  /// 那是一次拖拽拖到一半直接崩掉。这里的 `math.max` 就是那道兜底。
  ///
  /// [available] 是**内容区**宽度（宿主 `LayoutBuilder` 给的），不是窗口宽。
  static double clampListWidth(double wanted, double available) {
    final upper = math.min(
      listMaxWidth,
      available - paneHandleWidth - readerMinWidth,
    );
    return wanted.clamp(listMinWidth, math.max(listMinWidth, upper));
  }
}
