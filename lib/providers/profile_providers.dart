import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/enums.dart';
import '../data/models/mail_ref.dart';
import '../data/models/profile.dart';
import '../features/mail_list/mailbox_filter.dart';
import 'core_providers.dart';

/// 所有实例（按 `sort` 升序）。
///
/// 它是 `profiles` 表的 live query —— 改名、加实例、标记「需重登」
/// 都会自动让 UI 刷新，不需要谁去手动 invalidate。
final StreamProvider<List<Profile>> profilesProvider =
    StreamProvider<List<Profile>>(
  (ref) => ref.watch(profileRepositoryProvider).watchAll(),
  name: 'profiles',
);

/// 已登录、可以收信的实例（聚合视图与「当前实例」只认这一批）。
///
/// **同步调度不用它** —— 那件事要的集合更宽，见 [syncCandidatesProvider]。
final Provider<List<Profile>> activeProfilesProvider = Provider<List<Profile>>(
  (ref) {
    final list = ref.watch(profilesProvider).value ?? const <Profile>[];
    return list
        .where((p) => p.isLoggedIn)
        .toList(growable: false);
  },
  name: 'activeProfiles',
);

/// **该被同步调度考虑的**实例：**全部实例**，一个不筛。
///
/// 这里以前是一道 `userId > 0 && email.isNotEmpty` 的过滤，它同时踩了两个坑
/// （「新加的实例同步面板里没有、同步也不管它」就是这么来的）：
///
/// 1. **新建的实例到登录成功之间有一段它不满足的窗口**。`ProfileRepository
///    .create()` 把 `userId` 留成 0、`email` 留成空串，只有
///    `AuthRepository.loginAndApply` 走到 `markLoggedIn` 才写进这两列 ——
///    而用户「加了一台新服务器」之后很可能就停在那一段里（还没输密码、
///    或者登录成功了但 `loginUserInfo` 那一步失败，此时 **token 已经在钥匙串
///    里了**）。这一批实例在设置页看得见（那边读的是不筛的 `profilesProvider`），
///    在同步页却整台消失 —— 用户看到的是「加完了什么都没发生」。
/// 2. **把「能不能收信」这个判断挪错了地方**。真正的判据是「手里有没有
///    可用的 token」，而那件事**只有预热之后才知道**（`ProfileRuntime`
///    的 `hasToken` 看的是内存缓存，冷启动时得先 `warmUp` 读一次钥匙串）。
///    在这里按 `userId` 预筛等于用一个更弱的信号去替一个更强的判断，
///    结果是「有 token 但 userId 还没落库」的实例被永久排除。
///
/// 所以判据交给**真正有资格判断的那一处**：`SyncScheduler._ensureEngineFor`
/// 的 `!runtime.hasToken → return null`（没 token 就建不出 engine、这一台
/// 自然不进调度），以及 `SyncEngine.syncOnce` 开头那道同样的闸。这一层只负责
/// 「谁该出现在被考虑的名单里」—— 名单宽一点是**想要**的：出现在名单里、
/// 但不满足建 engine 的条件，界面上会如实显示成「需要重新登录 / 已停止」，
/// 那正是用户该看到的东西。
///
/// **仍然不含过滤的另一个理由**是会话自愈：`needsLogin` 是**落库的**标记，
/// 而过滤掉它正是「标记 → 被排除在调度外 → 永远没机会再验一次 → 标记永远
/// 留着」这个死循环的闭合点。真实的故障是服务端换过 `jwt_secret`
/// （提交 `c04c206` 自己写着「所有登录态立即失效」），而钥匙串里那份 token
/// 是**能**被恢复的 —— 只要有人去问一次（`RuntimeRegistry.probeSession`）。
///
/// 注意它**不**换掉聚合视图的口径：一个需重登（或还没登录）的实例，它的
/// 历史邮件当然还在本地可以看，但把它的信混进聚合时间线会让「这台实例
/// 下线了」这件事彻底看不见。所以聚合视图仍然只认 [activeProfilesProvider]。
final Provider<List<Profile>> syncCandidatesProvider = Provider<List<Profile>>(
  (ref) => ref.watch(profilesProvider).value ?? const <Profile>[],
  name: 'syncCandidates',
);

/// 用户选中的「当前实例」。
///
/// 来源是 `PrefsStore.activeProfileId`，但它可能指向一个已被删除的实例，
/// 所以这里会落到第一个可用实例上 —— 否则 UI 会拿到 null 而不知道
/// 该显示谁（冷启动、删除当前实例、登出之后都会遇到）。
final Provider<Profile?> currentProfileProvider = Provider<Profile?>(
  (ref) {
    final list = ref.watch(profilesProvider).value ?? const <Profile>[];
    if (list.isEmpty) return null;
    final wantedId = ref.watch(activeProfileIdProvider);
    if (wantedId != null) {
      for (final profile in list) {
        if (profile.id == wantedId) return profile;
      }
    }
    return list.first;
  },
  name: 'currentProfile',
);

/// 只存 id，避免「读 prefs 再查表」的循环依赖。
final activeProfileIdProvider = Provider<String?>(
  (ref) => ref.watch(prefsStoreProvider).activeProfileId,
  name: 'activeProfileId',
);

/// 当前实例的 id（空实例列表时为 null）。
final Provider<String?> currentProfileIdProvider = Provider<String?>(
  (ref) => ref.watch(currentProfileProvider)?.id,
  name: 'currentProfileId',
);

/// 按 id 取实例。
final profileByIdProvider = Provider.family<Profile?, String>(
  (ref, id) {
    final list = ref.watch(profilesProvider).value ?? const <Profile>[];
    for (final profile in list) {
      if (profile.id == id) return profile;
    }
    return null;
  },
  name: 'profileById',
);

/// 某个实例上「所有邮箱」的聚合视图用的伪 `accountId`。
///
/// 服务端在 `allReceive=1` 时会忽略 `accountId`，所以聚合视图传 0 就行；
/// 本地查询也用 `allReceive: true`，同样不看这个值。定义成常量是为了
/// 让「0 表示不分邮箱」这件事在调用点上可读。
const int kAllMailboxes = 0;

/// 列表视图（收件箱 / 未读 / 已发送 / 星标）的查询描述。
///
/// 做成值对象而不是几个散落的参数，是为了让 Riverpod 的 family 能按值比较。
///
/// 这是一次**语义升级**：以前是「一个实例 + 一个邮箱」两个标量，现在是
/// 「一个跨实例的邮箱集合」。旧形状表达不了「A 的收件箱 + B 的对账邮箱」
/// 这种最常用的组合。
///
/// 字段含义：
/// - [mailboxes] 为空 → **全部实例的全部邮箱**（聚合语义，与聚合页一致）；
/// - [folder] 决定 `type` 与游标口径（星标走另一张缓存路径）；
/// - [unreadOnly] 只看收件方向的未读（主屏「未读邮件」入口）。
class MailListQuery {
  const MailListQuery({
    this.mailboxes = const <MailboxFilter>[],
    this.folder = MailFolder.receive,
    this.unreadOnly = false,
  });

  final List<MailboxFilter> mailboxes;
  final MailFolder folder;
  final bool unreadOnly;

  /// 空集合 = 全部。
  bool get allMailboxes => mailboxes.isEmpty;

  /// 只选了一个邮箱时才能翻页 —— 多邮箱之间没有统一的游标
  /// （各实例的 `emailId` 是独立序列，跨实例翻页本来就是不成立的）。
  bool get singleMailbox => mailboxes.length == 1;

  /// 查询会碰到的实例（去重、保持首次出现的顺序）。
  List<String> get profileIds {
    if (mailboxes.isEmpty) return const <String>[];
    final seen = <String>{};
    final ids = <String>[];
    for (final box in mailboxes) {
      if (seen.add(box.profileId)) ids.add(box.profileId);
    }
    return ids;
  }

  int get apiType => folder.apiType;

  MailListQuery copyWith({
    List<MailboxFilter>? mailboxes,
    MailFolder? folder,
    bool? unreadOnly,
    bool clearMailboxes = false,
  }) =>
      MailListQuery(
        mailboxes:
            clearMailboxes ? const <MailboxFilter>[] : (mailboxes ?? this.mailboxes),
        folder: folder ?? this.folder,
        unreadOnly: unreadOnly ?? this.unreadOnly,
      );

  /// 单个实例的视图。[accountId] 为 [kAllMailboxes] 时是该实例的全部邮箱。
  static MailListQuery forProfile(
    String profileId, {
    int accountId = kAllMailboxes,
    MailFolder folder = MailFolder.receive,
    bool unreadOnly = false,
  }) =>
      MailListQuery(
        mailboxes: <MailboxFilter>[
          MailboxFilter(profileId: profileId, accountId: accountId),
        ],
        folder: folder,
        unreadOnly: unreadOnly,
      );

  @override
  bool operator ==(Object other) =>
      other is MailListQuery &&
      other.folder == folder &&
      other.unreadOnly == unreadOnly &&
      _sameBoxes(other.mailboxes, mailboxes);

  @override
  int get hashCode =>
      Object.hash(Object.hashAllUnordered(mailboxes), folder, unreadOnly);

  /// 集合比较：**顺序不参与**。用户在面板里勾选的先后顺序不该让查询
  /// 变成另一个 family key（那会白白多一条 drift 订阅）。
  static bool _sameBoxes(List<MailboxFilter> a, List<MailboxFilter> b) {
    if (a.length != b.length) return false;
    for (final box in a) {
      if (!b.contains(box)) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'MailListQuery(boxes=${mailboxes.length}, ${folder.name}'
      '${unreadOnly ? ', unread' : ''})';
}

/// 邮件行的唯一标识（列表 `key` 与批量操作用）。
///
/// 直接复用 [MailRef] —— 聚合视图里 `emailId` 会跨实例重号，
/// 用裸 int 当 key 会让 Flutter 认错行。
extension MailRowRefX on ({String profileId, int emailId}) {
  MailRef get ref => MailRef(profileId: profileId, emailId: emailId);
}
