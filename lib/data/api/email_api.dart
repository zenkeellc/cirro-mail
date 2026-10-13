import 'package:dio/dio.dart';

import '../../core/network/api_client.dart';
import '../../core/network/endpoints.dart';
import '../models/enums.dart';
import '../models/mail_attachment.dart';
import '../models/mail_page.dart';
import '../models/mail_row.dart';
import '../models/send_payload.dart';

/// 邮件读写。
///
/// 几个必须记住的服务端行为：
/// - **没有单封详情接口**：详情只能 `GET /email/list?full=1` 拿一页再按
///   `emailId` 找（通知深链找不到就往回翻页）。
/// - **HTTP 恒 200**，真实状态在信封 `code` 里，异常由拦截器抛。
/// - `/email/latest` 返回**裸数组**（不是 `{list}`），且只有收件、≤20 条、
///   用的 `emailBriefColumns` 里**没有 `isStar`` —— 见 [MailRow.starKnown]。
/// - `/email/delete` 的 `emailIds` 在 **query** 里，逗号拼接。
/// - `/email/read` 的 `emailIds` 在 **body** 里，是数组。两个接口形状不一样。
class EmailApi {
  const EmailApi(this._client);

  final ApiClient _client;

  /// 列表。`full=1` 才带完整 `content`/`attList`。
  ///
  /// [allReceive] 为 true 时忽略 `accountId`（服务端 `emailListFilters` 就是这么写的），
  /// 返回该用户所有邮箱的邮件 —— 这是 App 里「合并视图」的实现方式，
  /// 比逐个邮箱把 `allReceive` 打开要好（那个接口是切换语义）。
  Future<MailPage> list({
    required String profileId,
    required int accountId,
    int type = MailType.receive,
    int? beforeEmailId,
    int size = 50,
    bool full = false,
    bool allReceive = false,
    bool ascending = false,
    String mailboxEmail = '',
    CancelToken? cancelToken,
  }) async {
    final data = await _client.request<Object?>(
      Endpoints.emailList,
      query: <String, dynamic>{
        'accountId': accountId,
        'type': type,
        'size': size,
        if (beforeEmailId != null && beforeEmailId > 0) 'emailId': beforeEmailId,
        // timeSort=1 → 取比游标更大的 id（往上翻新），0 → 更小的（往下翻旧）。
        'timeSort': ascending ? 1 : 0,
        'full': full ? 1 : 0,
        if (allReceive) 'allReceive': 1,
      },
      cancelToken: cancelToken,
    );
    return MailPage.fromJson(
      data,
      profileId: profileId,
      mailboxEmail: mailboxEmail,
      pageSize: size,
    );
  }

  /// 增量新邮件（唯一的新信接口）。返回**裸数组**，≤20 条，仅收件。
  ///
  /// 返回的行同时给出「本次游标」：调用方应把 `emailId` 推到本页最大值，
  /// 并在发现**任何 `emailId <= 当前游标`** 时判定出现了空洞
  /// （服务端 `gt(email.emailId, emailId)` 理论上不会给出这种行，
  /// 但站内信、跨版本分支可能绕过），触发一次该邮箱的全量重扫。
  Future<List<MailRow>> latest({
    required String profileId,
    required int cursorEmailId,
    required int accountId,
    bool allReceive = false,
    String mailboxEmail = '',
    CancelToken? cancelToken,
  }) async {
    final data = await _client.request<Object?>(
      Endpoints.emailLatest,
      query: <String, dynamic>{
        'emailId': cursorEmailId,
        'accountId': accountId,
        if (allReceive) 'allReceive': 1,
      },
      cancelToken: cancelToken,
    );
    if (data is! List) return const <MailRow>[];
    return data
        .whereType<Map>()
        .map((e) => MailRow.fromJson(
              e.cast<String, dynamic>(),
              profileId: profileId,
              mailboxEmail: mailboxEmail,
            ))
        .toList(growable: false);
  }

  /// 标记已读/未读。服务端**只支持标已读**（`PUT /email/read` 写死
  /// `unread = READ`），标未读没有对应接口 —— 本地改、下次刷新会被服务端覆盖，
  /// 所以 [read] 为 false 时调用方只改本地并提示「服务端不支持标记未读」。
  Future<void> markRead(List<int> emailIds) async {
    if (emailIds.isEmpty) return;
    await _client.request<Object?>(
      Endpoints.emailRead,
      method: 'PUT',
      data: <String, dynamic>{'emailIds': emailIds},
    );
  }

  /// 删除。`emailIds` 走 **query**，逗号拼接。
  ///
  /// 站点若开了 `syncDelete`（默认开），服务端是**物理删除**，不可恢复。
  Future<void> delete(List<int> emailIds) async {
    if (emailIds.isEmpty) return;
    await _client.request<Object?>(
      Endpoints.emailDelete,
      method: 'DELETE',
      query: <String, dynamic>{'emailIds': emailIds.join(',')},
    );
  }

  /// 单封邮件的附件（`GET /email/attList?emailId=`）。
  ///
  /// 老版本没有这个端点（探测为 `absent`），退路是用 `full=1` 列表里的 `attList`。
  Future<List<MailAttachment>> attachments(int emailId) async {
    final data = await _client.request<Object?>(
      Endpoints.emailAttList,
      query: <String, dynamic>{'emailId': emailId},
    );
    if (data is! List) return const <MailAttachment>[];
    return data
        .whereType<Map>()
        .map((e) => MailAttachment.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// 发信（**小报文**路径）。
  ///
  /// 带附件的真实发送走 `features/compose/stream_body_builder.dart` 的流式 body，
  /// 不经过这里 —— 那样会把整个 base64 在内存里展开。
  ///
  /// 返回服务端创建的邮件行。**注意**：10 个附件 / 10 张内嵌图的检查发生在
  /// 插库之后（会留脏 `SAVING` 行），所以调用前必须
  /// [SendPayload.validate] 一遍。
  Future<List<MailRow>> send(
    SendPayload payload, {
    required String profileId,
    String mailboxEmail = '',
    CancelToken? cancelToken,
  }) async {
    final data = await _client.request<Object?>(
      Endpoints.emailSend,
      method: 'POST',
      data: payload.toJson(),
      cancelToken: cancelToken,
    );
    if (data is! List) return const <MailRow>[];
    return data
        .whereType<Map>()
        .map((e) => MailRow.fromJson(
              e.cast<String, dynamic>(),
              profileId: profileId,
              mailboxEmail: mailboxEmail,
            ))
        .toList(growable: false);
  }

  /// 流式发信：body 已经是拼好的 JSON 字节流（见 [StreamBodyBuilder]）。
  ///
  /// 必须显式带 `Content-Length` —— body 是 `Stream` 时 dio 无法自己推断，
  /// 而后面的 Cloudflare 链路更愿意收带长度的请求。[contentLength] 由
  /// 组装器精确算出（base64 长度可预算），不要用 -1。
  Future<List<MailRow>> sendStream(
    Stream<List<int>> body, {
    required int contentLength,
    required String profileId,
    String mailboxEmail = '',
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
  }) async {
    final data = await _client.request<Object?>(
      Endpoints.emailSend,
      method: 'POST',
      data: body,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
      options: Options(
        headers: <String, dynamic>{
          'Content-Type': 'application/json; charset=utf-8',
          'Content-Length': contentLength,
        },
      ),
    );
    if (data is! List) return const <MailRow>[];
    return data
        .whereType<Map>()
        .map((e) => MailRow.fromJson(
              e.cast<String, dynamic>(),
              profileId: profileId,
              mailboxEmail: mailboxEmail,
            ))
        .toList(growable: false);
  }
}

/// `/email/list` 的响应里 `latestEmail` 是对象，这里给一个安全取值。
int latestCursorOf(MailPage page) {
  if (page.latestEmailId != null && page.latestEmailId! > 0) {
    return page.latestEmailId!;
  }
  return page.list.fold<int>(0, (max, row) => row.emailId > max ? row.emailId : max);
}

/// 从 `full=1` 的一页里挑出目标邮件（没有单封详情接口，只能这么找）。
MailRow? pickById(Iterable<MailRow> rows, int emailId) {
  for (final row in rows) {
    if (row.emailId == emailId) return row;
  }
  return null;
}

/// 诊断页展示用：把一行的关键字段压成一行文本。
String describeRow(MailRow row) =>
    '#${row.emailId} type=${row.type} status=${row.status} '
    'unread=${row.unread} star=${row.isStar} '
    'create=${row.createTime?.toIso8601String() ?? '-'}';
