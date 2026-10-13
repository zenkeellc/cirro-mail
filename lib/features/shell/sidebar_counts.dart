/// 侧栏右侧那些数字的**全部文案逻辑**（纯函数，没有 Flutter 依赖）。
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

/// 侧栏一行右侧那一格的文案。`null` = **什么都不画**。
///
/// 五个分支：
/// - 未知总数 + 未读 0 → `null`。几十个邮箱每个挂一个 `—`、或每个挂一个灰色
///   的 `0`，是同一种噪声（既有约定，见 `SidebarMailboxCounts` 的注释）；
/// - 未知总数 + 未读 > 0 → `3/—`：有东西可看，只是还不知道总数；
/// - 已知 0 / 0 → `null`（同上，也是噪声）；
/// - 已知总数 + 未读 > 0 → `3/12`；
/// - 已知总数 + 未读 0 → `12`：未读为 0 时那个 `0/` 前缀只占地方。
///
/// **`total == null` 的判据是「还没探过」（库里 `remoteTotalAt == null`），
/// 不是 `total == 0`** —— 后者是「服务端说这个邮箱是空的」这条正经结论，
/// 按上面第四条折成 `0/0` → 不画。调用方负责把库里那三态折成这里的 `int?`。
///
/// [unknown] 是那个占位符，由调用方从 l10n 取（`l10n.mailboxCountUnknown`）。
/// 它看着只是个字面量 `—`，但**故意没有默认值**：纯函数里留一个默认值，
/// 漏传的那天就会安静地把一个字面量写死进界面，而那正是这一层想避免的事。
String? formatMailboxCounts({
  required int unread,
  required int? total,
  required String unknown,
}) {
  if (total == null) {
    return unread > 0 ? '${formatSidebarCount(unread)}/$unknown' : null;
  }
  if (unread <= 0) {
    return total > 0 ? formatSidebarCount(total) : null;
  }
  return '${formatSidebarCount(unread)}/${formatSidebarCount(total)}';
}
