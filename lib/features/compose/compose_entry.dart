import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/core_providers.dart';
import '../../providers/mail_providers.dart';
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

  @override
  ConsumerState<ComposeEntry> createState() => _ComposeEntryState();
}

class _ComposeEntryState extends ConsumerState<ComposeEntry> {
  MailRow? _row;
  bool _resolving = false;
  bool _failed = false;

  MailRef get _ref =>
      MailRef(profileId: widget.profileId, emailId: widget.emailId);

  @override
  void initState() {
    super.initState();
    _row = widget.initial;
    // 回复/转发才有正文要补；「写邮件」直接进。
    final needsFull = widget.emailId > 0 &&
        widget.profileId.isNotEmpty &&
        (_row == null || !_row!.hasFullBody);
    if (needsFull) {
      _resolving = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureFull());
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
  Widget build(BuildContext context) {
    if (_resolving) {
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
      args: ComposeArgs(
        profileId: widget.profileId.isEmpty ? null : widget.profileId,
        accountId: widget.accountId,
        draftId: widget.draftId,
        mode: widget.mode,
        mail: _row,
      ),
    );
  }
}
