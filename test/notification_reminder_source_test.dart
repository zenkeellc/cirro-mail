import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 与上面那条同一个理由：`NotificationService` 的类注释明确写了
/// **不做参数注入**（`FlutterLocalNotificationsPlugin` 是个单例，留一个假的
/// 注入口反而会让人以为单测里能换成 mock），所以「模式传对了没有」只能读源码。
///
/// 这条比行为测试弱 —— 它只证明「那一行文字还在」，不证明它被执行。
/// 但这一颗雷的形状正是「少写一行就静默失效」，文本断言正好防住这一类。
void main() {
  late String source;

  setUpAll(() {
    source =
        File('lib/features/notifications/notification_service.dart')
            .readAsStringSync();
  });

  /// `scheduleReminder` 的函数体：从它的签名到下一个「两个空格 + `///`」之前。
  String scheduleReminderBody() {
    const signature = 'Future<void> scheduleReminder(';
    final at = source.indexOf(signature);
    expect(at, greaterThanOrEqualTo(0), reason: '找不到 scheduleReminder');
    final rest = source.substring(at);
    final next = rest.indexOf('\n  /// ');
    return next < 0 ? rest : rest.substring(0, next);
  }

  test('scheduleReminder 里传的是 exactAllowWhileIdle', () {
    final body = scheduleReminderBody();
    expect(body, contains('AndroidScheduleMode.exactAllowWhileIdle'));
    expect(body, contains('zonedSchedule'));
    expect(body, contains('tz.TZDateTime.from(remindAt, tz.UTC)'));
  });

  test('scheduleReminder 用的是提醒那条渠道', () {
    expect(scheduleReminderBody(), contains('_details(reminder: true)'));
  });

  test('新邮件那条路的渠道 id 与名字一个字没变', () {
    expect(source, contains("static const String _channelId = 'new_mail';"));
    expect(source, contains("static const String _channelName = '新邮件';"));
  });

  test('提醒那条路的渠道 id 是 mail_reminder', () {
    expect(
      source,
      contains("static const String _reminderChannelId = 'mail_reminder';"),
    );
  });

  test('reminderId 的拼法与新邮件那个不同', () {
    expect(source, contains(r"_fnv1a('reminder|$profileId|$emailId')"));
    expect(source, contains(r"_fnv1a('$profileId|$emailId')"));
  });
}
