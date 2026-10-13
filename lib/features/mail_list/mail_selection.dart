import 'package:flutter/foundation.dart';

import '../../data/models/mail_ref.dart';

/// 多选状态下「这一批选中了哪几行」。
///
/// ## 为什么存**行下标**而不是 `MailRef`
///
/// 两种表达都要能算出来：
/// - [cells]：Shift / Ctrl 逐行勾出来的集合；
/// - [band]：长按后拖动扫出来的一段**连续**区间，只记「起点 + 长度」两个数。
///
/// 两个原因让「存下标、用的时候现解析成 `MailRow`」是唯一说得通的方案：
///
/// 1. **拖动带会越过可见范围**。手指扫到列表底部时带子要继续长，而那时候
///    底下那些行可能还没被 `SliverList` 建出来 —— 存 `MailRef` 就要求每一格
///    都已经有行对象，做不到。
/// 2. **行数会变**。同步下来一批新邮件，列表顶部会插进新行。存 `MailRef`
///    的话「这一段」就散架了；存 `bandStart + bandLength` 至少能按同一条规则
///    重新算一遍（见 [positions] 的越界规则）。
///
/// ## 为什么 `cells` 与 `band` 不能合并成一个 `Set<int>`
///
/// 那正是这个类要解决的问题：拖动扫过 500 行时，`Set<int>` 要装 500 个整数、
/// 每帧重建一次；而 `band` 只有两个数，从 `(20, 3)` 长到 `(20, 500)` 是
/// 两次赋值。拖完之后才会 [normalize] 成 `cells` —— 那一步之后它才需要一个
/// 大集合，而那时候拖动已经结束了。
@immutable
class MailSelection {
  const MailSelection({
    this.scope,
    this.cells = const <int>{},
    this.bandStart,
    this.bandLength = 0,
    this.anchor,
  }) : assert(
          bandStart == null || bandStart >= 0,
          'bandStart 只在拖动时有意义，且从 0 开始',
        );

  /// 这份选择是在**哪一块列表**上做的。
  ///
  /// 见 [selectionScopeOf]：它把「实例节点 / 文件夹 / 只看未读 / 星标页」
  /// 折成一个字符串。同一时刻只会有一块列表的选择是「活的」—— 别处（另一屏、
  /// 另一个文件夹、被 `IndexedStack` 藏起来的那一支）读到 scope 对不上，
  /// 就知道「这不是我的选择」，既不高亮也不接管。
  final String? scope;

  /// 逐个勾选的行下标（当前列表快照下）。
  final Set<int> cells;

  /// 拖动带的起点行下标；null = 没有在拖。
  final int? bandStart;

  /// 拖动带覆盖多少行（>= 1 才有意义）。
  final int bandLength;

  /// Shift 点击的锚点 / 右键那一封。
  ///
  /// **存 `MailRef` 而不是下标**：锚点必须钉在**邮件的身份**上，不是位置 ——
  /// 用户 Shift 点到第 40 行，中途同步插进来 3 封新邮件，锚点不该跟着往下滑。
  /// 解析回下标时找不到（那封被删了 / 被过滤了）就放弃扩展，见 [shiftRange]。
  final MailRef? anchor;

  /// 是「正在多选」而不是「什么都没选」。
  bool get isActive =>
      cells.isNotEmpty || (bandStart != null && bandLength > 0);

  static const MailSelection empty = MailSelection();

  /// 收干净：`cells` 里越界的丢掉，`band` 折成具体的行下标。
  ///
  /// 任何**界面读取**都应该先过它一次 —— 这样「已选 N 封」这个数字与按钮
  /// 真正会作用到的那批行**永远是同一个集合**，不会出现「显示 5 封、
  /// 实际删 3 封」。
  MailSelection normalize(int rowCount) => MailSelection(
        scope: scope,
        cells: positions(rowCount).toSet(),
        anchor: anchor,
      );

  /// 折成行下标列表（**升序、不重复**）。
  ///
  /// [band] 的越界规则（纯函数，`test/mail_selection_test.dart` 钉着）：
  /// - `k = min(bandLength, rowCount)`：带子不可能比列表还长；
  /// - `start + k <= rowCount` 时就是 `[start, start + k)`；
  /// - 越过末尾时**整体退回最后 k 行**（`[rowCount - k, rowCount)`）。
  ///
  /// 最后那条是关键：拖动带往下拉到底以后 `start + length` 会一直涨，
  /// 用 `clamp` 逐格夹会得到一段「尾巴被压平」的区间（末尾几行重复算），
  /// 而「退回最后 k 行」让这一段**始终是 k 行**，且用户往回拖时能原样收回去。
  List<int> positions(int rowCount) {
    final result = <int>{};
    for (final index in cells) {
      if (index >= 0 && index < rowCount) result.add(index);
    }
    final start = bandStart;
    final length = bandLength;
    if (start != null && length > 0 && rowCount > 0) {
      final k = length < rowCount ? length : rowCount;
      final from = start + k <= rowCount ? start : rowCount - k;
      for (var i = 0; i < k; i++) {
        result.add(from + i);
      }
    }
    final sorted = result.toList()..sort();
    return sorted;
  }

  /// 解析出真正选中的那几封（**按列表顺序**，调用方不必再排一次）。
  ///
  /// 行下标撞上越界（列表缩短了）时下面的 `where` 会自然把它们丢掉。
  List<MailRef> refsOf(List<MailRef> ordered) {
    final picked = positions(ordered.length);
    return <MailRef>[for (final index in picked) ordered[index]];
  }

  // ------------------------------------------------------------ 变换

  /// 只选中这一行（平点 / 右键落在没选中的行上）。
  MailSelection only(int index, {MailRef? anchor, bool clearAnchor = false}) =>
      MailSelection(
        scope: scope,
        cells: <int>{index},
        anchor: clearAnchor ? anchor : (anchor ?? this.anchor),
      );

  /// 整个列表全选（「全选（本页 N 封）」）。
  MailSelection all(int rowCount) => MailSelection(
        scope: scope,
        cells: <int>{for (var i = 0; i < rowCount; i++) i},
        anchor: anchor,
      );

  /// Ctrl / Cmd 点击：在集合里加一个或去掉一个。
  ///
  /// 减到空**不等价于退出多选** —— 退出是控制器的事（它要看 `isActive`）。
  /// 这里只负责集合本身。
  MailSelection toggle(int index) {
    final next = Set<int>.of(cells);
    if (!next.remove(index)) next.add(index);
    return MailSelection(scope: scope, cells: next, anchor: anchor);
  }

  /// Shift 点击：从 [anchor] 到这一行。
  ///
  /// 锚点解析不出来（已被删 / 不在当前列表里）时**退回只选这一行**并把它
  /// 设为新锚 —— 比什么都不做更像用户预期（用户看到的是「点了没反应」）。
  MailSelection extendTo(int index, List<MailRef> ordered) {
    final from = _indexOf(ordered, anchor);
    if (from == null) return only(index, anchor: ordered[index]);
    final lo = from < index ? from : index;
    final hi = from < index ? index : from;
    return MailSelection(
      scope: scope,
      cells: <int>{for (var i = lo; i <= hi; i++) i},
      anchor: anchor,
    );
  }

  /// 长按进入多选并按到的那一行起一条拖动带。
  MailSelection beginBand(int index, {MailRef? anchor}) => bandAt(index, 1, anchor: anchor);

  /// 拖动中：带子现在从哪一行起、有多长。
  ///
  /// **两个参数都由视图算**：只有它知道行高、指针位移，以及「按住的那一行」
  /// 的原始下标（往回拖时起点要跟着往上走，不是固定不动）。这个类只负责把
  /// 结果存下来。
  MailSelection bandAt(int start, int length, {MailRef? anchor}) => MailSelection(
        scope: scope,
        bandStart: start,
        bandLength: length,
        anchor: anchor ?? this.anchor,
      );

  /// 拖动结束：把带子折成具体行下标。
  ///
  /// **不 [normalize] 就落状态**的话，接下来每一次读取都要再算一遍
  /// `bandLength`（因为行数随时会变），而且「带子」这个形态会一直跟着这份
  /// 状态走 —— 但拖动已经结束了，那时它唯一的用途就是被折成集合。
  MailSelection commitBand(int rowCount) => normalize(rowCount);

  static int? _indexOf(List<MailRef> ordered, MailRef? ref) {
    if (ref == null) return null;
    final index = ordered.indexOf(ref);
    return index >= 0 ? index : null;
  }

  @override
  bool operator ==(Object other) =>
      other is MailSelection &&
      other.scope == scope &&
      other.bandStart == bandStart &&
      other.bandLength == bandLength &&
      other.anchor == anchor &&
      setEquals(other.cells, cells);

  @override
  int get hashCode => Object.hash(
        scope,
        bandStart,
        bandLength,
        anchor,
        Object.hashAllUnordered(cells),
      );

  @override
  String toString() =>
      'MailSelection(scope: $scope, cells: ${cells.length}, '
      'band: $bandStart+$bandLength)';
}

/// 「这一块列表」的身份 —— 多选不跨列表串味靠它。
///
/// 为什么不用 `MailListQuery` 本身：它是 `family` 的 key，跨会话/跨实例的比较
/// 要走那条值相等（集合无序）的路径；而这里要的是一根**稳定的字符串**，
/// 存进状态里、给别的屏比较用。两者关心的东西不一样，硬合成一个迟早会分叉。
///
/// 四个输入对应四种「换一块列表」的方式：换实例节点 / 换文件夹 / 切「只看
/// 未读」/ 换看的是哪几个邮箱（星标页的实例 Tab、收件箱那张勾选出来的集合）。
/// 任一项变了，旧选择就作废 —— 用户从收件箱切到已发送，那一批勾选对该列表
/// 毫无意义。
///
/// **邮箱集合那一项不能省**：星标页的实例 Tab 换的只是 `mailboxes`（节点还是
/// `all`），收件箱那张勾选表换的也只是它。少了它，切个 Tab 之后同一批行下标
/// 会指向另外几封信 —— 而列表看上去「差不多」，用户根本发现不了。
String selectionScopeOf({
  String? listNode,
  String folder = 'receive',
  bool unreadOnly = false,
  String mailboxSet = '*',
}) {
  final parts = <String>[
    listNode ?? 'all',
    folder,
    unreadOnly ? 'unread' : 'all',
    mailboxSet,
  ];
  return parts.join('|');
}

/// 这份选择是不是（就该由）这一块列表来处理。
///
/// 判据只有这一处：`MailListView` 用它决定画不画复选框，列表页用它决定右栏
/// 要不要换成多选面板。两处各写一遍的话，「左栏在选、右栏还在显示某一封的
/// 正文」这种对不上的状态迟早出现。
bool selectionAppliesTo(MailSelection selection, String scope) =>
    selection.isActive && selection.scope == scope;
