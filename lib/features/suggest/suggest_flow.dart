import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../providers/ai_providers.dart';
import '../../providers/core_providers.dart';
import '../../providers/mail_providers.dart';
// `AiSettings` 出现在 [SuggestFlow.visible] 的参数表里；
// `AiStart` 出现在 [SuggestPanelOpener] 的签名里（`launch` 的返回类型）。
// 少了这两行，那两处编译不过。
import '../ai/ai_service.dart';
import '../ai/ai_settings.dart';
import 'mail_action_runner.dart';
import 'suggest_panel.dart';
import 'suggestion.dart';

/// 弹面板这一步的形状，与 [showSuggestPanel] 逐字一致。
///
/// 做成可注入的**只为用例**：`test/suggest_flow_test.dart` 要钉的是 `open`
/// 自己那三步的顺序（先补 → 重读 → 执行），不是面板的四个态 —— 面板在
/// `suggest_panel_test.dart` 里已经逐条钉过了。生产路径上永远是默认那一个。
typedef SuggestPanelOpener = Future<SuggestionChoice?> Function(
  BuildContext context, {
  required MailRow row,
  required bool starEnabled,
  required Future<MailRow?> Function() refresh,
  required Future<AiStart> Function(String input, List<String> actionIds) launch,
});

/// 执行一次动作的函数形状。默认是 [MailActionRunner.execute] ——
/// 同样只为用例：断言「执行器收到的是重读过的那一行」最直接的办法就是
/// 把它换成一支只记录的笔。
typedef SuggestExecutor = Future<void> Function(
  BuildContext context,
  WidgetRef ref, {
  required MailRow row,
  required SuggestionChoice choice,
  VoidCallback? onDeleted,
});

/// 两个入口（列表行菜单 / 详情页顶栏）共用的那一步（spec §8.4）。
///
/// 两个入口各写一遍这五步的话，「从列表点」与「从详情页点」迟早分叉 ——
/// 而分叉的地方一定在最不常走的那条路径上（补正文失败、内嵌详情页）。
abstract final class SuggestFlow {
  const SuggestFlow._();

  /// 这个入口该不该画（spec §8.3）。**三个条件的唯一定义** ——
  /// 列表行菜单（D6）与详情页顶栏（D7）各调一次它。
  ///
  /// 两处各写一遍的话，必然出现「列表里藏了、详情页里还在」这种不一致，
  /// 而那种不一致用户只会理解成「这功能时灵时不灵」。
  ///
  /// 传 [AiSettings] 而不是 `WidgetRef`：两个调用点一个在 `build` 里
  /// （D7，`ref.watch`）、一个在长按回调里（D6，`ref.read`），
  /// 而 `WidgetRef.watch` 在 `build` 之外是**禁用**的。把取值留在调用方，
  /// 这一条判据就是纯的、能脱开 Riverpod 断。
  ///
  /// `settings == null`（还没读到）时返回 false —— 与
  /// `AiSettingsController` 里那段 `_hasKey` 三态注释同一个口径：还没读到
  /// 就**别说能用**。
  static bool visible(MailRow row, AiSettings? settings) {
    // ① 已发送方向：建议怎么处理自己发出去的信号没有意义。
    if (row.isSend) return false;
    // ② 没配好 Key / 地址 / 模型 —— 点了只会弹一句「去设置里填」，
    //    那是把一次注定失败的往返做成了一个按钮。
    if (settings == null || !settings.isUsable) return false;
    // ③ 用户在设置里关掉了这一项（spec §10）。
    return settings.mailSuggestEnabled;
  }

  /// [onDeleted] 是**视图相关的收尾**（内嵌详情页要把选中清掉），一路透传给
  /// 执行器 —— 与 `MailActionRunner.execute` 的同名参数是同一件事。
  ///
  /// 必须透传：从**列表行菜单**点开面板、模型建议「删除」、用户点了它，
  /// 走的是这一条路。不透传的话，那一封被删掉之后详情页（如果开着）还停在
  /// 一个已经不存在的邮件上 —— 而同一个删除从菜单直接点是好使的，于是这变成
  /// 「同一个动作两个入口行为不一样」，正是这个文件存在的理由要防的东西。
  static Future<void> open(
    BuildContext context,
    WidgetRef ref, {
    required MailRow row,
    VoidCallback? onDeleted,
    @visibleForTesting SuggestPanelOpener? opener,
    @visibleForTesting SuggestExecutor? executor,
  }) async {
    final db = ref.read(databaseProvider);
    final mailRef = MailRef(profileId: row.profileId, emailId: row.emailId);
    // 星标能力：与详情页那颗星同一个口径 —— `unknown`（还没探到）按可用算，
    // 宁可多显示一项，也不要在一个正常的实例上把它藏起来。
    final starEnabled =
        ref.read(capabilitiesProvider(row.profileId)).value?.starEnabled ?? true;

    final choice = await (opener ?? showSuggestPanel)(
      context,
      row: row,
      starEnabled: starEnabled,
      // 第 2 步：补正文。`ensureFull` 的异常吞掉（实例可能不支持 full、
      // 网络可能挂）—— **不阻断**，拿摘要继续（spec §8.4 第 3 段）。
      //
      // 回来的是**重新读过的那一行**（`MailDao.find`），不是手里这个对象：
      // 补完正文的是**库**。
      refresh: () async {
        try {
          await ref.read(emailRepositoryProvider).ensureFull(mailRef);
        } catch (_) {
          // 补不到就明说：抬头会如实写「正文 N 字」，比什么都不弹好。
        }
        return db.mailDao.find(row.profileId, row.emailId);
      },
      // 第 4 步：起会话。池子由会话按当前状态算（`suggestActionPool`），
      // 面板与这里都不再算第二遍。
      launch: (input, actionIds) =>
          ref.read(aiServiceProvider).suggest(input: input, actionIds: actionIds),
    );
    if (choice == null || !context.mounted) return;

    // 第 5 步之前**再读一次**：这才是执行器要拿的那一行。文档里那次重读
    // 发生在面板**弹出之前**，而面板开着的那几秒里补正文可能才刚写完库。
    final fresh = await db.mailDao.find(row.profileId, row.emailId) ?? row;
    if (!context.mounted) return;
    await (executor ?? MailActionRunner.execute)(
      context,
      ref,
      row: fresh,
      choice: choice,
      onDeleted: onDeleted,
    );
  }
}
