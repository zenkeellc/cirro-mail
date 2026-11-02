import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/core_providers.dart';
import '../../providers/settings_providers.dart';
import '../config/app_defaults.dart';
import '../version/version_info.dart';
import 'update_manifest.dart';
import 'update_service.dart';

/// 关于页 / 启动提示要展示的检查结果。
enum UpdateCheckStatus {
  /// 还没检查过（或检查结果已经展示完了）。
  idle,

  /// 正在检查。
  checking,

  /// 已经是最新版本（也包含「当前构建版本未知、不做判断」）。
  upToDate,

  /// 有更新。
  available,

  /// 检查失败，可以重试。
  failed,

  /// 这个构建不做更新检查（清单地址为空），或用户关掉了自动检查。
  ///
  /// 清单地址为空时关于页整块 UI 隐藏，所以这个状态实际上只在
  /// 「用户关掉了自动检查」时被界面看到 —— 那时手动「检查」仍然可用。
  disabled,
}

/// 一次更新检查的结果。
@immutable
class UpdateCheckState {
  const UpdateCheckState({
    this.status = UpdateCheckStatus.idle,
    this.release,
    this.failure,
  });

  /// 什么都不做时的初始态。
  static const UpdateCheckState initial = UpdateCheckState();

  /// 「这个构建不做更新检查」。
  static const UpdateCheckState disabled =
      UpdateCheckState(status: UpdateCheckStatus.disabled);

  final UpdateCheckStatus status;

  /// 清单里那个渠道的最新版本。只有 [UpdateCheckStatus.available] /
  /// [UpdateCheckStatus.upToDate] 时非空。
  final UpdateRelease? release;

  /// 失败原因。只有 [UpdateCheckStatus.failed] 时非空。
  final UpdateException? failure;

  bool get isChecking => status == UpdateCheckStatus.checking;

  @override
  bool operator ==(Object other) =>
      other is UpdateCheckState &&
      other.status == status &&
      other.release == release &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(status, release, failure);

  @override
  String toString() => 'UpdateCheckState(${status.name})';
}

/// 检查新版本的状态机。
///
/// 它只做三件事：调 [UpdateService]、把结果折成 [UpdateCheckState]、记
/// prefs 时间戳。**不发 UI 事件** —— SnackBar 在 `UpdateHost`，关于页的
/// 按钮状态直接 `watch` 这里。
///
/// ## 为什么更新检查不依赖任何实例
///
/// 清单在官网，不在用户的 mail 实例上。所以没登录、甚至一台实例都没配时
/// 关于页的更新检查依然可用 —— 这正是「关于页不依赖实例状态」这条约定。
class UpdateController extends Notifier<UpdateCheckState> {
  @override
  UpdateCheckState build() {
    // 清单地址是构建期常量，`isConfigured` 在进程生命周期里不会变；
    // 用户开关会变，所以 watch 它 —— 拨掉开关时状态立刻落到 disabled，
    // 关于页当场切到「检查按钮仍可点」的那一态。
    if (!ref.watch(updateServiceProvider).isConfigured) {
      return UpdateCheckState.disabled;
    }
    if (!ref.watch(updateCheckEnabledProvider)) {
      return UpdateCheckState.disabled;
    }
    return UpdateCheckState.initial;
  }

  /// 手动检查。关于页的「检查」/「重试」按钮走这条。
  ///
  /// 不受自动检查开关影响：用户明确点了按钮，就是「现在就要知道」。
  /// [now] 只为测试注入时间戳。
  Future<UpdateCheckState> check({DateTime? now}) async {
    final service = ref.read(updateServiceProvider);
    if (!service.isConfigured) {
      state = UpdateCheckState.disabled;
      return state;
    }
    // 连点两下按钮不并发打两个请求；第二下直接返回正在跑的那一次的状态。
    if (state.status == UpdateCheckStatus.checking) return state;

    state = const UpdateCheckState(status: UpdateCheckStatus.checking);
    final version = await ref.read(appVersionProvider.future);

    try {
      final release = await service.fetchLatest();
      // 时间戳只在**成功**时写：失败最常见的原因是「当时没网」，
      // 写进去等于今天不再重试，用户整天都收不到更新提示。
      await ref
          .read(prefsStoreProvider)
          .setUpdateLastCheckMs((now ?? DateTime.now()).millisecondsSinceEpoch);
      if (!ref.mounted) return state;
      state = UpdateCheckState(
        status: release.isNewerThan(version)
            ? UpdateCheckStatus.available
            : UpdateCheckStatus.upToDate,
        release: release,
      );
    } on UpdateException catch (error) {
      if (!ref.mounted) return state;
      state = UpdateCheckState(
        status: UpdateCheckStatus.failed,
        failure: error,
      );
    } catch (error) {
      // 未知异常也折成失败：更新检查不该把 App 打挂。
      if (!ref.mounted) return state;
      state = UpdateCheckState(
        status: UpdateCheckStatus.failed,
        failure: UpdateException(UpdateFailureKind.network, '$error'),
      );
    }
    return state;
  }

  /// 启动时调用：开关打开、且距上次**成功**检查已超过
  /// [AppDefaults.updateCheckInterval] 时才真的打网络。
  ///
  /// 返回值只给测试/调用方看，宿主不需要它。间隔未到时**什么都不做**
  /// （保持当前状态），也不写时间戳。
  Future<UpdateCheckState> autoCheckIfDue({DateTime? now}) async {
    final service = ref.read(updateServiceProvider);
    if (!service.isConfigured) {
      state = UpdateCheckState.disabled;
      return state;
    }
    if (!ref.read(updateCheckEnabledProvider)) {
      state = UpdateCheckState.disabled;
      return state;
    }
    if (state.status == UpdateCheckStatus.checking) return state;

    final current = now ?? DateTime.now();
    final lastCheck = ref.read(prefsStoreProvider).updateLastCheckMs;
    final dueAfter = AppDefaults.updateCheckInterval.inMilliseconds;
    if (lastCheck > 0 &&
        current.millisecondsSinceEpoch - lastCheck < dueAfter) {
      return state;
    }
    return check(now: current);
  }

  /// 这个新版本还没提示过？—— 启动 SnackBar 的判据。
  ///
  /// 判据是「清单里的版本串」与 prefs 里记的那个是否相同：同一个版本只提示
  /// 一次，下个版本发布后自然重新提示，不需要额外的过期逻辑。
  bool get shouldNotify {
    final release = state.release;
    if (state.status != UpdateCheckStatus.available || release == null) {
      return false;
    }
    return ref.read(prefsStoreProvider).updateLastNotified != release.display;
  }

  /// 记下「这个版本已经提示过了」。
  Future<void> markNotified() async {
    final release = state.release;
    if (release == null) return;
    await ref.read(prefsStoreProvider).setUpdateLastNotified(release.display);
  }

  /// 用户点了「稍后」：收起这条 available 状态，并且**不再自动打扰**
  /// （记成已提示过）。下个版本出来时会重新提示。
  Future<void> dismiss() async {
    if (state.status != UpdateCheckStatus.available) return;
    await markNotified();
    if (!ref.mounted) return;
    state = UpdateCheckState.initial;
  }
}

/// 全局唯一的更新检查状态。
///
/// **不做 autoDispose**：`UpdateHost` 与关于页可能在不同路由上同时 watch 它；
/// 自动释放会让「检查完还没来得及展示」的那份结果丢掉，启动检查就白做了。
final NotifierProvider<UpdateController, UpdateCheckState> updateCheckProvider =
    NotifierProvider<UpdateController, UpdateCheckState>(
  UpdateController.new,
  name: 'updateCheck',
);
