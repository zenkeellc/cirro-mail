import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/change_signal.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/compose/writing_snippets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('每一个 setter 都恰好打一枪（写盘 → notify）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final signal = SettingsChangeSignal();
    final prefs = PrefsStore(
      await SharedPreferences.getInstance(),
      signal: signal,
    );
    final writers = <String, Future<void> Function()>{
      'setActiveProfileId': () => prefs.setActiveProfileId('p-1'),
      'setLocaleCode': () => prefs.setLocaleCode('en'),
      'setThemeMode': () => prefs.setThemeMode('dark'),
      'setThemePackId': () => prefs.setThemePackId('pack-1'),
      'setPollInterval': () =>
          prefs.setPollInterval(const Duration(seconds: 120)),
      'setPaneListWidth': () => prefs.setPaneListWidth(320),
      'setSidebarMailboxesExpanded': () =>
          prefs.setSidebarMailboxesExpanded(false),
      'setSidebarComposeExpanded': () => prefs.setSidebarComposeExpanded(false),
      'setCollapsedSidebarInstances': () =>
          prefs.setCollapsedSidebarInstances(<String>{'p-1'}),
      'setSendDelay': () => prefs.setSendDelay(const Duration(seconds: 3)),
      'setPrefetchFull': () => prefs.setPrefetchFull(false),
      'setInstanceColors': () => prefs.setInstanceColors(<String, int>{'p-1': 2}),
      'setSignature': () => prefs.setSignature('a@b.com', '— A'),
      'setPhrases': () =>
          prefs.setPhrases('a@b.com', const <WritingSnippet>[]),
      'setMailboxFilter': () => prefs.setMailboxFilter(null),
      'setNotifyEnabled': () => prefs.setNotifyEnabled(false),
      'setNotifyBanner': () => prefs.setNotifyBanner(false),
      'setOnboarded': () => prefs.setOnboarded(true),
      'setPushRelayUrl': () => prefs.setPushRelayUrl('https://push.example.com'),
      'setPushInstanceId': () => prefs.setPushInstanceId('inst-1'),
      'setPushDeviceId': () => prefs.setPushDeviceId('inst-1-abc'),
      'setPushMailboxes': () => prefs.setPushMailboxes(<String>['a@b.com']),
      'setPushEnabled': () => prefs.setPushEnabled(true),
      'setPushIsAdmin': () => prefs.setPushIsAdmin(true),
      'setAiSettingsJson': () => prefs.setAiSettingsJson('{"apiFormat":"openai"}'),
      'setAiSourceCode': () => prefs.setAiSourceCode('byok'),
      'setAiUsage': () => prefs.setAiUsage('2026-11-11:1'),
      'setExternalAllowedHosts': () =>
          prefs.setExternalAllowedHosts(<String>['*.example.com']),
      'setQuietTrackingPixels': () => prefs.setQuietTrackingPixels(false),
      'setUpdateCheckEnabled': () => prefs.setUpdateCheckEnabled(false),
      'setUpdateLastCheckMs': () => prefs.setUpdateLastCheckMs(1),
      'setUpdateLastNotified': () => prefs.setUpdateLastNotified('0.2.0+132'),
      'dismissPromo': () => prefs.dismissPromo('https://promo.example.com'),
      'clearPushConfig': () => prefs.clearPushConfig(),
      // remove 支：值是 null / 默认值 → 走 `_putOrRemove` 的删 key 那一半，
      // 和上面那些 setString 不是同一行代码，漏了就是「删掉的配置永远不
      // 触发同步」。
      'setActiveProfileId(null)': () => prefs.setActiveProfileId(null),
      'setThemePackId(null)': () => prefs.setThemePackId(null),
      'setQuietTrackingPixels(true)': () => prefs.setQuietTrackingPixels(true),
      // 放最后：它清空整个 prefs，排在后面会让那些 setter 的断言失去意义。
      'clearAll': () => prefs.clearAll(),
    };
    var count = 0;
    final sub = prefs.changes.listen((_) => count++);
    for (final entry in writers.entries) {
      final before = count;
      await entry.value();
      await pumpEventQueue();
      expect(count, before + 1, reason: '${entry.key} 没发变更信号');
    }
    await sub.cancel();
  });
}
