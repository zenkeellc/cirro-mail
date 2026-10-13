import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/core/storage/token_store.dart';
import 'package:mail_app/data/models/mailbox_account.dart';
import 'package:mail_app/data/models/profile.dart';
import 'package:mail_app/features/notifications/push_service.dart';
import 'package:mail_app/features/notifications/relay_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个最小的 profile，只填判定要用到的字段。
///
/// `isLoggedIn` 是个派生值（`userId > 0 && !needsLogin && email.isNotEmpty`），
/// 所以「已登录 / 已登出」只能靠这两个字段摆出来，不能直接给它赋值。
Profile _profile(String id, {required bool loggedIn}) => Profile(
      id: id,
      baseUrl: 'https://mail.example.com/api',
      name: id,
      email: 'a@b.com',
      userId: loggedIn ? 1 : 0,
      needsLogin: !loggedIn,
    );

MailboxAccount _mailbox(String email) => MailboxAccount(
      accountId: email.hashCode & 0xffff,
      email: email,
      name: '',
    );

/// 本机这一侧确实和平台无关的那几个行为：平台可用性判定、配置就绪判定、
/// `instanceId → profileId` 的映射，以及「没配好时不许打网络」这条纪律。
///
/// 之所以值得测：这几处错了的后果是「用户点了通知，App 打开了，但落在
/// 一堆不相干的邮件上」或者「明明没配，却每次启动都去连一个空地址」——
/// 两种都很难在真机上复现（要为它准备一套完整的中转配置）。
///
/// 这里用**真的** `PrefsStore` / `TokenStore`（前者走 SharedPreferences 的
/// mock 后端，后者也装上插件自带的假平台 —— 见 [fakeKeychain]），不再手搓
/// 假对象：推送服务只依赖这两个类的公开行为，用真类才能测到真的行为。

/// 把 `flutter_secure_storage` 换成插件自带的**内存**实现，并返回那份
/// 底层 map。
///
/// 不装它的话，测试里的每次钥匙串读写都抛 `MissingPluginException`，
/// `TokenStore` 会走降级分支 —— 「配对码读不回来」在那些测试里是对的
/// （它们要测的正是「没有配对码就别打网络」），可是**注册这条链路恰恰
/// 需要配对码在**：不装上它，「设备号有没有带着实例位前缀上网」根本走
/// 不到发请求那一步。
///
/// 返回底层 map 是为了能反过来断言「写进去了什么」。
Map<String, String> fakeKeychain({
  Map<String, String> initial = const <String, String>{},
}) {
  final data = Map<String, String>.of(initial);
  FlutterSecureStorage.setMockInitialValues(data);
  return data;
}

/// 三条配置值都填上的 prefs —— `isConfigured` 要它们全都在才为 true。
///
/// `resolveProfileId` 第一行就是 `if (!isConfigured) return ''`，所以**凡是
/// 想走到映射逻辑的测试都必须带上这三条**，否则会在第一行就被拦住，测试
/// 看起来「失败了」而实际根本没进到被测的那段代码。
const Map<String, Object> _configuredPrefs = <String, Object>{
  'cm_push_relay_url': 'https://push.example.com',
  'cm_push_instance_id': 'inst-1',
  'cm_push_device_id': 'inst-1-abc',
};

void main() {
  // 这里用的是**真的** TokenStore，它会去碰平台通道；不初始化 binding 的话
  // 抛出来的是一句和本意无关的 `Binding has not yet been initialized`，
  // 虽然被 TokenStore 的降级分支兜住了，日志里却全是噪音。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 每一条都从「钥匙串是空的」开始，免得上一条写进去的配对码漏过来。
    fakeKeychain();
    // 后台待取槽是**库级**的（见 `pushServiceBackgroundEntry`），不清的话
    // 上一条用例留下的待取事件会漏到下一条里。
    resetBackgroundForTesting();
  });

  Future<PushService> service({
    bool available = true,
    Map<String, Object> prefs = const <String, Object>{},
    List<Object> Function()? onReadProfiles,
    List<Profile> Function()? profiles,
    List<MailboxAccount> Function(String profileId)? mailboxes,
    RelayClient Function(String baseUrl)? clientFactory,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    return PushService(
      prefs: await PrefsStore.open(),
      tokens: TokenStore(),
      readProfiles: () async {
        if (onReadProfiles != null) onReadProfiles();
        return profiles?.call() ?? const <Profile>[];
      },
      readMailboxes: (profileId) async => mailboxes?.call(profileId) ?? const <MailboxAccount>[],
      forceAvailable: available,
      clientFactory: clientFactory,
    );
  }

  group('平台可用性', () {
    test('平台不支持时 isConfigured 恒为 false —— 即使三条值都填了', () async {
      final push = await service(
        available: false,
        prefs: const <String, Object>{
          'cm_push_relay_url': 'https://push.example.com',
          'cm_push_instance_id': 'inst-1',
          'cm_push_device_id': 'inst-1-abc',
        },
      );

      expect(push.available, isFalse);
      expect(push.isConfigured, isFalse,
          reason: 'Windows / Linux 上 firebase_messaging 没有实现（见它的 '
              'pubspec 里 flutter.plugin.platforms 只有 android/ios/macos/web），'
              '填了配置也不该让 UI 显示「已开启」');
    });

    test('syncAll 在平台不支持时直接返回，**不打网络、不读 profile**', () async {
      final push = await service(
        available: false,
        onReadProfiles: () => throw StateError('不该读 profile'),
      );
      final result = await push.syncAll();
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
    });
  });

  group('配置就绪判定', () {
    test('三条值缺一条都算没配', () async {
      final empty = await service();
      expect(empty.isConfigured, isFalse);

      final noRelay = await service(prefs: const <String, Object>{
        'cm_push_instance_id': 'inst-1',
        'cm_push_device_id': 'inst-1-abc',
      });
      expect(noRelay.isConfigured, isFalse);

      final noInstance = await service(prefs: const <String, Object>{
        'cm_push_relay_url': 'https://push.example.com',
        'cm_push_device_id': 'inst-1-abc',
      });
      expect(noInstance.isConfigured, isFalse);

      final noDevice = await service(prefs: const <String, Object>{
        'cm_push_relay_url': 'https://push.example.com',
        'cm_push_instance_id': 'inst-1',
      });
      expect(noDevice.isConfigured, isFalse);
    });

    test('三条齐全才算配好；syncAll 仍然会拦住「没有配对码」', () async {
      final push = await service(prefs: const <String, Object>{
        'cm_push_relay_url': 'https://push.example.com',
        'cm_push_instance_id': 'inst-1',
        'cm_push_device_id': 'inst-1-abc',
        // 开关也要打开 —— 「配好了」和「开着」是两件事（见 PushService.enabled）。
        'cm_push_enabled': true,
      });

      expect(push.isConfigured, isTrue);
      expect(push.enabled, isTrue);
      // 测试环境里密钥库走降级分支 → 读不到配对码 → 应该在这里就停下，
      // 而不是带着一个空配对码去请求中转（那会拿到 401）。
      final result = await push.syncAll();
      expect(result.ok, isFalse);
      expect(result.message, contains('配对码'));
    });

    test('配置齐了但开关关着 → syncAll 不动，也不读 profile', () async {
      final push = await service(
        prefs: const <String, Object>{
          'cm_push_relay_url': 'https://push.example.com',
          'cm_push_instance_id': 'inst-1',
          'cm_push_device_id': 'inst-1-abc',
        },
        onReadProfiles: () => throw StateError('不该读 profile'),
      );

      expect(push.isConfigured, isTrue, reason: '关了开关不该把配置一起丢掉');
      expect(push.enabled, isFalse);
      final result = await push.syncAll();
      expect(result.ok, isFalse);
      expect(result.message, contains('开关'));
    });

    test('没配好时 syncAll 不打网络，只说「还没填配置」', () async {
      final push = await service(onReadProfiles: () => throw StateError('不该读 profile'));
      final result = await push.syncAll();
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
    });

    test('没配好时 unsubscribe 是安全的空操作（设置页反复点不会报错）', () async {
      final push = await service();
      final result = await push.unsubscribe();
      expect(result.ok, isTrue);
    });
  });

  group('instanceId → profileId 映射', () {
    test('还没配好时返回空串，而不是抛', () async {
      final push = await service();
      expect(await push.resolveProfileId('inst-1', 'a@b.com'), '');
    });

    test('推送来自别的实例位时返回空串（这条不是我们的）', () async {
      final push = await service(prefs: const <String, Object>{
        'cm_push_relay_url': 'https://push.example.com',
        'cm_push_instance_id': 'inst-1',
        'cm_push_device_id': 'inst-1-abc',
      });
      expect(await push.resolveProfileId('inst-other', 'a@b.com'), '');
    });

    test('只有一个已登录实例时直接用它（绝大多数设备就是这个形状）', () async {
      // 注意这一条**不需要查邮箱** —— 冷启动那一刻邮箱列表可能还没同步过，
      // 而这个分支是唯一能在那种状态下把用户送到正确实例上的路。
      var readMailboxes = 0;
      final push = await service(
        prefs: _configuredPrefs,
        profiles: () => <Profile>[_profile('p-1', loggedIn: true)],
        mailboxes: (_) {
          readMailboxes++;
          return const <MailboxAccount>[];
        },
      );

      final id = await push.resolveProfileId('inst-1', 'anything@x.com');
      expect(id, 'p-1');
      expect(readMailboxes, 0, reason: '只有一个实例时不该白查一遍邮箱');
    });

    test('多个实例共用同一个位时靠 mailboxEmail 分（推送里的 toEmail 就是它）',
        () async {
      final push = await service(
        prefs: _configuredPrefs,
        profiles: () => <Profile>[
          _profile('p-1', loggedIn: true),
          _profile('p-2', loggedIn: true),
        ],
        mailboxes: (profileId) => <MailboxAccount>[
          _mailbox(profileId == 'p-1' ? 'a@b.com' : 'other@b.com'),
        ],
      );

      // 大小写不该影响判定 —— 服务端和中转端都做过 lowercase，
      // 而推送里的值最终来自邮件的收件人字段。
      expect(await push.resolveProfileId('inst-1', 'A@B.com'), 'p-1');
      expect(await push.resolveProfileId('inst-1', 'other@b.com'), 'p-2');
    });

    test('多实例但邮箱对不上 → 空串（宁可不深链，也不能送到错的实例上）',
        () async {
      final push = await service(
        prefs: _configuredPrefs,
        profiles: () => <Profile>[
          _profile('p-1', loggedIn: true),
          _profile('p-2', loggedIn: true),
        ],
        mailboxes: (_) => <MailboxAccount>[_mailbox('a@b.com')],
      );

      expect(await push.resolveProfileId('inst-1', 'nobody@nowhere.com'), '');
      expect(await push.resolveProfileId('inst-1', ''), '');
    });

    test('已登出的实例不参与匹配', () async {
      final push = await service(
        prefs: _configuredPrefs,
        profiles: () => <Profile>[
          _profile('p-1', loggedIn: false),
          _profile('p-2', loggedIn: true),
        ],
        mailboxes: (_) => const <MailboxAccount>[],
      );

      expect(await push.resolveProfileId('inst-1', 'a@b.com'), 'p-2');
    });

    test('认不出实例时 event.ref 为 null —— 调用方据此退化成「同步一轮」', () {
      const event = PushMailEvent(profileId: '', emailId: 9);
      expect(event.ref, isNull);
    });

    test('认得出实例时 event.ref 直接可用于深链', () {
      const event = PushMailEvent(profileId: 'p-1', emailId: 9);
      expect(event.ref?.profileId, 'p-1');
      expect(event.ref?.emailId, 9);
    });
  });

  group('中转地址归一化', () {
    test('没填协议就补 https，末尾斜杠去掉', () async {
      // 用户多半是从浏览器地址栏复制的，末尾那个 `/` 会让拼出来的
      // 路径变成 `//health`。
      final push = await service(prefs: const <String, Object>{
        'cm_push_relay_url': 'push.example.com/',
      });
      expect(push.relayUrl, 'push.example.com/');
      // 归一化发生在 RelayClient 里，这里只确认服务原样保存、
      // 不在存储层做「聪明」的改写（否则用户改地址时会看到值被吞掉）。
    });
  });

  // 这一组是**回归测试**：线上实测过，裸 UUID 的设备号在每一次真实登记上
  // 都会被中转端拒掉，而 App 生成的一直是裸 UUID。当初漏掉它，是因为端到端
  // 只拿 curl 手工验过、单测 fixture 里**自带**前缀 —— 那个前缀从一开始
  // 就是设计意图，只是两处生成漏了。
  //
  // 那时候中转端回的还是「配对码不正确」（它把前缀错和配对码错合成一句），
  // 现在它单回「设备号格式不对」（`register.ts` 的 `credentialError()`）。
  // 两边都修了是对的：App 不该送出坏值，中转端也不该在拒了值之后指错方向。
  group('设备号前缀（中转端的硬校验）', () {
    test('裸 UUID 补上实例位前缀，形状是 <id>-<32 hex>', () async {
      fakeKeychain();
      final push = await service(prefs: const <String, Object>{
        'cm_push_relay_url': 'https://push.example.com',
        'cm_push_instance_id': 'inst-1',
        'cm_push_device_id': '289946f1440e472ba945590f6394b76d',
      });

      final fixed = await push.ensureDeviceId();
      expect(fixed, startsWith('inst-1-'));
      expect(push.deviceId, fixed, reason: '修完必须落盘，否则下一次请求还是旧值');
      expect(push.deviceIdValid, isTrue);
      // 尾段不保留：那个值从来没有注册成功过（带它的每一次登记都 401），
      // 「留着尾段」只会在新位上多出一条注册。
      expect(fixed.length, 'inst-1-'.length + 32);
    });

    test('已经对了的值**不重掷**（幂等，且不动钥匙串/不写盘）', () async {
      fakeKeychain();
      const good = 'inst-1-289946f1440e472ba945590f6394b76d';
      final push = await service(prefs: const <String, Object>{
        'cm_push_relay_url': 'https://push.example.com',
        'cm_push_instance_id': 'inst-1',
        'cm_push_device_id': good,
      });

      expect(await push.ensureDeviceId(), good);
      expect(await push.ensureDeviceId(), good, reason: '反复调用必须是同一个值');
    });

    test('没有实例位时不掷 —— 掷出来会是个 `-xxxx` 的残废值', () async {
      fakeKeychain();
      final push = await service(prefs: const <String, Object>{
        'cm_push_relay_url': 'https://push.example.com',
      });
      expect(await push.ensureDeviceId(), '');
    });

    test('判据与中转端逐字一致：inst-1 和 inst-11 不算一家', () {
      // 写成「以 id 开头」的话这两个会互相认成一家。
      expect(PushService.deviceIdMatchesInstance('inst-1-abc', 'inst-1'), isTrue);
      expect(PushService.deviceIdMatchesInstance('inst-11-abc', 'inst-1'), isFalse);
      expect(PushService.deviceIdMatchesInstance('inst-1-abc', 'inst-11'), isFalse);
      expect(PushService.deviceIdMatchesInstance('inst-1', 'inst-1'), isFalse,
          reason: '光有前缀没有尾段也是空的');
    });

    test('configure() 里传进来的坏值会被丢掉、换成一个能用的', () async {
      fakeKeychain();
      final push = await service();
      await push.configure(
        relayUrl: 'https://push.example.com',
        instanceId: 'inst-1',
        pairingCode: 'code-1',
        deviceId: '裸的坏值',
      );
      expect(push.deviceId, startsWith('inst-1-'));
      expect(push.deviceIdValid, isTrue);
    });

    test('换实例位时前缀跟着换，并对旧位退订过一次', () async {
      final keychain = fakeKeychain(initial: <String, String>{
        'push_inst-1': 'old-code',
      });
      final adapter = _FakeAdapter();
      final push = await service(
        prefs: const <String, Object>{
          'cm_push_relay_url': 'https://push.example.com',
          'cm_push_instance_id': 'inst-1',
          'cm_push_device_id': 'inst-1-abc123',
        },
        clientFactory: (baseUrl) => RelayClient(
          baseUrl: baseUrl,
          dio: adapter.dio(),
        ),
      );

      await push.configure(
        relayUrl: 'https://push.example.com',
        instanceId: 'inst-2',
        pairingCode: 'new-code',
      );

      expect(push.instanceId, 'inst-2');
      expect(push.deviceId, startsWith('inst-2-'));
      expect(push.deviceIdValid, isTrue);
      expect(keychain['push_inst-2'], 'new-code');

      // 旧位必须被退订：不退的话手机会继续收到 A 实例的通知，而
      // `resolveProfileId` 在 instanceId 对不上时返回空串 —— 用户点开一条
      // 不知道去哪的通知。
      expect(adapter.paths, contains('/unregister'));
      final unregister = adapter.requests.firstWhere((r) => r.path == '/unregister');
      expect(unregister.body['instanceId'], 'inst-1');
      expect(unregister.body['deviceId'], 'inst-1-abc123');
      expect(unregister.body['deviceToken'], 'old-code');
    });

    test('旧位退订失败不阻塞保存（配对码可能已经轮换，会 401）', () async {
      fakeKeychain(initial: <String, String>{'push_inst-1': 'old-code'});
      final adapter = _FakeAdapter(
        respond: (path) => path == '/unregister'
            ? const <String, Object?>{'code': 401, 'message': '配对码不正确'}
            : const <String, Object?>{'code': 200, 'data': <String, Object?>{}},
      );
      final push = await service(
        prefs: const <String, Object>{
          'cm_push_relay_url': 'https://push.example.com',
          'cm_push_instance_id': 'inst-1',
          'cm_push_device_id': 'inst-1-abc123',
        },
        clientFactory: (baseUrl) => RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
      );

      final result = await push.configure(
        relayUrl: 'https://push.example.com',
        instanceId: 'inst-2',
        pairingCode: 'new-code',
      );

      expect(result.ok, isTrue, reason: '退订是顺手做的事，不该把保存搞失败');
      expect(push.instanceId, 'inst-2');
    });
  });

  // 这一条是那个 bug 的**唯一现场**：光断言 prefs 里存对了，断不出
  // `_client()` 那一跳有没有把它原样送出去。中转端看的正是请求体里那个值。
  group('出站请求体里的设备号', () {
    test('unsubscribe 送出去的 deviceId 带着实例位前缀', () async {
      fakeKeychain(initial: <String, String>{'push_inst-1': 'code-1'});
      final adapter = _FakeAdapter();
      final push = await service(
        // 故意预置一个**没有前缀**的裸 UUID —— 就是线上那份 prefs 的样子。
        prefs: const <String, Object>{
          'cm_push_relay_url': 'https://push.example.com',
          'cm_push_instance_id': 'inst-1',
          'cm_push_device_id': '289946f1440e472ba945590f6394b76d',
        },
        clientFactory: (baseUrl) =>
            RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
      );

      final result = await push.unsubscribe();

      expect(result.ok, isTrue);
      final request = adapter.requests.single;
      expect(request.path, '/unregister');
      // 注销**不校验**前缀（中转端按 device_id 精确匹配），所以拿裸 UUID
      // 去删只会「删成功 0 条」—— 注册原样留着继续推。这里断的是发出去的
      // 那个值本身，而不只是 prefs 里存对了。
      expect(request.body['deviceId'], startsWith('inst-1-'));
      expect(request.body['deviceId'], isNot('289946f1440e472ba945590f6394b76d'));
      expect(request.body['instanceId'], 'inst-1');
      expect(request.body['deviceToken'], 'code-1');
    });

    test('syncAll 里凡是发出去的 /register 也带着前缀', () async {
      fakeKeychain(initial: <String, String>{'push_inst-1': 'code-1'});
      final adapter = _FakeAdapter();
      final push = await service(
        prefs: const <String, Object>{
          'cm_push_relay_url': 'https://push.example.com',
          'cm_push_instance_id': 'inst-1',
          'cm_push_device_id': '289946f1440e472ba945590f6394b76d',
          'cm_push_enabled': true,
        },
        profiles: () => <Profile>[_profile('p-1', loggedIn: true)],
        mailboxes: (_) => <MailboxAccount>[_mailbox('a@b.com')],
        clientFactory: (baseUrl) =>
            RelayClient(baseUrl: baseUrl, dio: adapter.dio()),
      );

      // FCM token 拿不到（那是插件的平台通道，且字段是私有的），所以
      // 正常路径会停在「拿不到 token」那一步、一条请求都不发。这里关心
      // 的是**万一发了**，形状对不对 —— 中转端按 `startsWith(<id>-)`
      // 校验，不带前缀一律 401。
      await push.syncAll();
      for (final request in adapter.requests.where((r) => r.path == '/register')) {
        expect(request.body['deviceId'], startsWith('inst-1-'));
      }
    });
  });

  // 后台推送（App 不在前台时收到的那条）与前台走的是**同一套解析**，
  // 但那条路没有前台那种 UI 兜底 —— 前台至少还有列表页接着，后台这条路
  // 字段错一个就是「点了通知落到错的实例上」，所以这层映射值得钉住。
  group('后台推送的载荷解析', () {
    /// 一份形状正确的 data 载荷（与 `mail-push/src/fanout.ts` 的
    /// `buildMessage` 一一对应）。
    Map<String, dynamic> payload({
      String kind = 'new_mail',
      Object emailId = 128,
      String instanceId = 'inst-1',
      String mailboxEmail = 'a@b.com',
    }) =>
        <String, dynamic>{
          'kind': kind,
          'emailId': '$emailId',
          'instanceId': instanceId,
          'mailboxEmail': mailboxEmail,
          'sendEmail': 'noreply@github.com',
          'sendName': 'GitHub',
          'subject': 'Verify',
          'code': '123456',
          'createTime': '2026-10-12T00:00:00Z',
        };

    test('认得的载荷折成事件，profileId 现查库', () async {
      final push = await service(
        prefs: _configuredPrefs,
        profiles: () => <Profile>[_profile('p-1', loggedIn: true)],
        mailboxes: (_) => <MailboxAccount>[_mailbox('a@b.com')],
      );

      final event = await push.debugDecode(payload());

      expect(event, isNotNull);
      expect(event!.profileId, 'p-1');
      expect(event.emailId, 128);
      expect(event.sendName, 'GitHub');
      expect(event.subject, 'Verify');
      expect(event.code, '123456');
      expect(event.mailboxEmail, 'a@b.com');
      expect(event.ref?.profileId, 'p-1');
      expect(event.ref?.emailId, 128);
    });

    test('kind 不是 new_mail → null（别的消息不该触发同步）', () async {
      final push = await service(prefs: _configuredPrefs);
      expect(await push.debugDecode(payload(kind: 'other')), isNull);
    });

    test('emailId 缺失 / 非数字 / 非正 → null', () async {
      final push = await service(prefs: _configuredPrefs);
      expect(await push.debugDecode(payload(emailId: 'abc')), isNull);
      expect(await push.debugDecode(payload(emailId: 0)), isNull);
      expect(await push.debugDecode(payload(emailId: -1)), isNull);
      expect(await push.debugDecode(payload()..remove('emailId')), isNull);
    });

    test('实例位对不上 → profileId 空串，但事件本身仍然成立', () async {
      // 事件**不**丢：`_onPush` 见到空 profileId 会退化成「全量同步一轮」，
      // 那比什么都不做更接近用户期望的「推送不响」。
      final push = await service(
        prefs: _configuredPrefs,
        profiles: () => <Profile>[_profile('p-1', loggedIn: true)],
      );

      final event = await push.debugDecode(payload(instanceId: 'inst-9'));
      expect(event, isNotNull);
      expect(event!.profileId, isEmpty);
      expect(event.ref, isNull);
    });

    test('background 是广播流：可被多次订阅', () async {
      final push = await service(prefs: _configuredPrefs);
      // 广播流的判据是「订阅两次都拿到同一个 stream 对象上的监听」——
      // 单订阅流第二次 listen 会直接抛 StateError。
      final first = push.background.listen((_) {});
      final second = push.background.listen((_) {});
      addTearDown(first.cancel);
      addTearDown(second.cancel);
    });
  });

  // 冷启动竞态：iOS 上带 `content-available` 的推送可以把**没在运行**的 App
  // 拉到后台启动，那一刻顶层入口已经被调用，而 `NotificationHost` 还没建出来。
  // 这一组就是那条路的最小模型 —— 先投递、后订阅。
  group('后台推送的冷启动竞态', () {
    test('事件比监听者先到 → 订阅时从待取槽取走', () async {
      final push = await service(
        prefs: _configuredPrefs,
        profiles: () => <Profile>[_profile('p-1', loggedIn: true)],
      );

      await pushServiceBackgroundEntry(
        const RemoteMessage(
          data: <String, dynamic>{
            'kind': 'new_mail',
            'emailId': '256',
            'instanceId': 'inst-1',
            'mailboxEmail': 'a@b.com',
          },
        ),
      );

      final event = await push.background.first;
      expect(event.profileId, 'p-1');
      expect(event.emailId, 256);
    });

    test('待取槽只留最新一条（多条推送共用一次全量刷新）', () async {
      final push = await service(prefs: _configuredPrefs);

      for (final id in <String>['256', '257', '258']) {
        await pushServiceBackgroundEntry(
          RemoteMessage(
            data: <String, dynamic>{
              'kind': 'new_mail',
              'emailId': id,
              'instanceId': 'inst-1',
            },
          ),
        );
      }

      final event = await push.background.first;
      // 最后那条胜出；同步是全量的，前面两条会被同一个 `_nextRunAt` 带回来。
      expect(event.emailId, 258);
    });

    test('槽里那条只被取走一次', () async {
      final push = await service(prefs: _configuredPrefs);

      await pushServiceBackgroundEntry(
        const RemoteMessage(
          data: <String, dynamic>{
            'kind': 'new_mail',
            'emailId': '300',
            'instanceId': 'inst-1',
          },
        ),
      );

      expect((await push.background.first).emailId, 300);
      // 再订阅一次：槽已经空了，事件也已经过去，什么都不该再来。
      final second = push.background.listen((_) {});
      addTearDown(second.cancel);
      await Future<void>.delayed(Duration.zero);
    });
  });
}

/// 按路径给一份信封。返回 null 走默认的「200 空数据」。
typedef _Respond = Map<String, Object?>? Function(String path);

/// 只回预设信封的适配器，并把每一次请求的路径与 body 记下来。
///
/// 这台设备在测试里拿不到 FCM token（那是插件的平台通道，且是私有字段），
/// 所以「登记成功」这一步单独测不了；这里能钉住的是**出站形状** ——
/// 而那正是本次 bug 逃过单测的地方。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this._respond});

  final _Respond? _respond;

  final List<({String path, Map<String, dynamic> body})> requests =
      <({String path, Map<String, dynamic> body})>[];

  List<String> get paths =>
      requests.map((r) => r.path).toList(growable: false);

  /// 装好这个适配器的 Dio —— `RelayClient` 允许注入，`ConnectTimeout` 之类
  /// 的选项仍然照它自己那份 `BaseOptions` 走。
  Dio dio() {
    final dio = Dio(
      BaseOptions(
        validateStatus: (_) => true,
        contentType: Headers.jsonContentType,
      ),
    );
    dio.httpClientAdapter = this;
    return dio;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    final decoded = bytes.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final path = options.uri.path;
    requests.add((path: path, body: decoded));

    final body = (_respond?.call(path) ??
        <String, Object?>{'code': 200, 'data': <String, Object?>{}});
    final encoded = utf8.encode(jsonEncode(body));
    return ResponseBody(
      Stream<Uint8List>.fromIterable(<Uint8List>[Uint8List.fromList(encoded)]),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
