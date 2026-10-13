import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/enums.dart';
import '../../providers/profile_providers.dart' show kAllMailboxes;
import '../mail_list/mailbox_filter.dart';

/// 写邮件页要预选的发件箱（「从哪个邮箱发」）。
///
/// [accountId] 为 [kAllMailboxes]（0）表示「这个实例的全部邮箱」——
/// 与 [MailboxFilter.accountId] 同一个约定；写邮件页据此退化成「第一个可用
/// 邮箱」（`ComposeArgs.hasMailboxHint` 只认 > 0）。
@immutable
class ComposePreselect {
  const ComposePreselect({required this.profileId, required this.accountId});

  final String profileId;
  final int accountId;

  @override
  bool operator ==(Object other) =>
      other is ComposePreselect &&
      other.profileId == profileId &&
      other.accountId == accountId;

  @override
  int get hashCode => Object.hash(profileId, accountId);

  @override
  String toString() => 'ComposePreselect($profileId/$accountId)';
}

/// 这一屏**说得出**「写邮件从哪个邮箱发」吗。
///
/// 收件方向、且不是「只看未读」时才说得出。已发送与未读邮件那两屏说不出
/// 这件事（改造前收件箱里那颗 FAB 的判据也是这一条）。
///
/// **为什么单独一个函数、而不是并进「页面可不可见」那个判断**：
/// `IndexedStack` 藏起来的那一支，它的 `TickerMode` enabled 本来就是 false，
/// 所以「有没有话可说」根本没法从可见性里推出来。两件事必须分开说：
/// **说什么**（这一条）与**什么时候说**（可见性）。
///
/// 不加 `@visibleForTesting`：调用方在 `MailListScreen` 里（另一个 library），
/// 加了反而报 `invalid_use_of_visible_for_testing_member`。
bool composePreselectCanSpeak(MailFolder folder, bool unreadOnly) =>
    folder == MailFolder.receive && !unreadOnly;

/// 列表屏要发布的预选值。
///
/// 返回 null = 「这一屏说不清从哪个邮箱发」→ 外壳那颗 FAB 不带实例，
/// 让写邮件页落到当前实例的默认邮箱（`ComposeArgs.resolveProfileId`）。
///
/// 判据与**改造前 `MailListScreen._composeFab` 逐条同义**。那一颗已经删掉：
/// 外壳挂了 FAB 之后，页面上再挂一颗会被它盖住（外壳的 Scaffold 把
/// `floatingActionButton` 画在 body 最上层），所以这件事只能由外壳那颗做，
/// 而「勾了哪个邮箱」只有列表屏知道 —— 就绕这一层 provider 递过去。
///
/// - [pinnedAccountId] 非 null（左侧菜单下级菜单那一屏）：**直接用它**，
///   完全不看 [selection]。这一屏的意义就是「只看这一个邮箱」，而
///   [selection] 是全局 prefs 推出来的跨实例集合 —— 拿它推会预选成另一个
///   邮箱（用户明明正看着 a@x.com 的收件箱，写信却从 b@x.com 发）。
/// - [profileId] 为 null（`/mail/all`）：只有**恰好勾了一个邮箱**时才带它。
///   勾了一个 = 用户明确的「就从这个发」。
/// - [profileId] 非 null（`/mail/<实例>`）：实例是钉死的；这一屏收窄到唯一
///   那个具体邮箱时把它也带上。
/// - 合并项（[kAllMailboxes]）不写进地址。
/// - **不判**「有没有实例」「这一台能不能发信」：那两道闸在 `ComposeAction`
///   自己身上，两边判同一件事只会多一处会走散的结论。
///
/// 不加 `@visibleForTesting`：调用方在 `MailListScreen` 里（另一个 library）。
ComposePreselect? composePreselectOf({
  required MailboxSelection selection,
  required String? profileId,
  int? pinnedAccountId,
}) {
  if (profileId != null && pinnedAccountId != null) {
    return ComposePreselect(profileId: profileId, accountId: pinnedAccountId);
  }
  if (profileId == null) {
    if (selection.selected.length != 1) return null;
    final only = selection.selected.first;
    return ComposePreselect(
      profileId: only.profileId,
      accountId: only.accountId,
    );
  }
  final scoped = selection.selected
      .where((box) => box.profileId == profileId)
      .toList(growable: false);
  return ComposePreselect(
    profileId: profileId,
    accountId: scoped.length == 1 ? scoped.first.accountId : kAllMailboxes,
  );
}

/// 外壳那颗写邮件 FAB 的预选发件箱。
///
/// **为什么绕这一层**：FAB 是外壳挂的（一颗、所有页面共用），而
/// 「用户在收件箱里勾了哪个邮箱」只有列表屏知道。所以由**列表屏发布**、
/// 外壳读（见 [composePreselectOf]）。
///
/// 「什么时候说」的判据只有一条、且是树上的事实（不是地址）：
/// `ModalRoute.of(context)?.isCurrent` —— 在这一支的 Navigator 里是不是栈顶。
/// 压在下面的一页（比如列表上面顶着一封详情）不该替用户说话。
///
/// **刻意不看 `TickerMode`**：`StatefulShellRoute.indexedStack` 确实会给当前
/// 分支 `true`、其余 `false`，但被藏起来的那一支本来就不重建（切分支只换
/// offstage 标记），拿它当开关只会帮倒忙 —— 藏起来的那一屏一旦因为收到新邮件
/// 而重建，就会把可见那一屏刚发布的结论抹掉。
///
/// 地址在外壳那一层会慢一帧（外壳可能看到新地址、却还在渲染旧分支），
/// 不能用 —— 那正是上一版「按地址补位」失效的原因。
final NotifierProvider<ComposePreselectController, ComposePreselect?>
    composePreselectProvider =
    NotifierProvider<ComposePreselectController, ComposePreselect?>(
  ComposePreselectController.new,
  name: 'composePreselect',
);

class ComposePreselectController extends Notifier<ComposePreselect?> {
  /// 谁最后说的话（见 [publish] 的 [owner]）。
  Object? _owner;

  /// 不 watch 任何东西：这份状态是「谁最后说话」而不是派生物 ——
  /// 依赖一变就重算，会把刚发布进来的值冲掉。
  @override
  ComposePreselect? build() => null;

  /// [owner] 是调用方持有的唯一对象（页面 State 里一个 `Object()`）。
  ///
  /// 它挡的是**切分支那一帧**：旧屏清空、新屏发布，两者的 post-frame 回调
  /// 谁先跑由 build 顺序决定，而 build 顺序不可靠。改成「只有最后说话的
  /// 那个能改」之后，顺序就无关紧要了 —— 谁最后写，谁的结论留下。
  void publish(Object owner, ComposePreselect? value) {
    _owner = owner;
    if (state != value) state = value;
  }

  /// 只有自己还是最后说话的那个时才清空 —— 否则说明已经有人接棒了，
  /// 那一位的值不该被我抹掉。
  void clear(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    if (state != null) state = null;
  }
}
