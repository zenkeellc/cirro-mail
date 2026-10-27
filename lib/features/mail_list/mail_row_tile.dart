import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/instance_colors.dart';
import '../../core/util/time_utils.dart';
import '../../core/widgets/email_address_text.dart';
import '../../data/models/enums.dart';
import '../../data/models/mail_row.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/profile_providers.dart';
import '../../providers/sync_providers.dart';
import 'sender_avatar.dart';

/// 列表里的一行邮件。聚合、收件箱、已发送、星标四处共用。
///
/// 六个刻意的取舍：
/// - **左侧色带只在聚合视图显示**：单实例列表里每行都同色，全是噪声。
/// - **发件方向的未读用另一种样式**：`unread` 字段对 `type=1` 的行没有意义
///   （服务端只在收信时写它），照搬会显示出一堆假的未读。
/// - **未读行整行铺一层极淡的主题色**：只用字重（w600/w700）区分，在
///   「不看具体文字」的扫视里几乎读不出来；一整块底色能直接回答「这片
///   有几封没读」。它和选中底色是同一个色相、只差密度，所以选中那一档
///   跟着抬高了（见 [selected]）—— 否则「正开着」和「没读」看起来一样。
///   同一行的两种底色不做叠加：选中优先，未读在选中行上仍有字重与信封
///   两个出口。
/// - **`emailId` 不能当 key**：聚合视图里不同实例会重号，必须用
///   `profileId + emailId`（见 `MailRef`）。
/// - **选中竖条与实例色带共用最左那 3px**（见下面 [selected] 的注释）：
///   两个都画会让选中的那一行比上下两行宽 3px。
/// - **头像不表达已读**（见 [SenderAvatar]）：未读由标题行那个信封承担，
///   两者同时表达一件事的话，用户读不出哪个才是「权威」的那个。
class MailRowTile extends ConsumerWidget {
  const MailRowTile({
    super.key,
    required this.row,
    required this.onTap,
    this.onLongPress,
    this.showInstanceBand = false,
    this.selected = false,
    this.trailingTime = true,
    this.selectionMode = false,
    this.onCheckboxToggle,
  });

  final MailRow row;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 是否显示实例色带（聚合视图为 true）。
  final bool showInstanceBand;

  /// 分栏形态下这一行的邮件正开在右栏里。
  ///
  /// 两个提示，**强弱分工**：整行底色（淡）回答「这一片是选中区」，
  /// 最左那条 3px 竖条回答「具体是这一行」—— 只靠底色在几十行里认不出来，
  /// 因为相邻的未读/星标行本来就带各种浅色块（未读行现在真的铺了一层，
  /// 见 [MailRowTile] 的类注释）。
  ///
  /// 底色从 0.35 抬到 0.55，是给未读色（0.30）让出层次：两者同色相，
  /// 一档之差在列表里认不出来。
  ///
  /// 竖条**压过实例色带**（两者都要最左那一格）：同时画的话这一行会比
  /// 别的行宽 3px，整列的标题跟着往右挪一点 —— 选中/取消选中时列表会抖一下。
  /// 代价是选中那一行看不出实例色，但聚合视图里发件人下面那颗实例 chip
  /// 一直在，这条信息没丢。
  final bool selected;
  final bool trailingTime;

  /// 多选模式：左侧 40px 的头像位**换成复选框**。
  ///
  /// 换（而不是在旁边再加一个）的理由就是上面 [selected] 那段：这一行左边
  /// 的格子是**定宽**的，多塞一个控件会让整列文字一起往右挪。头像的直径
  /// （40）与复选框的命中区一样大，换过去正好严丝合缝。
  ///
  /// 只在**已经进入多选**时才是 true —— 没进入时连一个空槽都不留。多留一个
  /// 空槽的代价是：从「单栏列表」切到「可以多选」，所有标题会平移一次，
  /// 而用户并没做什么。
  final bool selectionMode;

  /// 复选框被点。null = 不画复选框（哪怕 [selectionMode] 是 true）——
  /// 发件箱 / 草稿箱那两处不接多选，它们连这一层都不该有。
  final VoidCallback? onCheckboxToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final profile = ref.watch(profileByIdProvider(row.profileId));
    final colorIndex = profile?.colorIndex ?? 0;
    final accent = InstanceColors.of(colorIndex);

    final unread = showsUnreadBadge(row);
    final subjectStyle = theme.textTheme.bodyLarge?.copyWith(
      fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
      color: theme.colorScheme.onSurface,
    );

    // 未读行的整行底色：主题容器的极淡一档（「较浅的主题色」）。
    //
    // 与选中底色**同一个色相**（`primaryContainer`），只靠透明度分强弱，
    // 所以两个数值是一对：未读 0.30 / 选中 0.55。选中原来是 0.35 —— 未读
    // 一旦也用这个色相，0.35 跟它只差一点密度，一列里就分不出「正开着」
    // 和「没读」，于是选中抬高了一档。
    //
    // 深色主题反而少给一点：同样的透明度叠在深色 surface 上，色块与背景的
    // 落差更大，0.30 会显得过重。
    final unreadSurface = theme.colorScheme.primaryContainer.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.22 : 0.30,
    );

    final sender = row.isSend
        ? (row.recipients.isEmpty
            ? row.toEmail
            : row.recipients.map((r) => r.display).join('、'))
        : row.displaySender;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        // 只给测试用的锚点：整行底色（选中态 / 未读态）在这一层，从外面找不到
        // 第二个同形状的 `Container`。命名规则与上面那条竖条的 key 一致。
        key: const ValueKey<String>('rowSurface'),
        // 选中优先于未读：两种底色叠加会混出第三种颜色，而「这一行正开着」
        // 必须比「这一行没读」更硬。未读在选中行上仍有字重与信封两个出口。
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
            : unread
                ? unreadSurface
                : null,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 最左那一格：选中的竖条优先，其次实例色带。
              // 宽度两种情况都是 3，行与行之间不会错位（见 [selected]）。
              if (selected)
                Container(
                  key: const ValueKey<String>('selectedBand'),
                  width: 3,
                  color: theme.colorScheme.primary,
                )
              else if (showInstanceBand)
                Container(width: 3, color: accent)
              else
                const SizedBox(width: 3),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      // 发件人的身份。字取显示名、色取**地址** —— 见
                      // [SenderAvatar.seed] 上那两条理由。
                      //
                      // 多选时这一格换成复选框（同一个 40px 宽的位置，见
                      // [selectionMode]）。
                      if (selectionMode && onCheckboxToggle != null)
                        _SelectionCheckbox(
                          checked: selected,
                          onTap: onCheckboxToggle!,
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: SenderAvatar(
                            label: sender.isEmpty ? l10n.unknown : sender,
                            seed: row.isSend
                                ? (row.sendEmail.isEmpty
                                    ? row.toEmail
                                    : row.sendEmail)
                                : row.sendEmail,
                          ),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                // 「正文还没同步」的灰点（需求三）。
                                //
                                // 以前它左边还有一个未读点；未读改由标题行那个
                                // 信封承担之后，这里只剩它一个点 —— 位置、
                                // 大小、`outlineVariant` 的淡色、以及那个
                                // tooltip 全部保持原样。一个灰点本身解释不了
                                // 自己是「还没下载」，所以 tooltip 不能省。
                                //
                                // 只对收件方向显示：发件行的正文是我们自己发出去的，
                                // 服务端对 `type=1` 的行不一定给 `content`，
                                // 拿它当「没同步完」会一直挂着灰点永远不消失。
                                if (row.type == MailType.receive && !row.hasFullBody)
                                  Tooltip(
                                    message: l10n.bodyNotSynced,
                                    child: Container(
                                      width: 6,
                                      height: 6,
                                      margin: const EdgeInsets.only(right: 6),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.outlineVariant,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                Expanded(
                                  // 发件人这一格有两种内容：显示名，或者退回
                                  // 原始地址（`MailRow.displaySender`）。地址
                                  // 那种情况下本地部分再重一档、`@域名` 留在
                                  // 基础字重上 —— 一列域名里要认出「谁」只看
                                  // 前半截。显示名不受影响（没有地址就没有
                                  // 加粗的片段）。
                                  //
                                  // `localWeight` 跟着未读走（没读的那一行
                                  // 再重 100）：未读/已读在发件人这一格上的
                                  // 落差原来靠整串 w600/w500，现在压在本地
                                  // 部分上，域名保持基础字重。
                                  child: EmailAddressText(
                                    sender.isEmpty ? l10n.unknown : sender,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: unread
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                    ),
                                    localWeight: unread
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                  ),
                                ),
                                if (row.isStarred)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: Icon(
                                      Icons.star,
                                      size: 14,
                                      color: theme.colorScheme.tertiary,
                                    ),
                                  ),
                                // 附件标记：回形针 + 数量。
                                //
                                // **`hasFullBody` 是那个必要的第二条件** ——
                                // 附件数来自列表查询的子查询，而摘要行的附件
                                // 还没同步回来，这时候 `attachmentCount == 0`
                                // 与「真的没有附件」分不开。假装知道会给出一
                                // 个会变（而且变得很显眼）的标记。
                                if (row.hasFullBody && row.attachmentCount > 0)
                                  _AttachmentBadge(
                                    count: row.attachmentCount,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                if (trailingTime)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: Text(
                                      TimeUtils.formatListTime(row.createTime),
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: <Widget>[
                                // 邮件的方向/已读状态。
                                //
                                // 三态而不是两态：**发件行没有未读语义**
                                // （服务端只在收信时写 `unread`），拿收件那套
                                // 去画会让所有发出去的信都显示成未读；所以它
                                // 恒用「拆开的信封」。收件行才在合/拆之间切。
                                //
                                // `drafts` 是这里唯一像「拆开的信封」的图标
                                // （打开的信纸）。`mail` 是合着的。
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Icon(
                                    unread ? Icons.mail : Icons.drafts,
                                    key: ValueKey<String>(
                                      unread ? 'unreadEnvelope' : 'readEnvelope',
                                    ),
                                    size: 14,
                                    color: unread
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                if (showInstanceBand) ...<Widget>[
                                  _InstanceChip(
                                    label: profile?.displayName ?? l10n.unknown,
                                    color: accent,
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Expanded(
                                  child: Text(
                                    row.displaySubject,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: subjectStyle,
                                  ),
                                ),
                              ],
                            ),
                            if (row.preview.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 2),
                              Text(
                                row.preview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            // 退信 / 投诉 / 延迟：这三种状态在列表里就要看见，
                            // 否则用户会以为信发出去了。
                            if (_warnOf(l10n) != null) ...<Widget>[
                              const SizedBox(height: 4),
                              _StatusChip(
                                text: _warnOf(l10n)!,
                                color: theme.colorScheme.error,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 只把「需要用户注意」的状态翻出来。`已发送`/`已送达` 是正常态，不占地方。
  String? _warnOf(AppLocalizations l10n) {
    if (!row.isSend) return null;
    return switch (row.status) {
      MailStatus.bounced => '退信',
      MailStatus.complained => '被投诉',
      MailStatus.delayed => '延迟',
      MailStatus.noRecipient => '无收件人',
      MailStatus.failed => '发送失败',
      MailStatus.saving => l10n.syncing,
      _ => null,
    };
  }
}

/// 附件标记：回形针 + 数量。
///
/// 为什么带数字：`MailRow.attachmentCount` 是本地已有的精确值，成本为零，
/// 而「1 个附件」和「5 个附件」对「要不要点进去」是不同量级的信息。
///
/// 数字用 `labelSmall` 而不是跟着图标放大：它比发件人的名字次要，
/// 压过标题就本末倒置了。
class _AttachmentBadge extends StatelessWidget {
  const _AttachmentBadge({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.attach_file, size: 14, color: color),
          const SizedBox(width: 1),
          Text(
            '$count',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// 聚合视图里的实例标签。
class _InstanceChip extends StatelessWidget {
  const _InstanceChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 多选时替掉头像的那一格。
///
/// **外框 40×40**，与 `SenderAvatar(diameter: 40)` 一分不差 —— 这是从
/// 「没有复选框」切到「有复选框」时整列文字不挪窝的唯一保证
/// （`test/mail_row_tile_test.dart` 那条宽度断言量的是同一件事）。
///
/// 勾选圈用 Material 的 `Checkbox` 而不是自己画：它带主题的选中色、以及
/// 各平台的勾选动效，自己画一个 20px 的圆会在深色主题下与旁边那颗
/// 「未读信封」的蓝色对不上。
class _SelectionCheckbox extends StatelessWidget {
  const _SelectionCheckbox({required this.checked, required this.onTap});

  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Center(
        // 手势只包住这个圈本身，不包满 40×40：外面那片留白点下去应该等于
        // 「点了这一行」（下面是 `InkWell`），而不是「勾掉这一行」。
        child: GestureDetector(
          key: const ValueKey<String>('selectionCheckbox'),
          onTap: onTap,
          // 圈内任何一点都算点它（`Checkbox` 自己的命中区比视觉的方框小）。
          behavior: HitTestBehavior.opaque,
          child: Checkbox(
            value: checked,
            onChanged: (_) => onTap(),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    );
  }
}
