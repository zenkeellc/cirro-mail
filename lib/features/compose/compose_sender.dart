import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/instance_capabilities.dart';
import '../../data/models/mailbox_account.dart';
import '../../data/models/profile.dart';
import '../../providers/mail_providers.dart';
import '../../providers/profile_providers.dart';

/// 「用**哪台实例**的**哪个邮箱**发信」。
///
/// 这两件事必须焊在一个值里，理由是 `MailboxAccount.accountId` **只在实例内
/// 有意义** —— 它是 worker 里 `account` 表的自增主键，实例 A 的 `#3` 与实例 B
/// 的 `#3` 是两个毫不相干的邮箱。而 `/email/send` 是这样校验发件人的
/// （`mail-worker/src/service/email-service.js` 的 `send`）：
///
/// ```js
/// const accountRow = await accountService.selectById(c, accountId);
/// if (!accountRow) throw new BizError(t('senderAccountNotExist'));
/// if (accountRow.userId !== userId) throw new BizError(t('sendEmailNotCurUser'));
/// ```
///
/// 拆成两个字段（一个 `accountId`、一个 `profileId`）就会出现「发件人属于 A、
/// 发信走 B」这种组合，而那一定命中上面两条错误之一。焊在一起，这种组合
/// 在类型上就构造不出来。
@immutable
class SenderOption {
  const SenderOption({required this.profile, required this.mailbox});

  /// 走哪台实例。
  final Profile profile;

  /// 用哪个邮箱（`account.accountId` 只有配上 [profile] 才有意义）。
  final MailboxAccount mailbox;

  String get profileId => profile.id;

  String get email => mailbox.email;

  String get name => mailbox.name;

  /// 一行字的形状：有名字时 `名字 <地址>`，没有就是裸地址。
  String get label => name.isEmpty ? email : '$name <$email>';

  /// 实例显示名（面板里的组头、触发行下面那行小字）。
  String get profileName => profile.displayName;

  @override
  bool operator ==(Object other) =>
      other is SenderOption &&
      other.profile.id == profile.id &&
      other.mailbox.accountId == mailbox.accountId &&
      other.mailbox.email == mailbox.email;

  /// **不把 `Profile` 整个算进来**：它是一个会变的行（改名、换 `ossBase`、
  /// 被标 `needsLogin` 都会写库），拿它当身份会让「刚选好的发件人在一次同步
  /// 之后被判成换了一个」—— 于是选中项莫名其妙跳回第一个。
  @override
  int get hashCode => Object.hash(profile.id, mailbox.accountId, mailbox.email);

  @override
  String toString() =>
      'SenderOption(${profile.id}, #${mailbox.accountId}, $email)';
}

/// 面板里的一组：一台实例 + 它的可选邮箱。
@immutable
class SenderGroup {
  const SenderGroup({required this.profile, required this.mailboxes});

  final Profile profile;
  final List<MailboxAccount> mailboxes;

  List<SenderOption> get options => mailboxes
      .map((m) => SenderOption(profile: profile, mailbox: m))
      .toList(growable: false);

  @override
  String toString() => 'SenderGroup(${profile.id}, ${mailboxes.length})';
}

/// 发件人候选：**跨实例**，按实例分组。
///
/// 三处刻意的选择：
///
/// 1. **用 `activeProfilesProvider`**（已登录且没被标 `needsLogin`）：一台需要
///    重登的实例，token 已经废了，列它的邮箱只会给用户一个「选了也发不出去」
///    的选项。写邮件设置页（`compose_section.dart`）那类**管理**界面口径更宽
///    （`profilesProvider`，连没登录的都列），因为它看的是**本地已有的数据**；
///    这里要的是「现在能不能用这个身份发信」。
/// 2. **过滤 `caps.sendEnabled`**：站点关掉发信、或该账号没有 `email:send`
///    权限的实例整组不出现。`unknown`（还没探测）按可用处理 —— 与
///    `canSendProvider` 同一条约定（冷启动就把入口藏起来，用户会以为功能
///    没了）。
/// 3. **复用 [senderCandidates]**：它已经把「拿不到真 `accountId` 的邮箱」
///    挡掉了（降级兜底造出来的那个 id 是 0，发不出去）。这条判据只有一处
///    出处，不在这里重写一遍 —— 两份判据迟早会分叉。
///
/// **组的顺序 = `activeProfilesProvider` 的顺序**，也就是按 `sort` 排过的
/// 实例顺序；组内沿用 `mailboxesProvider` 的顺序。调用方（`_initialSender` /
/// `_entryGroup` / 面板）依赖这一点，别在这里重排。
final composeSendersProvider = Provider<List<SenderGroup>>(
  (ref) {
    final groups = <SenderGroup>[];
    for (final profile in ref.watch(activeProfilesProvider)) {
      final caps = ref.watch(capabilitiesProvider(profile.id)).value ??
          const InstanceCapabilities();
      if (!caps.sendEnabled) continue;

      final boxes = ref.watch(mailboxesProvider(profile.id)).value ??
          const <MailboxAccount>[];
      final candidates = senderCandidates(boxes, profile);
      if (candidates.isEmpty) continue;
      groups.add(SenderGroup(profile: profile, mailboxes: candidates));
    }
    return groups;
  },
  name: 'composeSenders',
);
