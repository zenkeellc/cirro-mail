import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/router.dart';

/// 分栏形态的选中态。
///
/// 选中态用查询参数 `sel` 表达（而不是把详情压成路径），是整件事的地基：
/// 只改查询参数时 go_router 的 `pageKey`（取的是路由**模式串**）不变，
/// Navigator 原地更新那一页 —— 不 push、不转场，列表的 State 与滚动位置
/// 都保住。代价是「系统返回手势关不掉右栏」，由右栏自己的关闭按钮兜住。
///
/// 这里钉住的是**地址的拼法与解析**（纯字符串，可测）；「滚动位置真的
/// 保住了」只能在真机上看。
void main() {
  group('Routes.mailOf', () {
    test('没选中时不带 sel', () {
      expect(Routes.mailOf('p1'), '/mail/p1');
      expect(Routes.mailOf('p1', selectedEmailId: 0), '/mail/p1');
      expect(Routes.mailOf('p1', selectedEmailId: null), '/mail/p1');
    });

    test('选中时带上 sel，且与 account/folder 共存', () {
      expect(
        Routes.mailOf('p1', selectedEmailId: 7),
        '/mail/p1?sel=7',
      );
      expect(
        Routes.mailOf('p1',
            accountId: 3, folder: MailFolder.send, selectedEmailId: 7),
        '/mail/p1?account=3&folder=send&sel=7',
      );
    });

    /// `account` **写不写**就是「钉不钉住」这条标志本身（见 `pinnedMailboxOf`）。
    /// 所以判据是 `!= null` 而不是 `> 0` —— `0`（`kAllMailboxes`，缺
    /// `account:query` 权限那个实例的合并项）是一个正经的落点。
    ///
    /// 反过来更要紧：**一级入口（收件箱 / 未读 / 已发送）永远不传它**，
    /// 传了收件箱自己就会被判成「某个邮箱的收件箱」，筛选按钮当场被藏掉。
    test('accountId 非 null 就写出来，0 也算；null 就一个字都不写', () {
      expect(Routes.mailOf('p1', accountId: 0), '/mail/p1?account=0');
      expect(Routes.mailOf('p1', accountId: 3), '/mail/p1?account=3');
      expect(Routes.mailOf('p1', accountId: null), '/mail/p1');
      expect(Routes.mailOf('p1'), '/mail/p1');
    });

    /// 「只看未读」是**这张列表的另一个维度**，必须跟着地址走：收件箱与
    /// 未读邮件的路径段、folder 都相同，只有它能把两者分开。关掉右栏
    /// （`_clearSelection`）时少带它，用户就会被从「未读邮件」挪到「收件箱」。
    test('unreadOnly 写出 unread=1，且与 folder/sel 共存', () {
      expect(
        Routes.mailOf(Routes.kAggregateNode, unreadOnly: true),
        '/mail/all?unread=1',
      );
      expect(
        Routes.mailOf(Routes.kAggregateNode,
            folder: MailFolder.send, selectedEmailId: 7, unreadOnly: true),
        '/mail/all?folder=send&sel=7&unread=1',
      );
    });
  });

  /// `account` 的读写必须成对：写出规则（[Routes.mailOf]）说「null 不写、
  /// 0 也写」，读回规则（[Routes.parseAccountId]）就必须说「没写 → null、
  /// `'0'` → 0」。
  ///
  /// 这一条挡的是一个具体的 bug：详情折返那条路（`_paneRedirectForDetail`）
  /// 曾经用 `int.tryParse(...) ?? 0` 读它，于是**每次详情折返都开始写
  /// `?account=0`** —— 那条「参数在不在 = 钉不钉住」的标志当场变成垃圾，
  /// 筛选按钮开始时有时无。
  group('Routes.parseAccountId', () {
    test('没写 / 空 / 非数字 / 负数 → null（= 没钉住）', () {
      expect(Routes.parseAccountId(null), isNull);
      expect(Routes.parseAccountId(''), isNull);
      expect(Routes.parseAccountId('x'), isNull);
      expect(Routes.parseAccountId('-1'), isNull);
      // 小数也不是这一套编码里的值（`int.tryParse` 不收它）。
      expect(Routes.parseAccountId('1.5'), isNull);
    });

    test("'0' → 0（合法值，不是「没指名」）", () {
      expect(Routes.parseAccountId('0'), 0);
      expect(Routes.parseAccountId('7'), 7);
    });
  });

  group('paneSelectionOf', () {
    test('全部实例合并 / 星标必须连实例一起带（emailId 跨实例会重号）', () {
      final uri = Uri.parse(paneSelectionOf(
        root: Routes.mailAll,
        profileId: 'p1',
        emailId: 7,
      ));
      expect(uri.path, Routes.mailAll);
      expect(uri.queryParameters['sel'], '7');
      expect(uri.queryParameters['profile'], 'p1');
      // 默认值不写出来 —— 免得同一张列表出现两个「看着不一样其实一样」的地址。
      expect(uri.queryParameters.containsKey('folder'), isFalse);
      expect(uri.queryParameters.containsKey(Routes.unreadParam), isFalse);
    });

    /// 聚合列表在宽屏下也有右栏（`_paneRedirectForDetail` 折过来的就是这一
    /// 条），而 `/mail/all` 这一段上有三个入口 —— folder / unread 必须一起
    /// 折进来，否则未读里点开一封之后侧栏会跳成「收件箱」。
    test('folder / unread 跟到折返后的地址上（收件箱 / 未读 / 已发送各自站住）', () {
      final sent = Uri.parse(paneSelectionOf(
        root: Routes.mailAll,
        profileId: 'p1',
        emailId: 7,
        folder: MailFolder.send,
      ));
      expect(sent.queryParameters['folder'], 'send');

      final unread = Uri.parse(paneSelectionOf(
        root: Routes.mailAll,
        profileId: 'p1',
        emailId: 7,
        unreadOnly: true,
      ));
      expect(unread.queryParameters[Routes.unreadParam], '1');
    });

    /// 星标那一支**不带 folder**：星标入口的 `folder` 是默认的 `receive`，
    /// 地址里多一个 `folder=starred` 会让它自己反而失配（整列不亮）。
    test('调用方不传 folder 时地址里就没有 folder', () {
      final uri = Uri.parse(paneSelectionOf(
        root: Routes.starred,
        profileId: 'p1',
        emailId: 7,
      ));
      expect(uri.queryParameters.containsKey('folder'), isFalse);
    });
  });

  group('detailRouteOf', () {
    /// 列表里一条 → 详情：**路径段是列表节点，实例走 `profile=`**。
    /// 写反了的表现就是「点开一封之后侧栏整列没有高亮」。
    test('聚合列表里的收件箱：节点是 all，实例在 profile', () {
      expect(
        detailRouteOf(
          node: Routes.kAggregateNode,
          profileId: 'p1',
          emailId: 7,
          folder: MailFolder.receive,
        ),
        '/mail/all/7?profile=p1',
      );
    });

    test('已发送 / 未读各自带上 folder / unread', () {
      expect(
        detailRouteOf(
          node: Routes.kAggregateNode,
          profileId: 'p1',
          emailId: 7,
          folder: MailFolder.send,
        ),
        '/mail/all/7?profile=p1&folder=send',
      );
      expect(
        detailRouteOf(
          node: Routes.kAggregateNode,
          profileId: 'p1',
          emailId: 7,
          folder: MailFolder.receive,
          unreadOnly: true,
        ),
        '/mail/all/7?profile=p1&unread=1',
      );
    });

    /// 节点本身就是实例时，路径段已经说得清是哪一个，不必再写一遍。
    test('单实例列表：节点即实例，不再重复写 profile', () {
      expect(
        detailRouteOf(
          node: 'p1',
          profileId: 'p1',
          emailId: 7,
          folder: MailFolder.receive,
        ),
        '/mail/p1/7',
      );
    });

    test('星标是另一支：节点固定是 /starred，实例走 profile', () {
      expect(
        detailRouteOf(
          node: Routes.kAggregateNode,
          profileId: 'p1',
          emailId: 7,
          folder: MailFolder.starred,
        ),
        '/starred/7?profile=p1',
      );
    });

    /// 钉住某个邮箱时点开一封，**返回之后必须还在那个邮箱上**。
    ///
    /// 漏传的表现是最典型的 R2：返回列表时筛选按钮又冒出来、列表悄悄变宽，
    /// 而用户完全看不出是自己哪一步做错了。宽屏（关掉右栏走
    /// `_clearSelection`）与窄屏（返回走这条详情地址）两条路都要带上。
    test('accountId 跟着详情地址走；不传 / null 就一个字都不写', () {
      expect(
        detailRouteOf(
          node: 'p1',
          profileId: 'p1',
          emailId: 7,
          folder: MailFolder.receive,
          accountId: 5,
        ),
        '/mail/p1/7?account=5',
      );
      // 合并项（0）同样要能表达。
      expect(
        detailRouteOf(
          node: 'p1',
          profileId: 'p1',
          emailId: 7,
          folder: MailFolder.receive,
          accountId: 0,
        ),
        '/mail/p1/7?account=0',
      );
      expect(
        detailRouteOf(
          node: 'p1',
          profileId: 'p1',
          emailId: 7,
          folder: MailFolder.receive,
        ),
        '/mail/p1/7',
      );
      expect(
        detailRouteOf(
          node: 'p1',
          profileId: 'p1',
          emailId: 7,
          folder: MailFolder.receive,
          accountId: null,
        ),
        '/mail/p1/7',
      );
    });
  });

  group('paneSelectionOfRoute', () {
    test('窄屏恒为 null —— 选中态只属于分栏形态', () {
      expect(
        paneSelectionOfRoute(wide: false, profileId: 'p1', emailId: 7),
        isNull,
      );
    });

    test('宽屏下缺实例或邮号不合法都不给选中', () {
      expect(
        paneSelectionOfRoute(wide: true, profileId: 'p1', emailId: 0),
        isNull,
      );
      expect(
        paneSelectionOfRoute(wide: true, profileId: null, emailId: 7),
        isNull,
      );
      expect(
        paneSelectionOfRoute(wide: true, profileId: '', emailId: 7),
        isNull,
      );
    });

    test('宽屏 + 齐全才给出选中', () {
      final ref =
          paneSelectionOfRoute(wide: true, profileId: 'p1', emailId: 7);
      expect(ref, isNotNull);
      expect(ref!.profileId, 'p1');
      expect(ref.emailId, 7);
    });
  });
}
