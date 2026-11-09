import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/avatar_colors.dart';
import '../../core/theme/breakpoints.dart';
import '../../core/theme/instance_colors.dart';
import '../../core/util/diag_log.dart';
import '../../core/util/time_utils.dart';
import '../../core/widgets/email_address_text.dart';
import '../../data/models/enums.dart';
import '../../data/models/mail_attachment.dart';
import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../data/models/recipient.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/mail_providers.dart';
import '../../providers/ai_providers.dart';
import '../../providers/notification_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/settings_providers.dart';
import '../../providers/sync_providers.dart';
import '../compose/compose_draft.dart';
import '../compose/compose_launcher.dart';
import '../mail_list/mail_panes.dart';
import '../suggest/mail_action_runner.dart';
import '../suggest/suggest_dock_request.dart';
import '../suggest/suggest_dock_state.dart';
import '../suggest/suggest_flow.dart';
import '../suggest/suggest_panel.dart';
import '../suggest/suggestion.dart';
import '../sync/sync_stage.dart';
import '../attachment/attachment_kind.dart'
    show formatAttachmentSize, iconOf;
import '../attachment/attachment_sheet.dart';
import 'html_body_view.dart';
import 'image_viewer_screen.dart';
import 'mail_detail_context_menu.dart';

/// 邮件详情。
///
/// 打开的次序只有一份，在 `EmailRepository.openMail`：**先把已读写进本地库**
/// （同一帧 UI 就变），再并发跑 `PUT /email/read` 与 `full=1` 的正文补拉。
/// 今天没有哪两件事是「串在本地写之前等网络」的 —— 那正是「点开半天不变已读」
/// 的来源。
///
/// 附件在 M0/M1 阶段只做「打开/下载」（交给系统浏览器），因为
/// 应用内下载到缓存 → 系统应用打开 → 分享 → 另存为这一整套属于 M1/M4，
/// 需要 `attachment_repository`；这里不做半套实现。
class MailDetailScreen extends ConsumerStatefulWidget {
  const MailDetailScreen({
    super.key,
    required this.profileId,
    required this.emailId,
    this.embedded = false,
    this.onClose,
  });

  final String profileId;
  final int emailId;

  /// 嵌在分栏宿主里（宽屏三栏的右栏），而不是 push 上来的整页。
  ///
  /// 差别只有两处：不自己撑 `Scaffold`（外面的宿主已经有一个），
  /// 以及「删除」之后不是 `pop` 而是让宿主清掉选中。
  /// 其余动作（回复 / 转发 / 星标 / 附件 / 图片预览）全都照旧可用 ——
  /// 这正是复用本类、而不是另写一个「预览控件」的理由。
  final bool embedded;

  /// [embedded] 为真时「关掉右栏」的回调。
  final VoidCallback? onClose;

  @override
  ConsumerState<MailDetailScreen> createState() => _MailDetailScreenState();
}

class _MailDetailScreenState extends ConsumerState<MailDetailScreen> {
  bool _opened = false;

  /// 这一封正在被这个页面**当场补**（[ManualSyncController.sync] 那一趟）。
  ///
  /// 只包住本页发起的那个 await：引擎自己在后台补的那一封信由
  /// [inFlightByProfileProvider] 反映，两者一起决定标题栏转不转圈。
  bool _syncing = false;

  /// 正文选区的键盘焦点。
  ///
  /// **必须有这一颗显式的焦点节点**（见 [_focusReaderOnce] 上面那段）：
  /// `SelectableRegion` 的 `Actions`（`复制` / `全选` 就挂在那里）只对
  /// **焦点在它里面**的按键生效。`SelectionArea` 自己的局部焦点节点在
  /// 「谁都没点过」时不持有焦点，于是打开一封信直接按 `Cmd/Ctrl+C` 什么
  /// 都不会发生 —— 而右键菜单里的「复制」照常好使，因为右键那条路
  /// （`selectable_region.dart` 的 `_handleRightClickDown`）自己会
  /// `requestFocus()`。
  final FocusNode _readerFocus =
      FocusNode(debugLabel: 'mail-detail-selection');

  /// 上一次把焦点交给正文时**是哪一封**（`profileId/emailId`）。
  ///
  /// 焦点只在这一封**第一次显示**（以及换邮件）时抢：页面内部的重建
  /// （同步状态、外联资源开关、附件到位……）不该把用户正点的按钮 / 菜单
  /// 的焦点抢回来。
  String? _focusedMailKey;

  /// 停靠请求的订阅（`initState` 里建，`dispose` 里关）。
  late final ProviderSubscription<MailRef?> _suggestDockSub;

  MailRef get _ref =>
      MailRef(profileId: widget.profileId, emailId: widget.emailId);

  @override
  void initState() {
    super.initState();
    // 「AI 建议」停靠面板的开关**不在本页的 `State` 里**，在
    // `suggestDockStateProvider`。理由：窗口拖过「分栏 / 单栏」那条线时本页会
    // 被整棵拆掉重建（内嵌右栏 ↔ 整页详情，见 `router.dart` 的
    // `foldSelectionAcrossBreakpoints`）—— 开关留在 `State` 里就会跟着旧
    // widget 一起消失，正是用户报的「AI 提示框一改窗口大小就不见」。
    //
    // 从列表行菜单点进来时，列表页摸不到本页的 `State`，它发一次
    // `suggestDockRequestProvider` 请求；本页收到、认领并打开面板。
    // `fireImmediately`：列表页可能先发请求、本页后挂载（宽屏从行菜单点进来
    // 时 `?sel=` 才把右栏建出来）—— 只靠「变化时通知」会漏掉这一种。
    _suggestDockSub = ref.listenManual<MailRef?>(
      suggestDockRequestProvider,
      (_, next) {
        if (next == null || next != _ref) return;
        if (!mounted) return;
        // `fireImmediately` 那次回调发生在 `initState` 里（本页还没完成第一帧）
        // —— 那时**读写 provider**（`consume`）是在构建途中动状态：Riverpod 会
        // 抛「Tried to modify a provider while the widget tree was building」。
        // 统一推到帧后：多等一帧对用户不可见，却避开了这条边界。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // 认领掉：同一个请求不能再被别的页面（比如随后重建的这一页）消费。
          ref.read(suggestDockRequestProvider.notifier).consume(next);
          // 不管宽窄都开：宽窄切换后面板要能留下来（窄屏原先走整页路由，
          // 保留在 `SuggestFlow.open` 里；这一条只处理「列表行菜单先选中、
          // 详情晚一帧挂载」的竞态）。
          ref.read(suggestDockStateProvider.notifier).open(next);
        });
      },
      fireImmediately: true,
    );
    // 上一封的面板会话不许跟着换到这封信上：**只在真的是另一封时**收掉。
    // 窗口宽窄切换重挂的是同一封，那种情况下面板必须还在。
    _closeStaleDock();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openOnce());
  }

  /// 收掉「不是当前这一封」的面板状态（切信 / 从列表点开另一封时）。
  ///
  /// 帧后写 provider：`initState` / `didUpdateWidget` 都可能跑在构建阶段。
  void _closeStaleDock() {
    final openFor = ref.read(suggestDockStateProvider).openFor;
    if (openFor == null || openFor == _ref) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 帧后重新读一遍：这中间面板可能已经被别人收掉 / 换成当前这一封。
      final still = ref.read(suggestDockStateProvider).openFor;
      if (still != null && still != _ref) {
        ref.read(suggestDockStateProvider.notifier).close();
      }
    });
  }

  @override
  void didUpdateWidget(MailDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内嵌时本 widget 在树里的位置是固定的，换一封邮件只会走到这里，
    // **不会重跑 `initState`** —— 少了这一段，第二封点开的邮件永远不会被
    // 标已读、也不会补拉 `full=1`，界面停在截断的摘要上。
    // 宿主已经用 `ValueKey` 保证换邮件即重挂，这里是第二道保险：
    // 将来别的内嵌方漏了 key，也不会静默出错。
    if (oldWidget.emailId != widget.emailId ||
        oldWidget.profileId != widget.profileId) {
      _opened = false;
      _syncing = false;
      // 换了一封：上一封的停靠面板不能跟着留在新邮件下面。
      _closeStaleDock();
      WidgetsBinding.instance.addPostFrameCallback((_) => _openOnce());
    }
  }

  @override
  void dispose() {
    _suggestDockSub.close();
    _readerFocus.dispose();
    super.dispose();
  }

  /// 把**键盘焦点**交给这一封的正文选区。
  ///
  /// ## 为什么需要它（用户报的那个 bug）
  ///
  /// 现象：点开一封信，选中字之后按 `Cmd/Ctrl+C` 没有任何反应，只能用右键
  /// 菜单里的「复制」。
  ///
  /// 根因在 Flutter 的分发路径上，不在菜单：`Cmd/Ctrl+C` 经
  /// `DefaultTextEditingShortcuts` 解成 `CopySelectionTextIntent`，再由
  /// `Actions.maybeFind` **从 `primaryFocus` 的 context 往上找**执行者
  /// （`actions.dart`）。而那个执行者（`_CopySelectionAction`）挂在
  /// `SelectableRegion` 自己的 `Actions` 上
  /// （`selectable_region.dart:353-354`）。焦点不在选区里时找不到它，
  /// 按键就被静默忽略 —— 没有报错、没有提示，看起来就是「快捷键坏了」。
  ///
  /// `SelectableRegion` 在**鼠标**路径上只有两处把焦点要过来：
  /// `_startNewMouseSelectionGesture` 的**第一次单击**那一支（`:741`）与
  /// `_handleRightClickDown`（`:1050`；触摸的长按在 `:1007`）。所以：
  /// - 用右键 → 焦点一定在里面 → 菜单里的「复制」永远好使；
  /// - 打开邮件后**什么都没点**就按键 → 焦点还在别处（列表、或干脆没有）
  ///   → `Cmd+A`/`Cmd+C` 一起失效 —— 这正是「必须用右键」的来源；
  /// - 在**普通正文**上按一下或拖选 → 顺带拿到了焦点 → 这时快捷键又好了，
  ///   于是这个 bug 时灵时不灵，很难复现。
  ///
  /// 修法就是补上「打开这一封时主动把焦点交给正文」这一步 —— 与 macOS
  /// 原生邮件客户端一致（点一封信，阅读区就是键盘焦点所在）。焦点一旦
  /// 在选区里，`Cmd+A`/`Cmd+C` 与右键菜单走的是同一套 `Actions`，
  /// 不再有「快捷键不行、右键才行」的差别。
  ///
  /// ## 为什么在 build 里排 post-frame 回调、而不是在 initState 里要焦点
  ///
  /// `initState` 那一刻正文还没建出来（`mailDetailProvider` 是异步的），
  /// `FocusNode` 还没挂到 `Focus` 上；对着一个没挂上的节点 `requestFocus()`
  /// 是空操作。排到这一帧建完之后，节点一定在树上。
  ///
  /// 用 [_focusedMailKey] 去重：只有「这一封第一次显示 / 换了一封」才抢焦点，
  /// 同封邮件的后续重建（同步转圈、外联资源开关、附件到位）不抢 —— 否则
  /// 用户正在点的按钮、正开着的菜单会被无声地剥掉焦点。
  void _focusReaderOnce(MailRow row) {
    final key = '${row.profileId}/${row.emailId}';
    if (_focusedMailKey == key) return;
    _focusedMailKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 页面被别的路由盖住时**不抢**：那会把焦点从弹层（写邮件页、对话框）
      // 拽回下面这一页。`ModalRoute` 对整页形态是详情自己，对内嵌形态是
      // 外壳所在的那条路由 —— 两种形态都成立。
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      _readerFocus.requestFocus();
    });
  }

  /// 只跑一次。`build` 里不能直接做（会重复标已读 + 重复拉详情），
  /// 也不能放在 `initState` 里（那时还拿不到 provider 的写权限）。
  ///
  /// 整个方法**不允许把异常抛出去**：它挂在 `addPostFrameCallback` 上，
  /// 抛出去就是一个没有任何 UI 承接的异步异常（日志里只有一行
  /// `Unhandled Exception`，屏幕上什么都不会变）。这里做的是「尽力补全」，
  /// 补不到就退回摘要渲染 —— 和 `MailListController.ensureFull`、
  /// `ComposeEntry._ensureFull` 是同一条约定。
  ///
  /// **注意这里吞掉的异常里现在也包括标已读失败**：`openMail` 会先把本地
  /// 标成已读、PUT 失败时回滚成未读（用户看到的是一封信没能标已读，
  /// 列表上仍然粗体 —— 那本身就是提示），然后异常传到这里被记进诊断日志。
  /// 不弹提示是刻意的：打开一封信这件事不该被一个标记失败挡住。
  Future<void> _openOnce() async {
    if (_opened || !mounted) return;
    _opened = true;

    try {
      // 用户已经把这封信读进来了，通知栏里那条就该消失 —— 不管他是从
      // 通知点进来的（`NotificationHost` 已经撤过一次，这里是幂等的）
      // 还是从列表里点开的（那条通知还挂着）。
      unawaited(ref.read(notificationServiceProvider).cancelFor(_ref));

      final row = ref.read(mailDetailProvider(_ref)).value;
      if (row == null) {
        // 本地没有这封（通知深链、或被清理过）：先往回翻页找 —— 通知里的
        // 邮件可能已经掉出本地窗口，而 `ensureFull` 只按 `emailId` 拉一小段，
        // 找不到就放弃。**翻到了会落库**，接下来那一趟才有得标。
        await ref.read(emailRepositoryProvider).locateAcrossPages(_ref);
      }
      // 标已读 + 补正文。`openMail` 本地优先（同帧变已读），网络那两趟并发。
      //
      // **不能只在 `row != null` 时调**（原来是那样）：从通知点进来的邮件
      // 本地往往还没有行，走 `locateAcrossPages` 找回来之后如果直接
      // `ensureFull`，那封信就**永远标不上已读** —— 详情页开着，列表里
      // 还是粗体未读。
      await ref.read(emailRepositoryProvider).openMail(_ref);
    } catch (error, stack) {
      // 详情页已经有摘要可显示，拿不到完整正文不该变成用户可见的故障。
      DiagLog.log('detail', '补全 ${_ref.emailId} 失败（降级为摘要）：'
          '${error.runtimeType}: $error');
      DiagLog.log('detail', '$stack');
    }

    // 上面那两趟只保证**正文**到位（`openMail` 里的 `ensureFull`），附件
    // 一个都不会下 —— 而用户点开一封信正是「我要看它」的意思。所以再补一趟：
    // 判据是 `syncStageOf`，缺正文或缺附件都算没齐，就由
    // `ManualSyncController.sync` 当场补（正文 + 附件，见 `syncOneMail`）。
    //
    // 这条路径**绕过调度器队列**、在调用方的 isolate 上直接打请求 —— 正是
    // 需求里那条「最高优先级」；自动队列那一轮由它自己的排期决定，
    // 用户点开的这一封不该排在它后面。
    await _ensureSynced();
  }

  /// 这一封还没齐就在当场补掉（问题 6 的第二步）。
  ///
  /// 与 [_openOnce] 同一条约定：不抛异常。补不到就什么都不发生 —— 下一轮
  /// 自动同步还会再试（它本来就在「待同步」清单里）。
  Future<void> _ensureSynced() async {
    if (!mounted) return;
    final row = ref.read(mailDetailProvider(_ref)).value;
    if (row == null) return;

    final attachments =
        ref.read(mailAttachmentsProvider(_ref)).value ?? row.attList;
    // 数的是**全部附件行**，与 `MailDao.watchMissingAttachments`（同步面板
    // 列清单用的那条）保持同一口径：`syncOneMail` 补的也正是这一批。
    // 这里若额外滤掉内嵌图，就会出现「详情页说齐了、同步页还列着它」。
    final missing = attachments.where((a) => !a.isDownloaded).length;
    final stage = syncStageOf(
      row: row,
      attachmentTotal: attachments.length,
      attachmentMissing: missing,
    );
    if (!stage.isPending) return;

    setState(() => _syncing = true);
    try {
      await ref.read(manualSyncProvider.notifier).sync(_ref);
    } catch (error, stack) {
      // 手动补这一趟的失败不值得打扰用户：正文/附件各自的失败原因在
      // `syncOneMail` 内部已经被吞过一次，这里再兜一层是防「provider 拿去
      // 之后才炸」的那种（比如实例被删）。
      DiagLog.log('detail', '当场补 ${_ref.emailId} 失败：'
          '${error.runtimeType}: $error');
      DiagLog.log('detail', '$stack');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(mailDetailProvider(_ref));
    final row = async.value;
    final profile = ref.watch(profileByIdProvider(widget.profileId));

    if (row == null) {
      // 还没读出来。内嵌时也要有那个头（右栏不能在这一两帧里塌成空白）。
      // 标题此刻还没有 —— 它是**这封信的标题**（见 [_paneHeader]），
      // 拿实例名顶上会先闪一个与正文无关的词。
      if (widget.embedded) {
        return Column(
          children: <Widget>[
            _paneHeader(''),
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final ossBase = ref.watch(ossBaseProvider(widget.profileId));
    final attachments =
        ref.watch(mailAttachmentsProvider(_ref)).value ?? row.attList;
    final ac = InstanceColors.of(profile?.colorIndex ?? 0);
    // 已发送方向没有「回复自己」这回事（Web 端也只给收件方向的邮件回复入口）。
    final isSendFolder = row.type == MailType.send;
    final syncing = _syncingThisMail();
    // 内嵌形态（宽屏右栏）**不折叠**：右栏最窄也有 `readerMinWidth`（420），
    // 六颗图标放得下 —— 折叠是窄屏整页才需要的（见 [_actions] 的 `collapse`）。
    final actions = _actions(row, isSendFolder, syncing);
    // 面板开关在 provider 上（见 `initState` 的注释）：两种布局共用同一份，
    // 窗口宽窄切换把本页拆了重建之后它还在这儿。
    final suggestOpen = ref.watch(
      suggestDockStateProvider.select((state) => state.isOpenFor(_ref)),
    );

    if (widget.embedded) {
      return Column(
        children: <Widget>[
          _paneHeader(row.displaySubject, actions: actions),
          // 正文**占满整个阅读区宽度**：这里不封顶。封顶（原来是
          // `Breakpoints.readerMaxWidth` 900）在宽屏上会把右栏变成一条居中的
          // 窄带，两边的留白比正文还宽 —— 而右栏本来就是用户自己拖出来的：
          // 嫌它宽，拖分隔条就是那个调节手段。
          Expanded(
            child: _bodyWithSuggest(
              row,
              ossBase,
              attachments,
              ac,
              showSuggest: suggestOpen,
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        // 顶栏是**这封信的标题**（需求二）：实例名在左栏的头、在聚合列表的
        // 实例 chip 上都已经有了一份，这里再来一遍等于把最显眼的一行字
        // 让给了一个用户早就知道的词。正文里还带一次标题，是因为这一屏
        // 可能是滚动到一半的状态（比如从别处回来）—— 那时顶栏是唯一还看得见
        // 「这是哪封信」的地方。
        title: Text(
          row.displaySubject,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        // 窄屏（< 600）把「全部回复 / 转发 / AI 建议」收进 ⋯：六颗 48dp 的
        // 按钮 + 返回箭头 + 标题在 500 宽里摆不下，硬摆的结果是标题被挤成
        // 一条省略号、按钮互相压。宽屏照旧直出图标。
        actions: Breakpoints.compactOf(context)
            ? _actions(row, isSendFolder, syncing, collapse: true)
            : actions,
      ),
      // 整页形态同样不封顶（需求二说的是「占满全部宽度」）。这条路径在
      // 宽屏上只可能出现在**拖窄到刚够单栏**的那一刻（>= 1024 时路由会把
      // 选中折进分栏），所以不封顶不会变成一条 1800px 宽的正文。
      body: _bodyWithSuggest(
        row,
        ossBase,
        attachments,
        ac,
        showSuggest: suggestOpen,
      ),
    );
  }

  /// 正文 + **停靠在正文下方的 AI 建议面板**。
  ///
  /// 为什么是「正文下方插入」而不是弹窗：弹窗会盖住用户正在读的那一段，而
  /// 建议要引用正文里的细节；停靠在下方时正文与建议同时可见。
  ///
  /// 高度取阅读区的 45%，夹在 240–420：再矮放不下两张动作卡，再高会把正文
  /// 挤没。两列/一列由面板自己按**面板宽度**判（>= 720 两列），不按窗口宽
  /// —— 宽屏的阅读区可能被用户拖得很窄。
  ///
  /// **[showSuggest] 不分宽窄**：窄屏开面板仍然走 `SuggestFlow.open` 的整页
  /// 路由（那里是「点」进来的），但**已经从宽屏带着一张开着的面板缩下来**时，
  /// 面板必须继续可见（用户的原话是「需要保持那个 AI 推荐建议面板一直可见」）。
  /// [SuggestView] 的窄形态本来就是按面板自身宽度排的（单列 + 右侧图标栏），
  /// 最低 240 高也放得下 —— 所以这里不再按 `Breakpoints.compactOf` 藏它。
  Widget _bodyWithSuggest(
    MailRow row,
    String ossBase,
    List<MailAttachment> attachments,
    Color ac, {
    required bool showSuggest,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          children: <Widget>[
            Expanded(child: _body(row, ossBase, attachments, ac)),
            if (showSuggest)
              SizedBox(
                height: (constraints.maxHeight * 0.45).clamp(240.0, 420.0),
                child: _suggestDock(row),
              ),
          ],
        );
      },
    );
  }

  /// 停靠面板。回调与 `SuggestFlow.open` 组装的是同一份
  /// （[SuggestFlow.deps]）—— 两个入口的补正文 / 起请求口径不会分叉。
  ///
  /// 结果交给 [suggestDockStateProvider] 存着：窗口宽窄切换重建本页时新面板
  /// 拿它直接画，不再重跑一次分析（见 [SuggestSnapshot]）。
  Widget _suggestDock(MailRow row) {
    final theme = Theme.of(context);
    final deps = SuggestFlow.deps(ref, row);
    final state = ref.read(suggestDockStateProvider);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        // 换邮件就重挂：会话（连同正在跑的 `AiRun`）跟着换掉，不会把上一封
        // 的半截分析留在新邮件下面。
        child: SuggestView(
          key: ValueKey<String>(
            'ai-suggest-dock-${row.profileId}#${row.emailId}',
          ),
          row: row,
          starEnabled: deps.starEnabled,
          refresh: deps.refresh,
          launch: deps.launch,
          onPick: _onSuggestPick,
          onClose: () =>
              ref.read(suggestDockStateProvider.notifier).close(),
          // 宽窄切换重建出来的面板拿这份成品直接画结果（不重跑分析）。
          cached: state.snapshot,
          onResult: (snapshot) => ref
              .read(suggestDockStateProvider.notifier)
              .publish(_ref, snapshot),
          // 抬头右侧的来源署名（设计稿 §5.3）：与 `SuggestFlow.open` 那条路
          // 用的是同一个 `deps.sourceLabel`，两个入口不会一个署名一个不署名。
          sourceLabel: deps.sourceLabel,
        ),
      ),
    );
  }

  /// 停靠面板里点了一项。**执行仍走唯一的执行器**，`onDeleted` 也照旧带上
  /// —— 从 AI 面板删掉一封之后，内嵌详情页要把选中清掉（否则屏幕上是一个
  /// 永远转下去的圈，见 `_afterDelete` 上面那段注释）。
  ///
  /// 先收起面板再执行：回复 / 转发会 push 写邮件页，面板留在下面没有意义。
  void _onSuggestPick(SuggestionChoice choice) {
    final row = ref.read(mailDetailProvider(_ref)).value;
    if (row == null) return;
    ref.read(suggestDockStateProvider.notifier).close();
    unawaited(
      MailActionRunner.execute(
        context,
        ref,
        row: row,
        choice: choice,
        onDeleted: _afterDelete,
      ),
    );
  }

  /// 内嵌形态的顶栏：**邮件标题** + 动作 + 关闭。
  ///
  /// 高度钉死在 [kPaneHeaderHeight]，与左栏的头对齐 —— 两栏的头不一样高，
  /// 中间那条分隔条一眼就看出是两块拼的。
  ///
  /// 长标题截断（`ellipsis`）是必然的：这是**一行**的条。要读全就走正文
  /// 开头那一行标题（它就在下面，没有被截）。
  Widget _paneHeader(String subject, {List<Widget> actions = const <Widget>[]}) {
    return PaneHeader(
      actions: <Widget>[
        ...actions,
        if (widget.onClose != null)
          IconButton(
            tooltip: AppLocalizations.of(context).close,
            icon: const Icon(Icons.close),
            onPressed: widget.onClose,
          ),
      ],
      child: Text(
        subject,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 16),
      ),
    );
  }

  /// 这一封此刻是不是正在被同步（标题栏要不要转圈）。
  ///
  /// 两个来源，缺一不可：
  /// - [_syncing]：这一页自己发起的那一趟（打开时缺什么补什么）；
  /// - [inFlightByProfileProvider]：**调度器**正在补的那一封。少了这一条
  ///   「引擎在补、页面上什么都没发生」就回来了 —— 而用户点开一封待同步
  ///   的信，等的正是那个转圈。
  ///
  /// 这条 watch 挂在 `build` 上（`_syncingThisMail` 只在 `build` 里被调），
  /// 所以引擎的清单一变，这一页就会重画 —— 转圈消失得跟出现一样及时。
  bool _syncingThisMail() {
    if (_syncing) return true;
    final inFlight =
        ref.watch(inFlightByProfileProvider(widget.profileId)).value;
    return inFlight?.contains(_ref) ?? false;
  }

  /// 右上角的动作区。整页形态直接塞进 `AppBar.actions`，内嵌形态塞进 `PaneHeader`。
  ///
  /// [syncing] 时最前面多一个转圈（问题 6）：它标的是**这封信**而不是某个
  /// 实例 —— 实例级的那个转圈在侧栏/列表头，两个说的是不同的事。
  /// 16×16、`strokeWidth: 2`，与 `SyncStatusButton` 里那个是同一副样子。
  ///
  /// 这个转圈**点得动**：它同时是「再补一次」。补完之后这封信可能还是没齐
  /// （服务端 500、附件太大超时），那时转圈消失、页面上没有任何东西告诉用户
  /// 还能重试 —— 后台自动补要等到下一轮排期。点一下就是立刻再来一次。
  /// 这一趟正在跑（[_syncing]）时点它没有意义，那时不可点。
  ///
  /// [collapse] 为真时（窄屏整页，`Breakpoints.compactOf`）只把
  /// **回复 / 星标 / ⋯** 三样留在顶栏，「全部回复 / 转发 / AI 建议」收进 ⋯
  /// 菜单：500 宽下六颗 48dp 的按钮加标题已经摆不开，硬摆时标题被压成一条
  /// 省略号、按钮互相压。**收进菜单的三项仍然是同一批动作**（菜单里的
  /// `onSelected` 走 [_onMenu]，最终调用的还是 [_compose] / `SuggestFlow.open`），
  /// 不是另写一套。
  ///
  /// 内嵌形态（宽屏右栏）**不折叠**：那一栏最窄也有 `readerMinWidth`（420），
  /// 放得下六颗。
  List<Widget> _actions(
    MailRow row,
    bool isSendFolder,
    bool syncing, {
    bool collapse = false,
  }) {
    final l10n = AppLocalizations.of(context);
    // 收件方向才有「回复 / 全部回复 / 转发」这三件事：自己的已发送件
    // 「回复自己」没有意义（Web 端也只给收件方向这些入口）。
    final canReply = !isSendFolder;
    // spec §8.2：AI 建议的位置在**转发之后、星标之前** —— 回复/转发是
    // 「读完就做的事」，星标/⋯是「标记」，AI 建议是「我拿不准该怎么办，
    // 你帮我想想」。它紧挨着回复/转发（两者有重叠：AI 大概率也会建议答复）。
    //
    // 条件读的是 `ref.watch` —— 这里在 `build` 里，watch 合法；设置页里
    // 打开开关之后这一颗会自己出现，不需要重建页面。
    //
    // `channelConfigured` 走 `ref.read`：托管通道在 `runApp` 之前注册、之后
    // 不再变（`ai_providers.dart` 的注释），没有可 watch 的信号。它是审计 D1
    // 的修法 —— 真订阅用户从没配过 Key 时，这颗入口也必须画出来。
    final canSuggest = SuggestFlow.visible(
      row,
      ref.watch(aiSettingsProvider).value,
      channelAvailable: SuggestFlow.channelConfigured(ref),
    );
    // 星标：实例根本没有 `/star/list`（老版本/别的分支）时不要给一个
    // 点了必然报错的按钮。探测结果是 `unknown`（还没探到）时按可用算 ——
    // 宁可多显示一个按钮，也不要在一个正常的实例上把它藏起来。
    final canStar =
        ref.watch(capabilitiesProvider(widget.profileId)).value?.starEnabled ??
            true;

    return <Widget>[
      if (syncing)
        // 32×32 而不是贴着图标的大小：`PaneHeader` 那一行的高度被
        // `kPaneHeaderHeight` 钉死，一个太小的热区点不中，而太大的话
        // 窄屏 `AppBar` 里的按钮会跟着变高。32 与 `IconButton` 的默认
        // 热区一致。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Tooltip(
            message: l10n.syncingThisMail,
            child: InkResponse(
              radius: 18,
              onTap: _syncing ? null : _ensureSynced,
              child: const SizedBox(
                width: 32,
                height: 32,
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          ),
        ),
      // 「回复」**任何宽度都留在顶栏**：读一封来信之后接下来最可能做的一件事
      // 就是回它，藏进菜单等于多一次点击。下面三颗才随宽度决定要不要折叠。
      if (canReply)
        IconButton(
          tooltip: l10n.reply,
          icon: const Icon(Icons.reply),
          onPressed: () => _compose(ComposeMode.reply, row),
        ),
      if (!collapse && canReply) ...<Widget>[
        IconButton(
          tooltip: l10n.replyAll,
          icon: const Icon(Icons.reply_all),
          onPressed: () => _compose(ComposeMode.replyAll, row),
        ),
        IconButton(
          tooltip: l10n.forward,
          icon: const Icon(Icons.forward),
          onPressed: () => _compose(ComposeMode.forward, row),
        ),
      ],
      // **不能塞进下面那个 `PopupMenuButton` 的固定项里**（宽屏时）：
      // 那里面两项（标已读 / 删除）是无条件画出来的，而 AI 建议有三个条件
      // （spec §8.3）。窄屏收进菜单时也照条件来，不画一个点了没反应的项。
      if (!collapse && canSuggest)
        IconButton(
          key: const ValueKey('ai-suggest-detail'),
          tooltip: l10n.aiSuggest,
          icon: const Icon(Icons.auto_awesome_outlined),
          onPressed: () =>
              SuggestFlow.open(context, ref, row: row, onDeleted: _afterDelete),
        ),
      if (canStar)
        IconButton(
          tooltip: row.isStarred ? l10n.unstar : l10n.star,
          icon: Icon(row.isStarred ? Icons.star : Icons.star_border),
          onPressed: () => _toggleStar(row),
        ),
      PopupMenuButton<String>(
        onSelected: (value) => _onMenu(value, row),
        itemBuilder: (context) => <PopupMenuEntry<String>>[
          // 窄屏才有的三项：顺序与宽屏顶栏从左到右一致（回、转、想），
          // 用户从上往下扫的那条视线与宽屏是同一个。
          if (collapse && canReply) ...<PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'replyAll',
              child: Text(l10n.replyAll),
            ),
            PopupMenuItem<String>(
              value: 'forward',
              child: Text(l10n.forward),
            ),
          ],
          if (collapse && canSuggest)
            PopupMenuItem<String>(
              value: 'suggest',
              child: Text(l10n.aiSuggest),
            ),
          // 上面那一组是「对这一封做什么」，下面两项是「怎么处置这一行」——
          // 两类混在一起排下来，用户会误以为删除与回复同一档。
          if (collapse && (canReply || canSuggest))
            const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: 'unread',
            child: Text(row.isUnread ? l10n.markRead : l10n.markUnread),
          ),
          PopupMenuItem<String>(
            value: 'delete',
            child: Text(l10n.delete),
          ),
        ],
      ),
    ];
  }

  /// 正文。整页形态是 `Scaffold.body`，内嵌形态是右栏的 `Expanded`。
  ///
  /// 两个形态都**占满可用宽度**（需求二：不封顶）。原来的 `readerMaxWidth`
  /// 封顶在分栏右栏上尤其难受 —— 右栏的宽度本来就是用户拖出来的，
  /// 再自作主张留一道留白等于把那个拖动条作废。
  ///
  /// ## 外面这层 `SelectionArea`（为什么包 `ListView` 而不是只包正文）
  ///
  /// 套在 `ListView` **外面**不是审美，是能力差异：
  ///
  /// - `SelectableRegion` 把 `SelectionContainer(registrar: this, …)` 放在
  ///   自己 child 的外面（`selectable_region.dart:1953`），注册器是**往下**通过
  ///   InheritedWidget 找的；
  /// - `Scrollable` 只在 `SelectionContainer.maybeOf(context)` 非空时才装
  ///   `_ScrollableSelectionHandler`（`scrollable.dart:1063-1071`），后者带一个
  ///   `EdgeDraggingAutoScroller`（`:1156-1188`）—— 也就是**拖到视口边缘会自动
  ///   滚**、滚出已构建范围的选择**不被回收**；而且 `Cmd+A` 的范围是「用户看到
  ///   的这一封」（主题 / 收发人 / 时间 / 正文 / 附件），不是只有正文。
  ///
  /// 包在 `HtmlBodyView` 里面的话，`Scrollable` 就跑到了注册器**上面**，
  /// 上面两条一起没有。
  ///
  /// ## 它不会弄坏图片、链接、按钮、chip、滚轮
  ///
  /// 三条底层机制：命中测试里**后代排在祖先前面**（`rendering/box.dart:2951`，
  /// 而 `SelectableRegion` 用的是 `translucent`，`selectable_region.dart:1978`）；
  /// 手势竞技场 sweep 时给**先进来的那个**（`gestures/arena.dart:169` 原话
  /// "First member wins"）；而 `Scrollable` 的 `dragDevices` 默认**不含鼠标**
  /// （`scroll_configuration.dart:28-37`，注释明说给鼠标放开会让选区
  /// "difficult or impossible"）—— 所以鼠标拖动从来不归滚动管，滚轮是
  /// `PointerScrollEvent`、走 pointer signal、不经 arena，照样滚。
  ///
  /// ## 一条只能真机看的风险，先接受
  ///
  /// 鼠标按下与抬起之间抖动**超过 2 逻辑像素**时，选区那个
  /// `TapAndPanGestureRecognizer` 会 `resolve(accepted)`
  /// （`tap_and_drag.dart:1206`），于是这一次点击被选区抢走，**图片预览 /
  /// 链接不再打开**。阈值 `computePanSlop(mouse) = kPrecisePointerPanSlop = 2.0`
  /// （`events.dart:2566`、`constants.dart:102`），而且它对鼠标**不读**
  /// `DeviceGestureSettings` —— 没有调大的旋钮。`tester.tap` 不发 move，
  /// 所以测试永远是绿的，这条只有真人手抖着点才验得到。
  ///
  /// 先接受：macOS 原生文本视图同样是「拖 2px 就是选字」。
  ///
  /// ## 键盘焦点：打开这一封就要在选区上
  ///
  /// 见 [_focusReaderOnce]：`Cmd/Ctrl+A` 与 `Cmd/Ctrl+C` 的执行者挂在
  /// `SelectableRegion` 的 `Actions` 上，焦点不在选区里就静默失效。
  /// `SelectionArea` 只有在鼠标点过之后才持有焦点，而打开一封邮件的那一下
  /// 点的是**列表里的行** —— 所以必须由页面自己把这颗焦点交过去。
  Widget _body(
    MailRow row,
    String ossBase,
    List<MailAttachment> attachments,
    Color ac,
  ) {
    // 外联资源域名白名单：设置页与 Banner 上的「始终允许」都写这一份，
    // 打开邮件时按它决定哪些外链图直接加载。这里 `watch` 是合法的 ——
    // `_body` 只在 build 里被调用。
    final allowedHosts = ref.watch(externalAllowedHostsProvider);
    // 拉起焦点是 build 里的副作用，但 `_focusReaderOnce` 自己按
    // `(profileId, emailId)` 去重，一封信只排一次。
    _focusReaderOnce(row);
    return SelectionArea(
      // 键盘焦点归页面持有（见 [_focusReaderOnce]）；右键 / 单击时
      // `SelectableRegion` 会把焦点收进同一个节点，两者不打架。
      focusNode: _readerFocus,
      // 右键菜单：**不能再套一个 `GestureDetector(onSecondaryTapUp:)`** ——
      // macOS 上 `SelectableRegion` 的右键是 `onSecondaryTapDown`
      // （`selectable_region.dart:455`），它不看竞技场结果，一定会
      // `_selectWordAt()` + `_showToolbar(location:)`（`:1046-1099`）。
      // 再挂一个就是两个菜单同时出现。
      //
      // 两个 context 各有各的用：`menuContext`（builder 传进来的那个）只用来
      // 取 l10n / 定位菜单，它在菜单那条 overlay entry 里；**动作要用页面
      // 自己的 `context`** —— entry 一摘 `menuContext.mounted` 就是 false，
      // 而 `MailActionRunner` 的删除路径在确认框之后正要看这一位
      // （详见 `mail_detail_context_menu.dart` 上那段注释）。
      contextMenuBuilder: (menuContext, state) => mailDetailContextMenu(
        menuContext,
        context,
        ref,
        row,
        state,
        onDeleted: _afterDelete,
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          // 实例色带：从聚合/星标列表跳进来的详情看不出这是谁的邮件。
          Container(height: 3, color: ac, width: 40),
          const SizedBox(height: 12),
          Text(
            row.displaySubject,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          // 头部（发件人 / 时间 / 收件人详情）。**整块都在 `SelectionArea`
          // 里**：地址要能选中复制，`Cmd+A` 的作用范围也把头部算进去
          // （`_body` 上面那段注释说的「用户看到的这一封」）。
          _MailHeader(row: row),
          if (row.bounceMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            _Banner(
              icon: Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
              text: row.bounceMessage!,
            ),
          ],
          if (row.status == MailStatus.delayed)
            const _SimpleBanner(
              icon: Icons.schedule,
              text: '这封邮件曾被延迟投递',
            ),
          if (row.status == MailStatus.complained)
            const _SimpleBanner(
              icon: Icons.report_problem_outlined,
              text: '收件人把这封邮件标记为垃圾邮件',
            ),
          // 验证码：Workers AI 已经识别出来了，直接给个复制按钮 ——
          // 这是这个客户端最常用的一个动作。
          if (row.code.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _CodeCard(code: row.code),
          ],
          // 头部与正文之间的 hairline。
          //
          // 原来这里只有一条 `Divider`，但上面紧挨着的是时间那一行，而正文
          // 第一行的字号与时间不同 —— 留白不够时分界是「读出来的」而不是
          // 「看出来的」。现在头部是一个带头像的区块（展开收件人详情还会更高），
          // 不给一条线的话，正文第一段会被当成头部的最后一行。
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          if (row.hasFullBody)
            HtmlBodyView(
              // 只有 `text/plain` 部分的邮件（GitHub 通知、很多站内信）在
              // 服务端 `content` 就是空串 —— 前端 Web 端为此有一条 `<pre>`
              // 兜底，这里对齐它，否则一封明明有正文的邮件会显示「（这封邮件
              // 没有正文）」。见 [_plainTextHtml]。
              html: row.content?.trim().isNotEmpty ?? false
                  ? row.content!
                  : _plainTextHtml(row.text),
              ossBase: ossBase,
              allowedHosts: allowedHosts,
              // Banner 组头的「始终允许」：把域名写进白名单，下一帧就按
              // 新名单判定（HtmlBodyView 会换 key 重新解析正文）。
              onAllowHost: (host) => ref
                  .read(externalAllowedHostsProvider.notifier)
                  .add(host),
              onTapImage: (url) => _previewImage(url),
            )
          else
            _SummaryFallback(row: row),
          if (attachments.isNotEmpty) ...<Widget>[
            const SizedBox(height: 24),
            _AttachmentPanel(
              attachments: attachments,
              ossBase: ossBase,
              onOpen: _openAttachment,
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 动作

  /// 打开写邮件页（回复 / 转发）。
  ///
  /// 把**当前这一行**一起递过去：详情页里的 `row` 已经是 `full=1` 的完整行
  /// （打开时 `openMail` 会确保补齐），引用块直接用得上，不必再跑一趟网络。
  void _compose(ComposeMode mode, MailRow row) {
    // 拼地址收在 [openMailCompose] 里：`Cmd+R` / `Cmd+Shift+F` 走同一个函数。
    openMailCompose(
      context,
      mode: mode,
      profileId: row.profileId.isEmpty ? widget.profileId : row.profileId,
      emailId: row.emailId,
    );
  }

  Future<void> _toggleStar(MailRow row) async {
    try {
      await ref
          .read(emailRepositoryProvider)
          .setStar(_ref, starred: !row.isStarred);
    } catch (e) {
      _show(e.toString());
    }
  }

  Future<void> _onMenu(String value, MailRow row) async {
    switch (value) {
      // 窄屏 ⋯ 菜单里的三项（宽屏它们是顶栏上直出的图标）。动作与顶栏那三颗
      // **同一个函数**（[_compose] / `SuggestFlow.open`），不在这里另拼一份
      // 地址与模式 —— 同一个动作两个入口各写一遍，正是本仓库反复吃过的那类
      // bug（`_afterDelete` 上面那段注释记着）。
      case 'replyAll':
        _compose(ComposeMode.replyAll, row);
      case 'forward':
        _compose(ComposeMode.forward, row);
      case 'suggest':
        SuggestFlow.open(context, ref, row: row, onDeleted: _afterDelete);
      case 'unread':
        // 服务端**只支持标已读**（`PUT /email/read` 写死 `unread = READ`），
        // 所以「标未读」只能改本地，下次列表刷新会被服务端盖回来。
        //
        // `read` 是**目标**状态，不是当前状态 —— 直接给 `row.isUnread`
        // （当前未读 → 标成已读）。这里原来写的是 `!row.isUnread`，等于把
        // 两颗菜单项的语义对调了：未读的那封点「标记已读」什么都没发生，
        // 已读的那封点「标记未读」反而又标回已读。`syncServer` 也不用传：
        // `markRead` 内部只对「标已读」发请求。
        try {
          await ref.read(emailRepositoryProvider).markRead(
                <MailRef>[_ref],
                read: row.isUnread,
              );
        } catch (e) {
          _show(e.toString());
        }
      case 'delete':
        final ok = await _confirm('删除这封邮件？');
        if (!ok) return;
        try {
          await ref.read(emailRepositoryProvider).delete(<MailRef>[_ref]);
          if (!mounted) return;
          _afterDelete();
        } catch (e) {
          _show(e.toString());
        }
    }
  }

  /// 这一封被删掉之后的收尾：**内嵌时右栏没有可 pop 的东西**，让宿主把
  /// 选中清掉、回到空态；整页形态则 pop 回列表。
  ///
  /// 抽成一个方法而不是在 `_onMenu` 里就地写：**AI 建议面板那条路也要它**。
  /// `MailActionRunner._delete` 是「模型建议删除 → 用户点它」的唯一执行处，
  /// 它的收尾是回调 `onDeleted`；详情页这颗 AI 图标从前**没传**这个回调
  /// （`SuggestFlow.open(context, ref, row: row)`），于是从那颗图标删掉之后
  /// `mailDetailProvider` 推出 `null`，本页落进 `row == null` 那一支 ——
  /// 屏幕上是一个**永远转下去**的圈（内嵌与整页两条都是）。
  ///
  /// 同一个动作两个入口行为不一样，正是本仓库反复吃过的那一类 bug。
  void _afterDelete() {
    // 这一封没了，面板状态也该跟着走 —— 否则「开着的面板」会挂在一个已经不
    // 存在的邮件上，下一封同号邮件（本地自增/服务端回收时可能复用）一打开
    // 就顶着一个旧面板。
    ref.read(suggestDockStateProvider.notifier).close();
    if (widget.embedded) {
      widget.onClose?.call();
    } else if (context.mounted) {
      context.pop();
    }
  }

  /// 附件：弹出动作面板（预览 / 打开 / 分享 / 另存为）。
  ///
  /// 早先这里是「直接丢给系统浏览器」，问题是内嵌图之外的普通附件在浏览器里
  /// 往往只会**下载**而不是打开（content-disposition 是 attachment），
  /// 用户点了没反应。改成面板之后每个动作都是明确的。
  Future<void> _openAttachment(MailAttachment attachment) =>
      showAttachmentActions(
        context: context,
        ref: ref,
        attachment: attachment,
        profileId: widget.profileId,
      );

  void _previewImage(String url) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImageViewerScreen(url: url),
      ),
    );
  }

  Future<bool> _confirm(String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(AppLocalizations.of(context).confirm),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 摘要模式下的正文。
///
/// `full=0` 的响应里 `text` 被截断到 300 字符，`content` 只在没有 `text`
/// 时才给。这里如实说明「这是摘要」，而不是把截断的正文当成全文展示 ——
/// 用户会以为邮件就是这样的。
class _SummaryFallback extends StatelessWidget {
  const _SummaryFallback({required this.row});

  final MailRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = row.preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (preview.isNotEmpty)
          Text(preview, style: theme.textTheme.bodyMedium)
        else
          Text(
            '（这封邮件没有正文）',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Icon(Icons.info_outline, size: 14, color: theme.colorScheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '当前只是摘要。该实例可能不支持完整正文，或正文还没拉取完成。',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 这一封的「收件人」列表。
///
/// 服务端把 To 存在 `recipient`（JSON 字符串）里，但摘要行与很老的数据可能
/// 只有 `toEmail` + `toName` 那一对 —— 两条都认，否则用户点开「收件人详情」
/// 会看到一行空的。
List<Recipient> _toRecipients(MailRow row) {
  if (row.recipients.isNotEmpty) return row.recipients;
  final address = row.toEmail.trim();
  if (address.isEmpty) return const <Recipient>[];
  return <Recipient>[Recipient(address: address, name: row.toName)];
}

/// 详情页头部：谁发的（头像 / 姓名 / 地址 / 时间）+ 收件人详情。
///
/// 有状态：收件人详情默认收起，点一下展开。**整块仍在 `SelectionArea` 之内**
/// —— 头部这些地址同样要能选中复制，`Cmd+A` 的作用范围也把头部算进去
/// （`_body` 上面那段注释说的「用户看到的这一封」）。
///
/// 头像用 [AvatarColors]（按发件地址哈希取色）而不是实例色：实例已经由上方
/// 那条色带表达了，而「这封是谁发的」与「这封来自哪个实例」是两件事 —— 那正是
/// `AvatarColors` 与 `InstanceColors` 分成两个类的原因，混用会让它们在聚合
/// 视图里看起来像同一个信息。
class _MailHeader extends StatefulWidget {
  const _MailHeader({required this.row});

  final MailRow row;

  @override
  State<_MailHeader> createState() => _MailHeaderState();
}

class _MailHeaderState extends State<_MailHeader> {
  bool _expanded = false;

  /// 换一封邮件时收起。
  ///
  /// 内嵌形态换邮件时本 widget 会被宿主重挂（`ValueKey`），但**不能只靠
  /// 那个**：上一封展开了收件人详情、切到下一封还开着，用户会以为这封信的
  /// 抄送名单多出来几个人。与 `MailDetailScreen.didUpdateWidget` 里那段是
  /// 同一道保险。
  @override
  void didUpdateWidget(_MailHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.row.emailId != widget.row.emailId ||
        oldWidget.row.profileId != widget.row.profileId) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final row = widget.row;

    final name = row.name.trim();
    final address = row.sendEmail.trim();
    // 没有显示名就用地址顶（老数据里 `name` 常是空串）。
    final title = name.isEmpty ? address : name;
    final muted = theme.colorScheme.onSurfaceVariant;
    final time = TimeUtils.formatDetailTime(row.createTime);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _SenderAvatar(
              key: const ValueKey<String>('detail-sender-avatar'),
              address: address,
              label: title,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: <Widget>[
                      // `EmailAddressText` 把地址的本地部分加重、域名退回去
                      // —— 与列表页同一个约定，扫视时先认「谁」。
                      Flexible(
                        child: EmailAddressText(
                          address,
                          style:
                              theme.textTheme.bodySmall?.copyWith(color: muted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (address.isNotEmpty) _CopyAddress(address: address),
                    ],
                  ),
                ],
              ),
            ),
            // 时间右对齐、与姓名顶端起：它是头部第三重要的信息，扫视时先看
            // 「谁」再看「什么时候」。放不进一行时它被挤到的最小宽度是
            // 自己的文字宽（`Text` 不参与 `Expanded`），不会变成省略号。
            if (time.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  time,
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
            ],
          ],
        ),
        // 没有收件人 / 抄送 / 密送可看时**不画这一行**：一个点开是空的展开
        // 箭头比没有更糟（用户会以为内容还在加载）。草稿与某些老实例的行就是
        // 这种形态。
        if (_hasRecipients) ...<Widget>[
          const SizedBox(height: 6),
          _disclosure(context, l10n, _toRecipients(row), muted),
        ],
      ],
    );
  }

  bool get _hasRecipients =>
      widget.row.recipients.isNotEmpty ||
      widget.row.toEmail.trim().isNotEmpty ||
      widget.row.cc.isNotEmpty ||
      widget.row.bcc.isNotEmpty;

  /// 收件人详情的渐进披露控件。
  ///
  /// **默认收起是刻意的**：一封信绝大多数时候只有一个收件人，把「发件人 /
  /// 收件人 / 抄送 / 密送」四行全摊开，等于用四行地址把正文挤出首屏，而其中
  /// 三行多数时候是空的。收起时只留一行「收件人」摘要（超出省略），需要的人
  /// 点一下就能看全 —— 真实需求往往是「这封抄送了谁」，一次点击不贵。
  ///
  /// 展开控件用 [InkWell] 而不是 `TextButton` 那类按钮：按钮会把自己做成一块
  /// Material，既抢走 `SelectionArea` 的拖选手势（点击与拖动在同一次竞技场里
  /// 谁赢随平台而变），也让这一行看起来比标题还重。展开后的地址仍在
  /// `SelectionArea` 里，**可选、可复制**（`Ctrl/Cmd+C` 走选区那条路）。
  Widget _disclosure(
    BuildContext context,
    AppLocalizations l10n,
    List<Recipient> to,
    Color muted,
  ) {
    final theme = Theme.of(context);
    final row = widget.row;
    final toText =
        to.map((r) => r.address).where((a) => a.isNotEmpty).join(', ');
    // To 缺失但还有抄送/密送时（少见：只密送给某个人的那种），摘要退成
    // 「显示详情」—— 不能拿发件人地址顶上，那一行会被读成「收件人是他」。
    final summary =
        toText.isEmpty ? l10n.detailShowDetails : '${l10n.detailTo}  $toText';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Tooltip(
            message:
                _expanded ? l10n.detailHideDetails : l10n.detailShowDetails,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _expanded ? l10n.detailHideDetails : summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: muted,
                  ),
                ],
              ),
            ),
          ),
        ),
        // 展开后**只在有内容时才画那一行**：空的「抄送」行比没有这一行更让人
        // 困惑（用户会以为加载坏了）。
        if (_expanded) ...<Widget>[
          const SizedBox(height: 2),
          _AddressLine(
            label: l10n.detailFrom,
            value: row.name.trim().isEmpty
                ? row.sendEmail
                : '${row.name.trim()} <${row.sendEmail}>',
          ),
          if (to.isNotEmpty)
            _AddressLine(
              label: l10n.detailTo,
              value: to.map((r) => r.display).join(', '),
            ),
          if (row.cc.isNotEmpty)
            _AddressLine(
              label: l10n.detailCc,
              value: row.cc.map((r) => r.display).join(', '),
            ),
          if (row.bcc.isNotEmpty)
            _AddressLine(
              label: l10n.detailBcc,
              value: row.bcc.map((r) => r.display).join(', '),
            ),
        ],
      ],
    );
  }
}

/// 发件人圆形头像：深色底 + 首字母。
///
/// 取色走 [AvatarColors.of]（按地址哈希）——「同一个人永远是同一个颜色」，
/// 跨实例、跨文件夹都一样。
class _SenderAvatar extends StatelessWidget {
  const _SenderAvatar({
    super.key,
    required this.address,
    required this.label,
  });

  final String address;

  /// 取首字母的那段文字（优先显示名）。
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AvatarColors.of(address),
        shape: BoxShape.circle,
      ),
      // 用 [AvatarColors.initial] 而不是 `label[0]`：emoji / 组合字符按
      // `characters` 切，取半个字符会画出一个方块。
      child: Text(
        AvatarColors.initial(label),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 发件人地址旁的小号「复制」热区。
///
/// 用 [InkWell] 而不是 `IconButton`：后者默认 48×48 的热区会把地址这一行
/// 撑高（头部本来就只有两行字）。**它不抢选区手势**：无位移的点击归它，
/// 带位移的拖动归 `SelectionArea`（两者在同一次竞技场里，拖动的那一方赢）。
class _CopyAddress extends StatelessWidget {
  const _CopyAddress({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: AppLocalizations.of(context).copySenderAddress,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: address));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).copied)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.copy_rounded,
            size: 13,
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}

/// 「标签 + 地址」一行（收件人详情里用）。
///
/// 标签盒定宽：四行的地址左缘才会对齐 —— 中文标签是 2~3 个字、英文是
/// 2~4 个字母，不定宽的话每一行的地址都错开一点，看起来像没排过版。
class _AddressLine extends StatelessWidget {
  const _AddressLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: EmailAddressText(
              value,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 验证码卡片（一键复制）。
class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: <Widget>[
            Icon(Icons.password, size: 18,
                color: theme.colorScheme.onPrimaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                code,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: AppLocalizations.of(context).copy,
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(AppLocalizations.of(context).copied)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SimpleBanner extends StatelessWidget {
  const _SimpleBanner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Banner(
      icon: icon,
      color: theme.colorScheme.tertiary,
      text: text,
    );
  }
}

/// 附件面板。
class _AttachmentPanel extends StatelessWidget {
  const _AttachmentPanel({
    required this.attachments,
    required this.ossBase,
    required this.onOpen,
  });

  final List<MailAttachment> attachments;
  final String ossBase;
  final void Function(MailAttachment attachment) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // `attList` 里理论上只有普通附件（`type=0`），但内嵌图在部分分支上会混进来
    // —— 它们不该出现在附件面板里。
    final visible = attachments.where((a) => a.isDownloadable).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.attach_file, size: 16,
                color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              '${visible.length} 个附件',
              style: theme.textTheme.labelMedium,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final attachment in visible)
              ActionChip(
                avatar: Icon(iconOf(attachment), size: 16),
                label: Text(
                  '${attachment.displayName}'
                  '${attachment.size > 0 ? '  ${formatAttachmentSize(attachment.size)}' : ''}',
                ),
                onPressed: () => onOpen(attachment),
              ),
          ],
        ),
      ],
    );
  }
}

/// 字节数显示。
String formatBytes(int bytes) => formatAttachmentSize(bytes);

/// 纯文本正文的最小 HTML 包装（服务端 `content` 为空时的读信兜底）。
///
/// **为什么要有它**：只有 `text/plain` 部分的邮件（GitHub 通知、很多站内信）
/// 在服务端 `content` 就是空串（`postal-mime` 只给 `text`），而详情页只认
/// `content` —— 一封明明有正文的邮件会显示「（这封邮件没有正文）」。
/// Web 端为此有一条 `<pre v-else class="email-text">` 兜底
/// （`mail-vue/src/views/content/index.vue`），这里对齐它。
///
/// 形状与 `ComposeHtml.originalBody` 的兜底、以及 worker 现在写入 `content`
/// 的形状一致：`white-space: pre-wrap` 保住换行、`word-break: break-word`
/// 让长 URL 折行、`font-family: inherit` 避免掉进 fwfh `tag_pre` 的等宽字体。
///
/// **必须先转义**：`text` 与 `content` 一样是不可信输入，裸接进 HTML 再交给
/// `HtmlWidget` 就等于 XSS。只转 `& < >` —— 与 worker 侧同一个形状。
String _plainTextHtml(String? text) {
  final raw = text ?? '';
  if (raw.trim().isEmpty) return '';
  final escaped = raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return '<pre style="font-family: inherit; word-break: break-word; '
      'white-space: pre-wrap; margin: 0">$escaped</pre>';
}
