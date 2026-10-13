import 'package:flutter/material.dart';

import '../../data/models/enums.dart';
import '../../l10n/app_localizations.dart';
import '../../router.dart';

/// 主屏的一个入口。
///
/// 窄屏的 icon 网格与宽屏的侧栏导航列**共用这一份定义**。分两份一定会走散：
/// 加了新入口只改一处，另一处那条就悄悄看不见了，而且没人会发现。
@immutable
class HomeEntry {
  const HomeEntry({
    required this.id,
    required this.icon,
    required this.selectedIcon,
    required this.titleKey,
    required this.location,
    this.folder = MailFolder.receive,
    this.unreadOnly = false,
  });

  /// 稳定标识（测试与 key 用），不是给用户看的。
  final String id;

  final IconData icon;
  final IconData selectedIcon;

  /// l10n 的 key（`AppLocalizations` 上的属性名），**不是文案本身**：
  /// 这个类没有 `BuildContext`，拿不到当前语言。
  final String titleKey;

  /// 点它去哪儿。
  final String location;

  final MailFolder folder;

  /// 只看未读（主屏「未读邮件」入口）。
  final bool unreadOnly;

  /// 当前地址是不是停在这个入口上。
  ///
  /// 三条判据缺一不可：
  /// 1. **路径**要落在这一项上 —— `/mail/all`、`/starred`、`/outbox` 各不同；
  /// 2. `folder` 要一致 —— 收件箱与已发送是同一个路径；
  /// 3. `unread` 要一致 —— 收件箱与未读是同一个路径**又**同一个 folder。
  ///
  /// 少了 3，用户在「未读邮件」里时「收件箱」也会高亮，两个入口同时亮着。
  bool isSelectedBy(Uri uri) {
    if (!_onPath(uri.path)) return false;
    if (folder != _folderOf(uri)) return false;
    return unreadOnly == _unreadOf(uri);
  }

  /// 路径判据：停在**这一项自己**上，或者停在它里面的子路径上。
  ///
  /// 子路径也算，是因为那些子路径就是从这一项 push 出去的：中屏（600–1023）
  /// 从收件箱点开一封是 `/mail/all/<emailId>`，从发件箱点开一条是
  /// `/outbox/<id>`，退出之后回到的正是这一项。只认完全相等的话，这两种
  /// 情况下侧栏会**整列都没有高亮**，看起来像「当前不在任何一处」。
  ///
  /// 前面的斜杠不能省：少了它 `/mail/all` 会把 `/mail/all2` 也吞进来。
  bool _onPath(String path) {
    final own = _pathOf(location);
    return path == own || path.startsWith('$own/');
  }

  static String _pathOf(String location) => Uri.parse(location).path;

  static MailFolder _folderOf(Uri uri) {
    final raw = uri.queryParameters['folder'];
    for (final folder in MailFolder.values) {
      if (folder.name == raw) return folder;
    }
    return MailFolder.receive;
  }

  static bool _unreadOf(Uri uri) {
    final raw = uri.queryParameters[Routes.unreadParam];
    return raw == '1' || raw == 'true';
  }
}

/// 主屏的入口表。
class HomeEntries {
  const HomeEntries._();

  /// 全部邮箱 / 全部实例合并的列表落点（主屏邮件组的根）。
  static String _list(MailFolder folder, {bool unread = false}) => Uri(
        path: '${Routes.mail}/${Routes.kAggregateNode}',
        queryParameters: <String, String>{
          'folder': folder.name,
          if (unread) Routes.unreadParam: '1',
        },
      ).toString();

  static final HomeEntry unread = HomeEntry(
    id: 'unread',
    icon: Icons.mark_email_unread_outlined,
    selectedIcon: Icons.mark_email_unread,
    titleKey: 'unreadMail',
    location: _list(MailFolder.receive, unread: true),
    unreadOnly: true,
  );

  static final HomeEntry inbox = HomeEntry(
    id: 'inbox',
    icon: Icons.inbox_outlined,
    selectedIcon: Icons.inbox,
    titleKey: 'inbox',
    location: _list(MailFolder.receive),
  );

  /// 已发送。**改动之前一个入口都没有** —— 从主屏进来之后，它是唯一能
  /// 打开 `folder=send` 的地方。
  static final HomeEntry sent = HomeEntry(
    id: 'sent',
    icon: Icons.send_outlined,
    selectedIcon: Icons.send,
    titleKey: 'sent',
    location: _list(MailFolder.send),
    folder: MailFolder.send,
  );

  static const HomeEntry outbox = HomeEntry(
    id: 'outbox',
    icon: Icons.outbox_outlined,
    selectedIcon: Icons.outbox,
    titleKey: 'outbox',
    location: Routes.outbox,
  );

  static const HomeEntry drafts = HomeEntry(
    id: 'drafts',
    icon: Icons.drafts_outlined,
    selectedIcon: Icons.drafts,
    titleKey: 'drafts',
    location: Routes.drafts,
  );

  static const HomeEntry starred = HomeEntry(
    id: 'starred',
    icon: Icons.star_border,
    selectedIcon: Icons.star,
    titleKey: 'starred',
    location: Routes.starred,
  );

  static const HomeEntry attachmentCache = HomeEntry(
    id: 'attachmentCache',
    icon: Icons.attach_file,
    selectedIcon: Icons.attach_file,
    titleKey: 'attachmentCache',
    location: Routes.attachmentCache,
  );

  /// **置顶的那一组**：星标 + 附件缓存。
  ///
  /// 星标原来埋在邮件组最后一位（第 6 项）。它是一个**常去**的地方，
  /// 而「未读 / 收件箱 / 已发送 / 发件箱 / 草稿箱」那五项的语义是「一封信
  /// 在哪个文件夹」，跟它不是一个维度 —— 把它们混在一列里，星标就得靠
  /// 用户自己记住在哪儿。
  static List<HomeEntry> get topActions => <HomeEntry>[starred, attachmentCache];

  /// **邮件组**：一封信的各条去向。
  ///
  /// 收件箱下面挂那棵邮箱子树（实例 + 邮箱下级菜单），所以这一组要
  /// 整体渲染（见 `AppShell._sidebar`）—— 组内插进来的不只是 `NavSidebarItem`。
  static List<HomeEntry> get mailGroup =>
      <HomeEntry>[unread, inbox, sent, outbox, drafts];

  /// 网格里的顺序 = 上面两组按顺序拼起来。**宽窄两形态都读它**。
  ///
  /// 两形态各存一份顺序一定会走散（见类注释），所以窄屏那张网格虽然
  /// 只认识一个扁平列表，也一律从 [all] 取 —— 想调顺序就调上面那两个组，
  /// 两处自动一起变。
  static List<HomeEntry> get all => <HomeEntry>[...topActions, ...mailGroup];
}

/// 入口的显示文案。
///
/// `HomeEntry` 只存 l10n 的 **key** —— 它没有 `BuildContext`，拿不到当前语言，
/// 所以取文案这件事必须由调用方带着 l10n 来做。
///
/// 收成这一个函数（而不是窄屏网格与宽屏侧栏各写一份 switch）：两处 switch
/// 一定会走散，而走散的表现是「侧栏有这一项、网格没有」这种安静的缺失。
String homeEntryLabel(HomeEntry entry, AppLocalizations l10n) =>
    switch (entry.titleKey) {
      'unreadMail' => l10n.unreadMail,
      'inbox' => l10n.inbox,
      'sent' => l10n.sent,
      'outbox' => l10n.outbox,
      'drafts' => l10n.drafts,
      'starred' => l10n.starred,
      'attachmentCache' => l10n.attachmentCache,
      // 不认识的 key 直接把它显示出来：新加一个入口却忘了在这里加分支时，
      // 界面上会明明白白地写一行 `myKey`，而不是安静地空白一片。
      _ => entry.titleKey,
    };
