import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/home/home_entries.dart';
import 'package:mail_app/features/home/home_nav.dart';

/// 点一个主屏入口之后该做什么。
///
/// 这一组钉的全是**在界面上很难发现**的错法：
/// 点进去出不来（用 `go` 进了窄屏那几个页面）、叠出第二个列表页
/// （已经在那一项上还 `push`）、把别的分支的页面叠在邮件这一支上
/// （星标用 `push`）。
void main() {
  HomeNav nav(HomeEntry entry, String location, {required bool push}) =>
      homeNavFor(entry, Uri.parse(location), push: push);

  group('窄屏（push）', () {
    test('从主屏点别项 = 压一层，返回箭头才有得回', () {
      expect(nav(HomeEntries.drafts, '/home', push: true), HomeNav.push);
      expect(nav(HomeEntries.outbox, '/home', push: true), HomeNav.push);
      expect(
        nav(HomeEntries.inbox, '/home', push: true),
        HomeNav.push,
      );
    });

    test('星标无论哪种形态都只能 go（它是别的分支）', () {
      expect(nav(HomeEntries.starred, '/home', push: true), HomeNav.go);
      expect(nav(HomeEntries.starred, '/home', push: false), HomeNav.go);
    });
  });

  group('宽屏侧栏（go）', () {
    test('点别项 = 换掉这一支的栈', () {
      expect(nav(HomeEntries.drafts, '/home', push: false), HomeNav.go);
      expect(nav(HomeEntries.inbox, '/home', push: false), HomeNav.go);
    });
  });

  group('点当前项', () {
    test('已经在根上：什么都不做', () {
      expect(nav(HomeEntries.outbox, '/outbox', push: true), HomeNav.none);
      expect(nav(HomeEntries.inbox, '/mail/all', push: true), HomeNav.none);
      expect(
        nav(HomeEntries.inbox, '/mail/all?folder=receive', push: false),
        HomeNav.none,
      );
    });

    test('停在子路径上（详情页）：退回列表那一层', () {
      expect(nav(HomeEntries.outbox, '/outbox/7', push: true), HomeNav.backToRoot);
      expect(
        nav(HomeEntries.inbox, '/mail/all/7', push: true),
        HomeNav.backToRoot,
      );
    });

    test('查询参数不算子路径（?sel= 时仍然什么都不做）', () {
      // 宽屏选中一封信走 `?sel=`，地址的 path 没变 —— 那不是「沉进详情」，
      // 点侧栏同一项不该有任何动作。
      expect(
        nav(HomeEntries.outbox, '/outbox?sel=7', push: false),
        HomeNav.none,
      );
    });

    test('收件箱与未读是两个入口，互不吞并', () {
      // 同一个 path、只差 unread=1：在未读里点收件箱要**真的换过去**
      // （isSelectedBy 只认自己那一个），而不是被判成「已经在上面了」。
      expect(
        nav(HomeEntries.inbox, '/mail/all?folder=receive&unread=1', push: false),
        HomeNav.go,
      );
      expect(
        nav(HomeEntries.unread, '/mail/all?folder=receive&unread=1',
            push: false),
        HomeNav.none,
      );
    });
  });

  /// 侧栏/主屏里的**实例行**是另一个落点（`/mail/<实例>`，不带 `account`），
  /// 它不属于那七个一级入口，所以有自己的判据。
  group('instanceNavFor', () {
    HomeNav node(String location, {required bool push, String id = 'p1'}) =>
        instanceNavFor(Uri.parse(location), profileId: id, push: push);

    test('从别处点 = 压一层（窄屏）/ 换这一支的栈（宽屏）', () {
      expect(node('/starred', push: true), HomeNav.push);
      expect(node('/starred', push: false), HomeNav.go);
      // 别的实例上的列表也算「别处」：点 p1 就是换到 p1。
      expect(node('/mail/p2', push: false, id: 'p1'), HomeNav.go);
      expect(node('/mail/p2', push: true, id: 'p1'), HomeNav.push);
    });

    test('已经在根上：什么都不做', () {
      expect(node('/mail/p1', push: true), HomeNav.none);
      expect(node('/mail/p1', push: false), HomeNav.none);
      // 别的查询参数不算子路径（与 `homeNavFor` 同一条：`?sel=` 只是
      // 宽屏右栏开着，path 没变）。
      expect(node('/mail/p1?sel=7', push: true), HomeNav.none);
    });

    test('停在详情页：退回这一屏的列表', () {
      expect(node('/mail/p1/7', push: true), HomeNav.backToRoot);
      expect(node('/mail/p1/7?sel=7', push: false), HomeNav.backToRoot);
    });

    /// 钉在**某个邮箱**上（`?account=`）不算「就在这台实例上」——
    /// 那是子行那一件事，点实例行应当**换**过去（`?account` 被丢掉）。
    test('钉在某个邮箱上时，点实例行是真的换过去', () {
      expect(node('/mail/p1?account=2', push: false), HomeNav.go);
      expect(node('/mail/p1?account=2', push: true), HomeNav.push);
    });
  });
}
