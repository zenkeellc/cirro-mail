import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/data/models/recipient.dart';
import 'package:mail_app/features/compose/compose_draft.dart';

/// 「全部回复」预填的收件人集合。
///
/// 这一组守的是三条**错了不会报错、只会把信发给不该发的人（或漏发）**的规则：
///
/// - **密送名单不能跟着回复全部走**。密送之所以是密送，就是因为别人不该知道
///   他们也在这一封里；把 `bcc` 拼进来等于替原发件人公开密送名单。
/// - **自己不能在收件人里**。除了礼节，服务端会把「收件人里有自己」当成一次
///   额外的投递（多一份未读、有时还算配额）。
/// - **同一个人只能出现一次**。`alice@x.com` 与 `Alice@X.com` 是同一个邮箱，
///   按原样拼会出现两个 chip、服务端投两份。
///
/// 顺带钉住「replyAll 与 reply 只有收件人不同」：主题前缀与引用块必须一致，
/// 否则同一封来信的两次回复在邮件客户端里会断成两个线程。
void main() {
  const own = 'me@x.com';

  MailRow rowWith({
    String mailboxEmail = own,
    String sendEmail = 'alice@x.com',
    List<Recipient> recipients = const <Recipient>[],
    List<Recipient> cc = const <Recipient>[],
    List<Recipient> bcc = const <Recipient>[],
  }) =>
      MailRow(
        emailId: 1,
        profileId: 'p1',
        mailboxEmail: mailboxEmail,
        sendEmail: sendEmail,
        name: 'Alice',
        subject: '主题',
        recipients: recipients,
        cc: cc,
        bcc: bcc,
        content: '<p>第一段</p>',
        hasFullBody: true,
        createTime: DateTime.utc(2026, 1, 2, 3, 4),
      );

  test('原发件人 + 原 To + 原 Cc，顺序稳定', () {
    final mail = rowWith(
      recipients: const <Recipient>[
        Recipient(address: 'bob@x.com', name: 'Bob'),
      ],
      cc: const <Recipient>[
        Recipient(address: 'carol@x.com'),
      ],
    );

    expect(
      ComposeDraftFactory.replyAllRecipients(mail),
      <String>['alice@x.com', 'bob@x.com', 'carol@x.com'],
    );
  });

  test('密送（Bcc）不出现 —— 回复全部不是「把密送也抄上」', () {
    final mail = rowWith(
      recipients: const <Recipient>[
        Recipient(address: 'bob@x.com'),
      ],
      cc: const <Recipient>[
        Recipient(address: 'carol@x.com'),
      ],
      bcc: const <Recipient>[
        Recipient(address: 'secret@x.com'),
      ],
    );

    final recipients = ComposeDraftFactory.replyAllRecipients(mail);
    expect(recipients, isNot(contains('secret@x.com')));
    expect(recipients, <String>['alice@x.com', 'bob@x.com', 'carol@x.com']);
  });

  test('自己不在收件人里（大小写不敏感）', () {
    final mail = rowWith(
      mailboxEmail: own,
      // 原发件人就是自己（自己发给自己），To 里也混着大小写不同的自己。
      sendEmail: 'ME@X.com',
      recipients: const <Recipient>[
        Recipient(address: 'Me@x.COM'),
        Recipient(address: 'bob@x.com'),
      ],
      cc: const <Recipient>[
        Recipient(address: 'me@x.com'),
      ],
    );

    expect(
      ComposeDraftFactory.replyAllRecipients(mail),
      <String>['bob@x.com'],
      reason: '自己已经在本地这一行的 mailboxEmail 里说明了，不该再收一份',
    );
  });

  test('按地址去重（大小写不敏感）', () {
    final mail = rowWith(
      recipients: const <Recipient>[
        Recipient(address: 'bob@x.com'),
        Recipient(address: 'BOB@x.com'),
      ],
      cc: const <Recipient>[
        // 原发件人常常也在 To/Cc 里。
        Recipient(address: 'Alice@X.com'),
        Recipient(address: 'bob@x.com'),
      ],
    );

    expect(
      ComposeDraftFactory.replyAllRecipients(mail),
      <String>['alice@x.com', 'bob@x.com'],
    );
  });

  test('格式不合法的地址被丢掉（不是「看着像就发」）', () {
    final mail = rowWith(
      recipients: const <Recipient>[
        Recipient(address: 'not-an-address'),
        Recipient(address: '  bob@x.com  '),
        Recipient(address: ''),
      ],
    );

    expect(
      ComposeDraftFactory.replyAllRecipients(mail),
      <String>['alice@x.com', 'bob@x.com'],
      reason: '坏地址拼进收件人栏，服务端会整封拒收；两头空白的要 trim',
    );
  });

  test('ComposeDraftFactory：replyAll 与 reply 只有收件人不同', () {
    final mail = rowWith(
      recipients: const <Recipient>[
        Recipient(address: 'bob@x.com'),
      ],
      cc: const <Recipient>[
        Recipient(address: 'carol@x.com'),
      ],
    );

    ComposeDraft draftOf(ComposeMode mode) => ComposeDraftFactory.of(
          ComposeArgs(mode: mode, mail: mail),
          ossBase: '',
          wroteLabel: '写道：',
        );

    final reply = draftOf(ComposeMode.reply);
    final replyAll = draftOf(ComposeMode.replyAll);

    expect(replyAll.recipients,
        <String>['alice@x.com', 'bob@x.com', 'carol@x.com']);
    expect(reply.recipients, <String>['alice@x.com']);
    // 主题与引用块（线程、引用头、横线）必须逐字一致 —— 两处各写一份就会分叉。
    expect(replyAll.subject, reply.subject);
    expect(replyAll.quoted, reply.quoted);
  });
}
