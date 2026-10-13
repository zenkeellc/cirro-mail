// 「这一行该不该弹通知」这条判定，以及它在两个调用点上的**一致性**。
//
// 背景：这条判定以前在两处各写了一遍 —— 前台闸门 `NotificationGate.select`
// 与后台计数 `BackgroundSyncTask.countNotifiable`，靠注释提醒「刻意保持一致」。
// 扩展规则（免打扰）接进来之后这件事不能再靠注释了：两处一旦漂，用户会看到
// 「横幅拦住了静音的发件人，静默通知里的数字却还是把它算进去了」。
//
// 所以这里钉四件事：
// 1. 通用条件（未读 + 收件方向）不因接缝而变；
// 2. 扩展说别弹就真的不弹；
// 3. **闸门的基线仍照常推进** —— 静音是「这次别弹」，不是「当它没来过」；
// 4. 两个调用点对同一批行给出同一个数字。
import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/notifications/background_sync_task.dart';
import 'package:mail_app/features/notifications/notification_policy_seam.dart';
import 'package:mail_app/features/notifications/notification_service.dart';

/// 只回答「某个发件人被静音了没有」的假扩展 —— 形状与商业版那个一致。
class _MuteExt extends AppExtension {
  _MuteExt(this.muted);

  final Set<String> muted;

  @override
  String get id => 'test.mute';

  @override
  bool allowsNotification(NotificationCandidate candidate) =>
      !muted.contains(candidate.sendEmail);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppExtensionRegistry.instance.reset);
  tearDown(AppExtensionRegistry.instance.reset);

  group('通用条件', () {
    test('未读的收件 → 弹', () {
      expect(isNotifiable(_row(1)), isTrue);
    });

    test('已读的不弹', () {
      expect(isNotifiable(_row(1, unread: UnreadState.read)), isFalse);
    });

    test('发件方向的不弹（给自己发出去的信）', () {
      expect(isNotifiable(_row(1, type: MailType.send)), isFalse);
    });

    test('发件方向的判据短路在最前面 —— 连候选都不会构造', () {
      // 这条不是性能洁癖：`notificationCandidateOf` 会读 `row.preview`，
      // 而 `preview` 在 `text` 为空时会跑两条正则去剥 HTML。给每一封自己发出去
      // 的信都白算一遍正则是没必要付的钱。
      var called = 0;
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _RecordingExt(() => called++),
      ]);
      expect(isNotifiable(_row(1, type: MailType.send)), isFalse);
      expect(called, 0);
    });
  });

  group('扩展规则', () {
    test('空注册表 = 恒等（公开版行为不变）', () {
      expect(isNotifiable(_row(1)), isTrue);
    });

    test('被静音的发件人不弹，别人照弹', () {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[_MuteExt(<String>{'noisy@b.com'})]);
      expect(isNotifiable(_row(1, sendEmail: 'noisy@b.com')), isFalse);
      expect(isNotifiable(_row(2, sendEmail: 'quiet@b.com')), isTrue);
    });

    test('候选里带上了扩展判定要用的那几个字段', () {
      final candidate = notificationCandidateOf(MailRow(
        profileId: 'p-1',
        emailId: 7,
        accountId: 3,
        subject: '你的验证码',
        code: '839201',
        sendEmail: 'noreply@shop.com',
        name: 'Shop',
        text: '验证码 839201，五分钟内有效。',
      ));
      expect(candidate.profileId, 'p-1');
      expect(candidate.emailId, 7);
      expect(candidate.accountId, 3);
      expect(candidate.subject, '你的验证码');
      expect(candidate.sendEmail, 'noreply@shop.com');
      expect(candidate.name, 'Shop');
      expect(candidate.bodyPreview, contains('839201'));
      expect(candidate.hasCode, isTrue);
    });

    /// `hasCode` 取的是**服务端抽好的 `code`**，不是「正文里找得到六位数字」。
    ///
    /// 差别在正文还没补拉的邮件上：那种行本地只有摘要，「只弹验证码」这个
    /// 开关如果去正文里找，就会在这一批邮件上静默失灵 —— 而用户刚打开这个
    /// 开关，看到的正是「说好的只弹验证码呢」。
    test('hasCode 只看服务端那个字段，不翻正文', () {
      final withCode = notificationCandidateOf(
        MailRow(profileId: 'p', emailId: 1, code: '123456'),
      );
      expect(withCode.hasCode, isTrue);

      final codeInBodyOnly = notificationCandidateOf(
        MailRow(profileId: 'p', emailId: 2, text: '您的验证码是 123456'),
      );
      expect(
        codeInBodyOnly.hasCode,
        isFalse,
        reason: '正文里出现六位数字不算 —— 那要等 AI 那一列下来',
      );
    });
  });

  group('闸门的游标语义', () {
    /// 这条是整个免打扰功能里**最容易做坏的一处**。
    ///
    /// 静音是「这次别弹」，不是「当它没来过」。基线要是跟着过滤器一起走，
    /// 被静音的那封信就永远推不动游标 —— 用户解除静音之后，它会被当成新邮件
    /// 补弹一次（可能是几周前的信）。
    test('被静音的行照样推进基线：解除静音之后不补弹', () {
      // 用**可变的**静音开关：这个用例要的就是「同一个闸门、中途改规则」。
      var muted = true;
      final gate = NotificationGate(
        policy: (row) => !(muted && row.sendEmail == 'noisy@b.com'),
      );
      gate.select('p-1', <MailRow>[_row(10, sendEmail: 'quiet@b.com')]);

      // 11 被静音、12 正常 —— 基线必须停在 12 上。
      final fresh = gate.select('p-1', <MailRow>[
        _row(11, sendEmail: 'noisy@b.com'),
        _row(12, sendEmail: 'quiet@b.com'),
      ]);
      expect(fresh.map((r) => r.emailId), <int>[12]);

      // 解除静音，再把同一批（外加一封真新的 13）喂回来：11 已经在基线
      // 之下，不该补弹。
      muted = false;
      final afterUnmute = gate.select('p-1', <MailRow>[
        _row(11, sendEmail: 'noisy@b.com'),
        _row(13, sendEmail: 'noisy@b.com'),
      ]);
      expect(
        afterUnmute.map((r) => r.emailId),
        <int>[13],
        reason: '静音期间那封信不该在解除静音后被补弹 —— 那是几周前的信了',
      );
    });

    test('一根都不放行时闸门返回空，但基线仍然推进', () {
      final gate = NotificationGate(policy: (row) => false);
      gate.select('p-1', <MailRow>[_row(10)]);
      expect(gate.select('p-1', <MailRow>[_row(11), _row(12)]), isEmpty);

      // 换个判据（等价于「用户把静音全撤了」）也**看不到** 11、12：
      // 基线已经推到 12 了，只有 13 是新的。
      final reopened = NotificationGate();
      reopened.select('p-1', <MailRow>[_row(12)]);
      expect(
        reopened.select('p-1', <MailRow>[_row(11), _row(12), _row(13)]).single.emailId,
        13,
      );
    });

    /// **注入的那个策略是整条判据**，不是「只换扩展那一段」。
    ///
    /// 所以默认值必须是 [isNotifiable]（通用条件 + 扩展规则），而测试里
    /// 注入一个 `(row) => true` **会**连「未读 + 收件方向」一起换掉 ——
    /// 这一点值得在这儿写清楚：它是「测试能拿它造出任意场景」的代价。
    test('默认策略就是 isNotifiable —— 注册扩展后默认闸门也拦', () {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[_MuteExt(<String>{'noisy@b.com'})]);
      final gate = NotificationGate();
      gate.select('p-1', <MailRow>[_row(10)]);
      final fresh = gate.select('p-1', <MailRow>[
        _row(11, sendEmail: 'noisy@b.com'),
        _row(12, unread: UnreadState.read),
        _row(13, type: MailType.send),
        _row(14),
      ]);
      expect(fresh.map((r) => r.emailId), <int>[14]);
    });
  });

  group('两个调用点不许漂', () {
    /// 前台横幅弹几封、后台静默通知说几封，用户拿这两个当同一件事。
    ///
    /// `select` 需要先建基线，所以这里对**同一批 delta**（后台那种形状）比。
    test('同一批行：countNotifiable 的数字 == select 的长度', () {
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[_MuteExt(<String>{'noisy@b.com'})]);
      final rows = <MailRow>[
        _row(1),
        _row(2, unread: UnreadState.read),
        _row(3, type: MailType.send),
        _row(4, sendEmail: 'noisy@b.com'),
        _row(5),
      ];

      final gate = NotificationGate();
      expect(
        BackgroundSyncTask.countNotifiable(rows),
        gate.select('p-1', rows, delta: true).length,
      );
      expect(BackgroundSyncTask.countNotifiable(rows), 2, reason: '1 与 5');
    });

    test('静音之后计数跟着下降', () {
      final rows = <MailRow>[
        _row(1, sendEmail: 'noisy@b.com'),
        _row(2, sendEmail: 'quiet@b.com'),
      ];
      expect(BackgroundSyncTask.countNotifiable(rows), 2);

      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[_MuteExt(<String>{'noisy@b.com'})]);
      expect(BackgroundSyncTask.countNotifiable(rows), 1);
    });

    test('空注册表时计数语义与从前一致', () {
      final rows = <MailRow>[
        _row(1),
        _row(2, unread: UnreadState.read),
        _row(3, type: MailType.send),
        _row(4),
      ];
      expect(BackgroundSyncTask.countNotifiable(rows), 2);
    });
  });
}

MailRow _row(
  int emailId, {
  int type = MailType.receive,
  int unread = UnreadState.unread,
  String sendEmail = 'a@b.com',
  String code = '',
  String text = '正文',
}) =>
    MailRow(
      profileId: 'p-1',
      emailId: emailId,
      subject: 's$emailId',
      sendEmail: sendEmail,
      code: code,
      text: text,
      type: type,
      unread: unread,
    );

/// 只记「候选被构造了吗」的假扩展。
class _RecordingExt extends AppExtension {
  _RecordingExt(this.onCall);

  final void Function() onCall;

  @override
  String get id => 'test.record';

  @override
  bool allowsNotification(NotificationCandidate candidate) {
    onCall();
    return true;
  }
}
