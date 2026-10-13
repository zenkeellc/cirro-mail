import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/settings/push_pages.dart';

/// 推送向导里**唯一有分支的地方**：这一页算不算做完了、下一步该去哪。
///
/// 界面那一侧（`sections/push_section.dart`）只负责把这里的结果画出来，所以
/// 这一组能覆盖到那七页的全部判断逻辑 —— 而不用为它引入一套「pump 一个挂
/// `ProviderScope` 的页面」的基建。那样一条要建内存库、灌 token、再拼一棵
/// 外壳，成本远大于它钉住的那几条分支；`mailbox_filter_overlay_test.dart`
/// 是仓库里**唯一**一处例外，因为那里要钉的东西（浮层跟着路由收起）只有把
/// 整块界面 pump 起来才看得见。

/// 一份「平台支持、其余什么都没配」的事实，各测试按需覆盖单项。
PushFacts _facts({
  bool available = true,
  bool hasFirebaseConfig = true,
  String relayUrl = '',
  String instanceId = '',
  bool hasPairingCode = false,
  bool deviceIdValid = true,
  bool enabled = false,
  int enrolledMailboxes = 0,
  bool instanceConfirmed = false,
  String? chainEventAt,
}) =>
    PushFacts(
      available: available,
      hasFirebaseConfig: hasFirebaseConfig,
      relayUrl: relayUrl,
      instanceId: instanceId,
      hasPairingCode: hasPairingCode,
      deviceIdValid: deviceIdValid,
      enabled: enabled,
      enrolledMailboxes: enrolledMailboxes,
      instanceConfirmed: instanceConfirmed,
      chainEventAt: chainEventAt,
    );

/// 全配好了、设备也登记上了、检查也过了。
const PushFacts _allDone = PushFacts(
  available: true,
  hasFirebaseConfig: true,
  relayUrl: 'https://push.example.com',
  instanceId: 'inst-1',
  hasPairingCode: true,
  deviceIdValid: true,
  enabled: true,
  enrolledMailboxes: 2,
);

void main() {
  test('七页，顺序就是向导顺序', () {
    expect(PushPage.values, <PushPage>[
      PushPage.status,
      PushPage.threeValues,
      PushPage.enable,
      PushPage.register,
      PushPage.instance,
      PushPage.check,
      PushPage.limits,
    ]);
    expect(pushPageCount, 7);
    expect(pageIndexOf(PushPage.status), 0);
    expect(pageIndexOf(PushPage.limits), 6);
  });

  group('每一页的完成判据', () {
    test('三条值齐了而且设备号格式对，才算填完', () {
      expect(
        pageDone(
          PushPage.threeValues,
          _facts(
            relayUrl: 'https://push.example.com',
            instanceId: 'inst-1',
            hasPairingCode: true,
          ),
        ),
        isTrue,
      );
      // 缺配对码 = 缺最要紧的那一条。
      expect(
        pageDone(
          PushPage.threeValues,
          _facts(relayUrl: 'https://push.example.com', instanceId: 'inst-1'),
        ),
        isFalse,
      );
    });

    test('设备号格式不对时「三条值」也不算完成', () {
      // 这个值填了也注册不上（中转端 401），算成「已完成」会让人去查网络。
      expect(
        pageDone(
          PushPage.threeValues,
          _facts(
            relayUrl: 'https://push.example.com',
            instanceId: 'inst-1',
            hasPairingCode: true,
            deviceIdValid: false,
          ),
        ),
        isFalse,
      );
    });

    test('三条值齐了但平台没有 FCM 实现，仍然不算完成', () {
      // 与 `PushService.isConfigured` 同一口径：`available` 是它的一部分。
      expect(
        pageDone(
          PushPage.threeValues,
          _facts(
            available: false,
            relayUrl: 'https://push.example.com',
            instanceId: 'inst-1',
            hasPairingCode: true,
          ),
        ),
        isFalse,
      );
    });

    test('开关与登记各有各的判据', () {
      expect(pageDone(PushPage.enable, _facts(enabled: true)), isTrue);
      expect(pageDone(PushPage.register, _facts(enrolledMailboxes: 1)), isTrue);
      // 「一个邮箱都没登记」和「登记失败了」在这里看起来一样 —— 都是没完成，
      // 页面据此把用户引回第 ④ 页。
      expect(pageDone(PushPage.register, _facts()), isFalse);
    });

    test('第⑤页：用户没确认、中转端也没记录时回 null，不画假的红叉', () {
      // 这件事发生在**实例后台**（另一个网站），本机看不见 —— 用户什么都不
      // 说的时候只能显示「待你自己确认」，而不是断言他没做。
      expect(pageDone(PushPage.instance, _allDone), isNull);
      // 他没勾，但中转端确实收到过 webhook：那是客观证据，算完成。
      expect(
        pageDone(PushPage.instance, _facts(chainEventAt: '2026-10-01T02:03:04Z')),
        isTrue,
      );
      // 勾了就作数（本机只拿得到「用户自己说的」这一条）。
      expect(pageDone(PushPage.instance, _facts(instanceConfirmed: true)), isTrue);
      // 空串与 null 一个意思：「最近一次事件」还没有过，不是证据。
      expect(pageDone(PushPage.instance, _facts(chainEventAt: '')), isNull);
    });

    test('第⑥页：只有「这一次真的问过中转端」才算，没问过是查不出来', () {
      expect(pageDone(PushPage.check, _allDone), isNull);
      expect(pageDone(PushPage.check, _allDone, chainVerified: true), isTrue);
      expect(pageDone(PushPage.check, _allDone, chainVerified: false), isFalse);
      // 上次会话存下来的那份通过记录走 `chainVerified: true` 进来（见
      // `_chainDone`）—— 判据本身不需要知道它是哪一次问的。
      expect(
        pageDone(
          PushPage.check,
          _facts(chainEventAt: '2026-10-01T02:03:04Z'),
          chainVerified: true,
        ),
        isTrue,
      );
    });

    test('状态页与说明页是「知道了就算完」', () {
      expect(pageDone(PushPage.status, _allDone), isTrue);
      expect(pageDone(PushPage.limits, _allDone), isTrue);
      // 平台没有 FCM 实现时，状态页没有可确认的答案。
      expect(pageDone(PushPage.status, _facts(available: false)), isNull);
    });
  });
}
