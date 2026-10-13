import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/suggest/mail_action_runner.dart';

/// 某一天的 10:00。
DateTime at10(DateTime day) => DateTime(day.year, day.month, day.day, 10);

/// 从 [day] 往回找到最近一个周一（用来构造「今天是周一」那个边界）。
DateTime latestMonday(DateTime day) =>
    DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));

void main() {
  group('快捷时间（spec §7.4）', () {
    final day = DateTime(2026, 10, 11);
    final options = MailActionRunner.quickRemindOptions(at10(day));

    test('三项按 今天 / 明天 / 下周一 的次序', () {
      expect(
        options.map((o) => o.kind).toList(),
        <RemindKind>[RemindKind.today, RemindKind.tomorrow, RemindKind.nextMonday],
      );
    });

    test('全部在**未来**（雷三：插件对过去的时间直接抛）', () {
      final now = at10(day);
      for (final option in options) {
        expect(option.at.isAfter(now), isTrue, reason: '${option.kind} 在过去');
      }
    });

    test('都是**本机墙上时间**（isUtc 为 false）—— toUtc 只能发生一次，在落库之前', () {
      for (final option in options) {
        expect(option.at.isUtc, isFalse);
      }
    });

    test('钟点：今天 18:00、明天与下周一都是 9:00', () {
      expect(options[0].at.hour, 18);
      expect(options[0].at.minute, 0);
      expect(options[1].at.hour, 9);
      expect(options[2].at.hour, 9);
    });

    test('已经过了 18:00：「今天 18:00」整项**不出现**', () {
      final evening = DateTime(day.year, day.month, day.day, 19, 30);
      final late = MailActionRunner.quickRemindOptions(evening);
      expect(
        late.map((o) => o.kind),
        isNot(contains(RemindKind.today)),
        reason: '19:30 打开面板时，今天 18:00 已经过去了',
      );
      expect(late.map((o) => o.kind), contains(RemindKind.tomorrow));
    });

    test('今天的 18:00 正好等于 now 时也算过去（不是「还没到」）', () {
      final sharp = DateTime(day.year, day.month, day.day, 18);
      final at = MailActionRunner.quickRemindOptions(sharp);
      expect(at.map((o) => o.kind), isNot(contains(RemindKind.today)));
    });

    test('「下周一」永远是星期一，且**永远不在今天**', () {
      final monday = at10(latestMonday(day)); // 2026-10-05（周一）10:00
      expect(monday.weekday, DateTime.monday, reason: '前提');

      final onMonday = MailActionRunner.quickRemindOptions(monday);
      final next = onMonday.lastWhere((o) => o.kind == RemindKind.nextMonday);
      expect(next.at.weekday, DateTime.monday);
      expect(next.at.isAfter(monday), isTrue, reason: '不能是「今天」那一刻');
      // 周一 10:00 → 下周一 9:00 = **6 个整日**（实为 6 天 23 小时，`inDays` 截断）。
      // 千万别写 7：`inDays` 是截断不是四舍五入，而这里两边钟点不同（10:00 vs 9:00）。
      expect(next.at.difference(monday).inDays, 6);

      // 再拿另一个周一当基准，用**日期差**（不带钟点）钉「整 7 天之后」。
      final anotherMonday = at10(DateTime(2026, 10, 12));
      final soon = MailActionRunner.quickRemindOptions(anotherMonday)
          .lastWhere((o) => o.kind == RemindKind.nextMonday);
      expect(soon.at.weekday, DateTime.monday);
      expect(
        DateTime(soon.at.year, soon.at.month, soon.at.day).difference(
          DateTime(
            anotherMonday.year,
            anotherMonday.month,
            anotherMonday.day,
          ),
        ).inDays,
        7,
        reason: '同样是周一 → 下周一指的是**下一周**那一周一，整 7 天之后',
      );
    });

    test('明天那一项跨月也对（月末的最后一天）', () {
      // 2026-01-31 是月末；加一天必须落到 2 月 1 日而不是「1 月 32 日」。
      final jan = MailActionRunner.quickRemindOptions(
        DateTime(2026, 1, 31, 10),
      );
      final tomorrow =
          jan.firstWhere((o) => o.kind == RemindKind.tomorrow).at;
      expect(tomorrow.month, 2);
      expect(tomorrow.day, 1);
      expect(tomorrow.hour, 9);
    });
  });
}
