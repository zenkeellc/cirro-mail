/// 侧栏那些数字的**全部文案逻辑**（纯函数，没有 Flutter 依赖）。
///
/// 单独一个文件而不是塞进 `nav_sidebar.dart`：这里的每一条分支都是「多说一个
/// 字 / 少说一个数字」这种安静的错，只有能单独跑测试才钉得住 —— 而
/// `nav_sidebar.dart` 拖着一整棵 widget 树，测试为了调一个 `formatXxx` 要
/// 先搭一个 `MaterialApp`，那就会让人干脆不写。
library;

/// 角标里的数字。
///
/// 超过 99 显示 `99+` —— 四位数的角标会把标签挤到只剩两个字，钉住位数更稳。
///
/// 抽出来是因为**已经有第二处在手抄它**了（`SidebarCountPill` 与 `BadgedIcon`
/// 各写了一遍 `count > 99 ? '99+' : '$count'`），而侧栏这一改又把「未读/总数」
/// 带进来 —— 第三份、第四份立刻会走散。
String formatSidebarCount(int count) => count > 99 ? '99+' : '$count';

/// 邮箱行（或实例行）名字后面那个**浅色总数**。`null` = **什么都不画**。
///
/// 只有两个分支：
/// - `total == null`（还没探过）或 `total == 0`（真的是空的）→ `null`。
///   几十个邮箱每个名字后面挂一个浅灰的 `0` 是同一种噪声；
/// - `total > 0` → 总数本身（`99+` 走 [formatSidebarCount]）。
///
/// 未读**不**并入这里：它挪到行最右边那颗红色徽章上（`SidebarUnreadBadge`），
/// 一灰一红各说一件事 —— 原来那个 `3/12` 在扫视时得先拆斜杠才知道哪边是未读。
///
/// 早期这里还有一个 `unknown` 参数（`3/—` 那个占位符）。拆开之后总数未知就是
/// 「不画」，未读仍然由徽章说，占位符没有存在的余地了。
String? formatMailboxTotal(int? total) =>
    (total == null || total <= 0) ? null : formatSidebarCount(total);
