import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/mail_list/mailbox_scope.dart';

/// 「这一屏是不是钉在某个邮箱上」的判据。
///
/// 这条判断错了的表现全部是**安静**的：「筛选按钮时有时无」「侧栏高亮跑偏」
/// 「关掉右栏之后列表悄悄变宽」—— 没有一条会报错，也没有一条能在界面上
/// 一眼看出来。所以它必须由纯函数测钉住。
///
/// 判据是两条：**路径的节点是一个实例**（`/mail/all` 不算），**且查询串里
/// 出现 `account`**（值是什么无关 —— `0` 也是一个正经的落点）。
void main() {
  group('pinnedMailboxOf', () {
    test('没有 account 参数 → 没钉住', () {
      expect(pinnedMailboxOf(Uri.parse('/mail/p1')), isNull);
      expect(pinnedMailboxOf(Uri.parse('/mail/p1?folder=receive')), isNull);
      expect(pinnedMailboxOf(Uri.parse('/mail/p1?sel=7')), isNull);
      expect(pinnedMailboxOf(Uri.parse('/mail/all')), isNull);
    });

    test('account=0 是**一个正经的落点**，不是「没指名」', () {
      // 0 = kAllMailboxes = 缺 `account:query` 权限那个实例的合并项。
      // 把它当成 null 处理，那台实例的下级菜单点了就没反应。
      expect(
        pinnedMailboxOf(Uri.parse('/mail/p1?account=0')),
        (profileId: 'p1', accountId: 0),
      );
    });

    test('具体的邮箱 → 钉住', () {
      expect(
        pinnedMailboxOf(Uri.parse('/mail/p1?account=2')),
        (profileId: 'p1', accountId: 2),
      );
    });

    test('详情页也认（`/mail/<实例>/<emailId>?account=`）', () {
      // 窄屏从下级菜单点开一封，返回时得回到那个邮箱 —— 详情地址上必须
      // 留着这个标志，判据也得认它。
      expect(
        pinnedMailboxOf(Uri.parse('/mail/p1/7?account=2')),
        (profileId: 'p1', accountId: 2),
      );
      expect(
        pinnedMailboxOf(Uri.parse('/mail/p1/7?account=2&folder=send')),
        (profileId: 'p1', accountId: 2),
      );
    });

    test('聚合节点上的 account 不算 —— 那儿本来就是模糊的', () {
      // `/mail/all` 是收件箱 / 未读 / 已发送三个一级入口共用的路径段，
      // 认它会让三个入口全体沦陷。
      expect(pinnedMailboxOf(Uri.parse('/mail/all?account=2')), isNull);
      expect(pinnedMailboxOf(Uri.parse('/mail/all/7?account=2')), isNull);
    });

    test('值不合法（空 / 非数字 / 负数）→ 不算钉住', () {
      // 与 `Routes.parseAccountId` 同口径：写不出这种地址，但手改 / 旧版本
      // 留下的坏地址不该让页面进入一个说不清的形态。
      expect(pinnedMailboxOf(Uri.parse('/mail/p1?account=')), isNull);
      expect(pinnedMailboxOf(Uri.parse('/mail/p1?account=x')), isNull);
      expect(pinnedMailboxOf(Uri.parse('/mail/p1?account=-1')), isNull);
    });

    test('别的路径一律不算（星标 / 设置 / 发件箱 / 主屏）', () {
      for (final path in <String>[
        '/starred',
        '/starred/7',
        '/settings',
        '/outbox',
        '/drafts',
        '/attachment-cache',
        '/home',
        // 再深一段就不是「一封信」了（与 `isDetailRoute` 同一条边界）。
        '/mail/p1/7/attachment',
      ]) {
        expect(
          pinnedMailboxOf(Uri.parse('$path?account=2')),
          isNull,
          reason: path,
        );
      }
    });
  });

  /// [instanceNodeOf] 与 [pinnedMailboxOf] 是**成对**的两条判据：路径形状
  /// 完全一样，唯一的分岔是「查询串里有没有 `account`」。所以下面这一组
  /// 是上面那一组**镜像着**写的 —— 同一组地址，把 `account` 拿掉之后（或者
  /// 说不该有 `account` 的那些），结论应该恰好反过来。两条一起错的表现是
  /// 「侧栏点一下亮错行」，而它不会报错。
  group('instanceNodeOf', () {
    test('实例级列表（不带 account）→ 命中', () {
      expect(instanceNodeOf(Uri.parse('/mail/p1')), 'p1');
      // 别的查询参数不影响：认的是「没有 account」，不是「没有查询串」。
      expect(instanceNodeOf(Uri.parse('/mail/p1?folder=send')), 'p1');
      expect(instanceNodeOf(Uri.parse('/mail/p1?unread=1')), 'p1');
      expect(instanceNodeOf(Uri.parse('/mail/p1?sel=7')), 'p1');
    });

    test('实例的详情页也认', () {
      expect(instanceNodeOf(Uri.parse('/mail/p1/7')), 'p1');
      expect(instanceNodeOf(Uri.parse('/mail/p1/7?folder=send')), 'p1');
    });

    test('带 account 一律不认 —— 那是「钉在某个邮箱上」，归另一条判据管', () {
      // 这一条就是两条判据的分岔本身。`account=0` 也不例外：合并项也是
      // 一个**具体的落点**，它落在邮箱子树上而不是实例行上。
      expect(instanceNodeOf(Uri.parse('/mail/p1?account=0')), isNull);
      expect(instanceNodeOf(Uri.parse('/mail/p1?account=2')), isNull);
      expect(instanceNodeOf(Uri.parse('/mail/p1/7?account=2')), isNull);
      // 坏值也一样不认：它连「钉住」都不是，更不是实例级。
      expect(instanceNodeOf(Uri.parse('/mail/p1?account=')), isNull);
      expect(instanceNodeOf(Uri.parse('/mail/p1?account=x')), isNull);
    });

    test('聚合节点（`all`）不是实例', () {
      // `/mail/all` 是收件箱 / 未读 / 已发送三个一级入口共用的路径段，
      // 认它会让三条一级入口同时被当成「某台实例」。
      expect(instanceNodeOf(Uri.parse('/mail/all')), isNull);
      expect(instanceNodeOf(Uri.parse('/mail/all?folder=send')), isNull);
      expect(instanceNodeOf(Uri.parse('/mail/all/7')), isNull);
    });

    test('别的路径一律不算（星标 / 设置 / 发件箱 / 主屏）', () {
      for (final path in <String>[
        '/starred',
        '/starred/7',
        '/settings',
        '/settings/diagnostics',
        '/outbox',
        '/drafts',
        '/attachment-cache',
        '/home',
        // 再深一段就不是「一封信」了（与 `isDetailRoute` 同一条边界）。
        '/mail/p1/7/attachment',
      ]) {
        expect(instanceNodeOf(Uri.parse(path)), isNull, reason: path);
      }
    });

    test('与 pinnedMailboxOf 互斥：同一条地址不会两边都命中', () {
      for (final path in <String>[
        '/mail/p1',
        '/mail/p1?account=2',
        '/mail/p1/7',
        '/mail/p1/7?account=0',
      ]) {
        final uri = Uri.parse(path);
        expect(
          pinnedMailboxOf(uri) != null && instanceNodeOf(uri) != null,
          isFalse,
          reason: path,
        );
      }
    });
  });
}
