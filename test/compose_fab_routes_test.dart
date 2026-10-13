import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/features/compose/compose_preselect.dart';
import 'package:mail_app/features/mail_list/mailbox_filter.dart';
import 'package:mail_app/features/shell/app_shell.dart' show showsComposeFab;
import 'package:mail_app/providers/profile_providers.dart' show kAllMailboxes;

/// 外壳那颗写邮件 FAB「从哪个邮箱发」的判据。
///
/// 这一组原来钉的是 `pageOwnsComposeFab`（「这一屏自己有没有 FAB」）——
/// 那个判据连同各页自带的 FAB 一起删掉了：外壳的 Scaffold 把 FAB 画在 body
/// 最上层，页面上再挂一颗只会被盖住。现在的问题从「谁挂」变成「那颗按钮
/// 该预选谁」，判据搬到了 [composePreselectOf]。
void main() {
  MailboxFilter box(String profileId, int accountId) =>
      MailboxFilter(profileId: profileId, accountId: accountId);

  /// 把一个「勾好的集合」做成勾选态。`saved` 为 null = 全选（没筛过）。
  MailboxSelection selectionOf(
    List<MailboxFilter> all, [
    List<MailboxFilter>? saved,
  ]) =>
      MailboxSelection.resolve(all, saved);

  group('这一屏说得出「从哪个邮箱发」吗', () {
    test('收件方向、非「只看未读」→ 说得出', () {
      expect(composePreselectCanSpeak(MailFolder.receive, false), isTrue);
    });

    test('已发送 / 星标 / 只看未读 → 说不出', () {
      expect(composePreselectCanSpeak(MailFolder.send, false), isFalse);
      expect(composePreselectCanSpeak(MailFolder.starred, false), isFalse);
      expect(composePreselectCanSpeak(MailFolder.receive, true), isFalse);
    });
  });

  group('/mail/all（没有钉死实例）', () {
    test('恰好勾了一个邮箱 → 带上它', () {
      final all = <MailboxFilter>[box('p1', 11), box('p1', 12), box('p2', 21)];
      final preselect = composePreselectOf(
        selection: selectionOf(all, <MailboxFilter>[box('p1', 12)]),
        profileId: null,
      );
      expect(preselect, const ComposePreselect(profileId: 'p1', accountId: 12));
    });

    test('勾了两个 → 说不清，落到当前实例的默认邮箱', () {
      final all = <MailboxFilter>[box('p1', 11), box('p1', 12)];
      expect(
        composePreselectOf(
          selection: selectionOf(all, <MailboxFilter>[
            box('p1', 11),
            box('p1', 12),
          ]),
          profileId: null,
        ),
        isNull,
      );
    });

    test('一个都没勾（全选 = 没筛过）→ 同样说不清', () {
      final all = <MailboxFilter>[box('p1', 11), box('p1', 12)];
      expect(
        composePreselectOf(selection: selectionOf(all), profileId: null),
        isNull,
      );
    });
  });

  group('/mail/<实例>（实例钉死了）', () {
    test('这一屏收窄到唯一一个具体邮箱 → 顺带带上它', () {
      final all = <MailboxFilter>[box('p1', 11), box('p1', 12), box('p2', 21)];
      final preselect = composePreselectOf(
        selection: selectionOf(all, <MailboxFilter>[box('p1', 11), box('p2', 21)]),
        profileId: 'p1',
      );
      expect(preselect, const ComposePreselect(profileId: 'p1', accountId: 11));
    });

    test('收到多个邮箱 → 只带实例，落到它自己的默认邮箱', () {
      final all = <MailboxFilter>[box('p1', 11), box('p1', 12)];
      final preselect = composePreselectOf(
        selection: selectionOf(all),
        profileId: 'p1',
      );
      expect(preselect, const ComposePreselect(profileId: 'p1', accountId: kAllMailboxes));
    });

    test('实例的合并项本身就是一个可勾的值 → 算一项', () {
      // 缺 `account:query` 权限的实例只有合并项可勾。它算「一项」，
      // 但它是合并项（0）—— 带上实例、不带具体邮箱。
      final all = <MailboxFilter>[box('p1', kAllMailboxes)];
      final preselect = composePreselectOf(
        selection: selectionOf(all),
        profileId: 'p1',
      );
      expect(preselect, const ComposePreselect(profileId: 'p1', accountId: kAllMailboxes));
    });
  });

  /// 左侧菜单下级菜单点进来的那一屏（地址里带 `account`）。
  ///
  /// 这一屏**完全不看 prefs**：`selection` 是跨实例的全局筛选，而这一刻用户
  /// 正盯着 a@x.com 的收件箱 —— 拿全局筛选去推，写信会从另一个邮箱发出去，
  /// 而且用户看不出是怎么回事（写邮件页上那颗发件人下拉里显示的就是那个错的）。
  group('钉在某个邮箱上（左侧菜单下级菜单）', () {
    test('钉住的邮箱压过 prefs 勾选', () {
      final all = <MailboxFilter>[box('p1', 11), box('p1', 12), box('p2', 21)];
      final preselect = composePreselectOf(
        // 此刻 prefs 里恰好只勾了 p1/11 —— 不看它，看钉住的那个。
        selection: selectionOf(all, <MailboxFilter>[box('p1', 11)]),
        profileId: 'p1',
        pinnedAccountId: 12,
      );
      expect(preselect, const ComposePreselect(profileId: 'p1', accountId: 12));
    });

    test('钉住的合并项（0）照样带出去', () {
      // 缺 `account:query` 权限的实例：下级菜单里那一行就是合并项。
      final all = <MailboxFilter>[box('p1', 11)];
      final preselect = composePreselectOf(
        selection: selectionOf(all),
        profileId: 'p1',
        pinnedAccountId: kAllMailboxes,
      );
      expect(
        preselect,
        const ComposePreselect(profileId: 'p1', accountId: kAllMailboxes),
      );
    });

    test('没有实例时钉住参数不起作用，退回原来的判据', () {
      // `pinnedMailboxOf` 对 `/mail/all?account=` 给 null，所以这一组参数
      // 组合**产生不出来**；真被谁传进来了也不能凭空造出一个实例来 ——
      // 这里退回「恰好勾了一个就带它」那条既有规则。
      final all = <MailboxFilter>[box('p1', 11)];
      expect(
        composePreselectOf(
          selection: selectionOf(all, <MailboxFilter>[box('p1', 11)]),
          profileId: null,
          pinnedAccountId: 11,
        ),
        const ComposePreselect(profileId: 'p1', accountId: 11),
      );
    });
  });

  group('发布 / 收回（owner 语义）', () {
    test('后说话的那个留下，先说话的不许把后来者抹掉', () {
      // 切分支那一帧：旧屏清空、新屏发布，两个 post-frame 回调谁先跑
      // 由 build 顺序决定 —— 顺序无关紧要才是对的。
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(composePreselectProvider.notifier);
      final oldOwner = Object();
      final newOwner = Object();

      notifier.publish(oldOwner, const ComposePreselect(profileId: 'p1', accountId: 1));
      notifier.publish(newOwner, const ComposePreselect(profileId: 'p2', accountId: 2));
      // 旧屏的回调此时才跑：不能把新屏的结论抹掉。
      notifier.clear(oldOwner);
      expect(
        container.read(composePreselectProvider),
        const ComposePreselect(profileId: 'p2', accountId: 2),
      );

      notifier.clear(newOwner);
      expect(container.read(composePreselectProvider), isNull);
    });
  });

  group('这一屏有没有那颗写邮件浮动按钮', () {
    test('列表 / 主屏 / 星标 / 本机页面 —— 两种宽度都有', () {
      for (final uri in <Uri>[
        Uri.parse('/mail/all'),
        Uri.parse('/mail/all?folder=send'),
        Uri.parse('/mail/p1'),
        Uri.parse('/starred'),
        Uri.parse('/home'),
        Uri.parse('/outbox'),
        Uri.parse('/drafts'),
        Uri.parse('/attachment-cache'),
      ]) {
        expect(showsComposeFab(uri, compact: true), isTrue, reason: '窄 $uri');
        expect(showsComposeFab(uri, compact: false), isTrue, reason: '宽 $uri');
      }
    });

    test('设置那一支 —— 两种宽度都没有，子页一并跟上', () {
      // 这一支是写邮件按钮最多余的地方：页面右边整片留白，按钮浮在上面像
      // 放错了位置；宽屏下侧栏顶部那颗一模一样的图标就在旁边。
      for (final uri in <Uri>[
        Uri.parse('/settings'),
        Uri.parse('/settings/diagnostics'),
        Uri.parse('/settings/push'),
        Uri.parse('/settings/add-instance'),
        Uri.parse('/settings/ai'),
      ]) {
        expect(showsComposeFab(uri, compact: true), isFalse, reason: '窄 $uri');
        expect(showsComposeFab(uri, compact: false), isFalse, reason: '宽 $uri');
      }
    });

    test('一封信的详情页 —— 只有宽屏收起来（窄屏它一直就在那儿）', () {
      // 宽屏收：右栏是阅读区，按钮正压在正文右下角。窄屏那不归按钮管 ——
      // 窄屏在详情页收起的是**底部导航**（同一份详情判据，见 `isDetailRoute`）。
      for (final uri in <Uri>[
        Uri.parse('/mail/p1/42'),
        Uri.parse('/mail/all/42'),
        Uri.parse('/starred/42'),
        Uri.parse('/outbox/7'),
      ]) {
        expect(showsComposeFab(uri, compact: false), isFalse, reason: '宽 $uri');
        expect(showsComposeFab(uri, compact: true), isTrue, reason: '窄 $uri');
      }
    });

    test('前缀不能吞掉同前缀的别的路径', () {
      // `/settings` 那一支的例外不该把 `/settingsFoo` 也算进去。
      expect(showsComposeFab(Uri.parse('/settingsFoo'), compact: false), isTrue);
      // 反过来说：`/mail/p1/42` 是详情，但 `/mail/p1` 不是。
      expect(showsComposeFab(Uri.parse('/mail/p1'), compact: false), isTrue);
      // `/mail/p1/42` 之后的更深一段不是「一封信」，判据不该一路走下去。
      expect(
        showsComposeFab(Uri.parse('/mail/p1/42/attachment'), compact: false),
        isTrue,
      );
    });
  });
}
