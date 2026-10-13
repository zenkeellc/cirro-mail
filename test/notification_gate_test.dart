import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/notifications/notification_service.dart';

/// 「哪些邮件真的该弹通知」是一条**有状态的判断**（每个实例一条基线），
/// 也是这个功能里唯一容易悄悄做错的地方：
///
/// - 新装 App / 新加一个实例 → 不能把已有的几百封当成新的全弹一遍；
/// - 重扫历史（服务端补发、空洞重扫）→ 同样不能重弹；
/// - 但基线之后真正新到的，一封都不能漏。
///
/// 这三条互相拉扯，光靠肉眼看代码很容易写反，所以逐条钉住。
void main() {
  group('通知闸门', () {
    test('第一次见到实例只建基线，不弹', () {
      final gate = NotificationGate();
      expect(
        gate.select('A', <MailRow>[_row(1), _row(2), _row(3)]),
        isEmpty,
        reason: '新装 App 的那一刻不该被历史邮件糊满屏幕',
      );
    });

    test('基线之后新到的才弹', () {
      final gate = NotificationGate();
      gate.select('A', <MailRow>[_row(10)]); // 建基线
      final fresh = gate.select('A', <MailRow>[_row(11), _row(12)]);

      expect(fresh.map((r) => r.emailId), <int>[11, 12]);
    });

    test('重扫历史不会重弹（基线以下的都过滤掉）', () {
      final gate = NotificationGate();
      gate.select('A', <MailRow>[_row(10), _row(11)]);
      // 一轮里混着旧邮件：11 已经在基线内，只有 12 是新的。
      final fresh = gate.select('A', <MailRow>[_row(9), _row(10), _row(12)]);

      expect(fresh.map((r) => r.emailId), <int>[12]);
    });

    test('基线不会被旧的一批拉回去', () {
      final gate = NotificationGate();
      gate.select('A', <MailRow>[_row(20)]);
      // 一批全是旧的（低于基线）—— 基线该停在 20，不能退到 5。
      expect(gate.select('A', <MailRow>[_row(3), _row(5)]), isEmpty);
      // 因此 6 仍然算旧的。若基线被拉回 5，这里会错误地弹出来。
      expect(gate.select('A', <MailRow>[_row(6)]), isEmpty);
      expect(gate.select('A', <MailRow>[_row(21)]).single.emailId, 21);
    });

    test('发件方向的邮件不弹（给自己发的信）', () {
      final gate = NotificationGate();
      gate.select('A', <MailRow>[_row(1)]);
      final fresh = gate.select('A', <MailRow>[
        _row(2, type: MailType.send),
        _row(3),
      ]);

      expect(fresh.map((r) => r.emailId), <int>[3]);
    });

    test('已读的邮件不弹', () {
      final gate = NotificationGate();
      gate.select('A', <MailRow>[_row(1)]);
      final fresh = gate.select('A', <MailRow>[
        _row(2, unread: UnreadState.read),
        _row(3),
      ]);

      expect(fresh.map((r) => r.emailId), <int>[3]);
    });

    test('一批全是已读时，基线照样推进', () {
      // 否则：用户在别处读完一批信，App 这边基线没动，之后再来一封会比
      // 旧基线大、看起来正常 —— 但如果那批已读信被反复重扫，就会一直被
      // 当成候选重新计算。基线要跟住「已经见过的最新 id」这个事实。
      final gate = NotificationGate();
      gate.select('A', <MailRow>[_row(1)]);
      expect(gate.select('A', <MailRow>[_row(9, unread: UnreadState.read)]),
          isEmpty);
      // 基线已到 9：比 9 小的不再弹，比 9 大的才弹。
      expect(gate.select('A', <MailRow>[_row(5)]), isEmpty);
      expect(gate.select('A', <MailRow>[_row(10)]).single.emailId, 10);
    });

    test('两个实例各有一条基线，互不干扰', () {
      final gate = NotificationGate();
      gate.select('A', <MailRow>[_row(100)]);
      gate.select('B', <MailRow>[_row(1)]); // B 第一次见，只建基线

      // B 的 2 是新的（别被 A 的 100 影响）；A 的 101 也是新的。
      expect(gate.select('B', <MailRow>[_row(2)]).single.emailId, 2);
      expect(gate.select('A', <MailRow>[_row(101)]).single.emailId, 101);
    });
  });

  group('通知闸门（delta：后台任务那条路）', () {
    // 后台每一轮唤醒都是**一个全新的进程**（`_baseline` 是内存里的，
    // 必然是空的），所以「首轮只建基线」那条不能套在这里用 ——
    // 套了的结果是每一轮都静默地什么都不弹，而日志里干干净净。
    test('全新进程里的第一批增量就该弹（不能当首轮吃掉）', () {
      final gate = NotificationGate();
      final fresh = gate.select('A', <MailRow>[_row(11), _row(12)], delta: true);

      expect(fresh.map((r) => r.emailId), <int>[11, 12]);
    });

    test('同一批再来一次不重弹（换成打基线，而不是打「首轮」）', () {
      final gate = NotificationGate();
      expect(gate.select('A', <MailRow>[_row(11)], delta: true), hasLength(1));
      // 服务端补发 / 重试导致同一批又回来了。
      expect(gate.select('A', <MailRow>[_row(11)], delta: true), isEmpty);
      expect(gate.select('A', <MailRow>[_row(12)], delta: true), hasLength(1));
    });

    test('delta 下仍然只弹未读的收件', () {
      final gate = NotificationGate();
      final fresh = gate.select(
        'A',
        <MailRow>[
          _row(1),
          _row(2, unread: UnreadState.read),
          _row(3, type: MailType.send),
        ],
        delta: true,
      );

      expect(fresh.map((r) => r.emailId), <int>[1]);
    });
  });

  group('通知 payload', () {
    test('编解码往返', () {
      final ref = NotificationService.decodePayload(
        NotificationService.encodePayload('p-1', 42),
      );
      expect(ref, const MailRef(profileId: 'p-1', emailId: 42));
    });

    test('畸形输入一律返回 null，不抛', () {
      // 这个串是系统在进程重建后原样交回来的，什么形状都可能有。
      for (final bad in <String?>[null, '', '|', 'abc', 'abc|', 'abc|0',
        'abc|-1', 'abc|xyz']) {
        expect(NotificationService.decodePayload(bad), isNull, reason: '$bad');
      }
    });

    test('profileId 里带 - 也不会解析错（uuid 就是这种形状）', () {
      const id = '3f1c9b7e-2a44-4d10-9c88-0ab1cd2ef345';
      expect(
        NotificationService.decodePayload(
          NotificationService.encodePayload(id, 7),
        ),
        const MailRef(profileId: id, emailId: 7),
      );
    });
  });

  group('通知 id', () {
    test('两个实例的同号邮件不能撞（否则会互相覆盖）', () {
      expect(
        NotificationService.notificationId('A', 42),
        isNot(NotificationService.notificationId('B', 42)),
      );
    });

    test('同一封恒等（重弹覆盖而不是叠一条）', () {
      expect(
        NotificationService.notificationId('A', 42),
        NotificationService.notificationId('A', 42),
      );
    });

    test('是**跨进程稳定**的固定值，不是每运行一次就换一批', () {
      // 这一条看着多余，其实是在钉死「不能用 `Object.hash`」这件事：
      // 它带一个每个 isolate 随机生成的种子，同一个字符串在两次运行里
      // 会得到不同的值。那样「重启后点通知 → cancel 掉那条」算出的 id
      // 就跟当初 show 用的对不上，通知会一直挂在通知栏里。
      //
      // 这几个期望值是用当前实现算出来的定值。**改哈希实现时必须一起改**
      // —— 改了就等于所有已发出的旧通知再也撤不掉（一次性代价，
      // 可以接受，但不能是「悄悄改掉」）。
      expect(NotificationService.notificationId('A', 42), 2035273658);
      expect(NotificationService.notificationId('B', 42), 1794834237);
      expect(
        NotificationService.notificationId(
          '3f1c9b7e-2a44-4d10-9c88-0ab1cd2ef345',
          7,
        ),
        1258369560,
      );
    });

    test('结果永远是非负的 int32（不能喂负数给插件）', () {
      for (var id = 1; id < 500; id++) {
        final value = NotificationService.notificationId('p-$id', id);
        expect(value, greaterThanOrEqualTo(0), reason: 'id=$id');
        expect(value, lessThanOrEqualTo(0x7fffffff), reason: 'id=$id');
      }
    });
  });
}

MailRow _row(
  int emailId, {
  int type = MailType.receive,
  int unread = UnreadState.unread,
  int isStar = 0,
}) =>
    MailRow(
      profileId: 'A',
      emailId: emailId,
      subject: 's$emailId',
      sendEmail: 'a@b.com',
      type: type,
      unread: unread,
      isStar: isStar,
    );
