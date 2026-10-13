import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/db/daos/reminder_dao.dart';
import '../../core/db/database.dart';

/// 「稍后提醒」的**降级路**（spec §7.6）。
///
/// Linux 上这条路是**唯一**一条：`flutter_local_notifications_linux 8.0.1`
/// 没有覆写 `zonedSchedule`，平台接口直接抛 `UnimplementedError`。其余平台
/// 由系统排期（`NotificationService.scheduleReminder`），本类**不参与**。
///
/// **它是有损的**：只在应用进程活着时有效 —— Linux 上关掉 App 就收不到提醒。
/// 桌面端「关窗是藏起来」所以进程通常在，但这不是保证。如实写在文档里，
/// 而不是让用户以为 Linux 也和服务端排期一样可靠。
///
/// 两处刻意的设计：
///
/// 1. **不自己起计时器**，搭现成的 `SyncScheduler` 那 1 秒心跳的慢活那一道
///    （`onSlowTick`，每 20 拍一次，与出站队列那个 20 秒同频）。调度器的启停
///    已经绑在「有实例在跑」上，再起一个计时器就要在同一批启停点维护它。
///
///    **节流只有调度器那一处**。这里曾经自己也数一遍 20 拍，两下一乘就是
///    ≈400 秒 —— 而两个文件的注释都写着「≈20 秒」。Linux 上这条降级路是
///    唯一一条，慢了 20 倍意味着用户设的「今天 18:00」当天基本不会响。
/// 2. **不 import 平台插件，也不 import `NotificationService`** —— 弹那一下
///    由 [show] 这个回调注入。理由不是「为了好测」而已：Linux 的插件类在
///    macOS 的测试进程里连构造都会失败（`dlopen('libc.so.6')`），
///    直接持有它等于把这个类也变成不可测的。
class ReminderTicker {
  ReminderTicker({required this.dao, required this.show});

  final ReminderDao dao;

  /// 把一条到点的提醒弹出去。抛异常 = 这一条没弹成（不置 `firedAt`）。
  final Future<void> Function(DbReminder reminder) show;

  /// 上一轮还没跑完时为真（重入闸门）。见 [run]。
  bool _running = false;

  /// 心跳**每跳一次**调一次（由 `SyncScheduler.onSlowTick` 驱动）。
  ///
  /// **这里不数拍**：调度器那边的慢活闸门（`slowEveryTicks`，1 秒 × 20）已经
  /// 把这一个回调节流到 ≈20 秒一次了。再数一遍就是两道闸门相乘，实际变成
  /// ≈400 秒 —— 而两个文件都写着「≈20 秒」。这条降级路只在 Linux 上跑，
  /// 那里它是**唯一**一条提醒通路，慢 20 倍等于这个功能当天的提醒不响。
  ///
  /// 返回值是给测试的：`run()` 是 fire-and-forget 的，不返回它，
  /// 「这一拍真的去查库了」在用例里就观察不到。
  bool onHeartbeat() {
    unawaited(run());
    return true;
  }

  /// 现在查一次（不等计数到 20）—— 测试用，以及 App 起来时立刻补一次
  /// 「关着 App 的那段时间里到点、错过了的」那几条（spec §7.5
  /// 「下一轮 ticker 会补」）。
  ///
  /// 返回**弹成功了几条**。
  ///
  /// **整个方法吞异常**：它是从心跳里 fire-and-forget 调起来的，抛出去就是
  /// 一条没人接的未处理异常（在真机上表现为日志里一串红字 + 提醒永远不弹）。
  /// 逐条的失败在下面那个 `try` 里单独处理，这里的兜底是给「库挂了」这类
  /// 整批失败用的。
  Future<int> run({DateTime? now}) async {
    if (_running) return 0;
    _running = true;
    final at = now ?? DateTime.now().toUtc();
    var fired = 0;
    try {
      final due = await dao.due(at);
      for (final reminder in due) {
        try {
          await show(reminder);
          // 顺序：先弹、后置 `firedAt`。反过来的话，弹失败会留下一条
          // 「已经提醒过」的记录 —— 用户永远等不到那条提醒，而库里写着弹过了。
          // 现在的失败是「下一拍重试」，可恢复。
          await dao.markFired(reminder.id, at);
          fired++;
        } catch (e) {
          // 这一条弹不出来：不置 firedAt，下一拍再试。
          debugPrint('提醒：弹出「${reminder.subject}」失败：$e');
        }
      }
    } catch (e) {
      debugPrint('提醒：查询失败：$e');
    } finally {
      _running = false;
    }
    return fired;
  }
}
