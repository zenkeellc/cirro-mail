import 'dart:async';

import 'package:cirro_mail_ext/cirro_mail_ext.dart';

/// 本地邮件变更的**发布点**。
///
/// ## 为什么不直接用 drift 的 `tableUpdates`
///
/// 它当然更省事，但三件事上对不上：
/// - 它只说「某张表变了」，**不说是哪几行**，而增量重建索引要的正是那几行；
/// - 区分写入/删除靠 `kind`，而本地有几条删除走的是原生 SQL，那里 `kind`
///   是 `null`；
/// - `DriftNativeOptions.shareAcrossIsolates` 默认为 false —— **本 isolate 的
///   drift 句柄看不到另一个 isolate 的写入**，而本项目前台与 Android 后台各开
///   一个连接。
///
/// 所以写路径上**显式发布**。代价是「新增一条写 `mails` 的路径时必须记得回来
/// 加发布」—— 由 `test/mail_store_publish_test.dart` 逐条钉住现存的那几条
/// （写入两条、删除三条）。
///
/// ## 为什么是库级单例而不是 provider
///
/// `MailDao` 是 drift 生成的访问器，它拿不到 `ProviderScope`；而发布点必须贴着
/// 写语句，不能上移到仓储层（仓储层不是唯一写入方 —— 后台 isolate 直接调 DAO）。
/// 一个库级 `StreamController.broadcast()` 是这里最直白的形状。
///
/// 监听者是 **broadcast** 语义：没有监听者时事件直接丢弃，不留缓冲 ——
/// 公开版从头到尾没有监听者，不该为它留任何东西。
final StreamController<MailStoreEvent> _changes =
    StreamController<MailStoreEvent>.broadcast();

/// 订阅本地变更。语义见 [MailStore.changes]（**冷订阅收不到历史**）。
Stream<MailStoreEvent> mailStoreChanges() => _changes.stream;

void _publish(MailStoreEvent event) {
  if (_changes.isClosed) return;
  _changes.add(event);
}

/// 一批行被写入或更新。
void publishMailsUpserted(String profileId, Iterable<int> emailIds) {
  final ids = emailIds.toList(growable: false);
  if (ids.isEmpty) return;
  _publish(MailUpserted(profileId, ids));
}

/// 一批行被删掉了。
void publishMailsDeleted(String profileId, Iterable<int> emailIds) {
  final ids = emailIds.toList(growable: false);
  if (ids.isEmpty) return;
  _publish(MailDeleted(profileId, ids));
}

/// 整个实例的本地邮件被清空了。
void publishMailStoreReset(String profileId) =>
    _publish(MailStoreReset(profileId));
