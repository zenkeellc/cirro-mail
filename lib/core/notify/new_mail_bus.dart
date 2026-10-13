import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/mail_row.dart';

/// 新邮件的单一出口。
///
/// `SyncEngine` 每轮同步后会调它（**写库之后**），订阅者拿到的行已经是本地
/// 合并过的最终形态。两个订阅方：
/// - M5 的通知服务（前台本地通知 / 后台补拉）；
/// - UI 的「N 封新邮件」提示。
///
/// 刻意不做去重或节流：engine 已经保证「一轮只回调一次」，
/// 通知侧要按 `(profileId, emailId)` 幂等是自己的事（推送与轮询会撞车）。
class NewMailBus {
  NewMailBus();

  final StreamController<NewMailEvent> _controller =
      StreamController<NewMailEvent>.broadcast();

  Stream<NewMailEvent> get stream => _controller.stream;

  void emit(String profileId, List<MailRow> fresh) {
    if (fresh.isEmpty || _controller.isClosed) return;
    _controller.add(NewMailEvent(profileId: profileId, mails: fresh));
  }

  Future<void> dispose() => _controller.close();
}

/// 一次「本轮新到」的邮件。
///
/// [mails] 是**本轮**新写入的行（不是全部），可能包含发件方向的行 ——
/// 订阅方要自己按 `type` / `unread` 过滤。
@immutable
class NewMailEvent {
  const NewMailEvent({required this.profileId, required this.mails});

  final String profileId;
  final List<MailRow> mails;

  /// 其中未读的收件数（通知文案用）。
  int get unreadReceived =>
      mails.where((m) => m.isUnread && !m.isSend).length;

  @override
  String toString() => 'NewMailEvent($profileId, ${mails.length} 封)';
}
