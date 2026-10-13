import 'package:flutter/foundation.dart';

import '../../data/models/mailbox_account.dart';
import '../../providers/profile_providers.dart' show kAllMailboxes;

/// 「某实例的某个邮箱」。
///
/// 收件箱的筛选条件从「一个实例 + 一个邮箱」（URL 里的 `account=`）升级成
/// 一个**跨实例的集合**，这个类是那个集合的元素。
///
/// [accountId] 为 [kAllMailboxes]（0）是一个**有意义的值**，不是「没指名」：
/// 它表示「这个实例的全部邮箱」。缺 `account:query` 权限时本地拿不到邮箱
/// 列表，实例行只能退化成这一个合并项。别把它当成空值处理 —— 列表查询的
/// 谓词里 `accountId == kAllMailboxes` 走的是另一条分支（只看 `profileId`），
/// 见 `MailListQuery` 的注释。
@immutable
class MailboxFilter {
  const MailboxFilter({required this.profileId, required this.accountId});

  final String profileId;
  final int accountId;

  /// 落 prefs 的字符串形态。`profileId` 是 uuid v4，里面不会有 `/`。
  String get wire => '$profileId/$accountId';

  MailboxFilter copyWithAccount(int accountId) =>
      MailboxFilter(profileId: profileId, accountId: accountId);

  static MailboxFilter? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final at = raw.indexOf('/');
    if (at <= 0) return null;
    final id = raw.substring(0, at);
    final account = int.tryParse(raw.substring(at + 1));
    if (id.isEmpty || account == null || account < 0) return null;
    return MailboxFilter(profileId: id, accountId: account);
  }

  static MailboxFilter parse(String raw) {
    final parsed = tryParse(raw);
    if (parsed == null) throw FormatException('不是合法的邮箱筛选值：$raw');
    return parsed;
  }

  @override
  bool operator ==(Object other) =>
      other is MailboxFilter &&
      other.profileId == profileId &&
      other.accountId == accountId;

  @override
  int get hashCode => Object.hash(profileId, accountId);

  @override
  String toString() => 'MailboxFilter($wire)';
}

/// 实例行的三态。`Checkbox` 只能表达两态，半选要自己画。
enum MailboxTriState { all, partial, none }

/// 勾选面板的当前态。
///
/// [all] 是「这个用户拥有的全部邮箱」（由各实例的 `mailboxesProvider` 拼出来）；
/// [selected] 是其中被勾上的那些。**恒非空** —— 最少留一个是硬规则。
@immutable
class MailboxSelection {
  const MailboxSelection._({
    required this.all,
    required this.selected,
    required this.rejected,
    this.rejectionSeq = 0,
  });

  final List<MailboxFilter> all;
  final List<MailboxFilter> selected;

  /// 上一次 [toggle] / [toggleProfile] 是不是被「最少留一个」挡下来了。
  /// UI 拿它弹一句提示，纯逻辑本身不改状态。
  final bool rejected;

  /// 「被拒绝」这件事发生过的次数（自增）。
  ///
  /// 比 [rejected] 那个布尔多一个维度：布尔只有上升沿，**连着拒绝两次时
  /// 第二次什么都不会发生**（`prev.rejected` 已经是 true 了）。面板从
  /// 「弹一下就没」的底部弹层变成常驻浮层之后，这个 bug 会变得很显眼 ——
  /// 用户连点两下「取消最后一个」，第二次却安安静静。
  ///
  /// UI 一律比**序号**，不比布尔。
  final int rejectionSeq;

  /// 把「落 prefs 的值」折成勾选态。
  ///
  /// [saved] 为 null 表示**还没筛过** = 全部勾上（这是默认态）。
  /// 一项都对不上时（邮箱在 Web 端被删了）也退回全部：留下一个空集会让列表
  /// 永久空白，而用户完全看不出是自己哪一步做错了。
  static MailboxSelection resolve(
    List<MailboxFilter> all,
    List<MailboxFilter>? saved,
  ) {
    if (all.isEmpty) {
      return const MailboxSelection._(
        all: <MailboxFilter>[],
        selected: <MailboxFilter>[],
        rejected: false,
      );
    }
    if (saved == null || saved.isEmpty) {
      return MailboxSelection._(all: all, selected: all, rejected: false);
    }
    final wanted = saved.toSet();
    final kept = all.where(wanted.contains).toList(growable: false);
    if (kept.isEmpty) {
      return MailboxSelection._(all: all, selected: all, rejected: false);
    }
    return MailboxSelection._(all: all, selected: kept, rejected: false);
  }

  bool get isAll => all.isNotEmpty && selected.length == all.length;

  bool get isPartiallySelected =>
      selected.isNotEmpty && selected.length < all.length;

  /// 筛选按钮上那个数字。全选时不给数字（按钮就只是一个漏斗）。
  int? get badgeCount => isPartiallySelected ? selected.length : null;

  /// 写回 prefs 的值：全选写 null（= 没筛过），否则写具体集合。
  List<MailboxFilter>? toPrefsValue() => isAll ? null : selected;

  MailboxSelection _with(List<MailboxFilter> next, {bool rejected = false}) =>
      MailboxSelection._(
        all: all,
        selected: _ordered(next),
        rejected: rejected,
        // 只在**这一次也**被拒时自增：成功的那几次不碰它，于是序号严格等于
        // 「被拒过几次」，UI 每次比较都拿得到一个严格变大的值。
        rejectionSeq: rejected ? rejectionSeq + 1 : rejectionSeq,
      );

  /// 把 `selected` 归到 `all` 的顺序上。
  ///
  /// 勾选是「加一个进集合」，但如果直接 append，取消再勾回来之后那一项会跑到
  /// 末尾 —— 于是列表的邮箱顺序跟着用户的点击历史变。写进 prefs 的那个集合
  /// 也因此每次不一样（内容相同、顺序不同），测试与快照都会莫名其妙地飘。
  /// 顺序一律以 [all] 为准，与用户的操作顺序无关。
  List<MailboxFilter> _ordered(List<MailboxFilter> items) {
    final wanted = items.toSet();
    return all.where(wanted.contains).toList(growable: false);
  }

  /// 勾选 / 取消一项。
  ///
  /// **最少留一个**：取消最后一个会被拒绝，原样返回并置 [rejected]。
  MailboxSelection toggle(MailboxFilter item) {
    final index = selected.indexOf(item);
    if (index >= 0) {
      if (selected.length <= 1) {
        return _with(selected, rejected: true);
      }
      final next = List<MailboxFilter>.of(selected)..removeAt(index);
      return _with(next);
    }
    final next = List<MailboxFilter>.of(selected)..add(item);
    return _with(next);
  }

  /// 点实例行 = 该实例整组切换（有半选时按「没勾」处理，即先全勾上）。
  MailboxSelection toggleProfile(String profileId) {
    final group = all
        .where((box) => box.profileId == profileId)
        .toList(growable: false);
    if (group.isEmpty) return _with(selected);

    final groupSet = group.toSet();
    final groupOn = group.every(selected.contains);

    if (groupOn) {
      final next =
          selected.where((box) => !groupSet.contains(box)).toList(growable: false);
      if (next.isEmpty) return _with(selected, rejected: true);
      return _with(next);
    }

    final next = List<MailboxFilter>.of(selected);
    for (final box in group) {
      if (!next.contains(box)) next.add(box);
    }
    return _with(next);
  }

  MailboxTriState profileState(String profileId) {
    final group = all.where((box) => box.profileId == profileId).toList();
    if (group.isEmpty) return MailboxTriState.none;
    var on = 0;
    for (final box in group) {
      if (selected.contains(box)) on++;
    }
    if (on == 0) return MailboxTriState.none;
    if (on == group.length) return MailboxTriState.all;
    return MailboxTriState.partial;
  }
}

/// 落 prefs 的字符串列表。
List<String> mailboxesToPrefs(List<MailboxFilter> boxes) =>
    boxes.map((box) => box.wire).toList(growable: false);

/// 从 prefs 读回来，坏数据直接丢掉（不让一行烂数据把整个筛选弄没）。
List<MailboxFilter>? prefsToMailboxes(List<String>? raw) {
  if (raw == null || raw.isEmpty) return null;
  final parsed = <MailboxFilter>[];
  for (final item in raw) {
    final box = MailboxFilter.tryParse(item);
    if (box != null) parsed.add(box);
  }
  return parsed.isEmpty ? null : parsed;
}

// ---------------------------------------------------------------------------
// 「实例 → 可勾的项」。
//
// 这几个原来是勾选面板里的私有 helper，搬到模型文件里是因为**别处也要用同一份
// 结论**：左侧菜单的邮箱下级菜单要把「这台实例有哪些邮箱」列出来，规则必须与
// 面板一模一样 —— 缺 `account:query` 权限的实例在两边都得退化成一个合并项，
// 否则那台实例会在一边里整体消失。
// ---------------------------------------------------------------------------

/// 一个实例下有哪些可勾的项。
///
/// **本地没有邮箱列表时给一行合并项**（`accountId = kAllMailboxes`）：
/// 缺 `account:query` 权限的账号拿不到 `/account/list`，本地邮箱表是空的。
/// 不给这一行的话，那台实例在面板里完全没有可勾的东西 —— 用户筛了别的实例
/// 之后，它的信会一声不响地整体消失。
List<MailboxFilter> boxesOfProfile(
  String profileId,
  List<MailboxAccount> mailboxes,
) =>
    mailboxes.isEmpty
        ? <MailboxFilter>[
            MailboxFilter(profileId: profileId, accountId: kAllMailboxes),
          ]
        : mailboxes
            .map((box) => MailboxFilter(
                  profileId: profileId,
                  accountId: box.accountId,
                ))
            .toList(growable: false);

/// 把「实例 → 它的邮箱列表」拼成完整可勾集合，保持传入的实例顺序。
List<MailboxFilter> allBoxesOf(Map<String, List<MailboxAccount>> byProfile) {
  final boxes = <MailboxFilter>[];
  for (final entry in byProfile.entries) {
    boxes.addAll(boxesOfProfile(entry.key, entry.value));
  }
  return boxes;
}

/// 分组渲染时的实例顺序（**不用集合**：顺序是给用户看的）。
List<String> profileOrderOf(List<MailboxFilter> boxes) {
  final seen = <String>{};
  final order = <String>[];
  for (final box in boxes) {
    if (seen.add(box.profileId)) order.add(box.profileId);
  }
  return order;
}

/// 邮箱行显示什么。**不依赖 `BuildContext`** —— 合并项那一支的文案由调用方
/// 通过 [allMailboxesLabel] 传进来，这个函数才能脱离 widget 测。
String mailboxLabelOf(
  MailboxFilter box,
  Map<String, List<MailboxAccount>> byProfile, {
  String allMailboxesLabel = '全部邮箱',
}) {
  if (box.accountId == kAllMailboxes) return allMailboxesLabel;
  final list = byProfile[box.profileId] ?? const <MailboxAccount>[];
  return list.byId(box.accountId)?.email ?? '${box.accountId}';
}
