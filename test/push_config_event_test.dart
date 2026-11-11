import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/notifications/push_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只记「钩子被调了几次」的扩展 —— 「配置快照有变化」的静默推送在核心这一侧
/// 只该做一件事：把 `config_changed` 交给扩展（`AppExtension.onConfigChanged`）。
class _Ext extends AppExtension {
  _Ext(this.id, {this.calls, this.fail = false});

  @override
  final String id;

  /// null = 不记账（只关心副作用）。
  final List<String>? calls;

  /// `onConfigChanged` 抛不抛 —— 验注册表吞异常。
  final bool fail;

  @override
  Future<void> onConfigChanged() async {
    calls?.add(id);
    if (fail) throw StateError('$id 处理配置事件失败');
  }
}

/// `mail-push` 发的那条静默消息的 data 形状（见服务端 §5.5）：
/// 只有 `kind / licenseId / at`，**没有** `notification` 字段。
Map<String, dynamic> _configChanged() => <String, dynamic>{
      'kind': 'config_changed',
      'licenseId': 'CM-1234',
      'at': '1762650000000',
    };

Map<String, dynamic> _newMail() => <String, dynamic>{
      'kind': 'new_mail',
      'emailId': '128',
      'instanceId': 'inst-1',
      'mailboxEmail': 'a@b.com',
      'sendEmail': 'noreply@github.com',
      'sendName': 'GitHub',
      'subject': 'Verify',
      'code': '123456',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppExtensionRegistry.instance.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    resetBackgroundForTesting();
  });

  tearDown(AppExtensionRegistry.instance.reset);

  Future<PushService> service() async => PushService(
        prefs: await PrefsStore.open(),
        tokens: TokenStore(),
        readProfiles: () async => <Profile>[],
        readMailboxes: (_) async => <MailboxAccount>[],
        forceAvailable: true,
      );

  group('kind=config_changed 的分派', () {
    /// `_decode` 是所有 `RemoteMessage → PushMailEvent` 路径（`onMessage` /
    /// `onMessageOpenedApp` / 冷启动 `getInitialMessage` / 后台流）唯一的收口：
    /// 它回 null 就没有事件，`NotificationHost` 也就没有东西可弹。所以「调了
    /// 钩子 + 返回 null」合起来才是「静默转发、不构造通知事件」。
    test('前台分派：调钩子、不构造通知事件', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[_Ext('ext-a', calls: calls)]);
      final push = await service();

      expect(await push.debugDecode(_configChanged()), isNull);
      await pumpEventQueue();

      expect(calls, <String>['ext-a']);
    });

    /// 后台入口（Android 另起 isolate 时也走它）与前台同一个归宿：钩子，
    /// **不进后台事件流**。进去只会让前台把它当一封信去同步一轮。
    test('后台入口：调钩子，且不进后台事件流', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[_Ext('ext-a', calls: calls)]);
      final push = await service();

      await pushServiceBackgroundEntry(RemoteMessage(data: _configChanged()));
      await pumpEventQueue();

      expect(calls, <String>['ext-a']);
      final events = <PushMailEvent>[];
      final sub = push.background.listen(events.add);
      await pumpEventQueue();
      expect(events, isEmpty);
      await sub.cancel();
    });

    /// 待取槽（`_pendingBackgroundData`）是后台事件流的另一半：冷启动时
    /// `PushService.background` 一被订阅就把它取走。`config_changed` 若落进槽里
    /// （后台分支漏了 `return`），订阅那一刻会把它当一条后台事件再解一次 ——
    /// 既第二次调钩子，又把先到的 `new_mail` 顶掉。这条钉「它根本没进槽」。
    test('后台入口：config_changed 不占待取槽（不顶掉先到的 new_mail）', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance
          .registerAll(<AppExtension>[_Ext('ext-a', calls: calls)]);
      final push = await service();

      // 先来一条普通推送占住槽；config_changed 只该走钩子，不该覆盖它。
      await pushServiceBackgroundEntry(RemoteMessage(data: _newMail()));
      await pushServiceBackgroundEntry(RemoteMessage(data: _configChanged()));
      await pumpEventQueue();
      expect(calls, <String>['ext-a']);

      final events = <PushMailEvent>[];
      final sub = push.background.listen(events.add);
      await pumpEventQueue();
      await sub.cancel();

      expect(calls, <String>['ext-a'],
          reason: '槽里若换成 config_changed，订阅会把它再解一次、钩子被调第二遍');
      expect(events.map((event) => event.emailId), <int>[128],
          reason: 'config_changed 落进待取槽会顶掉先到的 new_mail');
    });

    test('一个扩展抛错不影响另一个；new_mail 行为不变', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _Ext('ext-bad', fail: true),
        _Ext('ext-good', calls: calls),
      ]);
      final push = await service();

      expect(await push.debugDecode(_configChanged()), isNull);
      await pumpEventQueue();
      expect(calls, <String>['ext-good']);

      expect(await push.debugDecode(_newMail()), isNotNull);
      await pumpEventQueue();
      expect(calls, <String>['ext-good'], reason: 'new_mail 不该触发配置钩子');
    });
  });
}
