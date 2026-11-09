import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/mail_providers.dart';
import '../../providers/profile_providers.dart';
import 'compose_controller.dart';
import 'compose_draft.dart';
import 'compose_screen.dart';

/// 「回复 / 转发」这条路由的入口。
///
/// 为什么要单独一层（而不是在路由表里直接 `ComposeScreen(args: …)`）：
/// **引用原文必须是完整正文**。列表行是 `full=0` 的摘要（`text` 被截到
/// 300 字符，`content` 为 null），直接拿它拼引用块，用户会转发出一封只有
/// 前 300 个字的信 —— 而且他不会立刻发现。
///
/// 所以这里先把正文补齐再交给 [ComposeScreen]；[initial] 是详情页顺手递过来
/// 的那一行（已经是 `full=1` 的话就不必再跑一趟）。
class ComposeEntry extends ConsumerStatefulWidget {
  const ComposeEntry({
    super.key,
    required this.mode,
    this.profileId = '',
    this.accountId = 0,
    this.draftId = 0,
    this.emailId = 0,
    this.initial,
    this.from,
  });

  final ComposeMode mode;

  /// 空 = 用当前实例（普通「写邮件」）。
  final String profileId;

  /// 从哪个邮箱进来的（0 = 没有指定，用第一个可用邮箱）。
  final int accountId;

  /// 接着写哪条草稿（0 = 新建）。
  final int draftId;

  /// 0 = 普通写邮件。
  final int emailId;

  final MailRow? initial;

  /// 进撰写页之前所在的地址（地址栏上的 `from` 参数）。
  ///
  /// 撰写页现在是「邮件」那一支的根路由，没有可 pop 的栈 —— 关闭时靠它
  /// 回到用户来的地方；没有就回草稿箱（见 `ComposeScreen._leave`）。
  final String? from;

  @override
  ConsumerState<ComposeEntry> createState() => _ComposeEntryState();
}

class _ComposeEntryState extends ConsumerState<ComposeEntry> {
  MailRow? _row;
  bool _resolving = false;
  bool _failed = false;

  /// 这一页真实的草稿行 id。
  ///
  /// 新建（路由没带 `draft`）时在 [initState] 之后补建一行再放行 —— 见
  /// [_ensureDraft]。没有行就没有「邮件撰写」里那一项，也没有重启恢复。
  int? _draftId;

  /// 建行失败（本地库坏了）。**不挡住写信**：退化成「没有草稿行」的旧行为，
  /// 至少这一封还能发出去；只是它不会出现在撰写列表里。
  bool _draftFailed = false;

  /// 左侧「邮件撰写」高亮用的「当前编辑的是哪一行」。
  ///
  /// 在 [initState] 里就抓住 notifier（而不是在 [dispose] 里 `ref.read`）：
  /// Riverpod 3 的 `ref` 依赖 `BuildContext`，元素 unmount 之后（`State.dispose`
  /// 正是那时）再读会抛 `Using "ref" when a widget is about to or has been
  /// unmounted is unsafe`。notifier 本身与页面生命周期无关，抓住它才能在
  /// `dispose` 里清掉自己发布的那一条。
  late final ActiveComposeDraft _activeDraft;

  MailRef get _ref =>
      MailRef(profileId: widget.profileId, emailId: widget.emailId);

  @override
  void initState() {
    super.initState();
    _activeDraft = ref.read(activeComposeDraftIdProvider.notifier);
    _row = widget.initial;
    _draftId = widget.draftId > 0 ? widget.draftId : null;
    if (widget.draftId > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _markOpen());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureDraft());
    }
    // 回复/转发才有正文要补；「写邮件」直接进。
    final needsFull = widget.emailId > 0 &&
        widget.profileId.isNotEmpty &&
        (_row == null || !_row!.hasFullBody);
    if (needsFull) {
      _resolving = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureFull());
    }
  }

  /// 已有的草稿：把它标成「打开中」（深链 / 从草稿箱点开都会走到）。
  Future<void> _markOpen() async {
    final id = _draftId;
    if (id == null || id <= 0) return;
    // 这一页就是「此刻正在编辑的那一行」—— 与写不写得进打开标记无关，
    // 所以先发布（左侧高亮不该因为一次本地库写失败就消失）。
    _activeDraft.publish(id);
    try {
      await ref.read(databaseProvider).localDao.markComposeOpen(id);
    } catch (_) {
      // 标记写不进去不挡写作：草稿内容照样能存，只是这一页不会出现在
      // 左侧「邮件撰写」里（重启后也不会恢复）。
    }
  }

  /// 新建的撰写页：先插一条草稿行 + 打开标记，再放行页面。
  ///
  /// 为什么不是「第一次保存时才建」：左侧「邮件撰写」要在用户点「写邮件」的
  /// **那一刻**就有这一项 —— 否则切走之后这一页在列表里不存在，回不去；
  /// 「重启恢复」也就无从谈起。空行由关闭时那句「什么都没写就删掉」收尾。
  Future<void> _ensureDraft() async {
    final profileId = widget.profileId.isNotEmpty
        ? widget.profileId
        : (ref.read(currentProfileIdProvider) ?? '');
    if (profileId.isEmpty) {
      // 一台实例都没有时写邮件入口本来就不出现（`ComposeAction`）；走到这里
      // 说明是从深链/旧地址进来的 —— 退回「无草稿行」的旧行为。
      if (mounted) setState(() => _draftFailed = true);
      return;
    }
    try {
      final dao = ref.read(databaseProvider).localDao;
      final id = await dao.createComposeDraft(profileId: profileId);
      if (!mounted) {
        // 建行这段时间里用户已经把页面关掉了：没人会写这一行，留着只会让
        // 下次启动在「邮件撰写」里冒出一页空白的「（无主题）」。删掉。
        // 用创建前就抓好的 dao —— 此刻 `ref` 可能已经不能用了。
        unawaited(dao.deleteDraft(id));
        return;
      }
      setState(() => _draftId = id);
      // 行建好了，页面正式成为「正在编辑的这一页」：左侧「邮件撰写」里
      // 刚出现的那一项要立刻亮起来（地址里没有 draft，侧栏推不出来）。
      _activeDraft.publish(id);
    } catch (_) {
      if (!mounted) return;
      setState(() => _draftFailed = true);
    }
  }

  /// 补齐正文。**失败不阻断** —— 拿不到完整原文时退回摘要虽然不理想，
  /// 但总比让用户连回复都打不开好；界面上会用引用块的内容如实反映它。
  Future<void> _ensureFull() async {
    try {
      await ref.read(emailRepositoryProvider).ensureFull(_ref);
      final row = ref.read(mailDetailProvider(_ref)).value;
      if (!mounted) return;
      setState(() {
        _row = row ?? _row;
        _resolving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _failed = true;
      });
    }
  }

  @override
  void dispose() {
    final id = _draftId;
    if (id != null && id > 0) {
      // **不能在 dispose 里直接改 provider**：此时 widget 树正在拆，Riverpod 会
      // 抛 `Tried to modify a provider while the widget tree was building`。
      // 排到这一帧收尾之后再清。
      //
      // 只清**自己那一条**：切到另一封撰写页时，新页面可能已经先把它自己的
      // id 发布出来了，无条件置 0 会把刚亮起来的那一项灭掉。
      final active = _activeDraft;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          active.clear(id);
        } catch (_) {
          // 整棵树/容器已经没了（退出 App、测试收尾）：一个纯 UI 状态没清掉
          // 没有任何后果，不该在这里抛。
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_resolving || (_draftId == null && !_draftFailed)) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_failed && _row == null) {
      final l10n = AppLocalizations.of(context);
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(l10n.mailUnavailable),
                const SizedBox(height: 16),
                // 打不开原邮件不该把用户挡在写邮件之外 —— 退化成「写一封
                // 新的」，主题与收件人由他自己填。
                FilledButton(
                  onPressed: () => setState(() {
                    _failed = false;
                    _row = null;
                  }),
                  child: Text(l10n.compose),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ComposeScreen(
      from: widget.from,
      // 本页的草稿行是「刚建出来的空行」：预填只在控制器内存里，首帧要把它
      // 落一次盘（见 `ComposeScreen._maybeMarkBaseline`），并且不要去读回
      // 那一行空草稿（见 `ComposeController._restoreDraft`）。
      freshPage: widget.draftId <= 0,
      args: ComposeArgs(
        profileId: widget.profileId.isEmpty ? null : widget.profileId,
        accountId: widget.accountId,
        draftId: _draftId ?? 0,
        mode: widget.mode,
        mail: _row,
        freshPage: widget.draftId <= 0,
      ),
    );
  }
}
