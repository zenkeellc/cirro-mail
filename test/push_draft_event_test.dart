import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/notifications/push_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只记「钩子被调了几次」的扩展 —— 云草稿的推送事件在核心这一侧只该做一件事：
/// 把 `draft_changed` 交给扩展。
class _RecordingExt extends AppExtension {
  _RecordingExt(this.id, {this.calls, this.draftFail = false});

  @override
  final String id;

  /// null = 不记账（只关心副作用）。
  final List<String>? calls;

  /// `onDraftChanged` 抛不抛 —— 验注册表吞异常。
  final bool draftFail;

  @override
  Future<void> onDraftChanged() async {
    calls?.add(id);
    if (draftFail) throw StateError('$id 处理草稿事件失败');
  }
}

Profile _profile(String id) => Profile(
      id: id,
      baseUrl: 'https://mail.example.com/api',
      name: id,
      email: 'a@b.com',
      userId: 1,
      needsLogin: false,
    );

MailboxAccount _mailbox(String email) => MailboxAccount(
      accountId: email.hashCode & 0xffff,
      email: email,
      name: '',
    );

const Map<String, Object> _configuredPrefs = <String, Object>{
  'cm_push_relay_url': 'https://push.example.com',
  'cm_push_instance_id': 'inst-1',
  'cm_push_device_id': 'inst-1-abc',
};

/// `mail-push` 发的那条静默消息的 data 形状（见服务端 §5.5）：
/// 只有 `kind / licenseId / at`，**没有** `notification` 字段。
Map<String, dynamic> _draftChanged({String kind = 'draft_changed'}) =>
    <String, dynamic>{
      'kind': kind,
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

  Future<PushService> service({Map<String, Object> prefs = const <String, Object>{}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    return PushService(
      prefs: await PrefsStore.open(),
      tokens: TokenStore(),
      readProfiles: () async => <Profile>[_profile('p-1')],
      readMailboxes: (_) async => <MailboxAccount>[_mailbox('a@b.com')],
      forceAvailable: true,
    );
  }

  group('kind=draft_changed 的分派', () {
    /// 这一条就是「draft_changed 不弹通知」的证明：`_decode` 是所有
    /// `RemoteMessage → PushMailEvent` 路径（`onMessage` / `onMessageOpenedApp` /
    /// 冷启动 `getInitialMessage` / 后台流）唯一的收口，它回 null 就没有事件，
    /// `NotificationHost` 也就没有东西可弹。
    test('不构造通知事件（返回 null），只调扩展钩子', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _RecordingExt('ext-a', calls: calls),
      ]);
      // 故意不配推送实例位：草稿事件与「这封信落在哪个 profile」无关，
      // 钩子不该被 `isConfigured` 拦住。
      final push = await service();

      expect(await push.debugDecode(_draftChanged()), isNull);
      await pumpEventQueue();

      expect(calls, <String>['ext-a']);
    });

    test('new_mail 的行为逐字不变：照旧折成事件、不碰草稿钩子', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _RecordingExt('ext-a', calls: calls),
      ]);
      final push = await service(prefs: _configuredPrefs);

      final event = await push.debugDecode(_newMail());
      await pumpEventQueue();

      expect(event, isNotNull);
      expect(event!.profileId, 'p-1');
      expect(event.emailId, 128);
      expect(calls, isEmpty, reason: 'new_mail 不该触发草稿钩子');
    });

    test('别的 kind 仍然安静地丢掉', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _RecordingExt('ext-a', calls: calls),
      ]);
      final push = await service();

      expect(await push.debugDecode(_draftChanged(kind: 'other')), isNull);
      await pumpEventQueue();
      expect(calls, isEmpty);
    });

    /// 后台入口（`FirebaseMessaging.onBackgroundMessage`）也要触发钩子，
    /// 但**不能**把载荷塞进后台事件流 —— 否则前台那条 `PushService.background`
    /// 订阅会把它当一封信去同步一轮。
    test('后台入口触发钩子，且不进后台事件流（不补通知）', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _RecordingExt('ext-a', calls: calls),
      ]);
      final push = await service(prefs: _configuredPrefs);

      await pushServiceBackgroundEntry(
        RemoteMessage(data: _draftChanged()),
      );
      await pumpEventQueue();

      expect(calls, <String>['ext-a']);
      // 待取槽是空的：订阅之后什么都不会来（超时而不是干等）。
      await expectLater(
        push.background.first.timeout(const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
        reason: 'draft_changed 不该变成一条后台推送事件',
      );
    });

    /// 一个扩展抛错不拖累下一个 —— 这个钩子是「静默推送到达」的公共事件，
    /// 一条坏实现不该让别的扩展收不到。
    test('一个扩展抛错不影响另一个收到事件', () async {
      final calls = <String>[];
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _RecordingExt('ext-bad', draftFail: true),
        _RecordingExt('ext-good', calls: calls),
      ]);
      final push = await service();

      expect(await push.debugDecode(_draftChanged()), isNull);
      await pumpEventQueue();

      expect(calls, <String>['ext-good']);
    });
  });
}
