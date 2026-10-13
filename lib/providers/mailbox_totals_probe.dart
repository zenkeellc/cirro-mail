import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_defaults.dart';
import '../data/models/enums.dart';
import '../data/models/profile.dart';
import '../data/repositories/email_repository.dart';
import '../features/mail_list/mailbox_filter.dart';
import 'core_providers.dart';
import 'mail_providers.dart';
import 'profile_providers.dart';
import 'sync_providers.dart';

/// 侧栏展开时，把这一台实例各邮箱的**服务端总数**探一遍。
///
/// 为什么要有这一层（而不是让 UI 直接调仓库）：探测有**策略** —— 什么时候
/// 该跳过、多久算过期、同一发不重复发、一次并发几个。策略写在 widget 里就
/// 没法单独测，写进 `EmailRepository` 又会让那个「只负责一次请求 + 落库」
/// 的类开始管调度。仓库那一侧只有一个 `probeMailboxTotal`（一次请求、只读、
/// 失败返回 null），其余全在这里。
///
/// **失败是静默的**：拿不到就什么都不写（连时间戳都不写），于是 TTL 判据认为
/// 它仍然未知，下次展开自动重试 —— 这正是想要的，不需要谁去做定时重试。
/// 刻意**不**调 `recordFailure`：那是同步引擎的退避计数，探测失败不该让
/// 同步面板显示「失败 N 次」—— 用户没按过任何按钮，那件事与他无关。
class MailboxTotalsProbe {
  MailboxTotalsProbe({required this.ref});

  final Ref ref;

  /// 正在飞的探测，键是 `'$profileId/$accountId'`。
  ///
  /// 光有 TTL 挡不住这一种：**两次展开之间库还没被写**（请求还在路上），
  /// 第二次展开读到的仍是「未知」，于是同一个邮箱会挨两发。收起再展开是
  /// 一两秒内做得完的动作，而一个往返可能比那更久。
  final Set<String> _inFlight = <String>{};

  /// 探这一组邮箱里那些「该探」的。
  ///
  /// 返回的 Future 在**这一批都结束之后**才完成（调用方通常 `unawaited`）。
  Future<void> ensure({
    required Profile profile,
    required List<MailboxFilter> boxes,
  }) async {
    // 断网就整个跳过：探出来的东西只是给侧栏看的一个数字，而离线时那几个
    // 请求必然全部失败 —— 白等一轮超时，下次展开再重来。
    if (!(ref.read(onlineProvider).value ?? true)) return;

    final known = ref
            .read(profileMailboxTotalsProvider(profile.id))
            .value ??
        const <String, MailboxTotal>{};
    final now = DateTime.now();

    final pending = <MailboxFilter>[];
    for (final box in boxes) {
      // 合并项（`allReceive`）不探：它的 scope 是 `all:type:0`，同步引擎的
      // 冷启动基线一直在维护它；而且 `accountId = 0` 要服务端收到
      // `allReceive: 1` 才不会被当成「某个具体账户」，探测这条路没有那个开关。
      if (box.accountId == kAllMailboxes) continue;

      final scope = EmailRepository.mailboxScope(box.accountId, MailType.receive);
      final probed = known[scope];
      // 已知且在 TTL 之内：不重探。一个装着几十个邮箱的实例每展开一次就是
      // 几十个请求，而用户往往只是滑过那一眼。
      if (probed != null &&
          now.difference(probed.at) < AppDefaults.mailboxTotalTtl) {
        continue;
      }
      pending.add(box);
    }
    if (pending.isEmpty) return;

    // 批内并发、批间串行：同一个实例的邮箱共用一条连接，一个个发等于把延迟
    // 叠起来；而并发的档位不能开太大 —— 展开一个几十邮箱的实例会瞬间打出
    // 几十个请求，把首屏那几个真正要紧的（列表、正文）挤在后面。
    const size = AppDefaults.mailboxTotalProbeConcurrency;
    for (var i = 0; i < pending.length; i += size) {
      await Future.wait(
        pending
            .skip(i)
            .take(size)
            .map((box) => _probeOne(profile, box.accountId)),
      );
    }
  }

  Future<void> _probeOne(Profile profile, int accountId) async {
    final key = '${profile.id}/$accountId';
    // `add` 返回 false = 已经有一发在飞（同一个邮箱在两次展开之间被点了两下）。
    if (!_inFlight.add(key)) return;
    try {
      await ref.read(emailRepositoryProvider).probeMailboxTotal(
            profile: profile,
            accountId: accountId,
          );
    } catch (_) {
      // 仓库那一层已经吞掉了 `AppException`，这里兜的是**别的**意外
      // （序列化、插件缺失……）。这一格数字坏掉不该让整棵树崩：没有
      // catch 的话它会变成一个「测试结束之后才失败」的异步错误，而现场
      // 只会看到「点了侧栏之后崩了」。
    } finally {
      // **必须 finally**：中途抛异常时这一发要立刻从在飞里撤掉，否则这个
      // 邮箱在本次会话里再也探不动了（与 `backfillBodies` 同一个理由）。
      _inFlight.remove(key);
    }
  }
}

/// 探测器的持有者。形态照 `mailListControllerProvider`：普通 `Provider` +
/// 构造时注入 `ref`，不是一个 `Notifier`（它没有对外可观察的状态 ——
/// 探测的结果落在库里，UI 读的也是库）。
final Provider<MailboxTotalsProbe> mailboxTotalsProbeProvider =
    Provider<MailboxTotalsProbe>(
  (ref) => MailboxTotalsProbe(ref: ref),
  name: 'mailboxTotalsProbe',
);
