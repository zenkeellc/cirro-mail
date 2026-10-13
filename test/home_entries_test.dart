import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/features/home/home_entries.dart';
import 'package:mail_app/router.dart';

/// 主屏 7 个入口的落点。
///
/// 这里钉住两件在界面上看不出来的事：
/// 1. **「已发送」终于可达** —— 改动之前没有任何一处导航能打开 `folder=send`，
///    `MailFolder.send` 只在拼详情页地址时用到（见 spec §2.6）；
/// 2. 每个入口的「选中判据」互不重叠 —— 收件箱与未读邮件的路径相同、
///    只差一个 `unread=1`，判据写错会让两个入口同时高亮。
void main() {
  test('七个入口，顺序固定：置顶组在前，邮件组在后', () {
    expect(
      HomeEntries.all.map((e) => e.id).toList(),
      <String>[
        'starred',
        'attachmentCache',
        'unread',
        'inbox',
        'sent',
        'outbox',
        'drafts',
      ],
    );
  });

  /// `all` 必须是那两个组拼出来的，**不能另存一份顺序**。
  ///
  /// 这条是防「只改了一处」：`all` 与 `topActions` / `mailGroup` 一旦各说各的，
  /// 宽屏侧栏（按组渲染）与窄屏网格（按 `all` 渲染）会显示两个不同的顺序，
  /// 而两边都不会报错。
  test('all 就是 topActions + mailGroup 拼出来的', () {
    expect(
      HomeEntries.all.map((e) => e.id).toList(),
      <HomeEntry>[
        ...HomeEntries.topActions,
        ...HomeEntries.mailGroup,
      ].map((e) => e.id).toList(),
    );
    expect(HomeEntries.topActions.length, 2);
    expect(HomeEntries.mailGroup.length, 5);
  });

  test('收件箱 / 未读 / 已发送落在同一个列表路由上，靠 folder 与 unread 区分', () {
    expect(HomeEntries.unread.location, '/mail/all?folder=receive&unread=1');
    expect(HomeEntries.inbox.location, '/mail/all?folder=receive');
    expect(HomeEntries.sent.location, '/mail/all?folder=send');
  });

  test('未读入口带 unread=1，收件箱不带', () {
    expect(HomeEntries.unread.unreadOnly, isTrue);
    expect(HomeEntries.inbox.unreadOnly, isFalse);
    expect(HomeEntries.sent.unreadOnly, isFalse);
  });

  test('已发送仍旧落 receive 之外的那个 folder（它要开 includeSent）', () {
    expect(HomeEntries.sent.folder, MailFolder.send);
    expect(HomeEntries.inbox.folder, MailFolder.receive);
  });

  test('发件箱 / 草稿箱 / 附件缓存是邮件分支里的根路由，地址不带前缀', () {
    expect(HomeEntries.outbox.location, Routes.outbox);
    expect(HomeEntries.drafts.location, Routes.drafts);
    expect(HomeEntries.attachmentCache.location, Routes.attachmentCache);
  });

  test('选中判据：子路径也算（发件箱里点开一条，发件箱仍然高亮）', () {
    expect(HomeEntries.outbox.isSelectedBy(Uri.parse('/outbox')), isTrue);
    expect(HomeEntries.outbox.isSelectedBy(Uri.parse('/outbox/7')), isTrue);
    expect(HomeEntries.outbox.isSelectedBy(Uri.parse('/outbox?sel=7')), isTrue);
    expect(HomeEntries.drafts.isSelectedBy(Uri.parse('/drafts')), isTrue);
    expect(
      HomeEntries.attachmentCache
          .isSelectedBy(Uri.parse('/attachment-cache')),
      isTrue,
    );
    // 反过来：停在一项上不该把别项也点亮。
    expect(HomeEntries.outbox.isSelectedBy(Uri.parse('/drafts')), isFalse);
    expect(HomeEntries.drafts.isSelectedBy(Uri.parse('/outbox/7')), isFalse);
  });

  test('选中判据：前缀不能吞掉同前缀的别的路径', () {
    // `/mail/all` 不该把 `/mail/all2` 算成自己（少了那道斜杠就会）。
    expect(HomeEntries.inbox.isSelectedBy(Uri.parse('/mail/all2')), isFalse);
  });

  test('选中判据：收件箱在 ?folder=receive 上高亮，未读不在', () {
    final inbox = Uri.parse('/mail/all?folder=receive');
    final unread = Uri.parse('/mail/all?folder=receive&unread=1');
    expect(HomeEntries.inbox.isSelectedBy(inbox), isTrue);
    expect(HomeEntries.unread.isSelectedBy(inbox), isFalse);
    expect(HomeEntries.unread.isSelectedBy(unread), isTrue);
    expect(HomeEntries.inbox.isSelectedBy(unread), isFalse);
  });

  test('选中判据：没有任何 query 时算收件箱（默认落点）', () {
    expect(HomeEntries.inbox.isSelectedBy(Uri.parse('/mail/all')), isTrue);
    expect(HomeEntries.unread.isSelectedBy(Uri.parse('/mail/all')), isFalse);
    expect(HomeEntries.sent.isSelectedBy(Uri.parse('/mail/all')), isFalse);
  });

  test('选中判据：子路径也算（分栏时停在一封信里，收件箱仍然是当前入口）', () {
    expect(
      HomeEntries.inbox.isSelectedBy(Uri.parse('/mail/all?sel=7&profile=A')),
      isTrue,
    );
  });

  /// 详情页的地址形状（`detailRouteOf` 拼出来的）：**路径段是列表节点**
  /// （这里是聚合 `all`），这封信真正属于哪个实例走 `profile=`。
  ///
  /// 这一条以前不存在，于是「点开一封之后侧栏整列失去高亮」这个 bug 一直
  /// 没人挡住 —— 地址里写的是真实实例（`/mail/<p>/<e>`），而收件箱/未读/
  /// 已发送三个入口的落点都在 `/mail/all` 这一段上，按段比对自然对不上。
  test('选中判据：收件箱里点开一封，收件箱仍然高亮', () {
    expect(
      HomeEntries.inbox.isSelectedBy(Uri.parse('/mail/all/7?profile=p1')),
      isTrue,
    );
    expect(
      HomeEntries.unread.isSelectedBy(Uri.parse('/mail/all/7?profile=p1')),
      isFalse,
    );
    expect(
      HomeEntries.sent.isSelectedBy(Uri.parse('/mail/all/7?profile=p1')),
      isFalse,
    );
  });

  test('选中判据：已发送 / 未读里点开一封，各自仍然高亮（靠 folder / unread 分）', () {
    expect(
      HomeEntries.sent
          .isSelectedBy(Uri.parse('/mail/all/7?profile=p1&folder=send')),
      isTrue,
    );
    expect(
      HomeEntries.inbox
          .isSelectedBy(Uri.parse('/mail/all/7?profile=p1&folder=send')),
      isFalse,
    );
    expect(
      HomeEntries.unread
          .isSelectedBy(Uri.parse('/mail/all/7?profile=p1&unread=1')),
      isTrue,
    );
    // 未读里点开一封之后**不能**变成「收件箱亮着」—— 那正是 unread 必须
    // 跟着地址走的理由。
    expect(
      HomeEntries.inbox
          .isSelectedBy(Uri.parse('/mail/all/7?profile=p1&unread=1')),
      isFalse,
    );
  });

  test('选中判据：钉在某个实例上的列表点开一封，三个 folder 入口都不亮', () {
    // `/mail/<p>/<e>` 这个形状今天只剩「深链直接进」一种来路（侧栏一律
    // 走聚合节点），不为了它放宽按段比对 —— 见 `detailRouteOf` 的注释。
    expect(HomeEntries.inbox.isSelectedBy(Uri.parse('/mail/p1/7')), isFalse);
  });

  test('选中判据：星标与设置各自独立', () {
    expect(HomeEntries.starred.isSelectedBy(Uri.parse('/starred')), isTrue);
    expect(HomeEntries.starred.isSelectedBy(Uri.parse('/mail/all')), isFalse);
    expect(HomeEntries.inbox.isSelectedBy(Uri.parse('/starred')), isFalse);
  });

  test('入口携带的 l10n key 与文案表对得上', () {
    expect(HomeEntries.inbox.titleKey, 'inbox');
    expect(HomeEntries.sent.titleKey, 'sent');
    expect(HomeEntries.unread.titleKey, 'unreadMail');
  });

  /// **一级入口的地址里永远不许出现 `account`。**
  ///
  /// 「参数在不在 = 钉没钉在某个邮箱上」是这一轮加的判据（`pinnedMailboxOf`），
  /// 而「筛选按钮在不在」直接建在它上面。一级入口一旦带上 `account`，收件箱
  /// 自己就会被判成「某个邮箱的收件箱」—— 筛选按钮被藏掉、也不再看全局筛选，
  /// 而这是**它自己的入口**把功能弄坏的，最难想到去查。
  ///
  /// 连同 `Routes.mailAll`（聚合列表的根，主屏与冷启动都落在那儿）一起守。
  test('守卫：一级入口与聚合列表的地址里都不含 account', () {
    final origins = <String, String>{
      for (final entry in HomeEntries.all) entry.id: entry.location,
      'Routes.home': Routes.home,
      'Routes.mailAll': Routes.mailAll,
    };
    for (final item in origins.entries) {
      final uri = Uri.parse(item.value);
      expect(
        uri.queryParameters.containsKey(Routes.accountParam),
        isFalse,
        reason: '${item.key} 的落点不该带 ${Routes.accountParam}：${item.value}',
      );
      // 大写的 `?account=` 也不可能（Uri 的查询串是大小写敏感的）——
      // 用别的大小写绕过去的写法同样是错的。
      expect(item.value.contains('account'), isFalse, reason: item.key);
    }
  });
}
