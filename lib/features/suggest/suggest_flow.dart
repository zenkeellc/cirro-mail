import 'package:cirro_mail_ext/cirro_mail_ext.dart' as ext;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/breakpoints.dart';
import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../providers/ai_providers.dart';
import '../../providers/core_providers.dart';
import '../../providers/mail_providers.dart';
// `AiSettings` 出现在 [SuggestFlow.visible] 的参数表里；
// `AiStart` 出现在 [SuggestDeps] 的签名里（`launch` 的返回类型）。
import '../ai/ai_service.dart';
import '../ai/ai_settings.dart';
import 'mail_action_runner.dart';
import 'suggest_dock_request.dart';
import 'suggest_panel.dart';
import 'suggestion.dart';

/// 弹整页建议这一步的形状，与 [showSuggestPage] 逐字一致。
///
/// 做成可注入的**只为用例**：`test/suggest_flow_test.dart` 要钉的是 `open`
/// 自己那几步的顺序（先补 → 重读 → 执行），不是面板的四个态 —— 面板在
/// `suggest_panel_test.dart` 里已经逐条钉过了。生产路径上永远是默认那一个。
typedef SuggestPageOpener = Future<SuggestionChoice?> Function(
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

/// 组装一次建议要用的三个东西：补正文、起请求、星标能力。
///
/// **面板与详情页停靠面板共用这一份**：两个形态各写一遍的话，「补不到正文
/// 就明说、不阻断」与「星标 unknown 按可用算」迟早分叉，而分叉只会出现在
/// 最不常走的那条路径上（内嵌详情页）。
typedef SuggestDeps = ({
  bool starEnabled,
  Future<MailRow?> Function() refresh,
  Future<AiStart> Function(String input, List<String> actionIds) launch,
  String? sourceLabel,
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
  ///
  /// [channelAvailable] 是**托管通道就绪**（见 [channelConfigured]）：真订阅
  /// 用户可能从没配过 Key，那时 `settings.isUsable` 恒为 false —— 只看它的话
  /// 订阅通道的七个 AI 入口一个都画不出来（审计 D1）。带上这一位之后，
  /// 「有通道」与「有自带 Key」是**并列**的两条路，任一成立即可见。
  static bool visible(
    MailRow row,
    AiSettings? settings, {
    bool channelAvailable = false,
  }) {
    // ① 已发送方向：建议怎么处理自己发出去的信号没有意义。
    if (row.isSend) return false;
    // ② 设置还没读到（首读在飞）：与从前一样**先别说能用** —— 这一帧过去
    //    之后 `settings` 就会有值了，用户看到的是一次正常的晚出现。
    if (settings == null) return false;
    // ③ 没配好 Key / 地址 / 模型，也**没有**托管通道 —— 点了只会弹一句
    //    「去设置里填」，那是把一次注定失败的往返做成了一个按钮。
    //    有通道时不看 BYOK 那三样：通道自己会在 `state()` 里判就绪。
    if (!channelAvailable && !settings.isUsable) return false;
    // ④ 用户在设置里关掉了这一项（spec §10）。通道与 Key 都不能绕过它：
    //    这是「要不要这个功能」，与「从哪儿调模型」是两件事。
    return settings.mailSuggestEnabled;
  }

  /// **托管通道就绪**：注册了实现方，或者实现方要求入口常驻（S8）。
  ///
  /// 与 `compose_screen` 的 `channelConfigured` 是同一个口径的两半：
  /// 那边还要并上 `settings.isUsable`（BYOK 那条路），而 [visible] 自己就在
  /// 判 BYOK，所以这里只报「通道那一半」。
  ///
  /// `aiEntryAlwaysVisible` 为真时**入口不藏**：商业版的规矩是「先让用户点到，
  /// 点下去再说明原因并给自救路径」—— 它有真正的下一步（登录 / 订阅）。公开版
  /// 返回 false，仍然按 BYOK 判据藏（沿用「不该出现一个点了只回一句『去设置』
  /// 的图标」那条理由）。
  static bool channelConfigured(WidgetRef ref) =>
      ref.read(aiTransportProvider) != null ||
      ext.AppExtensionRegistry.instance.aiEntryAlwaysVisible;

  /// 组装 [SuggestDeps]（补正文 / 起请求 / 星标能力）。纯读，不导航。
  static SuggestDeps deps(WidgetRef ref, MailRow row) {
    final db = ref.read(databaseProvider);
    final mailRef = MailRef(profileId: row.profileId, emailId: row.emailId);
    // 星标能力：与详情页那颗星同一个口径 —— `unknown`（还没探到）按可用算，
    // 宁可多显示一项，也不要在一个正常的实例上把它藏起来。
    final starEnabled =
        ref.read(capabilitiesProvider(row.profileId)).value?.starEnabled ?? true;
    return (
      starEnabled: starEnabled,
      // 补正文：`ensureFull` 的异常吞掉（实例可能不支持 full、网络可能挂）
      // —— **不阻断**，拿摘要继续（spec §8.4 第 3 段）。
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
      // 池子由会话按当前状态算（`suggestActionPool`），面板与这里都不再算第二遍。
      launch: (input, actionIds) =>
          ref.read(aiServiceProvider).suggest(input: input, actionIds: actionIds),
      // 输出处的来源署名（设计稿 §7.5）：同步读，不发网络。公开版恒为 null
      // → 面板抬头不画那颗 chip。
      sourceLabel: ref.read(aiServiceProvider).sourceLabel,
    );
  }

  /// 打开建议。**形态按宽度分**（2026-11-09 需求）：
  ///
  /// - `< 600`（手机）：push 一整页（`showSuggestPage`），拿回用户点的项；
  /// - `>= 600`（平板 / 桌面）：请求详情页把面板**停靠在正文下方**
  ///   （[suggestDockRequestProvider]）。此时执行由详情页自己收口 ——
  ///   只有它手里有那个 `onDeleted`（内嵌详情页删完要清选中）。
  ///
  /// [onDeleted] 是**视图相关的收尾**（内嵌详情页要把选中清掉），窄屏一路
  /// 透传给执行器 —— 与 `MailActionRunner.execute` 的同名参数是同一件事。
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
    @visibleForTesting SuggestPageOpener? opener,
    @visibleForTesting SuggestExecutor? executor,
  }) async {
    final deps = SuggestFlow.deps(ref, row);

    // 手机：整页。执行仍留在调用方 —— 页面只负责「选」，`onDeleted` 才找得到
    // 正确的宿主（内嵌详情页 / 列表）。
    if (Breakpoints.isCompact(MediaQuery.sizeOf(context).width)) {
      // 默认那一支要**多带一个** `sourceLabel`（整页形态把它画在 AppBar 右侧），
      // 而 [SuggestPageOpener] 是对外的测试约定（用例照它写假面板）。所以默认
      // 实现包成一个闭包，不把新参数加到 typedef 上逼每个假实现跟着改。
      final SuggestPageOpener openPage = opener ??
          (
            context, {
            required MailRow row,
            required bool starEnabled,
            required Future<MailRow?> Function() refresh,
            required Future<AiStart> Function(String, List<String>) launch,
          }) =>
              showSuggestPage(
                context,
                row: row,
                starEnabled: starEnabled,
                refresh: refresh,
                launch: launch,
                sourceLabel: deps.sourceLabel,
              );
      final choice = await openPage(
        context,
        row: row,
        starEnabled: deps.starEnabled,
        refresh: deps.refresh,
        launch: deps.launch,
      );
      if (choice == null || !context.mounted) return;

      // 第 5 步之前**再读一次**：这才是执行器要拿的那一行。文档里那次重读
      // 发生在面板**弹出之前**，而面板开着的那几秒里补正文可能才刚写完库。
      final db = ref.read(databaseProvider);
      final fresh = await db.mailDao.find(row.profileId, row.emailId) ?? row;
      if (!context.mounted) return;
      await (executor ?? MailActionRunner.execute)(
        context,
        ref,
        row: fresh,
        choice: choice,
        onDeleted: onDeleted,
      );
      return;
    }

    // 宽屏：面板是详情页正文下方的一块，不在这个函数的上下文里 —— 只能
    // 发一次请求。详情页若还没挂载（列表行菜单先选中再开），它会用
    // `fireImmediately` 在挂载时认领。
    ref
        .read(suggestDockRequestProvider.notifier)
        .request(MailRef(profileId: row.profileId, emailId: row.emailId));
  }
}
