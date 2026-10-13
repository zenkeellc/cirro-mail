// 「当前那一封邮件」从哪来 —— 这是本轮**唯一**一处新逻辑，其余都是接线。
//
// 为什么不是新加一个全局「列表选中态」：宽屏分栏的选中态今天就在**地址**里
// （`?sel=<emailId>&profile=<pid>`，见 `Routes.mailOf` 的注释），窄屏详情页
// 在路径段里。再造一份全局状态就有两个真相，切分支 / 换地址时它们会漂。
// 所以从地址解 —— 解不出就返回 null，调用方静默不做。
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/mail_ref.dart';
import 'package:mail_app/features/shortcuts/shortcut_host.dart';

void main() {
  group('解得出', () {
    test('窄屏详情：/mail/<p>/<e>', () {
      expect(
        currentMailRef(Uri.parse('/mail/p1/7')),
        const MailRef(profileId: 'p1', emailId: 7),
      );
    });

    test('聚合节点详情：/mail/all/<e> 靠 ?profile= 补实例', () {
      expect(
        currentMailRef(Uri.parse('/mail/all/7?profile=p2')),
        const MailRef(profileId: 'p2', emailId: 7),
      );
    });

    test('星标详情：/starred/<e>?profile=<p>', () {
      expect(
        currentMailRef(Uri.parse('/starred/7?profile=p2')),
        const MailRef(profileId: 'p2', emailId: 7),
      );
    });

    test('宽屏收件箱选中：/mail/<p>?sel=<e>', () {
      expect(
        currentMailRef(Uri.parse('/mail/p1?sel=7')),
        const MailRef(profileId: 'p1', emailId: 7),
      );
    });

    test('宽屏星标选中：/starred?sel=<e>&profile=<p>', () {
      expect(
        currentMailRef(Uri.parse('/starred?sel=7&profile=p2')),
        const MailRef(profileId: 'p2', emailId: 7),
      );
    });

    test('详情地址上多余的查询参数不影响（folder / unread / account）', () {
      expect(
        currentMailRef(Uri.parse('/mail/p1?sel=7&folder=send&unread=1')),
        const MailRef(profileId: 'p1', emailId: 7),
      );
    });
  });

  group('解不出就是 null', () {
    test('列表页没选中', () {
      for (final uri in <String>[
        '/mail/p1',
        '/starred',
        '/mail/all',
        '/mail/p1?sel=0',
      ]) {
        expect(currentMailRef(Uri.parse(uri)), isNull, reason: uri);
      }
    });

    test('不是邮件列表的地方', () {
      for (final uri in <String>[
        '/settings',
        '/drafts',
        '/compose',
        '/outbox?sel=3', // 发件箱的 sel 是**队列条目** id，不是邮件
        '/',
      ]) {
        expect(currentMailRef(Uri.parse(uri)), isNull, reason: uri);
      }
    });

    test('缺实例参数的聚合地址（画不出右栏，也做不了动作）', () {
      for (final uri in <String>['/mail/all/7', '/starred/7', '/starred?sel=7']) {
        expect(currentMailRef(Uri.parse(uri)), isNull, reason: uri);
      }
    });

    test('emailId 不是正整数', () {
      for (final uri in <String>[
        '/mail/p1/abc',
        '/mail/p1/-3',
        '/mail/p1?sel=abc',
      ]) {
        expect(currentMailRef(Uri.parse(uri)), isNull, reason: uri);
      }
    });
  });
}
