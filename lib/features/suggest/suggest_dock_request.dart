import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/mail_ref.dart';

/// 「请详情页把 AI 建议停靠面板打开」的**一次性请求**。
///
/// 为什么需要它：宽屏下建议面板是**插在邮件预览下方**的（见
/// `mail_detail_screen.dart` 的 `_bodyWithSuggest`），而列表行菜单的入口在
/// 列表页手里 —— 列表页摸不到详情页的 `State`。于是让它发一次请求：
///
/// 1. 列表页先走它既有的 `_open(row)`（宽屏会折成 `?sel=`，右栏换成这封）；
/// 2. 再 `request(MailRef)`；
/// 3. 详情页在 `initState` 里用 `listenManual(..., fireImmediately: true)`
///    认领（先发请求、后挂载也不会漏），认领后立刻 `consume`。
///
/// **不落盘、不跨页面保留**：`consume` 掉之后就是 null。下一次请求是下一个
/// 独立的意图 —— 绝不能让一个旧请求在用户后来再打开同一封信时突然弹出面板。
class SuggestDockRequest extends Notifier<MailRef?> {
  @override
  MailRef? build() => null;

  /// 请求「下一帧在详情页打开这封邮件的建议面板」。
  void request(MailRef mail) => state = mail;

  /// 认领掉（只在还是同一个请求时清空，避免把更晚的一条请求误清）。
  void consume(MailRef mail) {
    if (state == mail) state = null;
  }
}

final NotifierProvider<SuggestDockRequest, MailRef?> suggestDockRequestProvider =
    NotifierProvider<SuggestDockRequest, MailRef?>(SuggestDockRequest.new);
