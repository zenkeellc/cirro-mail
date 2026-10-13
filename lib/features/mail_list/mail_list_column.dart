import 'package:flutter/material.dart';

import '../../data/models/mail_ref.dart';
import '../../data/models/mail_row.dart';
import '../../providers/profile_providers.dart';
import 'mail_list_view.dart';
import 'mail_panes.dart';

/// 窄屏的列表页 / 宽屏的左栏，共用这一个主体。
///
/// 抽出来的理由是 **草稿箱与发件箱也要长得一样**（spec §2.4：「外壳一致」）。
/// 复制一份 `Column(头 + MailListView)` 到两个新页面里，它们就会各自漂移
/// —— 加了「还有 N 封未同步」的占位行之后只改了收件箱那一份，是必然会发生的
/// 事。
class MailListColumn extends StatelessWidget {
  const MailListColumn({
    super.key,
    required this.query,
    required this.header,
    this.listNode,
    this.headerActions = const <Widget>[],
    this.emptyHint,
    this.selected,
    this.onOpen,
    this.multiSelect = false,
    this.showInstanceBand = false,
    this.hintBanner,
  });

  final MailListQuery query;

  /// 这一页是哪张列表（实例 id 或 `all`）—— 只透传给 [MailListView]，
  /// 供它拼详情地址时决定路径段用哪个节点。
  final String? listNode;

  /// 头上那个主体（收件箱是「标题 + 在看哪几个邮箱」）。
  final Widget header;

  final List<Widget> headerActions;

  final String? emptyHint;
  final MailRef? selected;
  final void Function(MailRow row)? onOpen;

  /// 这一块列表接不接多选。见 [MailListView.multiSelect]。
  final bool multiSelect;

  final bool showInstanceBand;

  /// 头下面那条常驻提示（缺 `account:query` 权限、草稿不同步云端…）。
  final Widget? hintBanner;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        PaneHeader(actions: headerActions, child: header),
        ?hintBanner,
        Expanded(
          child: MailListView(
            query: query,
            listNode: listNode,
            emptyHint: emptyHint,
            selected: selected,
            onOpen: onOpen,
            multiSelect: multiSelect,
            showInstanceBand: showInstanceBand,
          ),
        ),
      ],
    );
  }
}
