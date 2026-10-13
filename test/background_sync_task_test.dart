import 'package:cirro_mail_ext/cirro_mail_ext.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models/enums.dart';
import 'package:mail_app/data/models/mail_row.dart';
import 'package:mail_app/features/notifications/background_sync_task.dart';

/// 后台兜底任务里**不用真机就能钉住**的部分。
///
/// 三件事值得测，因为它们错了都不会报错、只会静默地做错事：
///
/// 1. **平台门控**：`workmanager` 在 Windows 上根本没有实现
///    （`_PlaceholderImplementation` 会抛 `UnimplementedError`），
///    Linux 走的是 systemd、iOS 是机会式调度。少判一个平台就是「启动即崩」
///    或者「注册了一个永远不跑的任务」。
/// 2. **计数的过滤条件**：静默通知里那个「N 封新邮件」如果连已读和发件方向
///    都算进去，数字会永远偏大 —— 而用户没法从界面上看出来是哪个环节错了。
/// 3. **通知 id 的稳定性**：后台 isolate 与前台是**两个进程**，`Object.hash`
///    那套随机种子的哈希在这里会直接算错。
void main() {
  group('平台门控', () {
    test('只有 Android 支持', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(BackgroundSyncTask.isSupported, isTrue);

      for (final platform in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          BackgroundSyncTask.isSupported,
          isFalse,
          reason: '$platform 上不该注册 workmanager 任务',
        );
      }
      debugDefaultTargetPlatformOverride = null;
    });

    test('不支持的平台上 register/cancel 是安全的空操作', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      // 这两个调用在 Windows 上会走到 `_PlaceholderImplementation` 并抛
      // `UnimplementedError` —— 所以必须由 `isSupported` 提前拦住。
      // 测试环境里平台通道本来也不通，能正常返回就说明门控生效了。
      await BackgroundSyncTask.register();
      await BackgroundSyncTask.cancel();
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('值得提醒的邮件计数', () {
    test('只数未读的收件', () {
      final rows = <MailRow>[
        _row(1), // 未读收件 → 算
        _row(2, unread: UnreadState.read), // 已读 → 不算
        _row(3, type: MailType.send), // 发件方向 → 不算
        _row(4, unread: UnreadState.read, type: MailType.send), // 两样都不占
        _row(5), // 未读收件 → 算
      ];

      expect(BackgroundSyncTask.countNotifiable(rows), 2);
    });

    test('空的一批是 0（后台跑一轮什么都没来时不该弹通知）', () {
      expect(BackgroundSyncTask.countNotifiable(const <MailRow>[]), 0);
      expect(
        BackgroundSyncTask.countNotifiable(<MailRow>[
          _row(1, unread: UnreadState.read),
        ]),
        0,
      );
    });

    /// 免打扰规则要在**后台**也生效 —— 后台 isolate 不跑 `main()`，
    /// 它的注册由 `backgroundSyncCallbackDispatcher()` 那句
    /// `registerAll(kAppExtensions)` 负责。这里钉的是下游那半段：
    /// 注册表里有一个静音 `a@b.com` 的扩展时，这个计数要跟着降下来。
    ///
    /// 之所以值得单独钉：`countNotifiable` 与前台闸门
    /// （`NotificationGate.select`）**本来是各写一遍过滤条件的**，两处
    /// 漂了就会出现「横幅不弹、后台静默通知照旧报 N 封」—— 而用户看不出
    /// 数字是哪儿来的。两边现在都走 `isNotifiable`。
    test('有扩展静音某个发件人时，计数跟着降', () {
      AppExtensionRegistry.instance.registerAll(<AppExtension>[
        _MuteSenderExt('a@b.com'),
      ]);
      addTearDown(AppExtensionRegistry.instance.reset);

      final rows = <MailRow>[
        _row(1), // a@b.com，静音 → 不算
        _row(2), // a@b.com，静音 → 不算
        _row(3, sendEmail: 'c@d.com'), // 别的发件人 → 算
      ];

      expect(BackgroundSyncTask.countNotifiable(rows), 1);
      // 反过来：注册表清空之后语义回到从前（这条防的是「规则被记住了」）。
      AppExtensionRegistry.instance.reset();
      expect(BackgroundSyncTask.countNotifiable(rows), 3);
    });
  });
}

/// 一个按发件人地址静音的假扩展 —— 形状与商业版那条规则一致。
class _MuteSenderExt extends AppExtension {
  const _MuteSenderExt(this.muted);

  final String muted;

  @override
  String get id => 'test.mute';

  @override
  bool allowsNotification(NotificationCandidate candidate) =>
      candidate.sendEmail.toLowerCase() != muted;
}

MailRow _row(
  int emailId, {
  int type = MailType.receive,
  int unread = UnreadState.unread,
  String sendEmail = 'a@b.com',
}) =>
    MailRow(
      profileId: 'p-1',
      emailId: emailId,
      subject: 's$emailId',
      sendEmail: sendEmail,
      type: type,
      unread: unread,
    );
