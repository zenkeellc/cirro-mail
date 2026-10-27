import 'dart:math' as math;

import 'compose_text.dart' show looksLikeEmail;

/// 收件人 chip 的多选状态。
///
/// **为什么单独一个类、单独一个文件**：这套手势（点选 / ⌘ 点切换 /
/// Shift 点范围、← 从末尾往左扩、→ 收缩、⌘A 全选、退格两步删除）全是
/// 「下标算术 + 边界」，而它在控件里只表现为「chip 有没有变色」——
/// 边界错一格（0 还是 -1、「只剩一个时再按一次」算扩还是算取消）肉眼极难
/// 发现，用户只会觉得「键盘坏了」。把它抽成纯类之后，这些边界可以用
/// 普通的 `test()` 钉死，不必去点像素。
///
/// 模型只认**下标**，不认地址字符串：地址会重复（不会，控制器去了重）、
/// 也会在用户删掉中间一个 chip 之后集体前移 —— 下标随之失效，所以控件每次
/// 重建都要用 [reconcile] 把选择夹回当前列表。反过来，选择状态**不能**存
/// 地址：`state.recipients` 是控制器给的不可变列表，重排/删除之后「第几个」
/// 才是视觉上的位置。
///
/// 选区在内部是「锚点 + 活动端」：[anchor] 是 Shift+点击 / Shift+方向键的
/// 起点（不动），活动端是方向键移动的那一端，实际选中的是两者之间的**闭区间**。
/// 这跟文本选择是同一个心智模型 —— 用户不会觉得收件人 chip 与正文里的
/// 文字选择是两套东西。
class RecipientSelection {
  final Set<int> _indices = <int>{};

  /// 锚点：范围选择的起点。**不随光标移动**，换一个锚点只有三种情况 ——
  /// 单击、⌘ 点、以及从空选区开始的方向键。
  int? _anchor;

  /// 活动端：方向键移动的就是它。`null` 表示选区不是「一段范围」而是
  /// ⌘ 点拼出来的离散集合（那种情况下再按方向键会收敛成以 [_anchor] 为
  /// 起点的一段范围，与文本选择的行为一致）。
  int? _cursor;

  bool get isEmpty => _indices.isEmpty;
  bool get isNotEmpty => _indices.isNotEmpty;
  int get length => _indices.length;

  /// 选中下标，**升序**。复制地址、删除收件人都按它来 —— 顺序决定了
  /// 「复制出来那一串」和用户视觉上的顺序一致。
  List<int> get indices => _indices.toList(growable: false)..sort();

  bool contains(int index) => _indices.contains(index);

  /// 当前锚点（测试与「Shift+点击要落在哪」用得上）。
  int? get anchor => _anchor;

  void clear() {
    _indices.clear();
    _anchor = null;
    _cursor = null;
  }

  /// 单击：只选这一个，锚点也落在这里。
  void selectSingle(int index) {
    if (index < 0) return;
    _setRange(index, index);
  }

  /// ← 在空选区上的第一下：选最后一个 chip（不扩）。
  void selectLast(int count) {
    if (count <= 0) {
      clear();
      return;
    }
    selectSingle(count - 1);
  }

  void selectAll(int count) {
    if (count <= 0) {
      clear();
      return;
    }
    _setRange(0, count - 1);
  }

  /// ⌘/Ctrl+点击：切换这一枚。
  void toggle(int index) {
    if (index < 0) return;
    if (_indices.remove(index)) {
      // 取消之后把活动端放在这一格上：紧接着 Shift+点击从这里量范围，
      // 与 Finder / 资源管理器里「取消一个、再 Shift 点」的手感一致。
      _anchor = index;
      _cursor = index;
      if (_indices.isEmpty) {
        _anchor = null;
        _cursor = null;
      }
      return;
    }
    _indices.add(index);
    _anchor = index;
    _cursor = index;
  }

  /// Shift+点击：从锚点（没锚点就退化成单击）拉一块连续范围。
  void extendTo(int index) {
    if (index < 0) return;
    final anchor = _anchor;
    if (anchor == null) {
      selectSingle(index);
      return;
    }
    _setRange(anchor, index);
  }

  /// ←（含 Shift+←）：空选区选最后一个，非空则把活动端往左挪一格。
  ///
  /// 返回「状态有没有变」：控件拿它决定要不要重建 —— 已经顶到最左边时
  /// 每按一次都重建一遍整行是白费。
  bool arrowLeft(int count) {
    if (count <= 0) return false;
    if (_indices.isEmpty) {
      selectLast(count);
      return true;
    }
    final cursor = _cursor ?? _maxIndex;
    if (cursor <= 0) return false;
    final anchor = _anchor ?? cursor;
    _setRange(anchor, cursor - 1);
    return true;
  }

  /// →（含 Shift+→）：**收缩** —— 活动端朝锚点走一格；活动端已经与锚点
  /// 重合（只剩一个选中）时再按一次就是取消选择。
  ///
  /// 「消到空」这个分支是有意的：用户在末尾一路按 →，最后的落点应该是
  /// 「什么都没选」，而不是卡在一个选中的 chip 上 —— 那样再按退格会删掉
  /// 他以为已经取消掉的那个地址。
  bool arrowRight(int count) {
    if (_indices.isEmpty || count <= 0) return false;
    final cursor = _cursor ?? _maxIndex;
    final anchor = _anchor ?? cursor;
    if (cursor == anchor) {
      clear();
      return true;
    }
    final next = cursor + 1;
    if (next >= count) {
      // 锚点在左边、活动端一路向右扩到列表末尾：再扩就越界了。这里不
      // 顺手 clear —— 用户还在「扩」的方向上，清空选区会吓他一跳。
      return false;
    }
    _setRange(anchor, next);
    return true;
  }

  /// 把选择夹回「当前有 [count] 个 chip」的列表。
  ///
  /// 每次重建都要跑：用户删掉一个 chip、草稿恢复换了整批收件人、发送成功
  /// 清空列表 —— 这些都会让旧下标指向不存在的格子。不夹的话，最轻的表现是
  /// 高亮飘到空处，重的是删掉不相干的收件人（`recipients[i]` 越界或错位）。
  void reconcile(int count) {
    if (count <= 0) {
      if (_indices.isNotEmpty) clear();
      return;
    }
    _indices.removeWhere((i) => i < 0 || i >= count);
    _anchor = _clamp(_anchor, count);
    _cursor = _clamp(_cursor, count);
    if (_indices.isEmpty) {
      _anchor = null;
      _cursor = null;
    }
  }

  /// 选中项对应的地址，**按下标升序**。
  List<String> addressesFrom(List<String> recipients) => <String>[
    for (final i in indices)
      if (i >= 0 && i < recipients.length) recipients[i],
  ];

  int get _maxIndex => _indices.reduce(math.max);

  void _setRange(int a, int b) {
    _anchor = a;
    _cursor = b;
    _indices
      ..clear()
      ..addAll(<int>[for (var i = math.min(a, b); i <= math.max(a, b); i++) i]);
  }

  static int? _clamp(int? value, int count) {
    if (value == null) return null;
    if (value < 0) return 0;
    if (value >= count) return count - 1;
    return value;
  }
}

/// 硬分隔符：**逗号、分号、顿号、换行、制表符**。
///
/// 都是「这个地址肯定写完了」的信号，不可能是地址的一部分。空格刻意不在此
/// 列 —— 见 [splitRecipientInput] 里那条「完整地址之后的空格」。
const String _hardSeparators = ',;，、\r\n\t';

/// 把用户刚敲/刚粘进来的一整串拆成「可以立刻收下的地址」与「还留在输入框里
/// 的那半截」。
///
/// 为什么要有这个函数：`ComposeController.commitRecipientInput()` 只在
/// 回车 / 逗号键 / 失焦时被调用，而粘贴一串 `a@x.com, b@y.com` 这两条路都
/// 不会立刻走到 —— 用户看到的是「一长串地址挤在输入框里」，直到点别处才
/// 变成 chip。这里按「边界」实时拆：一边打字一边成型。
///
/// 三条刻意的判据：
///
/// 1. **只在确定写完的地方切**：硬分隔符，或者「一个完整地址后面跟了空格」
///    （`a@x.com b@y.com` 是复制粘贴的常见形状）。
/// 2. **切出来的每一段都必须是地址**，否则整串原样留着。宁可让用户自己删，
///    也不能把一个写错的地址悄悄吃掉 —— 那就是「地址凭空消失」。
/// 3. **尾部半截留在输入框**：没有分隔符结尾的那一段永远不自动收下，用户还在
///    敲它。
///
/// 返回值里的 `remainder` 是**已经去掉前缀**之后剩下的文字；`accepted` 为空
/// 时 `remainder` 就是原串（控件据此判断「这次不必改输入框」）。
({List<String> accepted, String remainder}) splitRecipientInput(String raw) {
  final accepted = <String>[];
  var rest = raw;
  while (rest.isNotEmpty) {
    final boundary = _firstBoundary(rest);
    if (boundary == null) break;
    final piece = rest.substring(0, boundary).trim();
    if (piece.isEmpty) {
      // 连着两个分隔符（`, ,` / 换行后面一个逗号）：跳过空段继续找。
      rest = rest.substring(boundary + 1);
      continue;
    }
    if (!looksLikeEmail(piece)) break;
    accepted.add(piece);
    rest = rest.substring(boundary + 1);
  }
  if (accepted.isEmpty) {
    return (accepted: const <String>[], remainder: raw);
  }
  return (accepted: accepted, remainder: rest.trim());
}

/// `raw` 里第一个「地址写完」的位置（分隔符本身的下标）。
int? _firstBoundary(String raw) {
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (_hardSeparators.contains(ch)) return i;
    // 空格只有在「前面已经是一个完整地址」时才算边界：否则 `zhang zhang`
    // 这种打到一半的名字会被拆成两截。
    if (ch == ' ' && looksLikeEmail(raw.substring(0, i).trim())) return i;
  }
  return null;
}
