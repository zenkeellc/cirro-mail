import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/notifications/notification_service.dart';

void main() {
  group('提醒的通知 id 与新邮件那个必须不同（spec §7.5）', () {
    test('reminderId 与 notificationId 不同（同一封邮件两条通知不互相顶掉）', () {
      const profileId = 'p1';
      const emailId = 7;
      expect(
        NotificationService.reminderId(profileId, emailId),
        isNot(NotificationService.notificationId(profileId, emailId)),
      );
    });

    test('reminderId 稳定且落在 31 位正数里（Android 的 id 是 int）', () {
      final a = NotificationService.reminderId('p1', 7);
      final b = NotificationService.reminderId('p1', 7);
      expect(a, b);
      expect(a, greaterThanOrEqualTo(0));
      expect(a, lessThan(0x7fffffff));
    });

    test('不同邮件算出不同 id', () {
      expect(
        NotificationService.reminderId('p1', 7),
        isNot(NotificationService.reminderId('p1', 8)),
      );
      expect(
        NotificationService.reminderId('p1', 7),
        isNot(NotificationService.reminderId('p2', 7)),
      );
    });
  });
}
