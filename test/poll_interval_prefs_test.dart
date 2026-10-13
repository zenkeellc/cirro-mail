import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/config/app_defaults.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「检查邮件间隔」这一个设置的口径：默认 5 分钟、区间 1 分钟 – 1 小时、
/// 旧版本那两档（`cm_poll_active_seconds` / `cm_poll_idle_seconds`）不再作数。
///
/// 这些都是纯值语义，不需要起数据库或 Riverpod —— 与
/// `mailbox_filter_prefs_test.dart` 同一路数。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<PrefsStore> open() async =>
      PrefsStore(await SharedPreferences.getInstance());

  group('默认值与区间', () {
    test('没存过 = 5 分钟', () async {
      final prefs = await open();
      expect(prefs.pollInterval, const Duration(minutes: 5));
      expect(AppDefaults.pollDefault, const Duration(minutes: 5));
    });

    test('档位从 1 分钟到 1 小时，没有秒级选项', () async {
      expect(AppDefaults.pollChoices.first, const Duration(minutes: 1));
      expect(AppDefaults.pollChoices.last, const Duration(hours: 1));
      for (final choice in AppDefaults.pollChoices) {
        expect(choice.inSeconds % 60, 0);
      }
    });

    test('存进去的档位原样读回来', () async {
      final prefs = await open();
      await prefs.setPollInterval(const Duration(minutes: 20));
      expect(prefs.pollInterval, const Duration(minutes: 20));
    });

    test('比下限还激进的被抬到 1 分钟（旧的 30 秒 / 3 秒也不会溜进来）', () async {
      final prefs = await open();
      await prefs.setPollInterval(const Duration(seconds: 30));
      expect(prefs.pollInterval, const Duration(minutes: 1));
      await prefs.setPollInterval(Duration.zero);
      expect(prefs.pollInterval, const Duration(minutes: 1));
    });

    test('超过上限的被压到 1 小时', () async {
      final prefs = await open();
      await prefs.setPollInterval(const Duration(hours: 24));
      expect(prefs.pollInterval, const Duration(hours: 1));
    });
  });

  group('旧版本的两档 key', () {
    test('不再参与取值 —— 没存过新 key 就是默认 5 分钟', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cm_poll_active_seconds': 30,
        'cm_poll_idle_seconds': 600,
      });
      final prefs = await open();
      expect(prefs.pollInterval, const Duration(minutes: 5));
    });

    test('写新值不动那两个旧 key（降级回旧版本时它们还是原样）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cm_poll_active_seconds': 30,
        'cm_poll_idle_seconds': 600,
      });
      final prefs = await open();
      await prefs.setPollInterval(const Duration(minutes: 15));
      final raw = await SharedPreferences.getInstance();
      expect(raw.getInt('cm_poll_active_seconds'), 30);
      expect(raw.getInt('cm_poll_idle_seconds'), 600);
    });
  });

  group('nearestPollChoice', () {
    test('刚好在档位上就是它自己', () {
      for (final choice in AppDefaults.pollChoices) {
        expect(AppDefaults.nearestPollChoice(choice), choice);
      }
    });

    test('档位外的值取最近一档', () {
      expect(
        AppDefaults.nearestPollChoice(const Duration(seconds: 30)),
        const Duration(minutes: 1),
      );
      expect(
        AppDefaults.nearestPollChoice(const Duration(minutes: 26)),
        const Duration(minutes: 30),
      );
      expect(
        AppDefaults.nearestPollChoice(const Duration(hours: 5)),
        const Duration(hours: 1),
      );
    });

    test('平局取靠前那一档（结果确定，不随遍历顺序飘）', () {
      // 4 分钟离 3 和 5 一样近。
      expect(
        AppDefaults.nearestPollChoice(const Duration(minutes: 4)),
        const Duration(minutes: 3),
      );
    });
  });
}
