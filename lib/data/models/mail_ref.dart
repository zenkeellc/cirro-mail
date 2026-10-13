import 'package:flutter/foundation.dart';

/// 指向「某实例里的某封邮件」。
///
/// 多实例下最容易写错的地方是：从聚合列表里拿到一个裸 `emailId`，
/// 然后丢给**当前**实例的 ApiClient 去操作 —— 那会改到别的实例的同号邮件
/// （实例 A 的 emailId=42 和实例 B 的 emailId=42 是两封完全不同的信）。
///
/// 本仓库的约定：**所有写操作（已读/星标/删除/回复）都必须传 [MailRef]**，
/// 由 `EmailRepository` 用它去 `RuntimeRegistry` 找到正确的运行时。
@immutable
class MailRef {
  const MailRef({required this.profileId, required this.emailId});

  final String profileId;
  final int emailId;

  @override
  bool operator ==(Object other) =>
      other is MailRef && other.profileId == profileId && other.emailId == emailId;

  @override
  int get hashCode => Object.hash(profileId, emailId);

  @override
  String toString() => 'MailRef($profileId#$emailId)';
}
