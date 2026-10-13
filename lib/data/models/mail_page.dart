import 'mail_ref.dart';
import 'mail_row.dart';

/// `GET /email/list` 与 `GET /star/list` 的响应。
///
/// 注意两者形状不同：
/// - `/email/list` → `{list, total, latestEmail}`
/// - `/star/list`  → 只有 `{list}`，**没有 total、没有 latestEmail**
///   （见 worker `service/star-service.js::list`），
///   所以 total/latestEmail 都要给默认值。
///
/// 另外 `/email/list` 的 `latestEmail` 是**过滤无关的**：它按 `type` 取该用户
/// （或该邮箱，取决于 `allReceive`）全局最新的一封，不受当前页游标影响
/// （见 `email-service.js` 的 `latestEmailQuery`）。这正是增量轮询要的游标。
class MailPage {
  const MailPage({
    this.list = const <MailRow>[],
    this.total,
    this.latestEmailId,
    this.hasMore,
    this.raw = const <String, dynamic>{},
  });

  final List<MailRow> list;

  /// 服务端返回的过滤后总数；`/star/list` 不返回。
  final int? total;

  /// 服务端给的最新邮件游标（`latestEmail.emailId`），用于增量轮询。
  final int? latestEmailId;

  /// 由调用方根据「本次返回条数 == size」推断；服务端不返回这个字段。
  final bool? hasMore;

  final Map<String, dynamic> raw;

  /// [profileId] 是必传的 —— 聚合列表里每一行都要知道自己是哪个实例的。
  factory MailPage.fromJson(
    Object? json, {
    required String profileId,
    String mailboxEmail = '',
    int? pageSize,
  }) {
    MailRow parse(Map<dynamic, dynamic> e) => MailRow.fromJson(
          e.cast<String, dynamic>(),
          profileId: profileId,
          mailboxEmail: mailboxEmail,
        );

    if (json is List) {
      // `/email/latest` 直接返回数组（≤20 条，仅收件）。
      return MailPage(
        list: json.whereType<Map>().map(parse).toList(growable: false),
      );
    }
    if (json is! Map) return const MailPage();

    final map = json.cast<String, dynamic>();
    final rawList = map['list'];
    final list = rawList is List
        ? rawList.whereType<Map>().map(parse).toList(growable: false)
        : const <MailRow>[];
    final latest = map['latestEmail'];

    return MailPage(
      list: list,
      total: _intOrNull(map['total']),
      latestEmailId:
          latest is Map ? _intOrNull(latest['emailId']) : null,
      hasMore: pageSize == null ? null : list.length >= pageSize,
      raw: map,
    );
  }

  bool get isEmpty => list.isEmpty;

  static int? _intOrNull(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw.toString());
  }

  /// 把一页行转成带 profileId 的引用列表（批量操作要用）。
  List<MailRef> get refs =>
      list.map((row) => MailRef(profileId: row.profileId, emailId: row.emailId)).toList(growable: false);
}
